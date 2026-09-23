/// Secure storage for watch-only wallet material, behind biometric auth for
/// anything that gets *displayed*.
///
/// Storage:   flutter_secure_storage → Android Keystore AES-256-GCM /
///            iOS Keychain (accessible after first unlock, so the Android
///            WorkManager and Sentinel isolates can still read while the
///            screen is locked).
/// Auth gate: local_auth prompt required to READ/DISPLAY the raw secret.
///            Internal scanning reads without displaying.
///
/// Two classes of data live here:
///  1. Wallet secrets — the zpub or output descriptor, one entry per wallet.
///  2. Wallet metadata — labels, per-wallet balances and scan cursors.
///     These used to sit in SharedPreferences; balances are sensitive
///     financial data, so they are encrypted at rest too.
///
/// Security invariants:
/// - Secrets and balances are NEVER logged.
/// - [readWalletSecretForDisplay] requires a successful biometric prompt
///   every call.
/// - [readWalletSecretForScanning] does NOT display the string — it only
///   feeds the derivation engine, which never surfaces it to the UI.
/// - On authentication failure or cancellation, null is returned silently.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_constants.dart';

// Legacy single-wallet key — kept for migration in readWalletSecretForScanning.
const _legacySecretKey = 'wallet_zpub';

// Multi-wallet: one secure key per wallet UUID. The key name is historical —
// the value may be a zpub or an output descriptor — and is deliberately left
// unchanged so existing installs keep resolving their stored zpub.
String _secretKeyForId(String id) => 'wallet_zpub_$id';

// Wallet metadata blob (JSON array of WalletEntry).
const _walletsMetadataKey = 'wallets_metadata';

const _storage = FlutterSecureStorage(
  aOptions: AndroidOptions(),
  // first_unlock (not first_unlock_this_device_only) keeps the keychain items
  // restorable to a new device the user owns, while still being readable by
  // background work after the first unlock following a reboot.
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
);

final _auth = LocalAuthentication();

/// Checks whether the device has biometric hardware enrolled.
/// Falls back to device credential (PIN/pattern/password) automatically.
/// Returns [BiometricAvailability.available] if the device has any screen lock
/// (PIN, pattern, password, or biometric) — all of which work with
/// [AuthenticationOptions.biometricOnly] = false.
/// Returns [BiometricAvailability.unsupported] only if no lock screen at all.
Future<BiometricAvailability> checkAvailability() async {
  try {
    final supported = await _auth.isDeviceSupported();
    return supported
        ? BiometricAvailability.available
        : BiometricAvailability.unsupported;
  } on PlatformException {
    return BiometricAvailability.unsupported;
  }
}

// ── Wallet secrets (keyed by wallet UUID) ─────────────────────────────────

/// Stores [secret] (a zpub or an output descriptor) encrypted at rest,
/// keyed by wallet [id].
Future<void> storeWalletSecretForId(String id, String secret) =>
    _storage.write(key: _secretKeyForId(id), value: secret);

/// Reads a wallet secret for internal scanning by wallet [id].
///
/// Falls back to the legacy single-wallet key on first run after upgrade,
/// then migrates transparently to the new key format.
Future<String?> readWalletSecretForScanningById(String id) async {
  final secret = await _storage.read(key: _secretKeyForId(id));
  if (secret != null) return secret;

  // Migration: legacy key → new keyed key (runs once after upgrade).
  final legacy = await _storage.read(key: _legacySecretKey);
  if (legacy != null) {
    await _storage.write(key: _secretKeyForId(id), value: legacy);
    await _storage.delete(key: _legacySecretKey);
    if (kDebugMode) {
      debugPrint('[SecureStorage] migrated legacy wallet secret → id=$id');
    }
  }
  return legacy;
}

/// Authenticates and returns the wallet secret for display, keyed by [id].
/// Returns null if authentication is cancelled or fails.
Future<String?> readWalletSecretForDisplayById(String id) async {
  final authenticated = await _authenticate(
    reason: 'Authenticate to view your wallet key',
  );
  if (!authenticated) return null;
  return _storage.read(key: _secretKeyForId(id));
}

/// Deletes the stored secret for wallet [id].
Future<void> deleteWalletSecretForId(String id) =>
    _storage.delete(key: _secretKeyForId(id));

// ── Wallet metadata blob ──────────────────────────────────────────────────

