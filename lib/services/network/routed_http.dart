import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/constants/app_constants.dart';
import '../../models/network_route.dart';
import '../tor_host.dart';
import 'socks5_connect.dart';

/// A `.onion` host on a route that cannot reach one ([NetworkRoute
/// .canReachOnion]): refused before any DNS lookup or proxy CONNECT, so the
/// name of the user's onion service never leaves the device (R-2).
class OnionNeedsTorException extends SocketException {
  const OnionNeedsTorException()
      : super('.onion addresses need Tor or a SOCKS5 proxy');
}

/// A client built for one route (or explorer) was closed because the user
/// selected another while it worked. Its requests were abandoned, never
/// retried on the new route, and every later call on it throws this (R-1).
class RouteChangedException implements Exception {
  const RouteChangedException();

  @override
  String toString() => 'RouteChangedException: the network settings changed';
}

/// Connect/receive timeout for every private route. Tor circuit set-up alone
/// can take 10-20 s, and a user's own proxy may chain onto Tor.
const privateRouteTimeout = Duration(seconds: 60);

/// Makes [client] leave the device the way [route] says, and returns it.
///
/// This is the one place that decides it. Every private route fails closed:
/// if the proxy is down, unresolvable or its settings are unreadable, the
/// request throws. None of them ever falls back to a direct connection.
///
/// [securityContext] is for tests: it decides which certificates the TLS
/// step of a SOCKS5 tunnel, or of a direct https connection, trusts. Null
/// means the default (system roots).
/// [handshakeTimeout] is for tests too: the budget for a SOCKS5 tunnel's
/// whole set-up (proxy connect, SOCKS handshake and TLS).
HttpClient routeHttpClient(
  HttpClient client,
  NetworkRoute route, {
  @visibleForTesting SecurityContext? securityContext,
  @visibleForTesting Duration handshakeTimeout = privateRouteTimeout,
}) {
  switch (route) {
    case DirectRoute():
      _dialRefusingOnion(client, securityContext);
    case TorRoute():
      // The in-app Tor client's SOCKS port, over the same tunnel code as a
      // SOCKS5 proxy: this isolate's own client, or the one another isolate
      // of the process runs (TorHost). The port is read per connection (it
      // moves after a restart), and is -1 until Tor has bootstrapped.
      _routeViaSocks5(
        client,
        resolveProxy: _embeddedTorEndpoint,
        securityContext: securityContext,
        timeout: handshakeTimeout,
      );
    case ProxyRoute(:final config) when !config.isRoutable:
      // Stored configs bypass ProxyConfig.validate, and the host and
      // credentials end up in strings with no escaping (Dart's PROXY string
      // falls back to the next entry on error, which can be DIRECT). Refuse
      // anything unexpected rather than interpret it.
      _refuseEverything(client);
    case ProxyRoute(:final config):
      switch (config.type) {
        case ProxyType.socks5:
          _routeViaSocks5(
            client,
            resolveProxy: () async => (
              InternetAddress.tryParse(config.host) ??
                  (await InternetAddress.lookup(config.host)).first,
              config.port,
            ),
            username: config.username,
            password: config.password,
            securityContext: securityContext,
            timeout: handshakeTimeout,
          );
        case ProxyType.http:
          _routeViaHttpProxy(client, config);
          _dialRefusingOnion(client, null);
      }
    case MisconfiguredProxyRoute():
      _refuseEverything(client);
  }
  return client;
}

/// A [Dio] whose every request goes out over [route].
///
/// Redirects are never followed (R-5): none of Bag's sources needs one, and
/// following them would let an explorer or an upstream send the next request
/// to another host, to `http://`, or into the LAN. A 30x fails the request.
Dio buildRoutedDio({
  required NetworkRoute route,
  required Duration clearnetTimeout,
  String? baseUrl,
  Map<String, String>? headers,
}) {
  final timeout = route.isPrivate ? privateRouteTimeout : clearnetTimeout;
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl ?? '',
      connectTimeout: timeout,
      receiveTimeout: timeout,
      headers: headers,
      followRedirects: false,
    ),
  );
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => routeHttpClient(HttpClient(), route),
  );
  return dio;
}

/// A [Dio] for JSON requests over [route]: the Esplora explorer, the fee
/// estimate (in the app and in Sentinel), and the widget's background price,
/// chart and fee fetches. A 20 s clearnet timeout, and no identifying
/// headers, only `Accept: application/json`.
///
/// Every request leaves over [route]; a private route (Tor or a proxy) gets
/// the 60 s [privateRouteTimeout] and fails closed when it is down.
///
/// MUST be called with the route the user selected (`readNetworkRoute` in
/// background isolates). No clearnet fallback — that is a privacy leak.
Dio buildRoutedJsonDio(NetworkRoute route) => buildRoutedDio(
      route: route,
      clearnetTimeout: const Duration(seconds: 20),
      headers: {'Accept': 'application/json'},
    );

