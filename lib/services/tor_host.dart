// One Tor client per process, shared by every isolate in it (Task A2).
//
// Android runs up to three isolates that need Tor (the UI, Sentinel's
// foreground service, the WorkManager callback) and iOS two (the UI and the
// background refresh), all in one OS process. Dart statics are per isolate,
// so each has its own [EmbeddedTorService], but the plugin's native client is
// not per isolate either way: every start builds a fresh client and SOCKS
// listener (a second one doubles the relay traffic and finds the state
// directory locked), and a client whose isolate dies keeps running with
// nothing left in that isolate that can stop it. Its handles lived in that
// isolate's `Tor` singleton, and dropping them doesn't stop the accept loop,
// which runs on the process-wide Rust runtime (the fork's `lib/tor.dart`
// `stop()`, `rust/src/api/tor.rs` `start_tor`, `TorProxyState`; details in
// the A2 report).
//
// So one isolate, the owner, runs the client and the others lease it:
//
// - Claiming: the owner registers a port under [TorHost.portName] with the
//   process-wide IsolateNameServer before its native start, so an isolate
//   that starts meanwhile finds it and waits for its port instead of
//   starting a second client (Review Focus 1). It also registers its
//   isolate's control port under [TorHost.isolatePortName]. A ping there is
//   answered by the VM even while the owner's event loop is busy, so a slow
//   owner is never mistaken for a dead one.
// - A dead owner: when neither the owner nor its control port answers
//   within [TorHost.lookupTimeout], the owner died and left its mapping
//   behind. The caller removes the mapping (only while it is still that
//   port) and becomes the owner (Review Focus 2). Until its own client is
//   ready, its requests are refused.
// - Nothing is orphaned that Dart can prevent: a non-UI owner stops its
//   client when its last lease is released, and the UI stops it on
//   `AppLifecycleState.detached`, since its engine is destroyed right after.
//   Either way, with leaseholders or not: they get `gone`, and one of them
//   becomes the next owner once the old client has stopped.
// - What Dart can't prevent, a sweep cures (Task A2c): an engine destroyed
//   with no Dart callback at all (WorkManager's `onStopped`: a lost network
//   constraint, a cancel, the 10-minute cap) leaves its client running, and
//   the fork's `Tor.stopAllInProcess()` stops every client in the process,
//   whichever isolate started it. TorHost sweeps at exactly three points: a
//   takeover, before its own native start; Tor switched off in the UI; and
//   a launch whose route isn't Tor. A takeover is marked process-wide
//   ([TorHost.unsweptPortName]) before the dead mapping goes, so whichever
//   isolate claims next sweeps first, and the mark goes only once a sweep
//   has succeeded. The sweeping isolate stops its own client first, and a
//   client a sweep stopped elsewhere is not restarted automatically
//   (EmbeddedTorService, R-A2c-c).
// - The UI's route decides: switching away from Tor stops the client
//   wherever it runs, and every isolate's port is -1 from then on (R-A2b).
//
// Wiring: [EmbeddedTorService] runs its state machine unchanged (R1–R10, N1,
// M1–M3) over [_HostedBackend]. That is the native backend while this
// isolate owns the client, and a mirror of the owner's client while it
// leases one. So every surface that reads EmbeddedTorService (the home row,
// the Tor card, routeStatusProvider, the route gate) shows the process's
// client, whichever isolate runs it.
//
// Protocol. Every message is a map of strings, ints, bools, nulls and
// SendPorts, so it crosses isolate groups (each Flutter engine is its own
// group); the VM's ping answers and exit notices are plain strings:
//   to the owner:   {'op': 'acquire', 'reply': SendPort, 'isolate': SendPort,
//                    'ui': true (only from a UI whose route is Tor)}
//                   {'op': 'release', 'reply': SendPort}
//                   {'op': 'port', 'reply': SendPort}
//                   {'op': 'stop'}
//   from the owner: {'state': 'starting'|'ready'|'failed'|'off'|'gone',
//                    'port': int, 'error': String?, 'isolate': SendPort}
// The owner answers an acquire, then sends every state change to each
// leaseholder. `gone` means the owner is giving the client up: look up the
// next owner.

import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;

import 'embedded_tor_service.dart';
import 'tor_service.dart';

/// Where the owner's ports are published: [IsolateNameServerRegistry] in the
/// app, a fake through [TorHost.debugRegistry] in tests.
abstract class TorPortRegistry {
  SendPort? lookup(String name);
  bool register(SendPort port, String name);
  bool remove(String name);
}

/// The process-wide [IsolateNameServer].
class IsolateNameServerRegistry implements TorPortRegistry {
  const IsolateNameServerRegistry();

  @override
  SendPort? lookup(String name) => IsolateNameServer.lookupPortByName(name);

  @override
  bool register(SendPort port, String name) =>
      IsolateNameServer.registerPortWithName(port, name);

  @override
  bool remove(String name) => IsolateNameServer.removePortNameMapping(name);
}

/// A failure reported by the isolate that runs the client (its `lastError`),
/// or the loss of that isolate. Carries no user data.
class TorHostFailure implements Exception {
  TorHostFailure(this.message);

  final String message;

  @override
  String toString() => 'TorHostFailure: $message';
}

/// One isolate's hold on the process's Tor client, from [TorHost.acquire].
class TorHostLease {
  TorHostLease._();

  bool _released = false;

  /// Status only: the client's SOCKS port as this isolate last heard it, or
  /// -1 (not ready, or released). Never connect to it: connections go
  /// through `routeHttpClient` / `buildRoutedDio`, which ask [TorHost.port]
  /// per connection, because the port moves with a restart and a
  /// leaseholder's copy can lag the owner's.
  int get port => _released ? -1 : EmbeddedTorService.port;

  /// Whether this isolate runs the client, rather than leasing another
  /// isolate's.
  bool get ownsClient => !_released && TorHost._role == _Role.owner;

