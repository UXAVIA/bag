import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_constants.dart';
import '../models/fee_estimate.dart';
import '../services/fee_service.dart';
import '../services/notification_service.dart';
import '../services/tor_service.dart';
import '../services/widget_service.dart';
import 'fee_alerts_provider.dart';
import 'fee_settings_provider.dart';
import 'network_settings_provider.dart';
import 'purchase_provider.dart';
import 'shared_preferences_provider.dart';

final feeProvider =
    AsyncNotifierProvider<FeeNotifier, FeeEstimate?>(FeeNotifier.new);

class FeeNotifier extends AsyncNotifier<FeeEstimate?> {
  Timer? _timer;

  @override
  Future<FeeEstimate?> build() async {
    final proUnlocked = ref.watch(proUnlockedProvider);
    // Watch only the flags that gate polling — changes to `compact` (display-only)
    // won't tear down and recreate the timer.
    final showOnHome = ref.watch(feeSettingsProvider.select((s) => s.showOnHome));
    final showInWidget =
        ref.watch(feeSettingsProvider.select((s) => s.showInWidget));

    ref.onDispose(() => _timer?.cancel());

    if (!proUnlocked) return null;

    // Poll if the home section is visible, widget fee is enabled, OR there are active alerts.
    final alerts = ref.read(feeAlertsProvider);
    final hasActiveAlerts = alerts.any((a) => !a.fired);
    if (!showOnHome && !showInWidget && !hasActiveAlerts) return null;

    _startTimer();

    // Return cached value immediately while we fetch fresh data.
    final cached = FeeEstimate.fromJsonStringOrNull(
      ref.read(sharedPreferencesProvider).getString(AppConstants.keyFeeCache),
    );
    if (cached != null && !cached.isStale) return cached;

    return _fetch();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(AppConstants.feeRefreshInterval, (_) {
      ref.invalidateSelf();
    });
  }

  Future<FeeEstimate?> _fetch() async {
    final settings = ref.read(networkSettingsProvider);

    // Tor safety: perform a fresh TCP probe — do NOT rely on the cached
    // torStatusProvider value, which may be stale if Orbot went down after
    // the last probe. Never fall back to clearnet — that exposes the user's
    // IP to mempool.space.
    if (settings.useTor) {
      final torStatus = await TorService.probe();
      if (torStatus != TorStatus.available) {
        if (kDebugMode) {
          debugPrint('[FeeProvider] Tor required but unavailable — skipping fetch');
        }
        return null;
      }
    }

    final dio = buildFeeDio(settings.useTor);
    final estimate = await fetchFeeEstimate(dio);

    if (estimate != null) {
      // Cache to SharedPreferences so background services and cold starts
      // can use the last known value.
      await ref
          .read(sharedPreferencesProvider)
          .setString(AppConstants.keyFeeCache, estimate.toJsonString());

      // Push to widget if enabled.
      final settings = ref.read(feeSettingsProvider);
      if (settings.showInWidget) {
        WidgetService.updateFee(estimate).ignore();
      }

      // Check fee alerts in the foreground.
      await _checkForegroundAlerts(estimate.fast);
    }

    return estimate;
  }

  Future<void> _checkForegroundAlerts(double fastRate) async {
    final alerts = ref.read(feeAlertsProvider);
    final toFire = alerts.where((a) => a.shouldFire(fastRate)).toList();
    if (toFire.isEmpty) return;

    for (final alert in toFire) {
      final direction = alert.above ? 'risen above' : 'dropped to';
      await NotificationService.showFeeAlert(
        id: alert.id.hashCode,
        title: 'Network fee alert',
        body: 'Fees have $direction '
            '${alert.targetRate.toStringAsFixed(0)} sat/vB. '
            'Current fast rate: ${fastRate.toStringAsFixed(0)} sat/vB',
      );
    }

    await ref
        .read(feeAlertsProvider.notifier)
        .markFired(toFire.map((a) => a.id).toList());
  }

  Future<void> refresh() async {
    _timer?.cancel();
    ref.invalidateSelf();
  }
}
