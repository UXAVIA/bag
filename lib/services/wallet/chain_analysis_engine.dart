// Pure chain analysis logic — no I/O, no Flutter dependencies.
// All inputs are pre-fetched; output is a ChainAnalysisResult.
//
// Scoring model (0–100):
// ┌──────────────────────────┬──────┬──────────────────────────────────────┐
// │ Component                │ Max  │ How scored                           │
// ├──────────────────────────┼──────┼──────────────────────────────────────┤
// │ Address hygiene          │  30  │ (1 − reuse%) × 30                    │
// │ Coinjoin coverage        │  25  │ (coinjoined UTXOs / total UTXOs) × 25│
// │ UTXO cleanliness         │  20  │ 1 − dust%×0.5 − round%×0.3) × 20    │
// │ Address type consistency │  10  │ 10 if all same type, 0 if mixed      │
// │ Privacy infrastructure   │  15  │ Tor=10, custom node=5                │
// └──────────────────────────┴──────┴──────────────────────────────────────┘
//
// Rationale for proportional scoring:
// - A wallet with 5% reused addresses is meaningfully better than one with
//   80% reuse. Flat "−25 if any reuse" hides that difference.
// - Similarly, 50% coinjoined UTXOs is a real privacy improvement vs 0%,
//   and deserves credit even if the wallet isn't fully mixed.

import '../../models/chain_analysis.dart';

/// Derives the address type from a Bitcoin mainnet address prefix.
String? _addressType(String address) {
  if (address.startsWith('bc1q')) return 'p2wpkh';
  if (address.startsWith('bc1p')) return 'p2tr';
  if (address.startsWith('3')) return 'p2sh';
  if (address.startsWith('1')) return 'p2pkh';
  return null;
}

/// Returns true if [tx] matches coinjoin heuristics:
/// ≥5 inputs, ≥5 outputs, and ≥3 outputs share the exact same value.
bool _isCoinjoin(RawTransaction tx) {
  if (tx.inputCount < 5 || tx.outputs.length < 5) return false;
  final valueCounts = <int, int>{};
  for (final out in tx.outputs) {
    valueCounts[out.valueSats] = (valueCounts[out.valueSats] ?? 0) + 1;
  }
  return valueCounts.values.any((count) => count >= 3);
}

/// Returns true if [valueSats] looks like a round payment amount:
/// at least 100,000 sats (0.001 BTC) and divisible by 10,000 sats.
/// Round amounts are a heuristic that the UTXO may be a payment output
/// (as opposed to a change output), which aids chain analysis.
bool _isRoundAmount(int valueSats) =>
    valueSats >= 100_000 && valueSats % 10_000 == 0;

