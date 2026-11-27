import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'sentinel_service.dart';

/// iOS's Background App Refresh setting for Bag
/// (`UIApplication.backgroundRefreshStatus`). [unknown] when it can't be read.
enum BackgroundRefresh { available, denied, restricted, unknown }

/// What stops Sentinel Lite's background checks on iPhone, for its screen's
/// status lines (spec D8): the Background App Refresh setting and Low Power
/// Mode. Answered in Swift by `AppDelegate.didInitializeImplicitFlutterEngine`
/// on the UI engine only.
///
/// Where Sentinel is the always-on service (Android,
/// [SentinelService.isAlwaysOn]) neither applies: [refresh] is
/// [BackgroundRefresh.available] and [lowPowerMode] false, with no call.
/// Any error (no handler, a platform error, an unexpected answer) reads as
/// [BackgroundRefresh.unknown] / false, so the screen shows no warning it
/// can't back up.
abstract final class BackgroundStatus {
  /// The channel and its two methods; `ios/Runner/AppDelegate.swift` names
  /// the same strings (pinned by test/sentinel/ios_sentinel_screen_test.dart).
  static const channelName = 'app.bitbag/background';
  static const methodRefreshStatus = 'backgroundRefreshStatus';
  static const methodLowPowerMode = 'lowPowerMode';

  static const _channel = MethodChannel(channelName);

  static Future<BackgroundRefresh> refresh() async {
    if (SentinelService.isAlwaysOn) return BackgroundRefresh.available;
    try {
      final answer = await _channel.invokeMethod<String>(methodRefreshStatus);
      return switch (answer) {
        'available' => BackgroundRefresh.available,
        'denied' => BackgroundRefresh.denied,
        'restricted' => BackgroundRefresh.restricted,
        _ => BackgroundRefresh.unknown,
      };
    } catch (e) {
      debugPrint(
        '[BackgroundStatus] refresh status unreadable: '
        '${e.runtimeType}',
      );
      return BackgroundRefresh.unknown;
    }
  }

  static Future<bool> lowPowerMode() async {
    if (SentinelService.isAlwaysOn) return false;
    try {
      return await _channel.invokeMethod<bool>(methodLowPowerMode) ?? false;
    } catch (e) {
      debugPrint(
        '[BackgroundStatus] low power mode unreadable: '
        '${e.runtimeType}',
      );
      return false;
    }
  }
}
