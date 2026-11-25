/// A health check already running when a wallet is removed must not store a
/// result that covers that wallet. `removeWallet` clears the cached result
/// (M-11), but a run in flight would otherwise write it straight back, with
/// every UTXO address of the removed wallet in it. The run drops its result
/// when the set of watch-only wallets is no longer the one it started with,
/// the same way it stops on a route change (route_change_abort_test.dart).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/models/chain_analysis.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/wallet_entry.dart';
import 'package:bag/providers/esplora_client_provider.dart';
import 'package:bag/providers/health_check_provider.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/providers/wallets_provider.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/services/wallet/biometric_storage_service.dart';
import 'package:bag/services/wallet/esplora_client.dart';

// BIP84 test vector account key (m/84'/0'/0').
const _zpub =
    'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs';

/// An explorer where no address was ever used. On request number [actAt]
/// it runs [act] (the user removing a wallet) before answering.
final class _ActingEsplora extends EsploraClient {
  _ActingEsplora()
    : super(
        baseUrl: AppConstants.explorerBlockstream,
        route: const DirectRoute(),
      );

  int requests = 0;
  int actAt = 0;
  Future<void> Function()? act;

  // The scan a newly added wallet starts; not counted.
  @override
  Future<AddressStats> fetchAddress(String address) async =>
      const AddressStats(hasTransactions: false, balanceSats: 0);

  @override
  Future<List<RawUtxo>> fetchUtxos(String address) async {
    requests++;
    if (requests == actAt) await act?.call();
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

  // 10 receive + 10 change addresses each: 40 lookups, 4 at a time.
  WalletEntry wallet(String id) => WalletEntry(
        id: id,
        label: 'Wallet $id',
        lastSats: 1000,
        lastScanAt: DateTime.now(),
        lastExternalIndex: 9,
        lastChangeIndex: 9,
      );

  Future<(ProviderContainer, _ActingEsplora)> container() async {
    FlutterSecureStorage.setMockInitialValues({
      'wallet_zpub_w1': _zpub,
      'wallet_zpub_w2': _zpub,
    });
    SharedPreferences.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    final esplora = _ActingEsplora();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(p),
        initialProxyConfigProvider.overrideWithValue(null),
        initialExplorerUrlProvider.overrideWithValue(''),
        initialWalletsProvider.overrideWithValue([wallet('w1'), wallet('w2')]),
        esploraClientProvider.overrideWithValue(esplora),
        proUnlockedProvider.overrideWith(_ProUser.new),
      ],
    );
    addTearDown(c.dispose);
    return (c, esplora);
  }

  Future<void> expectNothingStored(ProviderContainer c) async {
    expect(c.read(portfolioHealthCheckProvider), isA<HealthCheckIdle>());
    expect(await readSecureBlob('health_check_portfolio'), isNull);
    expect(
      c.read(sharedPreferencesProvider)
          .getBool('health_check_portfolio_running'),
      isNull,
    );
  }

  test('a wallet removed mid-run stops the run before its next lookup and '
      'no result is stored', () async {
    final (c, esplora) = await container();
    esplora
      ..actAt = 1
      ..act = () => c.read(walletsProvider.notifier).removeWallet('w2');

    await c.read(portfolioHealthCheckProvider.notifier).run();

    expect(esplora.requests, 4, reason: 'only the first batch went out');
    await expectNothingStored(c);
  });

  test('a wallet removed during the last lookup still stores nothing',
      () async {
    final (c, esplora) = await container();
    esplora
      ..actAt = 40
      ..act = () => c.read(walletsProvider.notifier).removeWallet('w2');

    await c.read(portfolioHealthCheckProvider.notifier).run();

    expect(esplora.requests, 40);
    await expectNothingStored(c);
  });

  test('a wallet added mid-run drops the result too', () async {
    final (c, esplora) = await container();
    esplora
      ..actAt = 1
      ..act = () => c.read(walletsProvider.notifier).addWallet(
            _zpub,
            label: 'New',
          );

    await c.read(portfolioHealthCheckProvider.notifier).run();

    expect(c.read(walletsProvider), hasLength(3));
    expect(esplora.requests, 4, reason: 'only the first batch went out');
    await expectNothingStored(c);
  });

  // A regression guard rather than a pin: the removal's own clear() runs
  // after the run's write here, so this passes without the wallet check too.
  test('a removal still under way when the run ends stores nothing either',
      () async {
    final (c, esplora) = await container();
    late Future<void> removal;
    esplora
      ..actAt = 40
      ..act = () async {
        // Not awaited: the run reaches its write while the removal is
        // still going.
        removal = c.read(walletsProvider.notifier).removeWallet('w2');
      };

    await c.read(portfolioHealthCheckProvider.notifier).run();
    await removal;

    expect(await readSecureBlob('health_check_portfolio'), isNull);
    final state = c.read(portfolioHealthCheckProvider);
    expect(
      state is HealthCheckDone && state.result.walletCount == 2,
      isFalse,
      reason: 'no result covering the removed wallet',
    );
  });

  test('without a removal the same run completes (so the counts are real)',
      () async {
    final (c, esplora) = await container();
    await c.read(portfolioHealthCheckProvider.notifier).run();
    expect(esplora.requests, 40);
    final state = c.read(portfolioHealthCheckProvider);
    expect(state, isA<HealthCheckDone>());
    expect((state as HealthCheckDone).result.walletCount, 2);
    expect(await readSecureBlob('health_check_portfolio'), isNotNull);
  });
}
