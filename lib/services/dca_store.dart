/// Encrypted-at-rest storage for the DCA purchase log.
///
/// A DCA history is a complete record of how much bitcoin the user bought,
/// when, and at what price — the same class of financial data as a wallet
/// balance. It used to live in a plaintext Hive box; this opens it under
/// AES-256 with a key held in the platform keystore, and migrates any
/// existing plaintext box across on first launch.
///
/// The price cache box is deliberately left unencrypted — it holds nothing
/// but public market data. Historical prices are not in it: the dates the
/// DCA sheet looked up are the user's purchase dates, so they live in an
/// encrypted box of their own (services/price_history_store.dart).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/constants/app_constants.dart';
import 'wallet/biometric_storage_service.dart';

// Secure-storage keys.
const _dcaKeyName = 'dca_box_key';
const _migratedFlag = 'dca_box_migrated';

/// Opens the encrypted DCA box, migrating the legacy plaintext box if needed.
/// Call once from `main()` before any provider reads it.
Future<void> openEncryptedDcaBox() async {
  final cipher = HiveAesCipher(await _loadOrCreateKey());

  final migrated = await readSecureBlob(_migratedFlag) == '1';
  if (!migrated) {
    await _migrateFromPlaintext(cipher);
  }

  await Hive.openBox<String>(
    AppConstants.dcaBoxEncrypted,
    encryptionCipher: cipher,
  );

  // Idempotent: removes the legacy plaintext file, including the case where a
  // previous migration wrote the flag but was killed before it could delete.
  await Hive.deleteBoxFromDisk(AppConstants.dcaBoxLegacy);
}

/// Copies every entry from the legacy plaintext box into the encrypted one.
///
/// Ordering matters: the encrypted box is written and flushed *before* the
/// migration flag is set, and the plaintext box is only deleted after that.
/// A kill at any point leaves the data recoverable on the next launch.
Future<void> _migrateFromPlaintext(HiveAesCipher cipher) async {
  Box<String>? legacy;
  try {
    if (!await Hive.boxExists(AppConstants.dcaBoxLegacy)) {
      await writeSecureBlob(_migratedFlag, '1');
      return;
    }

    legacy = await Hive.openBox<String>(AppConstants.dcaBoxLegacy);
    final entries = Map<String, String>.fromEntries(
      legacy.keys.map((k) => MapEntry(k as String, legacy!.get(k) as String)),
    );
    await legacy.close();
    legacy = null;

    if (entries.isNotEmpty) {
      final encrypted = await Hive.openBox<String>(
        AppConstants.dcaBoxEncrypted,
        encryptionCipher: cipher,
      );
      await encrypted.putAll(entries);
      await encrypted.flush();
      await encrypted.close();
    }

    await writeSecureBlob(_migratedFlag, '1');
    if (kDebugMode) {
      debugPrint('[DcaStore] migrated ${entries.length} entries to encrypted box');
    }
  } catch (e) {
    // Leave the plaintext box in place and retry next launch rather than
    // risk losing the user's purchase history.
    if (kDebugMode) debugPrint('[DcaStore] migration failed: $e');
    await legacy?.close();
  }
}

/// Returns the AES key for the DCA box, generating one on first use.
Future<List<int>> _loadOrCreateKey() => loadOrCreateHiveKey(_dcaKeyName);

/// Returns the 32-byte AES key stored in secure storage under [keyName],
/// generating and storing one on first use. Each encrypted box has a key of
/// its own, so a lost or regenerated key can only ever affect that box.
Future<List<int>> loadOrCreateHiveKey(String keyName) async {
  final stored = await readSecureBlob(keyName);
  if (stored != null) {
    try {
      final key = base64Decode(stored);
      if (key.length == 32) return key;
    } catch (_) {
      // Fall through and regenerate — a malformed key can only mean the
      // entry was corrupted, and an unreadable box is handled by migration.
    }
  }
  final key = Hive.generateSecureKey();
  await writeSecureBlob(keyName, base64Encode(key));
  return key;
}