  /// Gives the lease back. In the UI isolate the client stays, following
  /// the route and the app lifecycle. Elsewhere, once this isolate holds no
  /// other lease: a leaseholder tells the owner, and an owner stops its
  /// client — handing it over first if other isolates lease it, because
  /// its isolate is about to end and a client left running could never be
  /// stopped again.
  Future<void> release() => TorHost._release(this);
}

enum _Role { none, owner, leaseholder }

class TorHost {
  TorHost._();

  /// The owner's request port, in the IsolateNameServer.
  static const portName = 'bag_tor_host';

  /// The owner isolate's control port, in the IsolateNameServer.
  static const isolatePortName = 'bag_tor_host.isolate';

  /// How long an owner may stay silent, with its control port silent too,
  /// before it counts as dead.
  static const lookupTimeout = Duration(milliseconds: 500);

  /// How long an owner that is alive (its control port answered) may take
  /// to answer before it is given up on for this attempt. It is not
  /// replaced: the caller tries again.
  static const unresponsiveTimeout = Duration(seconds: 10);

  /// How long to wait before looking again while the owner is giving the
  /// client up, or after a live owner didn't answer in time.
  static const lookupRetryDelay = Duration(milliseconds: 100);

  /// How long after the app goes to the background the client it owns
  /// goes to sleep (I1): 2 s on Android, none on iOS (N-g). On Android 7–11
  /// a Back at the root destroys the engine right after `detached`, and a
  /// sleep still waiting for its native result could hold that teardown
  /// back; deferred, a quick Back finds nothing in flight. iOS destroys no
  /// engine on a Back, and suspends the app within seconds of the
  /// background, so a deferred sleep there might never go out. A resume,
  /// `detached`, a stop, a route change or an acquire meanwhile cancels it.
  static Duration get sleepDelay =>
      TorService.isIOS ? Duration.zero : const Duration(seconds: 2);

  /// Test seam: a shorter [sleepDelay] for cases that run in real time.
  @visibleForTesting
  static Duration? debugSleepDelay;

  /// How long a sweep may take, and the stand-down before it, before it is
  /// given up on (R-A2c-d). The fork bounds a sweep at about 15 s per proxy
  /// plus a 15 s wait for what was already running: about 30 s for the one
  /// orphan a dead owner leaves.
  static const sweepTimeout = Duration(seconds: 35);

  /// Registered in the IsolateNameServer before the first native start in
  /// the process, by whichever isolate makes it, and never removed: a Tor
  /// client may have run in this process. A process without it can hold
  /// no client, so Tor off and a non-Tor launch have nothing to sweep and
  /// leave the Tor library unloaded.
  static const usedPortName = 'bag_tor_host.used';

  /// Registered by an isolate that found the owner dead, before it removes
  /// the dead mapping ([_removeDead]): a takeover the process hasn't been
  /// swept for yet, so the dead owner's client may still run. Process-wide,
  /// because the isolate that claims next may not be the one that removed
  /// the mapping: another isolate found the same dead owner first, or the
  /// remover gave up (its route check failed, it was stopped). So every
  /// claim, fresh or of this isolate's own mapping, sweeps before its
  /// native start while the mark is registered, and only that sweep, once
  /// it succeeds, removes it: a sweep that failed, timed out or never ran
  /// is tried again by the next start. Each mark is a port of its own
  /// ([_markUnswept]).
  static const unsweptPortName = 'bag_tor_host.unswept';

  /// How long a takeover waits before its native start, to see whether a
  /// second isolate that found the same dead mapping replaced it (M1).
  static const takeoverSettle = Duration(milliseconds: 30);

  /// Test seam: when set, used instead of the IsolateNameServer.
  @visibleForTesting
  static TorPortRegistry? debugRegistry;

  static TorPortRegistry get _registry =>
      debugRegistry ?? const IsolateNameServerRegistry();

  static const _pong = 'bag_tor_host.pong';
  static const _ownerExited = 'bag_tor_host.owner-exited';
  static const _leaseholderExited = 'bag_tor_host.leaseholder-exited:';
  static const Map<String, Object?> _gone = {'state': 'gone', 'port': -1};

  // ── This isolate ─────────────────────────────────────────────────────

  /// The route, as the UI isolate last saw it ([routeChanged]); null in
  /// other isolates. Set means this is the UI: its client follows the route
  /// and the lifecycle, not leases.
  static bool? _routeTor;

  /// Leases this isolate holds ([acquire] minus [TorHostLease.release]).
  static int _leases = 0;

  /// This isolate still wants the client: it is the UI, whose client
  /// follows the route, or it holds a lease. An owner that no longer wants
  /// it gives ownership up.
  static bool get _wantsClient => _routeTor != null || _leases > 0;

  /// The route re-check of the latest [acquire]: null in the UI, whose route
  /// is the one obeyed.
  static Future<bool> Function()? _stillTor;

  static _Role _role = _Role.none;
  static _HostedBackend? _hosted;

  /// This isolate has called the native start at least once, so a stop
  /// outside the owner role still reaches it (a start abandoned during a
  /// role change can bring a client up, N1).
  static bool _nativeUsed = false;

  // ── Owner ────────────────────────────────────────────────────────────

  static RawReceivePort? _ownerPort;

  /// Each leaseholder's update port, with the id its exit listener reports.
  static final Map<SendPort, int> _leaseholders = {};
  static int _nextLeaseholderId = 0;
  static StreamSubscription<EmbeddedTorState>? _changesSub;

  /// Ownership being given up: the client stops, then the mapping goes.
  static Future<void>? _ending;

  /// The native client is dormant.
  static bool _asleep = false;

  /// A sleep waiting out [sleepDelay].
  static Timer? _sleepTimer;

  /// The UI switched Tor off ({'op': 'stop'}). Sticks until an acquire from
  /// the UI, or this isolate's own fresh route check, says Tor again (M2):
  /// an isolate acting on a stale route reading is told `off`.
  static bool _offByUi = false;

