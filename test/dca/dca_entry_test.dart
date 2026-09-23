/// GitHub issue #8: per-purchase performance. Each entry is measured against
/// today's price in the currency it was bought in — no cross-currency
/// conversion, unlike the summary card.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:bag/models/dca_entry.dart';

void main() {
  final entry = DcaEntry(
    id: 'e1',
    btcAmount: 0.02,
    pricePerBtc: 50000,
    currency: 'usd',
    date: DateTime(2024, 3, 18),
  );

  test('profit: value, absolute P&L and % all derive from the entry price',
      () {
    final perf = entry.performanceAt(80000)!;
    expect(perf.currentValue, closeTo(1600, 1e-9));
    expect(perf.pnl, closeTo(600, 1e-9)); // paid 1000
    expect(perf.pnlPercent, closeTo(60, 1e-9));
    expect(perf.isProfit, isTrue);
  });

  test('loss is signed negative', () {
    final perf = entry.performanceAt(40000)!;
    expect(perf.pnl, closeTo(-200, 1e-9));
    expect(perf.pnlPercent, closeTo(-20, 1e-9));
    expect(perf.isProfit, isFalse);
  });

  test('break-even counts as profit (matches DcaStats.isProfit)', () {
    expect(entry.performanceAt(50000)!.isProfit, isTrue);
  });

  test('no quote for the entry currency means no figure, not a zero', () {
    expect(entry.performanceAt(null), isNull);
  });

  test('a zero entry price cannot produce an infinite percentage', () {
    final free = entry.copyWith(pricePerBtc: 0);
    expect(free.performanceAt(80000), isNull);
  });
}
