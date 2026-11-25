/// A wallet scan that the route pre-flight refused (Tor still connecting or
/// failed, or the proxy down) leaves `scanError` set but `lastScanAt` alone, so
/// a recently scanned wallet isn't stale and `scanAllIfStale()` skips it.
/// After the route recovers, `scanAllIfStale(includeRouteBlocked: true)`
/// rescans exactly those wallets (I2). Plain `scanAllIfStale()` — pull to
/// refresh, app resume — is unchanged.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/wallet_entry.dart';
import 'package:bag/providers/esplora_client_provider.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/providers/wallets_provider.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/services/wallet/esplora_client.dart';

// BIP84 test vector account key (m/84'/0'/0').
const _zpub =
    'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs';

/// An explorer that is down: every request fails at once.
final class _DownEsplora extends EsploraClient {
  _DownEsplora()
    : super(baseUrl: 'http://unused.invalid', route: const DirectRoute());

  @override
  Future<AddressStats> fetchAddress(String address) async =>
      throw const EsploraException('down');
}

class _ProUser extends ProUnlockedNotifier {
  @override
  bool build() => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int probes;

  setUp(() {
    probes = 0;
    RouteGate.debugProbeOverride = (route) async {
      probes++;
      return RouteStatus.unavailable;
    };
  });

  tearDown(() {
    RouteGate.debugProbeOverride = null;
    RouteGate.invalidateCache();
  });

  Future<ProviderContainer> container(List<WalletEntry> wallets) async {
    FlutterSecureStorage.setMockInitialValues({
      for (final w in wallets) 'wallet_zpub_${w.id}': _zpub,
    });
    SharedPreferences.setMockInitialValues({AppConstants.keyUseTor: true});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        initialProxyConfigProvider.overrideWithValue(null),
        initialWalletsProvider.overrideWithValue(wallets),
        esploraClientProvider.overrideWithValue(_DownEsplora()),
        // Wallet scans are Pro (R-B2g); the free case is in
        // test/pro/action_locks_test.dart.
        proUnlockedProvider.overrideWith(_ProUser.new),
      ],
    );
    addTearDown(c.dispose);
    expect(c.read(networkSettingsProvider).route, const TorRoute());
    return c;
  }

  final fresh = WalletEntry(
    id: 'fresh',
    label: 'Fresh',
    lastSats: 1000,
    lastScanAt: DateTime.now(),
  );

  test('a fresh wallet whose scan the route refused is rescanned only when '
      'asked to include route-blocked wallets', () async {
    final c = await container([fresh]);
    final wallets = c.read(walletsProvider.notifier);

    await wallets.scan('fresh');
    expect(probes, 1);
    expect(c.read(walletsProvider).single.scanError, isNotNull);

    // Pull to refresh / resume: not stale, so not rescanned.
    await wallets.scanAllIfStale();
    expect(probes, 1);

    // The route came back: the refused scan runs again.
    await wallets.scanAllIfStale(includeRouteBlocked: true);
    expect(probes, 2);
  });

  test('a wallet that was never refused is not rescanned', () async {
    final c = await container([fresh]);
    await c
        .read(walletsProvider.notifier)
        .scanAllIfStale(includeRouteBlocked: true);
    expect(probes, 0);
  });

  test(
    'a scan that gets past the route check is no longer route-blocked',
    () async {
      final c = await container([fresh]);
      final wallets = c.read(walletsProvider.notifier);
      await wallets.scan('fresh');
      expect(probes, 1);

      // The route is up now, but the explorer isn't reachable: the scan gets
      // past the pre-flight and fails on the network instead.
      RouteGate.debugProbeOverride = (route) async {
        probes++;
        return RouteStatus.available;
      };
      await wallets.scanAllIfStale(includeRouteBlocked: true);
      // Its pre-flight, plus routeStatusProvider's own first probe when the
      // scan publishes the result to it.
      expect(probes, greaterThan(1));
      expect(
        c.read(walletsProvider).single.scanError,
        'Network error — check your connection and try again',
      );

      final afterRecovery = probes;
      await wallets.scanAllIfStale(includeRouteBlocked: true);
      expect(probes, afterRecovery);
    },
  );
}
