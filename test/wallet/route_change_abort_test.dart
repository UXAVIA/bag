/// R-1 and R-2 on the long runs. A wallet scan or the health check that is
/// running when the user changes the route stops before its next lookup and
/// writes nothing it found; the wallet counts as route-blocked, so the
/// recovery refresh rescans it. A `.onion` explorer on a route that cannot
/// reach it reads as route-blocked and makes no request at all.
///
/// The explorer is a fake that the provider never closes, so these pin the
/// runs' own route checks, not the client closing (test/network/
/// route_change_test.dart).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/models/chain_analysis.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/network_settings.dart';
import 'package:bag/models/wallet_entry.dart';
import 'package:bag/providers/esplora_client_provider.dart';
import 'package:bag/providers/health_check_provider.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/providers/wallets_provider.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/services/wallet/esplora_client.dart';
import 'package:bag/services/wallet/biometric_storage_service.dart';

// BIP84 test vector account key (m/84'/0'/0').
const _zpub =
    'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs';

/// An explorer where no address was ever used. On request number
/// [flipAt] it runs [flip] (the user changing the route) before answering.
final class _FlippingEsplora extends EsploraClient {
  _FlippingEsplora()
    : super(
        baseUrl: AppConstants.explorerBlockstream,
        route: const DirectRoute(),
      );

  int requests = 0;
  int flipAt = 0;
  Future<void> Function()? flip;

  Future<void> _count() async {
    requests++;
    if (requests == flipAt) await flip?.call();
  }

  @override
  Future<AddressStats> fetchAddress(String address) async {
    await _count();
    return const AddressStats(hasTransactions: false, balanceSats: 0);
  }

  @override
  Future<List<RawUtxo>> fetchUtxos(String address) async {
    await _count();
    return const [];
  }
}

