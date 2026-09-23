import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../services/sentinel_service.dart';
import 'purchase_provider.dart';
import 'shared_preferences_provider.dart';
import 'wallets_provider.dart';

// ── State ─────────────────────────────────────────────────────────────────────

sealed class SentinelState {
  const SentinelState();
}

final class SentinelDisabled extends SentinelState {
  const SentinelDisabled();
}

final class SentinelEnabled extends SentinelState {
  final DateTime? lastScanAt;
  // walletId → last known sats, written by the background isolate.
  final Map<String, int> lastBalances;

  const SentinelEnabled({this.lastScanAt, this.lastBalances = const {}});
}

// ── Provider ──────────────────────────────────────────────────────────────────

final sentinelProvider =
    NotifierProvider<SentinelNotifier, SentinelState>(SentinelNotifier.new);

class SentinelNotifier extends Notifier<SentinelState> {
  @override
  SentinelState build() {
    final prefs = ref.read(sharedPreferencesProvider);

    // Auto-disable if Pro is revoked while app is open.
    ref.listen(proUnlockedProvider, (_, unlocked) {
      if (!unlocked && state is SentinelEnabled) {
        _doDisable();
      }
    });

    // Auto-disable if all wallets are removed while Sentinel is active.
    ref.listen(walletsProvider, (_, wallets) {
      if (wallets.isEmpty && state is SentinelEnabled) {
        _doDisable();
      }
    });

    return _readFromPrefs(prefs);
  }

  SentinelState _readFromPrefs(dynamic prefs) {
    final enabled = prefs.getBool(AppConstants.keySentinelEnabled) ?? false;
    if (!enabled) return const SentinelDisabled();

    final lastScanRaw = prefs.getString(AppConstants.keySentinelLastScan);
    final lastScanAt =
        lastScanRaw != null ? DateTime.tryParse(lastScanRaw) : null;

    final balancesRaw = prefs.getString(AppConstants.keySentinelBalances);
    final lastBalances = balancesRaw != null
        ? Map<String, int>.from(jsonDecode(balancesRaw) as Map)
        : <String, int>{};

    return SentinelEnabled(lastScanAt: lastScanAt, lastBalances: lastBalances);
  }

  /// Enable Sentinel. Caller should show the disclosure UI first.
  Future<void> enable() async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (!(prefs.getBool(AppConstants.keyProUnlocked) ?? false)) return;

    await prefs.setBool(AppConstants.keySentinelEnabled, true);
    await SentinelService.start();
    state = const SentinelEnabled();
  }

  Future<void> disable() async {
    await _doDisable();
  }

  Future<void> _doDisable() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(AppConstants.keySentinelEnabled, false);
    await SentinelService.stop();
    state = const SentinelDisabled();
  }

  /// Re-reads SharedPreferences state written by the background isolate
  /// (lastScanAt, lastBalances). Call when app resumes from background.
  Future<void> syncFromPrefs() async {
    if (state is! SentinelEnabled) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    state = _readFromPrefs(prefs);
  }
}
