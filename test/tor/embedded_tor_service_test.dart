import 'dart:async';

import 'package:bag/services/embedded_tor_service.dart';
import 'package:bag/services/tor_host.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tor/tor.dart' as plugin;

/// A scriptable [EmbeddedTorBackend]. Each `start()` call takes the next
/// behaviour from [startScript] (the last entry repeats); a [Completer] lets
/// a test hold a start open and finish it later.
///
/// Like the plugin (`Tor.stop()` invalidates its lifecycle and cancels the
/// bootstrap token; a start that returns after that drops what it built), a
/// `stop()` during a [StartBehaviour.hold] start makes that start return at
/// once without bootstrapping. A [StartBehaviour.hang] start ignores the
/// stop — a native start that doesn't honour the cancel — and returns only
/// when the test calls [release].
///
/// With [initGate], the first `start()` first waits on it, as the default
/// backend awaits `Tor.init()` before calling the plugin's `start()`. The
/// plugin captures its lifecycle generation only once `start()` runs, so a
/// stop during that gap cancels nothing: the start that follows runs as
/// scripted.
class FakeTorBackend implements EmbeddedTorBackend {
  FakeTorBackend({
    List<StartBehaviour>? startScript,
    this.readyPort = 47123,
    this.stopTakes = Duration.zero,
    this.initGate,
  }) : startScript = startScript ?? [StartBehaviour.succeed];

  final List<StartBehaviour> startScript;
  final int readyPort;

  /// The init phase of the first start; null for none.
  Completer<void>? initGate;

  /// How long a native stop takes (the plugin's own teardown).
  final Duration stopTakes;

  int startCalls = 0;
  int stopCalls = 0;
  final List<bool> dormantCalls = [];
  final List<String> calls = [];

  /// Completes the start that is being held open by [StartBehaviour.hold]
  /// or [StartBehaviour.hang].
  Completer<void>? heldStart;

  /// The running start can be cancelled by a stop ([StartBehaviour.hold]).
  bool _cancellable = false;

  /// Set by a stop during a cancellable start: it returns without a circuit.
  bool _cancelled = false;

  bool _bootstrapped = false;

  final StreamController<Object> _failures =
      StreamController<Object>.broadcast();
  final StreamController<int> _events = StreamController<int>.broadcast();

  /// Ends the init gap of the start waiting in it.
  void releaseInit() {
    final init = _initWaiting;
    if (init != null && !init.isCompleted) init.complete();
  }

  /// The init gate the running start is waiting on.
  Completer<void>? _initWaiting;

  /// Releases a held or hung start, if one is still waiting.
  void release() {
    final held = heldStart;
    if (held != null && !held.isCompleted) held.complete();
  }

  /// Simulates the plugin losing its SOCKS proxy: like the real plugin, it
  /// tears its own client down (publishing port -1), then reports the
  /// failure.
  void dieOnItsOwn() {
    losePort();
    reportFailure('proxy exited');
  }

  /// The plugin's first sign of a dying proxy: port -1 on `events`, before
  /// `failures` reports it.
  void losePort() {
    _bootstrapped = false;
    _events.add(-1);
  }

  /// A port broadcast that changes nothing (the plugin re-publishing it).
  void reportPort(int port) => _events.add(port);

  /// The failure report that follows [losePort].
  void reportFailure(Object failure) => _failures.add(failure);

  @override
  Stream<Object> get failures => _failures.stream;

  @override
  Stream<int> get events => _events.stream;

  @override
  bool get bootstrapped => _bootstrapped;

  @override
  int get port => _bootstrapped ? readyPort : -1;

  @override
  Future<void> start() async {
    final behaviour =
        startScript[startCalls < startScript.length
            ? startCalls
            : startScript.length - 1];
    startCalls++;
    calls.add('start');
    // The init gap: nothing to cancel yet, so a stop meanwhile is lost.
    final init = _initWaiting = initGate;
    initGate = null;
    if (init != null) await init.future;
    _cancelled = false;
    _cancellable = behaviour == StartBehaviour.hold;
    switch (behaviour) {
      case StartBehaviour.succeed:
        _bootstrapped = true;
      case StartBehaviour.fail:
        throw StateError('bootstrap failed');
      case StartBehaviour.never:
        await Completer<void>().future;
      case StartBehaviour.hold:
      case StartBehaviour.hang:
        heldStart = Completer<void>();
        await heldStart!.future;
        _cancellable = false;
        if (_cancelled) return;
        _bootstrapped = true;
    }
  }

  @override
  Future<void> bootstrap() async {
    calls.add('bootstrap');
  }

  @override
  Future<void> setDormant(bool dormant) async {
    calls.add('dormant:$dormant');
    dormantCalls.add(dormant);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    calls.add('stop');
    _bootstrapped = false;
    if (_cancellable) {
      _cancelled = true;
      release();
    }
    if (stopTakes > Duration.zero) await Future<void>.delayed(stopTakes);
  }
}

