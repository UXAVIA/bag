/// TorHost: one Tor client per process, shared by every isolate (Task A2).
///
/// - One isolate, a fake registry: the owner protocol, spoken by the test
///   as if from another isolate. First acquire starts and registers; a
///   second acquirer gets `starting` then the same port (Review Focus 1); a
///   dead mapping is given up after 500 ms and replaced (Review Focus 2); a
///   non-UI owner's last release stops the client and hands its
///   leaseholders over; a UI-owned client stays and follows the lifecycle;
///   dormancy and the route switch are lease-aware (R-A2b); `detached`
///   stops the UI's client (R-A2a).
/// - Real isolates over the real IsolateNameServer: the same guarantees
///   end to end, a busy owner is not mistaken for a dead one, a request
///   from an isolate that doesn't run Tor goes through the owner's port,
///   and the R-A2a sequence (Back-exit with Sentinel running → relaunch →
///   Tor off) leaves no client and never two at once.
/// - Process-wide sweeps (Task A2c): a takeover, Tor off in the UI and a
///   non-Tor launch stop every client in the process, orphans included,
///   and only there; the sweeping isolate stops its own client first, and a
///   client a sweep stopped is not restarted automatically. A takeover is
///   marked process-wide before the dead mapping goes, so whichever isolate
///   claims next sweeps, and the mark goes only with a successful sweep.
///
/// The fake native clients report every start and stop to a ledger in the
/// test isolate, standing in for the process's real native clients. A sweep
/// from any isolate goes through the ledger, which stops every client in it
/// (the fork's `Tor.stopAllInProcess()`).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:tor/tor.dart' as plugin;

import 'package:bag/models/network_route.dart';
import 'package:bag/services/embedded_tor_service.dart';
import 'package:bag/services/network/routed_http.dart';
import 'package:bag/services/tor_host.dart';
import 'package:bag/services/tor_service.dart';

import '../network/fake_proxies.dart';

/// A native client like the plugin's: a start can be held open, a stop
/// cancels a held start, and every start and stop is reported to [ledger].
/// Its sweep stops every client in the process: with a [ledger], through
/// the test isolate, which knows them all; without one, this isolate is the
/// whole process.
class _Native implements EmbeddedTorBackend, ProcessWideTorStop {
  _Native({this.socksPort = 47123, this.ledger, this.tag = 'test'});

  /// How long after its port -1 the plugin reports a lost proxy: the time
  /// its own teardown takes.
  static const reportLag = Duration(milliseconds: 50);

  int socksPort;
  final SendPort? ledger;
  final String tag;

  int startCalls = 0;
  int stopCalls = 0;
  int sweepCalls = 0;
  final List<bool> dormantCalls = [];

  /// Every start, stop and sweep, in order.
  final List<String> calls = [];

  /// A sweep waits on this.
  Completer<void>? sweepGate;

  /// A sweep throws this.
  Object? sweepError;

  /// The next read of [failures] throws (A3-M7).
  bool failuresThrow = false;

  /// A stop doesn't end a held start at once (the plugin's cancel lands
  /// late); the start still drops what it built once it returns.
  bool slowCancel = false;

  /// The next start waits on this.
  Completer<void>? hold;

  /// A stop waits on this (a native teardown that takes a while).
  Completer<void>? stopGate;
  Completer<void>? _held;
  bool _cancelled = false;
  bool _bootstrapped = false;
  final _failures = StreamController<Object>.broadcast();
  final _events = StreamController<int>.broadcast();

  void releaseStart() {
    final held = _held;
    if (held != null && !held.isCompleted) held.complete();
  }

  @override
  Stream<Object> get failures {
    if (failuresThrow) {
      failuresThrow = false;
      throw StateError('no failure stream');
    }
    return _failures.stream;
  }

  @override
  Stream<int> get events => _events.stream;

  @override
  bool get bootstrapped => _bootstrapped;

  @override
  int get port => _bootstrapped ? socksPort : -1;

  @override
  Future<int> stopAllInProcess() async {
    sweepCalls++;
    calls.add('sweep');
    final error = sweepError;
    if (error != null) throw error;
    final gate = sweepGate;
    if (gate != null) await gate.future;
    final ledger = this.ledger;
    if (ledger == null) {
      if (!_bootstrapped) return 0;
      swept();
      return 1;
    }
    final reply = ReceivePort();
    ledger.send(['sweep', tag, reply.sendPort]);
    final stopped = await reply.first as int;
    reply.close();
    return stopped;
  }

  /// A sweep (from any isolate) stopped this client, as the plugin reports
  /// it: port -1 at once, then, after its teardown, a failure that says so.
  void swept() => _die(processWideStop: true);

  /// The client dies on its own: the same signals, an ordinary failure.
  void die() => _die(processWideStop: false);

  void _die({required bool processWideStop}) {
    if (!_bootstrapped) return;
    _bootstrapped = false;
    _events.add(-1);
    Timer(reportLag, () {
      _failures.add(
        plugin.TorProxyFailure(
          processWideStop
              ? 'Tor proxy was stopped by a process-wide stop'
              : 'proxy task exited',
          processWideStop: processWideStop,
        ),
      );
    });
  }

  @override
  Future<void> start() async {
    startCalls++;
    calls.add('start');
    ledger?.send(['start', tag]);
    _cancelled = false;
    final held = _held = hold;
    hold = null;
    if (held != null) await held.future;
    if (_cancelled) return;
    _bootstrapped = true;
    ledger?.send(['up', tag]);
  }

  @override
  Future<void> bootstrap() async {}

  @override
  Future<void> setDormant(bool dormant) async => dormantCalls.add(dormant);

  @override
  Future<void> stop() async {
    stopCalls++;
    calls.add('stop');
    _bootstrapped = false;
    _cancelled = true;
    if (!slowCancel) releaseStart();
    ledger?.send(['stop', tag]);
    final gate = stopGate;
    if (gate != null) await gate.future;
  }
}

/// The IsolateNameServer's contract, in memory. The process-wide marks (a
/// Tor client has run, [TorHost.usedPortName]; a takeover not swept yet,
/// [TorHost.unsweptPortName]) are kept apart in [marks], so [names] holds
/// only an owner's mappings.
class _Registry implements TorPortRegistry {
  static const _markNames = {TorHost.usedPortName, TorHost.unsweptPortName};

  final Map<String, SendPort> names = {};
  final Map<String, SendPort> marks = {};

  SendPort? get used => marks[TorHost.usedPortName];
  SendPort? get unswept => marks[TorHost.unsweptPortName];

  Map<String, SendPort> _holding(String name) =>
      _markNames.contains(name) ? marks : names;

  @override
  SendPort? lookup(String name) => _holding(name)[name];

  @override
  bool register(SendPort port, String name) {
    final map = _holding(name);
    if (map.containsKey(name)) return false;
    map[name] = port;
    return true;
  }

  @override
  bool remove(String name) => _holding(name).remove(name) != null;
}

/// A mark as another isolate registers one: a port of its own, closed.
SendPort _mark() {
  final port = RawReceivePort();
  final send = port.sendPort;
  port.close();
  return send;
}

/// Another isolate, simulated by the test speaking the owner protocol.
class _Remote {
  _Remote(this.owner) {
    _port.listen((m) => _inbox.add(m as Map));
  }

  final SendPort owner;
  final _port = ReceivePort();
  final _inbox = StreamController<Map>();
  late final _messages = StreamIterator(_inbox.stream);

  void acquire({bool ui = false}) => owner.send({
    'op': 'acquire',
    'reply': _port.sendPort,
    if (ui) 'ui': true,
  });

  void release() => owner.send({'op': 'release', 'reply': _port.sendPort});

  /// The next message from the owner.
  Future<Map> next() async {
    final more = await _messages.moveNext().timeout(const Duration(seconds: 5));
    expect(more, isTrue);
    return _messages.current;
  }

  /// No message arrives for a while.
  Future<void> expectSilence() async {
    final more = _messages.moveNext().timeout(
      const Duration(milliseconds: 200),
      onTimeout: () => false,
    );
    expect(await more, isFalse, reason: 'unexpected message from the owner');
  }

  void close() {
    _port.close();
    _inbox.close();
  }
}

/// testWidgets-free tests still get real HttpClients through this.
class _RealHttp extends HttpOverrides {}

/// GETs `http://bag-test.invalid:<port>/` over [TorRoute]. `.invalid` never
/// resolves (RFC 6761), so a hit proves the SOCKS proxy did.
Future<int> _get(int port) => HttpOverrides.runWithHttpOverrides(() async {
  final c = routeHttpClient(HttpClient(), const TorRoute());
  try {
    final request = await c.getUrl(Uri.parse('http://bag-test.invalid:$port/'));
    request.persistentConnection = false;
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    c.close(force: true);
  }
}, _RealHttp());

Matcher get _torNotConnected => throwsA(
  isA<SocketException>().having(
    (e) => e.message,
    'message',
    'Tor is not connected',
  ),
);

