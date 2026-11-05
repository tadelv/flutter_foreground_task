import Flutter
import UIKit
import BackgroundTasks

public class SwiftFlutterForegroundTaskPlugin: NSObject, FlutterPlugin {
  // ====================== Plugin ======================
  static private(set) var registerPlugins: FlutterPluginRegistrantCallback? = nil
  
  private var notificationPermissionManager: NotificationPermissionManager? = nil
  private var backgroundServiceManager: BackgroundServiceManager? = nil

  private var foregroundChannel: FlutterMethodChannel? = nil
  
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SwiftFlutterForegroundTaskPlugin()
    instance.initServices()
    instance.initChannels(registrar.messenger())
    registrar.addApplicationDelegate(instance)
    if #available(iOS 13.0, *) {
      registrar.addSceneDelegate(instance)
    }
  }
  
  @objc public static func setPluginRegistrantCallback(_ callback: @escaping FlutterPluginRegistrantCallback) {
    registerPlugins = callback
  }

  /// Opt-in entry point for iOS background app refresh.
  ///
  /// This is the only path that registers the BGTaskScheduler task, because Apple requires
  /// `BGTaskScheduler.register` to be called before `application(_:didFinishLaunchingWithOptions:)`
  /// returns. A Flutter plugin cannot satisfy that from its own lifecycle callback: with the UIScene
  /// lifecycle Flutter delivers `didFinishLaunching` after launch completed (and possibly after the
  /// scene connected), which trips a BGTaskScheduler assertion. See
  /// https://github.com/Dev-hwang/flutter_foreground_task/issues/393.
  ///
  /// To opt in, a host app must:
  ///   1. declare `com.pravera.flutter_foreground_task.refresh` in `BGTaskSchedulerPermittedIdentifiers`,
  ///   2. declare `fetch` in `UIBackgroundModes`,
  ///   3. call this method from `AppDelegate.application(_:didFinishLaunchingWithOptions:)` before returning.
  /// The Objective-C `+load` shims call it at image-load time for the same reason; extra calls are ignored
  /// once the task is registered. Hosts that do not opt in never register, never schedule, and need neither
  /// Info.plist entry.
  @objc public static func registerAppRefreshForBackgroundLaunch() {
    if #available(iOS 13.0, *) {
      let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
      guard permitted.contains(refreshIdentifier) else { return }
      registerRefreshTaskIfNeeded()
    }
  }
  
  public static func addTaskLifecycleListener(_ listener: FlutterForegroundTaskLifecycleListener) {
    BackgroundService.sharedInstance.addTaskLifecycleListener(listener)
  }
  
  public static func removeTaskLifecycleListener(_ listener: FlutterForegroundTaskLifecycleListener) {
    BackgroundService.sharedInstance.removeTaskLifecycleListener(listener)
  }
  
  private func initServices() {
    notificationPermissionManager = NotificationPermissionManager()
    backgroundServiceManager = BackgroundServiceManager()
  }
  
  private func initChannels(_ messenger: FlutterBinaryMessenger) {
    foregroundChannel = FlutterMethodChannel(name: "flutter_foreground_task/methods", binaryMessenger: messenger)
    foregroundChannel?.setMethodCallHandler(onMethodCall)
  }
  
  private func onMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments
    do {
      switch call.method {
        case "checkNotificationPermission":
          notificationPermissionManager!.checkPermission { permission in
            result(permission.rawValue)
          }
        case "requestNotificationPermission":
          notificationPermissionManager!.requestPermission { permission in
            result(permission.rawValue)
          }
        case "startService":
          try backgroundServiceManager!.start(arguments: args)
          result(true)
        case "restartService":
          try backgroundServiceManager!.restart(arguments: args)
          result(true)
        case "updateService":
          try backgroundServiceManager!.update(arguments: args)
          result(true)
        case "stopService":
          try backgroundServiceManager!.stop()
          result(true)
        case "sendData":
          backgroundServiceManager!.sendData(data: args)
        case "isRunningService":
          result(backgroundServiceManager!.isRunningService())
        case "minimizeApp":
          UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
        case "isAppOnForeground":
          result(UIApplication.shared.applicationState == .active)
        default:
          result(FlutterMethodNotImplemented)
      }
    } catch {
      let code = String(describing: error.self)
      let message = error.localizedDescription
      let flutterError = FlutterError(code: code, message: message, details: nil)
      result(flutterError)
    }
  }
  
  // ================== App Lifecycle ===================
  public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [AnyHashable : Any] = [:]) -> Bool {
    // Deprecated since iOS 13, but still the trigger for legacy (pre-iOS-13) background fetch, and the
    // podspec supports iOS 12. Only ask for a fetch window when the host declared the capability, so an
    // app that does not use background fetch is never scheduled one.
    if let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
       modes.contains("fetch") {
      UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
    }
    // Deliberately no BGTaskScheduler registration here: Flutter only delivers this plugin
    // application-delegate callback after launch completed, which is too late for
    // BGTaskScheduler.register (Dev-hwang/flutter_foreground_task#393, decentespresso/decaid#1073).
    // iOS background app refresh is opt-in through registerAppRefreshForBackgroundLaunch().
    return true
  }
  
  public func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
    completionHandler(.newData)
    return true
  }
  
  public func applicationDidEnterBackground(_ application: UIApplication) {
    if #available(iOS 13.0, *) {
      SwiftFlutterForegroundTaskPlugin.scheduleAppRefresh()
    }
  }
  
  public func applicationWillTerminate(_ application: UIApplication) {
    if !BackgroundService.sharedInstance.isRunningService {
      return
    }
    
    BackgroundServiceStatus.setData(action: BackgroundServiceAction.APP_TERMINATE)
    BackgroundService.sharedInstance.run()
    
    // Chance to handle onDestroy before app terminates
    sleep(5)
  }

  // ================= Service Delegate =================
  @available(iOS 10.0, *)
  public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                     didReceive response: UNNotificationResponse,
                                     withCompletionHandler completionHandler: @escaping () -> Void) {
    BackgroundService.sharedInstance.userNotificationCenter(center, response, completionHandler)
  }
  
  @available(iOS 10.0, *)
  public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                     willPresent notification: UNNotification,
                                     withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    BackgroundService.sharedInstance.userNotificationCenter(center, notification, completionHandler)
  }
  
  // ============== Background App Refresh ==============
  public static var refreshIdentifier: String = "com.pravera.flutter_foreground_task.refresh"
  private static var isBgTaskRegistered: Bool = false

  @available(iOS 13.0, *)
  private static func registerRefreshTaskIfNeeded() {
    guard !isBgTaskRegistered else { return }
    // The flag records whether registration actually succeeded, not merely that it was attempted.
    // Both callers (the Obj-C +load shims at image-load time, and AppDelegate.didFinishLaunching) run on
    // the main thread before the app is interactive, so this one-time state needs no further locking.
    isBgTaskRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
      handleAppRefresh(task: task as! BGAppRefreshTask)
    }
  }
  
  @available(iOS 13.0, *)
  private static func scheduleAppRefresh() {
    // A host that never opted in has no registered handler; never submit a task for it.
    guard isBgTaskRegistered else { return }

    let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      print("Could not schedule app refresh: \(error)")
    }
  }
  
  @available(iOS 13.0, *)
  private static func cancelAppRefresh() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
  }
  
  @available(iOS 13.0, *)
  private static func handleAppRefresh(task: BGAppRefreshTask) {
    let queue = OperationQueue()
    let operation = AppRefreshOperation()
    
    task.expirationHandler = {
      operation.cancel()
    }
    
    operation.completionBlock = {
      // Schedule a new refresh task
      scheduleAppRefresh()

      task.setTaskCompleted(success: true)
    }
    
    queue.addOperation(operation)
  }
}

class AppRefreshOperation: Operation {
  override func main() {
    let semaphore = DispatchSemaphore(value: 0)
    
    // avoid non-platform thread
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
      semaphore.signal()
    }
    
    semaphore.wait()
  }
}

@available(iOS 13.0, *)
extension SwiftFlutterForegroundTaskPlugin: FlutterSceneLifeCycleDelegate {
  public func sceneDidEnterBackground(_ scene: UIScene) {
    SwiftFlutterForegroundTaskPlugin.scheduleAppRefresh()
  }
}
