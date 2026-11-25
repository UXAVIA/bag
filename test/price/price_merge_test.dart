/// Regression tests for GitHub issue #2 ("selected currencies don't display
/// consistently") and the gold derivation.
///
/// The cascade used to return whichever source answered first, verbatim. A
/// fallback with partial coverage (Bitfinex quotes four currencies) therefore
/// produced a PriceData missing the others, and the home screen hid their
/// cards. These pin the merge that now carries a missing currency over from
/// the cache and flags it, plus the pure helpers gold pricing relies on.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:bag/core/constants/supported_currencies.dart';
import 'package:bag/models/price_data.dart';
import 'package:bag/services/price_service.dart';
import 'package:bag/services/widget_service.dart';

void main() {
  group('mergeWithCache', () {
    final cached = PriceData(
      prices: const {'usd': 70000, 'chf': 60000, 'eur': 65000},
      changes24h: const {'usd': 1.5, 'chf': 1.2, 'eur': 1.1},
      fetchedAt: DateTime(2026, 4, 10, 6),
    );

    test('carries a currency the sources skipped and flags it stale', () {
      // Bitfinex-only answer: USD present, CHF absent — the exact shape the
      // reporter saw as "CHF + USD: only USD displays".
      final fresh = PriceData(
        prices: const {'usd': 77000},
        changes24h: const {'usd': 0.3},
        fetchedAt: DateTime(2026, 4, 10, 7),
      );

      final merged = mergeWithCache(fresh: fresh, cached: cached);

      expect(merged.priceFor('usd'), 77000);
      expect(merged.priceFor('chf'), 60000);
      expect(merged.isCarriedOver('chf'), isTrue);
      expect(merged.isCarriedOver('usd'), isFalse);
      expect(merged.fetchedAt, fresh.fetchedAt);
    });

    test('drops the cached 24 h change for a carried currency', () {
      final fresh = PriceData(
        prices: const {'usd': 77000},
        changes24h: const {'usd': 0.3},
        fetchedAt: DateTime(2026, 4, 10, 7),
      );
      final merged = mergeWithCache(fresh: fresh, cached: cached);
      // A stale price is still a price; a stale "24 h change" is just wrong.
      expect(merged.changeFor('chf'), isNull);
      expect(merged.changeFor('usd'), 0.3);
    });

    test('fresh values always win over cached ones', () {
      final fresh = PriceData(
        prices: const {'usd': 77000, 'chf': 61000, 'eur': 66000},
        changes24h: const {},
        fetchedAt: DateTime(2026, 4, 10, 7),
      );
      final merged = mergeWithCache(fresh: fresh, cached: cached);
      expect(merged.prices, fresh.prices);
      expect(merged.staleCurrencies, isEmpty);
    });

    test('is a no-op without a cache', () {
      final fresh = PriceData(
        prices: const {'usd': 77000},
        changes24h: const {},
        fetchedAt: DateTime(2026, 4, 10, 7),
      );
      expect(identical(mergeWithCache(fresh: fresh, cached: null), fresh), isTrue);
    });
  });

  group('PriceData JSON', () {
    test('round-trips staleCurrencies', () {
      final data = PriceData(
        prices: const {'usd': 1, 'chf': 2},
        changes24h: const {'usd': 0.1},
        fetchedAt: DateTime.utc(2026, 9, 12),
        staleCurrencies: const {'chf'},
      );
      final back = PriceData.fromJsonString(data.toJsonString());
      expect(back.staleCurrencies, {'chf'});
      expect(back.prices, data.prices);
    });

    test('reads cache entries written before staleCurrencies existed', () {
      final back = PriceData.fromJsonString(
        '{"prices":{"usd":1.0},"changes24h":{},"fetchedAt":"2026-09-12T00:00:00.000Z"}',
      );
      expect(back.staleCurrencies, isEmpty);
    });
  });

  group('divideSeries', () {
    test('joins on timestamp and drops candles missing from either side', () {
      final t0 = DateTime.utc(2026, 1, 1);
      final t1 = DateTime.utc(2026, 1, 8);
      final t2 = DateTime.utc(2026, 1, 15);
      final btcUsd = [(t0, 80000.0), (t1, 88000.0), (t2, 90000.0)];
      // PAXG's history starts one week later, like the real pair does.
      final paxgUsd = [(t1, 4400.0), (t2, 4500.0)];

      final btcInGold = divideSeries(btcUsd, paxgUsd);

      expect(btcInGold, [(t1, 20.0), (t2, 20.0)]);
    });

    test('skips a zero divisor rather than producing infinity', () {
      final t = DateTime.utc(2026, 1, 1);
      expect(divideSeries([(t, 1.0)], [(t, 0.0)]), isEmpty);
    });
  });

  group('divideAlignedTails', () {
    // Widget sparklines carry no timestamps, so the background isolate aligns
    // the two Kraken series from their shared most-recent candle instead.
    test('aligns from the end when one history is shorter', () {
      expect(
        divideAlignedTails([1, 80000, 88000, 90000], [4400, 4500]),
        [88000 / 4400, 90000 / 4500],
      );
    });

    test('skips zero divisors', () {
      expect(divideAlignedTails([1, 2], [0, 2]), [1.0]);
    });
  });

  group('currency formatting', () {
    test('gold reads as ounces after the number', () {
      expect(currencyFormatter('xau').format(17.7512), '17.751 oz');
      expect(currencyFormatter('xau', decimalDigits: 2).format(17.7512),
          '17.75 oz');
    });

    test('fiat keeps its sign in front', () {
      expect(currencyFormatter('usd').format(1234.5), r'$1,234.50');
      expect(currencyFormatter('jpy').format(1234.5), '¥1,235');
    });

    test('unknown codes fall back to the code itself', () {
      expect(currencyFormatter('xyz').format(1), 'XYZ1.00');
    });
  });
}
