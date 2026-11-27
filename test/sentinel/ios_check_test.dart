/// The iOS Sentinel Lite check engine (`lib/services/sentinel_ios_check.dart`,
/// spec D4–D6): one `/address` request per watched address, comparing its
/// transaction counts with the last run's, and the transaction lists fetched
/// only for addresses that changed.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:bag/services/sentinel_ios_check.dart';
import 'package:bag/services/sentinel_records.dart';
import 'package:bag/services/wallet/esplora_client.dart';

final _now = DateTime(2026, 11, 26, 12);

const _cold = SentinelWatchEntry(walletId: 'w1', walletLabel: 'Cold');
const _spending = SentinelWatchEntry(walletId: 'w2', walletLabel: 'Spending');

/// A 64-hex txid whose first 8 hex chars are [n], so `sentinelNotifId` reads
/// back [n].
String _txid(int n) => n.toRadixString(16).padLeft(8, '0') + '0' * 56;

AddressStats _stats(int chain, int mempool) => AddressStats(
  hasTransactions: chain + mempool > 0,
  balanceSats: 0,
  chainTxCount: chain,
  mempoolTxCount: mempool,
);

MempoolTx _tx(
  String txid, {
  List<(String, int)> inputs = const [],
  List<(String, int)> outputs = const [],
}) => MempoolTx(
  txid: txid,
  inputs: [for (final (a, s) in inputs) (address: a, sats: s)],
  outputs: [for (final (a, s) in outputs) (address: a, sats: s)],
);

/// Per-address scripted answers and a log of every request, in order
/// (`address a`, `mempool a`, `chain a`).
class _FakeExplorer implements SentinelExplorer {
  final Map<String, AddressStats> stats = {};
  final Map<String, List<MempoolTx>> mempool = {};
  final Map<String, List<MempoolTx>> chain = {};

  /// Addresses whose `/address` request fails.
  final Set<String> failing = {};

  /// Addresses whose transaction-list requests fail.
  final Set<String> failingTxs = {};

  /// Addresses whose `/address` answer waits until the completer completes.
  final Map<String, Completer<void>> holdAddress = {};

  final List<String> log = [];

  int inFlight = 0;
  int maxInFlight = 0;

  Future<T> _answer<T>(
    String request,
    T Function() answer,
    bool fails, [
    Future<void>? hold,
  ]) async {
    log.add(request);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (hold != null) await hold;
      // A few event-loop turns, so concurrent checks overlap.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      if (fails) throw const EsploraException('Network error: unknown');
      return answer();
    } finally {
      inFlight--;
    }
  }

  @override
  Future<AddressStats> fetchAddress(String a) => _answer(
    'address $a',
    () => stats[a] ?? (throw StateError('no stats scripted for $a')),
    failing.contains(a),
    holdAddress[a]?.future,
  );

  @override
  Future<List<MempoolTx>> fetchMempoolTxs(String a) =>
      _answer('mempool $a', () => mempool[a] ?? [], failingTxs.contains(a));

  @override
  Future<List<MempoolTx>> fetchRecentChainTxs(String a) =>
      _answer('chain $a', () => chain[a] ?? [], failingTxs.contains(a));

  Iterable<String> get addressRequests =>
      log.where((r) => r.startsWith('address '));
}

/// The reviewer's probe explorer (R37): each `/address` request of
/// [hanging], and each mempool-list request of [hangingLists] (R38), stays in
/// flight until the client is closed ([closed]), as one over Tor can outlast
/// the whole run, and then fails, as the close makes it. [onAllHanging] runs
/// once two are in flight at once. The others answer from [stats].
class _HangingExplorer implements SentinelExplorer {
  _HangingExplorer(this.hanging, this.stats, {this.hangingLists = const {}});

  final Set<String> hanging;
  final Set<String> hangingLists;
  final Map<String, AddressStats> stats;
  final closed = Completer<void>();
  final requested = <String>[];
  var _hangingNow = 0;
  void Function()? onAllHanging;

  Future<Never> _hang() async {
    if (++_hangingNow == 2) onAllHanging?.call();
    await closed.future;
    throw const EsploraException('cancelled');
  }

  @override
  Future<AddressStats> fetchAddress(String a) async {
    requested.add(a);
    if (hanging.contains(a)) return _hang();
    await Future<void>.delayed(Duration.zero);
    return stats[a]!;
  }

  @override
  Future<List<MempoolTx>> fetchMempoolTxs(String a) async {
    if (hangingLists.contains(a)) return _hang();
    return const [];
  }

  @override
  Future<List<MempoolTx>> fetchRecentChainTxs(String a) async => const [];
}

Future<IosSentinelResult> _run(
  _FakeExplorer explorer, {
  required Map<String, SentinelWatchEntry> watchMap,
  Map<String, SentinelSeenTx> seen = const {},
  IosSentinelState state = IosSentinelState.empty,
  bool Function()? mayStart,
  Future<bool> Function()? stillOnRoute,
  int concurrency = 2,
  DateTime? at,
}) => runIosSentinelCheck(
  explorer: explorer,
  watchMap: watchMap,
  seen: seen,
  state: state,
  mayStart: mayStart ?? () => true,
  stillOnRoute: stillOnRoute ?? () async => true,
  concurrency: concurrency,
  now: () => at ?? _now,
);

IosSentinelState _counts(
  Map<String, ({int chain, int mempool})> counts, {
  int cursor = 0,
}) => IosSentinelState(counts: counts, cursor: cursor);

/// `mayStart` that turns false once [n] `/address` requests have gone out
/// since it was made, as the real cut-off turns false once the time is up.
/// Like it, it then refuses every later request, follow-ups included.
bool Function() _untilAddressRequests(_FakeExplorer explorer, int n) {
  final before = explorer.addressRequests.length;
  return () => explorer.addressRequests.length - before < n;
}

