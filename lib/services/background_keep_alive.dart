import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/secure/safe_log.dart';

/// Top-level entry for the Android/iOS foreground-task isolate.
@pragma('vm:entry-point')
void agentDockForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_AgentDockKeepAliveHandler());
}

class _AgentDockKeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  /// Periodic tick — keeps OEMs from freezing a "silent" foreground service.
  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }
}

/// Pedometer-style background stay-alive for agent SSH bridges.
///
/// Runs a persistent foreground notification (like fitness trackers) so Android
/// does not freeze the process when you leave the app. Default: on for phones.
class BackgroundKeepAlive {
  static const prefKey = 'run_in_background';

  bool _initialized = false;
  bool _holding = false;
  int _sessionCount = 0;

  /// True when lifecycle pause should leave SSH/ACP bridges alone.
  bool get canSurviveBackground {
    if (kIsWeb) return false;
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      return true;
    }
    return _holding;
  }

  bool get isHolding => _holding;

  bool get isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Default on for phones — same idea as a pedometer always tracking.
  Future<bool> isEnabled() async {
    if (!isMobile) return true;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKey) ?? true;
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, enabled);
    if (enabled) {
      await ensureRunning();
    } else {
      await release();
    }
  }

  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    if (!isMobile) {
      _initialized = true;
      return;
    }

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'agent_dock_bridge',
        channelName: 'Background agent bridge',
        channelDescription:
            'Keeps Agent Dock running so agents stay connected when you leave the app.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // Heartbeat so aggressive OEMs treat us like a fitness tracker, not idle.
        eventAction: ForegroundTaskEventAction.repeat(30000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  /// Start on launch when the setting is on (does not wait for an agent).
  Future<bool> ensureRunning() async {
    if (!await isEnabled()) return false;
    return hold(sessionCount: _sessionCount);
  }

  /// Refresh the notification for the current agent count; keep running even at 0.
  Future<bool> sync({required int sessionCount}) async {
    _sessionCount = sessionCount;
    if (!await isEnabled()) {
      await release();
      return false;
    }
    return hold(sessionCount: sessionCount);
  }

  Future<bool> hold({required int sessionCount}) async {
    _sessionCount = sessionCount;
    if (kIsWeb) return false;
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      _holding = true;
      return true;
    }
    if (!isMobile) return false;

    await init();
    await _requestPermissions();

    final (title, text) = _copyFor(sessionCount);

    try {
      final ServiceRequestResult result;
      if (await FlutterForegroundTask.isRunningService) {
        result = await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
      } else {
        result = await FlutterForegroundTask.startService(
          serviceTypes: const [ForegroundServiceTypes.dataSync],
          serviceId: 2601,
          notificationTitle: title,
          notificationText: text,
          callback: agentDockForegroundCallback,
        );
      }
      if (result is ServiceRequestFailure) {
        SafeLog.d('foreground keep-alive failed', result.error);
        _holding = false;
        return false;
      }
      _holding = true;
      return true;
    } catch (e) {
      SafeLog.d('foreground keep-alive start error', e);
      _holding = false;
      return false;
    }
  }

  (String, String) _copyFor(int sessionCount) {
    if (sessionCount <= 0) {
      return (
        'Agent Dock is running',
        'Background mode on — agents reconnect instantly',
      );
    }
    if (sessionCount == 1) {
      return (
        'Agent Dock · 1 agent live',
        'Connected in the background',
      );
    }
    return (
      'Agent Dock · $sessionCount agents live',
      'Connected in the background',
    );
  }

  Future<void> release() async {
    _holding = false;
    if (kIsWeb) return;
    if (!isMobile) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      SafeLog.d('foreground keep-alive stop error', e);
    }
  }

  Future<void> _requestPermissions() async {
    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (Platform.isAndroid) {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
  }
}