  /// This isolate's sweep in flight ([_sweep]), until it is done. A start
  /// here waits for it: the sweep cancels every start in the process.
  static Future<bool>? _sweeping;

  // ── Leaseholder ──────────────────────────────────────────────────────

  static _Lease? _lease;

  /// The start that is looking for, or waiting on, an owner.
  static _Attempt? _attempt;

  /// The backend [EmbeddedTorService] runs on: [native] brokered across the
  /// process. One per native backend, so its identity is stable. Only
  /// EmbeddedTorService calls this.
  static EmbeddedTorBackend backendFor(EmbeddedTorBackend native) {
    final hosted = _hosted;
    if (hosted != null && identical(hosted.native, native)) return hosted;
    hosted?._detach();
    return _hosted = _HostedBackend(native);
  }

  /// Takes a lease on the process's Tor client, starting it if no isolate
  /// runs it: this isolate becomes the owner, or leases the owner's client.
  /// Waits up to [bootstrapBudget] for the client to be ready, then returns
  /// the lease either way; its port is -1 until the client is ready. Await
  /// [TorHostLease.release] when done, in a `finally`.
  ///
  /// [stillTor] re-reads the route (A3 passes a prefs reload). It is asked
  /// before every claim, takeover and retry, also for this lease's later
  /// restarts; false (or a throw) fails closed with no native start (M2).
  static Future<TorHostLease> acquire({
    required Duration bootstrapBudget,
    required Future<bool> Function() stillTor,
  }) async {
    _leases++;
    _stillTor = stillTor;
    _cancelSleep();
    final lease = TorHostLease._();
    try {
      await EmbeddedTorService.ensureStarted().timeout(bootstrapBudget);
    } on TimeoutException {
      // Not ready in time. The lease stands; requests are refused until it
      // is.
    } catch (_) {
      // No lease to give back (A3-M7): a count left behind would keep a
      // non-UI owner's client running past its last release.
      _leases--;
      rethrow;
    }
    return lease;
  }

  /// The SOCKS port this isolate's next Tor connection uses, or -1: while
  /// the client isn't ready, and in an isolate that neither runs nor leases
  /// it. A leaseholder asks the owner every time, so a port that moved
  /// with a restart is never used stale. Read it per connection, never once
  /// per client: it changes after a restart.
  static Future<int> port() async {
    switch (_role) {
      case _Role.owner:
        return EmbeddedTorService.port;
      case _Role.none:
        return -1;
      case _Role.leaseholder:
        final lease = _lease!;
        if (EmbeddedTorService.port <= 0) return -1;
        final reply = RawReceivePort(null, 'bag_tor_host.port');
        // Ended with the lease, so a hand-over answers -1 at once (M4).
        final waiter = _Attempt();
        lease.waiters.add(waiter);
        final answer = await _firstAnswer(
          reply,
          lease.ownerIsolate,
          () => lease.owner.send({'op': 'port', 'reply': reply.sendPort}),
          attempt: waiter,
        );
        lease.waiters.remove(waiter);
        reply.close();
        if (!identical(_lease, lease)) return -1;
        if (answer == _Answer.dead) {
          _onLeaseUpdate(lease, _ownerExited);
          return -1;
        }
        if (answer is! Map || answer['state'] != 'ready') return -1;
        final port = answer['port'];
        return port is int && port > 0 ? port : -1;
    }
  }

  /// The UI isolate's route, at launch (`main()`, M9) and on every change
  /// ([TorService.followRoute]). Away from Tor, the client is stopped
  /// wherever it runs (R-A2b): here, at once (state off, port -1), and in
  /// any other registered owner by telling it, whatever this isolate's role
  /// (M1). From then on this isolate's acquirers are told `off`.
  ///
  /// Then, once this isolate's own stop is done, every client the process
  /// still runs is swept (R-A2c-b 2 and 3): an orphan left by an engine
  /// that died without a Dart callback, or a client an owner hasn't
  /// stopped yet. Not when no Tor client has run in this process
  /// ([usedPortName]). Returns at once; the sweep never throws.
  static void routeChanged({required bool tor}) {
    _routeTor = tor;
    _cancelSleep();
    if (tor) return;
    final registered = _registry.lookup(portName);
    if (registered != null && registered != _ownerPort?.sendPort) {
      registered.send(const {'op': 'stop'});
    }
    final standDown = EmbeddedTorService.stop().catchError(_log);
    if (_registry.lookup(usedPortName) == null) return;
    unawaited(_sweep('after Tor off', standDown));
  }

  /// The app is back in the foreground: a sleep still waiting is dropped.
  /// Called by [EmbeddedTorService.onResume].
  static void foregrounded() => _cancelSleep();

  /// The UI's engine is being destroyed (Android 7–11 Back at the root,
  /// app termination): this isolate runs no further events. An owner stops
  /// its client now, leaseholders or not — its handles die with the
  /// isolate, and a client left running could never be stopped (R-A2a).
  /// Leaseholders get `gone` and one of them takes over. A leaseholder
  /// gives its lease back.
  static void onDetached() {
    // Nothing may sit in the plugin's queue ahead of the stop (I1).
    _cancelSleep();
    if (_role == _Role.owner) {
      unawaited(_endOwnership());
    } else {
      unawaited(EmbeddedTorService.stop().catchError(_log));
    }
  }

  // ── Leases ───────────────────────────────────────────────────────────

  static Future<void> _release(TorHostLease lease) async {
    if (lease._released) return;
    lease._released = true;
    _leases--;
    if (_wantsClient) return;
    if (_role == _Role.owner) return _endOwnership();
    await EmbeddedTorService.stop();
  }

  // ── Starting ─────────────────────────────────────────────────────────

