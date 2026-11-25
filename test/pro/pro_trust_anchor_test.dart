/// M-13: the licence token, not the cached bool, is what Pro rests on.
///
/// (a) direct flavor: a valid stored token *restores* `pro_unlocked` on cold
///     start, so a lost pref no longer leaves a paying user on free;
/// (b) `WalletsNotifier` refuses to add or edit a wallet without Pro, as a
///     defence in depth behind the Pro layout; removing still works
///     (ruling R-B2g).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/core/services/license_key_service.dart';
import 'package:bag/models/wallet_entry.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/providers/wallets_provider.dart';

class _FixedPro extends ProUnlockedNotifier {
  _FixedPro(this._value);
  final bool _value;
  @override
  bool build() => _value;
}

const _zpub =
    'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('direct flavor: the stored token restores Pro', () {
    late ed.KeyPair keys;
    late String validToken;

    setUp(() {
      expect(AppConstants.kFlavor, 'direct');
      keys = ed.generateKey();
      LicenseKeyService.debugPublicKey =
          Uint8List.fromList(keys.publicKey.bytes);
      final licenseId = List<int>.generate(8, (i) => i * 17);
      final signature = ed.sign(
        keys.privateKey,
        Uint8List.fromList(utf8.encode('bag-pro-v1:${_hex(licenseId)}')),
      );
      validToken = base64Url.encode([...licenseId, ...signature]);
      expect(LicenseKeyService.verify(validToken), isTrue);
    });

    tearDown(() => LicenseKeyService.debugPublicKey = null);

    Future<(ProviderContainer, SharedPreferences)> start({
      required Map<String, Object> prefsValues,
      required Map<String, String> secure,
    }) async {
      SharedPreferences.setMockInitialValues(prefsValues);
      FlutterSecureStorage.setMockInitialValues(secure);
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);
      c.read(proUnlockedProvider); // cold start: build() kicks off the check
      return (c, prefs);
    }

    // The secure-storage mock answers on later event-loop turns.
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }

    test('a valid token with the pref missing turns Pro back on, pref '
        'included', () async {
      final (c, prefs) = await start(
        prefsValues: {},
        secure: {AppConstants.keyLicenseToken: validToken},
      );
      expect(c.read(proUnlockedProvider), isFalse); // cached bool first
      await settle();
      expect(c.read(proUnlockedProvider), isTrue);
      expect(prefs.getBool(AppConstants.keyProUnlocked), isTrue);
    });

    test('a valid token with the pref set keeps Pro on', () async {
      final (c, prefs) = await start(
        prefsValues: {AppConstants.keyProUnlocked: true},
        secure: {AppConstants.keyLicenseToken: validToken},
      );
      await settle();
      expect(c.read(proUnlockedProvider), isTrue);
      expect(prefs.getBool(AppConstants.keyProUnlocked), isTrue);
    });

    test('a forged token with the pref set revokes', () async {
      final forged = base64Url.encode(List<int>.filled(72, 7));
      final (c, prefs) = await start(
        prefsValues: {AppConstants.keyProUnlocked: true},
        secure: {AppConstants.keyLicenseToken: forged},
      );
      await settle();
      expect(c.read(proUnlockedProvider), isFalse);
      expect(prefs.containsKey(AppConstants.keyProUnlocked), isFalse);
    });

    test('no token with the pref set revokes', () async {
      final (c, prefs) = await start(
        prefsValues: {AppConstants.keyProUnlocked: true},
        secure: {},
      );
      await settle();
      expect(c.read(proUnlockedProvider), isFalse);
      expect(prefs.containsKey(AppConstants.keyProUnlocked), isFalse);
    });
  });

  group('store flavor: a key also unlocks Pro', () {
    late ed.KeyPair keys;
    late String validToken;

    setUp(() {
      ProUnlockedNotifier.debugFlavor = 'store';
      keys = ed.generateKey();
      LicenseKeyService.debugPublicKey =
          Uint8List.fromList(keys.publicKey.bytes);
      final licenseId = List<int>.generate(8, (i) => i * 13);
      final signature = ed.sign(
        keys.privateKey,
        Uint8List.fromList(utf8.encode('bag-pro-v1:${_hex(licenseId)}')),
      );
      validToken = base64Url.encode([...licenseId, ...signature]);
    });

    tearDown(() {
      ProUnlockedNotifier.debugFlavor = null;
      LicenseKeyService.debugPublicKey = null;
    });

    Future<(ProviderContainer, SharedPreferences)> start({
      required Map<String, Object> prefsValues,
      required Map<String, String> secure,
    }) async {
      SharedPreferences.setMockInitialValues(prefsValues);
      FlutterSecureStorage.setMockInitialValues(secure);
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);
      c.read(proUnlockedProvider);
      return (c, prefs);
    }

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }

    test('valid stored key, bool missing: Pro on and bool written', () async {
      final (c, prefs) = await start(
        prefsValues: {},
        secure: {AppConstants.keyLicenseToken: validToken},
      );
      expect(c.read(proUnlockedProvider), isFalse);
      await settle();
      expect(c.read(proUnlockedProvider), isTrue);
      expect(prefs.getBool(AppConstants.keyProUnlocked), isTrue);
    });

    test('a key-only user keeps Pro after a restore that emits nothing',
        () async {
      final (c, _) = await start(
        prefsValues: {AppConstants.keyProUnlocked: true},
        secure: {AppConstants.keyLicenseToken: validToken},
      );
      await settle();
      expect(c.read(proUnlockedProvider), isTrue);
    });

    test('store bool true, no key: stays Pro', () async {
      final (c, prefs) = await start(
        prefsValues: {AppConstants.keyProUnlocked: true},
        secure: {},
      );
      await settle();
      expect(c.read(proUnlockedProvider), isTrue);
      expect(prefs.getBool(AppConstants.keyProUnlocked), isTrue);
    });

    test('store bool true, invalid key: stays Pro', () async {
      final forged = base64Url.encode(List<int>.filled(72, 7));
      final (c, prefs) = await start(
        prefsValues: {AppConstants.keyProUnlocked: true},
        secure: {AppConstants.keyLicenseToken: forged},
      );
      await settle();
      expect(c.read(proUnlockedProvider), isTrue);
      expect(prefs.getBool(AppConstants.keyProUnlocked), isTrue);
    });

    test('verifyAndUnlock works and licenceKeyStoredProvider turns true',
        () async {
      final (c, prefs) = await start(prefsValues: {}, secure: {});
      expect(await c.read(licenceKeyStoredProvider.future), isFalse);
      expect(
        await c.read(proUnlockedProvider.notifier).verifyAndUnlock(validToken),
        isTrue,
      );
      expect(c.read(proUnlockedProvider), isTrue);
      expect(prefs.getBool(AppConstants.keyProUnlocked), isTrue);
      expect(await c.read(licenceKeyStoredProvider.future), isTrue);
    });

    test('licenceKeyStoredProvider is false for an invalid stored key',
        () async {
      final forged = base64Url.encode(List<int>.filled(72, 7));
      final (c, _) = await start(
        prefsValues: {},
        secure: {AppConstants.keyLicenseToken: forged},
      );
      expect(await c.read(licenceKeyStoredProvider.future), isFalse);
    });
  });

  group('WalletsNotifier without Pro', () {
    final manual = WalletEntry(
      id: 'm1',
      label: 'Exchange',
      kind: WalletKind.manual,
      lastSats: 5000,
    );
    final watch = WalletEntry(id: 'w1', label: 'Cold', lastSats: 100);

    Future<ProviderContainer> container({required bool pro}) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({
        'wallet_zpub_w1': _zpub,
        'wallets_metadata': WalletEntry.listToJsonString([watch, manual]),
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          initialWalletsProvider.overrideWithValue([watch, manual]),
          proUnlockedProvider.overrideWith(() => _FixedPro(pro)),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<Map<String, String>> stored() =>
        const FlutterSecureStorage().readAll();

    test('adds nothing, and stores no secret', () async {
      final c = await container(pro: false);
      final before = await stored();
      final wallets = c.read(walletsProvider.notifier);

      await wallets.addWallet(_zpub, label: 'New');
      await wallets.addDescriptorWallet(
        'wpkh($_zpub/<0;1>/*)',
        label: 'Desc',
      );
      await wallets.addManualEntry(sats: 1, label: 'Typed');

      expect(c.read(walletsProvider), [watch, manual]);
      expect(await stored(), before);
    });

    test('edits nothing', () async {
      final c = await container(pro: false);
      final wallets = c.read(walletsProvider.notifier);

      await wallets.updateManualEntry('m1', 999);
      await wallets.renameWallet('w1', 'Renamed');

      expect(c.read(walletsProvider), [watch, manual]);
    });

    test('still removes', () async {
      final c = await container(pro: false);
      await c.read(walletsProvider.notifier).removeWallet('w1');

      expect(c.read(walletsProvider), [manual]);
      expect((await stored()).containsKey('wallet_zpub_w1'), isFalse);
    });

    test('with Pro, a manual entry is added and edited', () async {
      final c = await container(pro: true);
      final wallets = c.read(walletsProvider.notifier);

      await wallets.addManualEntry(sats: 1, label: 'Typed');
      await wallets.updateManualEntry('m1', 999);
      await wallets.renameWallet('w1', 'Renamed');

      final state = c.read(walletsProvider);
      expect(state.map((w) => w.label), ['Renamed', 'Exchange', 'Typed']);
      expect(state[1].lastSats, 999);
    });
  });
}