class _ProUser extends ProUnlockedNotifier {
  @override
  bool build() => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    RouteGate.debugProbeOverride = (_) async => RouteStatus.available;
  });

  tearDown(() {
    RouteGate.debugProbeOverride = null;
    RouteGate.invalidateCache();
  });

  final fresh = WalletEntry(
    id: 'w',
    label: 'Cold',
    lastSats: 1000,
    lastScanAt: DateTime.now(),
    // 10 receive + 10 change addresses for the health check.
    lastExternalIndex: 9,
    lastChangeIndex: 9,
  );

  Future<(ProviderContainer, _FlippingEsplora)> container({
    Map<String, Object> prefs = const {},
    String customUrl = '',
    ProxyConfig? proxy,
  }) async {
    FlutterSecureStorage.setMockInitialValues({'wallet_zpub_w': _zpub});
    SharedPreferences.setMockInitialValues(prefs);
    final p = await SharedPreferences.getInstance();
    final esplora = _FlippingEsplora();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(p),
        initialProxyConfigProvider.overrideWithValue(proxy),
        initialExplorerUrlProvider.overrideWithValue(customUrl),
        initialWalletsProvider.overrideWithValue([fresh]),
        esploraClientProvider.overrideWithValue(esplora),
        proUnlockedProvider.overrideWith(_ProUser.new),
      ],
    );
    addTearDown(c.dispose);
    return (c, esplora);
  }

  Future<void> switchTorOn(ProviderContainer c) =>
      c.read(networkSettingsProvider.notifier).setUseTor(true);

  group('wallet scan (R-1)', () {
    test('stops before its next lookup once the route changes, keeps the '
        'last balance and counts as route-blocked', () async {
      final (c, esplora) = await container();
      esplora
        ..flipAt = 1
        ..flip = () => switchTorOn(c);
      final wallets = c.read(walletsProvider.notifier);

      await wallets.scan('w');

      // The first batch (4 wide on a direct route) was already out; nothing
      // after it.
      expect(esplora.requests, 4);
      final w = c.read(walletsProvider).single;
      expect(w.isScanning, isFalse);
      expect(w.scanProgress, 0);
      expect(w.lastSats, 1000);
      expect(w.lastScanAt, fresh.lastScanAt);
      expect(w.scanError, routeChangedMessage);
      expect((await loadWalletsFromStorage()), isEmpty,
          reason: 'nothing persisted');

      // Not stale, so a plain refresh leaves it; the recovery refresh
      // rescans it on the new route.
      await wallets.scanAllIfStale();
      expect(esplora.requests, 4);
      await wallets.scanAllIfStale(includeRouteBlocked: true);
      expect(esplora.requests, greaterThan(4));
      expect(c.read(walletsProvider).single.scanError, isNull);
    });

    test('a new explorer stops it the same way', () async {
      final (c, esplora) = await container();
      esplora
        ..flipAt = 1
        ..flip = () => c
            .read(networkSettingsProvider.notifier)
            .setPreset(ExplorerPreset.mempool);

      await c.read(walletsProvider.notifier).scan('w');

      expect(esplora.requests, 4);
      expect(c.read(walletsProvider).single.scanError, routeChangedMessage);
    });

    test('a route change during the last batch still writes nothing',
        () async {
      final (c, esplora) = await container();
      // A wallet with no history: 20 receive + 20 change lookups, 4 at a
      // time. The flip lands in the very last one.
      esplora
        ..flipAt = 40
        ..flip = () => switchTorOn(c);

      await c.read(walletsProvider.notifier).scan('w');

      expect(esplora.requests, 40);
      final w = c.read(walletsProvider).single;
      expect(w.lastSats, 1000);
      expect(w.lastScanAt, fresh.lastScanAt);
      expect(w.scanError, routeChangedMessage);
    });

    test('without a route change the same scan completes (so the counts '
        'above are real)', () async {
      final (c, esplora) = await container();
      await c.read(walletsProvider.notifier).scan('w');
      expect(esplora.requests, 40);
      final w = c.read(walletsProvider).single;
      expect(w.lastSats, 0);
      expect(w.scanError, isNull);
    });
  });

  group('health check (R-1)', () {
    test('stops before its next lookup once the route changes and stores '
        'no result', () async {
      final (c, esplora) = await container();
      esplora
        ..flipAt = 1
        ..flip = () => switchTorOn(c);

      await c.read(portfolioHealthCheckProvider.notifier).run();

      expect(esplora.requests, 4);
      final state = c.read(portfolioHealthCheckProvider);
      expect(state, isA<HealthCheckError>());
      expect((state as HealthCheckError).message, routeChangedMessage);
      expect(await readSecureBlob('health_check_portfolio'), isNull);
    });

    test('a new explorer stops it the same way', () async {
      final (c, esplora) = await container();
      esplora
        ..flipAt = 1
        ..flip = () => c
            .read(networkSettingsProvider.notifier)
            .setPreset(ExplorerPreset.mempool);

      await c.read(portfolioHealthCheckProvider.notifier).run();

      expect(esplora.requests, 4);
      expect(
        (c.read(portfolioHealthCheckProvider) as HealthCheckError).message,
        routeChangedMessage,
      );
    });

    test('a route change during the last lookup still stores nothing',
        () async {
      final (c, esplora) = await container();
      esplora
        ..flipAt = 20
        ..flip = () => switchTorOn(c);

      await c.read(portfolioHealthCheckProvider.notifier).run();

      expect(esplora.requests, 20);
      expect(
        (c.read(portfolioHealthCheckProvider) as HealthCheckError).message,
        routeChangedMessage,
      );
      expect(await readSecureBlob('health_check_portfolio'), isNull);
    });

    test('without a route change it completes (so the counts are real)',
        () async {
      final (c, esplora) = await container();
      await c.read(portfolioHealthCheckProvider.notifier).run();
      expect(esplora.requests, 20);
      expect(c.read(portfolioHealthCheckProvider), isA<HealthCheckDone>());
    });
  });

  group('.onion explorer on a route that cannot reach it (R-2)', () {
    const onion = 'http://abcdefghijklmnop.onion';
    final custom = {
      AppConstants.keyExplorerPreset: ExplorerPreset.custom.index,
    };
    const http = ProxyConfig(type: ProxyType.http, host: 'p.lan', port: 3128);
    const socks = ProxyConfig(
      type: ProxyType.socks5,
      host: '10.0.0.5',
      port: 1080,
    );

    for (final (name, prefs, proxy) in [
      ('direct', custom, null),
      ('an HTTP proxy', {...custom, AppConstants.keyUseProxy: true}, http),
    ]) {
      test('$name: the scan is route-blocked and makes no request', () async {
        final (c, esplora) = await container(
          prefs: prefs,
          customUrl: onion,
          proxy: proxy,
        );
        final wallets = c.read(walletsProvider.notifier);

        await wallets.scan('w');

        expect(esplora.requests, 0);
        expect(c.read(walletsProvider).single.scanError, onionNeedsTorMessage);
        // Counted as route-blocked: picked up once the route can reach it.
        await c.read(networkSettingsProvider.notifier).setUseTor(true);
        await wallets.scanAllIfStale(includeRouteBlocked: true);
        expect(esplora.requests, greaterThan(0));
      });

      test('$name: the health check is refused and makes no request',
          () async {
        final (c, esplora) = await container(
          prefs: prefs,
          customUrl: onion,
          proxy: proxy,
        );

        await c.read(portfolioHealthCheckProvider.notifier).run();

        expect(esplora.requests, 0);
        expect(
          (c.read(portfolioHealthCheckProvider) as HealthCheckError).message,
          onionNeedsTorMessage,
        );
      });
    }

    test('a SOCKS5 proxy may carry it', () async {
      final (c, esplora) = await container(
        prefs: {...custom, AppConstants.keyUseProxy: true},
        customUrl: onion,
        proxy: socks,
      );
      await c.read(walletsProvider.notifier).scan('w');
      expect(esplora.requests, 40);
      expect(c.read(walletsProvider).single.scanError, isNull);
    });

    test('foo.onion.example.com is a clearnet host', () async {
      final (c, esplora) = await container(
        prefs: custom,
        customUrl: 'https://foo.onion.example.com',
      );
      await c.read(walletsProvider.notifier).scan('w');
      expect(esplora.requests, 40);
    });
  });
}