  static Future<void> _start(EmbeddedTorBackend native) {
    // The UI's common case, no other isolate running Tor and no sweep of
    // its own in flight, claims synchronously and calls the native start
    // with no gap, unless a takeover is still unswept: its settle and sweep
    // come first. An isolate with a route re-check asks it first, and one
    // whose route isn't declared Tor starts nothing (N-f).
    if (_routeTor == true && _stillTor == null && _sweeping == null) {
      final claim = _claimNow();
      if (claim != _Claim.none) {
        // The mark is read after the claim: it is registered before the
        // dead mapping goes, so every claim that follows the removal sees
        // it.
        if (!_unswept) return _startNative(native);
        return _startHosted(native, claimed: claim);
      }
    }
    return _startHosted(native);
  }

  static Future<void> _startNative(EmbeddedTorBackend native) {
    _cancelSleep();
    _nativeUsed = true;
    _asleep = false;
    // From now on a Tor client may run in this process (a no-op once set).
    _registry.register(Isolate.current.controlPort, usedPortName);
    return native.start();
  }

  /// [_stillTor], read now: false when it says otherwise or throws. Without
  /// a re-check, true only in the UI with its route declared Tor (N-f):
  /// a route declared otherwise, or none at all, fails closed.
  static Future<bool> _routeStillTor() async {
    final check = _stillTor;
    if (check == null) return _routeTor == true;
    try {
      if (!await check()) return false;
    } catch (e) {
      _log(e);
      return false;
    }
    // A fresh read says Tor: the UI has turned it back on.
    _offByUi = false;
    return true;
  }

  /// Claims ownership if no isolate holds it: [_Claim.fresh] if this
  /// isolate registered just now, [_Claim.kept] if the mapping was already
  /// its own, [_Claim.none] if another isolate holds it or this one is
  /// giving it up.
  static _Claim _claimNow() {
    if (_ending != null) return _Claim.none;
    if (_role == _Role.owner) {
      if (_registry.lookup(portName) == _ownerPort?.sendPort) {
        return _Claim.kept;
      }
      // Displaced (another isolate took over a mapping it found dead): our
      // leaseholders look for the new owner too (told by _dropOwnership).
      _dropOwnership();
    }
    if (_role == _Role.leaseholder) _endLease(release: true);
    if (_registry.lookup(portName) != null) return _Claim.none;
    return _register() ? _Claim.fresh : _Claim.none;
  }

  /// A takeover is waiting for its sweep ([unsweptPortName]).
  static bool get _unswept => _registry.lookup(unsweptPortName) != null;

  static bool _register() {
    final port = RawReceivePort(_onRequest, 'bag_tor_host')
      ..keepIsolateAlive = false;
    if (!_registry.register(port.sendPort, portName)) {
      port.close();
      return false;
    }
    // Registration order (M5): the request port goes first, so an isolate
    // looking up between the two calls below finds this request port next
    // to the previous owner's control port, or none. That is harmless: it
    // pings the stale control port, but this port answers its request
    // within the lookup timeout, and only silence from both means dead.
    // A control port left by a dead owner is replaced.
    _registry.remove(isolatePortName);
    _registry.register(Isolate.current.controlPort, isolatePortName);
    _ownerPort = port;
    _role = _Role.owner;
    _changesSub = EmbeddedTorService.changes.listen((_) => _pushAll());
    return true;
  }

  /// Finds the owner, or becomes it: leases a live owner's client, takes
  /// over from a dead one, waits out one that is giving the client up.
  /// While a takeover is unswept ([unsweptPortName]), any claim sweeps
  /// before its native start, whichever isolate removed the dead mapping
  /// ([_sweptBeforeStart]). [claimed] is a claim [_start] has just made.
  /// Completes once leased and ready, or once this isolate's own native
  /// start completes; throws, failing closed, if the owner reports a
  /// failure, the route is no longer Tor or a takeover's sweep failed.
  /// Cancelled by [_HostedBackend.stop].
  static Future<void> _startHosted(
    EmbeddedTorBackend native, {
    _Claim? claimed,
  }) async {
    final attempt = _attempt = _Attempt();
    var claim = claimed;
    try {
      while (!attempt.cancelled) {
        if (claim == null) {
          final ending = _ending;
          if (ending != null) {
            await ending;
            continue;
          }
          // A sweep of this isolate's would cancel the start that follows
          // it.
          final sweeping = _sweeping;
          if (sweeping != null) {
            await sweeping;
            continue;
          }
          // Before every claim, takeover and retry: a route switched off
          // meanwhile starts nothing (M2).
          if (!await _routeStillTor()) {
            throw TorHostFailure('the route is no longer Tor');
          }
          if (attempt.cancelled) return;
          if (_ending != null || _sweeping != null) continue;
          claim = _claimNow();
        }
        final current = claim;
        claim = null;
        if (current != _Claim.none) {
          if (_unswept) {
            // A fresh registration may have been replaced meanwhile by an
            // isolate that took over the same dead owner (M1).
            if (current == _Claim.fresh && !await _keptAfterTakeover(attempt)) {
              continue;
            }
            if (!await _sweptBeforeStart(attempt)) return;
          } else if (_stillTor != null &&
              !await _stillTorAfterClaim(attempt)) {
            return;
          }
          return await _startNative(native);
        }
        final owner = _registry.lookup(portName);
        if (owner == null) continue;
        final ownerIsolate = _registry.lookup(isolatePortName);
        final outcome = await _leaseFrom(owner, ownerIsolate, attempt);
        switch (outcome) {
          case _Answer.dead:
            _removeDead(owner, ownerIsolate);
          case _Answer.unresponsive || _Leased.gone:
            await Future<void>.delayed(lookupRetryDelay);
          case _Answer.cancelled || _Leased.ready || _Leased.off:
            return;
          case _LeaseFailed(:final error):
            throw TorHostFailure(error ?? 'Tor client failed');
        }
      }
    } finally {
      if (identical(_attempt, attempt)) _attempt = null;
    }
  }

