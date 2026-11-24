class Portfolio {
  final double btcAmount;
  final List<String> selectedCurrencies;

  const Portfolio({
    required this.btcAmount,
    required this.selectedCurrencies,
  });

  double netWorthIn(String currency, double btcPrice) => btcAmount * btcPrice;

  bool get hasAmount => btcAmount > 0;

  /// The first selected currency, or `usd` when none is selected.
  String get primaryCurrency =>
      selectedCurrencies.isNotEmpty ? selectedCurrencies.first : 'usd';

  Portfolio copyWith({
    double? btcAmount,
    List<String>? selectedCurrencies,
  }) =>
      Portfolio(
        btcAmount: btcAmount ?? this.btcAmount,
        selectedCurrencies: selectedCurrencies ?? this.selectedCurrencies,
      );
}