enum StartBehaviour { succeed, fail, never, hold, hang }

/// Shaped like the plugin's `TorProxyFailure`: its toString carries the type.
class TorProxyFailure {
  TorProxyFailure(this.message);
  final String message;

  @override
  String toString() => 'TorProxyFailure: $message';
}

void main() {
  setUp(() {
    // The UI isolate with Tor selected: TorHost refuses a start that has
    // neither a route nor a route check (N-f).
    TorHost.routeChanged(tor: true);
  });

  tearDown(() async {
    await EmbeddedTorService.stop();
    // A start a failed case left held can't stall the next one.
    EmbeddedTorService.debugReset();
    EmbeddedTorService.debugBackend = null;
  });

  test('starts off with no port', () {
    expect(EmbeddedTorService.state, EmbeddedTorState.off);
    expect(EmbeddedTorService.port, -1);
  });

  test('ensureStarted goes off → starting → ready and emits each '
      'change', () async {
    final backend = FakeTorBackend();
    EmbeddedTorService.debugBackend = backend;
    final seen = <EmbeddedTorState>[];
    final sub = EmbeddedTorService.changes.listen(seen.add);

    expect(EmbeddedTorService.state, EmbeddedTorState.off);
    final future = EmbeddedTorService.ensureStarted();
    // Readable synchronously, before the start completes.
    expect(EmbeddedTorService.state, EmbeddedTorState.starting);
    await future;

    expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    expect(EmbeddedTorService.port, 47123);
    await pumpEventQueue();
    expect(seen, [EmbeddedTorState.starting, EmbeddedTorState.ready]);
    await sub.cancel();
  });

  test('ensureStarted is a no-op once ready', () async {
    final backend = FakeTorBackend();
    EmbeddedTorService.debugBackend = backend;

    await EmbeddedTorService.ensureStarted();
    await EmbeddedTorService.ensureStarted();

    expect(backend.startCalls, 1);
    expect(backend.stopCalls, 0);
    expect(EmbeddedTorService.state, EmbeddedTorState.ready);
  });

  test('two concurrent ensureStarted calls start the backend once', () async {
    final backend = FakeTorBackend(startScript: [StartBehaviour.hold]);
    EmbeddedTorService.debugBackend = backend;

    final a = EmbeddedTorService.ensureStarted();
    final b = EmbeddedTorService.ensureStarted();
    await pumpEventQueue();
    expect(backend.startCalls, 1);

    backend.heldStart!.complete();
    await Future.wait([a, b]);

    expect(backend.startCalls, 1);
    expect(EmbeddedTorService.state, EmbeddedTorState.ready);
  });


  test('a backend that never bootstraps fails after the timeout', () {
    fakeAsync((async) {
      // Hung, not never: released at the end so the native start it leaves
      // in flight can't hold the next test's start.
      final backend = FakeTorBackend(startScript: [StartBehaviour.hang]);
      EmbeddedTorService.debugBackend = backend;
      var completed = false;

      EmbeddedTorService.ensureStarted().then((_) => completed = true);
      async.flushMicrotasks();
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);

      async.elapse(
        EmbeddedTorService.bootstrapTimeout - const Duration(seconds: 1),
      );
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(EmbeddedTorService.port, -1);
      expect(backend.stopCalls, 0);

      async.elapse(const Duration(seconds: 2));
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(EmbeddedTorService.port, -1);
      expect(completed, isTrue);
      // The abandoned native start is torn down, not left running.
      expect(backend.stopCalls, 1);

      // Leave the static service clean inside the fake zone.
      backend.release();
      EmbeddedTorService.stop();
      async.flushMicrotasks();
    });
  });

  test('a hung abandoned native start blocks a new start no longer than '
      'the bootstrap timeout, and no second native start overlaps it', () {
    fakeAsync((async) {
      // `hang`: a native start that ignores the plugin's cancel-on-stop.
      final backend = FakeTorBackend(
        startScript: [StartBehaviour.hang, StartBehaviour.succeed],
      );
      EmbeddedTorService.debugBackend = backend;

      EmbeddedTorService.ensureStarted();
      async.flushMicrotasks();
      EmbeddedTorService.stop();
      async.flushMicrotasks();
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      // The stop is issued at once, not after the start returns.
      expect(backend.calls, ['start', 'stop']);

      var done = false;
      EmbeddedTorService.ensureStarted().then((_) => done = true);
      async.flushMicrotasks();
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);

      async.elapse(
        EmbeddedTorService.bootstrapTimeout - const Duration(seconds: 1),
      );
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(backend.startCalls, 1);

      async.elapse(const Duration(seconds: 2));
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(EmbeddedTorService.port, -1);
      expect(done, isTrue);
      // The hung first start was never joined by a second one.
      expect(backend.startCalls, 1);

      // Release it, so the static service is clean for the next test; the
      // abandoned starts still publish nothing.
      backend.release();
      async.flushMicrotasks();
      expect(backend.startCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      // The client it brought up despite the cancel is torn down (N1).
      expect(backend.bootstrapped, isFalse);
      EmbeddedTorService.stop();
      async.elapse(EmbeddedTorService.bootstrapTimeout * 2);
    });
  });

  test('the bootstrap timeout is 90 seconds', () {
    expect(EmbeddedTorService.bootstrapTimeout, const Duration(seconds: 90));
  });

  test('a start that throws ends in failed', () async {
    final backend = FakeTorBackend(startScript: [StartBehaviour.fail]);
    EmbeddedTorService.debugBackend = backend;

    await EmbeddedTorService.ensureStarted();

    expect(EmbeddedTorService.state, EmbeddedTorState.failed);
    expect(EmbeddedTorService.port, -1);
  });

  test('stop() during starting → off and the native stop is issued at '
      'once; the cancelled start never moves the state to ready', () async {
    final backend = FakeTorBackend(startScript: [StartBehaviour.hold]);
    EmbeddedTorService.debugBackend = backend;
    final seen = <EmbeddedTorState>[];
    final sub = EmbeddedTorService.changes.listen(seen.add);

    final starting = EmbeddedTorService.ensureStarted();
    await pumpEventQueue();
    expect(EmbeddedTorService.state, EmbeddedTorState.starting);

    // Off at once, and the native stop goes out at once: the plugin cancels
    // its own bootstrap and drops whatever a late start built.
    final stopped = EmbeddedTorService.stop();
    expect(EmbeddedTorService.state, EmbeddedTorState.off);
    expect(backend.calls, ['start', 'stop']);

    await stopped;
    await starting;
    await pumpEventQueue();

    expect(EmbeddedTorService.state, EmbeddedTorState.off);
    expect(EmbeddedTorService.port, -1);
    expect(seen, [EmbeddedTorState.starting, EmbeddedTorState.off]);
    // No second stop: the one above covered the cancelled start.
    expect(backend.calls, ['start', 'stop']);
    expect(backend.bootstrapped, isFalse);
    await sub.cancel();
  });

  test('ensureStarted after stop() during starting starts afresh, once the '
      'stop has cancelled the first start', () async {
    final backend = FakeTorBackend(
      startScript: [StartBehaviour.hold, StartBehaviour.succeed],
    );
    EmbeddedTorService.debugBackend = backend;

    final first = EmbeddedTorService.ensureStarted();
    await pumpEventQueue();
    final stopped = EmbeddedTorService.stop();
    final second = EmbeddedTorService.ensureStarted();
    await Future.wait([first, stopped, second]);

    expect(backend.calls, ['start', 'stop', 'start']);
    expect(backend.startCalls, 2);
    expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    expect(EmbeddedTorService.port, 47123);
  });

  test('a stop during the plugin\'s init gap cancels nothing: the client '
      'that comes up afterwards is torn down (N1)', () async {
    final backend = FakeTorBackend(initGate: Completer<void>());
    EmbeddedTorService.debugBackend = backend;

    unawaited(EmbeddedTorService.ensureStarted());
    await pumpEventQueue();
    await EmbeddedTorService.stop();
    expect(EmbeddedTorService.state, EmbeddedTorState.off);
    expect(backend.stopCalls, 1);

    // Tor.init() returns; the plugin's start runs under the new generation
    // and brings a client up although Tor is off.
    backend.releaseInit();
    await pumpEventQueue();

    expect(backend.bootstrapped, isFalse,
        reason: 'a live client left running while Tor is off');
    expect(backend.stopCalls, 2);
    expect(EmbeddedTorService.state, EmbeddedTorState.off);
    expect(EmbeddedTorService.port, -1);
  });

  test('Tor → Direct → Tor across the init gap: the stale client is stopped '
      'before the new start, which then reaches ready (N1)', () async {
    final backend = FakeTorBackend(initGate: Completer<void>());
    EmbeddedTorService.debugBackend = backend;

    unawaited(EmbeddedTorService.ensureStarted());
    await pumpEventQueue();
    unawaited(EmbeddedTorService.stop());
    final again = EmbeddedTorService.ensureStarted();
    await pumpEventQueue();
    // The new start waits for the first native start.
    expect(backend.startCalls, 1);
    expect(EmbeddedTorService.state, EmbeddedTorState.starting);

    backend.releaseInit();
    await again;
    await pumpEventQueue();

    // The newer generation is starting when the stale start returns, so
    // _stopStale leaves it to that start, which stops the stale client
    // before its own start.
    expect(backend.calls, ['start', 'stop', 'stop', 'start']);
    expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    expect(EmbeddedTorService.port, 47123);
  });

  test('Tor → Direct mid-bootstrap: the native stop is issued immediately '
      '(I3)', () {
    fakeAsync((async) {
      final backend = FakeTorBackend(startScript: [StartBehaviour.hold]);
      EmbeddedTorService.debugBackend = backend;

      EmbeddedTorService.ensureStarted();
      async.elapse(const Duration(seconds: 10));
      expect(backend.stopCalls, 0);

      EmbeddedTorService.stop();
      // No time passes: the stop doesn't wait for the start.
      async.flushMicrotasks();
      expect(backend.stopCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      async.flushMicrotasks();
    });
  });

  test('Tor → Direct → Tor with a stuck first start: the new start waits '
      'only for the plugin\'s own stop, not its 90 s budget (I3)', () {
    fakeAsync((async) {
      final backend = FakeTorBackend(
        startScript: [StartBehaviour.hold, StartBehaviour.succeed],
        stopTakes: const Duration(seconds: 2),
      );
      EmbeddedTorService.debugBackend = backend;

      EmbeddedTorService.ensureStarted();
      async.elapse(const Duration(seconds: 5));
      EmbeddedTorService.stop();
      EmbeddedTorService.ensureStarted();
      async.flushMicrotasks();
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      // One native start at a time: nothing before the stop has finished.
      expect(backend.startCalls, 1);

      async.elapse(const Duration(seconds: 3));
      expect(backend.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(backend.calls, ['start', 'stop', 'start']);
    });
  });

  test('debugReset drops a held start, so the next start runs at once '
      '(T4)', () async {
    final stuck = FakeTorBackend(startScript: [StartBehaviour.never]);
    EmbeddedTorService.debugBackend = stuck;
    unawaited(EmbeddedTorService.ensureStarted());
    await pumpEventQueue();
    expect(EmbeddedTorService.state, EmbeddedTorState.starting);

    EmbeddedTorService.debugReset();
    expect(EmbeddedTorService.state, EmbeddedTorState.off);
    TorHost.routeChanged(tor: true);

    final fresh = FakeTorBackend();
    EmbeddedTorService.debugBackend = fresh;
    await EmbeddedTorService.ensureStarted();
    expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    expect(fresh.startCalls, 1);
  });


  test('failed → ensureStarted stops the backend, then restarts to '
      'ready', () async {
    final backend = FakeTorBackend(
      startScript: [StartBehaviour.fail, StartBehaviour.succeed],
    );
    EmbeddedTorService.debugBackend = backend;

    await EmbeddedTorService.ensureStarted();
    expect(EmbeddedTorService.state, EmbeddedTorState.failed);

    final retry = EmbeddedTorService.ensureStarted();
    expect(EmbeddedTorService.state, EmbeddedTorState.starting);
    await retry;

    expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    expect(EmbeddedTorService.port, 47123);
    expect(backend.calls, ['start', 'stop', 'start']);
  });

  test('a retry from failed that is abandoned before it runs issues no '
      'stop of its own', () async {
    final backend = FakeTorBackend(startScript: [StartBehaviour.fail]);
    EmbeddedTorService.debugBackend = backend;

    await EmbeddedTorService.ensureStarted();
    expect(EmbeddedTorService.state, EmbeddedTorState.failed);
    backend.calls.clear();

    // Retry, then switch Tor off before the retry's first step runs.
    unawaited(EmbeddedTorService.ensureStarted());
    await EmbeddedTorService.stop();
    await pumpEventQueue();

    // Only stop()'s own (tracked) stop. The abandoned generation must not
    // issue the restart's untracked one, nor start the client.
    expect(backend.calls, ['stop']);
    expect(EmbeddedTorService.state, EmbeddedTorState.off);
  });

  test('port is -1 in every state except ready', () async {
    final backend = FakeTorBackend(
      startScript: [StartBehaviour.hold, StartBehaviour.fail],
    );
    EmbeddedTorService.debugBackend = backend;

    // off
    expect(EmbeddedTorService.port, -1);

    // starting — even if the backend already reports a port.
    final start = EmbeddedTorService.ensureStarted();
    await pumpEventQueue();
    expect(EmbeddedTorService.state, EmbeddedTorState.starting);
    expect(EmbeddedTorService.port, -1);

    // ready
    backend.heldStart!.complete();
    await start;
    expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    expect(EmbeddedTorService.port, 47123);

    // off again
    await EmbeddedTorService.stop();
    expect(EmbeddedTorService.state, EmbeddedTorState.off);
    expect(EmbeddedTorService.port, -1);

    // failed
    await EmbeddedTorService.ensureStarted();
    expect(EmbeddedTorService.state, EmbeddedTorState.failed);
    expect(EmbeddedTorService.port, -1);
  });

  test('ready but the backend lost its port: port is -1 and ensureStarted '
      'restarts to ready', () async {
    final backend = FakeTorBackend();
    EmbeddedTorService.debugBackend = backend;
    await EmbeddedTorService.ensureStarted();
    expect(EmbeddedTorService.port, 47123);

    // The plugin tears its proxy down on its own when it dies.
    await backend.stop();
    expect(EmbeddedTorService.port, -1);

    final restart = EmbeddedTorService.ensureStarted();
    expect(EmbeddedTorService.state, EmbeddedTorState.starting);
    await restart;

    expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    expect(EmbeddedTorService.port, 47123);
    expect(backend.calls, ['start', 'stop', 'stop', 'start']);
  });

  test('a backend failure event moves ready to failed and emits it', () async {
    // The automatic retry (M2) fails; the user's retry works.
    final backend = FakeTorBackend(
      startScript: [
        StartBehaviour.succeed,
        StartBehaviour.fail,
        StartBehaviour.succeed,
      ],
    );
    EmbeddedTorService.debugBackend = backend;
    await EmbeddedTorService.ensureStarted();
    final seen = <EmbeddedTorState>[];
    final sub = EmbeddedTorService.changes.listen(seen.add);

    backend.dieOnItsOwn();
    await pumpEventQueue();

    expect(EmbeddedTorService.state, EmbeddedTorState.failed);
    expect(EmbeddedTorService.port, -1);
    expect(seen, [
      EmbeddedTorState.failed,
      EmbeddedTorState.starting,
      EmbeddedTorState.failed,
    ]);

    // Retry works from there.
    await EmbeddedTorService.ensureStarted();
    expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    await sub.cancel();
  });

  test('ready, then the plugin publishes port -1 before any failure: the '
      'state is failed at once (M1)', () async {
    // The automatic retry (M2) fails, so failed is what stays.
    final backend = FakeTorBackend(
      startScript: [StartBehaviour.succeed, StartBehaviour.fail],
    );
    EmbeddedTorService.debugBackend = backend;
    await EmbeddedTorService.ensureStarted();
    final seen = <EmbeddedTorState>[];
    final sub = EmbeddedTorService.changes.listen(seen.add);

    backend.losePort();
    await pumpEventQueue();

    expect(EmbeddedTorService.state, EmbeddedTorState.failed);
    expect(EmbeddedTorService.port, -1);
    expect(seen, [EmbeddedTorState.failed]);

    // The failure report that follows doesn't emit failed itself: it only
    // releases the one automatic retry (R-A2c-c), which fails here.
    backend.reportFailure('proxy exited');
    await pumpEventQueue();
    expect(seen, [
      EmbeddedTorState.failed,
      EmbeddedTorState.starting,
      EmbeddedTorState.failed,
    ]);
    expect(backend.startCalls, 2);
    await sub.cancel();
  });

  test('port events while the client is alive, starting or off change '
      'nothing (M1)', () async {
    final backend = FakeTorBackend(
      startScript: [StartBehaviour.hold, StartBehaviour.succeed],
    );
    EmbeddedTorService.debugBackend = backend;

    // starting: the plugin broadcasts -1 at the top of its own start.
    unawaited(EmbeddedTorService.ensureStarted());
    await pumpEventQueue();
    backend.losePort();
    await pumpEventQueue();
    expect(EmbeddedTorService.state, EmbeddedTorState.starting);
    backend.release();
    await pumpEventQueue();
    expect(EmbeddedTorService.state, EmbeddedTorState.ready);

    // ready and alive: a port broadcast is just the port.
    backend.reportPort(47123);
    await pumpEventQueue();
    expect(EmbeddedTorService.state, EmbeddedTorState.ready);

    // off: our own stop broadcasts -1.
    await EmbeddedTorService.stop();
    backend.losePort();
    await pumpEventQueue();
    expect(EmbeddedTorService.state, EmbeddedTorState.off);
  });

  group('one automatic retry after a foreground failure (M2)', () {
    test('a client that dies in the foreground is retried once', () async {
      final backend = FakeTorBackend();
      EmbeddedTorService.debugBackend = backend;
      await EmbeddedTorService.ensureStarted();

      backend.dieOnItsOwn();
      await pumpEventQueue();

      expect(backend.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(EmbeddedTorService.port, 47123);
    });

    test('a lost port holds the retry until the report says why; an '
        'ordinary report releases exactly one (R-A2c-c)', () async {
      final backend = FakeTorBackend();
      EmbeddedTorService.debugBackend = backend;
      await EmbeddedTorService.ensureStarted();

      backend.losePort();
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(backend.startCalls, 1, reason: 'the report decides');

      backend.reportFailure(plugin.TorProxyFailure('proxy task exited'));
      await pumpEventQueue();
      expect(backend.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);

      // A second report for the same death starts nothing more.
      backend.reportFailure('proxy exited');
      await pumpEventQueue();
      expect(backend.startCalls, 2);
    });

    test('a lost port, then a report of a process-wide stop: failed, with no '
        'automatic restart; Retry restarts it (R-A2c-c)', () async {
      final backend = FakeTorBackend();
      EmbeddedTorService.debugBackend = backend;
      await EmbeddedTorService.ensureStarted();

      // The plugin's order: port -1 first, the report after its teardown.
      backend.losePort();
      await pumpEventQueue();
      backend.reportFailure(
        plugin.TorProxyFailure(
          'Tor proxy was stopped by a process-wide stop',
          processWideStop: true,
        ),
      );
      await pumpEventQueue();

      expect(backend.startCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(EmbeddedTorService.port, -1);
      expect(
        EmbeddedTorService.lastError,
        'TorProxyFailure: Tor proxy was stopped by a process-wide stop',
      );

      // The user's Retry (or a resume, or the next acquire) restarts it.
      await EmbeddedTorService.ensureStarted();
      expect(backend.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    });

    test('a process-wide stop reported with no port loss before it restarts '
        'nothing either (R-A2c-c)', () async {
      final backend = FakeTorBackend();
      EmbeddedTorService.debugBackend = backend;
      await EmbeddedTorService.ensureStarted();

      backend._bootstrapped = false;
      backend.reportFailure(
        plugin.TorProxyFailure('stopped', processWideStop: true),
      );
      await pumpEventQueue();
      expect(backend.startCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
    });

    test('the held retry is dropped by a stop, and by the app going to the '
        'background, whose resume retries instead (R-A2c-c, R6)', () async {
      final backend = FakeTorBackend();
      EmbeddedTorService.debugBackend = backend;
      await EmbeddedTorService.ensureStarted();

      backend.losePort();
      await pumpEventQueue();
      await EmbeddedTorService.stop();
      backend.reportFailure('proxy exited');
      await pumpEventQueue();
      expect(backend.startCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.off);

      await EmbeddedTorService.ensureStarted();
      expect(backend.startCalls, 2);
      backend.losePort();
      await pumpEventQueue();
      await EmbeddedTorService.onPause();
      backend.reportFailure('proxy exited');
      await pumpEventQueue();
      expect(backend.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);

      await EmbeddedTorService.onResume();
      expect(backend.startCalls, 3);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    });

    test('a retry that fails is not retried again; only a ready re-arms '
        'it', () async {
      final backend = FakeTorBackend(
        startScript: [
          StartBehaviour.succeed, // 1: ready
          StartBehaviour.fail, // 2: the automatic retry
          StartBehaviour.fail, // 3: the user's Retry
          StartBehaviour.succeed, // 4: the user's next Retry
          StartBehaviour.succeed, // 5: the automatic retry after ready
        ],
      );
      EmbeddedTorService.debugBackend = backend;
      await EmbeddedTorService.ensureStarted();

      backend.dieOnItsOwn();
      await pumpEventQueue();
      expect(backend.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);

      // Another failure without an intervening ready: no retry.
      backend.dieOnItsOwn();
      await pumpEventQueue();
      expect(backend.startCalls, 2);

      // The user's Retry fails too: still no automatic one.
      await EmbeddedTorService.ensureStarted();
      await pumpEventQueue();
      expect(backend.startCalls, 3);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);

      // Ready again re-arms it.
      await EmbeddedTorService.ensureStarted();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      backend.dieOnItsOwn();
      await pumpEventQueue();
      expect(backend.startCalls, 5);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    });

    test('a lost port holds the retry; a Retry that fails at once drops it, '
        'so the old client\'s late report starts no second automatic retry '
        '(R-A2c-c)', () async {
      final backend = FakeTorBackend(
        startScript: [
          StartBehaviour.succeed, // 1: ready
          StartBehaviour.fail, // 2: the user's Retry (or a leaseholder's)
        ],
      );
      EmbeddedTorService.debugBackend = backend;
      await EmbeddedTorService.ensureStarted();

      backend.losePort();
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(backend.startCalls, 1, reason: 'held for the report');

      await EmbeddedTorService.ensureStarted();
      expect(backend.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);

      // The old client's ordinary report arrives only now.
      backend.reportFailure(plugin.TorProxyFailure('proxy task exited'));
      await pumpEventQueue();
      expect(backend.startCalls, 2, reason: 'a second automatic retry');
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
    });

    test('a client that dies in the background is not retried until '
        'resume (R6)', () async {
      final backend = FakeTorBackend();
      EmbeddedTorService.debugBackend = backend;
      await EmbeddedTorService.ensureStarted();

      await EmbeddedTorService.onPause();
      backend.dieOnItsOwn();
      await pumpEventQueue();
      expect(backend.startCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);

      await EmbeddedTorService.onResume();
      expect(backend.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    });

    test('Tor switched off: a late failure report starts nothing', () async {
      final backend = FakeTorBackend();
      EmbeddedTorService.debugBackend = backend;
      await EmbeddedTorService.ensureStarted();
      await EmbeddedTorService.stop();

      backend.dieOnItsOwn();
      await pumpEventQueue();
      expect(backend.startCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
    });
  });

  group('lastError (M3)', () {
    test('a start that throws records type and message; ready clears it',
        () async {
      final backend = FakeTorBackend(
        startScript: [StartBehaviour.fail, StartBehaviour.succeed],
      );
      EmbeddedTorService.debugBackend = backend;
      expect(EmbeddedTorService.lastError, isNull);

      await EmbeddedTorService.ensureStarted();
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(
        EmbeddedTorService.lastError,
        'StateError: Bad state: bootstrap failed',
      );

      await EmbeddedTorService.ensureStarted();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(EmbeddedTorService.lastError, isNull);
    });

    test('a timeout is recorded', () {
      fakeAsync((async) {
        final backend = FakeTorBackend(startScript: [StartBehaviour.hang]);
        EmbeddedTorService.debugBackend = backend;
        EmbeddedTorService.ensureStarted();
        async.elapse(EmbeddedTorService.bootstrapTimeout +
            const Duration(seconds: 1));
        expect(EmbeddedTorService.state, EmbeddedTorState.failed);
        expect(EmbeddedTorService.lastError, startsWith('TimeoutException'));
        backend.release();
        EmbeddedTorService.stop();
        async.flushMicrotasks();
      });
    });

    test('a start without a circuit is recorded', () async {
      EmbeddedTorService.debugBackend = FakeTorBackend(readyPort: -1);
      await EmbeddedTorService.ensureStarted();
      expect(
        EmbeddedTorService.lastError,
        'StateError: Bad state: Tor client started without a circuit',
      );
    });

    test('a lost port, then the plugin\'s failure report: the report is '
        'what stays', () async {
      // The retry the report releases (R-A2c-c) stays open, so nothing
      // records over the report.
      final backend = FakeTorBackend(
        startScript: [StartBehaviour.succeed, StartBehaviour.hold],
      );
      EmbeddedTorService.debugBackend = backend;
      await EmbeddedTorService.ensureStarted();

      backend.losePort();
      await pumpEventQueue();
      expect(EmbeddedTorService.lastError, isNotNull);

      backend.reportFailure(TorProxyFailure('proxy task exited: EOF'));
      await pumpEventQueue();
      expect(
        EmbeddedTorService.lastError,
        'TorProxyFailure: proxy task exited: EOF',
      );
    });

    test('FW-BG addendum: a report that replaces the reason while the state '
        'stays failed is announced on changes (the Tor card and the '
        'leaseholders hear of it); the same reason again is not', () async {
      final backend = FakeTorBackend();
      EmbeddedTorService.debugBackend = backend;
      await EmbeddedTorService.ensureStarted();
      // In the background no automatic retry follows a death (R6), so the
      // state stays failed throughout.
      await EmbeddedTorService.onPause();
      final seen = <(EmbeddedTorState, String?)>[];
      final sub = EmbeddedTorService.changes.listen(
        (state) => seen.add((state, EmbeddedTorService.lastError)),
      );
      addTearDown(sub.cancel);

      backend.losePort();
      await pumpEventQueue();
      expect(seen, [
        (EmbeddedTorState.failed, 'Tor client lost its SOCKS port'),
      ]);

      // A report that says what the state change already announced.
      backend.reportFailure('Tor client lost its SOCKS port');
      await pumpEventQueue();
      expect(seen, hasLength(1));

      // The plugin's report replaces the reason.
      backend.reportFailure(plugin.TorProxyFailure('proxy task exited'));
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(seen, [
        (EmbeddedTorState.failed, 'Tor client lost its SOCKS port'),
        (EmbeddedTorState.failed, 'TorProxyFailure: proxy task exited'),
      ]);

      backend.reportFailure(plugin.TorProxyFailure('proxy task exited'));
      await pumpEventQueue();
      expect(seen, hasLength(2));
      expect(backend.startCalls, 1);
    });

    test('TB-6: absolute paths are replaced with <dir> before the line is '
        'logged or kept (they name the app\'s own directories)', () {
      String describe(Object e) => EmbeddedTorService.describeError(e);
      // iOS: the app container, with the space in "Application Support".
      expect(
        describe(
          StateError(
            'Problem accessing "/var/mobile/Containers/Data/Application/'
            '0F3C2B7A-1D2E-4F5A-9B8C-7D6E5F4A3B2C/Library/Application '
            'Support/arti/state": Permission denied',
          ),
        ),
        'StateError: Bad state: Problem accessing "<dir>": Permission denied',
      );
      // Android, unquoted, followed by more text.
      expect(
        describe('fs-mistrust: /data/user/0/app.bitbag/files/tor/cache is '
            'writable by others'),
        'fs-mistrust: <dir> is writable by others',
      );
      expect(
        describe(
          TorHostFailure("can't lock '/data/data/app.bitbag/app_flutter/tor'"),
        ),
        "can't lock '<dir>'",
      );
      // Not paths: relative ones, relay addresses, plain text.
      expect(
        describe('and/or 198.51.100.7:9001 timed out'),
        'and/or 198.51.100.7:9001 timed out',
      );
      expect(describe('Tor client lost its SOCKS port'),
          'Tor client lost its SOCKS port');
      // Nothing of a path survives the cut either.
      final long = describe(StateError('${'x' * 140} /var/mobile/Containers/'
          'Data/Application/ABC/Library/Caches/tor'));
      expect(long, isNot(contains('/var')));
      expect(long, isNot(contains('Containers')));
    });

    test('long errors are cut to about 160 characters, on one line', () {
      final long = StateError('x' * 400);
      final text = EmbeddedTorService.describeError(long);
      expect(text.length, lessThanOrEqualTo(160));
      expect(text, startsWith('StateError: Bad state: xxx'));
      expect(text, endsWith('…'));
      expect(
        EmbeddedTorService.describeError(StateError('a\n  b')),
        'StateError: Bad state: a b',
      );
    });

    test('stop() keeps it (the card hides it while off); debugReset clears '
        'it', () async {
      EmbeddedTorService.debugBackend = FakeTorBackend(
        startScript: [StartBehaviour.fail],
      );
      await EmbeddedTorService.ensureStarted();
      expect(EmbeddedTorService.lastError, isNotNull);
      await EmbeddedTorService.stop();
      expect(EmbeddedTorService.lastError, isNotNull);
      EmbeddedTorService.debugReset();
      expect(EmbeddedTorService.lastError, isNull);
    });
  });

  test('a failure event from a replaced backend is ignored', () async {
    final old = FakeTorBackend();
    EmbeddedTorService.debugBackend = old;
    await EmbeddedTorService.ensureStarted();
    await EmbeddedTorService.stop();

    final current = FakeTorBackend();
    EmbeddedTorService.debugBackend = current;
    await EmbeddedTorService.ensureStarted();

    old.dieOnItsOwn();
    await pumpEventQueue();
    expect(EmbeddedTorService.state, EmbeddedTorState.ready);
  });

  test('a start that returns without a port ends in failed', () async {
    final backend = FakeTorBackend(readyPort: -1);
    EmbeddedTorService.debugBackend = backend;

    await EmbeddedTorService.ensureStarted();

    expect(EmbeddedTorService.state, EmbeddedTorState.failed);
    expect(EmbeddedTorService.port, -1);
  });

  test('onPause / onResume put a ready client to sleep and wake it; the '
      'sleep goes out after TorHost.sleepDelay (I1)', () {
    fakeAsync((async) {
      final backend = FakeTorBackend();
      EmbeddedTorService.debugBackend = backend;
      EmbeddedTorService.ensureStarted();
      async.flushMicrotasks();

      EmbeddedTorService.onPause();
      async.flushMicrotasks();
      expect(backend.dormantCalls, isEmpty);
      async.elapse(TorHost.sleepDelay);
      expect(backend.dormantCalls, [true]);
      EmbeddedTorService.onResume();
      async.flushMicrotasks();

      expect(backend.dormantCalls, [true, false]);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    });
  });

  test('onPause / onResume do nothing while off', () async {
    final backend = FakeTorBackend();
    EmbeddedTorService.debugBackend = backend;

    await EmbeddedTorService.onPause();
    await EmbeddedTorService.onResume();

    expect(backend.dormantCalls, isEmpty);
    expect(backend.startCalls, 0);
    expect(EmbeddedTorService.state, EmbeddedTorState.off);
  });

  test('onResume restarts a client that died in the background', () async {
    final backend = FakeTorBackend();
    EmbeddedTorService.debugBackend = backend;
    await EmbeddedTorService.ensureStarted();

    await EmbeddedTorService.onPause();
    await backend.stop(); // the plugin lost its proxy while suspended
    await EmbeddedTorService.onResume();

    expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    expect(EmbeddedTorService.port, 47123);
    expect(backend.startCalls, 2);
  });
}
