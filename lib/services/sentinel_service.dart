import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart'
    hide NotificationVisibility;
// Import fft's NotificationVisibility under a prefix to avoid conflict with
// flutter_local_notifications' NotificationVisibility (same name, different members).
import 'package:flutter_foreground_task/flutter_foreground_task.dart' as fft
    show NotificationVisibility;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../models/network_route.dart';
import '../models/wallet_entry.dart';
import 'embedded_tor_service.dart';
import 'fee_service.dart';
import 'network/network_route_store.dart';
import 'network/route_gate.dart';
import 'network/routed_http.dart';
import 'tor_host.dart';
import 'wallet/biometric_storage_service.dart' as bio;
import 'wallet/esplora_client.dart';
import 'wallet/tx_effect.dart';
import 'wallet/wallet_engine.dart';
import 'wallet/wallet_scanner.dart';
import 'wallet/wallet_store.dart';

// ── Background entry point ────────────────────────────────────────────────────

@pragma('vm:entry-point')
void sentinelStartCallback() {
  FlutterForegroundTask.setTaskHandler(SentinelTaskHandler());
}

// ── Seen-tx record ────────────────────────────────────────────────────────────

class _SeenTx {
  final String walletId;
  final String walletLabel;
  final String dir; // 'in' | 'out'
  final int sats;
  final DateTime seenAt;
  final int notifId;
  final bool confirmedAlerted;

  const _SeenTx({
    required this.walletId,
    required this.walletLabel,
    required this.dir,
    required this.sats,
    required this.seenAt,
    required this.notifId,
    this.confirmedAlerted = false,
  });

  _SeenTx copyWith({bool? confirmedAlerted}) => _SeenTx(
        walletId: walletId,
        walletLabel: walletLabel,
        dir: dir,
        sats: sats,
        seenAt: seenAt,
        notifId: notifId,
        confirmedAlerted: confirmedAlerted ?? this.confirmedAlerted,
      );

  Map<String, dynamic> toJson() => {
        'wid': walletId,
        'wlabel': walletLabel,
        'dir': dir,
        'sats': sats,
        'seenAt': seenAt.toIso8601String(),
        'nid': notifId,
        'conf': confirmedAlerted,
      };

  factory _SeenTx.fromJson(Map<String, dynamic> j) => _SeenTx(
        walletId: j['wid'] as String,
        walletLabel: j['wlabel'] as String,
        dir: j['dir'] as String,
        sats: j['sats'] as int,
        seenAt: DateTime.parse(j['seenAt'] as String),
        notifId: j['nid'] as int,
        confirmedAlerted: j['conf'] as bool? ?? false,
      );
}

// ── Watch-map entry ───────────────────────────────────────────────────────────

class _WatchEntry {
  final String walletId;
  final String walletLabel;

  const _WatchEntry({required this.walletId, required this.walletLabel});

  Map<String, dynamic> toJson() => {'wid': walletId, 'wlabel': walletLabel};

  factory _WatchEntry.fromJson(Map<String, dynamic> j) => _WatchEntry(
        walletId: j['wid'] as String,
        walletLabel: j['wlabel'] as String,
      );
}

// ── Task handler ──────────────────────────────────────────────────────────────

class SentinelTaskHandler extends TaskHandler {
  int _tickCount = 0;
  bool _scanning = false;
  DateTime? _routeUnavailableSince;
  final _notifPlugin = FlutterLocalNotificationsPlugin();
  bool _notifInitialized = false;
  static final _trailingZeros = RegExp(r'0+$');
  static final _trailingDot = RegExp(r'\.$');

  // Cached EsploraClient — reused across ticks to keep TCP connection pools alive.
  // Rebuilt only when the explorer URL or the network route changes.
  EsploraClient? _cachedClient;
  String? _cachedBaseUrl;
  NetworkRoute? _cachedRoute;

  /// Sentinel's lease on the process's one Tor client (TorHost) while the
  /// route is Tor: its own client, or the one the app or a WorkManager job
  /// runs. Connections never use the lease's port; they go through
  /// `routeHttpClient`, which asks `TorHost.port()` per connection.
  TorHostLease? _torLease;

  /// Lease changes run one at a time: each tick's and onDestroy's.
  Future<void> _torChain = Future<void>.value();

  bool _destroyed = false;

  /// The last full scan found watch-only wallets. Mempool ticks keep the
  /// lease only then (Ruling 2).
  bool _hadWallets = false;

