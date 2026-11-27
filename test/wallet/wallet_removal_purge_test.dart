/// M-11: removing a wallet takes its addresses, txids and balance out of
/// Sentinel's three state blobs, and drops the health-check result, which
/// lists every UTXO address of every watch-only wallet it covered.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/models/wallet_entry.dart';
import 'package:bag/providers/health_check_provider.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/providers/wallets_provider.dart';
import 'package:bag/services/sentinel_store.dart';

class _FixedPro extends ProUnlockedNotifier {
  _FixedPro(this._value);
  final bool _value;
  @override
  bool build() => _value;
}

const _zpub =
    'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs';

Map<String, dynamic> _seen(String wid) => {
      'wid': wid,
      'wlabel': 'label-$wid',
      'dir': 'in',
      'sats': 1000,
      'seenAt': DateTime(2026, 11, 24).toIso8601String(),
      'nid': 1,
      'conf': false,
    };

/// In-memory secure storage whose reads of Sentinel's blobs fail, as a
/// keystore error would.
class _FailingSentinelBlobs extends TestFlutterSecureStoragePlatform {
  _FailingSentinelBlobs(super.data);

  int failedReads = 0;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    if (key.startsWith('sentinel_')) {
      failedReads++;
      throw PlatformException(code: 'keystore', message: 'unavailable');
    }
    return super.read(key: key, options: options);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final cold = WalletEntry(id: 'w1', label: 'Cold', lastSats: 100);
  final spend = WalletEntry(id: 'w2', label: 'Spend', lastSats: 200);

  Map<String, String> sentinelBlobs() => {
        AppConstants.keySentinelWatchMap: jsonEncode({
          'bc1qcold0': {'wid': 'w1', 'wlabel': 'Cold'},
          'bc1qcold1': {'wid': 'w1', 'wlabel': 'Cold'},
          'bc1qspend0': {'wid': 'w2', 'wlabel': 'Spend'},
        }),
        AppConstants.keySentinelSeenTxids: jsonEncode({
          'aa' * 32: _seen('w1'),
          'bb' * 32: _seen('w2'),
        }),
        AppConstants.keySentinelBalances: jsonEncode({'w1': 100, 'w2': 200}),
      };

  Future<Map<String, String>> stored() =>
      const FlutterSecureStorage().readAll();

  Map<String, dynamic> decoded(Map<String, String> all, String key) =>
      jsonDecode(all[key]!) as Map<String, dynamic>;

  Future<ProviderContainer> container(List<WalletEntry> wallets) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        initialWalletsProvider.overrideWithValue(wallets),
        proUnlockedProvider.overrideWith(() => _FixedPro(true)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('removeWallet', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({
        'wallet_zpub_w1': _zpub,
        'wallet_zpub_w2': _zpub,
        'wallets_metadata': WalletEntry.listToJsonString([cold, spend]),
        'health_check_portfolio': '{"cached":"result"}',
        ...sentinelBlobs(),
      });
    });

    test('drops the removed wallet from all three Sentinel blobs and keeps '
        'the other wallet\'s entries', () async {
      final c = await container([cold, spend]);
      await c.read(walletsProvider.notifier).removeWallet('w1');

      final all = await stored();
      expect(
        decoded(all, AppConstants.keySentinelWatchMap).keys,
        ['bc1qspend0'],
      );
      expect(
        decoded(all, AppConstants.keySentinelSeenTxids).keys,
        ['bb' * 32],
      );
      expect(decoded(all, AppConstants.keySentinelBalances), {'w2': 200});
    });

    test('drops the health-check result even when another watch-only wallet '
        'is left', () async {
      final c = await container([cold, spend]);
      await c.read(walletsProvider.notifier).removeWallet('w1');

      final all = await stored();
      expect(all.containsKey('health_check_portfolio'), isFalse);
      expect(c.read(portfolioHealthCheckProvider), isA<HealthCheckIdle>());
    });

    test('removing the last wallet leaves no Sentinel state at all',
        () async {
      final c = await container([cold, spend]);
      await c.read(walletsProvider.notifier).removeWallet('w1');
      await c.read(walletsProvider.notifier).removeWallet('w2');

      final all = await stored();
      expect(all.containsKey(AppConstants.keySentinelWatchMap), isFalse);
      expect(all.containsKey(AppConstants.keySentinelSeenTxids), isFalse);
      expect(all.containsKey(AppConstants.keySentinelBalances), isFalse);
    });

    test('a manual entry leaves the health-check result alone', () async {
      final manual = WalletEntry(
        id: 'm1',
        label: 'Exchange',
        kind: WalletKind.manual,
        lastSats: 5,
      );
      final c = await container([cold, manual]);
      await c.read(walletsProvider.notifier).removeWallet('m1');

      final all = await stored();
      expect(all['health_check_portfolio'], '{"cached":"result"}');
    });
  });

  // net R-2: the purge is best effort. A secure-storage error in it must not
  // skip the health-check clear, or stop the free layout's remove-all loop
  // (one removeWallet per entry) before the remaining wallets are removed.
  group('removeWallet when Sentinel\'s blobs can\'t be read', () {
    late _FailingSentinelBlobs storage;

    setUp(() {
      storage = _FailingSentinelBlobs({
        'wallet_zpub_w1': _zpub,
        'wallet_zpub_w2': _zpub,
        'wallets_metadata': WalletEntry.listToJsonString([cold, spend]),
        'health_check_portfolio': '{"cached":"result"}',
        ...sentinelBlobs(),
      });
      FlutterSecureStoragePlatform.instance = storage;
    });

    test('still clears the health-check result', () async {
      final c = await container([cold, spend]);
      await c.read(walletsProvider.notifier).removeWallet('w1');

      expect(storage.failedReads, greaterThan(0));
      expect(storage.data.containsKey('health_check_portfolio'), isFalse);
      expect(c.read(portfolioHealthCheckProvider), isA<HealthCheckIdle>());
      expect(c.read(walletsProvider).map((w) => w.id), ['w2']);
    });

    test('a remove-all loop removes every wallet', () async {
      final c = await container([cold, spend]);
      final notifier = c.read(walletsProvider.notifier);
      for (final id in ['w1', 'w2']) {
        await notifier.removeWallet(id);
      }

      expect(c.read(walletsProvider), isEmpty);
      expect(storage.data.containsKey('wallet_zpub_w1'), isFalse);
      expect(storage.data.containsKey('wallet_zpub_w2'), isFalse);
      expect(
        WalletEntry.listFromJson(storage.data['wallets_metadata']!),
        isEmpty,
      );
    });
  });

  group('purgeSentinelWallet', () {
    test('tolerates missing and unreadable blobs', () async {
      FlutterSecureStorage.setMockInitialValues({
        AppConstants.keySentinelWatchMap: 'not json',
      });
      await purgeSentinelWallet('w1');
      final all = await stored();
      // An unreadable blob is something Sentinel itself reads as empty: it
      // goes, rather than keep addresses no one can check.
      expect(all.containsKey(AppConstants.keySentinelWatchMap), isFalse);
    });
  });

  // The store edits Sentinel's blobs as raw JSON, so the wallet-id field must
  // be the one sentinel_records writes.
  test('the wallet id field matches what Sentinel writes', () {
    final src = File('lib/services/sentinel_records.dart').readAsStringSync();
    expect(
      RegExp("'$sentinelWalletIdField': walletId").allMatches(src).length,
      2,
      reason: 'both SentinelSeenTx.toJson and SentinelWatchEntry.toJson',
    );
  });
}
