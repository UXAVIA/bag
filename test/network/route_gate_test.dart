import 'dart:async';
import 'dart:io';

import 'package:bag/models/network_route.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/services/tor_service.dart';
import 'package:flutter_test/flutter_test.dart';

ProxyRoute _proxy(int port, {String host = '127.0.0.1', String? password}) =>
    ProxyRoute(
      ProxyConfig(
        type: ProxyType.socks5,
        host: host,
        port: port,
        username: password == null ? null : 'alice',
        password: password,
      ),
    );

void main() {
  tearDown(() {
    RouteGate.debugProbeOverride = null;
    RouteGate.invalidateCache();
    TorService.debugIsIOS = null;
  });

  group('probe', () {
    test('DirectRoute is available', () async {
      expect(await RouteGate.probe(const DirectRoute()), RouteStatus.available);
    });

    test('MisconfiguredProxyRoute is unavailable', () async {
      expect(
        await RouteGate.probe(const MisconfiguredProxyRoute()),
        RouteStatus.unavailable,
      );
    });

    test('ProxyRoute is available when something is listening', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      expect(await RouteGate.probe(_proxy(server.port)), RouteStatus.available);
    });

    test('ProxyRoute is unavailable on a dead port', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      expect(await RouteGate.probe(_proxy(port)), RouteStatus.unavailable);
    });

    test(
      'ProxyRoute with an unsafe host is unavailable without connecting',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        var connections = 0;
        server.listen((_) => connections++);
        final route = _proxy(server.port, host: '127.0.0.1;DIRECT');
        expect(await RouteGate.probe(route), RouteStatus.unavailable);
        expect(connections, 0);
      },
    );

    test(
      'ProxyRoute with unroutable credentials is unavailable without '
      'connecting',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        var connections = 0;
        server.listen((_) => connections++);
        for (final (user, pass) in [('u', null), (null, 'p'), ('', '')]) {
          final route = ProxyRoute(
            ProxyConfig(
              type: ProxyType.socks5,
              host: '127.0.0.1',
              port: server.port,
              username: user,
              password: pass,
            ),
          );
          expect(await RouteGate.probe(route), RouteStatus.unavailable);
        }
        expect(connections, 0);
      },
    );

    test('ProxyRoute resolves a DNS host name', () async {
      // Bound by name so it lands on the same address the probe resolves to.
      final server = await ServerSocket.bind('localhost', 0);
      addTearDown(server.close);
      expect(
        await RouteGate.probe(_proxy(server.port, host: 'localhost')),
        RouteStatus.available,
      );
    });

    test('debugProbeOverride wins over a real probe', () async {
      RouteGate.debugProbeOverride = (_) async => RouteStatus.unavailable;
      expect(
        await RouteGate.probe(const DirectRoute()),
        RouteStatus.unavailable,
      );
    });
  });

  group('probeCached', () {
    test('reuses the answer for the same route', () async {
      var calls = 0;
      RouteGate.debugProbeOverride = (_) async {
        calls++;
        return RouteStatus.available;
      };
      await RouteGate.probeCached(_proxy(1080));
      await RouteGate.probeCached(_proxy(1080));
      expect(calls, 1);
    });

    test('never caches TorRoute, on either platform (R5)', () async {
      for (final ios in [true, false]) {
        TorService.debugIsIOS = ios;
        RouteGate.invalidateCache();
        var calls = 0;
        RouteGate.debugProbeOverride = (_) async {
          calls++;
          return RouteStatus.available;
        };
        await RouteGate.probeCached(const TorRoute());
        await RouteGate.probeCached(const TorRoute());
        await Future.wait([
          RouteGate.probeCached(const TorRoute()),
          RouteGate.probeCached(const TorRoute()),
        ]);
        expect(calls, 4, reason: ios ? 'iOS' : 'Android');
      }
    });

    test('re-probes for a different route', () async {
      var calls = 0;
      RouteGate.debugProbeOverride = (_) async {
        calls++;
        return RouteStatus.available;
      };
      await RouteGate.probeCached(_proxy(1079));
      await RouteGate.probeCached(_proxy(1080));
      await RouteGate.probeCached(_proxy(1081));
      expect(calls, 3);
    });

    test('invalidateCache forces a fresh probe', () async {
      var calls = 0;
      RouteGate.debugProbeOverride = (_) async {
        calls++;
        return RouteStatus.available;
      };
      await RouteGate.probeCached(_proxy(1080));
      RouteGate.invalidateCache();
      await RouteGate.probeCached(_proxy(1080));
      expect(calls, 2);
    });

    test('concurrent callers share one probe', () async {
      var calls = 0;
      RouteGate.debugProbeOverride = (_) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return RouteStatus.available;
      };
      await Future.wait([
        RouteGate.probeCached(_proxy(1080)),
        RouteGate.probeCached(_proxy(1080)),
      ]);
      expect(calls, 1);
    });

    test(
      'a probe that started before invalidateCache cannot evict the newer '
      'in-flight probe (M-1)',
      () async {
        final pending = <Completer<RouteStatus>>[];
        RouteGate.debugProbeOverride = (_) {
          final c = Completer<RouteStatus>();
          pending.add(c);
          return c.future;
        };
        final a = RouteGate.probeCached(_proxy(1080));
        RouteGate.invalidateCache();
        final b = RouteGate.probeCached(_proxy(1080));
        expect(pending, hasLength(2));

        // A answers first. Its completion must leave B's entry in place.
        pending[0].complete(RouteStatus.unavailable);
        expect(await a, RouteStatus.unavailable);

        // A caller arriving now joins B instead of starting a third probe.
        final c = RouteGate.probeCached(_proxy(1080));
        expect(pending, hasLength(2));
        pending[1].complete(RouteStatus.available);
        expect(await b, RouteStatus.available);
        expect(await c, RouteStatus.available);

        // And B's answer, not A's, is what was cached.
        expect(await RouteGate.probeCached(_proxy(1080)), RouteStatus.available);
        expect(pending, hasLength(2));
      },
    );

    test('a failed probe that started before invalidateCache cannot evict '
        'the newer one either (M-1)', () async {
      final pending = <Completer<RouteStatus>>[];
      RouteGate.debugProbeOverride = (_) {
        final c = Completer<RouteStatus>();
        pending.add(c);
        return c.future;
      };
      final a = RouteGate.probeCached(_proxy(1080));
      RouteGate.invalidateCache();
      final b = RouteGate.probeCached(_proxy(1080));
      pending[0].completeError(const SocketException('boom'));
      await expectLater(a, throwsA(isA<SocketException>()));
      final c = RouteGate.probeCached(_proxy(1080));
      expect(pending, hasLength(2));
      pending[1].complete(RouteStatus.available);
      expect(await b, RouteStatus.available);
      expect(await c, RouteStatus.available);
    });
  });

  group('routeUnavailableMessage', () {
    test('Tor names the built-in client, the same on both platforms', () {
      // Not started (off) reads as not ready yet; failed has its own copy
      // (test/tor/tor_copy_test.dart).
      for (final ios in [true, false]) {
        TorService.debugIsIOS = ios;
        expect(
          routeUnavailableMessage(const TorRoute()),
          'Tor is still connecting. Try again in a moment.',
          reason: ios ? 'iOS' : 'Android',
        );
      }
    });

    test('proxy names host:port and never the credentials', () {
      final message = routeUnavailableMessage(
        _proxy(1080, host: 'proxy.example', password: 'hunter2-secret'),
      );
      expect(
        message,
        'Proxy proxy.example:1080 is not reachable. '
        'Check it is running and try again.',
      );
      expect(message, isNot(contains('hunter2-secret')));
      expect(message, isNot(contains('alice')));
    });

    test('misconfigured proxy points at the settings', () {
      expect(
        routeUnavailableMessage(const MisconfiguredProxyRoute()),
        'Proxy settings could not be read. '
        'Re-enter them in Wallets → Network.',
      );
    });
  });
}
