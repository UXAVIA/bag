import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/constants/app_constants.dart';
import 'sentinel_records.dart';

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

/// Whether Bag may show notifications, as
/// [NotificationService.notificationAccess] reads it: allowed, switched off
/// by the user, or unknown (the answer couldn't be read).
enum NotificationAccess { allowed, off, unknown }

class NotificationService {
  /// Test seam: called instead of the plugin by [showSentinelAlert], with
  /// the id, title and body it would show. Ignored in release builds. Reset
  /// it in tearDown.
  @visibleForTesting
  static Future<void> Function(int id, String title, String body)? debugShow;

  /// Shows a Sentinel alert: the title and body of [sentinelAlertCopy], id
  /// [SentinelAlert.notifId] (so a confirmation replaces its pending alert).
  /// On iOS a plain notification; iOS's own preview setting decides whether
  /// the lock screen shows it. On Android it goes to Sentinel's alert
  /// channel, at the importance Android's Sentinel service gives that kind.
  ///
  /// Needs no [initialise] in the calling engine: the iOS background refresh
  /// runs in an engine of its own, where `main()` never ran, and asking for
  /// permission there could not show a prompt anyway (it is asked when
  /// Sentinel is turned on). Never throws; a failure is logged by type only,
  /// since the copy holds the wallet label and an amount.
  static Future<void> showSentinelAlert(SentinelAlert a) async {
    final copy = sentinelAlertCopy(a);
    try {
      final show = kReleaseMode ? null : debugShow;
      if (show != null) {
        await show(a.notifId, copy.title, copy.body);
        return;
      }
      final spend = a.kind == SentinelAlertKind.pendingOut ||
          a.kind == SentinelAlertKind.sent;
      await _plugin.show(
        a.notifId,
        copy.title,
        copy.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            AppConstants.notifChannelIdSentinelAlerts,
            AppConstants.notifChannelNameSentinelAlerts,
            channelDescription: AppConstants.notifChannelDescSentinelAlerts,
            importance: spend ? Importance.high : Importance.defaultImportance,
            priority: spend ? Priority.high : Priority.defaultPriority,
            visibility: NotificationVisibility.secret,
            icon: 'ic_notification',
            color: const Color(0xFFF7931A),
          ),
          iOS: const DarwinNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('[NotificationService] Sentinel alert not shown: '
          '${e.runtimeType}');
    }
  }

  /// Initialise the plugin and create the Android notification channel.
  /// Call once from main() after WidgetsFlutterBinding.ensureInitialized().
  static Future<void> initialise() async {
    const androidInit = AndroidInitializationSettings('ic_notification');
    const iosInit = DarwinInitializationSettings();
    const initSettings = InitializationSettings(android: androidInit, iOS: iosInit);
    await _plugin.initialize(initSettings);
  }

  /// Test seam: called instead of the plugin by [requestPermission].
  /// Ignored in release builds. Reset it in tearDown.
  @visibleForTesting
  static Future<bool> Function()? debugRequestPermission;

  /// Request permission to notify: POST_NOTIFICATIONS on Android 13+, alerts
  /// and sounds on iOS (asked when Sentinel Lite is turned on; iOS shows its
  /// prompt only the first time). Returns true if granted or not required.
  static Future<bool> requestPermission() async {
    final seam = kReleaseMode ? null : debugRequestPermission;
    if (seam != null) return seam();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final granted = await android.requestNotificationsPermission();
      return granted ?? false;
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      final granted = await ios.requestPermissions(alert: true, sound: true);
      return granted ?? false;
    }
    return true;
  }

  /// Test seam: called instead of the plugin by [notificationAccess]; what
  /// it throws is read as an error of the plugin. Ignored in release builds.
  /// Reset it in tearDown.
  @visibleForTesting
  static Future<NotificationAccess> Function()? debugNotificationAccess;

  /// Whether Bag may show notifications now (the user can turn them off in
  /// the system settings at any time): [NotificationAccess.allowed] where
  /// neither platform plugin is present, [NotificationAccess.unknown] when
  /// the answer can't be read, so a caller warns only for a real "off".
  static Future<NotificationAccess> notificationAccess() async {
    try {
      final seam = kReleaseMode ? null : debugNotificationAccess;
      if (seam != null) return await seam();
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        return _access(await android.areNotificationsEnabled());
      }
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) {
        return _access((await ios.checkPermissions())?.isEnabled);
      }
      return NotificationAccess.allowed;
    } catch (e) {
      debugPrint('[NotificationService] permission check failed: '
          '${e.runtimeType}');
      return NotificationAccess.unknown;
    }
  }

  static NotificationAccess _access(bool? enabled) => switch (enabled) {
        true => NotificationAccess.allowed,
        false => NotificationAccess.off,
        null => NotificationAccess.unknown,
      };

  /// Fire a price alert notification.
  static Future<void> showPriceAlert({
    required int id,
    required String title,
    required String body,
  }) async {
    try {
      await _plugin.show(id, title, body, _notifDetails);
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationService] show failed: $e');
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
      if (kDebugMode) {
        debugPrint('[NotificationService] fee alert show failed: $e');
      }
    }
  }
}
