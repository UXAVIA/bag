/// What Sentinel stores and says, shared by its Android foreground service
/// (`sentinel_service.dart`) and every other Sentinel engine, so they cannot
/// drift apart: the two encrypted blobs' record formats, which addresses a
/// wallet puts on the watch map, reading, saving and replacing one wallet's
/// part of the stored watch map (on iOS keeping what a rescan drops as
/// retired entries), the notification id of a transaction, and the alert
/// titles and bodies.
///
/// No record or copy here is ever logged; the wallet label in an alert is the
/// user's own text and reaches only the notification.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/constants/app_constants.dart';
import 'wallet/biometric_storage_service.dart' as bio;
import 'wallet/wallet_engine.dart';
import 'wallet/wallet_scanner.dart';

// ── Seen-tx record ────────────────────────────────────────────────────────────

/// A transaction Sentinel has already alerted about (`keySentinelSeenTxids`:
/// txid → this). The JSON keys are the stored format.
class SentinelSeenTx {
  final String walletId;
  final String walletLabel;
  final String dir; // 'in' | 'out'
  final int sats;
  final DateTime seenAt;
  final int notifId;
  final bool confirmedAlerted;

  const SentinelSeenTx({
    required this.walletId,
    required this.walletLabel,
    required this.dir,
    required this.sats,
    required this.seenAt,
    required this.notifId,
    this.confirmedAlerted = false,
  });

  SentinelSeenTx copyWith({bool? confirmedAlerted}) => SentinelSeenTx(
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

  factory SentinelSeenTx.fromJson(Map<String, dynamic> j) => SentinelSeenTx(
    walletId: j['wid'] as String,
    walletLabel: j['wlabel'] as String,
    dir: j['dir'] as String,
    sats: j['sats'] as int,
    seenAt: DateTime.parse(j['seenAt'] as String),
    notifId: j['nid'] as int,
    confirmedAlerted: j['conf'] as bool? ?? false,
  );
}

/// Removes records older than [maxAge] (by default
/// `AppConstants.sentinelSeenTxMaxAgeHours`, Android's) as of [now] from
/// [seen] in place. Returns whether any went, so the caller knows to save.
bool cleanupSentinelSeen(
  Map<String, SentinelSeenTx> seen,
  DateTime now, {
  Duration maxAge = const Duration(
    hours: AppConstants.sentinelSeenTxMaxAgeHours,
  ),
}) {
  final cutoff = now.subtract(maxAge);
  final before = seen.length;
  seen.removeWhere((_, v) => v.seenAt.isBefore(cutoff));
  return seen.length != before;
}

/// How long a seen record is kept on iOS, against Android's 24 hours. A
/// transaction is usually alerted through one address and found again through
/// another (its change, or the confirmation) a run or more later, and iOS runs
/// can be hours apart and a rotation several runs long: dropping the record
/// sooner would alert the same transaction twice. A retired watch entry
/// ([SentinelWatchEntry.retiredAt]) is kept as long, for the same
/// transactions.
const iosSentinelSeenMaxAge = Duration(days: 30);

// ── Watch-map entry ───────────────────────────────────────────────────────────

/// Which wallet a watched address belongs to (`keySentinelWatchMap`:
/// address → this). The JSON keys are the stored format.
class SentinelWatchEntry {
  final String walletId;
  final String walletLabel;

  /// iOS only (R31): when a rescan of the wallet first stopped listing this
  /// address (a spent input below the frontiers), or null for a live entry.
  /// A retired entry stays watched for [iosSentinelSeenMaxAge], so a spend
  /// from it is still netted as the wallet's own (not reported as incoming
  /// change) and a sweep with no change is still seen. Android never writes
  /// one (its full scan rewrites the whole map), so its entries, and the
  /// format it stores, are as before: the key is only there when set.
  final DateTime? retiredAt;

  const SentinelWatchEntry({
    required this.walletId,
    required this.walletLabel,
    this.retiredAt,
  });

  bool get isRetired => retiredAt != null;

  /// Whether this entry was retired more than [iosSentinelSeenMaxAge] before
  /// [now], so it is no longer watched. Never for a live entry.
  bool expiredAt(DateTime now) =>
      retiredAt?.isBefore(now.subtract(iosSentinelSeenMaxAge)) ?? false;

  Map<String, dynamic> toJson() => {
    'wid': walletId,
    'wlabel': walletLabel,
    if (retiredAt case final at?) 'retiredAt': at.toUtc().toIso8601String(),
  };

