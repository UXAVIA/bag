import 'dart:convert';

class DcaEntry {
  final String id;
  final double btcAmount;
  final double pricePerBtc;
  final String currency;
  final DateTime date;
  final String? note;

  const DcaEntry({
    required this.id,
    required this.btcAmount,
    required this.pricePerBtc,
    required this.currency,
    required this.date,
    this.note,
  });

  double get totalCost => btcAmount * pricePerBtc;

  DcaEntry copyWith({
    double? btcAmount,
    double? pricePerBtc,
    String? currency,
    DateTime? date,
    String? note,
  }) =>
      DcaEntry(
        id: id,
        btcAmount: btcAmount ?? this.btcAmount,
        pricePerBtc: pricePerBtc ?? this.pricePerBtc,
        currency: currency ?? this.currency,
        date: date ?? this.date,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'btcAmount': btcAmount,
        'pricePerBtc': pricePerBtc,
        'currency': currency,
        'date': date.toIso8601String(),
        if (note != null) 'note': note,
      };

  factory DcaEntry.fromJson(Map<String, dynamic> json) => DcaEntry(
        id: json['id'] as String,
        btcAmount: (json['btcAmount'] as num).toDouble(),
        pricePerBtc: (json['pricePerBtc'] as num).toDouble(),
        currency: json['currency'] as String,
        date: DateTime.parse(json['date'] as String),
        note: json['note'] as String?,
      );

  String toJsonString() => jsonEncode(toJson());

  factory DcaEntry.fromJsonString(String s) =>
      DcaEntry.fromJson(jsonDecode(s) as Map<String, dynamic>);
}

/// Computed stats derived from a list of DcaEntry records.
class DcaStats {
  final double totalBtc;
  final double totalCostBasis;
  final double avgBuyPrice;
  final String currency;

  // Populated when current price is available
  final double? currentPrice;
  final double? currentValue;
  final double? pnl;
  final double? pnlPercent;

  const DcaStats({
    required this.totalBtc,
    required this.totalCostBasis,
    required this.avgBuyPrice,
    required this.currency,
    this.currentPrice,
    this.currentValue,
    this.pnl,
    this.pnlPercent,
  });

  bool get hasPriceData => pnl != null;
  bool get isProfit => (pnl ?? 0) >= 0;

  /// Computes stats for [entries] expressed in [viewCurrency].
  ///
  /// When an entry's currency differs from [viewCurrency], its cost basis is
  /// converted using the ratio of current BTC prices
  /// (entryValue_view = entryCost * btcPrice_view / btcPrice_entryCurrency).
  /// If [currentPrices] is null or a required currency is missing, the raw
  /// cost is used as a best-effort fallback.
  factory DcaStats.fromEntries(
    List<DcaEntry> entries, {
    required String viewCurrency,
    Map<String, double>? currentPrices,
  }) {
    if (entries.isEmpty) {
      return DcaStats(
        totalBtc: 0,
        totalCostBasis: 0,
        avgBuyPrice: 0,
        currency: viewCurrency,
      );
    }

    final totalBtc = entries.fold(0.0, (sum, e) => sum + e.btcAmount);

    // Convert all entry costs to viewCurrency via BTC price ratio.
    double totalCostInView = 0;
    for (final e in entries) {
      if (e.currency == viewCurrency) {
        totalCostInView += e.totalCost;
      } else {
        final viewPrice = currentPrices?[viewCurrency];
        final entryPrice = currentPrices?[e.currency];
        if (viewPrice != null && entryPrice != null && entryPrice > 0) {
          totalCostInView += e.totalCost * (viewPrice / entryPrice);
        } else {
          totalCostInView += e.totalCost; // best-effort fallback
        }
      }
    }

    final avgBuyPrice = totalBtc > 0 ? totalCostInView / totalBtc : 0.0;
    final currentPrice = currentPrices?[viewCurrency];

    double? currentValue;
    double? pnl;
    double? pnlPercent;

    if (currentPrice != null && totalCostInView > 0) {
      currentValue = totalBtc * currentPrice;
      pnl = currentValue - totalCostInView;
      pnlPercent = (pnl / totalCostInView) * 100;
    }

    return DcaStats(
      totalBtc: totalBtc,
      totalCostBasis: totalCostInView,
      avgBuyPrice: avgBuyPrice,
      currency: viewCurrency,
      currentPrice: currentPrice,
      currentValue: currentValue,
      pnl: pnl,
      pnlPercent: pnlPercent,
    );
  }
}
