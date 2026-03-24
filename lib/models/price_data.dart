import 'dart:convert';

class PriceData {
  final Map<String, double> prices;
  final Map<String, double> changes24h;
  final DateTime fetchedAt;

  const PriceData({
    required this.prices,
    required this.changes24h,
    required this.fetchedAt,
  });

  double? priceFor(String currency) => prices[currency.toLowerCase()];
  double? changeFor(String currency) => changes24h[currency.toLowerCase()];

  bool get isStale => DateTime.now().difference(fetchedAt).inMinutes > 10;

  Map<String, dynamic> toJson() => {
        'prices': prices,
        'changes24h': changes24h,
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  factory PriceData.fromJson(Map<String, dynamic> json) => PriceData(
        prices: Map<String, double>.from(json['prices'] as Map),
        changes24h: Map<String, double>.from(
          (json['changes24h'] as Map?) ?? {},
        ),
        fetchedAt: DateTime.parse(json['fetchedAt'] as String),
      );

  String toJsonString() => jsonEncode(toJson());

  factory PriceData.fromJsonString(String s) =>
      PriceData.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