void main() {
  group('detection', () {
    test('first sight records counts without alerting history', () async {
      final explorer = _FakeExplorer()..stats['a'] = _stats(12, 0);

      final r = await _run(explorer, watchMap: {'a': _cold});

      expect(r.alerts, isEmpty);
      expect(r.state.counts, {'a': (chain: 12, mempool: 0)});
      expect(explorer.log, ['address a']);
      expect(r.checked, 1);
      expect(r.stopped, isFalse);
      expect(r.seen, isEmpty);
    });

    test('first sight with a pending tx alerts it', () async {
      final t = _txid(1);
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(3, 1)
        ..mempool['a'] = [
          _tx(t, outputs: [('a', 10000)]),
        ];

      final r = await _run(explorer, watchMap: {'a': _cold});

      expect(r.alerts, hasLength(1));
      expect(r.alerts.single.kind, SentinelAlertKind.pendingIn);
      expect(r.alerts.single.sats, 10000);
      expect(explorer.log, ['address a', 'mempool a']);
      expect(r.state.counts, {'a': (chain: 3, mempool: 1)});
    });

    test('a pending incoming tx alerts once', () async {
      final t = _txid(0xabc);
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(2, 1)
        ..mempool['a'] = [
          _tx(t, inputs: [('elsewhere', 60000)], outputs: [('a', 50000)]),
        ];
      final watchMap = {'a': _cold};

      final r1 = await _run(
        explorer,
        watchMap: watchMap,
        state: _counts({'a': (chain: 2, mempool: 0)}),
      );

      expect(r1.alerts, hasLength(1));
      final alert = r1.alerts.single;
      expect(alert.kind, SentinelAlertKind.pendingIn);
      expect(alert.walletLabel, 'Cold');
      expect(alert.sats, 50000);
      expect(alert.notifId, sentinelNotifId(t));
      final record = r1.seen[t]!;
      expect(record.walletId, 'w1');
      expect(record.walletLabel, 'Cold');
      expect(record.dir, 'in');
      expect(record.sats, 50000);
      expect(record.seenAt, _now);
      expect(record.notifId, sentinelNotifId(t));
      expect(record.confirmedAlerted, isFalse);

      final r2 = await _run(
        explorer,
        watchMap: watchMap,
        seen: r1.seen,
        state: r1.state,
      );

      expect(r2.alerts, isEmpty);
      expect(r2.seen.keys, [t]);
    });

    test('a spend nets out its change', () async {
      final t = _txid(2);
      final spend = _tx(
        t,
        inputs: [('a', 100000)],
        outputs: [('change', 30000), ('elsewhere', 69000)],
      );
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(1, 1)
        ..stats['change'] = _stats(0, 1)
        ..mempool['a'] = [spend]
        ..mempool['change'] = [spend];

      final r = await _run(
        explorer,
        watchMap: {'a': _cold, 'change': _cold},
        state: _counts({
          'a': (chain: 1, mempool: 0),
          'change': (chain: 0, mempool: 0),
        }),
      );

      expect(r.alerts, hasLength(1));
      expect(r.alerts.single.kind, SentinelAlertKind.pendingOut);
      expect(r.alerts.single.sats, 70000);
      expect(r.seen[t]!.dir, 'out');
    });

    test('a seen pending tx alerts confirmed once', () async {
      final t = _txid(3);
      final older = _txid(4);
      final payment = _tx(t, outputs: [('a', 20000)]);
      final watchMap = {'a': _cold};
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(3, 1)
        ..mempool['a'] = [payment];

      final r1 = await _run(
        explorer,
        watchMap: watchMap,
        state: _counts({'a': (chain: 3, mempool: 0)}),
      );
      expect(r1.alerts.single.kind, SentinelAlertKind.pendingIn);

      // It confirmed: one more chain tx, none pending. The chain list also
      // holds an older tx never alerted, outside the newest one.
      explorer
        ..log.clear()
        ..stats['a'] = _stats(4, 0)
        ..mempool['a'] = []
        ..chain['a'] = [
          payment,
          _tx(older, outputs: [('a', 1000)]),
        ];

      final r2 = await _run(
        explorer,
        watchMap: watchMap,
        seen: r1.seen,
        state: r1.state,
      );

      expect(r2.alerts, hasLength(1));
      final alert = r2.alerts.single;
      expect(alert.kind, SentinelAlertKind.confirmed);
      expect(alert.incoming, isTrue);
      expect(alert.sats, 20000);
      expect(alert.notifId, sentinelNotifId(t));
      expect(r2.seen[t]!.confirmedAlerted, isTrue);
      expect(r2.seen.containsKey(older), isFalse);
      expect(explorer.log, ['address a', 'chain a']);

      explorer.log.clear();
      final r3 = await _run(
        explorer,
        watchMap: watchMap,
        seen: r2.seen,
        state: r2.state,
      );

      expect(r3.alerts, isEmpty);
      expect(explorer.log, ['address a']);
    });

    test('a tx that confirmed between runs alerts received', () async {
      final t = _txid(5);
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(4, 0)
        ..chain['a'] = [
          _tx(t, outputs: [('a', 40000)]),
          _tx(_txid(6), outputs: [('a', 1000)]),
        ];

      final r = await _run(
        explorer,
        watchMap: {'a': _cold},
        state: _counts({'a': (chain: 3, mempool: 0)}),
      );

      expect(r.alerts, hasLength(1));
      final alert = r.alerts.single;
      expect(alert.kind, SentinelAlertKind.received);
      expect(alert.walletLabel, 'Cold');
      expect(alert.sats, 40000);
      expect(alert.notifId, sentinelNotifId(t));
      final record = r.seen[t]!;
      expect(record.dir, 'in');
      expect(record.sats, 40000);
      expect(record.confirmedAlerted, isTrue);
      expect(r.state.counts['a'], (chain: 4, mempool: 0));
    });

    test('a spend that confirmed between runs alerts sent, net of its '
        'change', () async {
      final t = _txid(7);
      final spend = _tx(
        t,
        inputs: [('a', 100000)],
        outputs: [('change', 30000), ('elsewhere', 69000)],
      );
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(2, 0)
        ..stats['change'] = _stats(0, 0)
        ..chain['a'] = [spend];

      final r = await _run(
        explorer,
        watchMap: {'a': _cold, 'change': _cold},
        state: _counts({
          'a': (chain: 1, mempool: 0),
          'change': (chain: 0, mempool: 0),
        }),
      );

      expect(r.alerts, hasLength(1));
      expect(r.alerts.single.kind, SentinelAlertKind.sent);
      expect(r.alerts.single.sats, 70000);
      expect(r.seen[t]!.dir, 'out');
      expect(r.seen[t]!.confirmedAlerted, isTrue);
    });

    test('one tx touching two watched addresses alerts once', () async {
      final t = _txid(8);
      final payment = _tx(t, outputs: [('a', 10000), ('b', 15000)]);
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(1, 1)
        ..stats['b'] = _stats(1, 1)
        ..mempool['a'] = [payment]
        ..mempool['b'] = [payment];

      final r = await _run(
        explorer,
        watchMap: {'a': _cold, 'b': _cold},
        state: _counts({
          'a': (chain: 1, mempool: 0),
          'b': (chain: 1, mempool: 0),
        }),
      );

      expect(explorer.log, containsAll(['mempool a', 'mempool b']));
      expect(r.alerts, hasLength(1));
      expect(r.alerts.single.kind, SentinelAlertKind.pendingIn);
      expect(r.alerts.single.sats, 25000);
      expect(r.seen.keys, [t]);
    });

    test('an address that errors keeps its counts', () async {
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(9, 0)
        ..stats['b'] = _stats(3, 0)
        ..failing.add('a');

      final r = await _run(
        explorer,
        watchMap: {'a': _cold, 'b': _cold},
        state: _counts({
          'a': (chain: 1, mempool: 0),
          'b': (chain: 3, mempool: 0),
        }),
      );

      expect(explorer.addressRequests, containsAll(['address a', 'address b']));
      expect(r.checked, 1);
      expect(r.state.counts['a'], (chain: 1, mempool: 0));
      expect(r.state.counts['b'], (chain: 3, mempool: 0));
      expect(r.alerts, isEmpty);
      expect(r.stopped, isFalse);
    });

    test('an address first seen with an error stays unseen', () async {
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(9, 0)
        ..failing.add('a');

      final r = await _run(explorer, watchMap: {'a': _cold});

      expect(r.checked, 0);
      expect(r.state.counts, isEmpty);
    });

    test('a failed transaction list keeps the old counts', () async {
      final t = _txid(9);
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(4, 0)
        ..chain['a'] = [
          _tx(t, outputs: [('a', 40000)]),
        ]
        ..failingTxs.add('a');
      final watchMap = {'a': _cold};

      final r1 = await _run(
        explorer,
        watchMap: watchMap,
        state: _counts({'a': (chain: 3, mempool: 0)}),
      );

      expect(r1.checked, 1);
      expect(r1.alerts, isEmpty);
      expect(r1.state.counts['a'], (chain: 3, mempool: 0));

      // The next run still sees the growth and alerts it.
      explorer.failingTxs.clear();
      final r2 = await _run(
        explorer,
        watchMap: watchMap,
        seen: r1.seen,
        state: r1.state,
      );

      expect(r2.alerts.single.kind, SentinelAlertKind.received);
      expect(r2.state.counts['a'], (chain: 4, mempool: 0));
    });
  });

  group('alert limit', () {
    test('more than three alerts for one wallet become a summary', () async {
      final txids = [for (var i = 1; i <= 5; i++) _txid(0x100 + i)];
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(15, 0)
        ..chain['a'] = [
          for (final t in txids) _tx(t, outputs: [('a', 1000)]),
        ];

      final r = await _run(
        explorer,
        watchMap: {'a': _cold},
        state: _counts({'a': (chain: 10, mempool: 0)}),
      );

      expect(r.alerts, hasLength(4));
      expect(
        r.alerts.take(3).map((a) => a.kind),
        everyElement(SentinelAlertKind.received),
      );
      expect(r.alerts.take(3).map((a) => a.notifId), [
        for (final t in txids.take(3)) sentinelNotifId(t),
      ]);
      final summary = r.alerts.last;
      expect(summary.kind, SentinelAlertKind.summary);
      expect(summary.count, 2);
      expect(summary.walletLabel, 'Cold');
      expect(summary.notifId, sentinelNotifId(txids[3]));
      // Every one is remembered, so none alerts again.
      expect(r.seen.keys, containsAll(txids));
    });

    test('a fourth alert is shown, not summarised', () async {
      final txids = [for (var i = 1; i <= 4; i++) _txid(0x200 + i)];
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(14, 0)
        ..chain['a'] = [
          for (final t in txids) _tx(t, outputs: [('a', 1000)]),
        ];

      final r = await _run(
        explorer,
        watchMap: {'a': _cold},
        state: _counts({'a': (chain: 10, mempool: 0)}),
      );

      expect(r.alerts.map((a) => a.kind), [
        for (var i = 0; i < 4; i++) SentinelAlertKind.received,
      ]);
    });

    test('the limit is per wallet', () async {
      final cold = [for (var i = 1; i <= 3; i++) _txid(0x300 + i)];
      final spending = [for (var i = 1; i <= 3; i++) _txid(0x400 + i)];
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(3, 0)
        ..stats['b'] = _stats(3, 0)
        ..chain['a'] = [
          for (final t in cold) _tx(t, outputs: [('a', 1000)]),
        ]
        ..chain['b'] = [
          for (final t in spending) _tx(t, outputs: [('b', 1000)]),
        ];

      final r = await _run(
        explorer,
        watchMap: {'a': _cold, 'b': _spending},
        state: _counts({
          'a': (chain: 0, mempool: 0),
          'b': (chain: 0, mempool: 0),
        }),
      );

      expect(r.alerts, hasLength(6));
      expect(
        r.alerts.where((a) => a.kind == SentinelAlertKind.summary),
        isEmpty,
      );
      expect(r.alerts.where((a) => a.walletLabel == 'Cold'), hasLength(3));
      expect(r.alerts.where((a) => a.walletLabel == 'Spending'), hasLength(3));
    });

    test('a confirmed spend is never folded into the summary', () async {
      final incoming = [for (var i = 1; i <= 5; i++) _txid(0x700 + i)];
      final spend = _txid(0x7ff);
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(16, 0)
        // Newest first: the spend is the last, oldest of the six.
        ..chain['a'] = [
          for (final t in incoming) _tx(t, outputs: [('a', 1000)]),
          _tx(spend, inputs: [('a', 5000)], outputs: [('elsewhere', 4800)]),
        ];

      final r = await _run(
        explorer,
        watchMap: {'a': _cold},
        state: _counts({'a': (chain: 10, mempool: 0)}),
      );

      expect(r.alerts, hasLength(5));
      final sent = r.alerts.where((a) => a.kind == SentinelAlertKind.sent);
      expect(sent.single.sats, 5000);
      expect(sent.single.notifId, sentinelNotifId(spend));
      expect(
        r.alerts
            .where((a) => a.kind == SentinelAlertKind.received)
            .map((a) => a.notifId),
        [for (final t in incoming.take(3)) sentinelNotifId(t)],
      );
      final summary = r.alerts.singleWhere(
        (a) => a.kind == SentinelAlertKind.summary,
      );
      expect(summary.count, 2);
      expect(summary.notifId, sentinelNotifId(incoming[3]));
    });

    test('pending spends are shown beside the capped incoming ones', () async {
      final incoming = [for (var i = 1; i <= 4; i++) _txid(0x800 + i)];
      final spends = [_txid(0x8f1), _txid(0x8f2)];
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(1, 6)
        ..mempool['a'] = [
          _tx(spends[0], inputs: [('a', 5000)], outputs: [('elsewhere', 4800)]),
          for (final t in incoming) _tx(t, outputs: [('a', 1000)]),
          _tx(spends[1], inputs: [('a', 7000)], outputs: [('elsewhere', 6800)]),
        ];

      final r = await _run(
        explorer,
        watchMap: {'a': _cold},
        state: _counts({'a': (chain: 1, mempool: 0)}),
      );

      // Four incoming: one over the cap is shown, not summarised (R6).
      expect(r.alerts, hasLength(6));
      expect(
        r.alerts
            .where((a) => a.kind == SentinelAlertKind.pendingOut)
            .map((a) => a.notifId),
        [for (final t in spends) sentinelNotifId(t)],
      );
      expect(
        r.alerts.where((a) => a.kind == SentinelAlertKind.pendingIn),
        hasLength(4),
      );
      expect(
        r.alerts.where((a) => a.kind == SentinelAlertKind.summary),
        isEmpty,
      );
    });

    test('at most 25 confirmed transactions are looked at', () async {
      final txids = [for (var i = 1; i <= 30; i++) _txid(0x500 + i)];
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(40, 0)
        ..chain['a'] = [
          for (final t in txids) _tx(t, outputs: [('a', 1000)]),
        ];

      final r = await _run(
        explorer,
        watchMap: {'a': _cold},
        state: _counts({'a': (chain: 10, mempool: 0)}),
      );

      expect(r.seen, hasLength(25));
      expect(r.seen.keys, containsAll(txids.take(25)));
      expect(r.alerts.last.kind, SentinelAlertKind.summary);
      expect(r.alerts.last.count, 22);
    });
  });

  group('order and limits', () {
    test('rotation covers every address across runs', () async {
      final addresses = [for (var i = 0; i < 10; i++) 'a$i'];
      final explorer = _FakeExplorer();
      for (final a in addresses) {
        explorer.stats[a] = _stats(1, 0);
      }
      final watchMap = {for (final a in addresses) a: _cold};

      // All seen before, so all are in the rotation (R32 puts never-seen
      // ones ahead of it).
      var state = _counts({
        for (final a in addresses) a: (chain: 1, mempool: 0),
      });
      final cursors = <int>[];
      for (var run = 0; run < 4; run++) {
        final r = await _run(
          explorer,
          watchMap: watchMap,
          state: state,
          mayStart: _untilAddressRequests(explorer, 3),
        );
        expect(r.checked, 3);
        state = r.state;
        cursors.add(state.cursor);
      }

      expect(explorer.addressRequests.toSet(), {
        for (final a in addresses) 'address $a',
      });
      expect(cursors, [3, 6, 9, 2]);
    });

    test('pending addresses first', () async {
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(1, 0)
        ..stats['b'] = _stats(1, 0)
        ..stats['c'] = _stats(1, 1);

      final r = await _run(
        explorer,
        watchMap: {'a': _cold, 'b': _cold, 'c': _cold},
        state: _counts({
          'a': (chain: 1, mempool: 0),
          'b': (chain: 1, mempool: 0),
          'c': (chain: 1, mempool: 1),
        }),
        mayStart: _untilAddressRequests(explorer, 1),
      );

      expect(explorer.addressRequests, ['address c']);
      // No address of the rotation was started, so it starts there next run.
      expect(r.state.cursor, 0);
    });

    test('R32: never-seen addresses go right after pending ones, before the '
        'rotation, and leave the cursor alone', () async {
      final explorer = _FakeExplorer();
      for (final a in ['a', 'b', 'c', 'new1', 'new2', 'p']) {
        explorer.stats[a] = _stats(1, 0);
      }
      explorer.stats['p'] = _stats(1, 1);

      final r = await _run(
        explorer,
        watchMap: {
          for (final a in ['a', 'b', 'c', 'new1', 'new2', 'p']) a: _cold,
        },
        state: _counts({
          'a': (chain: 1, mempool: 0),
          'b': (chain: 1, mempool: 0),
          'c': (chain: 1, mempool: 0),
          'p': (chain: 1, mempool: 1),
        }, cursor: 1),
        mayStart: _untilAddressRequests(explorer, 4),
        concurrency: 1,
      );

      // Pending, then the two never seen, then the rotation from its cursor
      // (index 1 of the sorted addresses: b).
      expect(explorer.addressRequests, [
        'address p',
        'address new1',
        'address new2',
        'address b',
      ]);
      expect(r.state.counts['new1'], (chain: 1, mempool: 0));
      expect(r.state.counts['new2'], (chain: 1, mempool: 0));
      // b was the rotation's first; it goes on at c (sorted index 2).
      expect(r.state.cursor, 2);
    });

    test('R32: a run cut off among never-seen addresses starts the rotation '
        'where it was next run', () async {
      final explorer = _FakeExplorer();
      for (final a in ['a', 'b', 'new1', 'new2']) {
        explorer.stats[a] = _stats(1, 0);
      }

      final r = await _run(
        explorer,
        watchMap: {for (final a in ['a', 'b', 'new1', 'new2']) a: _cold},
        state: _counts({
          'a': (chain: 1, mempool: 0),
          'b': (chain: 1, mempool: 0),
        }, cursor: 1),
        mayStart: _untilAddressRequests(explorer, 1),
        concurrency: 1,
      );

      expect(explorer.addressRequests, ['address new1']);
      expect(r.state.cursor, 1);
    });

    test('checks at most `concurrency` addresses at a time', () async {
      final explorer = _FakeExplorer();
      final watchMap = <String, SentinelWatchEntry>{};
      for (var i = 0; i < 6; i++) {
        explorer.stats['a$i'] = _stats(1, 0);
        watchMap['a$i'] = _cold;
      }

      final r = await _run(explorer, watchMap: watchMap, concurrency: 2);

      expect(r.checked, 6);
      expect(explorer.maxInFlight, 2);
      expect(explorer.inFlight, 0);
    });

    test('no address starts once the deadline is near; those under way '
        'finish', () async {
      final explorer = _FakeExplorer();
      final watchMap = <String, SentinelWatchEntry>{};
      for (var i = 0; i < 6; i++) {
        explorer.stats['a$i'] = _stats(1, 0);
        watchMap['a$i'] = _cold;
      }

      final r = await _run(
        explorer,
        watchMap: watchMap,
        mayStart: _untilAddressRequests(explorer, 2),
        concurrency: 4,
      );

      expect(explorer.addressRequests, ['address a0', 'address a1']);
      expect(explorer.inFlight, 0);
      expect(r.checked, 2);
      expect(r.state.counts.keys, ['a0', 'a1']);
      expect(r.stopped, isFalse);
    });

    test('an address answered after the cut-off sends no transaction '
        'request and keeps its counts', () async {
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(4, 1)
        ..mempool['a'] = [
          _tx(_txid(0x900), outputs: [('a', 1000)]),
        ]
        ..chain['a'] = [
          _tx(_txid(0x901), outputs: [('a', 1000)]),
        ];
      final hold = Completer<void>();
      explorer.holdAddress['a'] = hold;
      var open = true;

      final run = _run(
        explorer,
        watchMap: {'a': _cold},
        state: _counts({'a': (chain: 3, mempool: 0)}),
        mayStart: () => open,
        concurrency: 1,
      );
      await pumpEventQueue();
      // The cut-off passes while the `/address` request is under way.
      open = false;
      hold.complete();
      final r = await run;

      expect(explorer.log, ['address a']);
      expect(r.checked, 1);
      expect(r.state.counts['a'], (chain: 3, mempool: 0));
      expect(r.alerts, isEmpty);
      expect(r.stopped, isFalse);
    });

    test('once another worker finds the route changed, an address under way '
        'sends no follow-up', () async {
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(1, 1)
        ..mempool['a'] = [
          _tx(_txid(0x902), outputs: [('a', 1000)]),
        ]
        ..stats['b'] = _stats(1, 0)
        ..stats['c'] = _stats(1, 0);
      final hold = Completer<void>();
      explorer.holdAddress['a'] = hold;
      var calls = 0;

      final run = _run(
        explorer,
        watchMap: {'a': _cold, 'b': _cold, 'c': _cold},
        state: _counts({
          'a': (chain: 1, mempool: 0),
          'b': (chain: 1, mempool: 0),
          'c': (chain: 1, mempool: 0),
        }),
        // Yes for a and b; no when b's worker asks before c.
        stillOnRoute: () async => calls++ < 2,
      );
      await pumpEventQueue();
      hold.complete();
      final r = await run;

      expect(r.stopped, isTrue);
      expect(explorer.log, ['address a', 'address b']);
      expect(r.state.counts['a'], (chain: 1, mempool: 0));
      expect(r.alerts, isEmpty);
    });

    test('a worker whose route check outlasts the cut-off starts '
        'nothing', () async {
      final explorer = _FakeExplorer()..stats['a'] = _stats(1, 0);
      var open = true;

      final r = await _run(
        explorer,
        watchMap: {'a': _cold},
        mayStart: () => open,
        stillOnRoute: () async {
          open = false;
          return true;
        },
        concurrency: 1,
      );

      expect(explorer.log, isEmpty);
      expect(r.checked, 0);
      expect(r.stopped, isFalse);
    });

    test('the chain list is refused after the cut-off too', () async {
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(4, 0)
        ..chain['a'] = [
          _tx(_txid(0x903), outputs: [('a', 1000)]),
        ];
      final hold = Completer<void>();
      explorer.holdAddress['a'] = hold;
      var open = true;

      final run = _run(
        explorer,
        watchMap: {'a': _cold},
        state: _counts({'a': (chain: 3, mempool: 0)}),
        mayStart: () => open,
        concurrency: 1,
      );
      await pumpEventQueue();
      open = false;
      hold.complete();
      final r = await run;

      expect(explorer.log, ['address a']);
      expect(r.state.counts['a'], (chain: 3, mempool: 0));
      expect(r.alerts, isEmpty);
    });

    test('the next run starts at an address the cut-off cut short', () async {
      final addresses = [for (var i = 0; i < 10; i++) 'a$i'];
      final explorer = _FakeExplorer();
      for (final a in addresses) {
        explorer.stats[a] = _stats(1, 0);
      }
      // The third address grew, so it needs its chain list.
      explorer
        ..stats['a2'] = _stats(2, 0)
        ..chain['a2'] = [
          _tx(_txid(0x904), outputs: [('a2', 1000)]),
        ];

      final r = await _run(
        explorer,
        watchMap: {for (final a in addresses) a: _cold},
        state: _counts({for (final a in addresses) a: (chain: 1, mempool: 0)}),
        mayStart: _untilAddressRequests(explorer, 3),
      );

      expect(explorer.log, isNot(contains('chain a2')));
      expect(r.state.counts['a2'], (chain: 1, mempool: 0));
      expect(r.state.cursor, 2);
    });

    test('an address the explorer fails for does not hold the rotation '
        'back', () async {
      final explorer = _FakeExplorer()
        ..stats['a0'] = _stats(1, 0)
        ..stats['a1'] = _stats(2, 0)
        ..stats['a2'] = _stats(1, 0)
        ..stats['a3'] = _stats(1, 0)
        ..failingTxs.add('a1');

      final r = await _run(
        explorer,
        watchMap: {for (var i = 0; i < 4; i++) 'a$i': _cold},
        state: _counts({
          for (var i = 0; i < 4; i++) 'a$i': (chain: 1, mempool: 0),
        }),
        mayStart: _untilAddressRequests(explorer, 3),
        concurrency: 1,
      );

      expect(explorer.log, contains('chain a1'));
      expect(r.state.cursor, 3);
    });

    test('a first sight whose pending list is refused records a baseline, '
        'so what happens next still alerts', () async {
      final t = _txid(0x905);
      final payment = _tx(t, outputs: [('a', 1000)]);
      final watchMap = {'a': _cold};
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(5, 1)
        ..mempool['a'] = [payment];

      final r1 = await _run(
        explorer,
        watchMap: watchMap,
        mayStart: _untilAddressRequests(explorer, 1),
      );

      expect(explorer.log, ['address a']);
      expect(r1.state.counts, {'a': (chain: 5, mempool: 0)});
      expect(r1.alerts, isEmpty);

      // It confirmed before the next check.
      explorer
        ..stats['a'] = _stats(6, 0)
        ..mempool['a'] = []
        ..chain['a'] = [payment];
      final confirmed = await _run(
        explorer,
        watchMap: watchMap,
        seen: r1.seen,
        state: r1.state,
      );
      expect(confirmed.alerts.map((a) => a.kind), [SentinelAlertKind.received]);

      // Or it is still pending.
      explorer
        ..stats['a'] = _stats(5, 1)
        ..mempool['a'] = [payment];
      final pending = await _run(
        explorer,
        watchMap: watchMap,
        seen: r1.seen,
        state: r1.state,
      );
      expect(pending.alerts.map((a) => a.kind), [SentinelAlertKind.pendingIn]);
    });

    test('a first sight whose pending list fails records a baseline', () async {
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(5, 1)
        ..failingTxs.add('a');

      final r = await _run(explorer, watchMap: {'a': _cold});

      expect(explorer.log, ['address a', 'mempool a']);
      expect(r.state.counts, {'a': (chain: 5, mempool: 0)});
      expect(r.checked, 1);
    });

    test('a route change stops before the next request', () async {
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(1, 0)
        ..stats['b'] = _stats(1, 0)
        ..stats['c'] = _stats(1, 0);
      var calls = 0;

      final r = await _run(
        explorer,
        watchMap: {'a': _cold, 'b': _cold, 'c': _cold},
        stillOnRoute: () async => calls++ == 0,
        concurrency: 1,
      );

      expect(r.stopped, isTrue);
      expect(explorer.log, ['address a']);
    });

    test('no address starts once any route check has said no', () async {
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(1, 0)
        ..stats['b'] = _stats(1, 0);
      final slow = Completer<bool>();
      var calls = 0;

      final run = _run(
        explorer,
        watchMap: {'a': _cold, 'b': _cold},
        // The first check answers late, with yes; the second at once, with no.
        stillOnRoute: () => calls++ == 0 ? slow.future : Future.value(false),
      );
      await pumpEventQueue();
      slow.complete(true);
      final r = await run;

      expect(r.stopped, isTrue);
      expect(explorer.log, isEmpty);
    });

    test('a route check that throws stops the run', () async {
      final explorer = _FakeExplorer()..stats['a'] = _stats(1, 0);

      final r = await _run(
        explorer,
        watchMap: {'a': _cold},
        stillOnRoute: () async => throw StateError('prefs'),
      );

      expect(r.stopped, isTrue);
      expect(explorer.log, isEmpty);
    });
  });

  group('retired entries (R31)', () {
    SentinelWatchEntry retired(Duration ago) => SentinelWatchEntry(
      walletId: 'w1',
      walletLabel: 'Cold',
      retiredAt: _now.subtract(ago),
    );

    test('a spend seen through its change after the input was retired is '
        'one pending spend, net of the change', () async {
      final t = _txid(0x701);
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(1, 1)
        ..stats['change'] = _stats(0, 1)
        ..stats['next'] = _stats(0, 0)
        ..mempool['a'] = [
          _tx(
            t,
            inputs: [('a', 100000)],
            outputs: [('change', 30000), ('x', 69000)],
          ),
        ]
        ..mempool['change'] = [
          _tx(
            t,
            inputs: [('a', 100000)],
            outputs: [('change', 30000), ('x', 69000)],
          ),
        ];

      final r = await _run(
        explorer,
        watchMap: {
          'a': retired(const Duration(hours: 1)),
          'change': _cold,
          'next': _cold,
        },
        state: _counts({
          'a': (chain: 1, mempool: 0),
          'change': (chain: 0, mempool: 0),
          'next': (chain: 0, mempool: 0),
        }),
      );

      expect(r.alerts, hasLength(1));
      expect(r.alerts.single.kind, SentinelAlertKind.pendingOut);
      expect(r.alerts.single.sats, 70000);
      expect(r.seen[t]!.dir, 'out');
    });

    test('a sweep with no change is alerted through the retired input',
        () async {
      final t = _txid(0x702);
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(1, 1)
        ..stats['next'] = _stats(0, 0)
        ..mempool['a'] = [
          _tx(t, inputs: [('a', 100000)], outputs: [('x', 99000)]),
        ];

      final r = await _run(
        explorer,
        watchMap: {'a': retired(const Duration(days: 2)), 'next': _cold},
        state: _counts({
          'a': (chain: 1, mempool: 0),
          'next': (chain: 0, mempool: 0),
        }),
      );

      expect(explorer.log, contains('mempool a'));
      expect(r.alerts.map((a) => (a.kind, a.sats)), [
        (SentinelAlertKind.pendingOut, 100000),
      ]);
    });

    test('a sweep that confirmed between runs is alerted as sent', () async {
      final t = _txid(0x703);
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(2, 0)
        ..chain['a'] = [
          _tx(t, inputs: [('a', 100000)], outputs: [('x', 99000)]),
        ];

      final r = await _run(
        explorer,
        watchMap: {'a': retired(const Duration(days: 2))},
        state: _counts({'a': (chain: 1, mempool: 0)}),
      );

      expect(r.alerts.map((a) => (a.kind, a.sats)), [
        (SentinelAlertKind.sent, 100000),
      ]);
    });

    test('a retired entry kept more than 30 days is neither checked nor '
        'kept in the counts', () async {
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(1, 1)
        ..stats['next'] = _stats(0, 0);

      final r = await _run(
        explorer,
        watchMap: {
          'a': retired(const Duration(days: 31)),
          'next': _cold,
        },
        state: _counts({
          'a': (chain: 1, mempool: 1),
          'next': (chain: 0, mempool: 0),
        }),
      );

      expect(explorer.addressRequests, ['address next']);
      expect(r.state.counts.keys, ['next']);
    });

    test('retired entries are checked in the rotation, after pending and '
        'never-seen live ones; a pending one still goes first', () async {
      final explorer = _FakeExplorer();
      for (final a in ['live', 'new', 'old', 'oldNew', 'oldPending']) {
        explorer.stats[a] = _stats(1, 0);
      }

      await _run(
        explorer,
        watchMap: {
          'live': _cold,
          'new': _cold,
          'old': retired(const Duration(days: 1)),
          'oldNew': retired(const Duration(days: 1)),
          'oldPending': retired(const Duration(days: 1)),
        },
        state: _counts({
          'live': (chain: 1, mempool: 0),
          'old': (chain: 1, mempool: 0),
          'oldPending': (chain: 1, mempool: 1),
        }),
        concurrency: 1,
      );

      // Sorted: live, new, old, oldNew, oldPending; cursor 0.
      expect(explorer.addressRequests, [
        'address oldPending',
        'address new',
        'address live',
        'address old',
        'address oldNew',
      ]);
    });
  });

  group('state', () {
    test('counts for removed addresses are dropped', () async {
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(1, 0)
        ..failing.add('a');

      final r = await _run(
        explorer,
        watchMap: {'a': _cold},
        state: _counts({
          'a': (chain: 1, mempool: 0),
          'gone': (chain: 5, mempool: 1),
        }),
      );

      expect(r.state.counts, {'a': (chain: 1, mempool: 0)});
      expect(explorer.log, ['address a']);
    });

    test('seen records older than 30 days are dropped', () async {
      final explorer = _FakeExplorer()..stats['a'] = _stats(1, 0);
      SentinelSeenTx seenAt(DateTime at) => SentinelSeenTx(
        walletId: 'w1',
        walletLabel: 'Cold',
        dir: 'in',
        sats: 1000,
        seenAt: at,
        notifId: 1,
      );
      final old = _txid(0x600);
      final dayOld = _txid(0x601);

      final r = await _run(
        explorer,
        watchMap: {'a': _cold},
        seen: {
          old: seenAt(_now.subtract(const Duration(days: 31))),
          dayOld: seenAt(_now.subtract(const Duration(hours: 25))),
        },
        state: _counts({'a': (chain: 1, mempool: 0)}),
      );

      expect(r.seen.keys, [dayOld]);
      expect(iosSentinelSeenMaxAge, const Duration(days: 30));
    });

    test('a 25-hour-old seen record keeps its change address quiet', () async {
      // Alerted a day ago through `a`; its change address is only checked
      // now, a run of the rotation later.
      final t = _txid(0x602);
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(2, 0)
        ..stats['change'] = _stats(1, 0)
        ..chain['change'] = [
          _tx(
            t,
            inputs: [('a', 100000)],
            outputs: [('change', 30000), ('elsewhere', 69000)],
          ),
        ];

      final r = await _run(
        explorer,
        watchMap: {'a': _cold, 'change': _cold},
        seen: {
          t: SentinelSeenTx(
            walletId: 'w1',
            walletLabel: 'Cold',
            dir: 'out',
            sats: 70000,
            seenAt: _now.subtract(const Duration(hours: 25)),
            notifId: sentinelNotifId(t),
            confirmedAlerted: true,
          ),
        },
        state: _counts({
          'a': (chain: 2, mempool: 0),
          'change': (chain: 0, mempool: 0),
        }),
      );

      expect(explorer.log, contains('chain change'));
      expect(r.alerts, isEmpty);
      expect(r.seen.containsKey(t), isTrue);
    });

    test('a spend alerted through its input stays quiet when its change '
        'address is checked more than a day later', () async {
      final spend = _txid(0x603);
      final tx = _tx(
        spend,
        inputs: [('a', 100000)],
        outputs: [('change', 30000), ('elsewhere', 69000)],
      );
      final watchMap = {'a': _cold, 'change': _cold};
      final explorer = _FakeExplorer()
        ..stats['a'] = _stats(1, 1)
        ..stats['change'] = _stats(0, 1)
        ..mempool['a'] = [tx];

      // Run 1: only `a` is checked before the cut-off.
      final r1 = await _run(
        explorer,
        watchMap: watchMap,
        state: _counts({
          'a': (chain: 1, mempool: 0),
          'change': (chain: 0, mempool: 0),
        }),
        mayStart: () => !explorer.log.contains('mempool a'),
        concurrency: 1,
      );
      expect(r1.alerts.map((a) => a.kind), [SentinelAlertKind.pendingOut]);

      // Run 2, 25 hours later: it confirmed; again only `a` is checked.
      explorer
        ..log.clear()
        ..stats['a'] = _stats(2, 0)
        ..stats['change'] = _stats(1, 0)
        ..mempool.clear()
        ..chain['a'] = [tx]
        ..chain['change'] = [tx];
      final r2 = await _run(
        explorer,
        watchMap: watchMap,
        seen: r1.seen,
        state: r1.state,
        mayStart: () => !explorer.log.contains('chain a'),
        concurrency: 1,
        at: _now.add(const Duration(hours: 25)),
      );
      expect(r2.alerts.map((a) => a.kind), [SentinelAlertKind.confirmed]);
      expect(explorer.log, isNot(contains('address change')));
      // Android's 24 hours would have dropped it here.
      expect(r2.seen.containsKey(spend), isTrue);

      // Run 3: the change address is checked at last.
      explorer.log.clear();
      final r3 = await _run(
        explorer,
        watchMap: watchMap,
        seen: r2.seen,
        state: r2.state,
        at: _now.add(const Duration(hours: 26)),
      );
      expect(explorer.log, contains('chain change'));
      expect(r3.alerts, isEmpty);
    });

    test('state JSON round-trips', () {
      final state = _counts({
        'a': (chain: 3, mempool: 1),
        'b': (chain: 0, mempool: 0),
      }, cursor: 7);

      final json = state.toJson();
      expect(json, {
        'c': {
          'a': [3, 1],
          'b': [0, 0],
        },
        'i': 7,
      });

      final back = IosSentinelState.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(back.counts, state.counts);
      expect(back.cursor, 7);
      expect(back.later, isEmpty, reason: "no 'l': nothing deferred");

      expect(IosSentinelState.empty.counts, isEmpty);
      expect(IosSentinelState.empty.cursor, 0);
      expect(IosSentinelState.empty.later, isEmpty);
    });

    test("deferred addresses are stored under 'l', sorted, only when there "
        'are some (R37)', () {
      final state = IosSentinelState(
        counts: {'a': (chain: 1, mempool: 0)},
        cursor: 2,
        later: {'z', 'b'},
      );

      final json = state.toJson();
      expect(json, {
        'c': {
          'a': [1, 0],
        },
        'i': 2,
        'l': ['b', 'z'],
      });

      final back = IosSentinelState.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(back.later, {'b', 'z'});
      expect(back.counts, state.counts);
      expect(back.cursor, 2);
    });
  });

  group('addresses that never answer (R37)', () {
    const rot = ['r1', 'r2', 'r3', 'r4', 'r5'];
    final seenCounts = {for (final a in rot) a: (chain: 1, mempool: 0)};
    final rotStats = {for (final a in rot) a: _stats(1, 0)};

    /// Runs the check [runs] times as `_iosSentinelPart` does over Tor, where
    /// a request can outlast the run: each `/address` request of [hanging]
    /// stays in flight; once two are (both slots taken) the request window
    /// passes, and the client's close at the save cut-off then fails them.
    /// The state is kept as the caller keeps it: when the run wasn't stopped
    /// and checked an address or moved the rotation on (R37). Returns each
    /// run's `/address` requests, in order.
    Future<List<List<String>>> hangingRuns(
      Map<String, SentinelWatchEntry> watchMap,
      Map<String, AddressStats> stats,
      Set<String> hanging,
      IosSentinelState start, {
      Set<String> hangingLists = const {},
      int runs = 3,
      void Function(int run, IosSentinelResult r)? after,
    }) async {
      var state = start;
      final perRun = <List<String>>[];
      for (var run = 0; run < runs; run++) {
        final explorer = _HangingExplorer(
          hanging,
          stats,
          hangingLists: hangingLists,
        );
        var window = true;
        explorer.onAllHanging = () {
          // The window passes while both hang; then the save cut-off closes
          // the client.
          window = false;
          Timer(Duration.zero, explorer.closed.complete);
        };
        final r = await runIosSentinelCheck(
          explorer: explorer,
          watchMap: watchMap,
          seen: const {},
          state: state,
          mayStart: () => window,
          stillOnRoute: () async => true,
          concurrency: 2,
          now: () => _now,
        );
        perRun.add(explorer.requested);
        after?.call(run, r);
        if (!r.stopped && (r.checked > 0 || r.advanced)) state = r.state;
      }
      return perRun;
    }

    test('A: two never-seen addresses that hang are deferred, and run 2 '
        'reaches the rotation', () async {
      final per = await hangingRuns(
        {for (final a in [...rot, 'h1', 'h2']) a: _cold},
        rotStats,
        {'h1', 'h2'},
        IosSentinelState(counts: seenCounts, cursor: 0),
        after: (run, r) {
          if (run == 0) {
            expect(r.checked, 0);
            expect(r.advanced, isTrue);
            expect(r.state.later, {'h1', 'h2'});
          }
        },
      );

      expect(per[0], ['h1', 'h2']);
      expect(per[1], containsAll(rot));
      expect(per[1].take(rot.length), rot, reason: 'the rotation comes first');
    });

    test('B: a healthy pending address, then two never-seen ones that hang: '
        'run 2 reaches the rotation', () async {
      final per = await hangingRuns(
        {for (final a in [...rot, 'h1', 'h2', 'p']) a: _cold},
        {...rotStats, 'p': _stats(1, 1)},
        {'h1', 'h2'},
        IosSentinelState(
          counts: {...seenCounts, 'p': (chain: 1, mempool: 1)},
          cursor: 0,
        ),
      );

      expect(per[0], ['p', 'h1', 'h2']);
      expect(per[1].first, 'p', reason: 'still pending, still first');
      expect(per[1], containsAll(rot));
    });

    test('C: two pending addresses that hang are deferred, and run 2 reaches '
        'the rotation', () async {
      final per = await hangingRuns(
        {for (final a in [...rot, 'h1', 'h2']) a: _cold},
        rotStats,
        {'h1', 'h2'},
        IosSentinelState(
          counts: {
            ...seenCounts,
            'h1': (chain: 1, mempool: 1),
            'h2': (chain: 1, mempool: 1),
          },
          cursor: 0,
        ),
        after: (run, r) {
          if (run == 0) {
            expect(r.state.later, {'h1', 'h2'});
            // Their counts stay as they were, pending included.
            expect(r.state.counts['h1'], (chain: 1, mempool: 1));
          }
        },
      );

      expect(per[0], ['h1', 'h2']);
      expect(per[1], containsAll(rot));
    });

    test('D: two seen addresses that hang at the cursor: nothing answers, '
        'but the moved cursor is kept, and run 2 reaches the rest', () async {
      // Sorted: h1 h2 r1..r5; cursor 0 starts at h1.
      final per = await hangingRuns(
        {for (final a in [...rot, 'h1', 'h2']) a: _cold},
        rotStats,
        {'h1', 'h2'},
        IosSentinelState(
          counts: {
            ...seenCounts,
            'h1': (chain: 1, mempool: 0),
            'h2': (chain: 1, mempool: 0),
          },
          cursor: 0,
        ),
        after: (run, r) {
          if (run == 0) {
            expect(r.checked, 0);
            expect(r.advanced, isTrue);
            expect(r.state.cursor, 2);
            expect(r.state.later, isEmpty, reason: 'they were in the rotation');
          }
        },
      );

      expect(per[0], ['h1', 'h2']);
      expect(per[1].take(rot.length), rot);
    });

    test('E (unchanged): on Direct two hanging never-seen addresses leave two '
        'workers for the others', () async {
      final explorer = _HangingExplorer({'h1', 'h2'}, rotStats);
      var window = true;
      final run = runIosSentinelCheck(
        explorer: explorer,
        watchMap: {for (final a in [...rot, 'h1', 'h2']) a: _cold},
        seen: const {},
        state: IosSentinelState(counts: seenCounts, cursor: 0),
        mayStart: () => window,
        stillOnRoute: () async => true,
        concurrency: 4,
        now: () => _now,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      window = false;
      explorer.closed.complete();
      final r = await run;

      expect(r.checked, 5);
      expect(r.state.later, {'h1', 'h2'});
    });

    test('R38: two pending addresses that answer but whose mempool lists hang '
        'are deferred, and run 2 reaches the rotation', () async {
      final per = await hangingRuns(
        {for (final a in [...rot, 'h1', 'h2']) a: _cold},
        {...rotStats, 'h1': _stats(1, 1), 'h2': _stats(1, 1)},
        const {},
        IosSentinelState(
          counts: {
            ...seenCounts,
            'h1': (chain: 1, mempool: 1),
            'h2': (chain: 1, mempool: 1),
          },
          cursor: 0,
        ),
        hangingLists: {'h1', 'h2'},
        after: (run, r) {
          if (run == 0) {
            expect(r.checked, 2, reason: 'their /address answered');
            expect(r.state.later, {'h1', 'h2'});
            expect(r.state.counts['h1'], (chain: 1, mempool: 1));
          }
        },
      );

      expect(per[0], ['h1', 'h2']);
      expect(per[1].take(rot.length), rot);
    });

    test('R38: a list that fails fast defers the address too, and a deferred '
        'address whose lists fail again stays deferred', () async {
      final t = _txid(0x802);
      final explorer = _FakeExplorer()
        ..stats.addAll(rotStats)
        ..stats['p'] = _stats(1, 1)
        ..stats['d'] = _stats(1, 1)
        ..mempool['p'] = [
          _tx(t, outputs: [('p', 1000)]),
        ]
        ..failingTxs.addAll({'p', 'd'});

      final r = await _run(
        explorer,
        watchMap: {for (final a in [...rot, 'p', 'd']) a: _cold},
        state: IosSentinelState(
          counts: {
            ...seenCounts,
            'p': (chain: 1, mempool: 1),
            'd': (chain: 1, mempool: 1),
          },
          cursor: 0,
          later: {'d'},
        ),
      );

      expect(explorer.log, containsAll(['mempool p', 'mempool d']));
      expect(r.state.later, {'p', 'd'});
      expect(r.alerts, isEmpty);
      expect(r.advanced, isTrue);
    });

    test('R38: a never-seen address whose list the cut-off refuses gets its '
        'baseline (R14) and is deferred; the rotation completes it and it '
        'leaves later', () async {
      final explorer = _FakeExplorer()
        ..stats.addAll(rotStats)
        ..stats['n'] = _stats(3, 1);

      final r1 = await _run(
        explorer,
        watchMap: {for (final a in [...rot, 'n']) a: _cold},
        state: IosSentinelState(counts: seenCounts, cursor: 0),
        mayStart: _untilAddressRequests(explorer, 1),
      );
      expect(explorer.log, ['address n']);
      expect(r1.state.counts['n'], (chain: 3, mempool: 0));
      expect(r1.state.later, {'n'});

      explorer.log.clear();
      final r2 = await _run(
        explorer,
        watchMap: {for (final a in [...rot, 'n']) a: _cold},
        state: r1.state,
        concurrency: 1,
      );
      expect(explorer.addressRequests.first, isNot('address n'),
          reason: 'in the rotation, not first');
      expect(explorer.log, contains('mempool n'));
      expect(r2.state.later, isEmpty);
      expect(r2.state.counts['n'], (chain: 3, mempool: 1));
    });

    test('a healthy never-seen address behind one that hangs is still checked '
        'in run 1', () async {
      final explorer = _FakeExplorer()
        ..stats.addAll(rotStats)
        ..stats['n'] = _stats(4, 0);
      final closed = Completer<void>();
      explorer
        ..holdAddress['h'] = closed
        ..failing.add('h');
      var window = true;
      final run = runIosSentinelCheck(
        explorer: explorer,
        watchMap: {for (final a in [...rot, 'h', 'n']) a: _cold},
        seen: const {},
        state: IosSentinelState(counts: seenCounts, cursor: 0),
        mayStart: () => window,
        stillOnRoute: () async => true,
        concurrency: 2,
        now: () => _now,
      );
      while (!explorer.log.contains('address r5')) {
        await Future<void>.delayed(Duration.zero);
      }
      window = false;
      closed.complete();
      final r = await run;

      expect(explorer.addressRequests.take(2), ['address h', 'address n']);
      expect(r.state.counts['n'], (chain: 4, mempool: 0));
      expect(r.state.later, {'h'});
      expect(r.checked, 6);
    });

    test('a deferred never-seen address gets its baseline when the rotation '
        'reaches it, and leaves later', () async {
      final t = _txid(0x801);
      final explorer = _FakeExplorer()
        ..stats.addAll(rotStats)
        ..stats['h'] = _stats(7, 0)
        ..chain['h'] = [
          _tx(t, outputs: [('h', 5000)]),
        ];

      final r = await _run(
        explorer,
        watchMap: {for (final a in [...rot, 'h']) a: _cold},
        // Sorted: h r1..r5; the cursor is at r1, so h comes last.
        state: IosSentinelState(counts: seenCounts, cursor: 1, later: {'h'}),
        concurrency: 1,
      );

      expect(explorer.addressRequests.last, 'address h');
      expect(r.state.counts['h'], (chain: 7, mempool: 0));
      expect(r.state.later, isEmpty);
      expect(r.alerts, isEmpty, reason: 'a first sight alerts no history');
      expect(explorer.log, isNot(contains('chain h')));
    });

    test('a deferred address that fails again stays deferred; one no longer '
        'watched is dropped', () async {
      final explorer = _FakeExplorer()
        ..stats.addAll(rotStats)
        ..failing.add('h');

      final r = await _run(
        explorer,
        watchMap: {for (final a in [...rot, 'h']) a: _cold},
        state: IosSentinelState(
          counts: seenCounts,
          cursor: 1,
          later: {'h', 'gone'},
        ),
        concurrency: 1,
      );

      expect(explorer.addressRequests, contains('address h'));
      expect(r.state.later, {'h'});
    });

    test('a run that starts nothing has not moved on', () async {
      final explorer = _FakeExplorer()..stats.addAll(rotStats);

      final r = await _run(
        explorer,
        watchMap: {for (final a in [...rot, 'new']) a: _cold},
        state: IosSentinelState(counts: seenCounts, cursor: 0),
        mayStart: () => false,
      );

      expect(explorer.log, isEmpty);
      expect(r.checked, 0);
      expect(r.advanced, isFalse);
    });

    test('a rotation that fails all round leaves the cursor where it was, so '
        'it has not moved on', () async {
      final explorer = _FakeExplorer()..failing.addAll(rot);

      final r = await _run(
        explorer,
        watchMap: {for (final a in rot) a: _cold},
        state: IosSentinelState(counts: seenCounts, cursor: 3),
      );

      expect(explorer.addressRequests, hasLength(rot.length));
      expect(r.checked, 0);
      expect(r.state.cursor, 3);
      expect(r.advanced, isFalse);
    });
  });

  test('an empty watch map checks nothing', () async {
    final explorer = _FakeExplorer();

    final r = await _run(
      explorer,
      watchMap: const {},
      state: _counts({'gone': (chain: 1, mempool: 0)}, cursor: 4),
    );

    expect(explorer.log, isEmpty);
    expect(r.checked, 0);
    expect(r.state.counts, isEmpty);
    expect(r.state.cursor, 0);
    expect(r.alerts, isEmpty);
  });
}