/// SOCKS5 with the target sent as a hostname (ATYP 0x03), so the proxy does
/// the DNS lookup and the device never resolves the target itself.
///
/// Uses [socks5Connect] rather than the `socks5_proxy` package, which appends
/// a NUL byte to the hostname; Go-based proxies (Xray, sing-box, gost) then
/// try to resolve "host\0". The embedded Tor client comes through here too.
///
/// [resolveProxy] gives the proxy's address and port. It runs inside each
/// connection, after the deadline starts, so a DNS lookup counts against
/// [timeout] and a port that changes between connections is followed. If it
/// throws, that connection fails with its error.
void _routeViaSocks5(
  HttpClient client, {
  required Future<(InternetAddress, int)> Function() resolveProxy,
  String? username,
  String? password,
  SecurityContext? securityContext,
  required Duration timeout,
}) {
  // Without this an HTTP_PROXY environment variable would turn requests into
  // absolute-form ones for a "proxy" that the factory below ignores.
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (uri, _, _) async {
    // The TCP socket to the proxy, once it is open. Cancelling destroys it
    // directly: waiting on [socket] instead would wait on a stalled SOCKS
    // handshake and leave the connection open until that times out. (Once
    // TLS has started, dart:io owns the socket; see [Socks5Tunnel.secure].)
    Socket? raw;
    var cancelled = false;
    void adopt(Socket s) {
      raw = s;
      if (cancelled) s.destroy();
    }

    final socket = (() async {
      final deadline = DateTime.now().add(timeout);
      Duration remaining() {
        final left = deadline.difference(DateTime.now());
        return left > Duration.zero ? left : Duration.zero;
      }

      final (proxyAddress, proxyPort) = await resolveProxy();
      if (cancelled) throw const SocketException('Connection cancelled');
      final tunnel = await socks5Connect(
        proxy: proxyAddress,
        proxyPort: proxyPort,
        targetHost: uri.host,
        targetPort: uri.port,
        username: username,
        password: password,
        timeout: remaining(),
        onSocket: adopt,
      );
      if (cancelled) {
        tunnel.destroy();
        throw const SocketException('Connection cancelled');
      }
      if (uri.scheme != 'https') return tunnel;
      // TLS gets whatever is left of the same budget, never a fresh one.
      return tunnel.secure(
        uri.host,
        context: securityContext,
        timeout: remaining(),
      );
    })();
    // The HttpClient subscribes to [socket] only after this factory's own
    // future has resolved. A connection refused at once (Tor not yet
    // bootstrapped) would fail before then and surface as an uncaught error.
    // Marking it handled here does not hide it: the HttpClient still gets it.
    socket.ignore();
    return ConnectionTask.fromSocket(socket, () {
      cancelled = true;
      raw?.destroy();
      // A tunnel that completes after all is not leaked either.
      socket.then((s) => s.destroy(), onError: (_) {});
    });
  };
}

/// Plain HTTP proxy: absolute-form requests for http, CONNECT tunnels for
/// https.
///
/// Credentials have to be part of the `PROXY` string. Dart only sends
/// `Proxy-Authorization` on a CONNECT when the proxy configuration carries
/// them, and it fails a 407 on CONNECT outright; `addProxyCredentials` only
/// reaches plain-http requests, so it would break every HTTPS request.
void _routeViaHttpProxy(HttpClient client, ProxyConfig config) {
  final host = config.host.contains(':') ? '[${config.host}]' : config.host;
  final address = '$host:${config.port}';
  final proxy = config.hasCredentials
      ? 'PROXY ${config.username}:${config.password}@$address'
      : 'PROXY $address';
  client.findProxy = (_) => proxy;
}

/// Dials the way dart:io does by default (to the target, or to the HTTP
/// proxy [HttpClient.findProxy] chose, which then gets CONNECT or an
/// absolute-form request as usual), except that a `.onion` target is refused
/// first: no DNS lookup, and no CONNECT line naming it to the proxy (R-2).
/// For the routes that cannot reach an onion service; Tor and SOCKS5 carry
/// the name to the proxy instead.
///
/// [securityContext] is the test seam of [routeHttpClient], for a direct
/// https target; null means the default (system roots).
void _dialRefusingOnion(HttpClient client, SecurityContext? securityContext) {
  client.connectionFactory = (uri, proxyHost, proxyPort) {
    if (isOnionHost(uri.host)) {
      return Future.error(const OnionNeedsTorException());
    }
    if (proxyHost != null && proxyPort != null) {
      return Socket.startConnect(proxyHost, proxyPort);
    }
    return uri.scheme == 'https'
        ? SecureSocket.startConnect(
            uri.host,
            uri.port,
            context: securityContext,
          )
        : Socket.startConnect(uri.host, uri.port);
  };
}

/// The embedded Tor client's SOCKS endpoint, read at connection time. Fails
/// closed while Tor is not bootstrapped; the message names no host or port.
Future<(InternetAddress, int)> _embeddedTorEndpoint() async {
  final port = await TorHost.port();
  if (port <= 0) throw const SocketException('Tor is not connected');
  return (InternetAddress(AppConstants.torHost), port);
}

void _refuseEverything(HttpClient client) {
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (_, _, _) =>
      Future.error(const SocketException('Proxy settings unreadable'));
}
