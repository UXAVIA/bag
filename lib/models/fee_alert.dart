import 'dart:convert';

class FeeAlert {
  final String id;
  final double targetRate; // sat/vB
  final bool above; // true = fire when fee rises above target
  final bool fired;

  const FeeAlert({
    required this.id,
    required this.targetRate,
    required this.above,
    this.fired = false,
  });

  /// Returns true if this alert should fire given [currentRate].
  bool shouldFire(double currentRate) =>
      !fired && (above ? currentRate >= targetRate : currentRate <= targetRate);

  FeeAlert copyWith({bool? fired}) => FeeAlert(
        id: id,
        targetRate: targetRate,
        above: above,
        fired: fired ?? this.fired,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'targetRate': targetRate,
        'above': above,
        'fired': fired,
      };

  factory FeeAlert.fromJson(Map<String, dynamic> json) => FeeAlert(
        id: json['id'] as String,
        targetRate: (json['targetRate'] as num).toDouble(),
        above: json['above'] as bool,
        fired: json['fired'] as bool? ?? false,
      );

  static List<FeeAlert> listFromJsonString(String s) {
    final list = jsonDecode(s) as List<dynamic>;
    return list
        .map((e) => FeeAlert.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static String listToJsonString(List<FeeAlert> alerts) =>
      jsonEncode(alerts.map((a) => a.toJson()).toList());
}
