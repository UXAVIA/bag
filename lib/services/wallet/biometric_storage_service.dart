/// Secure storage for the user's zpub behind biometric authentication.
///
/// Storage:   flutter_secure_storage → Android Keystore AES-256-GCM.
/// Auth gate: local_auth biometric prompt required to READ/DISPLAY the
///            raw zpub string. Internal scanning reads without displaying.
///
/// Security invariants:
/// - The zpub string is NEVER logged.
/// - [readZpubForDisplayById] requires a successful biometric prompt every call.
/// - [readZpubForScanningById] does NOT display the string — only passes it
///   into the derivation engine which never surfaces it to the UI.
/// - On authentication failure or cancellation, null is returned silently.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

// Legacy single-wallet key — kept for migration in readZpubForScanningById.
const _zpubStorageKey = 'wallet_zpub';

// Multi-wallet: one secure key per wallet UUID.
String _zpubKeyForId(String id) => 'wallet_zpub_$id';

const _storage = FlutterSecureStorage(
  aOptions: AndroidOptions(),
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

// ── Multi-wallet API (keyed by wallet UUID) ───────────────────────────────

/// Stores [zpub] encrypted in the Android Keystore keyed by wallet [id].
Future<void> storeZpubForId(String id, String zpub) =>
    _storage.write(key: _zpubKeyForId(id), value: zpub);

/// Reads zpub for internal scanning by wallet [id].
///
/// Falls back to the legacy single-wallet key on first run after upgrade,
/// then migrates transparently to the new key format.
Future<String?> readZpubForScanningById(String id) async {
  final zpub = await _storage.read(key: _zpubKeyForId(id));
  if (zpub != null) return zpub;

  // Migration: legacy key → new keyed key (runs once after upgrade).
  final legacy = await _storage.read(key: _zpubStorageKey);
  if (legacy != null) {
    await _storage.write(key: _zpubKeyForId(id), value: legacy);
    await _storage.delete(key: _zpubStorageKey);
    if (kDebugMode) debugPrint('[BiometricStorage] migrated legacy zpub → wallet_zpub_$id');
  }
  return legacy;
}

/// Authenticates and returns the zpub for display, keyed by wallet [id].
/// Returns null if authentication is cancelled or fails.
Future<String?> readZpubForDisplayById(String id) async {
  final authenticated = await _authenticate(
    reason: 'Authenticate to view your wallet key',
  );
  if (!authenticated) return null;
  return _storage.read(key: _zpubKeyForId(id));
}

/// Deletes the zpub for wallet [id].
Future<void> deleteZpubForId(String id) =>
    _storage.delete(key: _zpubKeyForId(id));

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
    final result = await _auth.authenticate(
      localizedReason: reason,
      options: const AuthenticationOptions(
        biometricOnly: false,
        stickyAuth: true,
      ),
    );
    if (kDebugMode) debugPrint('[BiometricAuth] result: $result');
    return result;
  } on PlatformException catch (e) {
    if (kDebugMode) debugPrint('[BiometricAuth] PlatformException: code=${e.code} msg=${e.message}');
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
