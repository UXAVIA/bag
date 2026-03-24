import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/constants/app_constants.dart';
import '../models/wallet_entry.dart';
import '../services/tor_service.dart';
import '../services/wallet/biometric_storage_service.dart';
import '../services/wallet/esplora_client.dart';
import '../services/wallet/wallet_engine.dart';
import '../services/wallet/wallet_scanner.dart';
import 'esplora_client_provider.dart';
import 'network_settings_provider.dart';
import 'portfolio_provider.dart';
import 'shared_preferences_provider.dart';
import 'tor_status_provider.dart';

final walletsProvider =
    NotifierProvider<WalletsNotifier, List<WalletEntry>>(WalletsNotifier.new);

class WalletsNotifier extends Notifier<List<WalletEntry>> {
  late SharedPreferences _prefs;
  static const _uuid = Uuid();

  @override
  List<WalletEntry> build() {
    _prefs = ref.read(sharedPreferencesProvider);
    final wallets = _loadOrMigrate();

    // Restore cached aggregate balance to portfolio immediately.
    if (wallets.isNotEmpty) {
      final totalSats =
          wallets.fold<int>(0, (sum, w) => sum + (w.lastSats ?? 0));
      if (totalSats > 0) {
        Future.microtask(
          () => ref.read(portfolioProvider.notifier).setBtcAmount(totalSats / 1e8),
        );
      }
    }

    return wallets;
  }

  // ── Loading & migration ──────────────────────────────────────────────────

  List<WalletEntry> _loadOrMigrate() {
    final json = _prefs.getString(AppConstants.keyWallets);
    if (json != null && json.isNotEmpty) {
      try {
        return WalletEntry.listFromJson(json);
      } catch (e) {
        if (kDebugMode) debugPrint('[Wallets] failed to parse wallets JSON: $e');
        return [];
      }
    }

    // Migration from legacy single-wallet SharedPreferences format.
    final connected = _prefs.getBool(AppConstants.keyWalletConnected) ?? false;
    if (!connected) return [];

    final id = _uuid.v4();
    final lastSats = _prefs.getInt(AppConstants.keyWalletLastSats);
    final lastScanMs = _prefs.getInt(AppConstants.keyWalletLastScanAt);
    final usedAddresses =
        _prefs.getInt(AppConstants.keyWalletUsedAddresses) ?? 0;

    final migrated = WalletEntry(
      id: id,
      label: 'My Wallet',
      lastSats: lastSats,
      lastScanAt: lastScanMs != null
          ? DateTime.fromMillisecondsSinceEpoch(lastScanMs)
          : null,
      usedAddresses: usedAddresses,
    );

    // Persist asynchronously — build() must be synchronous.
    // zpub migration happens lazily in readZpubForScanningById on first scan.
    Future.microtask(() async {
      await _prefs.setString(
        AppConstants.keyWallets,
        WalletEntry.listToJsonString([migrated]),
      );
      if (kDebugMode) debugPrint('[Wallets] migrated single wallet → id=$id');
    });

    return [migrated];
  }

  // ── Public API ───────────────────────────────────────────────────────────

  /// Validates and connects a new wallet. Triggers an initial scan.
  /// Throws [ZpubException] if the zpub is invalid.
  Future<void> addWallet(String zpub, {String? label}) async {
    final trimmed = zpub.trim();
    parseZpub(trimmed); // throws ZpubException on bad input

    final id = _uuid.v4();
    final resolvedLabel = (label?.trim().isNotEmpty == true)
        ? label!.trim()
        : 'Wallet ${state.length + 1}';

    await storeZpubForId(id, trimmed);

    state = [...state, WalletEntry(id: id, label: resolvedLabel)];
    await _persistMetadata();

    await scan(id);
  }

  /// Removes a wallet from secure storage and state.
  Future<void> removeWallet(String id) async {
    await deleteZpubForId(id);
    state = state.where((w) => w.id != id).toList();
    await _persistMetadata();
    _updatePortfolioTotal();
  }

  /// Renames a wallet.
  Future<void> renameWallet(String id, String label) async {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return;
    _updateEntry(id, (w) => w.copyWith(label: trimmed));
    await _persistMetadata();
  }

