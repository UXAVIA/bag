import 'dart:convert';

class PriceData {
  final Map<String, double> prices;
  final Map<String, double> changes24h;
  final DateTime fetchedAt;

  /// Currencies whose price was carried over from the previous cache because
  /// no source quoted them this fetch. The figure is real but older than
  /// [fetchedAt]; the UI marks it rather than hiding the card, which is what
  /// used to happen and read as "my currency disappeared".
  final Set<String> staleCurrencies;

  const PriceData({
    required this.prices,
    required this.changes24h,
    required this.fetchedAt,
    this.staleCurrencies = const {},
  });

  double? priceFor(String currency) => prices[currency.toLowerCase()];
  double? changeFor(String currency) => changes24h[currency.toLowerCase()];

  bool get isStale => DateTime.now().difference(fetchedAt).inMinutes > 10;

  bool isCarriedOver(String currency) =>
      staleCurrencies.contains(currency.toLowerCase());

  // [fetchedAt] is stored as UTC and read back as local time. A local time
  // with no offset, as it was stored before, lands in the future after a
  // westward time-zone change: the cache then never looked stale, and the
  // widget took a refused request's cached data for fetched ones. An entry
  // stored that way still parses as local, exactly as it did.
  Map<String, dynamic> toJson() => {
        'prices': prices,
        'changes24h': changes24h,
        'fetchedAt': fetchedAt.toUtc().toIso8601String(),
        if (staleCurrencies.isNotEmpty)
          'staleCurrencies': staleCurrencies.toList(),
      };

  factory PriceData.fromJson(Map<String, dynamic> json) => PriceData(
        prices: Map<String, double>.from(json['prices'] as Map),
        changes24h: Map<String, double>.from(
          (json['changes24h'] as Map?) ?? {},
        ),
        fetchedAt: DateTime.parse(json['fetchedAt'] as String).toLocal(),
        staleCurrencies: {
          for (final c in (json['staleCurrencies'] as List?) ?? const [])
            c as String,
        },
      );

  String toJsonString() => jsonEncode(toJson());

  factory PriceData.fromJsonString(String s) =>
      PriceData.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
