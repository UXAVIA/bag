/// Sentinel Lite's check on iOS (spec D4–D6), run from the background refresh
/// in the little time iOS gives it.
///
/// Each watched address costs one `/address` request, whose two transaction
/// counts are compared with the last run's: only an address whose mempool
/// holds something, or whose confirmed count grew, gets its transactions
/// fetched. Pending addresses go first (to catch their confirmation), then
/// those never seen (R32: a new wallet's baseline is taken soon after
/// Sentinel Lite is turned on), then the rest round-robin from a saved
/// cursor, so a wallet with more addresses than one run can check is covered
/// over several runs. One that goes first but whose check doesn't complete
/// waits for the rotation from then on (R37, R38), until one does.
///
/// No I/O but the [SentinelExplorer]: the caller loads and saves the state
/// and the seen records, and shows the alerts. Nothing here is logged.
library;

import 'dart:math';

import 'sentinel_records.dart';
import 'wallet/esplora_client.dart';
import 'wallet/tx_effect.dart';

/// The explorer requests the check makes.
abstract interface class SentinelExplorer {
  Future<AddressStats> fetchAddress(String a);
  Future<List<MempoolTx>> fetchMempoolTxs(String a);

  /// The newest confirmed transactions, newest first.
  Future<List<MempoolTx>> fetchRecentChainTxs(String a);
}

/// [SentinelExplorer] over an [EsploraClient], which carries the route.
class EsploraSentinelExplorer implements SentinelExplorer {
  final EsploraClient client;

  const EsploraSentinelExplorer(this.client);

  @override
  Future<AddressStats> fetchAddress(String a) => client.fetchAddress(a);

  @override
  Future<List<MempoolTx>> fetchMempoolTxs(String a) =>
      client.fetchMempoolTxs(a);

  @override
  Future<List<MempoolTx>> fetchRecentChainTxs(String a) =>
      client.fetchRecentChainTxs(a);
}

/// What the check keeps between runs (`keySentinelIosActivity`, encrypted).
/// The JSON keys are the stored format.
class IosSentinelState {
  /// Each watched address's confirmed and mempool transaction counts as of
  /// its last successful check. An address without one hasn't been seen yet.
  final Map<String, ({int chain, int mempool})> counts;

  /// Where the next run's round-robin starts: an index into the watched
  /// addresses, sorted.
  final int cursor;

  /// Addresses that would go ahead of the rotation (pending, or never seen)
  /// but whose check didn't complete when last started there: the
  /// `/address` request failed (R37), or a transaction list it needed failed
  /// or was refused by the cut-off (R38). They wait for the rotation instead,
  /// until a check of them completes, so one that hangs every run can't take
  /// a slot ahead of it every run. Stored under `'l'` only when there are
  /// some; absent reads as none.
  final Set<String> later;

  const IosSentinelState({
    required this.counts,
    required this.cursor,
    this.later = const {},
  });

  static const empty = IosSentinelState(counts: {}, cursor: 0);

  Map<String, dynamic> toJson() => {
    'c': {
      for (final MapEntry(:key, :value) in counts.entries)
        key: [value.chain, value.mempool],
    },
    'i': cursor,
    if (later.isNotEmpty) 'l': later.toList()..sort(),
  };

  /// Throws if [j] isn't in the format [toJson] writes.
  factory IosSentinelState.fromJson(Map<String, dynamic> j) {
    final c = j['c'] as Map<String, dynamic>;
    return IosSentinelState(
      counts: {
        for (final MapEntry(:key, :value) in c.entries)
          key: (chain: (value as List)[0] as int, mempool: value[1] as int),
      },
      cursor: j['i'] as int,
      later: {for (final a in (j['l'] as List?) ?? const []) a as String},
    );
  }
}

class IosSentinelResult {
  /// The state for the next run: counts of the addresses still watched.
  final IosSentinelState state;

  /// The seen records, with this run's added and those older than
  /// [iosSentinelSeenMaxAge] gone.
  final Map<String, SentinelSeenTx> seen;

  /// What to show, wallet by wallet in the order found: per wallet every
  /// spend, and of the other alerts at most three, then one summary of the
  /// rest (or a fourth alert, rather than a summary of one).
  final List<SentinelAlert> alerts;

  /// How many addresses' `/address` request succeeded.
  final int checked;