  /// After a fresh claim while a takeover is unswept, whichever isolate
  /// removed the dead mapping: another isolate that found the same dead
  /// owner may have replaced this registration meanwhile, since the
  /// registry has no compare-and-swap. Waits [takeoverSettle], then keeps
  /// ownership only if the mapping is still this isolate's. Otherwise it
  /// gives it up before any native start, and the caller leases the
  /// other's client (M1). Ownership nobody here wants any more (a non-UI
  /// isolate whose leases were released meanwhile) is given up too.
  static Future<bool> _keptAfterTakeover(_Attempt attempt) async {
    await Future<void>.delayed(takeoverSettle);
    final port = _ownerPort;
    final mine = port != null && _registry.lookup(portName) == port.sendPort;
    if (mine && !attempt.cancelled) return true;
    if (!mine || !_wantsClient) _dropOwnership();
    return false;
  }

  /// Before the native start of an ordinary claim (fresh or kept, no
  /// takeover unswept) by an isolate with a route re-check (TB-2). The read
  /// before the claim can predate a switch to Tor off that found no owner to
  /// tell: the UI's [routeChanged] sends its stop only to a registered
  /// owner, and sweeps only once a client has run in the process. Read
  /// again now that this isolate is registered: a switch-off from here on
  /// reaches it as a stop, and one before it shows in this read. False if
  /// the start was cancelled meanwhile; throws, failing closed with the
  /// claim given up, if the route is no longer Tor.
  static Future<bool> _stillTorAfterClaim(_Attempt attempt) async {
    if (!await _routeStillTor()) {
      _dropOwnership();
      throw TorHostFailure('the route is no longer Tor');
    }
    if (attempt.cancelled) {
      if (!_wantsClient) _dropOwnership();
      return false;
    }
    return true;
  }

  /// Before the native start of a claim made while a takeover is unswept
  /// (after [_keptAfterTakeover] for a fresh one): reads the route again,
  /// since the claim and its settle took time (N-h), then sweeps the
  /// process (R-A2c-b 1). The dead owner's client may still be running,
  /// with nothing left that could stop it: an engine WorkManager destroyed
  /// mid-job, say. This isolate's own client isn't running: every native
  /// start here is preceded by a stop of whatever an earlier one left
  /// (restart, N1), so the sweep can't hit it. A sweep that succeeds
  /// removes the mark, whatever happens to this start. False if the start
  /// was cancelled meanwhile; throws, failing closed, if the route is no
  /// longer Tor or the sweep failed (R-A2c-d). After a failed sweep both
  /// ownership and the mark stay: no other isolate starts next to what the
  /// dead owner may have left, and the next start here sweeps again.
  static Future<bool> _sweptBeforeStart(_Attempt attempt) async {
    if (!await _routeStillTor()) {
      _dropOwnership();
      throw TorHostFailure('the route is no longer Tor');
    }
    final mark = _registry.lookup(unsweptPortName);
    final swept = await _sweep('before taking over', Future<void>.value());
    // Removed only while it is still the mark this sweep was for. A mark
    // registered during the sweep (the name was free again) is a port of
    // its own, so it is never this one and stays for the next start. Nor
    // can a takeover begin behind this mark while the sweep runs (its
    // register failing because this one stands): an isolate marks only on
    // finding the owner dead, and this isolate holds the mapping
    // throughout and its control port answers pings.
    if (swept && mark != null && _registry.lookup(unsweptPortName) == mark) {
      _registry.remove(unsweptPortName);
    }
    if (attempt.cancelled) {
      if (!_wantsClient) _dropOwnership();
      return false;
    }
    if (!swept) {
      throw TorHostFailure(
        'Tor clients a previous owner left could not be stopped',
      );
    }
    return true;
  }

  /// Asks [owner] for a lease. On an answer this isolate becomes its
  /// leaseholder and waits for the client to be ready (or to fail, stop or
  /// be handed over).
  static Future<Object> _leaseFrom(
    SendPort owner,
    SendPort? ownerIsolate,
    _Attempt attempt,
  ) async {
    final updates = RawReceivePort(null, 'bag_tor_host.lease')
      ..keepIsolateAlive = false;
    final lease = _Lease(owner, ownerIsolate, updates);
    final first = await _firstAnswer(
      updates,
      ownerIsolate,
      () => owner.send({
        'op': 'acquire',
        'reply': updates.sendPort,
        'isolate': Isolate.current.controlPort,
        // The UI's route is Tor: lifts an earlier `stop` (M2).
        if (_routeTor == true) 'ui': true,
      }),
      later: (message) => _onLeaseUpdate(lease, message),
      attempt: attempt,
    );
    final answered = first is Map && first['state'] != 'gone';
    if (!answered || attempt.cancelled) {
      // A lease the owner recorded, or may still record once it gets to
      // the request, is given back.
      if (answered ||
          first == _Answer.cancelled ||
          first == _Answer.unresponsive) {
        owner.send({'op': 'release', 'reply': updates.sendPort});
      }
      updates.close();
      if (attempt.cancelled) return _Answer.cancelled;
      if (first is Map) return _Leased.gone;
      return first is _Answer ? first : _Answer.dead;
    }
    _lease = lease;
    _role = _Role.leaseholder;
    final isolate = first['isolate'];
    if (isolate is SendPort) lease.ownerIsolate = isolate;
    final ownerControl = lease.ownerIsolate;
    if (ownerControl != null) {
      Isolate(
        ownerControl,
      ).addOnExitListener(updates.sendPort, response: _ownerExited);
    }
    final outcome = attempt.expect();
    _onLeaseUpdate(lease, first);
    return outcome;
  }

