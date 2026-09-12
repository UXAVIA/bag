import 'dart:convert';

// ── Raw Esplora shapes ────────────────────────────────────────────────────────

final class RawUtxo {
  final String txid;
  final int vout;
  final int valueSats;
  final int? blockHeight; // null = unconfirmed

  const RawUtxo({
    required this.txid,
    required this.vout,
    required this.valueSats,
    this.blockHeight,
  });
}

final class RawTxOutput {
  final String? address; // null = OP_RETURN etc.
  final int valueSats;
  final String scriptpubkeyType;

  const RawTxOutput({
    required this.address,
    required this.valueSats,
    required this.scriptpubkeyType,
  });
}

final class RawTransaction {
  final String txid;
  final int inputCount;
  final List<RawTxOutput> outputs;
  final int? blockHeight;

  const RawTransaction({
    required this.txid,
    required this.inputCount,
    required this.outputs,
    this.blockHeight,
  });
}

// ── Analysed types ────────────────────────────────────────────────────────────

enum UtxoRiskFlag { addressReused, dust, mixedType, roundAmount }

final class AnalysedUtxo {
  final RawUtxo raw;
  final String address;
  final Set<UtxoRiskFlag> flags;
  final bool isCoinjoined;
  final String? addressType; // "p2wpkh", "p2sh", "p2pkh", "p2tr"

  const AnalysedUtxo({
    required this.raw,
    required this.address,
    required this.flags,
    required this.isCoinjoined,
    this.addressType,
  });

  Map<String, dynamic> toJson() => {
        'txid': raw.txid,
        'vout': raw.vout,
        'valueSats': raw.valueSats,
        if (raw.blockHeight != null) 'blockHeight': raw.blockHeight,
        'address': address,
        'flags': flags.map((f) => f.name).toList(),
        'isCoinjoined': isCoinjoined,
        if (addressType != null) 'addressType': addressType,
      };

  factory AnalysedUtxo.fromJson(Map<String, dynamic> json) => AnalysedUtxo(
        raw: RawUtxo(
          txid: json['txid'] as String,
          vout: json['vout'] as int,
          valueSats: json['valueSats'] as int,
          blockHeight: json['blockHeight'] as int?,
        ),
        address: json['address'] as String,
        flags: (json['flags'] as List<dynamic>)
            .map((e) {
              try {
                return UtxoRiskFlag.values.byName(e as String);
              } catch (_) {
                return null;
              }
            })
            .whereType<UtxoRiskFlag>()
            .toSet(),
        isCoinjoined: json['isCoinjoined'] as bool,
        addressType: json['addressType'] as String?,
      );
}

// ── Privacy score ─────────────────────────────────────────────────────────────
//
// Score is computed as the sum of five weighted components (0–100 total).
// Each component contributes at most its maximum, and they sum exactly to
// [score]. This replaces the old flat-deduction-from-100 model.
//
// Component maxima:
//   hygienePoints     30  (address reuse — proportion-based)
//   coinjoinPoints    25  (coinjoin UTXO coverage — proportion-based)
//   cleanlinessPoints 20  (dust + round amounts — proportion-based)
//   consistencyPoints 10  (address type consistency — binary)
//   infraPoints       15  (Tor + custom node)
//   ─────────────────────
//   Total             100

final class PrivacyScore {
  final int score; // 0–100

  // ── Component earned scores (sum to [score]) ──
  final int hygienePoints;     // 0–30
  final int coinjoinPoints;    // 0–25
  final int cleanlinessPoints; // 0–20
  final int consistencyPoints; // 0–10
  final int infraPoints;       // 0–15

  // ── Diagnostic counts (used for detail text in the UI) ──
  final int totalUtxos;
  final int totalAddresses;
  final int reusedAddressCount;
  final int dustCount;
  final int coinjoinedCount;
  final int roundAmountCount;
  final bool hasMixedTypes;
  final bool torEnabled;
  final bool customExplorerEnabled;

  const PrivacyScore({
    required this.score,
    required this.hygienePoints,
    required this.coinjoinPoints,
    required this.cleanlinessPoints,
    required this.consistencyPoints,
    required this.infraPoints,
    required this.totalUtxos,
    required this.totalAddresses,
    required this.reusedAddressCount,
    required this.dustCount,
    required this.coinjoinedCount,
    required this.roundAmountCount,
    required this.hasMixedTypes,
    required this.torEnabled,
    required this.customExplorerEnabled,
  });

  Map<String, dynamic> toJson() => {
        'score': score,
        'hygienePoints': hygienePoints,
        'coinjoinPoints': coinjoinPoints,
        'cleanlinessPoints': cleanlinessPoints,
        'consistencyPoints': consistencyPoints,
        'infraPoints': infraPoints,
        'totalUtxos': totalUtxos,
        'totalAddresses': totalAddresses,
        'reusedAddressCount': reusedAddressCount,
        'dustCount': dustCount,
        'coinjoinedCount': coinjoinedCount,
        'roundAmountCount': roundAmountCount,
        'hasMixedTypes': hasMixedTypes,
        'torEnabled': torEnabled,
        'customExplorerEnabled': customExplorerEnabled,
      };

  factory PrivacyScore.fromJson(Map<String, dynamic> json) => PrivacyScore(
        score: json['score'] as int,
        hygienePoints: json['hygienePoints'] as int,
        coinjoinPoints: json['coinjoinPoints'] as int,
        cleanlinessPoints: json['cleanlinessPoints'] as int,
        consistencyPoints: json['consistencyPoints'] as int,
        infraPoints: json['infraPoints'] as int,
        totalUtxos: json['totalUtxos'] as int,
        totalAddresses: json['totalAddresses'] as int,
        reusedAddressCount: json['reusedAddressCount'] as int,
        dustCount: json['dustCount'] as int,
        coinjoinedCount: json['coinjoinedCount'] as int,
        roundAmountCount: json['roundAmountCount'] as int,
        hasMixedTypes: json['hasMixedTypes'] as bool,
        torEnabled: json['torEnabled'] as bool,
        customExplorerEnabled: json['customExplorerEnabled'] as bool,
      );
}

final class ChainAnalysisResult {
  final int walletCount; // number of wallets analysed
  final List<AnalysedUtxo> utxos;
  final PrivacyScore score;
  final DateTime fetchedAt;

  const ChainAnalysisResult({
    required this.walletCount,
    required this.utxos,
    required this.score,
    required this.fetchedAt,
  });

  bool get isStale =>
      DateTime.now().difference(fetchedAt) > const Duration(minutes: 30);

  Map<String, dynamic> toJson() => {
        'walletCount': walletCount,
        'utxos': utxos.map((u) => u.toJson()).toList(),
        'score': score.toJson(),
        'fetchedAt': fetchedAt.millisecondsSinceEpoch,
      };

  factory ChainAnalysisResult.fromJson(Map<String, dynamic> json) =>
      ChainAnalysisResult(
        walletCount: json['walletCount'] as int? ?? 1,
        utxos: (json['utxos'] as List<dynamic>)
            .map((e) => AnalysedUtxo.fromJson(e as Map<String, dynamic>))
            .toList(),
        score: PrivacyScore.fromJson(json['score'] as Map<String, dynamic>),
        fetchedAt:
            DateTime.fromMillisecondsSinceEpoch(json['fetchedAt'] as int),
      );

  String toJsonString() => jsonEncode(toJson());

  factory ChainAnalysisResult.fromJsonString(String raw) =>
      ChainAnalysisResult.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
