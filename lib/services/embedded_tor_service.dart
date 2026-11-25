// Embedded Tor: owns the lifecycle of the in-app Tor client, on Android and
// iOS alike.
//
// "Route through Tor" runs Tor inside the app through the `tor` Flutter
// plugin (Arti), an ordinary dependency that pubspec.yaml pins to a commit of
// the UXAVIA/tor fork. Every build (Play, App Store, the GitHub Releases APK
// and F-Droid) compiles the plugin's Rust from source, so they all run the
// same client. The default backend below drives the plugin's `Tor.instance`;
// tests inject a fake through [EmbeddedTorService.debugBackend].
//
// One client per process: the backend goes through [TorHost], so in an
// isolate that doesn't run the client this service mirrors the isolate that
// does (tor_host.dart).
//
// Nothing here routes traffic. Callers read the port per connection
// ([TorHost.port]; it changes after a restart) and must refuse the request
// while it is -1, as it is whenever the client isn't ready. That is what
// keeps a Tor request fail-closed.

import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;
import 'package:tor/tor.dart';

import 'tor_host.dart';

/// Lifecycle of the embedded Tor client.
///
/// - [off]: not requested, or stopped.
/// - [starting]: starting and bootstrapping (can take tens of seconds).
/// - [ready]: bootstrapped; [EmbeddedTorService.port] is the SOCKS port.
/// - [failed]: the start threw, timed out or ended without a port, or a
///   ready client died on its own.
enum EmbeddedTorState { off, starting, ready, failed }

/// What [EmbeddedTorService] needs from a Tor client. The default
/// implementation drives the plugin's `Tor.instance`; tests inject a fake via
/// [EmbeddedTorService.debugBackend].
abstract interface class EmbeddedTorBackend {
  /// Starts the client and bootstraps a circuit.
  Future<void> start();

  /// Bootstraps an already-started client.
  Future<void> bootstrap();

  bool get bootstrapped;

  /// The local SOCKS port, or -1 when there is no circuit.
  int get port;

  /// Puts the client to sleep (true) or wakes it (false).
  Future<void> setDormant(bool dormant);

  Future<void> stop();

  /// Fires when the client dies on its own (the plugin's SOCKS proxy
  /// exited). The plugin has already torn the client down by then.
  Stream<Object> get failures;

  /// The plugin's port broadcasts (`Tor.instance.events`): the port, or -1,
  /// whenever the plugin's published route changes. A dying proxy shows up
  /// here (-1) before [failures] reports it.
  Stream<int> get events;
}

/// A backend that can stop every Tor client in the process, not only its
/// own: the plugin's `Tor.stopAllInProcess()` (fork 3c379bc), which also
/// reaches a client whose isolate died without stopping it. See
/// [EmbeddedTorService.stopAllInProcess].
abstract interface class ProcessWideTorStop {
  /// Stops every client in the process and returns how many it stopped.
  Future<int> stopAllInProcess();
}

/// The default backend, over the plugin's singleton.
class _PluginTorBackend implements EmbeddedTorBackend, ProcessWideTorStop {
  Future<Tor>? _init;

  /// `Tor.init()` runs once; a failed init is retried on the next start.
  Future<void> _ensureInit() async {
    final pending = _init ??= Tor.init();
    try {
      await pending;
    } catch (_) {
      if (identical(_init, pending)) _init = null;
      rethrow;
    }
  }

  @override
  Future<void> start() async {
    await _ensureInit();
    // The plugin's start() both starts the client and bootstraps it.
    await Tor.instance.start();
  }

  @override
  Future<void> bootstrap() => Tor.instance.bootstrap();

  @override
  bool get bootstrapped => Tor.instance.bootstrapped;

  @override
  int get port => Tor.instance.port;

  @override
  Future<void> setDormant(bool dormant) =>
      Tor.instance.setClientDormant(dormant);

  @override
  Future<void> stop() => Tor.instance.stop();

