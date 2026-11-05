// Structural regression guard for the iOS BGTaskScheduler crash
// (decentespresso/decaid#1073, Dev-hwang/flutter_foreground_task#393).
//
// Dart tests cannot observe BGTaskScheduler at runtime, so this file asserts the *shape* of the native
// registration path instead: one registration call site, unreachable from plugin lifecycle callbacks,
// reachable only through the Info.plist-gated opt-in, with scheduling gated on that opt-in. Runtime
// evidence for the fix comes from an iOS simulator launch plus an lldb breakpoint on
// `registerForTaskWithIdentifier:`, not from here. A structural test goes green as soon as the text looks
// right: it is a tripwire against re-introducing the upstream bug, not a behavioural proof.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _pluginPath =
    'ios/flutter_foreground_task/Sources/flutter_foreground_task/'
    'SwiftFlutterForegroundTaskPlugin.swift';
const String _bridgePath =
    'ios/flutter_foreground_task/Sources/flutter_foreground_task/'
    'FlutterForegroundTaskPluginSPMBridge.swift';
const String _earlyRegistrationPath =
    'ios/flutter_foreground_task/Sources/flutter_foreground_task_early_registration/'
    'Flutterforegroundtaskearlyregistration.m';
const String _pluginShimPath =
    'ios/flutter_foreground_task/Classes/FlutterForegroundTaskPlugin.m';

/// Replaces line comments, (nestable) block comments and string literals with
/// spaces, preserving offsets and newlines, so brace matching cannot be fooled
/// by comments, doc comments or message strings.
String _codeOnly(String source) {
  final StringBuffer out = StringBuffer();
  int index = 0;

  void blank(int count) => out.write(' ' * count);
  void keep(int count) => out.write(source[index]);

  while (index < source.length) {
    if (source.startsWith('//', index)) {
      while (index < source.length && source[index] != '\n') {
        blank(1);
        index++;
      }
    } else if (source.startsWith('/*', index)) {
      int depth = 1;
      blank(2);
      index += 2;
      while (index < source.length && depth > 0) {
        if (source.startsWith('/*', index)) {
          depth++;
          blank(2);
          index += 2;
        } else if (source.startsWith('*/', index)) {
          depth--;
          blank(2);
          index += 2;
        } else {
          keep(1);
          index++;
        }
      }
    } else if (source[index] == '"') {
      final bool triple = source.startsWith('"""', index);
      final String quote = triple ? '"""' : '"';
      blank(quote.length);
      index += quote.length;
      while (index < source.length) {
        if (!triple && source[index] == r'\' && index + 1 < source.length) {
          blank(2);
          index += 2;
        } else if (source.startsWith(quote, index)) {
          blank(quote.length);
          index += quote.length;
          break;
        } else {
          keep(1);
          index++;
        }
      }
    } else {
      keep(1);
      index++;
    }
  }
  return out.toString();
}

/// Offsets [start, end] of the body of the first declaration of [functionName]
/// (Swift `func` or Objective-C `+ (void)`), found by matching braces in
/// code-only text. Offsets index the raw source too, since blanking preserves
/// length.
List<int> _functionSpan(String source, String functionName) {
  final String code = _codeOnly(source);
  int searchOffset = 0;
  while (true) {
    final int found = code.indexOf(functionName, searchOffset);
    if (found < 0) {
      fail('Could not find a declaration of $functionName');
    }
    final int lineStart = code.lastIndexOf('\n', found) + 1;
    final String linePrefix = code.substring(lineStart, found);
    if (linePrefix.contains('func ') || linePrefix.contains('(void)')) {
      final int openingBrace = code.indexOf('{', found);
      expect(openingBrace, isNonNegative,
          reason: 'Could not find the body of $functionName');
      int depth = 0;
      for (int index = openingBrace; index < code.length; index++) {
        if (code[index] == '{') {
          depth++;
        } else if (code[index] == '}') {
          depth--;
          if (depth == 0) {
            return <int>[openingBrace + 1, index];
          }
        }
      }
      fail('Unclosed body for $functionName');
    }
    searchOffset = found + functionName.length;
  }
}

/// Raw body text (comments and strings included).
String _rawBody(String source, String functionName) {
  final List<int> span = _functionSpan(source, functionName);
  return source.substring(span[0], span[1]);
}

/// Body text with comments and string literals blanked out.
String _codeBody(String source, String functionName) =>
    _codeOnly(_rawBody(source, functionName));

int _countOccurrences(String haystack, String needle) {
  int count = 0;
  int offset = 0;
  while (true) {
    final int found = haystack.indexOf(needle, offset);
    if (found < 0) {
      return count;
    }
    count++;
    offset = found + needle.length;
  }
}