  /// A state update from the owner (or its exit) for [lease].
  static void _onLeaseUpdate(_Lease lease, Object? message) {
    if (!identical(_lease, lease)) return;
    final Map<Object?, Object?>? update = switch (message) {
      _ownerExited => const {
        'state': 'gone',
        'error': 'the isolate running Tor exited',
      },
      Map() => message,
      _ => null,
    };
    if (update == null) return; // A late pong.
    final state = update['state'];
    final port = update['port'];
    final error = update['error'];
    final wasReady = lease.ready;
    lease.port = port is int ? port : -1;
    lease.ready = state == 'ready' && lease.port > 0;
    final attempt = _attempt;
    final waiting = attempt != null && attempt.expecting;
    switch (state) {
      case 'ready':
        if (waiting) {
          if (lease.ready) attempt.decide(_Leased.ready);
        } else if (lease.ready &&
            EmbeddedTorService.state == EmbeddedTorState.failed) {
          // The owner recovered after this isolate had given up: follow it,
          // once per ready report (M7). Sentinel has no resume to retry on.
          unawaited(EmbeddedTorService.ensureStarted());
        }
      case 'starting':
        if (wasReady) _lost('Tor client restarting');
      case 'failed':
        final reason = error is String ? error : null;
        if (waiting) {
          attempt.decide(_LeaseFailed(reason));
        } else if (wasReady) {
          _lost(reason ?? 'Tor client failed');
        } else if (reason != null) {
          // Still failed, for a new reason (the owner's plugin report
          // replaced its lost-port one): the mirror follows it.
          EmbeddedTorService.ownerFailureChanged(reason);
        }
      case 'off':
        // The route is no longer Tor: this isolate stops too.
        _endLease(release: true);
        if (waiting) attempt.decide(_Leased.off);
        unawaited(EmbeddedTorService.stop().catchError(_log));
      case 'gone':
        _endLease(release: false);
        if (waiting) {
          attempt.decide(_Leased.gone);
        } else if (wasReady) {
          _lost(error is String ? error : 'Tor client handed over');
        }
    }
  }

  /// The owner's client went away while this isolate used it: to
  /// EmbeddedTorService that is a client that died on its own (failed,
  /// then its one automatic retry, M2), which looks for the owner again.
  static void _lost(String reason) {
    final hosted = _hosted;
    if (hosted == null) return;
    hosted._failures.add(TorHostFailure(reason));
    hosted._events.add(-1);
  }

  static void _endLease({required bool release}) {
    final lease = _lease;
    if (lease == null) return;
    _lease = null;
    if (_role == _Role.leaseholder) _role = _Role.none;
    if (release) {
      lease.owner.send({'op': 'release', 'reply': lease.updates.sendPort});
    }
    final ownerControl = lease.ownerIsolate;
    if (ownerControl != null) {
      Isolate(ownerControl).removeOnExitListener(lease.updates.sendPort);
    }
    lease.updates.close();
    for (final waiter in List.of(lease.waiters)) {
      waiter.cancel();
    }
  }

  static void _removeDead(SendPort owner, SendPort? ownerIsolate) {
    // Only the mapping that failed to answer: another isolate may have
    // replaced it meanwhile. Compare and remove are two calls, not one: a
    // racer in between is caught by the takeover re-check
    // ([_keptAfterTakeover]).
    if (_registry.lookup(portName) != owner) return;
    // Marked before the mapping goes: whichever isolate claims next, this
    // one or another, sweeps what the dead owner may have left.
    _markUnswept();
    _registry.remove(portName);
    if (ownerIsolate != null &&
        _registry.lookup(isolatePortName) == ownerIsolate) {
      _registry.remove(isolatePortName);
    }
    debugPrint('[TorHost] the isolate that ran Tor is gone; taking over');
  }

  /// Registers [unsweptPortName] as a port of its own, closed at once: only
  /// its identity counts ([_sweptBeforeStart]). If a mark is already
  /// registered, that one stands for this takeover too.
  static void _markUnswept() {
    final mark = RawReceivePort(null, 'bag_tor_host.unswept');
    final port = mark.sendPort;
    mark.close();
    _registry.register(port, unsweptPortName);
  }

  /// Sends a request through [send] and waits for the first answer on
  /// [port], pinging [ownerIsolate]'s control port at the same time. The
  /// owner counts as dead when neither answers within [lookupTimeout]; an
  /// owner whose control port answered gets [unresponsiveTimeout]. Later
  /// messages go to [later].
  static Future<Object?> _firstAnswer(
    RawReceivePort port,
    SendPort? ownerIsolate,
    void Function() send, {
    void Function(Object? message)? later,
    _Attempt? attempt,
  }) {
    final answer = Completer<Object?>();
    var alive = false;
    port.handler = (Object? message) {
      if (answer.isCompleted) {
        later?.call(message);
      } else if (message == _pong) {
        alive = true;
      } else {
        answer.complete(message);
      }
    };
    send();
    if (ownerIsolate != null) {
      Isolate(
        ownerIsolate,
      ).ping(port.sendPort, response: _pong, priority: Isolate.immediate);
    }
    final dead = Timer(lookupTimeout, () {
      if (!alive && !answer.isCompleted) answer.complete(_Answer.dead);
    });
    final slow = Timer(unresponsiveTimeout, () {
      if (!answer.isCompleted) answer.complete(_Answer.unresponsive);
    });
    attempt?.onCancel = () {
      if (!answer.isCompleted) answer.complete(_Answer.cancelled);
    };
    return answer.future.whenComplete(() {
      dead.cancel();
      slow.cancel();
      attempt?.onCancel = null;
    });
  }

  // ── Owning ───────────────────────────────────────────────────────────