  @override
  Stream<Object> get failures => Tor.instance.failures.stream;

  @override
  Stream<int> get events => Tor.instance.events.stream;

  @override
  Future<int> stopAllInProcess() => Tor.stopAllInProcess();
}

class EmbeddedTorService {
  EmbeddedTorService._();

  /// How long a start (including bootstrap) may take before it counts as
  /// failed. A first bootstrap on a slow network takes 20–60 s.
  static const Duration bootstrapTimeout = Duration(seconds: 90);

  /// Test seam: when set, used instead of the plugin. Reset it in tearDown.
  @visibleForTesting
  static EmbeddedTorBackend? debugBackend;

  static EmbeddedTorBackend? _pluginBackend;

  /// The native client: the plugin, or [debugBackend].
  static EmbeddedTorBackend get _nativeBackend =>
      debugBackend ?? (_pluginBackend ??= _PluginTorBackend());

  /// The native client as [TorHost] shares it across the process.
  static EmbeddedTorBackend get _backend => TorHost.backendFor(_nativeBackend);

  static EmbeddedTorState _state = EmbeddedTorState.off;

  static final StreamController<EmbeddedTorState> _changes =
      StreamController<EmbeddedTorState>.broadcast();

  /// Bumped by every start and stop. A start only publishes its outcome while
  /// it is still the current generation, so a bootstrap that completes after
  /// [stop] can never move the state to [EmbeddedTorState.ready].
  static int _generation = 0;

  /// The public start operation ([ensureStarted]'s future).
  static Future<void>? _inFlight;

  /// The latest native stop, until it completes. The next start waits for it.
  static Future<void>? _stopping;

  /// The native start (`backend.start()` plus any `bootstrap()`) that is
  /// running right now, whichever generation issued it. Kept apart from
  /// [_inFlight]: [stop] abandons the operation at once, but the native call
  /// keeps running until the plugin's cancel lands, and the plugin is a
  /// singleton. The next start waits for it, so at most one native start is
  /// ever in flight.
  static _NativeStart? _nativeStart;

  static EmbeddedTorBackend? _watchedBackend;
  static StreamSubscription<Object>? _failureSub;
  static StreamSubscription<int>? _eventSub;

  /// The current state, readable synchronously.
  static EmbeddedTorState get state => _state;

  /// Every state change, as it happens.
  static Stream<EmbeddedTorState> get changes => _changes.stream;

  static String? _lastError;

  /// Why the client last failed — a start that threw, timed out or ended
  /// without a circuit, or a ready client that died — as the error's type
  /// and message on one line, at most [_lastErrorMaxLength] characters.
  /// Cleared when the client reaches ready; kept through a stop. Shown on
  /// the Tor card while failed. An Arti error may name the app's own
  /// directories (a per-install container path on iOS), so every absolute
  /// path is replaced with `<dir>` first ([describeError], TB-6); relay
  /// addresses are public.
  static String? get lastError => _lastError;

  static const int _lastErrorMaxLength = 160;

  /// False between [onPause] and [onResume]. A client that dies in the
  /// background is retried on resume (R6), not by [_clientDied].
  static bool _foreground = true;

  /// Whether the app is in the foreground ([onPause] … [onResume]). Always
  /// true outside the UI isolate. [TorHost] reads it to put a client back to
  /// sleep when the last other isolate stops using it.
  static bool get inForeground => _foreground;

  /// Armed each time the client reaches ready; spent by the one automatic
  /// retry after it dies. A retry that fails therefore isn't retried again
  /// until the client has been ready once more, so a persistent failure
  /// can't loop.
  static bool _autoRetryArmed = false;

  /// A port loss (the plugin's first signal of a dying proxy) spent the
  /// automatic retry and holds it for the `failures` report that follows:
  /// only that report says whether a process-wide stop caused the death,
  /// and such a death must not restart the client (R-A2c-c). Dropped by any
  /// start or stop meanwhile.
  static bool _retryHeld = false;

