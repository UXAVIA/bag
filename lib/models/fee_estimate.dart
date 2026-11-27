import 'dart:convert';

/// Current mempool fee estimates from mempool.space/api/v1/fees/recommended.
/// All rates are in sat/vB.
class FeeEstimate {
  final double fast;     // fastestFee — next block (~10 min)
  final double standard; // halfHourFee (~30 min)
  final double slow;     // hourFee (~1 hour)
  final DateTime fetchedAt;

  const FeeEstimate({
    required this.fast,
    required this.standard,
    required this.slow,
    required this.fetchedAt,
  });

  bool get isStale =>
      DateTime.now().difference(fetchedAt).inMinutes >= 5;

  Map<String, dynamic> toJson() => {
        'fast': fast,
        'standard': standard,
        'slow': slow,
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  factory FeeEstimate.fromJson(Map<String, dynamic> json) => FeeEstimate(
        fast: (json['fast'] as num).toDouble(),
        standard: (json['standard'] as num).toDouble(),
        slow: (json['slow'] as num).toDouble(),
        fetchedAt: DateTime.parse(json['fetchedAt'] as String),
      );

  String toJsonString() => jsonEncode(toJson());

  static FeeEstimate? fromJsonStringOrNull(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return FeeEstimate.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
