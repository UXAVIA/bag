import 'dart:convert';

class PriceAlert {
  final String id;
  final double targetPrice;
  final String currency;
  final bool above; // true = fire when price rises above target
  final bool fired;

  const PriceAlert({
    required this.id,
    required this.targetPrice,
    required this.currency,
    required this.above,
    this.fired = false,
  });

  bool shouldFire(double currentPrice) =>
      !fired && (above ? currentPrice >= targetPrice : currentPrice <= targetPrice);

  PriceAlert copyWith({bool? fired}) => PriceAlert(
        id: id,
        targetPrice: targetPrice,
        currency: currency,
        above: above,
        fired: fired ?? this.fired,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'targetPrice': targetPrice,
        'currency': currency,
        'above': above,
        'fired': fired,
      };

  factory PriceAlert.fromJson(Map<String, dynamic> json) => PriceAlert(
        id: json['id'] as String,
        targetPrice: (json['targetPrice'] as num).toDouble(),
        currency: json['currency'] as String,
        above: json['above'] as bool,
        fired: json['fired'] as bool? ?? false,
      );

  static List<PriceAlert> listFromJsonString(String s) {
    final list = jsonDecode(s) as List<dynamic>;
    return list.map((e) => PriceAlert.fromJson(e as Map<String, dynamic>)).toList();
  }

  static String listToJsonString(List<PriceAlert> alerts) =>
      jsonEncode(alerts.map((a) => a.toJson()).toList());
}