  /// Whether the client can carry traffic right now: bootstrapped, with a
  /// port. Starting, failed and off can't.
  static bool get carriesTraffic =>
      state == EmbeddedTorState.ready && port > 0;

  /// The SOCKS port of the embedded client, or -1 unless the state is
  /// [EmbeddedTorState.ready] *and* the client still reports a port. Read it
  /// per connection: it changes after a restart.
  static int get port {
    if (_state != EmbeddedTorState.ready) return -1;
    final port = _backend.port;
    return port > 0 ? port : -1;
  }

  /// Starts the client if it isn't running. Idempotent while starting or
  /// ready (concurrent callers share one start). From [EmbeddedTorState.failed]
  /// — or `ready` with a client that has lost its circuit or port — it stops
  /// the client and starts again; from [EmbeddedTorState.off] it starts.
  ///
  /// Completes normally either way; the outcome is in [state]. A start that
  /// throws, takes longer than [bootstrapTimeout], or ends without a port
  /// ends in [EmbeddedTorState.failed].
  static Future<void> ensureStarted() {
    switch (_state) {
      case EmbeddedTorState.ready:
        if (_clientAlive(_backend)) return Future<void>.value();
        return _beginStart(restart: true);
      case EmbeddedTorState.starting:
        return _inFlight ?? Future<void>.value();
      case EmbeddedTorState.failed:
        return _beginStart(restart: true);
      case EmbeddedTorState.off:
        return _beginStart(restart: false);
    }
  }

  /// Stops the client. State becomes [EmbeddedTorState.off] at once; an
  /// in-flight start is abandoned and can no longer publish
  /// [EmbeddedTorState.ready]. The native stop is issued at once too, even
  /// while a native start is still running: the plugin's `stop()` invalidates
  /// its lifecycle, cancels the bootstrap and drops whatever a start that
  /// returns afterwards built (fork `lib/tor.dart`, `stop()` and the
  /// `owns(generation)` check after `startTor`). The next start waits for
  /// this stop and for that native start.
  static Future<void> stop() async {
    if (_state == EmbeddedTorState.off) return;
    _retryHeld = false;
    _generation++;
    _inFlight = null;
    _set(EmbeddedTorState.off);
    await _stopBackend(_backend);
  }

  /// Stops every Tor client in the process, whichever isolate started it,
  /// a client whose isolate died without stopping it included, and returns
  /// how many it stopped (the fork's `Tor.stopAllInProcess()`). It stops
  /// live clients too, this isolate's and other isolates', and cancels
  /// every start in flight, so only [TorHost] calls it, at its sweep points
  /// (R-A2c-b), after stopping this isolate's own client. A backend that
  /// isn't a [ProcessWideTorStop] (a test fake) has nothing to stop.
  static Future<int> stopAllInProcess() {
    return switch (_nativeBackend) {
      final ProcessWideTorStop process => process.stopAllInProcess(),
      _ => Future<int>.value(0),
    };
  }

  /// App moved to the background: let a ready client go dormant; a client
  /// still starting goes dormant once it is ready, unless the app is back
  /// in the foreground by then (M3). While another isolate uses the client,
  /// [TorHost] holds the sleep back until it is done. Until [onResume], a
  /// client that dies is not retried automatically; the resume retries it
  /// (R6).
  static Future<void> onPause() async {
    _foreground = false;
    if (_state != EmbeddedTorState.ready) return;
    await _sleep(_backend);
  }

  static Future<void> _sleep(EmbeddedTorBackend backend) async {
    try {
      await backend.setDormant(true);
    } catch (e) {
      // Not fatal: onResume re-checks the client and restarts it if needed.
      if (kDebugMode) debugPrint('[EmbeddedTor] dormant failed: $e');
    }
  }

