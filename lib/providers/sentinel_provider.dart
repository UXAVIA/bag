import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../services/notification_service.dart';
import '../services/sentinel_service.dart';
import '../services/wallet/biometric_storage_service.dart';
import '../services/widget_service.dart';
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

    // Auto-disable if all wallets are removed while Sentinel is active. On
    // iOS also when only typed-in balances are left (R35): Sentinel Lite has
    // nothing to check then, and its screen says "Connect a wallet first".
    ref.listen(walletsProvider, (_, wallets) {
      final nothingToWatch = SentinelService.isAlwaysOn
          ? wallets.isEmpty
          : !wallets.any((w) => w.isWatchOnly);
      if (nothingToWatch && state is SentinelEnabled) {
        _doDisable();
      }
    });

    final initial = _readFromPrefs(prefs);
    // The balances are encrypted, so they arrive asynchronously: start
    // without them and fill them in once the read lands.
    if (initial is SentinelEnabled) {
      Future.microtask(() async {
        final balances = await _readBalances();
        final current = state;
        if (current is SentinelEnabled && current.lastBalances.isEmpty) {
          state = SentinelEnabled(
            lastScanAt: current.lastScanAt,
            lastBalances: balances,
          );
        }
      });
    }
    return initial;
  }

  /// The plaintext part of the state: the enabled flag and the last scan
  /// time. The per-wallet balances are not in prefs (see [_readBalances]).
  SentinelState _readFromPrefs(
    SharedPreferences prefs, {
    Map<String, int> lastBalances = const {},
  }) {
    final enabled = prefs.getBool(AppConstants.keySentinelEnabled) ?? false;
    if (!enabled) return const SentinelDisabled();

    final lastScanRaw = prefs.getString(AppConstants.keySentinelLastScan);
    final lastScanAt =
        lastScanRaw != null ? DateTime.tryParse(lastScanRaw) : null;

    return SentinelEnabled(lastScanAt: lastScanAt, lastBalances: lastBalances);
  }

  /// `sentinel_balances` (walletId → sats), which the Sentinel isolate writes
  /// to secure storage. `readSecureBlob` moves a pre-migration plaintext copy
  /// in if secure storage has none; one left beside a secure value is stale
  /// and is removed, so no plaintext copy survives a read. An unreadable or
  /// undecodable blob reads as no balances.
  Future<Map<String, int>> _readBalances() async {
    try {
      final raw = await readSecureBlob(AppConstants.keySentinelBalances);
      final prefs = ref.read(sharedPreferencesProvider);
      if (prefs.containsKey(AppConstants.keySentinelBalances)) {
        await prefs.remove(AppConstants.keySentinelBalances);
      }
      if (raw == null) return {};
      return Map<String, int>.from(jsonDecode(raw) as Map);
    } catch (e) {
      if (kDebugMode) debugPrint('[Sentinel] balances unreadable: ${e.runtimeType}');
      return {};
    }
  }

  /// Enable Sentinel. Caller should show the disclosure UI first.
  ///
  /// On Android this starts the foreground service. On iOS
  /// (`!SentinelService.isAlwaysOn`) there is none: it asks for notification
  /// permission (alerts are its only output), deletes any activity counts
  /// and last check time left from before, sets the flag, asks for the
  /// background refresh, which now has Sentinel Lite to run, and rescans
  /// every wallet so the watch map is built (spec D3). The rescan isn't
  /// awaited: over Tor it can take minutes, and each wallet writes its own
  /// entries as it finishes. If either delete throws, Sentinel Lite stays
  /// off and the error's type is logged (R34); nothing is thrown to the
  /// switch.
  Future<void> enable() async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (!(prefs.getBool(AppConstants.keyProUnlocked) ?? false)) return;

    if (!SentinelService.isAlwaysOn) {
      try {
        await NotificationService.requestPermission();
      } catch (e) {
        // Alerts may then not show; the Sentinel screen says so.
        debugPrint('[Sentinel] permission request failed: ${e.runtimeType}');
      }
      // Counts a background run wrote while Sentinel was being switched off
      // would otherwise be the baseline, and history since then would alert
      // (or be missed); start from first sight instead. An earlier run's
      // check time would read as this one's "Last checked" (R34).
      try {
        await deleteSecureBlob(AppConstants.keySentinelIosActivity);
        await prefs.remove(AppConstants.keySentinelLastScan);
      } catch (e) {
        debugPrint('[Sentinel] not turned on: earlier state not deleted '
            '(${e.runtimeType})');
        return;
      }
      await prefs.setBool(AppConstants.keySentinelEnabled, true);
      state = const SentinelEnabled();
      await WidgetService.iosBackgroundFollows();
      unawaited(ref.read(walletsProvider.notifier).scanAll());
      return;
    }

    await prefs.setBool(AppConstants.keySentinelEnabled, true);
    await SentinelService.start();
    state = const SentinelEnabled();
  }

  Future<void> disable() async {
    await _doDisable();
  }

  /// Never Pro-gated (R-B2g): a free user can always switch Sentinel off.
  ///
  /// On iOS this also deletes Sentinel Lite's activity counts
  /// (`sentinel_ios_activity`, best effort: a failure is logged by type and
  /// doesn't keep Sentinel on), removes its status from the widget (best
  /// effort too) and updates the background schedule, which
  /// is cancelled unless Tor still wants it. The watch map and seen records
  /// stay, as on Android.
  Future<void> _doDisable() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(AppConstants.keySentinelEnabled, false);
    if (!SentinelService.isAlwaysOn) {
      state = const SentinelDisabled();
      try {
        await deleteSecureBlob(AppConstants.keySentinelIosActivity);
      } catch (e) {
        debugPrint('[Sentinel] activity not deleted: ${e.runtimeType}');
      }
      // The widget stops saying it is watching (spec D11, R24). Best
      // effort, like the counts.
      try {
        await WidgetService.clearSentinelStatus();
      } catch (e) {
        debugPrint('[Sentinel] widget status not cleared: ${e.runtimeType}');
      }
      await WidgetService.iosBackgroundFollows();
      return;
    }
    await SentinelService.stop();
    state = const SentinelDisabled();
  }

  /// Re-reads the state the background isolate wrote: lastScanAt from
  /// prefs, lastBalances from secure storage. Call when app resumes from
  /// background.
  Future<void> syncFromPrefs() async {
    if (state is! SentinelEnabled) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final balances = await _readBalances();
    if (state is! SentinelEnabled) return;
    state = _readFromPrefs(prefs, lastBalances: balances);
  }
}