  static void _onRequest(Object? message) {
    if (message is String && message.startsWith(_leaseholderExited)) {
      final id = int.tryParse(message.substring(_leaseholderExited.length));
      _leaseholders.removeWhere((_, value) => value == id);
      if (_leaseholders.isEmpty) _scheduleSleep();
      return;
    }
    if (message is! Map) return;
    final reply = message['reply'];
    switch (message['op']) {
      case 'acquire' when reply is SendPort:
        if (_ending != null) {
          reply.send(_gone);
          return;
        }
        if (message['ui'] == true) _offByUi = false;
        if (_routeTor == false || _offByUi) {
          // The UI says the route isn't Tor: a stale reading elsewhere. Told
          // `off` whatever this isolate's own client is doing (TB-3): the
          // requester isn't registered, so it would never hear of a later
          // state, and a `starting` would leave it waiting out its budget.
          reply.send({
            'state': EmbeddedTorState.off.name,
            'port': -1,
            'isolate': Isolate.current.controlPort,
          });
          return;
        }
        if (!_leaseholders.containsKey(reply)) {
          final id = _nextLeaseholderId++;
          _leaseholders[reply] = id;
          final isolate = message['isolate'];
          if (isolate is SendPort) {
            Isolate(isolate).addOnExitListener(
              _ownerPort!.sendPort,
              response: '$_leaseholderExited$id',
            );
          }
        }
        _wake();
        unawaited(EmbeddedTorService.ensureStarted());
        reply.send(_status());
      case 'release' when reply is SendPort:
        if (_leaseholders.remove(reply) != null && _leaseholders.isEmpty) {
          _scheduleSleep();
        }
      case 'port' when reply is SendPort:
        reply.send(_status());
      case 'stop':
        _offByUi = true;
        unawaited(EmbeddedTorService.stop().catchError(_log));
    }
  }

  static Map<String, Object?> _status() => {
    'state': EmbeddedTorService.state.name,
    'port': EmbeddedTorService.port,
    'error': EmbeddedTorService.lastError,
    'isolate': Isolate.current.controlPort,
  };

  static void _pushAll() {
    if (_ending != null || _leaseholders.isEmpty) return;
    final status = _status();
    for (final port in _leaseholders.keys) {
      port.send(status);
    }
  }

  /// The owner's dormancy. A sleep goes out [sleepDelay] after it is asked
  /// for, and only if the app is still in the background and no other
  /// isolate uses the client (I1, R-A2b); a sleep held back by a lease
  /// goes out after the last release. A wake reaches the plugin only if it
  /// is actually asleep.
  static Future<void> _setDormant(EmbeddedTorBackend native, bool dormant) {
    if (dormant) {
      _scheduleSleep();
      return Future<void>.value();
    }
    _cancelSleep();
    if (!_asleep) return Future<void>.value();
    _asleep = false;
    return native.setDormant(false);
  }

  static void _scheduleSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = Timer(debugSleepDelay ?? sleepDelay, () {
      _sleepTimer = null;
      _sleepIfIdle();
    });
  }

  static void _cancelSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
  }

  /// Wakes the client for an acquire, as [_setDormant] does, logging errors.
  static void _wake() {
    final native = _hosted?.native;
    if (native == null) {
      _cancelSleep();
      return;
    }
    unawaited(_setDormant(native, false).catchError(_log));
  }

  static void _sleepIfIdle() {
    final native = _hosted?.native;
    if (_leaseholders.isNotEmpty ||
        _asleep ||
        _ending != null ||
        native == null ||
        _role != _Role.owner ||
        EmbeddedTorService.inForeground ||
        EmbeddedTorService.state != EmbeddedTorState.ready) {
      return;
    }
    _asleep = true;
    unawaited(native.setDormant(true).catchError(_log));
  }

  static Future<void> _endOwnership() {
    if (_role != _Role.owner) return Future<void>.value();
    return _ending ??= _end();
  }

  static Future<void> _end() async {
    _cancelSleep();
    try {
      _tellLeaseholdersGone();
      // Issued synchronously at the Dart level: after detached, nothing more
      // may run here.
      final stopping = EmbeddedTorService.stop().catchError(_log);
      // A native start still in Tor.init() can bring a client up after the
      // stop (N1), and its stale stop follows. The mapping stays, answering
      // `gone`, until both are done, so nobody starts next to it (M3). What
      // is waited for is taken now (N-d): a start begun here after this
      // point waits for this end, so it must not be waited for. One
      // deadline covers the stop and the settle (N-b): a native stop that
      // never returns can't keep the mapping forever.
      final idle = EmbeddedTorService.nativeIdle();
      await Future.wait([
        stopping,
        idle,
      ]).timeout(EmbeddedTorService.bootstrapTimeout);
    } on TimeoutException {
      debugPrint('[TorHost] Tor did not stop in time; giving it up');
    } catch (e) {
      _log(e);
    } finally {
      _dropOwnership();
      _ending = null;
    }
  }

  static void _dropOwnership() {
    _changesSub?.cancel();
    _changesSub = null;
    // Whoever still leases the client looks for the next owner (N-a).
    _tellLeaseholdersGone();
    _cancelSleep();
    _asleep = false;
    _offByUi = false;
    if (_role == _Role.owner) _role = _Role.none;
    final port = _ownerPort;
    _ownerPort = null;
    if (port == null) return;
    if (_registry.lookup(isolatePortName) == Isolate.current.controlPort) {
      _registry.remove(isolatePortName);
    }
    if (_registry.lookup(portName) == port.sendPort) _registry.remove(portName);
    port.close();
  }

  /// Tells every leaseholder `gone`, so it looks for the next owner, and
  /// forgets it.
  static void _tellLeaseholdersGone() {
    final leaving = _leaseholders.keys.toList();
    _leaseholders.clear();
    for (final port in leaving) {
      port.send(_gone);
    }
  }

  static void _log(Object e) {
    if (kDebugMode) debugPrint('[TorHost] $e');
  }

  // ── Sweeping (Task A2c) ──────────────────────────────────────────────

  /// Stops every Tor client in the process (`Tor.stopAllInProcess()`),
  /// whichever isolate started it, orphans included, once [standDown], this
  /// isolate's own stop, is done (R-A2c-c): the sweep would otherwise stop
  /// that client from under it. Only [routeChanged] and a takeover call it
  /// (R-A2c-b); a sweep also stops live owners' clients and cancels every
  /// start in flight. One at a time in this isolate, and a start here waits
  /// for it. Each step is bounded by [sweepTimeout]. Never throws: true
  /// once the sweep is done, false if it failed or timed out, logged by the
  /// error's type only (R-A2c-d; a message may name app paths).
  static Future<bool> _sweep(String when, Future<void> standDown) {
    final previous = _sweeping;
    late final Future<bool> sweep;
    sweep = _runSweep(when, standDown, previous).whenComplete(() {
      if (identical(_sweeping, sweep)) _sweeping = null;
    });
    _sweeping = sweep;
    return sweep;
  }

  static Future<bool> _runSweep(
    String when,
    Future<void> standDown,
    Future<bool>? previous,
  ) async {
    if (previous != null) await previous;
    try {
      await standDown.timeout(sweepTimeout);
    } on TimeoutException {
      debugPrint('[TorHost] sweep $when: own stop still running');
    }
    try {
      final stopped = await Future.sync(
        EmbeddedTorService.stopAllInProcess,
      ).timeout(sweepTimeout);
      debugPrint('[TorHost] sweep $when: stopped $stopped Tor client(s)');
      return true;
    } catch (e) {
      debugPrint('[TorHost] sweep $when failed: ${e.runtimeType}');
      return false;
    }
  }

  /// Test hygiene: forgets this isolate's role, leases and ports, and
  /// removes its own mappings, without messaging anyone. Only
  /// [EmbeddedTorService.debugReset] calls it (tests reset both at once).
  static void debugReset() {
    _attempt?.cancel();
    _attempt = null;
    final lease = _lease;
    _lease = null;
    lease?.updates.close();
    _ending = null;
    _sweeping = null;
    _leaseholders.clear();
    _dropOwnership();
    // As in a fresh process: no Tor client has run, no takeover is unswept.
    _registry.remove(usedPortName);
    _registry.remove(unsweptPortName);
    _role = _Role.none;
    _routeTor = null;
    _leases = 0;
    _stillTor = null;
    _nativeUsed = false;
    _hosted?._detach();
    _hosted = null;
  }
}