  /// App back in the foreground: wake a ready client, or restart it if it
  /// lost its circuit or port while suspended. A [EmbeddedTorState.failed]
  /// client (it died, or its start failed, while in the background) is
  /// retried through [ensureStarted], which stops it and starts again (R6).
  /// [EmbeddedTorState.off] and [EmbeddedTorState.starting] are left alone:
  /// off means Tor isn't the route, starting is already on its way.
  static Future<void> onResume() async {
    _foreground = true;
    // A sleep still waiting is dropped (I1).
    TorHost.foregrounded();
    // Every resume while failed retries, Face ID / biometric-lock resumes
    // included. While the start keeps failing (no network, say), each resume
    // shows a brief checking → unavailable flicker.
    if (_state == EmbeddedTorState.failed) return ensureStarted();
    if (_state != EmbeddedTorState.ready) return;
    final generation = _generation;
    final backend = _backend;
    var alive = _clientAlive(backend);
    if (alive) {
      try {
        await backend.setDormant(false);
      } catch (e) {
        if (kDebugMode) debugPrint('[EmbeddedTor] wake failed: $e');
        alive = false;
      }
    }
    if (alive || generation != _generation) return;
    if (_state != EmbeddedTorState.ready) return;
    await _beginStart(restart: true);
  }

  /// The one liveness check: a client counts as running only while it is
  /// bootstrapped and publishes a port.
  static bool _clientAlive(EmbeddedTorBackend backend) =>
      backend.bootstrapped && backend.port > 0;

  /// Stops [backend] now, and records the stop so the next start waits for
  /// it. A native start still running is marked as covered by this stop:
  /// the plugin cancels it and drops whatever it builds, so it needs no stop
  /// of its own when it returns. Errors reach the caller.
  static Future<void> _stopBackend(EmbeddedTorBackend backend) async {
    _nativeStart?.stopIssued = true;
    final stopping = backend.stop();
    _stopping = stopping;
    try {
      await stopping;
    } finally {
      if (identical(_stopping, stopping)) _stopping = null;
    }
  }

  /// Completes once the native start and stop in flight when it is called
  /// are done: an abandoned start that returns late (N1, it can still bring
  /// a client up) and the stale stop [_stopStale] then issues for it
  /// included. [TorHost] waits for it before it gives ownership up, so no
  /// other isolate starts a client next to one still coming up here (M3).
  /// What begins after the call isn't waited for (N-d): a start begun in
  /// this isolate while ownership is being given up waits for that to end,
  /// so waiting for it would wait on itself.
  static Future<void> nativeIdle() async {
    final native = _nativeStart;
    final stopping = _stopping;
    await _settle(native?.settled.future);
    await _settle(native?.staleStop);
    await _settle(stopping);
  }

  /// Waits for [future] and ignores its outcome: whoever started it reports
  /// its errors.
  static Future<void> _settle(Future<void>? future) async {
    if (future == null) return;
    try {
      await future;
    } catch (_) {}
  }

  /// A native start finished after its generation was abandoned. Normally
  /// the abandoning stop was issued while it ran ([_NativeStart.stopIssued])
  /// and the plugin has already dropped what it built. But a stop that lands
  /// while the default backend still awaits `Tor.init()` cancels nothing:
  /// the plugin captures its lifecycle generation only once its `start()`
  /// runs, so that start then brings a client up. So a covered start is
  /// left alone only if its client isn't alive. Otherwise tear the client
  /// down — unless a newer generation is starting or ready. That can't be a
  /// client the newer one brought up: its native start waits for this one,
  /// so it is still `starting` here, and it stops the backend before its own
  /// start ([_startBackend]). Tracked in [_stopping] so the next start waits
  /// for it, and in [_NativeStart.staleStop] for [nativeIdle].
  static void _stopStale(EmbeddedTorBackend backend, _NativeStart native) {
    if (native.stopIssued && !_clientAlive(backend)) return;
    if (_state == EmbeddedTorState.starting ||
        _state == EmbeddedTorState.ready) {
      return;
    }
    native.staleStop = _stopBackend(backend).catchError((Object e) {
      if (kDebugMode) debugPrint('[EmbeddedTor] stop after stale start: $e');
    });
  }

