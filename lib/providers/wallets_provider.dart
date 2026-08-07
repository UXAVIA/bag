import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/wallet_entry.dart';
import '../services/tor_service.dart';
import '../services/wallet/biometric_storage_service.dart';
import '../services/wallet/esplora_client.dart';
import '../services/wallet/wallet_engine.dart';
import '../services/wallet/wallet_scanner.dart';
import '../services/wallet/wallet_store.dart';
import 'esplora_client_provider.dart';
import 'network_settings_provider.dart';
import 'portfolio_provider.dart';
import 'tor_status_provider.dart';

export '../services/wallet/wallet_store.dart' show loadWalletsFromStorage;

/// Wallet metadata loaded from secure storage before `runApp`.
///
/// Overridden in `main()` so the wallet list is available synchronously and
/// the UI never flashes an empty portfolio while decryption completes.
/// Defaults to empty for tests and screenshot builds.
final initialWalletsProvider = Provider<List<WalletEntry>>((ref) => const []);

final walletsProvider =
    NotifierProvider<WalletsNotifier, List<WalletEntry>>(WalletsNotifier.new);

class WalletsNotifier extends Notifier<List<WalletEntry>> {
  static const _uuid = Uuid();

  @override
  List<WalletEntry> build() {
    final wallets = ref.read(initialWalletsProvider);

    // Restore the cached aggregate balance to the portfolio immediately.
    if (wallets.isNotEmpty) {
      final totalSats =
          wallets.fold<int>(0, (sum, w) => sum + (w.lastSats ?? 0));
      if (totalSats > 0) {
        Future.microtask(
          () =>
              ref.read(portfolioProvider.notifier).setBtcAmount(totalSats / 1e8),
        );
      }
    }

    return wallets;
  }

  // ── Public API ───────────────────────────────────────────────────────────

  /// Validates and connects a new single-sig (zpub) wallet, then scans it.
  /// Throws [ZpubException] if the zpub is invalid.
  Future<void> addWallet(String zpub, {String? label}) async {
    final trimmed = zpub.trim();
    parseZpub(trimmed); // throws ZpubException on bad input

    final id = _uuid.v4();
    await storeWalletSecretForId(id, trimmed);

    state = [
      ...state,
      WalletEntry(id: id, label: _resolveLabel(label), kind: WalletKind.zpub),
    ];
    await _persistMetadata();

    await scan(id);
  }

  /// Validates and connects a wallet described by an output descriptor
  /// (e.g. a Bitkey 2-of-3 multisig), then scans it.
  /// Throws [DescriptorException] if the descriptor is invalid.
  Future<void> addDescriptorWallet(String descriptor, {String? label}) async {
    final trimmed = descriptor.trim();
    final parsed = parseDescriptor(trimmed); // throws on bad input

    final id = _uuid.v4();
    await storeWalletSecretForId(id, trimmed);

    state = [
      ...state,
      WalletEntry(
        id: id,
        label: _resolveLabel(label),
        kind: WalletKind.descriptor,
        descriptorSummary: parsed.summary,
      ),
    ];
    await _persistMetadata();

    await scan(id);
  }

  /// Adds a manually-tracked balance (e.g. coins held on an exchange).
  /// Nothing is derived and no network request is ever made for it.
  Future<void> addManualEntry({required int sats, String? label}) async {
    final id = _uuid.v4();
    state = [
      ...state,
      WalletEntry(
        id: id,
        label: _resolveLabel(label),
        kind: WalletKind.manual,
        lastSats: sats,
        lastScanAt: DateTime.now(),
      ),
    ];
    await _persistMetadata();
    _updatePortfolioTotal();
  }

  /// Updates the amount on a manual entry.
  Future<void> updateManualEntry(String id, int sats) async {
    _updateEntry(
      id,
      (w) => w.kind == WalletKind.manual
          ? w.copyWith(lastSats: sats, lastScanAt: DateTime.now())
          : w,
    );
    await _persistMetadata();
    _updatePortfolioTotal();
  }

  /// Removes a wallet from secure storage and state.
  Future<void> removeWallet(String id) async {
    await deleteWalletSecretForId(id);
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

  /// Authenticates and returns the stored zpub or descriptor for display.
  /// Returns null if authentication is cancelled or fails.
  Future<String?> revealSecret(String id) =>
      readWalletSecretForDisplayById(id);

  /// Scans a single watch-only wallet by id. No-ops for manual entries.
  Future<void> scan(String id) async {
    final entry = state.firstWhere(
      (w) => w.id == id,
      orElse: () => throw StateError('Wallet $id not found'),
    );
    if (entry.isScanning || !entry.isWatchOnly) return;

    final secret = await readWalletSecretForScanningById(id);
    if (secret == null) {
      _updateEntry(
        id,
        (w) => w.copyWith(
          isScanning: false,
          scanError: 'Wallet key is missing — remove and re-add this wallet',
        ),
      );
      return;
    }

    final AddressSource source;
    try {
      source = buildAddressSource(entry.kind, secret);
    } on ZpubException catch (e) {
      _updateEntry(
          id, (w) => w.copyWith(isScanning: false, scanError: e.message));
      return;
    } on DescriptorException catch (e) {
      _updateEntry(
          id, (w) => w.copyWith(isScanning: false, scanError: e.message));
      return;
    }

    // Tor pre-flight — always do a fresh probe rather than relying on
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
        source,
        client,
        onProgress: (index) {
          _updateEntry(id, (w) => w.copyWith(scanProgress: index));
        },
      );

      _updateEntry(
        id,
        (w) => w.copyWith(
          isScanning: false,
          lastSats: balance.totalSats,
          lastScanAt: DateTime.now(),
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
      if (kDebugMode) debugPrint('[Wallets] scan failed: $e');
      _updateEntry(
        id,
        (w) => w.copyWith(
          isScanning: false,
          scanError: 'Network error — check your connection and try again',
          scanProgress: 0,
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[Wallets] scan error: $e');
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

  /// Scans all watch-only wallets sequentially.
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

  String _resolveLabel(String? label) {
    final trimmed = label?.trim() ?? '';
    return trimmed.isNotEmpty ? trimmed : 'Wallet ${state.length + 1}';
  }

  void _updateEntry(String id, WalletEntry Function(WalletEntry) update) {
    state = [
      for (final w in state)
        if (w.id == id) update(w) else w,
    ];
  }

  void _updatePortfolioTotal() {
    final totalSats = state.fold<int>(0, (sum, w) => sum + (w.lastSats ?? 0));
    ref.read(portfolioProvider.notifier).setBtcAmount(totalSats / 1e8);
  }

  /// Persists stable wallet metadata (not transient scan state) to secure
  /// storage. Balances are financial data — they are never written to
  /// plaintext SharedPreferences.
  Future<void> _persistMetadata() => saveWalletsToStorage(state);
}
