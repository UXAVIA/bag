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
import '../models/network_settings.dart';
import '../models/wallet_entry.dart';
import 'fee_service.dart';
import 'wallet/biometric_storage_service.dart' as bio;
import 'wallet/esplora_client.dart';
import 'wallet/wallet_engine.dart';
import 'wallet/wallet_scanner.dart';

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
  DateTime? _torUnavailableSince;
  final _notifPlugin = FlutterLocalNotificationsPlugin();
  bool _notifInitialized = false;
  static final _trailingZeros = RegExp(r'0+$');
  static final _trailingDot = RegExp(r'\.$');

  // Cached EsploraClient — reused across ticks to keep TCP connection pools alive.
  // Rebuilt only when the explorer URL or Tor setting changes.
  EsploraClient? _cachedClient;
  String? _cachedBaseUrl;
  bool? _cachedUseTor;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    if (kDebugMode) debugPrint('[Sentinel] service started');
    await _notifPlugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    ));
    _notifInitialized = true;
    await _runFullScan();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_scanning) {
      if (kDebugMode) debugPrint('[Sentinel] scan in progress, skipping');
      return;
    }
    _scanning = true;
    _tickCount++;
    final runFull =
        _tickCount % AppConstants.sentinelFullScanEveryNTicks == 0;
    (runFull ? _runFullScan() : _runMempoolOnly())
        .catchError((Object e, StackTrace st) {
          if (kDebugMode) debugPrint('[Sentinel] unhandled error: $e\n$st');
        })
        .whenComplete(() => _scanning = false);
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    if (kDebugMode) debugPrint('[Sentinel] service destroyed');
  }

  // ── Full scan (~10 min) ──────────────────────────────────────────────────────

  Future<void> _runFullScan() async {
    final prefs = await SharedPreferences.getInstance();

    if (!_proCheck(prefs)) return;
    final wallets = _loadWallets(prefs);
    if (wallets == null) return;
    final client = _getOrBuildClient(prefs);
    if (!await _torPreflight(prefs, client)) return;

    final lastKnown = _loadBalances(prefs);
    final watchMap = <String, _WatchEntry>{};
    final balanceChanges = <String, int>{}; // walletId → delta sats

    for (final wallet in wallets) {
      try {
        final zpub = await bio.readZpubForScanningById(wallet.id);
        if (zpub == null) continue;
        final root = parseZpub(zpub);
        final balance = await scanWallet(root, client);

        // Collect UTXO addresses for the watch map.
        for (final addr in balance.utxoAddresses) {
          watchMap[addr] =
              _WatchEntry(walletId: wallet.id, walletLabel: wallet.label);
        }
        // Derive frontier addresses (next few external addresses) for incoming watch.
        for (var i = 1; i <= AppConstants.sentinelFrontierCount; i++) {
          final key = deriveAddress(root, 0, balance.lastExternalIndex + i);
          final addr = pubKeyToP2wpkh(key.publicKey);
          watchMap[addr] =
              _WatchEntry(walletId: wallet.id, walletLabel: wallet.label);
        }

        final current = balance.totalSats;
        final previous = lastKnown[wallet.id];
        if (previous != null && current != previous) {
          balanceChanges[wallet.id] = current - previous;
        }
        lastKnown[wallet.id] = current;
      } on EsploraException catch (e) {
        if (kDebugMode) debugPrint('[Sentinel] scan failed (${wallet.label}): $e');
      } catch (e) {
        if (kDebugMode) debugPrint('[Sentinel] scan error (${wallet.label}): $e');
      }
    }

    // Persist the updated watch map for mempool-only ticks.
    await _saveWatchMap(prefs, watchMap);

    // Load seenTxids once — threaded through mempool check and confirmation pass.
    final seenTxids = _loadSeenTxids(prefs);

    // Run mempool check — mutates seenTxids in-place, returns current txids.
    final (currentMempoolTxids, mempoolUpdated) = await _checkMempool(
      client: client,
      watchMap: watchMap,
      seenTxids: seenTxids,
    );

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
    if (mempoolUpdated || confirmUpdated || cleaned) _saveSeenTxids(prefs, seenTxids);

    // Fire balance-changed alerts for wallets whose change wasn't covered by
    // a confirmation alert (missed mempool phase or direct on-chain change).
    for (final entry in balanceChanges.entries) {
      final wallet =
          wallets.firstWhere((w) => w.id == entry.key, orElse: () => wallets.first);
      await _fireBalanceChanged(wallet, entry.value);
    }

    // Fee alerts.
    final feeAlertsRaw = prefs.getString(AppConstants.keyFeeAlerts);
    if (feeAlertsRaw != null && feeAlertsRaw.isNotEmpty) {
      try {
        final useTor = prefs.getBool(AppConstants.keyUseTor) ?? false;
        final feeDio = buildFeeDio(useTor);
        final estimate = await fetchFeeEstimate(feeDio);
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

    await prefs.setString(AppConstants.keySentinelBalances, jsonEncode(lastKnown));
    final now = DateTime.now();
    await prefs.setString(
        AppConstants.keySentinelLastScan, now.toIso8601String());
    _updateNotification('Wallets & mempool · ${DateFormat('HH:mm').format(now)}');
    if (kDebugMode) debugPrint('[Sentinel] full scan complete');
  }

  // ── Mempool-only scan (every 2 min) ─────────────────────────────────────────

  Future<void> _runMempoolOnly() async {
    final prefs = await SharedPreferences.getInstance();

    if (!_proCheck(prefs)) return;
    final client = _getOrBuildClient(prefs);
    if (!await _torPreflight(prefs, client)) return;

    final watchMap = _loadWatchMap(prefs);
    if (watchMap.isEmpty) {
      if (kDebugMode) debugPrint('[Sentinel] mempool check: watch map empty, skipping');
      return;
    }

    final seenTxids = _loadSeenTxids(prefs);
    final (_, mempoolUpdated) = await _checkMempool(
        client: client, watchMap: watchMap, seenTxids: seenTxids);
    // Cleanup (24 h TTL) runs on full scans only — no need every 2 min.
    if (mempoolUpdated) _saveSeenTxids(prefs, seenTxids);

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
  Future<(Set<String>, bool)> _checkMempool({
    required EsploraClient client,
    required Map<String, _WatchEntry> watchMap,
    required Map<String, _SeenTx> seenTxids,
  }) async {
    if (watchMap.isEmpty) return (<String>{}, false);

    // seenTxids is passed in (already loaded by caller) — no redundant jsonDecode.
    final currentTxids = <String>{};
    bool seenUpdated = false;

    for (final mapEntry in watchMap.entries) {
      final address = mapEntry.key;
      final watchEntry = mapEntry.value;

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

        // Determine direction relative to this address.
        final isSpend = tx.inputs.any((i) => i.address == address);

        int sats;
        String dir;
        if (isSpend) {
          // Amount being spent from this address.
          sats = tx.inputs
              .where((i) => i.address == address)
              .fold(0, (s, i) => s + i.sats);
          dir = 'out';
        } else {
          // Amount arriving at this address.
          sats = tx.outputs
              .where((o) => o.address == address)
              .fold(0, (s, o) => s + o.sats);
          dir = 'in';
        }

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

    return (currentTxids, seenUpdated);
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

  List<WalletEntry>? _loadWallets(SharedPreferences prefs) {
    final walletsJson = prefs.getString(AppConstants.keyWallets);
    if (walletsJson == null || walletsJson.isEmpty) {
      _updateNotification('No wallets connected');
      return null;
    }
    final wallets = WalletEntry.listFromJson(walletsJson);
    if (wallets.isEmpty) {
      _updateNotification('No wallets connected');
      return null;
    }
    return wallets;
  }

  String _resolveBaseUrl(SharedPreferences prefs) {
    final presetIndex = prefs.getInt(AppConstants.keyExplorerPreset) ?? 0;
    final customUrl = prefs.getString(AppConstants.keyExplorerCustomUrl) ?? '';
    final preset = ExplorerPreset.values[presetIndex.clamp(
      0,
      ExplorerPreset.values.length - 1,
    )];
    return switch (preset) {
      ExplorerPreset.blockstream => AppConstants.explorerBlockstream,
      ExplorerPreset.mempool => AppConstants.explorerMempool,
      ExplorerPreset.custom =>
        customUrl.isNotEmpty ? customUrl : AppConstants.explorerBlockstream,
    };
  }

  /// Returns the cached [EsploraClient], rebuilding it only when the explorer
  /// URL or Tor preference has changed since the last tick. Reusing the same
  /// client preserves the Dio connection pool and (over Tor) existing SOCKS5
  /// circuits across mempool ticks.
  EsploraClient _getOrBuildClient(SharedPreferences prefs) {
    final useTor = prefs.getBool(AppConstants.keyUseTor) ?? false;
    final baseUrl = _resolveBaseUrl(prefs);
    if (_cachedClient == null ||
        _cachedBaseUrl != baseUrl ||
        _cachedUseTor != useTor) {
      _cachedClient = EsploraClient(baseUrl: baseUrl, useTor: useTor);
      _cachedBaseUrl = baseUrl;
      _cachedUseTor = useTor;
    }
    return _cachedClient!;
  }

  Future<bool> _torPreflight(
      SharedPreferences prefs, EsploraClient client) async {
    final useTor = prefs.getBool(AppConstants.keyUseTor) ?? false;
    if (!useTor) return true;

    final reachable = await _probeTor();
    if (!reachable) {
      _torUnavailableSince ??= DateTime.now();
      final waitMins =
          DateTime.now().difference(_torUnavailableSince!).inMinutes;
      if (waitMins >= AppConstants.sentinelTorMaxWaitMinutes) {
        _updateNotification('Paused — open Orbot to resume');
      } else {
        _updateNotification('Waiting for Tor…');
      }
      if (kDebugMode) debugPrint('[Sentinel] Tor unavailable for ${waitMins}m');
      return false;
    }
    _torUnavailableSince = null;
    return true;
  }

  Map<String, int> _loadBalances(SharedPreferences prefs) {
    final raw = prefs.getString(AppConstants.keySentinelBalances);
    if (raw == null) return {};
    try {
      return Map<String, int>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  // ── Watch map persistence ─────────────────────────────────────────────────────

  Future<void> _saveWatchMap(
      SharedPreferences prefs, Map<String, _WatchEntry> map) async {
    final encoded = jsonEncode(
        map.map((k, v) => MapEntry(k, v.toJson())));
    await prefs.setString(AppConstants.keySentinelWatchMap, encoded);
  }

  Map<String, _WatchEntry> _loadWatchMap(SharedPreferences prefs) {
    final raw = prefs.getString(AppConstants.keySentinelWatchMap);
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

  Map<String, _SeenTx> _loadSeenTxids(SharedPreferences prefs) {
    final raw = prefs.getString(AppConstants.keySentinelSeenTxids);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) =>
          MapEntry(k, _SeenTx.fromJson(v as Map<String, dynamic>)));
    } catch (_) {
      return {};
    }
  }

  void _saveSeenTxids(
      SharedPreferences prefs, Map<String, _SeenTx> seenTxids) {
    prefs.setString(AppConstants.keySentinelSeenTxids,
        jsonEncode(seenTxids.map((k, v) => MapEntry(k, v.toJson()))));
  }

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
    if (kDebugMode) debugPrint('[Sentinel] unconfirmed incoming: $walletLabel');
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
    if (kDebugMode) debugPrint('[Sentinel] unconfirmed outgoing: $walletLabel');
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
    if (kDebugMode) debugPrint('[Sentinel] confirmed: $walletLabel');
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
    if (kDebugMode) debugPrint('[Sentinel] balance changed: ${wallet.label}');
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

// ── TCP probe ─────────────────────────────────────────────────────────────────

Future<bool> _probeTor() async {
  try {
    final socket = await Socket.connect(
      AppConstants.torHost,
      AppConstants.torPort,
      timeout: const Duration(seconds: 5),
    );
    await socket.close();
    return true;
  } catch (_) {
    return false;
  }
}

// ── SentinelService static API ────────────────────────────────────────────────

class SentinelService {
  static void initialise() {
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
    await FlutterForegroundTask.stopService();
    if (kDebugMode) debugPrint('[SentinelService] stopped');
  }

  static Future<void> restoreIfEnabled() async {
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