  /// Listens to [backend] (once per backend): a client that dies on its own
  /// while ready moves the state to [EmbeddedTorState.failed].
  ///
  /// Two signals, whichever comes first. The plugin tears a dying proxy down
  /// before reporting it: `stop()` publishes port -1 on `events` at once,
  /// and `failures` fires only after the native teardown. Without the first,
  /// the state would read ready (and every surface would show normal copy)
  /// while the port is already gone. A port broadcast counts as a death only
  /// while the state is ready and the client no longer passes
  /// [_clientAlive] — our own starts and stops broadcast -1 too, but never
  /// while ready. A stale backend's events are ignored; a dead client of the
  /// current backend is what the plugin's own lifecycle gating reports.
  ///
  /// The automatic retry waits for the report (R-A2c-c): a port loss marks
  /// the client failed at once but holds the retry, and the report releases
  /// it, unless it says a process-wide stop ended the client
  /// ([TorProxyFailure.processWideStop]). Another isolate's sweep did that,
  /// and a restart here would start a client next to the one it is about
  /// to start (or after Tor was switched off). No time limit releases it:
  /// the plugin always reports a proxy it lost, and if it never did, a
  /// restart would only wait behind the same hung teardown.
  static void _watchBackend(EmbeddedTorBackend backend) {
    if (identical(_watchedBackend, backend)) return;
    _failureSub?.cancel();
    _eventSub?.cancel();
    _watchedBackend = backend;
    _failureSub = backend.failures.listen((failure) {
      if (!identical(_watchedBackend, backend)) return;
      final held = _retryHeld;
      _retryHeld = false;
      // Off: the user switched Tor off; nothing to explain.
      if (_state == EmbeddedTorState.off) return;
      // Ready with a live client: the report is about a proxy a restart has
      // already replaced (the plugin reports only after its teardown).
      if (_state == EmbeddedTorState.ready && _clientAlive(backend)) return;
      // The plugin's report usually lands after the port loss already moved
      // the state to failed; it says why, so it replaces that reason.
      _recordError(failure);
      if (_state == EmbeddedTorState.ready) {
        _clientDied(report: failure);
      } else if (held &&
          _state == EmbeddedTorState.failed &&
          _foreground) {
        // The retry the port loss held.
        _retryUnlessSwept(failure);
      }
      _announceError();
    });
    _eventSub = backend.events.listen((_) {
      if (!identical(_watchedBackend, backend)) return;
      if (_state != EmbeddedTorState.ready) return;
      if (_clientAlive(backend)) return;
      _recordError('Tor client lost its SOCKS port');
      _clientDied();
    });
  }

  /// A ready client died: failed, then — in the foreground, once per ready
  /// — one automatic retry, unless [report] says a process-wide stop ended
  /// it. Without a report yet (the port loss comes first) the retry waits
  /// for it ([_retryHeld]). The state was ready, so Tor is still the route
  /// (`TorService.followRoute` stops the client, state off, on any other
  /// route); a route change during the retry abandons it as usual.
  static void _clientDied({Object? report}) {
    _set(EmbeddedTorState.failed);
    if (!_foreground || !_autoRetryArmed) return;
    _autoRetryArmed = false;
    if (report == null) {
      _retryHeld = true;
      return;
    }
    _retryUnlessSwept(report);
  }

  /// The one automatic retry after a death that [report] explains. None
  /// after a process-wide stop (R-A2c-c): the client reads failed, and the
  /// next acquire, resume or Retry starts it again.
  static void _retryUnlessSwept(Object report) {
    if (report is TorProxyFailure && report.processWideStop) {
      debugPrint(
        '[EmbeddedTor] stopped by a process-wide stop; not restarted '
        'automatically',
      );
      return;
    }
    unawaited(ensureStarted());
  }

