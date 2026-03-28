// Fee estimation service — fetches current sat/vB rates from mempool.space.
//
// Security design (mirrors esplora_client.dart):
// - If the user has Tor enabled, [buildFeeDio] MUST be called with useTor=true.
//   Never pass a clearnet Dio when Tor is enabled — that exposes the user's IP
//   to mempool.space against their explicit privacy choice.
// - Callers in background isolates (WorkManager, Sentinel) are responsible for
//   verifying Tor availability before building the Dio.
// - This file has NO Riverpod dependency so it is safe to import from any isolate.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socks5_proxy/socks.dart';

import '../core/constants/app_constants.dart';
import '../models/fee_alert.dart';
import '../models/fee_estimate.dart';

/// Build a [Dio] configured for fee requests.
///
/// When [useTor] is true the client routes all traffic through the local
/// Orbot SOCKS5 proxy (127.0.0.1:9050). Timeouts are raised to 60 s to
/// accommodate Tor circuit establishment latency.
///
/// MUST be called with [useTor] = true whenever `keyUseTor` is enabled in
/// SharedPreferences. No clearnet fallback — that is a privacy leak.
Dio buildFeeDio(bool useTor) {
  final timeout =
      useTor ? const Duration(seconds: 60) : const Duration(seconds: 20);

  final dio = Dio(BaseOptions(
    connectTimeout: timeout,
    receiveTimeout: timeout,
    headers: {'Accept': 'application/json'},
  ));

  if (useTor) {
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        SocksTCPClient.assignToHttpClient(client, [
          ProxySettings(
            InternetAddress(AppConstants.torHost),
            AppConstants.torPort,
          ),
        ]);
        return client;
      },
    );
  }

  return dio;
}

/// Fetch the current fee estimates using the provided [dio].
///
/// Returns null on any error (network, parse, Tor circuit failure).
/// The caller decides how to handle a null result — do NOT silently fall
/// back to clearnet if Tor is enabled.
Future<FeeEstimate?> fetchFeeEstimate(Dio dio) async {
  try {
    final response =
        await dio.get<Map<String, dynamic>>(AppConstants.mempoolFeesUrl);
    final data = response.data!;
    return FeeEstimate(
      fast: (data['fastestFee'] as num).toDouble(),
      standard: (data['halfHourFee'] as num).toDouble(),
      slow: (data['hourFee'] as num).toDouble(),
      fetchedAt: DateTime.now(),
    );
  } catch (e) {
    if (kDebugMode) debugPrint('[FeeService] fetch failed: $e');
    return null;
  }
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
          'Current fast rate: ${fastRate.toStringAsFixed(0)} sat/vB',
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