/// [EmbeddedTorService]'s backend: the native client, or a mirror of the
/// owner's client while this isolate leases it. A start goes through
/// [TorHost] (claim, lease or take over), and an owner's dormancy is
/// deferred and lease-aware ([TorHost._setDormant]), so the service runs
/// the same state machine whichever isolate runs the client.
class _HostedBackend implements EmbeddedTorBackend {
  _HostedBackend(this.native);

  final EmbeddedTorBackend native;

  // Synchronous, so forwarding adds no delay to the native signals.
  final _failures = StreamController<Object>.broadcast(sync: true);
  final _events = StreamController<int>.broadcast(sync: true);
  StreamSubscription<Object>? _nativeFailures;
  StreamSubscription<int>? _nativeEvents;

  bool get _leasing => TorHost._role == _Role.leaseholder;

  void _forwardNative() {
    _nativeFailures ??= native.failures.listen((failure) {
      if (!_leasing) _failures.add(failure);
    });
    _nativeEvents ??= native.events.listen((port) {
      if (!_leasing) _events.add(port);
    });
  }

  void _detach() {
    _nativeFailures?.cancel();
    _nativeEvents?.cancel();
  }

  @override
  Stream<Object> get failures {
    _forwardNative();
    return _failures.stream;
  }

  @override
  Stream<int> get events {
    _forwardNative();
    return _events.stream;
  }

  @override
  Future<void> start() => TorHost._start(native);

  @override
  Future<void> bootstrap() =>
      _leasing ? Future<void>.value() : native.bootstrap();

  @override
  bool get bootstrapped =>
      _leasing ? TorHost._lease?.ready ?? false : native.bootstrapped;

  @override
  int get port {
    if (!_leasing) return native.port;
    final lease = TorHost._lease;
    return lease != null && lease.ready ? lease.port : -1;
  }

  @override
  Future<void> setDormant(bool dormant) => switch (TorHost._role) {
    _Role.owner => TorHost._setDormant(native, dormant),
    _Role.leaseholder => Future<void>.value(),
    _Role.none => native.setDormant(dormant),
  };

  @override
  Future<void> stop() {
    TorHost._attempt?.cancel();
    TorHost._cancelSleep();
    if (_leasing) {
      TorHost._endLease(release: true);
      return Future<void>.value();
    }
    if (!TorHost._nativeUsed) return Future<void>.value();
    return native.stop();
  }
}

/// This isolate's lease on the owner's client.
class _Lease {
  _Lease(this.owner, this.ownerIsolate, this.updates);

  final SendPort owner;
  SendPort? ownerIsolate;
  final RawReceivePort updates;
  bool ready = false;
  int port = -1;

  /// [TorHost.port] calls waiting on the owner.
  final List<_Attempt> waiters = [];
}

/// One start looking for an owner (cancelled by a stop), or one
/// [TorHost.port] call waiting on it (cancelled when the lease ends).
class _Attempt {
  bool cancelled = false;
  void Function()? onCancel;
  Completer<Object>? _outcome;

  /// Waiting for the leased client to be ready.
  bool get expecting => _outcome != null && !_outcome!.isCompleted;

  Future<Object> expect() => (_outcome = Completer<Object>()).future;

  void decide(Object outcome) {
    final pending = _outcome;
    if (pending != null && !pending.isCompleted) pending.complete(outcome);
  }

  void cancel() {
    cancelled = true;
    onCancel?.call();
    decide(_Answer.cancelled);
  }
}

enum _Claim { none, kept, fresh }

enum _Answer { dead, unresponsive, cancelled }

enum _Leased { ready, off, gone }

class _LeaseFailed {
  const _LeaseFailed(this.error);
  final String? error;
}
