import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../data/secure/safe_log.dart';

/// Local (not FCM) notifications when an assistant writes text.
class LocalNotificationService {
  LocalNotificationService();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;
  final Map<String, DateTime> _lastNotifyAt = {};

  Future<void> init() async {
    if (_ready) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const mac = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const init = InitializationSettings(
      android: android,
      iOS: ios,
      macOS: mac,
    );
    try {
      await _plugin.initialize(settings: init);
      if (Platform.isAndroid) {
        final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        await androidPlugin?.requestNotificationsPermission();
        await androidPlugin?.createNotificationChannel(
          const AndroidNotificationChannel(
            'agent_messages',
            'Agent messages',
            description: 'When an agent replies with text',
            importance: Importance.defaultImportance,
          ),
        );
      }
      if (Platform.isIOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }
      if (Platform.isMacOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }
      _ready = true;
    } catch (e) {
      SafeLog.d('local notifications init failed', e);
    }
  }

  /// Show a notification for assistant text (not tools / thoughts).
  Future<void> notifyAssistantText({
    required String chatId,
    required String title,
    required String snippet,
    required bool suppressBecauseFocused,
  }) async {
    if (suppressBecauseFocused) return;
    final text = snippet.trim();
    if (text.isEmpty) return;

    final now = DateTime.now();
    final last = _lastNotifyAt[chatId];
    // Coalesce streaming deltas into one alert every few seconds.
    if (last != null && now.difference(last) < const Duration(seconds: 8)) {
      return;
    }
    _lastNotifyAt[chatId] = now;

    await init();
    if (!_ready) return;

    final body = text.length > 180 ? '${text.substring(0, 180)}…' : text;
    final id = chatId.hashCode & 0x7fffffff;

    try {
      await _plugin.show(
        id: id,
        title: title.isEmpty ? 'Agent Dock' : title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'agent_messages',
            'Agent messages',
            channelDescription: 'When an agent replies with text',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
        ),
        payload: chatId,
      );
    } catch (e) {
      SafeLog.d('show notification failed', e);
    }
  }
}
