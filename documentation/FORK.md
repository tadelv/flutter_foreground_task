# Fork maintenance — tadelv/flutter_foreground_task

This is a fork of [Dev-hwang/flutter_foreground_task](https://github.com/Dev-hwang/flutter_foreground_task).
Package identity, history, licence and Dart API stay upstream's; this document is the fork's change ledger.

| | |
|---|---|
| Upstream base | `Dev-hwang/flutter_foreground_task` @ `f2acda8447dbf4e659be2782c010fe3dc6e8b187` ("release: 11.0.3") |
| Upstream tags | **none** — upstream does not tag releases, so `11.0.3` is only addressable by commit SHA |
| Fork version | `11.0.3+2` |
| Downstream consumer | [decentespresso/decaid](https://github.com/decentespresso/decaid) (issue #1073) |
| Upstream issue | [Dev-hwang/flutter_foreground_task#393](https://github.com/Dev-hwang/flutter_foreground_task/issues/393) |

Everything in this document is a **fork delta**. Nothing in `lib/` or `android/` differs from upstream.

## Why this fork exists

Decaid aborts at launch on iOS 16/17 with `SIGABRT` inside `BGTaskScheduler`. The app never uses iOS
background app refresh (its foreground service is Android-only), yet the plugin registered a
`BGTaskScheduler` handler on every launch, from a callback Flutter delivers *after* launch completed.

## Root cause

`BGTaskScheduler.register(forTaskWithIdentifier:usingQueue:launchHandler:)` asserts, with the same
stack and no visible assertion message, in two situations:

1. the identifier is missing from `BGTaskSchedulerPermittedIdentifiers`, and
2. registration happens after `application(_:didFinishLaunchingWithOptions:)` has returned.

Upstream 11.0.3 hit both:

- `ios/flutter_foreground_task/Sources/flutter_foreground_task/SwiftFlutterForegroundTaskPlugin.swift`
  `application(_:didFinishLaunchingWithOptions:)` called `registerAppRefresh()` unconditionally on
  iOS 13+. This is a *plugin* application-delegate callback, and under the UIScene lifecycle Flutter
  delivers it through
  `-[FlutterPluginAppLifeCycleDelegate sceneFallbackDidFinishLaunchingApplication:]` during
  `-[FlutterViewController awakeFromNib]` — i.e. after launch, sometimes hours later when the app was
  kept alive by another background mode.
- 11.0.2/11.0.3 added a *guarded* parallel path (the Objective-C `+load` shims calling
  `registerAppRefreshForBackgroundLaunch()`, which returns early unless the Info.plist declares the
  identifier). That only helped apps that had already opted in: for them the shim registers at
  image-load time and the late `didFinishLaunching` call is swallowed by the `isBgTaskRegistered` flag.
  Apps that had *not* opted in took the shim's early return and then still hit the late, unguarded
  registration — the crash population in #1073. Upstream #393 stayed open for exactly this reason.

## The change

`SwiftFlutterForegroundTaskPlugin.swift` only:

1. `application(_:didFinishLaunchingWithOptions:)` no longer registers anything. A plugin lifecycle
   callback can never satisfy Apple's timing rule, so it is not used for registration at all.
2. Registration happens in exactly one place, `private static func registerRefreshTaskIfNeeded()`
   (upstream's `registerAppRefresh()`, renamed so it cannot be confused with the public opt-in), which
   keeps the idempotence guard: a second call is a no-op, never a second `BGTaskScheduler` call.
3. That function is reachable only through the pre-existing public
   `registerAppRefreshForBackgroundLaunch()`, which checks `BGTaskSchedulerPermittedIdentifiers` first.
   **No new public symbol was added**; the opt-in API already existed in 11.0.2+.
4. `scheduleAppRefresh()` returns early unless the task is actually registered, so a host that did not
   opt in never submits a request for a task it never registered (covers
   `applicationDidEnterBackground` and `sceneDidEnterBackground`, which keep calling it unchanged).
5. The legacy `UIApplication.shared.setMinimumBackgroundFetchInterval(...)` call (deprecated since iOS 13,
   still the trigger for pre-iOS-13 background fetch, and the podspec supports iOS 12) is now gated on
   `UIBackgroundModes` containing `fetch`, so a host that never declared the capability is not scheduled
   a fetch window. Hosts that opted in keep the legacy behaviour unchanged. (Review point from the
   downstream fork review: remove-or-guard, guarded rather than removed.)

The Objective-C shims, the podspec source list, `Package.swift`, `lib/` and `android/` are untouched.

## How "default off" behaves

An app that does nothing different after this fork:

- never calls `BGTaskScheduler.register`, on cold launch, on engine init, on UIScene connection or
  reconnection;
- does not need `BGTaskSchedulerPermittedIdentifiers` or a `fetch` entry in `UIBackgroundModes`;
- never reaches `BGTaskScheduler.submit`, and never asks for a legacy background-fetch interval;
- keeps the Android foreground service, the Dart API and the iOS foreground task lifecycle exactly as
  upstream.

The only behaviour that changes for such an app is the one it never asked for: no iOS background app
refresh.

## How a host opts in (only if it wants iOS background app refresh)

1. `ios/Runner/Info.plist`:

   ```xml
   <key>BGTaskSchedulerPermittedIdentifiers</key>
   <array>
       <string>com.pravera.flutter_foreground_task.refresh</string>
   </array>
   <key>UIBackgroundModes</key>
   <array>
       <string>fetch</string>
       <!-- add bluetooth-central etc. only if the app really uses them -->
   </array>
   ```

2. `ios/Runner/AppDelegate.swift` — call the opt-in inside
   `application(_:didFinishLaunchingWithOptions:)`, **before it returns**:

   ```swift
   import flutter_foreground_task

   @main
   @objc class AppDelegate: FlutterAppDelegate {
     override func application(
       _ application: UIApplication,
       didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
     ) -> Bool {
       // Optional but recommended: registers explicitly, at the one moment Apple allows.
       SwiftFlutterForegroundTaskPlugin.registerAppRefreshForBackgroundLaunch()
       return super.application(application, didFinishLaunchingWithOptions: launchOptions)
     }
   }
   ```

   In Objective-C the method is not on the Objective-C `FlutterForegroundTaskPlugin` class — it is
   `@objc` on the Swift `SwiftFlutterForegroundTaskPlugin`, so import the plugin's generated Swift
   header and call that class:

   ```objc
   #import <flutter_foreground_task/flutter_foreground_task-Swift.h>

   [SwiftFlutterForegroundTaskPlugin registerAppRefreshForBackgroundLaunch];
   ```

   The explicit call is optional in practice — the `+load` shims already register at image-load time,
   which is also before `didFinishLaunching` returns — but it is the documented, Apple-recommended
   entry point, it survives a linker that strips the unreferenced `+load` class, and it makes the
   dependency visible in the host's own source.

3. `example/ios/Runner/AppDelegate.swift` in this repository shows the pattern (the example app is an
   opted-in host, as it was upstream).

Timing rules, stated once: register **before `didFinishLaunching` returns**. Never from a Flutter plugin
callback, a scene delegate, a `Timer`, or Dart. Do not add the plist keys "just in case" without the
registration call, and do not call registration without the plist keys: both halves are one opt-in.

## Supporting evidence (and what is not proven)

Reproduced on **iOS 27.0 simulator** (24A434, Xcode 27.0, Flutter 3.47.0/Dart 3.13.0) with the example
app configured like Decaid (`BGTaskSchedulerPermittedIdentifiers` removed, `UIBackgroundModes` =
`bluetooth-central` only):

- Before the fix, the system log reports
  `Registration rejected; com.pravera.flutter_foreground_task.refresh is not advertised in the
  application's Info.plist`, and an lldb breakpoint on `registerForTaskWithIdentifier:` stops with the
  exact crash stack from #1073:
  `registerAppRefresh()` (line 152) ← `application(didFinishLaunchingWithOptions:)` (line 101) ←
  `…isFallbackForScene:` ← `sceneFallbackDidFinishLaunchingApplication:` ←
  `-[FlutterViewController awakeFromNib]` ← `-[UIApplication _connectUISceneFromFBSScene:…]`.
- On **iOS 27.0** the abort did not happen: the identical call was instead rejected and logged. That is
  an iOS 27 observation. The iOS 16/17 abort is known only from the crash stacks in #1073, not from this
  machine.
- **After the fix, same build configuration** (`BGTaskSchedulerPermittedIdentifiers` removed,
  `UIBackgroundModes` = `bluetooth-central` only): the breakpoint was not hit in a 40 s window, no
  registration attempt was logged, and the app launched and stayed alive.
- **After the fix, opted-in configuration** (upstream's example plist, identifier + `fetch`): the same
  breakpoint stops during dyld image initialisers —
  `+[FlutterForegroundTaskEarlyRegistration load]` → `flutter_foreground_task_register_app_refresh()` →
  `registerAppRefreshForBackgroundLaunch()` → `registerRefreshTaskIfNeeded()` — i.e. before `main` and
  therefore inside the window Apple requires. `BGAppRefreshTask` *handler execution* was not exercised.

Not proven here, and not claimed:

- **No iOS 16/17 runtime is available on this machine** (Xcode 27 ships only the iOS 27.0 simulator
  runtime), so the `SIGABRT` was never observed, and no physical iOS 16.7 iPad was ever used.
  The fix is verified by call-site reachability and timing, not by reproducing the abort.
- No BLE/background continuity testing on devices; no TestFlight crash-submission data after release.
- The Dart regression test (`test/ios_app_refresh_registration_test.dart`) is structural: it proves
  there is one registration call site, that no plugin lifecycle callback reaches it, that it sits behind
  the plist guard, and that scheduling is gated. It cannot observe `BGTaskScheduler` at runtime — that
  is what the simulator/lldb evidence above is for.

## Compatibility limits

- **Dart/Flutter floor: deliberately relaxed** from upstream `sdk: ^3.12.0` / `flutter: ">=3.44.0"` to
  `sdk: ^3.10.0` / `flutter: ">=3.22.0"` (9.2.2's values). The Dart sources are byte-identical to
  9.2.2, so the raised floor was declarative. This lets Decaid keep Flutter 3.44.2 instead of moving its
  release pipeline in the same change as a launch-crash fix.
  What is actually verified: the plugin `pub get`/`analyze`/`test` and the example APK + iOS simulator
  builds on **Flutter 3.47.0 locally and on Flutter 3.44.2 in `.github/workflows/fork_compat.yml`** — i.e.
  Decaid's pinned toolchain. The declared floor (`3.10`/`3.22`), inherited from 9.2.2, is *not* exercised
  at its minimum here; treat anything below 3.44.2 as untested. **Exit condition:** restore upstream's
  values when Decaid moves past Flutter 3.46, so the patch stays upstream-proposable.
  (Upstream's own `>=3.44.0` floor is also self-inconsistent: Dart 3.12 ships with Flutter 3.46.)
- **Android:** unchanged, source-for-source identical to upstream `11.0.3` and to `9.2.2`. Upstream
  11.0.0 builds Kotlin without `kotlin-android` (Gradle 8.14 / AGP 8.11.1 / Kotlin 2.2.20 documented);
  Decaid already runs Gradle 8.14.3 / AGP 8.13.2 / Kotlin 2.3.21 / compileSdk 36, so nothing to do.
- **iOS packaging:** CocoaPods (podspec source list fixed upstream in 11.0.3) and Swift Package Manager
  are both supported; podspec platform 12.0, Package.swift iOS 13.0 — both below Decaid's 15.0.
- **Dart API migration 9.2.2 → 11.0.3:** none. `git diff b3d3d30 f2acda8 -- lib/` is empty.

## Syncing with upstream

```sh
git fetch upstream
git checkout master && git merge --ff-only upstream/master     # if upstream is ahead
git checkout fix/ios-app-refresh-opt-in
git rebase master                                               # resolve, keep the delta small
flutter pub get && flutter analyze && flutter test
```

Keep the fork delta to: the four Swift hunks, the fork-only CI workflow, this document, the README note,
the CHANGELOG entry, the example `AppDelegate` demonstration, the Dart regression test, and the pubspec
`environment` block. If upstream lands its own fix for #393, prefer upstream's and delete ours:
rerun `test/ios_app_refresh_registration_test.dart`, and re-run the simulator/lldb probe with a
non-opted-in host.

## Proposing the fix upstream

1. Comment on [Dev-hwang/flutter_foreground_task#393](https://github.com/Dev-hwang/flutter_foreground_task/issues/393)
   with the root cause above and the simulator/lldb evidence (the Flutter team asked for exactly this
   shape of fix: an explicit host-callable registration API, no plugin-callback registration).
2. Open a PR against `Dev-hwang/flutter_foreground_task:master` containing **only** the Swift hunks plus
   the Dart regression test — no version bump, no SDK floor change, no fork CI workflow.
3. If upstream wants the floor to stay at `^3.12.0`, that is fine: it is a fork-only divergence, not
   part of the fix.

## Pinning policy for consumers

- Consume an immutable ref: the fork tag (`fft-fork-11.0.3.1`) or the commit SHA it points at — never a
  branch.

```yaml
flutter_foreground_task:
  git:
    url: https://github.com/tadelv/flutter_foreground_task.git
    ref: fft-fork-11.0.3.1   # or the commit SHA for belt-and-braces
```

- Roll back by reverting the single dependency commit (restoring the previous `pubspec.lock`); the fork
  and its evidence stay in place.
