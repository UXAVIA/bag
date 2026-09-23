/// Isolate-safe access to persisted wallet metadata and address derivation.
///
/// The foreground app, the WorkManager widget isolate and the Sentinel
/// foreground-service isolate all read the same encrypted blob and must derive
/// addresses identically — so both live here rather than inside a Riverpod
/// provider.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../models/network_settings.dart';
import '../../models/wallet_entry.dart';
import 'biometric_storage_service.dart';
import 'wallet_engine.dart';

/// Reads wallet metadata from secure storage, migrating pre-1.3.0 installs
/// (both the SharedPreferences blob and the even older single-wallet keys).
///
/// Returns an empty list when the user has no wallets, and also when the
/// stored blob is unreadable — a corrupt blob must not crash every launch.
Future<List<WalletEntry>> loadWalletsFromStorage() async {
  final json = await readWalletsMetadata();
  if (json != null && json.isNotEmpty) {
    await _purgeLegacyWalletPrefs();
    try {
      return WalletEntry.listFromJson(json);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[WalletStore] failed to parse wallet metadata: $e');
      }
      return const [];
    }
  }

  // Migration from the original single-wallet SharedPreferences format.
  final prefs = await SharedPreferences.getInstance();
  final connected = prefs.getBool(AppConstants.keyWalletConnected) ?? false;
  if (!connected) {
    await _purgeLegacyWalletPrefs();
    return const [];
  }

  final lastScanMs = prefs.getInt(AppConstants.keyWalletLastScanAt);
  final migrated = WalletEntry(
    id: const Uuid().v4(),
    label: 'My Wallet',
    kind: WalletKind.zpub,
    lastSats: prefs.getInt(AppConstants.keyWalletLastSats),
    lastScanAt: lastScanMs != null
        ? DateTime.fromMillisecondsSinceEpoch(lastScanMs)
        : null,
    usedAddresses: prefs.getInt(AppConstants.keyWalletUsedAddresses) ?? 0,
  );

  // The zpub itself migrates lazily on first scan via the legacy-key fallback
  // in readWalletSecretForScanningById.
  await writeWalletsMetadata(WalletEntry.listToJsonString([migrated]));
  await _purgeLegacyWalletPrefs();
  if (kDebugMode) debugPrint('[WalletStore] migrated legacy single wallet');
  return [migrated];
}

/// Deletes the pre-multi-wallet SharedPreferences keys.
///
/// Runs on every load, not just during migration: installs that moved to the
/// multi-wallet format back in 1.0.x never cleaned these up, so a plaintext
/// `wallet_last_sats` balance can still be sitting on disk years later.
Future<void> _purgeLegacyWalletPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  for (final key in const [
    AppConstants.keyWalletConnected,
    AppConstants.keyWalletLastSats,
    AppConstants.keyWalletLastScanAt,
    AppConstants.keyWalletUsedAddresses,
  ]) {
    if (prefs.containsKey(key)) await prefs.remove(key);
  }
}

/// Persists wallet metadata to secure storage.
Future<void> saveWalletsToStorage(List<WalletEntry> wallets) =>
    writeWalletsMetadata(WalletEntry.listToJsonString(wallets));

// ── Aggregate portfolio amount ────────────────────────────────────────────

/// Reads the total BTC amount, migrating it out of SharedPreferences.
///
/// This is the single number that says "this device holds X bitcoin", so it
/// is encrypted at rest alongside the per-wallet balances rather than sitting
/// in plaintext app storage.
Future<double> loadBtcAmount() async {
  // readSecureValue, not readSecureBlob: the legacy prefs entry is a double,
  // and getString on it would throw a TypeError for every existing user.
  final raw = await readSecureValue(AppConstants.keyBtcAmount);
  if (raw != null) return double.tryParse(raw) ?? 0.0;

  final prefs = await SharedPreferences.getInstance();
  final legacy = prefs.getDouble(AppConstants.keyBtcAmount);
  if (legacy == null) return 0.0;
  await writeSecureBlob(AppConstants.keyBtcAmount, legacy.toString());
  await prefs.remove(AppConstants.keyBtcAmount);
  if (kDebugMode) debugPrint('[WalletStore] migrated BTC amount out of prefs');
  return legacy;
}

/// Persists the total BTC amount to secure storage.
Future<void> saveBtcAmount(double amount) =>
    writeSecureBlob(AppConstants.keyBtcAmount, amount.toString());

// ── Custom explorer URL ───────────────────────────────────────────────────

/// Reads the user's custom Esplora URL, migrating it out of SharedPreferences.
///
/// A self-hosted node address — often a `.onion` — identifies infrastructure
/// the user runs, so it is encrypted at rest alongside the wallet data. The
/// preset *choice* stays in plain prefs: knowing "custom" is selected reveals
/// nothing without the address itself.
Future<String> loadExplorerCustomUrl() async =>
    await readSecureBlob(AppConstants.keyExplorerCustomUrl) ?? '';

/// Persists the custom Esplora URL to secure storage.
Future<void> saveExplorerCustomUrl(String url) =>
    writeSecureBlob(AppConstants.keyExplorerCustomUrl, url);

/// Resolves the Esplora base URL from stored settings.
///
/// Shared by the WorkManager and Sentinel isolates, which have no Riverpod and
/// so cannot read `networkSettingsProvider`.
Future<String> resolveExplorerBaseUrl() async {
  final prefs = await SharedPreferences.getInstance();
  final presetIndex = prefs.getInt(AppConstants.keyExplorerPreset) ?? 0;
  final preset = ExplorerPreset.values[presetIndex.clamp(
    0,
    ExplorerPreset.values.length - 1,
  )];
  if (preset != ExplorerPreset.custom) {
    return preset == ExplorerPreset.mempool
        ? AppConstants.explorerMempool
        : AppConstants.explorerBlockstream;
  }
  final customUrl = await loadExplorerCustomUrl();
  return customUrl.isNotEmpty ? customUrl : AppConstants.explorerBlockstream;
}

/// Builds the [AddressSource] for a stored wallet secret.
///
/// Throws [ZpubException] or [DescriptorException] on invalid material, and
/// [StateError] for manual entries, which have no addresses at all.
AddressSource buildAddressSource(WalletKind kind, String secret) =>
    switch (kind) {
      WalletKind.zpub => ZpubAddressSource(parseZpub(secret)),
      WalletKind.descriptor => DescriptorAddressSource(parseDescriptor(secret)),
      WalletKind.manual =>
        throw StateError('Manual entries have no derivable addresses'),
    };
