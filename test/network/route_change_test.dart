/// R-1: a route change reaches work already in flight. The clients the
/// providers hand out are closed when the route (or, for the explorer, its
/// URL) changes: an in-flight request is abandoned, nothing is retried on
/// the new route, and every later call throws [RouteChangedException].
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/models/network_route.dart';
import 'package:bag/models/network_settings.dart';
import 'package:bag/providers/esplora_client_provider.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/services/network/routed_http.dart';
import 'package:bag/services/price_service.dart';
import 'package:bag/services/wallet/esplora_client.dart';

import 'fake_proxies.dart';

/// Takes requests and never answers them.
class _HangingServer {
  _HangingServer._(this._server) {
    _server.listen((request) {
      hits++;
      _held.add(request);
    });
  }

  final HttpServer _server;
  final _held = <HttpRequest>[];
  int hits = 0;

  int get port => _server.port;

  static Future<_HangingServer> start() async =>
      _HangingServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> close() => _server.close(force: true);
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: 'timed out waiting');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _HangingServer server;

  setUp(() async {
    // The test binding answers every HTTP request with a 400; these talk to
    // a real loopback server.
    HttpOverrides.global = null;
    server = await _HangingServer.start();
    EsploraClient.debugRetryDelayUnit = Duration.zero;
  });

  tearDown(() async {
    await server.close();
    EsploraClient.debugRetryDelayUnit = const Duration(seconds: 1);
  });

  group('EsploraClient.close', () {
    test('abandons the request in flight and refuses every later one',
        () async {
      final client = EsploraClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        route: const DirectRoute(),
      );
      final pending = client.fetchAddress('bc1qaddress');
      await _until(() => server.hits == 1);

      expect(client.isClosed, isFalse);
      client.close();
      expect(client.isClosed, isTrue);
      await expectLater(pending, throwsA(isA<RouteChangedException>()));

      await expectLater(
        client.fetchAddress('bc1qother'),
        throwsA(isA<RouteChangedException>()),
      );
      await expectLater(
        client.fetchUtxos('bc1qother'),
        throwsA(isA<RouteChangedException>()),
      );
      await expectLater(
        client.fetchTransaction('00' * 32),
        throwsA(isA<RouteChangedException>()),
      );
      await expectLater(
        client.fetchMempoolTxs('bc1qother'),
        throwsA(isA<RouteChangedException>()),
      );
      expect(server.hits, 1);
    });

    test('a close during the UTXO root fallback is not read as "no UTXOs"',
        () async {
      // /api/... answers a plain 404; the root-level retry hangs.
      final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => api.close(force: true));
      var rootHits = 0;
      api.listen((request) {
        if (request.uri.path.startsWith('/api/')) {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('not found');
          request.response.close();
        } else {
          rootHits++;
        }
      });
      final client = EsploraClient(
        baseUrl: 'http://127.0.0.1:${api.port}/api',
        route: const DirectRoute(),
      );
      final pending = client.fetchUtxos('bc1qaddress');
      await _until(() => rootHits == 1);

      client.close();
      await expectLater(pending, throwsA(isA<RouteChangedException>()));
    });

    test('a private-route client is not retried once closed', () async {
      final proxy = await FakeSocks5Proxy.start(targetPort: server.port);
      addTearDown(proxy.close);
      final client = EsploraClient(
        baseUrl: 'http://bag-test.invalid:${server.port}',
        route: ProxyRoute(
          ProxyConfig(type: ProxyType.socks5, host: '127.0.0.1', port: proxy.port),
        ),
      );
      final pending = client.fetchUtxos('bc1qaddress');
      await _until(() => server.hits == 1);

      client.close();
      await expectLater(pending, throwsA(isA<RouteChangedException>()));
      // Up to five attempts on a private route, but none after the close.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(proxy.connectHosts, ['bag-test.invalid']);
      expect(server.hits, 1);
    });
  });

  group('PriceService.close', () {
    test('every call after it throws RouteChangedException', () async {
      final service = PriceService(route: const DirectRoute());
      expect(service.isClosed, isFalse);
      service.close();
      expect(service.isClosed, isTrue);

      await expectLater(
        service.fetchCurrentPrice(['usd']),
        throwsA(isA<RouteChangedException>()),
      );
      await expectLater(
        service.fetchHistoricalPrice('usd', DateTime(2020, 1, 2)),
        throwsA(isA<RouteChangedException>()),
      );
      await expectLater(
        service.fetchAllCharts('usd'),
        throwsA(isA<RouteChangedException>()),
      );
    });
  });

  group('the providers close their clients', () {
    const proxy = ProxyConfig(
      type: ProxyType.socks5,
      host: '127.0.0.1',
      port: 1080,
    );

    Future<ProviderContainer> container() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          initialProxyConfigProvider.overrideWithValue(null),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('a route change closes both, without anyone re-reading them',
        () async {
      final c = await container();
      final esplora = c.read(esploraClientProvider);
      final prices = c.read(priceServiceProvider);

      await c.read(networkSettingsProvider.notifier).setUseTor(true);

      expect(esplora.isClosed, isTrue);
      expect(prices.isClosed, isTrue);
      final next = c.read(esploraClientProvider);
      expect(next.isClosed, isFalse);
      expect(next.route, const TorRoute());
      expect(c.read(priceServiceProvider).isClosed, isFalse);
    });

    test('a new explorer closes the Esplora client, not the price service',
        () async {
      final c = await container();
      final esplora = c.read(esploraClientProvider);
      final prices = c.read(priceServiceProvider);

      await c
          .read(networkSettingsProvider.notifier)
          .setPreset(ExplorerPreset.mempool);

      expect(esplora.isClosed, isTrue);
      expect(prices.isClosed, isFalse);
    });

    test('a settings change that moves neither route nor explorer closes '
        'nothing', () async {
      final c = await container();
      final esplora = c.read(esploraClientProvider);
      final prices = c.read(priceServiceProvider);

      // Saved while the proxy is off: the route stays direct.
      await c.read(networkSettingsProvider.notifier).saveProxy(proxy);
      // A custom URL while a preset is selected: the explorer stays.
      await c
          .read(networkSettingsProvider.notifier)
          .setCustomUrl('https://node.example');

      expect(c.read(networkSettingsProvider).route, const DirectRoute());
      expect(esplora.isClosed, isFalse);
      expect(prices.isClosed, isFalse);
      expect(c.read(esploraClientProvider), same(esplora));
    });
  });
}