/// Polls [condition] until it holds.
Future<void> _until(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String reason = '',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// The route re-check a caller passes to [TorHost.acquire]: Tor still on.
Future<bool> _yes() async => true;

/// The plugin as the A2 review modelled it (the fork's `lib/tor.dart` before
/// A2b's eager native stop): a `Tor.init()` gap before `start()`, in which a
/// stop cancels nothing (N1), and one serialised lifecycle queue
/// (`TorLifecycleGate`) that `setClientDormant`, `start` and the native
/// teardown of `stop()` all wait in, in order.
class _PluginLike implements EmbeddedTorBackend, ProcessWideTorStop {
  /// Sweeps asked for (none of these cases may sweep).
  int sweepCalls = 0;

  @override
  Future<int> stopAllInProcess() async {
    sweepCalls++;
    return 0;
  }

  /// `Tor.init()` hasn't returned yet.
  Completer<void>? initGate;

  /// A `setClientDormant` whose FRB result hasn't come back yet.
  Completer<void>? dormantGate;

  /// Created on first use, in the zone of the test that uses it (a future
  /// completed in another zone would schedule its callbacks there, out of
  /// fakeAsync's reach).
  Future<void>? _tail;
  int startCalls = 0;

  /// `Tor.stop()` calls (Dart level).
  int stopCalls = 0;

  /// Native teardowns that ran on a client that was up.
  int nativeStops = 0;
  final List<bool> dormantCalls = [];
  bool _bootstrapped = false;
  int _generation = 0;
  final _failures = StreamController<Object>.broadcast();
  final _events = StreamController<int>.broadcast();

  Future<T> _run<T>(Future<T> Function() operation) {
    final result = (_tail ?? Future<void>.value()).then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<void> start() async {
    startCalls++;
    final init = initGate;
    if (init != null) await init.future;
    // Captured only once start() runs (N1).
    final generation = _generation;
    await _run(() async {
      if (generation == _generation) _bootstrapped = true;
    });
  }

  @override
  Future<void> bootstrap() async {}

  @override
  bool get bootstrapped => _bootstrapped;

  @override
  int get port => _bootstrapped ? 47123 : -1;

  @override
  Future<void> setDormant(bool dormant) {
    dormantCalls.add(dormant);
    return _run(() async {
      final gate = dormantGate;
      if (gate != null) await gate.future;
    });
  }

  @override
  Future<void> stop() {
    stopCalls++;
    _generation++;
    final wasUp = _bootstrapped;
    _bootstrapped = false;
    return _run(() async {
      if (wasUp) nativeStops++;
    });
  }

  @override
  Stream<Object> get failures => _failures.stream;

  @override
  Stream<int> get events => _events.stream;
}

/// A registry in which another isolate's registration replaces this one's
/// a few milliseconds after it took over a dead mapping: the double
/// takeover (M1).
class _RacingRegistry extends _Registry {
  /// The racer's port, used once.
  SendPort? racer;

  @override
  bool register(SendPort port, String name) {
    final registered = super.register(port, name);
    final other = racer;
    if (registered && name == TorHost.portName && other != null) {
      racer = null;
      Timer(const Duration(milliseconds: 5), () {
        names[TorHost.portName] = other;
      });
    }
    return registered;
  }
}

/// Records, at each removal of an owner mapping in [dead], whether the
/// unswept mark was already registered: the mark must come first, or an
/// isolate that claims the freed mapping meanwhile sees no takeover.
class _OrderRegistry extends _Registry {
  final Set<SendPort> dead = {};
  final List<bool> markedFirst = [];

  @override
  bool remove(String name) {
    final port = names[name];
    if (name == TorHost.portName && port != null && dead.contains(port)) {
      markedFirst.add(unswept != null);
    }
    return super.remove(name);
  }
}

/// On the first lookup of the owner mapping that finds none, registers a
/// mark just before answering: another isolate marked the process and
/// removed a dead mapping between a read of the mark taken before the
/// claim and the claim itself.
class _MarkOnLookupRegistry extends _Registry {
  bool armed = true;

  @override
  SendPort? lookup(String name) {
    final found = super.lookup(name);
    if (armed && name == TorHost.portName && found == null) {
      armed = false;
      register(_mark(), TorHost.unsweptPortName);
    }
    return found;
  }
}

/// An owner in another isolate, played by the test: answers each request
/// through [onRequest].
class _FakeOwner {
  _FakeOwner(this.onRequest) {
    _port.handler = (Object? m) => onRequest(m as Map);
  }

  final void Function(Map request) onRequest;
  final _port = RawReceivePort();

  SendPort get sendPort => _port.sendPort;

  void close() => _port.close();
}

// ── A peer isolate running TorHost, driven by commands ─────────────────────

/// Another isolate of the process (the UI, Sentinel or a WorkManager job),
/// with its own EmbeddedTorService, TorHost and fake native client, over the
/// real IsolateNameServer.
class _Peer {
  _Peer._(this.tag, this.isolate, this._commands, this._exit);

  final String tag;
  final Isolate isolate;
  final SendPort _commands;
  final ReceivePort _exit;

  /// Killed: its client, if any, is an orphan only a sweep reaches.
  bool dead = false;

  static Future<_Peer> spawn(
    String tag, {
    required SendPort ledger,
    required int socksPort,
  }) async {
    final hello = ReceivePort();
    final exit = ReceivePort();
    final isolate = await Isolate.spawn(_peerMain, [
      hello.sendPort,
      ledger,
      tag,
      socksPort,
    ], onExit: exit.sendPort);
    final commands = await hello.first as SendPort;
    return _Peer._(tag, isolate, commands, exit);
  }

  Future<Map> call(String cmd, [Map<String, Object?> args = const {}]) async {
    final reply = ReceivePort();
    _commands.send({...args, 'cmd': cmd, 'reply': reply.sendPort});
    final answer = await reply.first.timeout(const Duration(seconds: 15));
    return answer as Map;
  }

  /// Sends [cmd] without waiting for its answer.
  void post(String cmd, [Map<String, Object?> args = const {}]) {
    final reply = ReceivePort();
    _commands.send({...args, 'cmd': cmd, 'reply': reply.sendPort});
    reply.first.then((_) => reply.close());
  }

  Future<Map> status() => call('status');

  /// Kills the isolate the way the OS ends an engine: no release, no
  /// detached, nothing more runs in it.
  Future<void> kill() async {
    dead = true;
    isolate.kill(priority: Isolate.immediate);
    await _exit.first.timeout(const Duration(seconds: 5));
  }
}

void _peerMain(List<Object?> args) {
  final hello = args[0]! as SendPort;
  final native = _Native(
    ledger: args[1]! as SendPort,
    tag: args[2]! as String,
    socksPort: args[3]! as int,
  );
  EmbeddedTorService.debugBackend = native;
  TorHostLease? lease;

  Future<Map<String, Object?>> status() async => {
    'state': EmbeddedTorService.state.name,
    'port': EmbeddedTorService.port,
    'hostPort': await TorHost.port(),
    'owns': lease?.ownsClient,
    'startCalls': native.startCalls,
    'stopCalls': native.stopCalls,
  };

  final commands = ReceivePort();
  hello.send(commands.sendPort);
  commands.listen((message) async {
    final m = message as Map;
    final reply = m['reply'] as SendPort;
    switch (m['cmd']) {
      case 'hold':
        native.hold = Completer<void>();
      case 'releaseStart':
        native.releaseStart();
      case 'acquire':
        // With 'torReads', the route check says Tor that many times only.
        final reads = m['torReads'];
        var read = 0;
        lease = await TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 10),
          stillTor: reads is int ? () async => ++read <= reads : _yes,
        );
      case 'release':
        await lease?.release();
      case 'followRoute':
        TorService.followRoute(
          m['tor'] == true ? const TorRoute() : const DirectRoute(),
        );
      case 'detached':
        TorHost.onDetached();
      case 'swept':
        native.swept();
      case 'busy':
        // Pure Dart work: the event loop is blocked, the VM is not.
        final sw = Stopwatch()..start();
        while (sw.elapsedMilliseconds < (m['ms'] as int)) {}
    }
    reply.send(await status());
  });
}