void main() {
  setUp(() {
    if (!Directory('${Directory.current.path}/ios').existsSync()) {
      markTestSkipped('The ios directory is not present.');
    }
  });

  test('the helper is the only registration call site, and has one caller', () {
    final String source = File(_pluginPath).readAsStringSync();
    final String plugin = _codeOnly(source);
    final String helper = _codeBody(source, 'registerRefreshTaskIfNeeded');
    final String optIn =
        _codeBody(source, 'registerAppRefreshForBackgroundLaunch');

    // Exactly one BGTaskScheduler registration in the plugin source...
    expect(_countOccurrences(plugin, 'BGTaskScheduler.shared.register('), 1);
    // ...inside the helper...
    expect(_countOccurrences(helper, 'BGTaskScheduler.shared.register('), 1);
    // ...reachable only through the plist-gated opt-in (declaration + one call).
    expect(_countOccurrences(plugin, 'registerRefreshTaskIfNeeded'), 2);
    expect(_countOccurrences(optIn, 'registerRefreshTaskIfNeeded'), 1);
  });

  test('registration is idempotent and records the real result', () {
    final String helper =
        _codeBody(File(_pluginPath).readAsStringSync(), 'registerRefreshTaskIfNeeded');
    final int guard =
        helper.indexOf('guard !isBgTaskRegistered else { return }');
    final int register = helper.indexOf('BGTaskScheduler.shared.register(');

    expect(guard, isNonNegative, reason: 'the idempotence guard is required');
    expect(register, isNonNegative);
    expect(guard, lessThan(register));
    expect(helper,
        contains('isBgTaskRegistered = BGTaskScheduler.shared.register('));
  });

  test('plugin registration for the engine does not touch app refresh', () {
    final String body = _codeBody(
        File(_pluginPath).readAsStringSync(), 'register(with registrar');

    for (final String token in <String>[
      'BGTaskScheduler',
      'registerAppRefreshForBackgroundLaunch',
      'registerRefreshTaskIfNeeded',
      'scheduleAppRefresh',
    ]) {
      expect(body, isNot(contains(token)),
          reason: 'plugin registration must not reach $token');
    }
  });

  test('the launch callback does not register a refresh task', () {
    final String body = _codeBody(
        File(_pluginPath).readAsStringSync(), 'didFinishLaunchingWithOptions');

    for (final String token in <String>[
      'BGTaskScheduler',
      'registerAppRefreshForBackgroundLaunch',
      'registerRefreshTaskIfNeeded',
      'scheduleAppRefresh',
    ]) {
      expect(body, isNot(contains(token)),
          reason: 'didFinishLaunching must not reach $token');
    }
  });

  test('background and scene callbacks cannot register directly', () {
    final String source = File(_pluginPath).readAsStringSync();

    for (final String callback in <String>[
      'applicationDidEnterBackground',
      'sceneDidEnterBackground',
    ]) {
      final String body = _codeBody(source, callback);
      expect(body, isNot(contains('BGTaskScheduler')));
      expect(body, isNot(contains('registerRefreshTaskIfNeeded')));
    }
  });

  test('scheduling is gated on a successful registration', () {
    final String source = File(_pluginPath).readAsStringSync();
    final String plugin = _codeOnly(source);
    final String schedule = _codeBody(source, 'scheduleAppRefresh');
    final int guard =
        schedule.indexOf('guard isBgTaskRegistered else { return }');
    final int submit = schedule.indexOf('submit(');

    expect(guard, isNonNegative);
    expect(submit, isNonNegative);
    expect(guard, lessThan(submit));
    // One submission site in total, so no second ungated scheduling path.
    expect(_countOccurrences(plugin, 'BGTaskScheduler.shared.submit('), 1);
  });

  test('the opt-in checks the Info.plist identifier before registering', () {
    final String body = _rawBody(
        File(_pluginPath).readAsStringSync(),
        'registerAppRefreshForBackgroundLaunch');
    final int lookup = body.indexOf('BGTaskSchedulerPermittedIdentifiers');
    final int guard = body
        .indexOf('guard permitted.contains(refreshIdentifier) else { return }');
    final int register = body.indexOf('registerRefreshTaskIfNeeded');

    expect(lookup, isNonNegative);
    expect(guard, isNonNegative,
        reason: 'the plist guard is the whole opt-in condition');
    expect(register, isNonNegative);
    expect(lookup, lessThan(guard));
    expect(guard, lessThan(register));
  });

  test('both Objective-C load shims opt in without touching the scheduler', () {
    final String pluginShim = File(_pluginShimPath).readAsStringSync();
    final String earlyShim = File(_earlyRegistrationPath).readAsStringSync();
    final String bridge = File(_bridgePath).readAsStringSync();
    final String pluginLoad = _rawBody(pluginShim, 'load');
    final String earlyLoad = _rawBody(earlyShim, 'load');

    // CocoaPods: the +load shim calls the Swift opt-in directly.
    expect(pluginLoad, contains('registerAppRefreshForBackgroundLaunch'));
    expect(pluginLoad, isNot(contains('BGTaskScheduler')));
    // SPM: the +load shim calls the C bridge, which forwards to the same opt-in.
    expect(earlyLoad, contains('flutter_foreground_task_register_app_refresh'));
    expect(earlyLoad, isNot(contains('BGTaskScheduler')));
    expect(bridge, contains('flutter_foreground_task_register_app_refresh'));
    expect(bridge, contains('registerAppRefreshForBackgroundLaunch'));
    expect(bridge, isNot(contains('BGTaskScheduler')));
  });

  test('both packaging modes still compile the fix and the shims', () {
    final String podspec =
        File('ios/flutter_foreground_task.podspec').readAsStringSync();
    final String package =
        File('ios/flutter_foreground_task/Package.swift').readAsStringSync();

    expect(
        podspec,
        contains(
            'flutter_foreground_task/Sources/flutter_foreground_task/**/*.swift'));
    expect(podspec, contains('flutter_foreground_task/Classes/**/*.{h,m}'));
    expect(package, contains('flutter_foreground_task_early_registration'));
  });
}
