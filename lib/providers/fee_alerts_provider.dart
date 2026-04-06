import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/constants/app_constants.dart';
import '../models/fee_alert.dart';
import 'shared_preferences_provider.dart';

final feeAlertsProvider =
    NotifierProvider<FeeAlertsNotifier, List<FeeAlert>>(FeeAlertsNotifier.new);

class FeeAlertsNotifier extends Notifier<List<FeeAlert>> {
  @override
  List<FeeAlert> build() {
    final raw =
        ref.read(sharedPreferencesProvider).getString(AppConstants.keyFeeAlerts);
    if (raw == null || raw.isEmpty) return [];
    try {
      return FeeAlert.listFromJsonString(raw);
    } catch (_) {
      return [];
    }
  }

  Future<void> add({
    required double targetRate,
    required bool above,
  }) async {
    final alert = FeeAlert(
      id: const Uuid().v4(),
      targetRate: targetRate,
      above: above,
    );
    state = [...state, alert];
    await _save();
  }

  Future<void> delete(String id) async {
    state = state.where((a) => a.id != id).toList();
    await _save();
  }

  Future<void> clearFired() async {
    state = state.where((a) => !a.fired).toList();
    await _save();
  }

  /// Mark a set of alerts as fired (called by feeProvider after foreground check).
  Future<void> markFired(List<String> ids) async {
    state = state
        .map((a) => ids.contains(a.id) ? a.copyWith(fired: true) : a)
        .toList();
    await _save();
  }

  /// Sync from SharedPreferences — called on app resume to pick up alerts
  /// fired by background services (WorkManager / Sentinel).
  Future<void> reload() async {
    final raw =
        ref.read(sharedPreferencesProvider).getString(AppConstants.keyFeeAlerts);
    if (raw == null || raw.isEmpty) {
      state = [];
      return;
    }
    try {
      state = FeeAlert.listFromJsonString(raw);
    } catch (_) {}
  }

  Future<void> _save() async {
    await ref
        .read(sharedPreferencesProvider)
        .setString(AppConstants.keyFeeAlerts, FeeAlert.listToJsonString(state));
  }
}