  factory SentinelWatchEntry.fromJson(Map<String, dynamic> j) =>
      SentinelWatchEntry(
        walletId: j['wid'] as String,
        walletLabel: j['wlabel'] as String,
        retiredAt: j['retiredAt'] == null
            ? null
            : DateTime.parse(j['retiredAt'] as String),
      );
}

/// The addresses of one scanned wallet that Sentinel watches, each mapped to
/// the wallet: those holding UTXOs, then the next few unused receive
/// addresses (so an incoming payment is seen) and the next few unused change
/// addresses (so a spend's change output is recognised as ours and netted out
/// of the reported amount, see `mempoolNetEffect`).
///
/// A chain [source] lacks (a receive-only descriptor has no chain 1) is
/// skipped, and so is a BIP32 invalid child (§4: skip that index).
Map<String, SentinelWatchEntry> sentinelWatchEntries({
  required String walletId,
  required String walletLabel,
  required AddressSource source,
  required WalletBalance balance,
}) {
  final entry = SentinelWatchEntry(
    walletId: walletId,
    walletLabel: walletLabel,
  );
  final entries = <String, SentinelWatchEntry>{};
  for (final addr in balance.utxoAddresses) {
    entries[addr] = entry;
  }
  for (final (chain, next) in [
    (0, balance.nextExternalIndex),
    (1, balance.nextChangeIndex),
  ]) {
    if (!source.hasChain(chain)) continue;
    for (var i = 0; i < AppConstants.sentinelFrontierCount; i++) {
      try {
        entries[source.addressAt(chain, next + i)] = entry;
      } on Bip32InvalidChildException {
        // BIP32 §4: skip an invalid child index.
      }
    }
  }
  return entries;
}

/// The watch map as stored (`keySentinelWatchMap`), empty when there is none.
///
/// A blob that isn't a watch map reads as empty, as the Android service reads
/// it (the next scan rebuilds it). A failure of the secure store itself is
/// rethrown: reading it as "empty" would let the caller write back a map
/// without the other wallets.
Future<Map<String, SentinelWatchEntry>> loadSentinelWatchMap() async =>
    _decodeWatchMap(
      await bio.readSecureBlob(AppConstants.keySentinelWatchMap),
    );

Map<String, SentinelWatchEntry> _decodeWatchMap(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map(
      (k, v) =>
          MapEntry(k, SentinelWatchEntry.fromJson(v as Map<String, dynamic>)),
    );
  } catch (_) {
    return {};
  }
}

/// Stores [map] as the watch map (`keySentinelWatchMap`), encrypted.
Future<void> saveSentinelWatchMap(Map<String, SentinelWatchEntry> map) =>
    bio.writeSecureBlob(AppConstants.keySentinelWatchMap, _encodeWatchMap(map));

String _encodeWatchMap(Map<String, SentinelWatchEntry> map) =>
    jsonEncode(map.map((k, v) => MapEntry(k, v.toJson())));

/// Where the last queued watch-map edit stands, so edits in one isolate run
/// one at a time.
Future<void> _watchMapWrites = Future.value();

/// Edits the stored watch map: reads it, lets [change] edit it in place,
/// then writes it (deleting the blob once it is empty), with every edit in
/// this isolate queued behind the ones before it. [change] runs only when
/// the edit's turn comes, so anything it reads (which wallets are stored,
/// a wallet's label) is current then. A failed edit throws to its caller,
/// writes nothing and doesn't stall the ones after it. (Another isolate,
/// Android's Sentinel service, can still write between the read and the
/// write; its full scan rebuilds the map.)
Future<void> editSentinelWatchMap(
  FutureOr<void> Function(Map<String, SentinelWatchEntry> map) change,
) {
  final run = _watchMapWrites.then((_) async {
    final raw = await bio.readSecureBlob(AppConstants.keySentinelWatchMap);
    final map = _decodeWatchMap(raw);
    final before = _encodeWatchMap(map);
    await change(map);
    if (map.isEmpty) {
      if (raw != null) {
        await bio.deleteSecureBlob(AppConstants.keySentinelWatchMap);
      }
      return;
    }
    final after = _encodeWatchMap(map);
    if (after == before && after == raw) return;
    await bio.writeSecureBlob(AppConstants.keySentinelWatchMap, after);
  });
  _watchMapWrites = run.then<void>((_) {}, onError: (_) {});
  return run;
}

/// Replaces [walletId]'s entries in the stored watch map with [entries]
/// (address → entry), leaving every other wallet's as they are, on the
/// [editSentinelWatchMap] queue: two edits at once would otherwise both read
/// the same map and the later write would erase the earlier one's addresses.
/// A plain replacement: what it drops goes at once. Only tests use it (they
/// pin the queue with it); a wallet's rescan keeps the addresses it drops
/// as retired entries instead ([retireSentinelWatchEntries], R31).
@visibleForTesting
Future<void> replaceSentinelWatchEntries(
  String walletId,
  Map<String, SentinelWatchEntry> entries,
) => editSentinelWatchMap((map) {
  map.removeWhere((_, entry) => entry.walletId == walletId);
  map.addAll(entries);
});

