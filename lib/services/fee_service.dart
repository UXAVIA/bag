// Fee estimation service — fetches current sat/vB rates from the selected
// explorer (a mempool backend or a plain Esplora).
//
// Security design (mirrors esplora_client.dart):
// - The Dio for [fetchFeeEstimate] (`buildRoutedJsonDio`) MUST be built
//   with the user's selected NetworkRoute, and the explorer base URL
//   resolved for that same route. Never pass a clearnet Dio when Tor or a
//   proxy is selected — that exposes the user's IP to the explorer against
//   their explicit privacy choice.
// - Callers in background isolates (WorkManager, Sentinel) are responsible for
//   verifying the route is available before building the Dio.
// - This file has NO Riverpod dependency so it is safe to import from any isolate.

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../models/fee_alert.dart';
import '../models/fee_estimate.dart';

/// Fetch the current fee estimates from the explorer at [explorerBase] (the
/// selected explorer's base URL on the route [dio] was built for).
///
/// A mempool backend (mempool.space, its onion, a self-hosted mempool)
/// answers `/v1/fees/recommended`; a plain Esplora (blockstream.info,
/// electrs) answers `/fee-estimates`, a confirmation target → sat/vB map,
/// read as 1 / 3 / 6 blocks. The first is tried, then the second (and both
/// again under `/api` for a base without it), except for blockstream.info,
/// which has only the second. A request that never got a
/// response (refused, timed out, cancelled, the route changed) ends the
/// fetch: the other endpoint is on the same server and route.
///
/// Returns null on any error. The caller decides how to handle a null
/// result — do NOT silently fall back to clearnet if a private route is
/// selected.
Future<FeeEstimate?> fetchFeeEstimate(
  Dio dio, {
  required String explorerBase,
  CancelToken? cancelToken,
}) async {
  final base = explorerBase.endsWith('/')
      ? explorerBase.substring(0, explorerBase.length - 1)
      : explorerBase;
  // A saved custom URL has its `/api` stripped (checkCustomExplorerUrl),
  // and a self-hosted mempool serves its API under `/api`, so a custom
  // base is also tried with it.
  final bases = [base, if (!base.endsWith('/api')) '$base/api'];
  final candidates = base == AppConstants.explorerBlockstream
      ? [('$base/fee-estimates', _parseEsploraEstimates)]
      : [
          for (final b in bases) ...[
            ('$b/v1/fees/recommended', _parseRecommended),
            ('$b/fee-estimates', _parseEsploraEstimates),
          ],
        ];
  for (final (url, parse) in candidates) {
    final (fee, reached) = await _feeFrom(dio, url, parse, cancelToken);
    if (fee != null || !reached) return fee;
  }
  return null;
}

/// One fee request. `reached` is false when no response came back at all,
/// so the caller tries no other endpoint.
Future<(FeeEstimate?, bool reached)> _feeFrom(
  Dio dio,
  String url,
  FeeEstimate? Function(Object? data) parse,
  CancelToken? cancelToken,
) async {
  try {
    final response = await dio.get<Object?>(url, cancelToken: cancelToken);
    return (parse(response.data), true);
  } on DioException catch (e) {
    if (kDebugMode) debugPrint('[FeeService] fetch failed: ${e.type}');
    return (null, e.type == DioExceptionType.badResponse);
  } catch (e) {
    if (kDebugMode) debugPrint('[FeeService] fetch failed: ${e.runtimeType}');
    return (null, true);
  }
}

/// A rate a server may plausibly report: finite, not negative, and below
/// 100,000 sat/vB (the highest ever seen is in the thousands). Anything else
/// would fire every fee alert at once, or fail to cache (`jsonEncode`
/// refuses infinity).
bool _plausibleRate(Object? v) =>
    v is num && v.isFinite && v >= 0 && v < 100000;

FeeEstimate? _parseRecommended(Object? data) {
  if (data is! Map) return null;
  final fast = data['fastestFee'], standard = data['halfHourFee'];
  final slow = data['hourFee'];
  if (!_plausibleRate(fast) ||
      !_plausibleRate(standard) ||
      !_plausibleRate(slow)) {
    return null;
  }
  return FeeEstimate(
    fast: (fast as num).toDouble(),
    standard: (standard as num).toDouble(),
    slow: (slow as num).toDouble(),
    fetchedAt: DateTime.now(),
  );
}

FeeEstimate? _parseEsploraEstimates(Object? data) {
  if (data is! Map) return null;
  final byTarget = <int, double>{};
  data.forEach((k, v) {
    final target = int.tryParse('$k');
    if (target != null && target > 0 && _plausibleRate(v)) {
      byTarget[target] = (v as num).toDouble();
    }
  });
  if (byTarget.isEmpty) return null;
  final targets = byTarget.keys.toList()..sort();
  // The rate for [blocks], or for the next larger target the server lists.
  double? at(int blocks) {
    for (final t in targets) {
      if (t >= blocks) return byTarget[t];
    }
    return null;
  }

  final fast = at(1), standard = at(3), slow = at(6);
  if (fast == null || standard == null || slow == null) return null;
  return FeeEstimate(
    fast: fast,
    standard: standard,
    slow: slow,
    fetchedAt: DateTime.now(),
  );
}

/// A fee rate for display, without "sat/vB": whole numbers from 10 up, one
/// decimal below (an Esplora estimate can be 1.19 or 0.13 sat/vB), and no
/// trailing ".0".
String formatFeeRate(double rate) {
  if (rate >= 10) return rate.toStringAsFixed(0);
  final s = rate.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// Check stored fee alerts against [fastRate], fire notifications for any
/// that trigger, and persist the updated (fired) state to [prefs].
///
/// Intended for background isolates (WorkManager, Sentinel). The notification
/// plugin is initialised inline because background isolates have a separate
/// Flutter engine and the app-level initialisation is not available.
Future<void> checkFeeAlerts(
    SharedPreferences prefs, double fastRate) async {
  final raw = prefs.getString(AppConstants.keyFeeAlerts);
  if (raw == null || raw.isEmpty) return;

  List<FeeAlert> alerts;
  try {
    alerts = FeeAlert.listFromJsonString(raw);
  } catch (_) {
    return;
  }

  final toFire =
      alerts.where((a) => a.shouldFire(fastRate)).toList();
  if (toFire.isEmpty) return;

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    ),
  );

  var notifId = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  for (final alert in toFire) {
    final direction = alert.above ? 'risen above' : 'dropped to';
    await plugin.show(
      notifId++,
      'Network fee alert',
      'Fees have $direction ${alert.targetRate.toStringAsFixed(0)} sat/vB. '
          'Current fast rate: ${formatFeeRate(fastRate)} sat/vB',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          AppConstants.notifChannelIdFeeAlerts,
          AppConstants.notifChannelNameFeeAlerts,
          channelDescription: AppConstants.notifChannelDescFeeAlerts,
          importance: Importance.high,
          priority: Priority.high,
          visibility: NotificationVisibility.secret,
          icon: 'ic_notification',
        ),
      ),
    );
    if (kDebugMode) {
      debugPrint(
          '[FeeService] fired alert ${alert.id}: fees ${alert.above ? '>=' : '<='} ${alert.targetRate}');
    }
  }

  // Mark fired alerts so the app UI reflects the state on next open.
  final updated = alerts
      .map((a) =>
          toFire.any((f) => f.id == a.id) ? a.copyWith(fired: true) : a)
      .toList();
  await prefs.setString(
      AppConstants.keyFeeAlerts, FeeAlert.listToJsonString(updated));
}