void main() {
  // ── One isolate, fake registry ──────────────────────────────────────────

  group('the owner protocol (one isolate, fake registry)', () {
    late _Registry registry;
    late _Native native;
    final remotes = <_Remote>[];

    _Remote remote() {
      final owner = registry.lookup(TorHost.portName);
      expect(owner, isNotNull, reason: 'no owner registered');
      final r = _Remote(owner!);
      remotes.add(r);
      return r;
    }

    setUp(() {
      registry = _Registry();
      TorHost.debugRegistry = registry;
      // The sleep after `paused` is deferred (I1); these cases run in real
      // time, so a short delay. The plugin-queue group uses the real one.
      TorHost.debugSleepDelay = const Duration(milliseconds: 50);
      native = _Native();
      EmbeddedTorService.debugBackend = native;
    });

    tearDown(() async {
      native.releaseStart();
      for (final r in remotes) {
        r.close();
      }
      remotes.clear();
      await EmbeddedTorService.stop();
      EmbeddedTorService.debugReset();
      EmbeddedTorService.debugBackend = null;
      TorHost.debugRegistry = null;
      TorHost.debugSleepDelay = null;
    });

    test('the first acquire with no owner starts the client, registers, and '
        'returns its port once ready', () async {
      native.hold = Completer<void>();
      final acquiring = TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      await pumpEventQueue();

      expect(native.startCalls, 1);
      expect(registry.lookup(TorHost.portName), isNotNull);
      expect(
        registry.lookup(TorHost.isolatePortName),
        Isolate.current.controlPort,
      );
      expect(await TorHost.port(), -1);

      native.releaseStart();
      final lease = await acquiring;
      expect(lease.ownsClient, isTrue);
      expect(lease.port, 47123);
      expect(await TorHost.port(), 47123);
      expect(await TorHost.port(), 47123);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    });

    test('an acquire that does not get ready within its budget returns the '
        'lease anyway, with port -1 until it is', () async {
      native.hold = Completer<void>();
      final lease = await TorHost.acquire(
        bootstrapBudget: const Duration(milliseconds: 50),
        stillTor: _yes,
      );
      expect(lease.port, -1);
      expect(await TorHost.port(), -1);
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);

      native.releaseStart();
      await pumpEventQueue();
      expect(lease.port, 47123);
    });

    test('a second isolate acquiring while the owner starts gets "starting", '
        'then the same port; one native start (Review Focus 1)', () async {
      native.hold = Completer<void>();
      final acquiring = TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      await pumpEventQueue();

      final other = remote()..acquire();
      final first = await other.next();
      expect(first['state'], 'starting');
      expect(first['port'], -1);

      native.releaseStart();
      await acquiring;
      final second = await other.next();
      expect(second['state'], 'ready');
      expect(second['port'], 47123);
      expect(native.startCalls, 1);
    });

    test('a dead mapping: the lookup gives up after 500 ms, removes it and '
        'this isolate becomes the owner; port() is -1 until its own client '
        'is ready (Review Focus 2)', () async {
      final dead = RawReceivePort();
      final deadPort = dead.sendPort;
      dead.close();
      registry.register(deadPort, TorHost.portName);

      native.hold = Completer<void>();
      final clock = Stopwatch()..start();
      final acquiring = TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );

      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(native.startCalls, 0, reason: 'started before the timeout');
      expect(registry.lookup(TorHost.portName), deadPort);
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(await TorHost.port(), -1);
      await expectLater(_get(1), _torNotConnected);

      await _until(() => native.startCalls == 1, reason: 'takeover');
      expect(clock.elapsed, greaterThanOrEqualTo(TorHost.lookupTimeout));
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      final mine = registry.lookup(TorHost.portName);
      expect(mine, isNotNull);
      expect(mine, isNot(deadPort));
      expect(await TorHost.port(), -1, reason: 'own client still starting');

      native.releaseStart();
      final lease = await acquiring;
      expect(lease.ownsClient, isTrue);
      expect(await TorHost.port(), 47123);
    });

    test('a mapping that answers is leased, not replaced', () async {
      final live = RawReceivePort();
      live.handler = (Object? m) {
        final reply = (m as Map)['reply'];
        if (reply is SendPort) reply.send({'state': 'ready', 'port': 47999});
      };
      addTearDown(live.close);
      registry.register(live.sendPort, TorHost.portName);

      final lease = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      expect(lease.ownsClient, isFalse);
      expect(native.startCalls, 0);
      expect(registry.lookup(TorHost.portName), live.sendPort);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(lease.port, 47999);
      expect(await TorHost.port(), 47999);
    });

    test('the last lease released by a non-UI owner stops the client and '
        'unregisters', () async {
      final lease = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      expect(lease.ownsClient, isTrue);

      await lease.release();
      expect(native.stopCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(registry.names, isEmpty);
      expect(lease.port, -1);
      expect(lease.ownsClient, isFalse);
      expect(await TorHost.port(), -1);
    });

    test('a lease released while another is held keeps the client', () async {
      final a = await TorHost.acquire(
        bootstrapBudget: Duration.zero,
        stillTor: _yes,
      );
      final b = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      await a.release();
      expect(native.stopCalls, 0);
      expect(b.port, 47123);

      await b.release();
      expect(native.stopCalls, 1);
    });

    test('a non-UI owner leaving with a leaseholder hands over: "gone" first, '
        'the mapping only after the client has stopped', () async {
      final lease = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      final other = remote()..acquire();
      expect((await other.next())['state'], 'ready');

      final stopping = native.stopGate = Completer<void>();
      final releasing = lease.release();
      expect((await other.next())['state'], 'gone');
      expect(native.stopCalls, 1);
      // Asked again while the client is still stopping: gone again, and the
      // mapping stays, so nobody starts a second client next to this one.
      other.acquire();
      expect((await other.next())['state'], 'gone');
      expect(registry.lookup(TorHost.portName), isNotNull);

      stopping.complete();
      await releasing;
      expect(registry.names, isEmpty);
      expect(native.stopCalls, 1);
      expect(native.startCalls, 1);
    });

    test('a UI-owned client is kept when a lease is released, and follows '
        'the app lifecycle (R6/R7 unchanged)', () async {
      TorService.followRoute(const TorRoute());
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);

      final lease = await TorHost.acquire(
        bootstrapBudget: Duration.zero,
        stillTor: _yes,
      );
      await lease.release();
      expect(native.stopCalls, 0);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(registry.lookup(TorHost.portName), isNotNull);

      await EmbeddedTorService.onPause();
      expect(native.dormantCalls, isEmpty, reason: 'the sleep waits (I1)');
      await _until(() => native.dormantCalls.length == 1);
      await EmbeddedTorService.onResume();
      expect(native.dormantCalls, [true, false]);
      expect(native.startCalls, 1);
    });

    test(
      'dormancy is lease-aware: paused with a leaseholder stays awake, '
      'sleeps on the last release, wakes on the next acquire (R-A2b)',
      () async {
        TorService.followRoute(const TorRoute());
        await pumpEventQueue();
        final other = remote()..acquire();
        expect((await other.next())['state'], 'ready');

        await EmbeddedTorService.onPause();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(native.dormantCalls, isEmpty, reason: 'another isolate uses it');

        other.release();
        await _until(() => native.dormantCalls.length == 1);
        expect(native.dormantCalls, [true]);

        other.acquire();
        expect((await other.next())['state'], 'ready');
        expect(native.dormantCalls, [true, false]);

        other.release();
        await _until(() => native.dormantCalls.length == 3);
        expect(native.dormantCalls, [true, false, true]);

        await EmbeddedTorService.onResume();
        expect(native.dormantCalls, [true, false, true, false]);
        // Back in the foreground: a release no longer puts it to sleep.
        other.acquire();
        await other.next();
        other.release();
        await other.expectSilence();
        expect(native.dormantCalls, [true, false, true, false]);
        expect(native.startCalls, 1);
      },
    );

    test('switching away from Tor stops the client whatever leases exist; the '
        'leaseholder hears "off", and port() is -1 (R-A2b)', () async {
      TorService.followRoute(const TorRoute());
      await pumpEventQueue();
      final other = remote()..acquire();
      expect((await other.next())['state'], 'ready');

      TorService.followRoute(const DirectRoute());
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(await TorHost.port(), -1);
      final off = await other.next();
      expect(off['state'], 'off');
      expect(off['port'], -1);
      expect(native.stopCalls, 1);

      // A leaseholder acting on a stale route read is told off; nothing
      // starts again until the UI's route is Tor.
      other.acquire();
      expect((await other.next())['state'], 'off');
      expect(native.startCalls, 1);
    });

    test(
      'detached: the UI stops its client even with a leaseholder, which is '
      'told "gone"; the mapping goes once the client has stopped (R-A2a)',
      () async {
        TorService.followRoute(const TorRoute());
        await pumpEventQueue();
        final other = remote()..acquire();
        expect((await other.next())['state'], 'ready');

        TorHost.onDetached();
        // Issued at once: the isolate may not run another event.
        expect(native.stopCalls, 1);
        expect(EmbeddedTorService.state, EmbeddedTorState.off);
        expect((await other.next())['state'], 'gone');
        await pumpEventQueue();
        expect(registry.names, isEmpty);
      },
    );
  });

  // ── Real isolates, real IsolateNameServer ───────────────────────────────

  group('across real isolates', () {
    late ReceivePort ledgerPort;
    late List<List<Object?>> ledger;
    late _Native native;
    final peers = <_Peer>[];
    final closers = <Future<void> Function()>[];

    Future<_Peer> peer(String tag, {int socksPort = 47001}) async {
      final p = await _Peer.spawn(
        tag,
        ledger: ledgerPort.sendPort,
        socksPort: socksPort,
      );
      peers.add(p);
      return p;
    }

    /// Native clients up at the end of [ledger], and the most ever up at
    /// once.
    (Set<String>, int) liveClients() {
      final live = <String>{};
      var most = 0;
      for (final [event, tag] in ledger) {
        if (event == 'up') live.add(tag! as String);
        if (event == 'stop' || event == 'swept') live.remove(tag);
        if (live.length > most) most = live.length;
      }
      return (live, most);
    }

    /// The process's sweep, as the fork runs it: every client up in the
    /// ledger stops, a dead isolate's (an orphan) included, and a live
    /// isolate's client reports the loss as a process-wide stop.
    void sweep(String tag, SendPort reply) {
      ledger.add(['sweep', tag]);
      final (live, _) = liveClients();
      for (final up in live) {
        ledger.add(['swept', up]);
        if (up == native.tag) {
          native.swept();
        } else {
          for (final p in peers) {
            if (p.tag == up && !p.dead) p.post('swept');
          }
        }
      }
      reply.send(live.length);
    }

    void removeMappings() {
      IsolateNameServer.removePortNameMapping(TorHost.portName);
      IsolateNameServer.removePortNameMapping(TorHost.isolatePortName);
      IsolateNameServer.removePortNameMapping(TorHost.usedPortName);
      IsolateNameServer.removePortNameMapping(TorHost.unsweptPortName);
    }

    setUp(() {
      removeMappings();
      ledger = [];
      ledgerPort = ReceivePort()
        ..listen((m) {
          final entry = m as List<Object?>;
          if (entry[0] == 'sweep') {
            sweep(entry[1]! as String, entry[2]! as SendPort);
          } else {
            ledger.add(entry);
          }
        });
      native = _Native(ledger: ledgerPort.sendPort, tag: 'test');
      EmbeddedTorService.debugBackend = native;
    });

    tearDown(() async {
      // This isolate first, so a peer's exit can't start a takeover here.
      native.releaseStart();
      await EmbeddedTorService.stop();
      EmbeddedTorService.debugReset();
      EmbeddedTorService.debugBackend = null;
      for (final p in peers) {
        p.isolate.kill(priority: Isolate.immediate);
      }
      peers.clear();
      for (final close in closers.reversed) {
        await close();
      }
      closers.clear();
      ledgerPort.close();
      removeMappings();
    });

    test(
      'Review Focus 1: the user opens Bag while the WorkManager job is '
      'bootstrapping → one native client, and the UI uses its port',
      () async {
        final wm = await peer('wm');
        await wm.call('hold');
        wm.post('acquire');
        await _until(
          () async => (await wm.status())['startCalls'] == 1,
          reason: 'wm starts',
        );

        // The UI launches with Tor on.
        TorService.followRoute(const TorRoute());
        expect(EmbeddedTorService.state, EmbeddedTorState.starting);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(native.startCalls, 0);
        expect(await TorHost.port(), -1);
        await expectLater(_get(1), _torNotConnected);

        await wm.call('releaseStart');
        await _until(
          () => EmbeddedTorService.state == EmbeddedTorState.ready,
          reason: 'the UI sees the job\'s client ready',
        );
        expect(EmbeddedTorService.port, 47001);
        expect(await TorHost.port(), 47001);
        expect(native.startCalls, 0);
        expect((await wm.status())['startCalls'], 1);
        expect(liveClients().$2, 1);
      },
    );

    test('a request from an isolate that does not run Tor goes through the '
        'owner\'s port', () async {
      final target = await TargetServer.start();
      closers.add(target.close);
      final proxy = await FakeSocks5Proxy.start(targetPort: target.port);
      closers.add(proxy.close);
      final sentinel = await peer('sentinel', socksPort: proxy.port);
      expect((await sentinel.call('acquire'))['state'], 'ready');

      final lease = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      expect(lease.ownsClient, isFalse);
      expect(lease.port, proxy.port);

      expect(await _get(target.port), 200);
      expect(proxy.connectHosts, ['bag-test.invalid']);
      expect(target.hits, 1);
      expect(native.startCalls, 0);
    });

    test('a busy owner is not mistaken for a dead one: its control port '
        'answers at once, and the acquirer waits for it', () async {
      final sentinel = await peer('sentinel');
      expect((await sentinel.call('acquire'))['state'], 'ready');

      sentinel.post('busy', {'ms': 1500});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final clock = Stopwatch()..start();
      final lease = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 10),
        stillTor: _yes,
      );
      expect(clock.elapsed, greaterThan(const Duration(milliseconds: 900)));
      expect(lease.ownsClient, isFalse);
      expect(native.startCalls, 0);
      expect(lease.port, 47001);
      expect(liveClients().$2, 1);
    });

    test('the previous owner died while its client may still run: the next '
        'isolate takes over after 500 ms and never uses the dead client\'s '
        'port (R-A2a, Review Focus 2)', () async {
      final target = await TargetServer.start();
      closers.add(target.close);
      final orphan = await FakeSocks5Proxy.start(targetPort: target.port);
      closers.add(orphan.close);
      final own = await FakeSocks5Proxy.start(targetPort: target.port);
      closers.add(own.close);
      native.socksPort = own.port;

      final wm = await peer('wm', socksPort: orphan.port);
      expect((await wm.call('acquire'))['state'], 'ready');
      // The OS ends the job's engine: no release, no detached. Its native
      // client may still be listening; nothing can reach it any more.
      await wm.kill();
      expect(IsolateNameServer.lookupPortByName(TorHost.portName), isNotNull);

      native.hold = Completer<void>();
      final clock = Stopwatch()..start();
      TorService.followRoute(const TorRoute());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(native.startCalls, 0);
      expect(await TorHost.port(), -1);
      await expectLater(_get(target.port), _torNotConnected);

      await _until(() => native.startCalls == 1, reason: 'takeover');
      expect(clock.elapsed, greaterThanOrEqualTo(TorHost.lookupTimeout));
      expect(await TorHost.port(), -1, reason: 'own client still starting');
      await expectLater(_get(target.port), _torNotConnected);

      native.releaseStart();
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.ready);
      expect(await _get(target.port), 200);
      expect(own.connectHosts, ['bag-test.invalid']);
      expect(orphan.connections, 0);

      // Tor off stops the client this isolate can reach.
      TorService.followRoute(const DirectRoute());
      expect(native.stopCalls, 1);
      expect(await TorHost.port(), -1);
      expect(orphan.connections, 0);
    });

    test('a leaseholder whose owner dies takes over', () async {
      final sentinel = await peer('sentinel');
      expect((await sentinel.call('acquire'))['state'], 'ready');
      TorService.followRoute(const TorRoute());
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.ready);
      expect(native.startCalls, 0);

      await sentinel.kill();
      await _until(
        () => native.startCalls == 1,
        reason: 'the exit takes the leaseholder over',
      );
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.ready);
      expect(await TorHost.port(), 47123);
    });

    test('R-A2a: Back-exit with Sentinel running → relaunch → Tor off leaves '
        'no client, and there are never two at once', () async {
      // The UI owns the client; Sentinel (this isolate) leases it.
      final ui = await peer('ui-1');
      expect(
        (await ui.call('followRoute', {'tor': true}))['state'],
        anyOf('starting', 'ready'),
      );
      await _until(
        () async => (await ui.status())['state'] == 'ready',
        reason: 'ui ready',
      );
      final sentinel = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      expect(sentinel.ownsClient, isFalse);
      expect(native.startCalls, 0);

      // Back at the root (Android 7–11): detached, then the engine goes.
      await ui.call('detached');
      await _until(
        () =>
            native.startCalls == 1 &&
            EmbeddedTorService.state == EmbeddedTorState.ready,
        reason: 'Sentinel takes over',
      );
      expect(sentinel.ownsClient, isTrue);
      await ui.kill();

      // Relaunch: the new UI leases Sentinel's client.
      final relaunched = await peer('ui-2');
      await relaunched.call('followRoute', {'tor': true});
      await _until(
        () async => (await relaunched.status())['state'] == 'ready',
        reason: 'the new UI is ready',
      );
      final status = await relaunched.status();
      expect(status['startCalls'], 0);
      expect(status['hostPort'], 47123);

      // Tor off in the new UI stops Sentinel's client.
      await relaunched.call('followRoute', {'tor': false});
      await _until(
        () => EmbeddedTorService.state == EmbeddedTorState.off,
        reason: 'Sentinel\'s client stops',
      );
      expect(sentinel.port, -1);
      expect(await TorHost.port(), -1);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final (live, most) = liveClients();
      expect(live, isEmpty, reason: '$ledger');
      expect(most, 1, reason: '$ledger');
      // ui-1's stop came before Sentinel's start.
      final stopUi = ledger.indexWhere((e) => e[0] == 'stop' && e[1] == 'ui-1');
      final startTest = ledger.indexWhere(
        (e) => e[0] == 'start' && e[1] == 'test',
      );
      expect(stopUi, lessThan(startTest), reason: '$ledger');
    });

    test(
      'R-A2e closed: a WorkManager engine destroyed mid-job leaves its client '
      'running; the next owner sweeps it before starting its own, so there '
      'is never a second client, and Tor off leaves none (R-A2c-b)',
      () async {
        final wm = await peer('wm');
        expect((await wm.call('acquire'))['state'], 'ready');
        // onStopped: the engine goes with no Dart callback at all.
        await wm.kill();
        expect(liveClients().$1, {'wm'}, reason: 'the orphan');

        TorService.followRoute(const TorRoute());
        await _until(
          () => EmbeddedTorService.state == EmbeddedTorState.ready,
          reason: 'the UI takes over',
        );
        await _until(
          () => liveClients().$1.contains('test'),
          reason: 'the ledger hears of it',
        );
        final (live, most) = liveClients();
        expect(live, {'test'}, reason: '$ledger');
        expect(most, 1, reason: '$ledger');
        final swept = ledger.indexWhere((e) => e[0] == 'swept');
        final start = ledger.indexWhere(
          (e) => e[0] == 'start' && e[1] == 'test',
        );
        expect(ledger[swept], ['swept', 'wm']);
        expect(swept, lessThan(start), reason: '$ledger');
        expect(native.sweepCalls, 1);

        // Tor off: this isolate's client stops first, then the sweep finds
        // nothing more.
        TorService.followRoute(const DirectRoute());
        await _until(() => native.sweepCalls == 2, reason: 'the second sweep');
        await _until(() => ledger.last[0] == 'sweep', reason: '$ledger');
        expect(liveClients().$1, isEmpty, reason: '$ledger');
        expect(
          ledger.indexWhere((e) => e[0] == 'stop' && e[1] == 'test'),
          lessThan(ledger.lastIndexWhere((e) => e[0] == 'sweep')),
          reason: '$ledger',
        );
        expect(native.startCalls, 1);
      },
    );

    test('Tor off in the UI while Sentinel runs the client: whichever of the '
        'UI\'s stop and its sweep reaches Sentinel first, its client stops '
        'and is not restarted, and nothing is left', () async {
      final sentinel = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      expect(sentinel.ownsClient, isTrue);
      final ui = await peer('ui');
      await ui.call('followRoute', {'tor': true});
      await _until(
        () async => (await ui.status())['state'] == 'ready',
        reason: 'the UI leases Sentinel\'s client',
      );

      await ui.call('followRoute', {'tor': false});
      await _until(
        () => EmbeddedTorService.state != EmbeddedTorState.ready,
        reason: 'Sentinel\'s client goes',
      );
      await Future<void>.delayed(_Native.reportLag * 6);
      expect(native.startCalls, 1, reason: '$ledger');
      expect(liveClients().$1, isEmpty, reason: '$ledger');
      expect(ledger.where((e) => e[0] == 'sweep'), hasLength(1));
      expect(await TorHost.port(), -1);
    });

    test(
      'the isolate that removed a dead owner\'s mapping reads the route '
      'switched off before it sweeps: the next start, the UI\'s in another '
      'isolate, sweeps the orphan before its own start (unswept mark)',
      () async {
        final wm = await peer('wm');
        expect((await wm.call('acquire'))['state'], 'ready');
        await wm.kill();
        expect(liveClients().$1, {'wm'}, reason: 'the orphan');

        // Sentinel finds the job dead and removes its mapping; its next route
        // check says Tor is off, so it claims nothing and sweeps nothing.
        final sentinel = await peer('sentinel');
        final gaveUp = await sentinel.call('acquire', {'torReads': 1});
        expect(gaveUp['state'], 'failed');
        expect(gaveUp['startCalls'], 0);
        expect(IsolateNameServer.lookupPortByName(TorHost.portName), isNull);
        expect(
          IsolateNameServer.lookupPortByName(TorHost.unsweptPortName),
          isNotNull,
          reason: 'the takeover is not swept yet',
        );
        expect(ledger.where((e) => e[0] == 'sweep'), isEmpty);

        // The UI claims a free mapping: a fresh claim, which still sweeps.
        TorService.followRoute(const TorRoute());
        await _until(
          () => EmbeddedTorService.state == EmbeddedTorState.ready,
          reason: 'the UI starts',
        );
        await _until(
          () => liveClients().$1.contains('test'),
          reason: 'the ledger hears of it',
        );
        final (live, most) = liveClients();
        expect(live, {'test'}, reason: '$ledger');
        expect(most, 1, reason: '$ledger');
        expect(
          ledger.indexWhere((e) => e[0] == 'swept' && e[1] == 'wm'),
          lessThan(ledger.indexWhere((e) => e[0] == 'start' && e[1] == 'test')),
          reason: '$ledger',
        );
        expect(native.sweepCalls, 1);
        expect(
          IsolateNameServer.lookupPortByName(TorHost.unsweptPortName),
          isNull,
          reason: 'swept: the mark goes',
        );
      },
    );
  });

  // ── Fix round 1: the plugin's queue, sticky off, races ──────────────────

  group('fix round 1 (fake registry)', () {
    late _Registry registry;
    late _PluginLike plugin;
    final closers = <void Function()>[];

    setUp(() {
      registry = _Registry();
      TorHost.debugRegistry = registry;
      plugin = _PluginLike();
      EmbeddedTorService.debugBackend = plugin;
    });

    tearDown(() async {
      for (final gate in [plugin.initGate, plugin.dormantGate]) {
        if (gate != null && !gate.isCompleted) gate.complete();
      }
      for (final close in closers) {
        close();
      }
      closers.clear();
      await EmbeddedTorService.stop();
      EmbeddedTorService.debugReset();
      EmbeddedTorService.debugBackend = null;
      TorHost.debugRegistry = null;
    });

    _FakeOwner fakeOwner(void Function(Map request) onRequest) {
      final owner = _FakeOwner(onRequest);
      closers.add(owner.close);
      registry.register(owner.sendPort, TorHost.portName);
      return owner;
    }

    test('detached right after paused: the native stop runs at once, with no '
        'sleep ahead of it in the plugin\'s queue (I1)', () {
      fakeAsync((async) {
        TorService.followRoute(const TorRoute());
        async.flushMicrotasks();
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);
        // A sleep issued now would hold the queue until after teardown.
        plugin.dormantGate = Completer<void>();

        EmbeddedTorService.onPause();
        async.flushMicrotasks();
        expect(plugin.dormantCalls, isEmpty);
        TorHost.onDetached();
        async.flushMicrotasks();
        expect(plugin.nativeStops, 1);

        async.elapse(TorHost.sleepDelay * 2);
        expect(plugin.dormantCalls, isEmpty);
      });
    });

    test('detached 1.9 s after paused: the sleep never went out, and the '
        'native stop runs (I1)', () {
      fakeAsync((async) {
        TorService.followRoute(const TorRoute());
        async.flushMicrotasks();
        plugin.dormantGate = Completer<void>();

        EmbeddedTorService.onPause();
        async.elapse(const Duration(milliseconds: 1900));
        expect(plugin.dormantCalls, isEmpty);
        TorHost.onDetached();
        async.flushMicrotasks();
        expect(plugin.nativeStops, 1);
        async.elapse(TorHost.sleepDelay);
        expect(plugin.dormantCalls, isEmpty);
      });
    });

    test('the sleep goes out 2 s after paused, only while still in the '
        'background; a resume, a route change or a stop cancels it (I1)', () {
      fakeAsync((async) {
        TorService.followRoute(const TorRoute());
        async.flushMicrotasks();

        EmbeddedTorService.onPause();
        async.elapse(TorHost.sleepDelay - const Duration(milliseconds: 1));
        expect(plugin.dormantCalls, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(plugin.dormantCalls, [true]);
        EmbeddedTorService.onResume();
        async.flushMicrotasks();
        expect(plugin.dormantCalls, [true, false]);

        // Back within 2 s: nothing goes into the plugin's queue at all.
        EmbeddedTorService.onPause();
        async.elapse(const Duration(seconds: 1));
        EmbeddedTorService.onResume();
        async.elapse(TorHost.sleepDelay * 2);
        expect(plugin.dormantCalls, [true, false]);

        // Switched away from Tor while paused: no sleep after the stop.
        EmbeddedTorService.onPause();
        async.flushMicrotasks();
        TorService.followRoute(const DirectRoute());
        async.elapse(TorHost.sleepDelay * 2);
        expect(plugin.dormantCalls, [true, false]);
        expect(plugin.stopCalls, 1);
      });
    });

    test('a detached that lands while a sleep\'s result is still pending is '
        'queued behind it, not lost (the fork\'s eager stop, R-A2e, removes '
        'the wait)', () {
      fakeAsync((async) {
        TorService.followRoute(const TorRoute());
        async.flushMicrotasks();
        plugin.dormantGate = Completer<void>();
        EmbeddedTorService.onPause();
        async.elapse(TorHost.sleepDelay);
        expect(plugin.dormantCalls, [true]);

        TorHost.onDetached();
        async.flushMicrotasks();
        expect(plugin.stopCalls, 1);
        expect(plugin.nativeStops, 0);
        plugin.dormantGate!.complete();
        async.flushMicrotasks();
        expect(plugin.nativeStops, 1);
      });
    });

    test(
      'a non-UI owner released during Tor.init() keeps its mapping until '
      'the client that start still brings up has been stopped (M3)',
      () async {
        plugin.initGate = Completer<void>();
        final lease = await TorHost.acquire(
          bootstrapBudget: Duration.zero,
          stillTor: _yes,
        );
        await pumpEventQueue();
        expect(plugin.startCalls, 1);

        var released = false;
        unawaited(lease.release().then((_) => released = true));
        await pumpEventQueue();
        expect(plugin.stopCalls, 1);
        expect(registry.lookup(TorHost.portName), isNotNull);
        expect(released, isFalse);
        // Another isolate asking now is told to wait, so nobody starts next
        // to the client that is still coming up.
        final other = _Remote(registry.lookup(TorHost.portName)!)..acquire();
        expect((await other.next())['state'], 'gone');

        plugin.initGate!.complete();
        await _until(() => released, reason: 'release resolves');
        expect(plugin.nativeStops, 1, reason: 'the late client is torn down');
        expect(plugin.bootstrapped, isFalse);
        expect(registry.names, isEmpty);
        other.close();
      },
    );

    test(
      'the UI\'s "stop" sticks in a non-UI owner: a stale acquire gets '
      '"off" and starts nothing; an acquire from the UI starts it (M2)',
      () async {
        await TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 1),
          stillTor: _yes,
        );
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);
        final owner = registry.lookup(TorHost.portName)!;
        owner.send(const {'op': 'stop'});
        await pumpEventQueue();
        expect(EmbeddedTorService.state, EmbeddedTorState.off);

        final stale = _Remote(owner)..acquire();
        expect((await stale.next())['state'], 'off');
        await pumpEventQueue();
        expect(plugin.startCalls, 1);
        expect(EmbeddedTorService.state, EmbeddedTorState.off);

        final ui = _Remote(owner)..acquire(ui: true);
        expect((await ui.next())['state'], anyOf('starting', 'ready'));
        await _until(() => EmbeddedTorService.state == EmbeddedTorState.ready);
        expect(plugin.startCalls, 2);
        stale.acquire();
        expect((await stale.next())['state'], 'ready');
        stale.close();
        ui.close();
      },
    );

    test(
      'TB-3 (probe P1): an acquire while the UI\'s stop stands and the '
      'owner\'s own restart is still starting is answered "off", not '
      '"starting"; the requester ends its lease at once instead of waiting '
      'out its budget',
      () async {
        // The owner: a non-UI isolate whose client the UI switched off.
        await TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 1),
          stillTor: _yes,
        );
        final owner = registry.lookup(TorHost.portName)!;
        owner.send(const {'op': 'stop'});
        await pumpEventQueue();
        expect(EmbeddedTorService.state, EmbeddedTorState.off);
        // Its next tick takes a lease again; its route re-check is slow, so
        // its own start stays `starting` meanwhile.
        final routeRead = Completer<bool>();
        final restarting = TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 5),
          stillTor: () => routeRead.future,
        );
        await pumpEventQueue();
        expect(EmbeddedTorService.state, EmbeddedTorState.starting);

        // Another isolate (a WorkManager job) acquires now.
        final requester = _Remote(owner)..acquire();
        closers.add(requester.close);
        final answer = await requester.next();
        expect(answer['state'], 'off');
        expect(answer['port'], -1);
        expect(answer['isolate'], Isolate.current.controlPort);
        // Not registered: the owner never writes to it again.
        routeRead.complete(false);
        await restarting;
        expect(EmbeddedTorService.state, EmbeddedTorState.failed);
        await requester.expectSilence();
        expect(plugin.startCalls, 1);

        // The requester's side, replayed from what the owner sent: a TorHost
        // in another isolate given exactly that answer.
        await EmbeddedTorService.stop();
        EmbeddedTorService.debugReset();
        registry.names.clear();
        final released = <Map>[];
        fakeOwner((request) {
          final reply = request['reply'] as SendPort;
          if (request['op'] == 'acquire') reply.send(answer);
          if (request['op'] == 'release') released.add(request);
        });
        final watch = Stopwatch()..start();
        final lease = await TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 3),
          stillTor: _yes,
        );
        expect(
          watch.elapsed,
          lessThan(const Duration(seconds: 1)),
          reason: 'waited out its budget for an owner that never writes again',
        );
        expect(lease.port, -1);
        expect(lease.ownsClient, isFalse);
        expect(EmbeddedTorService.state, EmbeddedTorState.off);
        await pumpEventQueue();
        expect(released, hasLength(1), reason: 'the lease was not ended');
        expect(plugin.startCalls, 1);
      },
    );

    test(
      'TB-2 (probe P2): the UI switches Tor off after a non-UI isolate read '
      '"Tor" and before its fresh claim, with no owner to tell and nothing to '
      'sweep: the route is read again after the claim, no client starts and '
      'the claim is given up',
      () async {
        var routeTor = true;
        var reads = 0;
        bool? uiFoundOwner;
        Future<bool> stillTor() async {
          reads++;
          final read = routeTor;
          await Future<void>.delayed(Duration.zero);
          if (reads == 1) {
            // The UI's routeChanged(tor: false) lands now, after this read:
            // it looks for an owner to send its stop to and finds none, and
            // with no Tor client run in this process (no used mark) it
            // sweeps nothing.
            routeTor = false;
            uiFoundOwner = registry.lookup(TorHost.portName) != null;
            expect(registry.used, isNull);
          }
          return read;
        }

        final lease = await TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 1),
          stillTor: stillTor,
        );
        expect(uiFoundOwner, isFalse);
        expect(reads, 2, reason: 'the route was not read again after the claim');
        expect(plugin.startCalls, 0);
        expect(plugin.sweepCalls, 0);
        expect(lease.port, -1);
        expect(lease.ownsClient, isFalse);
        expect(EmbeddedTorService.state, EmbeddedTorState.failed);
        expect(registry.names, isEmpty, reason: 'the claim was kept');
        expect(registry.used, isNull);
      },
    );

    test('stillTor false: acquire starts nothing, and the lease fails closed '
        '(M2)', () async {
      final lease = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 1),
        stillTor: () async => false,
      );
      expect(plugin.startCalls, 0);
      expect(lease.port, -1);
      expect(await TorHost.port(), -1);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(registry.names, isEmpty);
    });

    test('stillTor is read again before a takeover: the route switched off '
        'while the dead owner timed out → no start (M2)', () async {
      final dead = RawReceivePort();
      registry.register(dead.sendPort, TorHost.portName);
      dead.close();
      var reads = 0;
      await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 3),
        stillTor: () async => ++reads == 1,
      );
      expect(reads, greaterThanOrEqualTo(2));
      expect(plugin.startCalls, 0);
      expect(plugin.sweepCalls, 0);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(registry.lookup(TorHost.portName), isNull);
    });

    test(
      '30 ms after a takeover registration, a mapping that is not ours '
      'makes this isolate a leaseholder, with no native start (M1)',
      () async {
        final racing = _RacingRegistry();
        registry = racing;
        TorHost.debugRegistry = racing;
        final dead = RawReceivePort();
        racing.register(dead.sendPort, TorHost.portName);
        dead.close();
        final racer = _FakeOwner((request) {
          final reply = request['reply'];
          if (reply is SendPort && request['op'] != 'release') {
            reply.send({'state': 'ready', 'port': 47999});
          }
        });
        closers.add(racer.close);
        racing.racer = racer.sendPort;

        final lease = await TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 3),
          stillTor: _yes,
        );
        expect(plugin.startCalls, 0);
        expect(lease.ownsClient, isFalse);
        expect(lease.port, 47999);
        expect(racing.lookup(TorHost.portName), racer.sendPort);
        // Displaced before its native start: no sweep either (R-A2c-b).
        expect(plugin.sweepCalls, 0);
      },
    );

    test('Tor off reaches a registered owner even while this isolate still '
        'thinks it owns the client (M1)', () async {
      TorService.followRoute(const TorRoute());
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      // Another isolate's mapping replaced ours.
      final other = ReceivePort();
      registry.names[TorHost.portName] = other.sendPort;

      TorService.followRoute(const DirectRoute());
      expect(await other.first.timeout(const Duration(seconds: 2)), {
        'op': 'stop',
      });
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      other.close();
    });

    test('a non-Tor launch stops a client another isolate still runs, and '
        'main() says so (M9)', () async {
      final other = ReceivePort();
      registry.register(other.sendPort, TorHost.portName);
      TorHost.routeChanged(tor: false);
      expect(await other.first.timeout(const Duration(seconds: 2)), {
        'op': 'stop',
      });
      other.close();
      expect(
        File('lib/main.dart').readAsStringSync(),
        contains('TorHost.routeChanged(tor: false)'),
      );
    });

    test(
      'port() during a hand-over answers -1 at once, not after 10 s (M4)',
      () async {
        SendPort? updates;
        fakeOwner((request) {
          if (request['op'] != 'acquire') return; // 'port' goes unanswered
          updates = request['reply'] as SendPort;
          updates!.send({
            'state': 'ready',
            'port': 47999,
            // Its control port answers pings: busy, not dead.
            'isolate': Isolate.current.controlPort,
          });
        });
        await TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 2),
          stillTor: _yes,
        );
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);

        final clock = Stopwatch()..start();
        final asking = TorHost.port();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        updates!.send(const {'state': 'gone', 'port': -1});
        expect(await asking, -1);
        expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      },
    );

    test('a failed leaseholder retries once its owner is ready again, and its '
        'Details are the owner\'s own text (M7, M12)', () async {
      final acquires = <SendPort>[];
      final releases = <SendPort>[];
      fakeOwner((request) {
        final reply = request['reply'] as SendPort;
        switch (request['op']) {
          case 'acquire':
            acquires.add(reply);
            reply.send(
              acquires.length == 1
                  ? {'state': 'starting', 'port': -1}
                  : {'state': 'ready', 'port': 47999},
            );
          case 'release':
            releases.add(reply);
        }
      });
      unawaited(
        TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 5),
          stillTor: _yes,
        ),
      );
      await _until(() => acquires.length == 1);
      acquires.first.send({
        'state': 'failed',
        'port': -1,
        'error': 'StateError: Bad state: bootstrap failed',
      });
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.failed);
      expect(
        EmbeddedTorService.lastError,
        'StateError: Bad state: bootstrap failed',
      );

      // The owner recovers on its own: the leaseholder follows, once.
      acquires.first.send({'state': 'ready', 'port': 47999});
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.ready);
      expect(EmbeddedTorService.port, 47999);
      expect(acquires, hasLength(2));
      expect(releases, [acquires.first]);
      expect(plugin.startCalls, 0);
    });

    test('FW-BG addendum: a failed leaseholder follows the owner\'s new '
        'reason while both stay failed, and announces it on changes, so its '
        'Tor card redraws', () async {
      final acquires = <SendPort>[];
      fakeOwner((request) {
        final reply = request['reply'] as SendPort;
        if (request['op'] != 'acquire') return;
        acquires.add(reply);
        reply.send({
          'state': 'failed',
          'port': -1,
          'error': 'Tor client lost its SOCKS port',
        });
      });
      await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 2),
        stillTor: _yes,
      );
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(EmbeddedTorService.lastError, 'Tor client lost its SOCKS port');

      final seen = <(EmbeddedTorState, String?)>[];
      final sub = EmbeddedTorService.changes.listen(
        (state) => seen.add((state, EmbeddedTorService.lastError)),
      );
      addTearDown(sub.cancel);
      // The owner's plugin report replaces its lost-port reason; its state
      // stays failed.
      acquires.last.send({
        'state': 'failed',
        'port': -1,
        'error': 'TorProxyFailure: proxy task exited',
      });
      await _until(
        () => seen.isNotEmpty,
        timeout: const Duration(seconds: 2),
        reason: 'no change announced',
      );
      expect(seen, [
        (EmbeddedTorState.failed, 'TorProxyFailure: proxy task exited'),
      ]);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(plugin.startCalls, 0);
    });
  });

  // ── Task A2c: process-wide sweeps and the A2 carry-overs ─────────────────

  group('A2c (fake registry)', () {
    late _Registry registry;
    late _Native native;
    final remotes = <_Remote>[];
    final logs = <String>[];
    final savedDebugPrint = debugPrint;

    _Remote remoteOf(SendPort owner) {
      final r = _Remote(owner);
      remotes.add(r);
      return r;
    }

    void registerDead() {
      final dead = RawReceivePort();
      registry.register(dead.sendPort, TorHost.portName);
      dead.close();
    }

    setUp(() {
      registry = _Registry();
      TorHost.debugRegistry = registry;
      TorHost.debugSleepDelay = const Duration(milliseconds: 50);
      native = _Native();
      EmbeddedTorService.debugBackend = native;
      logs.clear();
      debugPrint = (String? message, {int? wrapWidth}) {
        logs.add(message ?? '');
      };
    });

    tearDown(() async {
      debugPrint = savedDebugPrint;
      final gate = native.sweepGate;
      if (gate != null && !gate.isCompleted) gate.complete();
      final stopGate = native.stopGate;
      if (stopGate != null && !stopGate.isCompleted) stopGate.complete();
      native.releaseStart();
      for (final r in remotes) {
        r.close();
      }
      remotes.clear();
      await EmbeddedTorService.stop();
      EmbeddedTorService.debugReset();
      EmbeddedTorService.debugBackend = null;
      TorHost.debugRegistry = null;
      TorHost.debugSleepDelay = null;
      TorService.debugIsIOS = null;
    });

    // ── Where sweeps happen (R-A2c-b) ───────────────────────────────────

    test('a takeover sweeps the process once, after its settle and before '
        'its own native start (R-A2c-b 1)', () async {
      registerDead();
      final lease = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      expect(lease.ownsClient, isTrue);
      expect(native.sweepCalls, 1);
      expect(native.calls, ['sweep', 'start']);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(
        logs,
        contains(
          '[TorHost] sweep before taking over: stopped 0 Tor '
          'client(s)',
        ),
      );
    });

    test('Tor off in the UI waits for its own client to stop, then sweeps '
        'the process once (R-A2c-b 2, R-A2c-c)', () async {
      TorService.followRoute(const TorRoute());
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);

      final stopping = native.stopGate = Completer<void>();
      TorService.followRoute(const DirectRoute());
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(native.sweepCalls, 0, reason: 'its own stop comes first');

      native.stopGate = null;
      stopping.complete();
      await _until(() => native.sweepCalls == 1, reason: 'the sweep');
      await pumpEventQueue();
      expect(native.calls, ['start', 'stop', 'sweep']);
      expect(native.sweepCalls, 1);
      expect(
        logs,
        contains('[TorHost] sweep after Tor off: stopped 0 Tor client(s)'),
      );
    });

    test('a non-Tor launch sweeps once if an isolate of this process has '
        'run Tor, and leaves the Tor library alone if none has '
        '(R-A2c-b 3)', () async {
      // main() in a fresh process: no Tor client can exist.
      TorHost.routeChanged(tor: false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(native.sweepCalls, 0);

      // Another isolate of this process (Sentinel, a WorkManager job) has
      // started a client before main() ran.
      final other = RawReceivePort();
      addTearDown(other.close);
      registry.register(other.sendPort, TorHost.usedPortName);
      TorHost.routeChanged(tor: false);
      await _until(() => native.sweepCalls == 1, reason: 'the sweep');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(native.sweepCalls, 1);
      expect(
        File('lib/main.dart').readAsStringSync(),
        contains('TorHost.routeChanged(tor: false)'),
      );
    });

    test('ordinary starts, leases, releases, the UI\'s stop and Tor on never '
        'sweep (R-A2c-b)', () async {
      // A fresh claim, with no dead owner.
      final a = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      expect(a.ownsClient, isTrue);
      // Another isolate leases it, and gives it back.
      final owner = registry.lookup(TorHost.portName)!;
      final other = remoteOf(owner)..acquire();
      expect((await other.next())['state'], 'ready');
      other.release();
      // A second lease here, released.
      final b = await TorHost.acquire(
        bootstrapBudget: Duration.zero,
        stillTor: _yes,
      );
      await b.release();
      // The UI's stop reaches this owner; an acquire from the UI restarts it.
      owner.send(const {'op': 'stop'});
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.off);
      other.acquire(ui: true);
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.ready);
      other.release();
      // The last release ends ownership.
      await a.release();
      expect(native.stopCalls, 2);
      expect(registry.lookup(TorHost.portName), isNull);
      expect(native.sweepCalls, 0);

      // The UI: Tor on, a paused and resumed client, detached.
      TorService.followRoute(const TorRoute());
      await pumpEventQueue();
      await EmbeddedTorService.onPause();
      await EmbeddedTorService.onResume();
      TorHost.onDetached();
      await pumpEventQueue();
      expect(native.startCalls, 3);
      expect(native.sweepCalls, 0);
    });

    test(
      'a lessee never sweeps: leasing a live owner, its owner failing, '
      'its automatic retry and its owner switching Tor off (R-A2c-b)',
      () async {
        final updates = <SendPort>[];
        final live = RawReceivePort();
        addTearDown(live.close);
        live.handler = (Object? m) {
          final request = m as Map;
          final reply = request['reply'];
          if (request['op'] == 'acquire' && reply is SendPort) {
            updates.add(reply);
            reply.send({'state': 'ready', 'port': 47999});
          }
        };
        registry.register(live.sendPort, TorHost.portName);

        final lease = await TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 5),
          stillTor: _yes,
        );
        expect(lease.ownsClient, isFalse);
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);
        // The owner's client fails: the lessee's one automatic retry leases
        // again from the same owner.
        updates.first.send({'state': 'failed', 'port': -1, 'error': 'x'});
        await _until(() => updates.length == 2, reason: 'the retry');
        await _until(() => EmbeddedTorService.state == EmbeddedTorState.ready);
        // The owner hands over, then switches Tor off.
        updates.last.send(const {'state': 'off', 'port': -1});
        await _until(() => EmbeddedTorService.state == EmbeddedTorState.off);
        await lease.release();
        expect(native.startCalls, 0);
        expect(native.sweepCalls, 0);
      },
    );

    // ── Standing down (R-A2c-c) ─────────────────────────────────────────

    test('an owner whose client another isolate\'s sweep stopped reads '
        'failed and restarts nothing; the next acquire restarts it '
        '(R-A2c-c)', () async {
      TorService.followRoute(const TorRoute());
      await pumpEventQueue();
      final other = remoteOf(registry.lookup(TorHost.portName)!)..acquire();
      expect((await other.next())['state'], 'ready');

      native.swept();
      expect((await other.next())['state'], 'failed');
      await Future<void>.delayed(_Native.reportLag * 4);
      expect(native.startCalls, 1, reason: 'no automatic restart');
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(
        EmbeddedTorService.lastError,
        'TorProxyFailure: Tor proxy was stopped by a process-wide stop',
      );
      // The report replaced the lost-port reason with the state still
      // failed: the leaseholder hears the new reason (FW-BG addendum), and
      // nothing more.
      final update = await other.next();
      expect(update['state'], 'failed');
      expect(
        update['error'],
        'TorProxyFailure: Tor proxy was stopped by a process-wide stop',
      );
      await other.expectSilence();

      other.acquire();
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.ready);
      expect(native.startCalls, 2);
    });

    test('an ordinary death of an owner\'s client still gets exactly one '
        'automatic restart, once the report has said why (M2)', () async {
      TorService.followRoute(const TorRoute());
      await pumpEventQueue();

      native.die();
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(native.startCalls, 1, reason: 'held for the report');
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.ready);
      await Future<void>.delayed(_Native.reportLag * 4);
      expect(native.startCalls, 2);
    });

    // ── Failures (R-A2c-d) ──────────────────────────────────────────────

    test('a sweep that throws after Tor off: nothing throws, the state stays '
        'off, and only the error\'s type is logged (R-A2c-d)', () async {
      TorService.followRoute(const TorRoute());
      await pumpEventQueue();
      native.sweepError = StateError(
        'stop failed: /data/user/0/app.bitbag/files/tor_state is locked',
      );

      TorService.followRoute(const DirectRoute());
      await _until(() => native.sweepCalls == 1);
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(
        logs,
        contains('[TorHost] sweep after Tor off failed: StateError'),
      );
      expect(logs.where((l) => l.contains('/data/user')), isEmpty);
    });

    test('a takeover whose sweep throws fails closed: failed, no native '
        'start, Tor requests refused, nothing thrown (R-A2c-d)', () async {
      registerDead();
      native.sweepError = StateError('stopped 0 of 1 Tor proxies cleanly');
      final lease = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      expect(native.sweepCalls, 1);
      expect(native.startCalls, 0);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(lease.port, -1);
      expect(await TorHost.port(), -1);
      await expectLater(_get(1), _torNotConnected);
      expect(
        logs,
        contains('[TorHost] sweep before taking over failed: StateError'),
      );
      expect(logs.where((l) => l.contains('0 of 1')), isEmpty);
    });

    test('a takeover whose sweep hangs is given up after sweepTimeout: '
        'failed, no native start (R-A2c-d)', () {
      fakeAsync((async) {
        registerDead();
        native.sweepGate = Completer<void>();
        TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 60),
          stillTor: _yes,
        );
        async.elapse(TorHost.lookupTimeout + TorHost.takeoverSettle);
        expect(native.sweepCalls, 1);
        async.elapse(TorHost.sweepTimeout - const Duration(seconds: 1));
        expect(EmbeddedTorService.state, EmbeddedTorState.starting);
        async.elapse(const Duration(seconds: 2));
        expect(native.startCalls, 0);
        expect(EmbeddedTorService.state, EmbeddedTorState.failed);
        expect(EmbeddedTorService.port, -1);
        expect(
          logs,
          contains(
            '[TorHost] sweep before taking over failed: '
            'TimeoutException',
          ),
        );
        expect(registry.unswept, isNotNull, reason: 'the next start sweeps');
      });
    });

    test('Tor straight back on while the Tor-off sweep hangs: the start '
        'waits for the sweep (which would cancel it), up to sweepTimeout '
        '(R-A2c-d)', () {
      fakeAsync((async) {
        TorService.followRoute(const TorRoute());
        async.flushMicrotasks();
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);
        native.sweepGate = Completer<void>();
        TorService.followRoute(const DirectRoute());
        async.flushMicrotasks();
        expect(native.sweepCalls, 1);

        TorService.followRoute(const TorRoute());
        async.elapse(TorHost.sweepTimeout - const Duration(seconds: 1));
        expect(native.startCalls, 1);
        expect(EmbeddedTorService.state, EmbeddedTorState.starting);
        expect(EmbeddedTorService.port, -1);
        async.elapse(const Duration(seconds: 2));
        expect(
          logs,
          contains('[TorHost] sweep after Tor off failed: TimeoutException'),
        );
        expect(native.startCalls, 2);
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      });
    });

    // ── A2 carry-overs ──────────────────────────────────────────────────

    test('the route is read again after the takeover settle: Tor off there '
        'means no sweep and no start, the mapping goes, and an isolate that '
        'leased meanwhile is told "gone" (N-h, N-a)', () async {
      registerDead();
      var reads = 0;
      final third = Completer<bool>();
      final acquiring = TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: () => ++reads < 3 ? Future.value(true) : third.future,
      );
      await _until(() => reads == 3, reason: 'the re-check after the settle');
      final other = remoteOf(registry.lookup(TorHost.portName)!)..acquire();
      expect((await other.next())['state'], 'starting');

      third.complete(false);
      final lease = await acquiring;
      expect((await other.next())['state'], 'gone');
      expect(native.sweepCalls, 0);
      expect(native.startCalls, 0);
      expect(lease.port, -1);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(registry.lookup(TorHost.portName), isNull);
    });

    test('a start with neither the UI\'s route nor a route check starts '
        'nothing (N-f)', () async {
      await EmbeddedTorService.ensureStarted();
      expect(native.startCalls, 0);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(EmbeddedTorService.port, -1);
      expect(registry.names, isEmpty);
    });

    test('a non-UI owner whose native stop never returns still gives '
        'ownership up, after one deadline for the stop and the settle '
        '(N-b)', () {
      fakeAsync((async) {
        late TorHostLease lease;
        TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 5),
          stillTor: _yes,
        ).then((l) => lease = l);
        async.flushMicrotasks();
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);

        native.stopGate = Completer<void>(); // never completes
        var released = false;
        lease.release().then((_) => released = true);
        async.elapse(
          EmbeddedTorService.bootstrapTimeout - const Duration(seconds: 1),
        );
        expect(released, isFalse);
        expect(registry.lookup(TorHost.portName), isNotNull);
        async.elapse(const Duration(seconds: 2));
        expect(released, isTrue);
        expect(registry.names, isEmpty);
      });
    });

    test('nativeIdle() waits only for the native start and stop in flight '
        'when it is called, not for a start begun after (N-d)', () async {
      native.hold = Completer<void>();
      native.slowCancel = true;
      TorService.followRoute(const TorRoute());
      await pumpEventQueue();
      expect(native.startCalls, 1, reason: 'a native start in flight');

      var idle = false;
      unawaited(EmbeddedTorService.nativeIdle().then((_) => idle = true));
      // Abandoned, but its cancel lands late, so the next start queues
      // behind it.
      await EmbeddedTorService.stop();
      native.slowCancel = false;
      unawaited(EmbeddedTorService.ensureStarted());
      await pumpEventQueue();
      expect(native.startCalls, 1, reason: 'the next start waits for it');

      native.hold = Completer<void>(); // the next start is held in turn
      native.releaseStart(); // the abandoned start returns, with no client
      await pumpEventQueue();
      expect(native.startCalls, 2, reason: 'the later start is in flight');
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(idle, isTrue, reason: 'the later start is not waited for');
    });

    test('an owner ending while a new lease in its own isolate waits for '
        'that end: the new lease starts as soon as the old stop is done '
        '(N-d, end to end)', () async {
      final a = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      final stopping = native.stopGate = Completer<void>();
      var released = false;
      unawaited(a.release().then((_) => released = true));
      await pumpEventQueue();
      final acquiring = TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 30),
        stillTor: _yes,
      );
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);

      native.stopGate = null;
      stopping.complete();
      await _until(
        () => EmbeddedTorService.state == EmbeddedTorState.ready,
        timeout: const Duration(seconds: 3),
        reason: 'the new lease starts once the end is done',
      );
      final b = await acquiring;
      expect(released, isTrue);
      expect(b.ownsClient, isTrue);
      expect(native.startCalls, 2);
    });

    test('an acquire whose start throws gives its lease back, so the last '
        'release still ends ownership (A3-M7)', () async {
      native.failuresThrow = true;
      await expectLater(
        TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 5),
          stillTor: _yes,
        ),
        throwsA(isA<StateError>()),
      );
      final lease = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      await lease.release();
      expect(native.stopCalls, 1);
      expect(registry.lookup(TorHost.portName), isNull);
    });

    test('the sleep after paused waits 2 s on Android and not at all on '
        'iOS (N-g)', () {
      TorService.debugIsIOS = false;
      expect(TorHost.sleepDelay, const Duration(seconds: 2));
      TorService.debugIsIOS = true;
      expect(TorHost.sleepDelay, Duration.zero);
      TorHost.debugSleepDelay = null;
      fakeAsync((async) {
        TorService.followRoute(const TorRoute());
        async.flushMicrotasks();
        EmbeddedTorService.onPause();
        async.elapse(Duration.zero);
        expect(native.dormantCalls, [true]);
      });
    });

    test('a UI whose route is not Tor starts nothing, even if ensureStarted() '
        'is called (N-f, strict)', () async {
      TorHost.routeChanged(tor: false);
      await EmbeddedTorService.ensureStarted();
      expect(native.startCalls, 0);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(EmbeddedTorService.port, -1);
      expect(registry.names, isEmpty);
    });

    // ── The unswept mark (fix round 1) ──────────────────────────────────

    test('a sweep is given 35 s: the fork bounds one orphan at about 15 s '
        'per proxy plus a 15 s wait', () {
      expect(TorHost.sweepTimeout, const Duration(seconds: 35));
    });

    test('another survivor removed the dead mapping while this isolate '
        'waited: this isolate\'s claim is fresh, and it still sweeps once '
        'before the process\'s only native start', () async {
      registerDead();
      registry.register(_mark(), TorHost.usedPortName);
      final acquiring = TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(native.startCalls, 0);
      // The other survivor's _removeDead: the mark first, then the dead
      // mapping. Its claim comes a moment later, finds this isolate's
      // mapping and leases it.
      registry.register(_mark(), TorHost.unsweptPortName);
      registry.remove(TorHost.portName);

      final lease = await acquiring;
      expect(lease.ownsClient, isTrue);
      expect(native.sweepCalls, 1);
      expect(native.calls, ['sweep', 'start']);
      expect(native.startCalls, 1);
      expect(registry.unswept, isNull, reason: 'swept: the mark goes');
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    });

    test('a takeover stopped during its settle, after it removed the dead '
        'mapping, leaves the mark; the next start sweeps first', () {
      fakeAsync((async) {
        registerDead();
        TorHost.acquire(bootstrapBudget: Duration.zero, stillTor: _yes);
        async.elapse(TorHost.lookupTimeout + const Duration(milliseconds: 5));
        expect(registry.lookup(TorHost.portName), isNotNull);
        expect(registry.unswept, isNotNull);
        EmbeddedTorService.stop();
        async.elapse(TorHost.takeoverSettle * 3);
        expect(native.calls, isEmpty);
        expect(registry.unswept, isNotNull, reason: 'not swept yet');

        TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 5),
          stillTor: _yes,
        );
        async.elapse(const Duration(seconds: 1));
        expect(native.calls, ['sweep', 'start']);
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);
        expect(registry.unswept, isNull);
      });
    });

    test('a takeover whose sweep failed keeps the mark, and its next start '
        'sweeps again before its native start', () async {
      registerDead();
      native.sweepError = StateError('stopped 0 of 1 Tor proxies cleanly');
      final lease = await TorHost.acquire(
        bootstrapBudget: const Duration(seconds: 5),
        stillTor: _yes,
      );
      expect(native.calls, ['sweep']);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(lease.ownsClient, isTrue, reason: 'ownership kept');
      expect(registry.unswept, isNotNull);

      native.sweepError = null;
      await EmbeddedTorService.ensureStarted();
      expect(native.calls, ['sweep', 'sweep', 'start']);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(registry.unswept, isNull);
    });

    test('the UI\'s fast path with a takeover not swept yet: a fresh claim '
        'settles, sweeps, and only then starts', () async {
      registry.register(_mark(), TorHost.unsweptPortName);
      TorService.followRoute(const TorRoute());
      expect(native.startCalls, 0, reason: 'no synchronous start');
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.ready);
      expect(native.calls, ['sweep', 'start']);
      expect(registry.unswept, isNull);
    });

    test('the UI\'s fast path on its own mapping after its takeover sweep '
        'failed: the Retry sweeps again before it starts', () async {
      registerDead();
      native.sweepError = StateError('stopped 0 of 1 Tor proxies cleanly');
      TorService.followRoute(const TorRoute());
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.failed);
      expect(native.calls, ['sweep']);
      expect(registry.lookup(TorHost.portName), isNotNull);

      native.sweepError = null;
      await EmbeddedTorService.ensureStarted(); // the Tor card's Retry
      expect(native.calls, ['sweep', 'sweep', 'start']);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(registry.unswept, isNull);
    });

    test('the mark is removed only while it is still the one the sweep was '
        'for: a mark registered during the sweep stays', () async {
      registry.register(_mark(), TorHost.unsweptPortName);
      final gate = native.sweepGate = Completer<void>();
      TorService.followRoute(const TorRoute());
      await _until(() => native.sweepCalls == 1, reason: 'the sweep');
      registry.remove(TorHost.unsweptPortName);
      final later = _mark();
      registry.register(later, TorHost.unsweptPortName);

      gate.complete();
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.ready);
      expect(registry.unswept, later);
    });

    // ── Cross-isolate orderings, through registry hooks (round 2) ───────

    group('the mark is registered before a dead mapping is removed', () {
      late _OrderRegistry order;

      SendPort deadOwner() {
        final port = _mark();
        order.dead.add(port);
        order.register(port, TorHost.portName);
        return port;
      }

      setUp(() {
        order = _OrderRegistry();
        registry = order;
        TorHost.debugRegistry = order;
      });

      test('by an acquire', () async {
        deadOwner();
        await TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 5),
          stillTor: _yes,
        );
        expect(order.markedFirst, [true]);
        expect(native.calls, ['sweep', 'start']);
      });

      test('by the UI', () async {
        deadOwner();
        TorService.followRoute(const TorRoute());
        await _until(() => EmbeddedTorService.state == EmbeddedTorState.ready);
        expect(order.markedFirst, [true]);
        expect(native.calls, ['sweep', 'start']);
      });

      test('by a leaseholder whose owner died', () async {
        final updates = <SendPort>[];
        final owner = _FakeOwner((request) {
          final reply = request['reply'];
          if (request['op'] == 'acquire' && reply is SendPort) {
            updates.add(reply);
            reply.send({'state': 'ready', 'port': 47999});
          }
        });
        addTearDown(owner.close);
        order.dead.add(owner.sendPort);
        order.register(owner.sendPort, TorHost.portName);
        await TorHost.acquire(
          bootstrapBudget: const Duration(seconds: 5),
          stillTor: _yes,
        );
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);

        // The owner dies after a last failure report: the automatic retry
        // finds its mapping dead and takes over.
        owner.close();
        updates.single.send({'state': 'failed', 'port': -1, 'error': 'x'});
        await _until(() => native.startCalls == 1, reason: 'the takeover');
        expect(order.markedFirst, [true]);
        expect(native.calls, ['sweep', 'start']);
      });
    });

    test('a takeover that marks and removes between a read of the mark '
        'before the claim and the claim still sweeps: the UI\'s fast path '
        'reads the mark after claiming', () async {
      final racing = _MarkOnLookupRegistry();
      registry = racing;
      TorHost.debugRegistry = racing;
      TorService.followRoute(const TorRoute());
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.ready);
      expect(racing.armed, isFalse, reason: 'the hook ran');
      expect(native.calls, ['sweep', 'start']);
      expect(racing.unswept, isNull);
    });
  });
}