/// One wallet's rescan on [map] (iOS, R31): [walletId]'s entries become
/// [fresh] (what [sentinelWatchEntries] builds from the rescan), except that
/// an address of the wallet the rescan no longer lists is kept, retired: a
/// spent input that holds no UTXO any more and lies below the frontiers.
/// The next background run may still meet the spend (through its change, or
/// through that input alone for a sweep with no change), and without the
/// input on the map the spend would net as incoming change, or not be seen.
///
/// An entry keeps the time it was first retired, takes [walletLabel], and
/// goes once retired more than [iosSentinelSeenMaxAge] before [now] (any
/// wallet's: the map stays bounded); one [fresh] lists again is live again.
/// Other wallets' entries are left as they are.
void retireSentinelWatchEntries(
  Map<String, SentinelWatchEntry> map, {
  required String walletId,
  required String walletLabel,
  required Map<String, SentinelWatchEntry> fresh,
  required DateTime now,
}) {
  final retired = {
    for (final MapEntry(key: address, value: entry) in map.entries)
      if (entry.walletId == walletId && !fresh.containsKey(address))
        address: SentinelWatchEntry(
          walletId: walletId,
          walletLabel: walletLabel,
          retiredAt: entry.retiredAt ?? now,
        ),
  };
  map
    ..removeWhere((_, entry) => entry.walletId == walletId)
    ..addAll(retired)
    ..addAll(fresh)
    ..removeWhere((_, entry) => entry.expiredAt(now));
}

/// Removes every watch-map entry of [walletId] (a removed wallet), retired
/// ones included, on the [editSentinelWatchMap] queue every edit uses, so a
/// rescan's edit queued by a scan that finished just before the removal
/// can't write it back.
Future<void> removeSentinelWatchWallet(String walletId) =>
    editSentinelWatchMap(
      (map) => map.removeWhere((_, entry) => entry.walletId == walletId),
    );

/// A deterministic notification id from the first 8 hex chars of a txid.
/// Stable across restarts, and lets a confirmed alert replace the unconfirmed
/// one.
int sentinelNotifId(String txid) =>
    int.parse(txid.substring(0, 8), radix: 16) & 0x7FFFFFFF;

// ── Alert copy ────────────────────────────────────────────────────────────────

enum SentinelAlertKind {
  /// A transaction into the wallet is in the mempool.
  pendingIn,

  /// A transaction out of the wallet is in the mempool.
  pendingOut,

  /// A transaction Sentinel alerted about has confirmed.
  confirmed,

  /// The wallet's balance rose with no mempool alert before it.
  received,

  /// The wallet's balance fell with no mempool alert before it.
  sent,

  /// [SentinelAlert.count] further alerts, folded into one.
  summary,
}

class SentinelAlert {
  final SentinelAlertKind kind;
  final String walletLabel;

  /// Always positive; the sign comes from the kind (and [incoming]).
  final int sats;
  final int notifId;

  /// Used by [SentinelAlertKind.confirmed]: whether the transaction paid in.
  final bool incoming;

  /// Used by [SentinelAlertKind.summary]: how many alerts it stands for.
  final int count;

  const SentinelAlert({
    required this.kind,
    required this.walletLabel,
    this.sats = 0,
    this.notifId = 0,
    this.incoming = true,
    this.count = 0,
  }) : assert(kind != SentinelAlertKind.summary || count >= 2);
}

/// The notification text of [a].
({String title, String body}) sentinelAlertCopy(SentinelAlert a) {
  final label = a.walletLabel;
  return switch (a.kind) {
    SentinelAlertKind.pendingIn => (
      title: '⚡ Incoming — $label',
      body: '${sentinelFormatSats(a.sats, '+')} (unconfirmed)',
    ),
    SentinelAlertKind.pendingOut => (
      title: '🚨 Possible unauthorized spend — $label',
      body: '${sentinelFormatSats(a.sats, '−')} (unconfirmed)',
    ),
    SentinelAlertKind.confirmed => (
      title: '✅ Confirmed — $label',
      body: a.incoming
          ? '${sentinelFormatSats(a.sats, '+')} received'
          : '${sentinelFormatSats(a.sats, '−')} spent',
    ),
    SentinelAlertKind.received => (
      title: '⬆ Received — $label',
      body: sentinelFormatSats(a.sats, '+'),
    ),
    SentinelAlertKind.sent => (
      title: '⬇ Sent — $label',
      body: sentinelFormatSats(a.sats, '−'),
    ),
    SentinelAlertKind.summary => (
      title: '${a.count} more transactions — $label',
      body: 'Open Bag to see them.',
    ),
  };
}

final _trailingZeros = RegExp(r'0+$');
final _trailingDot = RegExp(r'\.$');

/// [sats] as `<sign>₿<btc>`, up to 8 decimals with trailing zeros trimmed.
String sentinelFormatSats(int sats, String sign) {
  final btc = sats / 1e8;
  final btcStr = btc
      .toStringAsFixed(8)
      .replaceAll(_trailingZeros, '')
      .replaceAll(_trailingDot, '');
  return '$sign₿$btcStr';
}
