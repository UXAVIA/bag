/// `sentinel_balances` (walletId → sats, written by the Sentinel isolate) is
/// an encrypted blob in secure storage. `SentinelNotifier` used to read it
/// from plaintext prefs, where it no longer is, so the Sentinel screen's
/// per-wallet balances were always empty (or a stale pre-migration copy).
/// It now reads secure storage, and no plaintext copy is left or recreated.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/models/wallet_entry.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/sentinel_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/providers/wallets_provider.dart';

class _ProUser extends ProUnlockedNotifier {
  @override
  bool build() => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const key = AppConstants.keySentinelBalances;
  final wallet = WalletEntry(id: 'w1', label: 'Cold', lastSats: 5000);

  Future<ProviderContainer> container({
    Map<String, Object> prefs = const {},
    Map<String, String> secure = const {},
  }) async {
    FlutterSecureStorage.setMockInitialValues(Map.of(secure));
    SharedPreferences.setMockInitialValues({
      AppConstants.keySentinelEnabled: true,
      AppConstants.keySentinelLastScan: '2026-11-24T10:00:00.000',
      ...prefs,
    });
    final p = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(p),
        initialWalletsProvider.overrideWithValue([wallet]),
        proUnlockedProvider.overrideWith(_ProUser.new),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Builds the notifier and lets its secure-storage read land.
  Future<SentinelEnabled> settled(ProviderContainer c) async {
    c.read(sentinelProvider);
    await pumpEventQueue();
    return c.read(sentinelProvider) as SentinelEnabled;
  }

  Future<String?> plaintext() async =>
      (await SharedPreferences.getInstance()).getString(key);

  test('balances come from secure storage', () async {
    final c = await container(secure: {key: jsonEncode({'w1': 5000})});

    final state = await settled(c);

    expect(state.lastBalances, {'w1': 5000});
    expect(state.lastScanAt, DateTime.parse('2026-11-24T10:00:00.000'));
    expect(await plaintext(), isNull, reason: 'no plaintext copy written');
  });

  test('a stale plaintext copy is not read and is removed', () async {
    final c = await container(
      prefs: {key: jsonEncode({'w1': 1})},
      secure: {key: jsonEncode({'w1': 5000})},
    );

    final state = await settled(c);

    expect(state.lastBalances, {'w1': 5000});
    expect(await plaintext(), isNull);
    expect(
      await const FlutterSecureStorage().read(key: key),
      jsonEncode({'w1': 5000}),
    );
  });

  test('a plaintext copy alone is moved into secure storage', () async {
    final c = await container(prefs: {key: jsonEncode({'w1': 7})});

    final state = await settled(c);

    expect(state.lastBalances, {'w1': 7});
    expect(await plaintext(), isNull);
    expect(
      await const FlutterSecureStorage().read(key: key),
      jsonEncode({'w1': 7}),
    );
  });

  test('syncFromPrefs picks up what the isolate wrote since', () async {
    final c = await container(secure: {key: jsonEncode({'w1': 5000})});
    await settled(c);

    await const FlutterSecureStorage()
        .write(key: key, value: jsonEncode({'w1': 6000}));
    await c.read(sentinelProvider.notifier).syncFromPrefs();

    final state = c.read(sentinelProvider) as SentinelEnabled;
    expect(state.lastBalances, {'w1': 6000});
    expect(await plaintext(), isNull);
  });

  test('an unreadable blob reads as no balances', () async {
    final c = await container(secure: {key: 'not json'});

    final state = await settled(c);

    expect(state.lastBalances, isEmpty);
  });

  test('a disabled Sentinel stays disabled and reads nothing', () async {
    final c = await container(
      prefs: {AppConstants.keySentinelEnabled: false},
      secure: {key: jsonEncode({'w1': 5000})},
    );

    c.read(sentinelProvider);
    await pumpEventQueue();

    expect(c.read(sentinelProvider), isA<SentinelDisabled>());
  });
}
