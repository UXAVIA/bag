import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/constants/app_constants.dart';

final _plugin = FlutterLocalNotificationsPlugin();

const _androidDetails = AndroidNotificationDetails(
  AppConstants.notifChannelId,
  AppConstants.notifChannelName,
  channelDescription: AppConstants.notifChannelDesc,
  importance: Importance.high,
  priority: Priority.high,
  visibility: NotificationVisibility.secret,
  icon: 'ic_notification',
  color: Color(0xFFF7931A),
);

const _notifDetails = NotificationDetails(android: _androidDetails);

class NotificationService {
  /// Initialise the plugin and create the Android notification channel.
  /// Call once from main() after WidgetsFlutterBinding.ensureInitialized().
  static Future<void> initialise() async {
    const androidInit = AndroidInitializationSettings('ic_notification');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(initSettings);
  }

  /// Request POST_NOTIFICATIONS permission (Android 13+).
  /// Returns true if granted or not required.
  static Future<bool> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    final granted = await android.requestNotificationsPermission();
    return granted ?? false;
  }

  /// Fire a price alert notification.
  static Future<void> showPriceAlert({
    required int id,
    required String title,
    required String body,
  }) async {
    try {
      await _plugin.show(id, title, body, _notifDetails);
    } catch (e) {
      debugPrint('[NotificationService] show failed: $e');
    }
  }

  /// Fire a network fee alert notification.
  static Future<void> showFeeAlert({
    required int id,
    required String title,
    required String body,
  }) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        AppConstants.notifChannelIdFeeAlerts,
        AppConstants.notifChannelNameFeeAlerts,
        channelDescription: AppConstants.notifChannelDescFeeAlerts,
        importance: Importance.high,
        priority: Priority.high,
        visibility: NotificationVisibility.secret,
        icon: 'ic_notification',
        color: Color(0xFFF7931A),
      ),
    );
    try {
      await _plugin.show(id, title, body, details);
    } catch (e) {
      debugPrint('[NotificationService] fee alert show failed: $e');
    }
  }
}
