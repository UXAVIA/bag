// Bitcoin Portfolio Health Check provider.
//
// On-demand only — triggered explicitly by the user, never automatically.
// Analyses ALL connected wallets together as a single portfolio — this catches
// cross-wallet privacy issues (address reuse, consolidation) that per-wallet
// checks miss.
//
// State machine:
//   idle        → never run, or previous result cleared
//   running     → fetch in progress; done/total show UTXO fetch progress
//   done        → analysis complete; result available
//   incomplete  → process was killed mid-run last time
//   error       → last run failed; message describes the cause

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chain_analysis.dart';
import '../models/network_settings.dart';
import '../services/tor_service.dart';
import '../services/wallet/biometric_storage_service.dart';
import '../services/wallet/chain_analysis_engine.dart';
import '../services/wallet/esplora_client.dart';
import '../services/wallet/wallet_engine.dart';
import '../services/wallet/wallet_store.dart';
import 'esplora_client_provider.dart';
import 'network_settings_provider.dart';
import 'shared_preferences_provider.dart';
import 'tor_status_provider.dart';
import 'wallets_provider.dart';

// ── State ─────────────────────────────────────────────────────────────────────

sealed class HealthCheckState {
  const HealthCheckState();
}

/// No result — never been run.
final class HealthCheckIdle extends HealthCheckState {
  const HealthCheckIdle();
}

/// The process was killed while a check was running. User can restart.
final class HealthCheckIncomplete extends HealthCheckState {
  const HealthCheckIncomplete();
}

/// Analysis is running. [done] and [total] track UTXO+tx fetch progress.
final class HealthCheckRunning extends HealthCheckState {
  final int done;
  final int total;
  const HealthCheckRunning({this.done = 0, this.total = 0});

  double get progress => total > 0 ? done / total : 0;
}

/// Analysis complete.
final class HealthCheckDone extends HealthCheckState {
  final ChainAnalysisResult result;
  const HealthCheckDone(this.result);
}

/// Last run failed.
final class HealthCheckError extends HealthCheckState {
  final String message;
  const HealthCheckError(this.message);
}

// ── Provider ──────────────────────────────────────────────────────────────────

final portfolioHealthCheckProvider =
    NotifierProvider<PortfolioHealthCheckNotifier, HealthCheckState>(
        PortfolioHealthCheckNotifier.new);

class PortfolioHealthCheckNotifier extends Notifier<HealthCheckState> {
  late SharedPreferences _prefs;

  static const _prefsKey = 'health_check_portfolio';
  static const _runningKey = 'health_check_portfolio_running';

  @override
  HealthCheckState build() {
    _prefs = ref.read(sharedPreferencesProvider);
    if (_prefs.getBool(_runningKey) ?? false) {
      return const HealthCheckIncomplete();
    }
    // The cached result lists every UTXO address and amount, so it is stored
    // encrypted and has to be decrypted asynchronously. Start idle and fill in
    // once it lands.
    Future.microtask(_restoreCachedResult);
    return const HealthCheckIdle();
  }

