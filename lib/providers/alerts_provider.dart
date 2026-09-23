import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/constants/app_constants.dart';
import '../models/price_alert.dart';
import 'shared_preferences_provider.dart';

final alertsProvider =
    NotifierProvider<AlertsNotifier, List<PriceAlert>>(AlertsNotifier.new);

class AlertsNotifier extends Notifier<List<PriceAlert>> {
  @override
  List<PriceAlert> build() {
    final raw = ref.read(sharedPreferencesProvider).getString(AppConstants.keyPriceAlerts);
    if (raw == null || raw.isEmpty) return [];
    try {
      return PriceAlert.listFromJsonString(raw);
    } catch (_) {
      return [];
    }
  }

  Future<void> add({
    required double targetPrice,
    required String currency,
    required bool above,
  }) async {
    final alert = PriceAlert(
      id: const Uuid().v4(),
      targetPrice: targetPrice,
      currency: currency,
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

  /// Called when the app resumes to sync any alerts fired in the background.
  Future<void> reload() async {
    final raw = ref.read(sharedPreferencesProvider).getString(AppConstants.keyPriceAlerts);
    if (raw == null || raw.isEmpty) {
      state = [];
      return;
    }
    try {
      state = PriceAlert.listFromJsonString(raw);
    } catch (_) {}
  }

  Future<void> _save() async {
    await ref
        .read(sharedPreferencesProvider)
        .setString(AppConstants.keyPriceAlerts, PriceAlert.listToJsonString(state));
  }
}