/// Reads the wallet metadata JSON, migrating it out of SharedPreferences on
/// first run after upgrade.
///
/// Returns null when the user has no wallets.
Future<String?> readWalletsMetadata() async {
  final stored = await _storage.read(key: _walletsMetadataKey);
  if (stored != null && stored.isNotEmpty) return stored;

  // Migration: SharedPreferences → secure storage. Per-wallet balances are
  // financial data and should not sit in plaintext app storage.
  final prefs = await SharedPreferences.getInstance();
  // ignore: deprecated_member_use_from_same_package
  final legacy = prefs.getString(AppConstants.keyWalletsLegacy);
  if (legacy == null || legacy.isEmpty) return null;

  await _storage.write(key: _walletsMetadataKey, value: legacy);
  // ignore: deprecated_member_use_from_same_package
  await prefs.remove(AppConstants.keyWalletsLegacy);
  if (kDebugMode) {
    debugPrint('[SecureStorage] migrated wallet metadata out of prefs');
  }
  return legacy;
}

/// Persists the wallet metadata JSON.
Future<void> writeWalletsMetadata(String json) =>
    _storage.write(key: _walletsMetadataKey, value: json);

/// Removes the wallet metadata blob entirely.
Future<void> clearWalletsMetadata() =>
    _storage.delete(key: _walletsMetadataKey);

// ── Other sensitive blobs ─────────────────────────────────────────────────

/// Reads a sensitive JSON blob, migrating it out of SharedPreferences the
/// first time it is requested.
///
/// Used for data that reveals the user's on-chain footprint — Sentinel's
/// address watch map and balance baselines, and the cached health-check
/// result (which lists every UTXO address and amount). None of it belongs in
/// plaintext app storage.
Future<String?> readSecureBlob(String key) async {
  final stored = await _storage.read(key: key);
  if (stored != null && stored.isNotEmpty) return stored;

  final prefs = await SharedPreferences.getInstance();
  final legacy = prefs.getString(key);
  if (legacy == null || legacy.isEmpty) return null;

  await _storage.write(key: key, value: legacy);
  await prefs.remove(key);
  if (kDebugMode) debugPrint('[SecureStorage] migrated "$key" out of prefs');
  return legacy;
}

/// Reads a secure value *without* attempting a SharedPreferences migration.
///
/// Use this when the legacy prefs entry was not a string: `getString` on a
/// key holding a double or int throws a TypeError, so those migrations have
/// to be done by the caller with the right getter.
Future<String?> readSecureValue(String key) => _storage.read(key: key);

/// Writes a sensitive JSON blob.
Future<void> writeSecureBlob(String key, String value) =>
    _storage.write(key: key, value: value);

/// Deletes a sensitive JSON blob from both stores.
Future<void> deleteSecureBlob(String key) async {
  await _storage.delete(key: key);
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(key);
}

// ── App lock ──────────────────────────────────────────────────────────────

/// Authenticates the user to unlock the app.
/// Returns true on success, false on cancellation or failure.
/// Used by the app-lock feature — does NOT gate any storage read/write.
Future<bool> authenticateForAppLock() =>
    _authenticate(reason: 'Authenticate to open Bag');

/// Prompts for biometric / device-credential authentication.
///
/// Use this when gating display of sensitive data not managed by this
/// service (e.g. the license key). Returns false on cancellation or failure.
Future<bool> authenticateToView({required String reason}) =>
    _authenticate(reason: reason);

// ── Internal ──────────────────────────────────────────────────────────────

/// Triggers the system biometric / device-credential prompt.
/// Returns false on cancellation, failure, or platform error.
Future<bool> _authenticate({required String reason}) async {
  try {
    return await _auth.authenticate(
      localizedReason: reason,
      options: const AuthenticationOptions(
        biometricOnly: false,
        stickyAuth: true,
      ),
    );
  } on PlatformException catch (e) {
    // Log the code only — never the message, which some OEM implementations
    // populate with user-identifying text.
    if (kDebugMode) debugPrint('[BiometricAuth] PlatformException: ${e.code}');
    return false;
  }
}

enum BiometricAvailability {
  /// Biometrics or device credential available and enrolled.
  /// Any screen lock (PIN, pattern, fingerprint, face) is set up.
  available,

  /// No screen lock of any kind is set up on the device.
  unsupported,
}