  /// The route changed: the run stopped before its next address. The caller
  /// saves and shows nothing; the next run finds the same transactions.
  final bool stopped;

  /// Whether the run moved the round-robin on: it deferred an address to
  /// the rotation ([IosSentinelState.later]), or its cursor passed addresses
  /// it started. A run in which no address answered still saves [state] when
  /// this holds (R37), or the same addresses would take its first requests
  /// every run; otherwise it saves nothing (R16).
  final bool advanced;

  const IosSentinelResult({
    required this.state,
    required this.seen,
    required this.alerts,
    required this.checked,
    required this.stopped,
    required this.advanced,
  });
}

/// Esplora's first page of an address's confirmed transactions: the most one
/// check looks at.
const _maxChainTxs = 25;

/// Alerts other than spends shown per wallet per run before the rest fold
/// into one summary.
const _alertsPerWallet = 3;

/// An alert of this run, with the wallet it counts against and its txid.
typedef _Found = ({String walletId, String txid, SentinelAlert alert});

/// Checks the addresses of [watchMap] against [state], at most [concurrency]
/// at a time, and returns what to save and show.
///
/// Before each address it asks [stillOnRoute] (false, or a throw: the run is
/// [IosSentinelResult.stopped] and no further address starts). [mayStart] is
/// the cut-off for every request (R12): asked before the address's
/// `/address` request (before and after the route check) and before each of
/// its transaction-list requests. Once it says no, or the route has changed,
/// no further request goes out. An address whose lists it refused keeps its
/// old counts (R14: a first sight records its confirmed count, with nothing
/// pending), and the next run's round-robin starts at the first such address
/// (R13), so it is looked at again then.
///
/// Per address (spec D4): a first sight records the counts without alerting
/// confirmed history; a mempool count above zero fetches the pending
/// transactions, and each one not in [seen] alerts; a confirmed count that
/// grew by n fetches the newest min(n, 25) confirmed ones, of which a seen,
/// not yet confirmed one alerts confirmed and an unseen one (it confirmed
/// between runs) alerts received or sent. Amounts are the net effect on the
/// whole wallet, over all its watched addresses. An address that fails keeps
/// its old counts, so its change is found when it is next checked.
///
/// Order (spec D5): addresses whose last mempool count was above zero, then
/// live ones never seen (R32), then the rest round-robin from the cursor.
/// One of the first two kinds whose check doesn't complete this run (its
/// `/address` request, or a transaction list it needs, fails or is refused
/// by the cut-off; over Tor a request can outlast the whole run, and the
/// client's close then fails it) is deferred to the rotation (R37, R38,
/// [IosSentinelState.later]) until a check of it completes, so two that hang
/// every run can't take both slots ahead of the rotation every run.
/// Retired entries (R31, a spent input a rescan dropped) are checked in the
/// rotation, never as a first sight, and count as the wallet's addresses for
/// the net amounts; one retired more than [iosSentinelSeenMaxAge] ago is not
/// watched at all.
Future<IosSentinelResult> runIosSentinelCheck({
  required SentinelExplorer explorer,
  required Map<String, SentinelWatchEntry> watchMap,
  required Map<String, SentinelSeenTx> seen,
  required IosSentinelState state,
  required bool Function() mayStart,
  required Future<bool> Function() stillOnRoute,
  required int concurrency,
  DateTime Function() now = DateTime.now,
}) async {
  assert(concurrency > 0);
  final startedAt = now();
  final watched = {
    for (final MapEntry(key: address, value: entry) in watchMap.entries)
      if (!entry.expiredAt(startedAt)) address: entry,
  };
  final addresses = watched.keys.toList()..sort();
  final n = addresses.length;
  final cursor = n == 0 ? 0 : state.cursor % n;
  // Deferred before (R37), and still watched: in the rotation.
  final later = {
    for (final a in state.later)
      if (watched.containsKey(a)) a,
  };
  bool wasPending(String a) =>
      !later.contains(a) && (state.counts[a]?.mempool ?? 0) > 0;
  bool neverSeen(String a) =>
      !later.contains(a) &&
      !state.counts.containsKey(a) &&
      !watched[a]!.isRetired;

  // Pending addresses first, then the live ones never seen (R32), then the
  // others from the cursor on, each with its offset from the cursor.
  final pending = addresses.where(wasPending).toList();
  final unseen = addresses.where(neverSeen).toList();
  final rotation = [
    for (var k = 0; k < n; k++)
      if (!wasPending(addresses[(cursor + k) % n]) &&
          !neverSeen(addresses[(cursor + k) % n]))
        k,
  ];
  final order = [
    ...pending,
    ...unseen,
    for (final k in rotation) addresses[(cursor + k) % n],
  ];
  // Where the rotation starts in [order].
  final ahead = pending.length + unseen.length;

  final walletAddresses = <String, Set<String>>{};
  for (final MapEntry(key: address, value: entry) in watched.entries) {
    walletAddresses.putIfAbsent(entry.walletId, () => {}).add(address);
  }

  final counts = {
    for (final a in addresses)
      if (state.counts[a] case final c?) a: c,
  };
  final seenOut = Map.of(seen);
  final laterOut = {...later};
  var deferred = 0;
  final found = <_Found>[];
  var checked = 0;
  var started = 0;
  var stopped = false;
  var pastCutOff = false;

  // Whether another request may go out: the route hasn't changed and the
  // cut-off hasn't passed (R12).
  bool mayRequest() {
    if (stopped || pastCutOff) return false;
    if (mayStart()) return true;
    pastCutOff = true;
    return false;
  }

  // A transaction not in the seen records: remembered, and alerted as pending
  // or, when it confirmed between runs, as received or sent.
  void alertNew(
    MempoolTx tx,
    SentinelWatchEntry entry, {
    required bool confirmed,
  }) {
    final (:dir, :sats) = mempoolNetEffect(
      tx,
      walletAddresses[entry.walletId]!,
    );
    final incoming = dir == 'in';
    final notifId = sentinelNotifId(tx.txid);
    seenOut[tx.txid] = SentinelSeenTx(
      walletId: entry.walletId,
      walletLabel: entry.walletLabel,
      dir: dir,
      sats: sats,
      seenAt: now(),
      notifId: notifId,
      confirmedAlerted: confirmed,
    );
    found.add((
      walletId: entry.walletId,
      txid: tx.txid,
      alert: SentinelAlert(
        kind: switch ((confirmed, incoming)) {
          (false, true) => SentinelAlertKind.pendingIn,
          (false, false) => SentinelAlertKind.pendingOut,
          (true, true) => SentinelAlertKind.received,
          (true, false) => SentinelAlertKind.sent,
        },
        walletLabel: entry.walletLabel,
        sats: sats,
        notifId: notifId,
        incoming: incoming,
      ),
    ));
  }

  // A transaction seen pending earlier that has now confirmed.
  void alertConfirmed(String txid, SentinelSeenTx prior) {
    seenOut[txid] = prior.copyWith(confirmedAlerted: true);
    found.add((
      walletId: prior.walletId,
      txid: txid,
      alert: SentinelAlert(
        kind: SentinelAlertKind.confirmed,
        walletLabel: prior.walletLabel,
        sats: prior.sats,
        notifId: prior.notifId,
        incoming: prior.dir == 'in',
      ),
    ));
  }

  // Order indices whose lists the cut-off or a route stop refused.
  final cutShort = <int>{};

  // Fetches and alerts the lists [stats] says [order]'s address [i] needs.
  // False when one wasn't fetched: refused ([cutShort]) or failed.
  Future<bool> fetchLists(
    int i,
    AddressStats stats,
    ({int chain, int mempool})? old,
  ) async {
    final address = order[i];
    final entry = watched[address]!;
    try {
      if (stats.mempoolTxCount > 0) {
        if (!mayRequest()) {
          cutShort.add(i);
          return false;
        }
        for (final tx in await explorer.fetchMempoolTxs(address)) {
          if (!seenOut.containsKey(tx.txid)) {
            alertNew(tx, entry, confirmed: false);
          }
        }
      }
      final grew = old == null ? 0 : stats.chainTxCount - old.chain;
      if (grew > 0) {
        if (!mayRequest()) {
          cutShort.add(i);
          return false;
        }
        final txs = await explorer.fetchRecentChainTxs(address);
        for (final tx in txs.take(min(grew, _maxChainTxs))) {
          final prior = seenOut[tx.txid];
          if (prior == null) {
            alertNew(tx, entry, confirmed: true);
          } else if (!prior.confirmedAlerted) {
            alertConfirmed(tx.txid, prior);
          }
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  // The explorer's answers are untrusted: whatever goes wrong with one
  // address leaves its counts as they were, and the others are still checked.
  Future<void> check(int i) async {
    final address = order[i];
    // Started ahead of the rotation and its check didn't complete: it waits
    // for the rotation from now on (R37, R38).
    void defer() {
      if (i < ahead && laterOut.add(address)) deferred++;
    }

    final AddressStats stats;
    try {
      stats = await explorer.fetchAddress(address);
    } catch (_) {
      defer();
      return;
    }
    checked++;
    final old = counts[address];
    if (await fetchLists(i, stats, old)) {
      counts[address] = (
        chain: stats.chainTxCount,
        mempool: stats.mempoolTxCount,
      );
      laterOut.remove(address);
      return;
    }
    defer();
    if (old == null) {
      // A first sight's baseline, with nothing pending (R14): a transaction
      // that confirms before the next check shows as growth there, and one
      // still pending is fetched as pending.
      counts[address] = (chain: stats.chainTxCount, mempool: 0);
    }
    // Otherwise the old counts stay, so what changed is found again.
  }

  Future<bool> onRoute() async {
    try {
      return await stillOnRoute();
    } catch (_) {
      return false; // Unreadable: fail closed.
    }
  }

  Future<void> worker() async {
    while (started < order.length && mayRequest()) {
      if (!await onRoute()) {
        stopped = true;
        return;
      }
      // Meanwhile another worker may have found the route changed or taken
      // the last address, and the cut-off may have passed.
      if (started >= order.length || !mayRequest()) return;
      await check(started++);
    }
  }

  await Future.wait([
    for (var i = 0; i < min(concurrency, order.length); i++) worker(),
  ]);

  // Addresses start in [order], so those started are its first [started].
  // The next run's round-robin starts at the first rotation address not
  // started or cut short (R13); one the explorer failed for doesn't hold it
  // back. Once all are through, after the last.
  var through = 0;
  while (through < rotation.length &&
      ahead + through < started &&
      !cutShort.contains(ahead + through)) {
    through++;
  }
  final nextCursor = rotation.isEmpty
      ? cursor
      : through < rotation.length
      ? (cursor + rotation[through]) % n
      : (cursor + rotation.last + 1) % n;
  final advanced = deferred > 0 || (through > 0 && nextCursor != cursor);

  cleanupSentinelSeen(seenOut, now(), maxAge: iosSentinelSeenMaxAge);

  return IosSentinelResult(
    state: IosSentinelState(
      counts: {
        for (final a in addresses)
          if (counts[a] case final c?) a: c,
      },
      cursor: nextCursor,
      later: laterOut,
    ),
    seen: seenOut,
    alerts: _limitPerWallet(found),
    checked: checked,
    stopped: stopped,
    advanced: advanced,
  );
}

/// Spends ([SentinelAlertKind.pendingOut], [SentinelAlertKind.sent]): always
/// shown on their own, never folded into a summary (R9).
bool _alwaysShown(SentinelAlertKind kind) =>
    kind == SentinelAlertKind.pendingOut || kind == SentinelAlertKind.sent;

/// [found] wallet by wallet, in the order found. A wallet's spends are all
/// shown; of its other alerts the first [_alertsPerWallet] are, and the rest
/// fold into one summary after them, when that leaves at least two to fold (a
/// single extra one is shown as it is). The summary takes the notification id
/// of the first transaction it covers.
List<SentinelAlert> _limitPerWallet(List<_Found> found) {
  final byWallet = <String, List<_Found>>{};
  for (final f in found) {
    byWallet.putIfAbsent(f.walletId, () => []).add(f);
  }
  final alerts = <SentinelAlert>[];
  for (final list in byWallet.values) {
    final capped = [
      for (final f in list)
        if (!_alwaysShown(f.alert.kind)) f,
    ];
    final fold = capped.length > _alertsPerWallet + 1;
    final folded = fold ? capped.sublist(_alertsPerWallet) : const <_Found>[];
    alerts.addAll([
      for (final f in list)
        if (!folded.contains(f)) f.alert,
    ]);
    if (fold) {
      alerts.add(
        SentinelAlert(
          kind: SentinelAlertKind.summary,
          walletLabel: folded.first.alert.walletLabel,
          notifId: sentinelNotifId(folded.first.txid),
          count: folded.length,
        ),
      );
    }
  }
  return alerts;
}
