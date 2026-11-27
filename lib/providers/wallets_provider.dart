import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/wallet_entry.dart';
import '../core/constants/app_constants.dart';
import '../services/review_prompt_service.dart';
import '../services/sentinel_records.dart';
import '../services/sentinel_service.dart';
import '../services/sentinel_store.dart';
import '../services/wallet/biometric_storage_service.dart';
import '../services/wallet/esplora_client.dart';
import '../services/wallet/wallet_engine.dart';
import '../services/wallet/wallet_scanner.dart';
import '../services/wallet/wallet_store.dart';
import 'esplora_client_provider.dart';
import 'health_check_provider.dart';
import 'network_settings_provider.dart';
import 'portfolio_provider.dart';
import 'purchase_provider.dart';
import 'route_status_provider.dart';
import 'shared_preferences_provider.dart';
import '../models/network_route.dart';
import '../services/network/route_gate.dart';
import '../services/network/routed_http.dart';

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

  /// Wallets whose last scan the route pre-flight refused. Such a scan sets
  /// `scanError` but not `lastScanAt`, so a recently scanned wallet isn't
  /// stale; [scanAllIfStale] with `includeRouteBlocked` rescans these too.
  final Set<String> _routeBlocked = {};

  /// Wallets with a scan in progress. `isScanning` is only set once a scan
  /// has read the secret (and, on a private route, probed it), so two
  /// callers in that window (the Pro-on rescan and a resume, or a resume and
  /// Tor coming back) would both scan and double every explorer lookup.
  final Set<String> _inFlight = {};

  @override
  List<WalletEntry> build() {
    final wallets = ref.read(initialWalletsProvider);

    // Pro just came on (bought again, or the store answered late after a
    // reinstall): balances kept while scans were off are stale, so refresh
    // them once. Only the false → true change fires; Pro staying on, or
    // going off, scans nothing.
    ref.listen<bool>(proUnlockedProvider, (previous, unlocked) {
      if (previous == false && unlocked) unawaited(scanAllIfStale());
    });

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

  /// Adding and editing wallets is Pro. The only callers sit in the Pro
  /// layout; this is the defence in depth behind it (M-13). Removing is not
  /// gated: a free user can always take a wallet out (ruling R-B2g).
  bool get _pro => ref.read(proUnlockedProvider);

  /// Validates and connects a new single-sig (zpub) wallet, then scans it.
  /// Throws [ZpubException] if the zpub is invalid.
  Future<void> addWallet(String zpub, {String? label}) async {
    if (!_pro) return;
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
  /// (e.g. a Bitkey 2-of-3 multisig), then scans it. The whole export may be
  /// pasted — Bitkey's `External:` + `Internal:` lines are merged into one
  /// wallet by [parseDescriptor].
  /// Throws [DescriptorException] if the descriptor is invalid, or if it
  /// covers receive addresses only: change from the user's own spends would
  /// then land on addresses Bag never scans, and the balance would drop by
  /// the whole consumed input after every transaction.
  Future<void> addDescriptorWallet(String descriptor, {String? label}) async {
    if (!_pro) return;
    final trimmed = descriptor.trim();
    final parsed = parseDescriptor(trimmed); // throws on bad input
    if (parsed.isReceiveOnly) {
      throw const DescriptorException(
          'This descriptor covers receive addresses only (…/0/*), so change '
          'from your own transactions would be invisible and the balance '
          'would be wrong after every spend. Paste the complete export — '
          'Bitkey shows it as External and Internal — or a single …/<0;1>/* '
          'descriptor.');
    }

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
    if (!_pro) return;
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
    if (!_pro) return;
    _updateEntry(
      id,
      (w) => w.kind == WalletKind.manual
          ? w.copyWith(lastSats: sats, lastScanAt: DateTime.now())
          : w,
    );
    await _persistMetadata();
    _updatePortfolioTotal();
  }

  /// Removes a wallet from secure storage and state, along with what Bag
  /// derived from it (M-11): its addresses, txids and balance in Sentinel's
  /// blobs, and the health check's result. That result is portfolio-wide,
  /// lists every UTXO address of the wallets it covered and carries no
  /// wallet ids, so removing any watch-only wallet clears it (cached copy
  /// included); the next check recomputes it. Manual entries have no
  /// addresses and touch neither.
  Future<void> removeWallet(String id) async {
    final removed = state.where((w) => w.id == id).firstOrNull;
    await deleteWalletSecretForId(id);
    state = state.where((w) => w.id != id).toList();
    await _persistMetadata();
    _updatePortfolioTotal();
    // Best effort: a secure-storage error here must not skip the health-check
    // clear below, or stop a caller removing several wallets in a row (net
    // R-2). Only the error's type is logged: its message could name a
    // stored key.
    try {
      await purgeSentinelWallet(id);
    } catch (e) {
      debugPrint('[Wallets] Sentinel purge failed: ${e.runtimeType}');
    }
    if (removed != null && removed.isWatchOnly) {
      await ref.read(portfolioHealthCheckProvider.notifier).clear();
    }
  }

  /// Renames a wallet.
  Future<void> renameWallet(String id, String label) async {
    if (!_pro) return;
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
  ///
  /// Live balances are Pro. Without it this does nothing and makes no
  /// request, so a wallet kept after Pro went away (an unreadable licence,
  /// say) keeps its last balance, which still counts toward net worth (ruling
  /// R-B2g). Every scan goes through here: [scanAll], [scanAllIfStale] (app
  /// resume, pull to refresh, Tor coming back) and the Scan Now button.
  Future<void> scan(String id) async {
    if (!ref.read(proUnlockedProvider)) return;
    // Before any await: a second caller for the same wallet does nothing.
    if (!_inFlight.add(id)) return;
    try {
      await _scan(id);
    } finally {
      _inFlight.remove(id);
    }
  }

  Future<void> _scan(String id) async {
    final entry = state.firstWhere(
      (w) => w.id == id,
      orElse: () => throw StateError('Wallet $id not found'),
    );
    if (entry.isScanning || !entry.isWatchOnly) return;
    // Re-added below if the route refuses this scan too.
    _routeBlocked.remove(id);

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

    // Route pre-flight — always do a fresh probe rather than relying on
    // the cached routeStatusProvider value. Tor or the proxy can become
    // unavailable after the last cached check, which would cause every
    // request to fail silently.
    final settings = ref.read(networkSettingsProvider);
    final route = settings.route;
    final baseUrl = settings.effectiveBaseUrl;
    // A .onion explorer on a route that can't reach one: the routing layer
    // would refuse every lookup, so don't start (R-2).
    if (!route.canReachOnion &&
        isOnionHost(Uri.tryParse(baseUrl)?.host ?? '')) {
      _routeBlocked.add(id);
      _updateEntry(
        id,
        (w) => w.copyWith(isScanning: false, scanError: onionNeedsTorMessage),
      );
      return;
    }
    if (route.isPrivate) {
      final status = await RouteGate.probe(route);
      if (status != RouteStatus.available) {
        _routeBlocked.add(id);
        _updateEntry(
          id,
          (w) => w.copyWith(
            isScanning: false,
            scanError: routeUnavailableMessage(route),
          ),
        );
        return;
      }
      // Sync the cached status so the UI badge reflects reality without
      // triggering a second probe or passing through the loading state.
      ref.read(routeStatusProvider.notifier).setValue(status);
    }

    // Wallets added before receive-only descriptors were rejected are still
    // stored that way. Surface it on every scan rather than silently
    // reporting a balance that stops being right after the first spend.
    final descriptor =
        source is DescriptorAddressSource ? source.descriptor : null;
    final receiveOnlyWarning = descriptor?.isReceiveOnly == true
        ? 'Receive-only descriptor — change addresses are not watched, so '
            'this balance is wrong after any spend. Remove the wallet and '
            'paste the complete export (External and Internal).'
        : null;

    final client = ref.read(esploraClientProvider);
    _updateEntry(
      id,
      (w) => w.copyWith(isScanning: true, scanError: null, scanProgress: 0),
    );

    // The route (or explorer) this scan started on must still be the
    // selected one before every batch of lookups, and before anything is
    // written (R-1). The provider closes the old client on a change too;
    // this check is what stops a scan between requests.
    void requireSameRoute() {
      final now = ref.read(networkSettingsProvider);
      if (now.route != route || now.effectiveBaseUrl != baseUrl) {
        throw const RouteChangedException();
      }
    }

    try {
      final balance = await scanWallet(
        source,
        client,
        onProgress: (index) {
          requireSameRoute();
          _updateEntry(id, (w) => w.copyWith(scanProgress: index));
        },
      );
      requireSameRoute();

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
          scanError: receiveOnlyWarning,
          // Re-derive so a stored receive-only wallet is labelled as such.
          descriptorSummary: descriptor?.summary ?? w.descriptorSummary,
        ),
      );

      await _persistMetadata();
      _updatePortfolioTotal();
      await _keepSentinelWatchMap(id, source, balance);

      // A non-zero balance just appeared for a wallet the user set up
      // themselves — the best moment to ask for a rating (asked once, ever).
      if (receiveOnlyWarning == null && balance.totalSats > 0) {
        unawaited(ReviewPromptService.afterSuccessfulWalletScan());
      }
    } on RouteChangedException {
      // Abandoned, not failed: the last balance stays, and the scan counts
      // as route-blocked, so the recovery refresh runs it on the new route.
      _routeBlocked.add(id);
      _updateEntry(
        id,
        (w) => w.copyWith(
          isScanning: false,
          scanError: routeChangedMessage,
          scanProgress: 0,
        ),
      );
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
  ///
  /// With [includeRouteBlocked] (the route has just come back, e.g. the
  /// built-in Tor client became ready), also rescans wallets whose last scan
  /// the route refused, however recent their last successful scan.
  Future<void> scanAllIfStale({bool includeRouteBlocked = false}) async {
    for (final wallet in List.of(state)) {
      if (wallet.isScanning) continue;
      if (wallet.isStale ||
          (includeRouteBlocked && _routeBlocked.contains(wallet.id))) {
        await scan(wallet.id);
      }
    }
  }

  // ── Internals ────────────────────────────────────────────────────────────

  /// iOS Sentinel Lite (spec D3): background runs never derive addresses,
  /// so after each successful scan with Sentinel on, the wallet's part of
  /// the encrypted watch map is replaced with the entries Android's full
  /// scan builds, keeping the addresses the scan no longer lists as retired
  /// entries for 30 days (`retireSentinelWatchEntries`, R31), so a spend
  /// from them is still netted as the wallet's own. The edit runs on the
  /// watch map's queue, and which wallets are stored (and the wallet's
  /// label) is read when its turn comes, not when the scan ends: a wallet
  /// removed in between gets no entries, and entries of every wallet no
  /// longer stored (retired ones too) go in the same write, so a removal
  /// whose best-effort purge failed doesn't stay watched (R25).
  /// Android's service builds its own map, so nothing is written there.
  /// Never fails the scan: an error is logged by type only.
  Future<void> _keepSentinelWatchMap(
    String id,
    AddressSource source,
    WalletBalance balance,
  ) async {
    if (SentinelService.isAlwaysOn) return;
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      if (!(prefs.getBool(AppConstants.keySentinelEnabled) ?? false)) return;
      await editSentinelWatchMap((map) {
        final stored = {
          for (final w in state)
            if (w.isWatchOnly) w.id: w,
        };
        map.removeWhere((_, e) => !stored.containsKey(e.walletId));
        final wallet = stored[id];
        if (wallet == null) return;
        retireSentinelWatchEntries(
          map,
          walletId: id,
          walletLabel: wallet.label,
          fresh: sentinelWatchEntries(
            walletId: id,
            walletLabel: wallet.label,
            source: source,
            balance: balance,
          ),
          now: DateTime.now(),
        );
      });
    } catch (e) {
      debugPrint('[Wallets] Sentinel watch map not updated: ${e.runtimeType}');
    }
  }

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