  /// Authenticates and returns the zpub for display purposes only.
  /// Returns null if authentication is cancelled or fails.
  Future<String?> revealZpub(String id) => readZpubForDisplayById(id);

  /// Scans a single wallet by id.
  Future<void> scan(String id) async {
    final entry = state.firstWhere(
      (w) => w.id == id,
      orElse: () => throw StateError('Wallet $id not found'),
    );
    if (entry.isScanning) return;

    final zpub = await readZpubForScanningById(id);
    if (zpub == null) return;

    ZpubKey root;
    try {
      root = parseZpub(zpub);
    } on ZpubException catch (e) {
      _updateEntry(id, (w) => w.copyWith(isScanning: false, scanError: e.message));
      return;
    }

    // Tor pre-flight — always do a fresh TCP probe rather than relying on
    // the cached torStatusProvider value. Orbot can become unavailable after
    // the last cached check, which would cause every request to fail silently.
    final settings = ref.read(networkSettingsProvider);
    if (settings.useTor) {
      final torStatus = await TorService.probe();
      if (torStatus != TorStatus.available) {
        _updateEntry(
          id,
          (w) => w.copyWith(
            isScanning: false,
            scanError:
                'Tor is enabled but Orbot is not running. Start Orbot and try again.',
          ),
        );
        return;
      }
      // Sync the cached status so the UI badge reflects reality without
      // triggering a second probe or passing through the loading state
      // (which would momentarily make esploraClientProvider use clearnet).
      ref.read(torStatusProvider.notifier).setValue(torStatus);
    }

    final client = ref.read(esploraClientProvider);
    _updateEntry(
      id,
      (w) => w.copyWith(isScanning: true, scanError: null, scanProgress: 0),
    );

    try {
      final balance = await scanWallet(
        root,
        client,
        onProgress: (index) {
          _updateEntry(id, (w) => w.copyWith(scanProgress: index));
        },
      );

      final now = DateTime.now();
      _updateEntry(
        id,
        (w) => w.copyWith(
          isScanning: false,
          lastSats: balance.totalSats,
          lastScanAt: now,
          usedAddresses: balance.usedAddressCount,
          lastExternalIndex: balance.lastExternalIndex,
          lastChangeIndex: balance.lastChangeIndex,
          scanProgress: 0,
          scanError: null,
        ),
      );

      await _persistMetadata();
      _updatePortfolioTotal();
    } on EsploraException catch (e) {
      if (kDebugMode) debugPrint('[Wallets] scan failed ($id): $e');
      _updateEntry(
        id,
        (w) => w.copyWith(
          isScanning: false,
          scanError: 'Network error — check your connection and try again',
          scanProgress: 0,
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[Wallets] scan error ($id): $e');
      _updateEntry(
        id,
        (w) => w.copyWith(
          isScanning: false,
          scanError: 'Scan failed — please try again',
          scanProgress: 0,
        ),
      );
    }
  }

  /// Scans all wallets sequentially.
  Future<void> scanAll() async {
    for (final wallet in List.of(state)) {
      await scan(wallet.id);
    }
  }

  /// Scans all stale wallets. Safe to call on app resume — no-ops if fresh.
  Future<void> scanAllIfStale() async {
    for (final wallet in List.of(state)) {
      if (!wallet.isScanning && wallet.isStale) {
        await scan(wallet.id);
      }
    }
  }

  // ── Internals ────────────────────────────────────────────────────────────

  void _updateEntry(String id, WalletEntry Function(WalletEntry) update) {
    state = [
      for (final w in state)
        if (w.id == id) update(w) else w,
    ];
  }

  void _updatePortfolioTotal() {
    final totalSats =
        state.fold<int>(0, (sum, w) => sum + (w.lastSats ?? 0));
    ref.read(portfolioProvider.notifier).setBtcAmount(totalSats / 1e8);
  }

  /// Persists stable wallet metadata (not transient scan state) to SharedPreferences.
  Future<void> _persistMetadata() async {
    await _prefs.setString(
      AppConstants.keyWallets,
      WalletEntry.listToJsonString(state),
    );
  }
}
