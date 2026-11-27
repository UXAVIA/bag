import 'package:bag/models/portfolio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('primaryCurrency is the first selected currency', () {
    const p = Portfolio(btcAmount: 0, selectedCurrencies: ['eur', 'usd']);
    expect(p.primaryCurrency, 'eur');
  });

  test('primaryCurrency falls back to usd when none is selected', () {
    const p = Portfolio(btcAmount: 0, selectedCurrencies: []);
    expect(p.primaryCurrency, 'usd');
  });
}