  Future<void> _restoreCachedResult() async {
    final json = await readSecureBlob(_prefsKey);
    if (json == null) return;
    // Don't clobber a check the user kicked off while we were decrypting.
    if (state is! HealthCheckIdle) return;
    try {
      state = HealthCheckDone(ChainAnalysisResult.fromJsonString(json));
    } catch (e) {
      if (kDebugMode) debugPrint('[HealthCheck] failed to parse cached result: $e');
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Starts a fresh Bitcoin Health Check for all wallets.
  /// No-ops if a check is already running.
  Future<void> run() async {
    if (state is HealthCheckRunning) return;
    await _prefs.setBool(_runningKey, true);
    state = const HealthCheckRunning();
    try {
      final result = await _runAnalysis();
      await writeSecureBlob(_prefsKey, result.toJsonString());
      await _prefs.remove(_runningKey);
      state = HealthCheckDone(result);
    } catch (e) {
      if (kDebugMode) debugPrint('[HealthCheck] analysis failed: $e');
      await _prefs.remove(_runningKey);
      final message = switch (e) {
        _HealthCheckException(:final message) => message,
        EsploraException(:final message) => message,
        _ => 'Analysis failed — check your connection and try again',
      };
      state = HealthCheckError(message);
    }
  }

  /// Clears the cached result and resets to idle.
  Future<void> clear() async {
    await deleteSecureBlob(_prefsKey);
    await _prefs.remove(_runningKey);
    state = const HealthCheckIdle();
  }

  // ── Analysis pipeline ──────────────────────────────────────────────────────

  Future<ChainAnalysisResult> _runAnalysis() async {
    // Manual entries (exchange balances) have no addresses — they are
    // deliberately invisible to on-chain analysis.
    final wallets =
        ref.read(walletsProvider).where((w) => w.isWatchOnly).toList();
    if (wallets.isEmpty) {
      throw _HealthCheckException(
          'No watch-only wallets connected — add a zpub or descriptor first');
    }

    // ── 1. Derive all addresses across all wallets ───────────────────────────
    final addresses = <String>[];
    for (final entry in wallets) {
      final secret = await readWalletSecretForScanningById(entry.id);
      if (secret == null) continue;

      final AddressSource source;
      try {
        source = buildAddressSource(entry.kind, secret);
      } on ZpubException catch (e) {
        throw _HealthCheckException(
            'Invalid key for "${entry.label}": ${e.message}');
      } on DescriptorException catch (e) {
        throw _HealthCheckException(
            'Invalid descriptor for "${entry.label}": ${e.message}');
      }

      for (final (chain, lastIndex) in [
        (0, entry.lastExternalIndex),
        (1, entry.lastChangeIndex),
      ]) {
        if (!source.hasChain(chain)) continue;
        for (var i = 0; i <= lastIndex; i++) {
          try {
            addresses.add(source.addressAt(chain, i));
          } on Bip32InvalidChildException {
            // BIP32 §4: skip an invalid child index.
          }
        }
      }
    }

    if (addresses.isEmpty) {
      throw _HealthCheckException(
          'No addresses to analyse — run a wallet scan on each wallet first');
    }

    // ── Tor pre-flight ────────────────────────────────────────────────────────
    final settings = ref.read(networkSettingsProvider);
    if (settings.useTor) {
      final torStatus = await TorService.probe();
      if (torStatus != TorStatus.available) {
        throw _HealthCheckException(
          'Tor is enabled but Orbot is not running. '
          'Start Orbot and try again.',
        );
      }
      ref.read(torStatusProvider.notifier).setValue(torStatus);
    }

    final concurrency = settings.useTor ? 2 : 4;
    final client = ref.read(esploraClientProvider);
    if (kDebugMode) {
      debugPrint(
          '[HealthCheck] baseUrl=${client.baseUrl} useTor=${client.useTor} '
          'wallets=${wallets.length} addresses=${addresses.length}');
    }

    var total = addresses.length;
    var done = 0;
    void tick() {
      done += 1;
      state = HealthCheckRunning(done: done, total: total);
    }

    // ── 2. Fetch UTXOs per address ────────────────────────────────────────────
    final utxosByAddress = <String, List<RawUtxo>>{};
    await _batched(addresses, concurrency: concurrency, task: (address) async {
      final utxos = await client.fetchUtxos(address);
      if (utxos.isNotEmpty) utxosByAddress[address] = utxos;
      tick();
    });

    // ── 3. Fetch funding transactions (deduplicated) ──────────────────────────
    final uniqueTxids = {
      for (final utxos in utxosByAddress.values)
        for (final u in utxos) u.txid,
    }.toList();

    total = done + uniqueTxids.length;
    state = HealthCheckRunning(done: done, total: total);

    final txMap = <String, RawTransaction>{};
    await _batched(uniqueTxids, concurrency: concurrency, task: (txid) async {
      final tx = await client.fetchTransaction(txid);
      txMap[txid] = tx;
      tick();
    });

    // ── 4. Analyse ────────────────────────────────────────────────────────────
    final torEnabled = settings.useTor;
    final customExplorerEnabled =
        settings.preset == ExplorerPreset.custom &&
            settings.customUrl.isNotEmpty;

    return analyse(
      walletCount: wallets.length,
      utxosByAddress: utxosByAddress,
      txMap: txMap,
      torEnabled: torEnabled,
      customExplorerEnabled: customExplorerEnabled,
    );
  }

  Future<void> _batched<T>(
    List<T> items, {
    required int concurrency,
    required Future<void> Function(T item) task,
  }) async {
    for (var i = 0; i < items.length; i += concurrency) {
      final batch = items.sublist(i, min(i + concurrency, items.length));
      await Future.wait(batch.map(task));
    }
  }
}

final class _HealthCheckException implements Exception {
  final String message;
  const _HealthCheckException(this.message);
}
