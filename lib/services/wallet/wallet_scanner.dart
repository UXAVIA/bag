// Gap-limit address scanner.
//
// Derives consecutive addresses from an [AddressSource] — a BIP84 zpub or a
// parsed output descriptor (including multisig) — queries Esplora for each,
// and stops when _gapLimit consecutive addresses have no transactions
// (BIP44/BIP84 standard). Only addresses are sent to Esplora — the zpub or
// descriptor stays on-device.
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

/// Hard ceiling on addresses scanned per chain.
///
/// Without it, a server that answers every address with "has transactions"
/// (a buggy or hostile explorer) would keep the scanner looping forever,
/// draining battery and leaking an unbounded number of derived addresses.
const _maxAddressesPerChain = 1000;

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

  /// First never-used external index — where the wallet will hand out its
  /// next receive address. 0 for an empty chain. Unlike [lastExternalIndex],
  /// which reports 0 both for "index 0 used" and "nothing used", this is
  /// unambiguous, so Sentinel's frontier watch starts at the right place.
  final int nextExternalIndex;

  /// First never-used change index — where the wallet's next change output
  /// will land. 0 for an empty chain.
  final int nextChangeIndex;

  /// Addresses that currently hold UTXOs (balanceSats > 0).
  /// Used by Sentinel to build its mempool watch list.
  final List<String> utxoAddresses;

  const WalletBalance({
    required this.totalSats,
    required this.usedAddressCount,
    required this.lastExternalIndex,
    required this.lastChangeIndex,
    required this.nextExternalIndex,
    required this.nextChangeIndex,
    required this.utxoAddresses,
  });
}

/// Scans external (0) and change (1) address chains up to the gap limit.
///
/// [client] is the configured Esplora client (base URL + optional Tor proxy).
/// [onProgress] is called with the current address index during scanning
/// so callers can show a progress indicator.
///
/// Throws [EsploraException] on network errors.
Future<WalletBalance> scanWallet(
  AddressSource source,
  EsploraClient client, {
  void Function(int index)? onProgress,
}) async {
  // Reduce concurrency over Tor: fewer parallel circuits = fewer mid-batch
  // rotation failures. Clearnet can go wider without reliability risk.
  final concurrency = client.useTor ? 2 : 4;

  int totalSats = 0;
  int usedCount = 0;
  final utxoAddresses = <String>{};

  // Scans one chain (0 = external, 1 = change) and returns the last used
  // index, or -1 if the chain is empty (or the source has no such chain).
  //
  // Strategy: fetch addresses in batches of [concurrency]. After each batch,
  // count the trailing gap across the whole chain so far. Stop once the gap
  // reaches _gapLimit. This preserves exact BIP44 gap-limit semantics while
  // avoiding purely sequential fetches that compound Tor rotation risk.
  Future<int> scanChain(int chain) async {
    if (!source.hasChain(chain)) return -1;

    final results = <int, (AddressStats, String)>{}; // index → (stats, address)
    // Indices whose derived child key was invalid (BIP32 §4 says skip them).
    // They must not count towards the gap, or a 1-in-2^127 event would
    // silently truncate the scan.
    final skipped = <int>{};
    int index = 0;

    while (index < _maxAddressesPerChain) {
      // Build the next batch of indices to fetch.
      final batchIndices = List.generate(concurrency, (i) => index + i);

      onProgress?.call(index);

      // Derive first (synchronous, may throw for an invalid child), then
      // fetch the batch in parallel.
      final batch = <int, String>{};
      for (final i in batchIndices) {
        try {
          batch[i] = source.addressAt(chain, i);
        } on Bip32InvalidChildException {
          skipped.add(i);
        }
      }

      final entries = await Future.wait(batch.entries.map((e) async {
        final stats = await client.fetchAddress(e.value);
        return MapEntry(e.key, (stats, e.value));
      }));
      for (final e in entries) {
        results[e.key] = e.value;
      }

      index += concurrency;

      // Count the trailing gap: how many consecutive addresses (from the
      // highest index downward) have had no transactions.
      int trailingGap = 0;
      for (var i = index - 1; i >= 0; i--) {
        if (skipped.contains(i)) continue;
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

    return lastUsed;
  }

  final lastExternal = await scanChain(0);
  final lastChange = await scanChain(1);

  return WalletBalance(
    totalSats: totalSats,
    usedAddressCount: usedCount,
    lastExternalIndex: lastExternal < 0 ? 0 : lastExternal,
    lastChangeIndex: lastChange < 0 ? 0 : lastChange,
    nextExternalIndex: lastExternal + 1,
    nextChangeIndex: lastChange + 1,
    utxoAddresses: utxoAddresses.toList(),
  );
}