  static Future<void> _beginStart({required bool restart}) {
    _retryHeld = false;
    _watchBackend(_backend);
    final generation = ++_generation;
    _set(EmbeddedTorState.starting);
    late final Future<void> run;
    run = _start(generation, restart: restart).whenComplete(() {
      if (identical(_inFlight, run)) _inFlight = null;
    });
    _inFlight = run;
    return run;
  }

  static Future<void> _start(int generation, {required bool restart}) async {
    final backend = _backend;
    try {
      await _startBackend(
        backend,
        generation,
        restart: restart,
      ).timeout(bootstrapTimeout);
      if (generation != _generation) return;
      _lastError = null;
      _autoRetryArmed = true;
      _set(EmbeddedTorState.ready);
      // Paused before the client came up (M3): it sleeps now, as onPause
      // would have made it.
      if (!_foreground) unawaited(_sleep(backend));
    } on TimeoutException catch (e) {
      if (generation != _generation) return;
      _recordError(e);
      // Abandon the start for good: the bump stops its continuation, and the
      // stop cancels the native start (the plugin drops whatever it brings
      // up afterwards).
      _generation++;
      _set(EmbeddedTorState.failed);
      unawaited(
        _stopBackend(backend).catchError((Object stopError) {
          if (kDebugMode) {
            debugPrint('[EmbeddedTor] stop after timeout: $stopError');
          }
        }),
      );
    } catch (e) {
      if (generation != _generation) return;
      _recordError(e);
      _set(EmbeddedTorState.failed);
    }
  }

  static Future<void> _startBackend(
    EmbeddedTorBackend backend,
    int generation, {
    required bool restart,
  }) async {
    // A stop() still tearing the client down finishes first (its errors
    // were reported to stop()'s caller).
    await _settle(_stopping);
    // So does a native start an earlier generation abandoned: one at a time.
    // The stop that abandoned it cancelled it, so this is normally as quick
    // as the plugin's stop; bounded by this start's own bootstrapTimeout if
    // the native start ignores the cancel. If no stop covered it, or one did
    // but a client came up anyway (a stop during `Tor.init()` cancels
    // nothing), that client is torn down before this start.
    final prior = _nativeStart;
    if (prior != null) {
      await _settle(prior.future);
      if (!prior.stopIssued || _clientAlive(backend)) restart = true;
    }
    // Abandoned while waiting: issue nothing. Whoever abandoned it (stop(),
    // or the bootstrap timeout) stops the backend itself, tracked in
    // _stopping; a stop from here would be untracked, so a later start
    // couldn't wait for it.
    if (generation != _generation) return;
    // From failed: tear down whatever the failed attempt left behind.
    if (restart) await backend.stop();
    if (generation != _generation) return;

    final native = _NativeStart(_runNative(backend, generation));
    _nativeStart = native;
    try {
      try {
        await native.future;
      } finally {
        if (identical(_nativeStart, native)) _nativeStart = null;
      }
      if (generation != _generation) {
        _stopStale(backend, native);
        return;
      }
    } finally {
      native.settled.complete();
    }
    if (!backend.bootstrapped || backend.port <= 0) {
      throw StateError('Tor client started without a circuit');
    }
  }

  /// The native part of a start: `start()`, then `bootstrap()` unless the
  /// start already bootstrapped or the generation was abandoned meanwhile.
  static Future<void> _runNative(
    EmbeddedTorBackend backend,
    int generation,
  ) async {
    await backend.start();
    if (generation != _generation) return;
    if (!backend.bootstrapped) await backend.bootstrap();
  }

