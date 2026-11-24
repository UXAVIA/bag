import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../models/network_route.dart';
import '../embedded_tor_service.dart';
import '../tor_service.dart';

enum RouteStatus { checking, available, unavailable }

/// Whether a [NetworkRoute] can carry traffic right now.
///
/// This is the fail-closed gate for every private route: Tor (the embedded
/// client) and user-supplied proxies alike. A private route that is not
/// [available] means the request must not be made at all, never that it goes
/// out directly.
class RouteGate {
  RouteGate._();

  /// How long [probeCached] trusts a result.
  static const _cacheTtl = Duration(seconds: 30);

  /// TCP connect budget for a custom proxy, DNS lookup included.
  static const _proxyProbeTimeout = Duration(seconds: 3);

  /// Replaces the real probe. Consulted by [probe] and [probeCached] before
  /// anything touches the network.
  @visibleForTesting
  static Future<RouteStatus> Function(NetworkRoute route)? debugProbeOverride;

  /// Probes [route] right now. Wallet scans and the health check call this
  /// directly: they touch address data, so they always want a live answer.
  static Future<RouteStatus> probe(NetworkRoute route) {
    final override = debugProbeOverride;
    if (override != null) return override(route);
    switch (route) {
      case DirectRoute():
        return Future.value(RouteStatus.available);
      case TorRoute():
        return TorService.probe();
      case ProxyRoute(:final config):
        return _probeProxy(config);
      case MisconfiguredProxyRoute():
        return Future.value(RouteStatus.unavailable);
    }
  }

  // ── Short-lived probe cache ───────────────────────────────────────────────
  //
  // The price and chart layer fetches from up to five hosts per refresh. A
  // fresh probe per request would mean five TCP connects to the proxy.
  // Memoising for a few seconds collapses a refresh burst into one probe
  // while still being short enough that a route dropping is noticed on the
  // next cycle.
  //
  // Tor is never cached (R5): its probe is a synchronous read of the
  // embedded client's state, so it costs nothing, and a cached answer would
  // keep "unavailable" for up to 30 s after bootstrap, or "available" after
  // a crash.
  static ({NetworkRoute route, RouteStatus status, DateTime at})? _cached;
  static final Map<NetworkRoute, Future<RouteStatus>> _inFlight = {};

  /// Bumped by [invalidateCache] so a probe that was already running cannot
  /// write a pre-invalidation answer back into the cache.
  static int _generation = 0;

  /// Like [probe], but reuses a result for the same [route] younger than 30
  /// seconds and collapses concurrent callers onto a single probe. A
  /// different route is always a miss. [TorRoute] bypasses the cache and
  /// probes every time.
  ///
  /// Use this on hot paths (price/chart refresh).
  static Future<RouteStatus> probeCached(NetworkRoute route) {
    if (route is TorRoute) return probe(route);
    final cached = _cached;
    if (cached != null &&
        cached.route == route &&
        DateTime.now().difference(cached.at) < _cacheTtl) {
      return Future.value(cached.status);
    }
    final running = _inFlight[route];
    if (running != null) return running;
    final generation = _generation;
    late final Future<RouteStatus> thisProbe;
    // Only this probe's own entry is removed: after an [invalidateCache] the
    // map may hold a newer probe for the same route, and evicting it would
    // make the next caller start a third (M-1).
    void forget() {
      if (identical(_inFlight[route], thisProbe)) _inFlight.remove(route);
    }

    thisProbe = probe(route).then(
      (status) {
        forget();
        if (generation == _generation) {
          _cached = (route: route, status: status, at: DateTime.now());
        }
        return status;
      },
      onError: (Object e) {
        forget();
        throw e;
      },
    );
    return _inFlight[route] = thisProbe;
  }

  /// Drops the memoised probe result. Call when the user changes the route or
  /// explicitly re-checks, so the next request cannot use a stale answer.
  static void invalidateCache() {
    _generation++;
    _cached = null;
    _inFlight.clear();
  }

  /// TCP-connects to the proxy and closes again. Says nothing about the
  /// proxy's credentials or upstream, only that something is listening.
  static Future<RouteStatus> _probeProxy(ProxyConfig config) async {
    // Same rule as the routing layer: a config that could be misread is
    // never dialled.
    if (!config.isRoutable) return RouteStatus.unavailable;
    final pending = (() async {
      final address =
          InternetAddress.tryParse(config.host) ??
          (await InternetAddress.lookup(config.host)).first;
      return Socket.connect(address, config.port, timeout: _proxyProbeTimeout);
    })();
    try {
      final socket = await pending.timeout(_proxyProbeTimeout);
      socket.destroy();
      return RouteStatus.available;
    } catch (_) {
      // The outer timeout can fire while the connect (after a slow lookup)
      // is still running; a socket that opens after all must not stay open.
      unawaited(pending.then((s) => s.destroy(), onError: (_) {}));
      return RouteStatus.unavailable;
    }
  }
}

/// Why a wallet scan or the health check stopped part-way: the route or the
/// explorer changed while it ran (R-1). Nothing it found was kept, and the
/// next run uses the new settings.
const routeChangedMessage =
    'Stopped: the connection settings changed. Try again to use the new ones.';

/// Why a `.onion` explorer cannot be used on the selected route (R-2).
const onionNeedsTorMessage =
    '.onion addresses need Tor or a SOCKS5 proxy into Tor.';

/// User-facing explanation for why [route] cannot be used. Never includes
/// credentials.
String routeUnavailableMessage(NetworkRoute route) {
  switch (route) {
    case TorRoute():
      // Tor is built in. Failed is a failure the user can retry; otherwise
      // "not ready" is the client not bootstrapped yet.
      if (EmbeddedTorService.state == EmbeddedTorState.failed) {
        return "Tor couldn't connect. "
            'Check your internet connection, then retry.';
      }
      return 'Tor is still connecting. Try again in a moment.';
    case ProxyRoute(:final config):
      return 'Proxy ${config.label} is not reachable. '
          'Check it is running and try again.';
    case MisconfiguredProxyRoute():
      return 'Proxy settings could not be read. '
          'Re-enter them in Wallets → Network.';
    case DirectRoute():
      return 'The network is not reachable.';
  }
}