/// Analyses pre-fetched UTXO and transaction data and returns a
/// [ChainAnalysisResult] with per-UTXO flags and a privacy score.
ChainAnalysisResult analyse({
  required int walletCount,
  required Map<String, List<RawUtxo>> utxosByAddress,
  required Map<String, RawTransaction> txMap,
  required bool torEnabled,
  required bool customExplorerEnabled,
}) {
  // ── Flag computation ──────────────────────────────────────────────────────

  // Addresses with more than one UTXO are considered reused.
  final reusedAddresses = utxosByAddress.entries
      .where((e) => e.value.length > 1)
      .map((e) => e.key)
      .toSet();

  // Flatten to (address, utxo) pairs for uniform processing.
  final allPairs = [
    for (final entry in utxosByAddress.entries)
      for (final utxo in entry.value) (address: entry.key, utxo: utxo),
  ];

  // Determine the dominant address type to detect mixed-type UTXOs.
  final typeCounts = <String, int>{};
  for (final pair in allPairs) {
    final t = _addressType(pair.address);
    if (t != null) typeCounts[t] = (typeCounts[t] ?? 0) + 1;
  }
  final dominantType = typeCounts.isEmpty
      ? null
      : typeCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

  final analysed = <AnalysedUtxo>[];
  for (final pair in allPairs) {
    final flags = <UtxoRiskFlag>{};
    final addrType = _addressType(pair.address);

    if (reusedAddresses.contains(pair.address)) {
      flags.add(UtxoRiskFlag.addressReused);
    }
    if (pair.utxo.valueSats < 1000) {
      flags.add(UtxoRiskFlag.dust);
    }
    if (addrType != null && dominantType != null && addrType != dominantType) {
      flags.add(UtxoRiskFlag.mixedType);
    }
    if (_isRoundAmount(pair.utxo.valueSats)) {
      flags.add(UtxoRiskFlag.roundAmount);
    }

    final tx = txMap[pair.utxo.txid];
    analysed.add(AnalysedUtxo(
      raw: pair.utxo,
      address: pair.address,
      flags: flags,
      isCoinjoined: tx != null && _isCoinjoin(tx),
      addressType: addrType,
    ));
  }

  // ── Aggregate counts ──────────────────────────────────────────────────────

  final totalUtxos = analysed.length;
  final totalAddresses = utxosByAddress.length;
  final coinjoinedCount = analysed.where((u) => u.isCoinjoined).length;
  final dustCount =
      analysed.where((u) => u.flags.contains(UtxoRiskFlag.dust)).length;
  final roundAmountCount =
      analysed.where((u) => u.flags.contains(UtxoRiskFlag.roundAmount)).length;
  final hasMixedTypes =
      analysed.any((u) => u.flags.contains(UtxoRiskFlag.mixedType));

  // ── Component scoring ─────────────────────────────────────────────────────
  //
  // Each component is scored 0–100 and then scaled to its weight (max pts).
  // The five weighted scores sum directly to the final 0–100 score.

  // 1. Address hygiene (max 30):
  //    Proportion of addresses that have never been reused.
  //    Even one reused address in a large wallet is a minor hit; reusing half
  //    your addresses is a serious one.
  final reuseRatio =
      totalAddresses > 0 ? reusedAddresses.length / totalAddresses : 0.0;
  final hygienePoints = ((1.0 - reuseRatio) * 30).round().clamp(0, 30);

  // 2. Coinjoin coverage (max 25):
  //    Proportion of UTXOs that came from coinjoin transactions.
  //    A fully coinjoined UTXO set earns all 25 points. Partial mixing earns
  //    proportional credit — half mixed is better than none, and the score
  //    reflects that directly rather than treating coinjoin as a binary bonus.
  final coinjoinRatio =
      totalUtxos > 0 ? coinjoinedCount / totalUtxos : 0.0;
  final coinjoinPoints = (coinjoinRatio * 25).round().clamp(0, 25);

  // 3. UTXO cleanliness (max 20):
  //    Penalises dust UTXOs (−50% severity) and round amounts (−30% severity).
  //    Both are proportional so a single noisy UTXO in a large set is a minor
  //    deduction, not a flat −10.
  final dustRatio = totalUtxos > 0 ? dustCount / totalUtxos : 0.0;
  final roundRatio = totalUtxos > 0 ? roundAmountCount / totalUtxos : 0.0;
  final cleanlinessPoints =
      ((1.0 - dustRatio * 0.5 - roundRatio * 0.3).clamp(0.0, 1.0) * 20)
          .round();

  // 4. Address type consistency (max 10):
  //    Binary — mixed address types reveal spending history and wallet age.
  //    All-same type earns full 10 pts.
  final consistencyPoints = hasMixedTypes ? 0 : 10;

  // 5. Privacy infrastructure (max 15):
  //    Tor (10 pts) + custom/personal node (5 pts). These don't affect
  //    on-chain history but do protect query privacy during scanning.
  final infraPoints =
      (torEnabled ? 10 : 0) + (customExplorerEnabled ? 5 : 0);

  final score = (hygienePoints +
          coinjoinPoints +
          cleanlinessPoints +
          consistencyPoints +
          infraPoints)
      .clamp(0, 100);

  return ChainAnalysisResult(
    walletCount: walletCount,
    utxos: analysed,
    score: PrivacyScore(
      score: score,
      hygienePoints: hygienePoints,
      coinjoinPoints: coinjoinPoints,
      cleanlinessPoints: cleanlinessPoints,
      consistencyPoints: consistencyPoints,
      infraPoints: infraPoints,
      totalUtxos: totalUtxos,
      totalAddresses: totalAddresses,
      reusedAddressCount: reusedAddresses.length,
      dustCount: dustCount,
      coinjoinedCount: coinjoinedCount,
      roundAmountCount: roundAmountCount,
      hasMixedTypes: hasMixedTypes,
      torEnabled: torEnabled,
      customExplorerEnabled: customExplorerEnabled,
    ),
    fetchedAt: DateTime.now(),
  );
}