  /// Test hygiene: forgets every in-flight start and stop (without waiting
  /// for them), drops the backend subscriptions, resets [TorHost] and puts
  /// the state back to [EmbeddedTorState.off] without emitting. Call it in
  /// tearDown, so a case that fails while a start is held can't stall the
  /// rest of the file for [bootstrapTimeout].
  @visibleForTesting
  static void debugReset() {
    _generation++;
    _inFlight = null;
    _stopping = null;
    _nativeStart = null;
    _failureSub?.cancel();
    _failureSub = null;
    _eventSub?.cancel();
    _eventSub = null;
    _watchedBackend = null;
    _lastError = null;
    _announcedError = null;
    _foreground = true;
    _autoRetryArmed = false;
    _retryHeld = false;
    _state = EmbeddedTorState.off;
    TorHost.debugReset();
  }

  /// Records [error] as [lastError] and logs it — unconditionally:
  /// `debugPrint` survives release builds, so a TestFlight log shows why
  /// Tor failed (e.g. that the fs-mistrust error of plugin issue #91 is
  /// gone).
  static void _recordError(Object error) {
    final text = describeError(error);
    _lastError = text;
    debugPrint('[EmbeddedTor] failed: $text');
  }

  /// [lastError] as of the last [changes] event.
  static String? _announcedError;

  /// A [lastError] that changed while the state stayed
  /// [EmbeddedTorState.failed] (the plugin's report replacing a lost-port
  /// reason when no retry follows, or the owner's new reason in a
  /// leaseholder) is announced on [changes]: no state change would, and both
  /// the Tor card, which shows it, and an owner's leaseholders, which mirror
  /// it, redraw only on one. A change of state announces it anyway.
  static void _announceError() {
    if (_state != EmbeddedTorState.failed || _lastError == _announcedError) {
      return;
    }
    _announcedError = _lastError;
    _changes.add(_state);
  }

  /// A leaseholder's mirror of the owner's [lastError]: [TorHost] passes on
  /// a new reason the owner reports while this isolate already reads
  /// failed, and the state stays as it is. Ignored in any other state.
  static void ownerFailureChanged(String error) {
    if (_state != EmbeddedTorState.failed) return;
    _recordError(TorHostFailure(error));
    _announceError();
  }

  /// An absolute path: a `/` that doesn't follow a word character, then
  /// everything up to whitespace, a quote or an angle bracket. A space is
  /// taken too when what follows it reaches another `/` before the next
  /// space, so iOS's "Application Support" doesn't end the path.
  static final _absolutePath =
      RegExp(r'''(?<![\w.~-])/(?:[^\s"'<>]|\s(?=[^\s/"'<>]*/))+''');

  /// [error] as one line: its runtime type and message (the type once, if
  /// its toString already starts with it; a bare string, or the owner's
  /// line a [TorHostFailure] carries, as is), with every absolute path
  /// replaced by `<dir>` (TB-6), cut to [_lastErrorMaxLength] characters.
  /// Both the log line and [lastError] are this text.
  @visibleForTesting
  static String describeError(Object error) {
    final type = error.runtimeType.toString();
    final message = error.toString();
    var text = switch (error) {
      // A leaseholder shows the owner's own line, already described (M12).
      TorHostFailure() => error.message,
      String() => error,
      _ when message.startsWith(type) => message,
      _ => '$type: $message',
    };
    text = text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(_absolutePath, '<dir>');
    if (text.length > _lastErrorMaxLength) {
      text = '${text.substring(0, _lastErrorMaxLength - 1)}…';
    }
    return text;
  }

  static void _set(EmbeddedTorState next) {
    if (_state == next) return;
    _state = next;
    _announcedError = _lastError;
    _changes.add(next);
  }
}

/// A native start in flight, and whether a stop was issued while it ran.
class _NativeStart {
  _NativeStart(this.future);

  final Future<void> future;

  /// A native stop went out while this start ran: the plugin cancels the
  /// start and drops whatever it builds, so nothing is left to tear down.
  bool stopIssued = false;

  /// Completes once the start has returned and [staleStop], if it needs
  /// one, has been issued ([EmbeddedTorService.nativeIdle]).
  final Completer<void> settled = Completer<void>();

  /// The stop issued for a client this start brought up after it was
  /// abandoned (N1), if any.
  Future<void>? staleStop;
}