  /// The tick ([_tickCount]) on which Sentinel first saw its Tor client
  /// failed; null while it isn't. A failed client backs off from it.
  int? _torFailedAt;

  /// A private route was down on a tick, so the next tick that runs is a
  /// full scan: once the route is back, the watch map and balances are
  /// rebuilt rather than only the mempool checked.
  bool _fullScanDue = false;

  /// The tick in progress, or the last one.
  Future<void> _tick = Future<void>.value();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    if (kDebugMode) debugPrint('[Sentinel] service started');
    await _notifPlugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    ));
    _notifInitialized = true;
    // With Tor, the scan takes Sentinel's lease (_routeForTick).
    await _runFullScan();
  }

  /// Test seam: the tick [onRepeatEvent] started, which it doesn't return.
  @visibleForTesting
  Future<void> get debugTick => _tick;

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_scanning) {
      if (kDebugMode) debugPrint('[Sentinel] scan in progress, skipping');
      return;
    }
    _scanning = true;
    _tickCount++;
    final runFull = _fullScanDue ||
        _tickCount % AppConstants.sentinelFullScanEveryNTicks == 0;
    _tick = (runFull ? _runFullScan() : _runMempoolOnly())
        .catchError((Object e, StackTrace st) {
          if (kDebugMode) debugPrint('[Sentinel] unhandled error: $e\n$st');
        })
        .whenComplete(() => _scanning = false);
  }

  /// flutter_foreground_task waits for this before it destroys the engine,
  /// so the Tor lease is given back here: a client this isolate runs must
  /// stop before its isolate goes (R-A2a). Bounded by
  /// [sentinelTorReleaseBudget]: the stop is issued at the start of the
  /// release, and a mapping left behind is taken over after
  /// [TorHost.lookupTimeout]. A client left behind anyway (the engine went
  /// first) is stopped by the next TorHost sweep (Task A2c, which closes
  /// R-A2e); with the fork's eager stop (Task A2b) the native stop is not
  /// queued behind another plugin call.
  @override
  Future<void> onDestroy(DateTime timestamp) async {
    if (kDebugMode) debugPrint('[Sentinel] service destroyed');
    _destroyed = true;
    _torFailedAt = null;
    try {
      await _onTorChain(_releaseTor).timeout(sentinelTorReleaseBudget);
    } on TimeoutException {
      if (kDebugMode) debugPrint('[Sentinel] Tor lease not given back yet');
    }
  }

  // ── Full scan (~10 min) ──────────────────────────────────────────────────────

  Future<void> _runFullScan() async {
    final prefs = await reloadedPrefs();

    if (!_proCheck(prefs)) return;
    // Local reads first: Sentinel holds Tor only while it has wallets to
    // watch (Ruling 2).
    final wallets = await _loadWatchOnlyWallets();
    _hadWallets = wallets != null;
    final route = await _routeForTick(prefs, want: wallets != null);
    if (wallets == null) {
      // Nothing left to watch: the addresses and pending txids of wallets
      // that are gone are not kept, or queried again (N1).
      await bio.deleteSecureBlob(AppConstants.keySentinelWatchMap);
      await bio.deleteSecureBlob(AppConstants.keySentinelSeenTxids);
      await bio.deleteSecureBlob(AppConstants.keySentinelBalances);
      return;
    }
    final client = await _getOrBuildClient(route);
    if (!await _routePreflight(route)) return;
    _fullScanDue = false;

    final lastKnown = await _loadBalances();
    final watchMap = <String, _WatchEntry>{};
    final balanceChanges = <String, int>{}; // walletId → delta sats

    var scanned = 0;
    for (final wallet in wallets) {
      if (!await _stillOnRoute(route)) return;
      try {
        final secret = await bio.readWalletSecretForScanningById(wallet.id);
        if (secret == null) continue;
        final source = buildAddressSource(wallet.kind, secret);
        final balance = await scanWallet(source, client);
        scanned++;

        // Collect UTXO addresses for the watch map.
        for (final addr in balance.utxoAddresses) {
          watchMap[addr] =
              _WatchEntry(walletId: wallet.id, walletLabel: wallet.label);
        }
        // Frontier addresses: the next few unused receive addresses (so an
        // incoming payment is seen) and the next few unused change addresses
        // (so a spend's change output is recognised as ours and netted out
        // of the reported amount — see mempoolNetEffect).
        for (final (chain, next) in [
          (0, balance.nextExternalIndex),
          (1, balance.nextChangeIndex),
        ]) {
          if (!source.hasChain(chain)) continue;
          for (var i = 0; i < AppConstants.sentinelFrontierCount; i++) {
            try {
              final addr = source.addressAt(chain, next + i);
              watchMap[addr] =
                  _WatchEntry(walletId: wallet.id, walletLabel: wallet.label);
            } on Bip32InvalidChildException {
              // BIP32 §4: skip an invalid child index.
            }
          }
        }

        final current = balance.totalSats;
        final previous = lastKnown[wallet.id];
        if (previous != null && current != previous) {
          balanceChanges[wallet.id] = current - previous;
        }
        lastKnown[wallet.id] = current;
      } on EsploraException catch (e) {
        // Never log the wallet label — Logcat is readable by anyone with adb.
        if (kDebugMode) debugPrint('[Sentinel] scan failed: $e');
      } catch (e) {
        if (kDebugMode) debugPrint('[Sentinel] scan error: $e');
      }
    }

    // No wallet scanned (the explorer failed for every one): the last watch
    // map stays, and nothing claims a scan that didn't happen (M8).
    if (scanned == 0) {
      if (kDebugMode) debugPrint('[Sentinel] no wallet scanned; map kept');
      return;
    }
    if (!await _stillOnRoute(route)) return;

    // Persist the updated watch map for mempool-only ticks.
    await _saveWatchMap(watchMap);

    // Load seenTxids once — threaded through mempool check and confirmation pass.
    final seenTxids = await _loadSeenTxids();

    // Run mempool check — mutates seenTxids in-place, returns current txids.
    final (currentMempoolTxids, mempoolUpdated, mempoolStopped) =
        await _checkMempool(
      client: client,
      route: route,
      watchMap: watchMap,
      seenTxids: seenTxids,
    );
    if (mempoolStopped) {
      // Alerts already shown are remembered, or the next tick shows them
      // again; nothing else is written.
      if (mempoolUpdated) await _saveSeenTxids(seenTxids);
      return;
    }

    // Confirmation pass: fire "confirmed" alerts for seenTxids that left mempool.
    bool confirmUpdated = false;

    for (final entry in seenTxids.entries.toList()) {
      final txid = entry.key;
      final seen = entry.value;

      if (currentMempoolTxids.contains(txid)) continue; // still pending
      if (seen.confirmedAlerted) continue; // already notified

      // Check if the wallet had a balance change matching direction.
      final delta = balanceChanges[seen.walletId];
      final matches =
          (delta != null && delta > 0 && seen.dir == 'in') ||
          (delta != null && delta < 0 && seen.dir == 'out');

      if (matches) {
        await _fireConfirmedAlert(seen.walletLabel, seen.dir == 'in',
            seen.sats, seen.notifId);
        seenTxids[txid] = seen.copyWith(confirmedAlerted: true);
        confirmUpdated = true;
        // Mark this wallet's balance change as handled by a confirmation alert.
        balanceChanges.remove(seen.walletId);
      }
    }

    final cleaned = _cleanupSeenTxids(seenTxids);
    if (mempoolUpdated || confirmUpdated || cleaned) {
      await _saveSeenTxids(seenTxids);
    }

    // Fire balance-changed alerts for wallets whose change wasn't covered by
    // a confirmation alert (missed mempool phase or direct on-chain change).
    for (final entry in balanceChanges.entries) {
      final wallet =
          wallets.firstWhere((w) => w.id == entry.key, orElse: () => wallets.first);
      await _fireBalanceChanged(wallet, entry.value);
    }

    // Fee alerts.
    if (!await _stillOnRoute(route)) return;
    final feeAlertsRaw = prefs.getString(AppConstants.keyFeeAlerts);
    if (feeAlertsRaw != null && feeAlertsRaw.isNotEmpty) {
      try {
        final feeDio = buildRoutedJsonDio(route);
        final estimate = await fetchFeeEstimate(feeDio,
            explorerBase: await resolveExplorerBaseUrl(route));
        if (estimate != null) {
          await prefs.setString(
              AppConstants.keyFeeCache, estimate.toJsonString());
          await checkFeeAlerts(prefs, estimate.fast);
          if (kDebugMode) debugPrint('[Sentinel] fee estimate: ${estimate.fast} sat/vB');
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[Sentinel] fee fetch failed: $e');
      }
    }

    if (!await _stillOnRoute(route)) return;
    // Only wallets that still exist, read again now (net R-3): a removal
    // whose purge ran while this scan held the removed wallet's balance, or
    // an entry an earlier scan wrote back the same way, is dropped here.
    final stillStored = {
      for (final w in await loadWalletsFromStorage())
        if (w.isWatchOnly) w.id,
    };
    lastKnown.removeWhere((id, _) => !stillStored.contains(id));
    if (lastKnown.isEmpty) {
      await bio.deleteSecureBlob(AppConstants.keySentinelBalances);
    } else {
      await bio.writeSecureBlob(
          AppConstants.keySentinelBalances, jsonEncode(lastKnown));
    }
    final now = DateTime.now();
    await prefs.setString(
        AppConstants.keySentinelLastScan, now.toIso8601String());
    _updateNotification('Wallets & mempool · ${DateFormat('HH:mm').format(now)}');
    if (kDebugMode) debugPrint('[Sentinel] full scan complete');
  }

  // ── Mempool-only scan (every 2 min) ─────────────────────────────────────────

  Future<void> _runMempoolOnly() async {
    final prefs = await reloadedPrefs();

    if (!_proCheck(prefs)) return;
    // The lease stays while the last full scan had wallets; an empty map
    // never takes one (Ruling 2).
    final watchMap = await _loadWatchMap();
    final route = await _routeForTick(
      prefs,
      want: _hadWallets && (watchMap.isNotEmpty || _torLease != null),
    );
    // Without wallets behind it a stored map is not watched (N1).
    if (!_hadWallets) return;
    if (watchMap.isEmpty) {
      if (kDebugMode) debugPrint('[Sentinel] mempool check: watch map empty, skipping');
      return;
    }
    final client = await _getOrBuildClient(route);
    if (!await _routePreflight(route)) return;

    final seenTxids = await _loadSeenTxids();
    final (_, mempoolUpdated, stopped) = await _checkMempool(
        client: client, route: route, watchMap: watchMap, seenTxids: seenTxids);
    // Cleanup (24 h TTL) runs on full scans only — no need every 2 min.
    if (mempoolUpdated) await _saveSeenTxids(seenTxids);
    if (stopped) return;

    final now = DateTime.now();
    await prefs.setString(
        AppConstants.keySentinelLastScan, now.toIso8601String());
    _updateNotification('Mempool checked · ${DateFormat('HH:mm').format(now)}');
    if (kDebugMode) debugPrint('[Sentinel] mempool check complete');
  }

  // ── Mempool check (shared) ───────────────────────────────────────────────────

  /// Fetches mempool txs for each watched address, fires alerts for new
  /// unconfirmed transactions, and returns the set of currently-pending txids
  /// plus a flag indicating whether [seenTxids] was modified.
  /// [seenTxids] is mutated in-place; caller is responsible for persisting it.
  ///
  /// The route is read again before each address (R-6): once it is no
  /// longer [route] no further address is queried, and the third value
  /// says the check stopped there.
  Future<(Set<String>, bool, bool)> _checkMempool({
    required EsploraClient client,
    required NetworkRoute route,
    required Map<String, _WatchEntry> watchMap,
    required Map<String, _SeenTx> seenTxids,
  }) async {
    if (watchMap.isEmpty) return (<String>{}, false, false);

    // seenTxids is passed in (already loaded by caller) — no redundant jsonDecode.
    final currentTxids = <String>{};
    bool seenUpdated = false;

    // Every watched address of each wallet, so a transaction's effect can be
    // netted wallet-wide (inputs spent vs. change/receive outputs) instead of
    // judged from the single address that happened to surface it.
    final walletAddresses = <String, Set<String>>{};
    for (final e in watchMap.entries) {
      walletAddresses.putIfAbsent(e.value.walletId, () => {}).add(e.key);
    }

    for (final mapEntry in watchMap.entries) {
      final address = mapEntry.key;
      final watchEntry = mapEntry.value;
      if (!await _stillOnRoute(route)) return (currentTxids, seenUpdated, true);

      List<MempoolTx> txs;
      try {
        txs = await client.fetchMempoolTxs(address);
      } on EsploraException catch (e) {
        if (kDebugMode) debugPrint('[Sentinel] mempool fetch error: $e');
        continue;
      } catch (e) {
        if (kDebugMode) debugPrint('[Sentinel] mempool fetch error: $e');
        continue;
      }

      for (final tx in txs) {
        currentTxids.add(tx.txid);
        if (seenTxids.containsKey(tx.txid)) continue; // already alerted

        // Net effect on the whole wallet: a spend reports amount + fee, with
        // the change output (on the watched change frontier) subtracted
        // rather than counted as money leaving.
        final (:dir, :sats) = mempoolNetEffect(
          tx,
          walletAddresses[watchEntry.walletId] ?? {address},
        );

        final notifId = _txidToNotifId(tx.txid);
        seenTxids[tx.txid] = _SeenTx(
          walletId: watchEntry.walletId,
          walletLabel: watchEntry.walletLabel,
          dir: dir,
          sats: sats,
          seenAt: DateTime.now(),
          notifId: notifId,
        );
        seenUpdated = true;

        if (dir == 'in') {
          await _fireUnconfirmedIncoming(watchEntry.walletLabel, sats, notifId);
        } else {
          await _fireUnconfirmedOutgoing(watchEntry.walletLabel, sats, notifId);
        }
      }
    }

    return (currentTxids, seenUpdated, false);
  }

  /// R-6: whether the route selected now (reloaded prefs) is still [route],
  /// the one this tick started on. Checked between wallets, between watched
  /// addresses and before the tick's writes; once it isn't, or can't be
  /// read, the tick stops there with no further request and no write, and
  /// the next tick is a full scan on the route selected then.
  Future<bool> _stillOnRoute(NetworkRoute route) async {
    try {
      if (await readNetworkRoute(await reloadedPrefs()) == route) return true;
    } catch (_) {
      // Unreadable: fail closed.
    }
    if (kDebugMode) debugPrint('[Sentinel] the route changed — tick stopped');
    _fullScanDue = true;
    return false;
  }

  // ── Scan setup helpers ────────────────────────────────────────────────────────

  bool _proCheck(SharedPreferences prefs) {
    final pro = prefs.getBool(AppConstants.keyProUnlocked) ?? false;
    if (!pro) {
      if (kDebugMode) debugPrint('[Sentinel] Pro revoked — stopping service');
      prefs.setBool(AppConstants.keySentinelEnabled, false);
      FlutterForegroundTask.stopService();
      return false;
    }
    return true;
  }

  /// Loads wallets that Sentinel can actually monitor. Manual entries
  /// (exchange balances) have no addresses, so they are excluded — a portfolio
  /// of only manual entries reports "no wallets connected".
  Future<List<WalletEntry>?> _loadWatchOnlyWallets() async {
    final wallets = (await loadWalletsFromStorage())
        .where((w) => w.isWatchOnly)
        .toList();
    if (wallets.isEmpty) {
      _updateNotification('No wallets connected');
      return null;
    }
    return wallets;
  }

  /// Returns the cached [EsploraClient], rebuilding it only when the explorer
  /// URL or the network route has changed since the last tick. Reusing the
  /// same client preserves the Dio connection pool and (over Tor) existing
  /// SOCKS5 circuits across mempool ticks.
  ///
  /// Async because a custom explorer URL is held in secure storage.
  Future<EsploraClient> _getOrBuildClient(NetworkRoute route) async {
    final baseUrl = await resolveExplorerBaseUrl(route);
    if (_cachedClient == null ||
        _cachedBaseUrl != baseUrl ||
        _cachedRoute != route) {
      _cachedClient = EsploraClient(baseUrl: baseUrl, route: route);
      _cachedBaseUrl = baseUrl;
      _cachedRoute = route;
    }
    return _cachedClient!;
  }

  /// Fresh probe of a private route before any address touches the network.
  /// While it is down the tick is skipped — never run over clearnet. A Tor
  /// client still starting (a new lease, or a restart) is waited for first,
  /// with the route-down copy showing meanwhile, so the tick scans once it
  /// is ready instead of skipping.
  Future<bool> _routePreflight(NetworkRoute route) async {
    if (!route.isPrivate) {
      _routeUnavailableSince = null;
      return true;
    }

    if (route is TorRoute &&
        EmbeddedTorService.state == EmbeddedTorState.starting) {
      _showRouteDown(route);
      await _untilTorSettles();
    }
    final reachable = await RouteGate.probe(route) == RouteStatus.available;
    if (!reachable) {
      if (route is TorRoute &&
          EmbeddedTorService.state == EmbeddedTorState.failed) {
        _torFailedAt ??= _tickCount;
      }
      _fullScanDue = true;
      _showRouteDown(route);
      return false;
    }
    _routeUnavailableSince = null;
    _torFailedAt = null;
    return true;
  }

  /// "Waiting…" at first, "Paused…" once [route] has been down for
  /// `AppConstants.sentinelRouteMaxWaitMinutes`.
  void _showRouteDown(NetworkRoute route) {
    _routeUnavailableSince ??= DateTime.now();
    final waitMins =
        DateTime.now().difference(_routeUnavailableSince!).inMinutes;
    _updateNotification(sentinelRouteDownCopy(
      route,
      paused: waitMins >= AppConstants.sentinelRouteMaxWaitMinutes,
    ));
    if (kDebugMode) {
      debugPrint('[Sentinel] private route unavailable for ${waitMins}m');
    }
  }

  /// Waits until the Tor client is no longer starting (ready, failed or
  /// off), at most for its own bootstrap timeout.
  static Future<void> _untilTorSettles() async {
    final settled = Completer<void>();
    final sub = EmbeddedTorService.changes.listen((state) {
      if (state != EmbeddedTorState.starting && !settled.isCompleted) {
        settled.complete();
      }
    });
    try {
      if (EmbeddedTorService.state != EmbeddedTorState.starting) return;
      await settled.future.timeout(EmbeddedTorService.bootstrapTimeout);
    } on TimeoutException {
      // The probe decides.
    } finally {
      await sub.cancel();
    }
  }

  // ── Tor lease (TorHost) ─────────────────────────────────────────────────────

  /// The route for this tick, read from freshly reloaded [prefs], with
  /// Sentinel's Tor lease brought in line with it and with [want] (there is
  /// something to watch).
  Future<NetworkRoute> _routeForTick(
    SharedPreferences prefs, {
    required bool want,
  }) async {
    final route = await readNetworkRoute(prefs);
    await _onTorChain(() => _syncTorLease(route, want: want));
    return route;
  }

  /// Runs [step] after the lease changes queued before it. Errors are
  /// logged: the route probe decides what a tick may do.
  Future<void> _onTorChain(Future<void> Function() step) =>
      _torChain = _torChain.then((_) => step()).catchError((Object e) {
        if (kDebugMode) debugPrint('[Sentinel] Tor lease: $e');
      });

  /// Makes Sentinel's lease follow [route] and [want]: given back when the
  /// route left Tor, when there is nothing to watch, or when the service is
  /// going; taken when the route became Tor; and taken again when the
  /// client is off (no backoff: the app stopped it, it was handed over, or
  /// the route came back) or failed. Sentinel may be the isolate that runs
  /// the client, and it has no app resume to retry on (R6), so a failed
  /// client is retried on a backoff ([_retryDue], Ruling 1). A lease is
  /// taken again before the old one is given back, so the client isn't
  /// torn down in between.
  Future<void> _syncTorLease(NetworkRoute route, {required bool want}) async {
    if (route is! TorRoute || _destroyed || !want) {
      _torFailedAt = null;
      return _releaseTor();
    }
    final held = _torLease;
    switch (EmbeddedTorService.state) {
      case EmbeddedTorState.ready:
        _torFailedAt = null;
        if (held != null) return;
      case EmbeddedTorState.starting:
        if (held != null) return;
      case EmbeddedTorState.failed:
        final seen = _torFailedAt ??= _tickCount;
        if (held != null && !_retryDue(_tickCount - seen)) return;
      case EmbeddedTorState.off:
        _torFailedAt = null;
    }
    // A zero budget hands the lease over at once, so onDestroy can always
    // give it back; the wait for the client is in _routePreflight.
    _torLease = await TorHost.acquire(
      bootstrapBudget: Duration.zero,
      stillTor: torRouteStillSelected,
    );
    await held?.release();
  }

  Future<void> _releaseTor() async {
    final held = _torLease;
    _torLease = null;
    await held?.release();
  }

  /// Whether a client failed [ticks] ticks ago is retried now: on the 1st,
  /// 3rd and 7th tick, then every 5th, so the retries are 2, 4 and 8 min
  /// apart, then every 10 min.
  static bool _retryDue(int ticks) =>
      ticks == 1 || ticks == 3 || (ticks >= 7 && (ticks - 7) % 5 == 0);

  // Sentinel's three state blobs all describe the user's on-chain footprint —
  // watched addresses, per-wallet balances, pending txids and amounts — so
  // they live in encrypted storage rather than SharedPreferences.

  Future<Map<String, int>> _loadBalances() async {
    final raw = await bio.readSecureBlob(AppConstants.keySentinelBalances);
    if (raw == null) return {};
    try {
      return Map<String, int>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  // ── Watch map persistence ─────────────────────────────────────────────────────

  Future<void> _saveWatchMap(Map<String, _WatchEntry> map) =>
      bio.writeSecureBlob(
        AppConstants.keySentinelWatchMap,
        jsonEncode(map.map((k, v) => MapEntry(k, v.toJson()))),
      );

  Future<Map<String, _WatchEntry>> _loadWatchMap() async {
    final raw = await bio.readSecureBlob(AppConstants.keySentinelWatchMap);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) =>
          MapEntry(k, _WatchEntry.fromJson(v as Map<String, dynamic>)));
    } catch (_) {
      return {};
    }
  }

  // ── Seen txid persistence ─────────────────────────────────────────────────────

  Future<Map<String, _SeenTx>> _loadSeenTxids() async {
    final raw = await bio.readSecureBlob(AppConstants.keySentinelSeenTxids);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) =>
          MapEntry(k, _SeenTx.fromJson(v as Map<String, dynamic>)));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveSeenTxids(Map<String, _SeenTx> seenTxids) =>
      bio.writeSecureBlob(
        AppConstants.keySentinelSeenTxids,
        jsonEncode(seenTxids.map((k, v) => MapEntry(k, v.toJson()))),
      );

  /// Removes stale entries from [seenTxids] in-place.
  /// Returns true if any entries were removed (caller should save).
  bool _cleanupSeenTxids(Map<String, _SeenTx> seenTxids) {
    final cutoff = DateTime.now()
        .subtract(Duration(hours: AppConstants.sentinelSeenTxMaxAgeHours));
    final before = seenTxids.length;
    seenTxids.removeWhere((_, v) => v.seenAt.isBefore(cutoff));
    return seenTxids.length != before;
  }

  // ── Notification helpers ──────────────────────────────────────────────────────

  void _updateNotification(String text) {
    try {
      FlutterForegroundTask.updateService(
        notificationTitle: 'Sentinel',
        notificationText: text,
        notificationIcon: const NotificationIcon(metaDataName: 'ic_notification'),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[Sentinel] updateService error: $e');
    }
  }

  Future<void> _fireUnconfirmedIncoming(
      String walletLabel, int sats, int notifId) async {
    final btcStr = _formatSats(sats, '+');
    await _showNotif(
      id: notifId,
      title: '⚡ Incoming — $walletLabel',
      body: '$btcStr (unconfirmed)',
      importance: Importance.defaultImportance,
    );
    if (kDebugMode) debugPrint('[Sentinel] unconfirmed incoming alert fired');
  }

  Future<void> _fireUnconfirmedOutgoing(
      String walletLabel, int sats, int notifId) async {
    final btcStr = _formatSats(sats, '−');
    await _showNotif(
      id: notifId,
      title: '🚨 Possible unauthorized spend — $walletLabel',
      body: '$btcStr (unconfirmed)',
      importance: Importance.high,
    );
    if (kDebugMode) debugPrint('[Sentinel] unconfirmed outgoing alert fired');
  }

  Future<void> _fireConfirmedAlert(
      String walletLabel, bool isIncoming, int sats, int notifId) async {
    final sign = isIncoming ? '+' : '−';
    final verb = isIncoming ? 'received' : 'spent';
    final btcStr = _formatSats(sats, sign);
    await _showNotif(
      id: notifId,
      title: '✅ Confirmed — $walletLabel',
      body: '$btcStr $verb',
      importance: Importance.defaultImportance,
    );
    if (kDebugMode) debugPrint('[Sentinel] confirmation alert fired');
  }

  Future<void> _fireBalanceChanged(WalletEntry wallet, int deltaSats) async {
    final isIncoming = deltaSats > 0;
    final sign = isIncoming ? '+' : '−';
    final btcStr = _formatSats(deltaSats.abs(), sign);
    final notifId = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _showNotif(
      id: notifId,
      title: isIncoming
          ? '⬆ Received — ${wallet.label}'
          : '⬇ Sent — ${wallet.label}',
      body: btcStr,
      importance: isIncoming ? Importance.defaultImportance : Importance.high,
    );
    if (kDebugMode) debugPrint('[Sentinel] balance-change alert fired');
  }

  Future<void> _showNotif({
    required int id,
    required String title,
    required String body,
    required Importance importance,
  }) async {
    if (!_notifInitialized) {
      await _notifPlugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ));
      _notifInitialized = true;
    }
    await _notifPlugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          AppConstants.notifChannelIdSentinelAlerts,
          AppConstants.notifChannelNameSentinelAlerts,
          channelDescription:
              AppConstants.notifChannelDescSentinelAlerts,
          importance: importance,
          priority:
              importance == Importance.high ? Priority.high : Priority.defaultPriority,
          visibility: NotificationVisibility.secret,
          icon: 'ic_notification',
          color: const Color(0xFFF7931A),
        ),
      ),
    );
  }

  // ── Utilities ────────────────────────────────────────────────────────────────

  /// Derives a deterministic notification ID from the first 8 hex chars of a txid.
  /// Stable across app restarts; allows confirmed alerts to update unconfirmed ones.
  static int _txidToNotifId(String txid) =>
      int.parse(txid.substring(0, 8), radix: 16) & 0x7FFFFFFF;

  String _formatSats(int sats, String sign) {
    final btc = sats / 1e8;
    final btcStr = btc
        .toStringAsFixed(8)
        .replaceAll(_trailingZeros, '')
        .replaceAll(_trailingDot, '');
    return '$sign₿$btcStr';
  }
}

