import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/services/network/routed_http.dart';
import 'package:bag/services/price_service.dart';
import 'package:bag/services/wallet/esplora_client.dart';

import 'fake_proxies.dart';

void main() {
  // The binding is needed for the SharedPreferences and home_widget channels
  // in the provider test, but it also installs HttpOverrides that answer
  // every request with a canned 400 without touching the network. These
  // tests are about real sockets, so take the real HttpClient back.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late TargetServer target;
  final cleanup = <Future<void> Function()>[];

  setUp(() async {
    target = await TargetServer.start();
    cleanup.add(target.close);
  });

  tearDown(() async {
    RouteGate.debugProbeOverride = null;
    RouteGate.invalidateCache();
    for (final close in cleanup.reversed) {
      await close();
    }
    cleanup.clear();
  });

  Future<int> deadPort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  ProxyRoute socks5(int port) => ProxyRoute(
    ProxyConfig(type: ProxyType.socks5, host: '127.0.0.1', port: port),
  );

  test(
    'EsploraClient over a dead proxy throws and target sees zero hits',
    () async {
      final previous = EsploraClient.debugRetryDelayUnit;
      EsploraClient.debugRetryDelayUnit = Duration.zero;
      addTearDown(() => EsploraClient.debugRetryDelayUnit = previous);

      final client = EsploraClient(
        baseUrl: 'http://127.0.0.1:${target.port}',
        route: socks5(await deadPort()),
      );
      expect(client.isPrivateRoute, isTrue);

      await expectLater(
        client.fetchAddress('bc1qexample'),
        throwsA(isA<EsploraException>()),
      );
      expect(target.hits, 0);
    },
  );

  test(
    'buildRoutedJsonDio(ProxyRoute) reaches target through FakeSocks5Proxy',
    () async {
      final proxy = await FakeSocks5Proxy.start(targetPort: target.port);
      cleanup.add(proxy.close);

      final dio = buildRoutedJsonDio(socks5(proxy.port));
      cleanup.add(() async => dio.close(force: true));

      final response = await dio.get<Map<String, dynamic>>(
        'http://bag-test.invalid:${target.port}/api/v1/fees/recommended',
      );
      expect(response.data, {'ok': true});
      expect(target.hits, 1);
      // The proxy, not the device, resolved the hostname.
      expect(proxy.connectHosts, ['bag-test.invalid']);
    },
  );

  group('PriceService', () {
    late Directory hiveDir;

    setUp(() async {
      hiveDir = await Directory.systemTemp.createTemp('route_paths_hive');
      Hive.init(hiveDir.path);
      await Hive.openBox<String>(AppConstants.priceBox);
    });

    tearDown(() async {
      await Hive.close();
      await hiveDir.delete(recursive: true);
    });

    test(
      'with ProxyRoute and probe unavailable blocks before any request',
      () async {
        final probed = <NetworkRoute>[];
        RouteGate.debugProbeOverride = (route) async {
          probed.add(route);
          return RouteStatus.unavailable;
        };
        // PriceService's Dios point at real public hosts, so a hit counter
        // could not see a leak here. What this pins is that the gate throws
        // before any request; the zero-hit proofs are the Esplora and fee
        // tests above.
        final route = socks5(1080);
        final service = PriceService(route: route);

        await expectLater(
          service.fetchCurrentPrice(['usd']),
          throwsA(isA<RouteUnavailableException>()),
        );
        expect(service.lastRequestBlockedByRoute, isTrue);
        expect(probed, [route]);
      },
    );
  });

  test('priceServiceProvider rebuilds when route changes from TorRoute to '
      'ProxyRoute', () async {
    SharedPreferences.setMockInitialValues({AppConstants.keyUseTor: true});
    final prefs = await SharedPreferences.getInstance();
    const config = ProxyConfig(
      type: ProxyType.socks5,
      host: '127.0.0.1',
      port: 1080,
    );
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        initialProxyConfigProvider.overrideWithValue(config),
      ],
    );
    addTearDown(container.dispose);

    final first = container.read(priceServiceProvider);
    expect(first.route, const TorRoute());

    await container.read(networkSettingsProvider.notifier).setUseProxy(true);

    final second = container.read(priceServiceProvider);
    expect(second, isNot(same(first)));
    expect(second.route, const ProxyRoute(config));
  });
}
