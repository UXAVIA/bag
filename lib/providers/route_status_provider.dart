import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/network_route.dart';
import '../services/embedded_tor_service.dart';
import '../services/network/route_gate.dart';
import 'home_refresh_provider.dart';
import 'network_settings_provider.dart';

final routeStatusProvider =
    AsyncNotifierProvider<RouteStatusNotifier, RouteStatus>(
  RouteStatusNotifier.new,
);

/// How the embedded Tor client's state reads as a route status (ruling R2):
/// still bootstrapping is "checking", not "unavailable".
RouteStatus embeddedTorRouteStatus(EmbeddedTorState state) => switch (state) {
      EmbeddedTorState.starting => RouteStatus.checking,
      EmbeddedTorState.ready => RouteStatus.available,
      EmbeddedTorState.failed || EmbeddedTorState.off => RouteStatus.unavailable,
    };

class RouteStatusNotifier extends AsyncNotifier<RouteStatus> {
  /// The embedded Tor state this notifier last acted on ([TorRoute] only;
  /// null on any other route). Lives on the notifier, which survives
  /// rebuilds, so a `ready` is acted on once whether it arrives as an event
  /// or is already there when a rebuild reads it. `ready` is recorded only
  /// when its refresh actually runs, so a rebuild in between can't lose it.
  EmbeddedTorState? _seenTorState;

  @override
  FutureOr<RouteStatus> build() {
    final route = ref.watch(networkSettingsProvider.select((s) => s.route));
    if (route is TorRoute) return _followEmbeddedTor();
    _seenTorState = null;
    return RouteGate.probe(route);
  }

  /// [TorRoute]: the embedded client's state is the status — nothing is
  /// probed, and `PriceNotifier` doesn't mirror its gate result here. The
  /// only other writers are the wallet-scan and health-check pre-flights
  /// (`setValue`), and they write `available` only after a successful probe,
  /// which on Tor means the client is ready: they agree with it. Returned
  /// synchronously, so a change emitted right after this build can't be
  /// overwritten by it.
  ///
  /// Each transition to `ready` drops the memoised probes and runs one
  /// [HomeRefresh.refreshAll] — what pull-to-refresh does (forced price
  /// refresh, bulk charts, stale wallet scans, every chart re-read) plus the
  /// wallet scans the route refused and the fee estimate — so everything
  /// blocked while Tor connected catches up as soon as it is up, instead of
  /// at the next 5-minute tick or the user's next pull. That includes a
  /// client that became ready before this build subscribed (a fast start
  /// racing the route change). The refresh can't loop: only
  /// [EmbeddedTorService] emits `ready`, once per transition, and a refresh
  /// neither changes its state nor writes this status on Tor.
  RouteStatus _followEmbeddedTor() {
    var disposed = false;
    void observe(EmbeddedTorState next) {
      if (next != EmbeddedTorState.ready) {
        _seenTorState = next;
        return;
      }
      if (_seenTorState == EmbeddedTorState.ready) return;
      // Deferred: a provider may not change another while it builds. `ready`
      // is committed in the microtask, not here: a rebuild before it runs
      // disposes this one, finds the ready not yet acted on and schedules
      // its own. Duplicates are dropped by the same check.
      scheduleMicrotask(() {
        if (disposed || _seenTorState == EmbeddedTorState.ready) return;
        if (EmbeddedTorService.state != EmbeddedTorState.ready) return;
        _seenTorState = EmbeddedTorState.ready;
        RouteGate.invalidateCache();
        unawaited(
          ref
              .read(homeRefreshProvider)
              .refreshAll(afterRouteRecovered: true)
              .catchError((Object e) {
            if (kDebugMode) debugPrint('[RouteStatus] refresh on ready: $e');
          }),
        );
      });
    }

    final sub = EmbeddedTorService.changes.listen((next) {
      state = AsyncValue.data(embeddedTorRouteStatus(next));
      observe(next);
    });
    // Also runs when the route changes: a late event from a client that was
    // switched off can't reach the new route's status.
    ref.onDispose(() {
      disposed = true;
      sub.cancel();
    });
    final now = EmbeddedTorService.state;
    observe(now);
    return embeddedTorRouteStatus(now);
  }

  /// Re-probe the selected route — call this when the user taps the refresh
  /// button after starting their proxy, or to retry Tor.
  ///
  /// A [MisconfiguredProxyRoute] is always unavailable, so probing it alone
  /// would be a dead end: the saved proxy is re-read from secure storage
  /// first, and probed if it is readable now.
  ///
  /// [TorRoute] reads the embedded client's state instead of probing, so
  /// a re-check while Tor bootstraps stays "checking". This is the home
  /// screen's Retry: a client that has failed (or is off) is started again
  /// with [EmbeddedTorService.ensureStarted], not awaited, so it returns at
  /// once with "checking". The forced price refresh then comes from the
  /// transition to ready ([_followEmbeddedTor]), once.
  Future<void> recheck() async {
    state = const AsyncValue.loading();
    // The user explicitly asked for a fresh answer — bypass and reset the
    // short-lived probe memo used by the price/chart hot path.
    RouteGate.invalidateCache();
    final route = ref.read(networkSettingsProvider).route;
    if (route is TorRoute) {
      final now = EmbeddedTorService.state;
      if (now == EmbeddedTorState.failed || now == EmbeddedTorState.off) {
        unawaited(EmbeddedTorService.ensureStarted());
      }
      state = AsyncValue.data(embeddedTorRouteStatus(EmbeddedTorService.state));
      return;
    }
    if (route is MisconfiguredProxyRoute) {
      final settings = ref.read(networkSettingsProvider.notifier);
      try {
        await settings.reloadProxy();
      } catch (e) {
        // Still misconfigured: probed below, so the status settles on
        // unavailable rather than staying on loading (M-3).
        if (kDebugMode) debugPrint('[RouteStatus] proxy re-read: ${e.runtimeType}');
      }
      // A readable proxy changes the route this provider watches: build()
      // re-runs and probes it, and `ref` must not be used until it has.
      if (settings.route != route) return;
    }
    state = await AsyncValue.guard(() => RouteGate.probe(route));
  }

  /// Update the cached status with an already-known result.
  /// Use this when a fresh probe has just been performed inline (e.g. before
  /// a wallet scan) so the UI badge reflects reality without triggering a
  /// second probe or passing through the loading state.
  void setValue(RouteStatus status) {
    state = AsyncValue.data(status);
  }
}