// ── SentinelService static API ────────────────────────────────────────────────

class SentinelService {
  /// Test seam: forces the Android (true) or iOS (false) branch of
  /// [isSupported] on the host VM. Null means [Platform.isAndroid]. Reset it
  /// in tearDown.
  @visibleForTesting
  static bool? debugIsAndroid;

  /// Sentinel is an Android foreground service; iOS has none. Every screen
  /// that offers Sentinel (the Wallets tab's card and its "Also in Pro" row)
  /// asks this.
  static bool get isSupported => debugIsAndroid ?? Platform.isAndroid;

  static void initialise() {
    if (!Platform.isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: AppConstants.notifChannelIdSentinelService,
        channelName: AppConstants.notifChannelNameSentinelService,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        visibility: fft.NotificationVisibility.VISIBILITY_SECRET,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(
          AppConstants.sentinelScanIntervalMinutes * 60 * 1000,
        ),
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    await FlutterForegroundTask.requestNotificationPermission();
    // Request Doze-mode exemption so the service survives deep sleep.
    // Shows a system dialog the first time; subsequent calls are silent no-ops.
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    await FlutterForegroundTask.startService(
      notificationTitle: 'Sentinel',
      notificationText: 'Mempool checks every 2 min · wallet scan every 10 min',
      notificationIcon: const NotificationIcon(metaDataName: 'ic_notification'),
      callback: sentinelStartCallback,
    );
    if (kDebugMode) debugPrint('[SentinelService] started');
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await FlutterForegroundTask.stopService();
    if (kDebugMode) debugPrint('[SentinelService] stopped');
  }

  static Future<void> restoreIfEnabled() async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(AppConstants.keySentinelEnabled) ?? false;
    final pro = prefs.getBool(AppConstants.keyProUnlocked) ?? false;
    if (!enabled || !pro) return;

    final running = await FlutterForegroundTask.isRunningService;
    if (!running) {
      await FlutterForegroundTask.startService(
        notificationTitle: 'Sentinel',
        notificationText: 'Mempool checks every 2 min · wallet scan every 10 min',
        notificationIcon: const NotificationIcon(metaDataName: 'ic_notification'),
        callback: sentinelStartCallback,
      );
      if (kDebugMode) debugPrint('[SentinelService] restored after app restart');
    }
  }
}

/// How long Sentinel's onDestroy waits for its Tor lease to be given back.
const sentinelTorReleaseBudget = Duration(seconds: 30);

/// Sentinel's notification text while [route] is down: "waiting" at first,
/// then [paused] once it has been down for
/// `AppConstants.sentinelRouteMaxWaitMinutes`. Unreadable proxy settings get
/// their own copy: checking the proxy would not help, re-entering it would.
@visibleForTesting
String sentinelRouteDownCopy(NetworkRoute route, {bool paused = false}) =>
    switch (route) {
      TorRoute() =>
        paused ? "Paused — Tor couldn't connect" : 'Waiting for Tor…',
      MisconfiguredProxyRoute() => paused
          ? 'Paused — re-enter your proxy in Wallets → Network to resume'
          : 'Proxy settings unreadable…',
      ProxyRoute() => paused
          ? 'Paused — check your proxy to resume'
          : 'Waiting for proxy…',
      // Never down: the preflight lets a direct route through unprobed.
      DirectRoute() => paused ? 'Paused' : 'Waiting for network…',
    };
