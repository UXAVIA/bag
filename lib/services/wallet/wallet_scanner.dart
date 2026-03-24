// Gap-limit address scanner.
//
// Derives consecutive addresses from a zpub, queries Esplora for each,
// and stops when _gapLimit consecutive addresses have no transactions
// (BIP44/BIP84 standard). Only bc1q addresses are sent to Esplora — the
// zpub stays on-device.
//
// Concurrency:
// - Over clearnet: 4 parallel requests per chain (fast, low failure risk).
// - Over Tor: 2 parallel requests per chain (fewer concurrent circuits =
//   more reliable; mirrors health_check_provider batching strategy).
// - Within a batch, results are applied in arrival order but gap counting
//   is done after each batch to keep the sequential-gap semantics correct.

import 'wallet_engine.dart';
import 'esplora_client.dart';

const _gapLimit = 20;

/// Aggregated balance across all scanned addresses.
final class WalletBalance {
  /// Total confirmed + unconfirmed balance in satoshis.
  final int totalSats;

  /// Number of addresses that have ever received funds.
  final int usedAddressCount;

  /// The last external (receive) address index scanned.
  final int lastExternalIndex;

  /// The last change address index scanned.
  final int lastChangeIndex;

  /// Addresses that currently hold UTXOs (balanceSats > 0).
  /// Used by Sentinel to build its mempool watch list.
  final List<String> utxoAddresses;

  const WalletBalance({
    required this.totalSats,
    required this.usedAddressCount,
    required this.lastExternalIndex,
    required this.lastChangeIndex,
    required this.utxoAddresses,
  });
}

/// Scans external (0) and change (1) address chains up to the gap limit.
///
/// [client] is the configured Esplora client (base URL + optional Tor proxy).
/// [onProgress] is called with the current address index during scanning
/// so callers can show a progress indicator.
///
/// Throws [ZpubException] if the zpub is invalid.
/// Throws [EsploraException] on network errors.
Future<WalletBalance> scanWallet(
  ZpubKey root,
  EsploraClient client, {
  void Function(int index)? onProgress,
}) async {
  // Reduce concurrency over Tor: fewer parallel circuits = fewer mid-batch
  // rotation failures. Clearnet can go wider without reliability risk.
  final concurrency = client.useTor ? 2 : 4;

  int totalSats = 0;
  int usedCount = 0;
  int lastExternal = 0;
  int lastChange = 0;
  final utxoAddresses = <String>{};

  // Scans one chain (account 0 = external, 1 = change) and returns the
  // last used index, or 0 if the chain is empty.
  //
  // Strategy: fetch addresses in batches of [concurrency]. After each batch,
  // count the trailing gap across the whole chain so far. Stop once the gap
  // reaches _gapLimit. This preserves exact BIP44 gap-limit semantics while
  // avoiding purely sequential fetches that compound Tor rotation risk.
  Future<int> scanChain(int account) async {
    final results = <int, (AddressStats, String)>{}; // index → (stats, address)
    int index = 0;

    while (true) {
      // Build the next batch of indices to fetch.
      final batchIndices = List.generate(
        concurrency,
        (i) => index + i,
      );

      onProgress?.call(index);

      // Fetch the batch in parallel.
      final futures = batchIndices.map((i) async {
        final key = deriveAddress(root, account, i);
        final address = pubKeyToP2wpkh(key.publicKey);
        final stats = await client.fetchAddress(address);
        return MapEntry(i, (stats, address));
      });

      final entries = await Future.wait(futures);
      for (final e in entries) {
        results[e.key] = e.value;
      }

      index += concurrency;

      // Count the trailing gap: how many consecutive addresses (from the
      // highest index downward) have had no transactions.
      int trailingGap = 0;
      for (var i = index - 1; i >= 0; i--) {
        final entry = results[i];
        if (entry == null || entry.$1.hasTransactions) break;
        trailingGap++;
      }

      if (trailingGap >= _gapLimit) break;
    }

    // Aggregate balance from all fetched addresses.
    int lastUsed = -1;
    results.forEach((i, entry) {
      final (stats, address) = entry;
      if (stats.hasTransactions) {
        totalSats += stats.balanceSats;
        usedCount++;
        if (i > lastUsed) lastUsed = i;
      }
      if (stats.balanceSats > 0) utxoAddresses.add(address);
    });

    return lastUsed < 0 ? 0 : lastUsed;
  }

  lastExternal = await scanChain(0);
  lastChange = await scanChain(1);

  return WalletBalance(
    totalSats: totalSats,
    usedAddressCount: usedCount,
    lastExternalIndex: lastExternal,
    lastChangeIndex: lastChange,
    utxoAddresses: utxoAddresses.toList(),
  );
}
