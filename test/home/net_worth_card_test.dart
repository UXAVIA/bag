/// GitHub issue #2: a selected currency that no price source quoted used to
/// render as nothing at all, so the card list silently shrank. The card now
/// always renders, and says why the figure is missing or old.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bag/models/portfolio.dart';
import 'package:bag/models/price_data.dart';
import 'package:bag/widgets/net_worth_card.dart';

void main() {
  const portfolio = Portfolio(btcAmount: 0.5, selectedCurrencies: ['chf']);

  Future<void> pump(WidgetTester tester, PriceData priceData) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NetWorthCard(
          currencyCode: 'chf',
          portfolio: portfolio,
          priceData: priceData,
        ),
      ),
    ));
  }

  testWidgets('a currency with no quote still gets its card', (tester) async {
    await pump(
      tester,
      PriceData(
        prices: const {'usd': 77000}, // CHF missing, as a Bitfinex-only answer is
        changes24h: const {},
        fetchedAt: DateTime.now(),
      ),
    );
    expect(find.text('CHF'), findsOneWidget);
    expect(find.text('Price unavailable'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('a carried-over quote is labelled cached', (tester) async {
    await pump(
      tester,
      PriceData(
        prices: const {'usd': 77000, 'chf': 60000},
        changes24h: const {'usd': 1.0},
        fetchedAt: DateTime.now(),
        staleCurrencies: const {'chf'},
      ),
    );
    expect(find.text('BTC Fr60,000.00 · cached'), findsOneWidget);
    expect(find.text('Fr30,000.00'), findsOneWidget);
    // No change chip: the cached 24 h change was dropped, not carried.
    expect(find.textContaining('24h'), findsNothing);
  });

  testWidgets('a fresh quote renders as before', (tester) async {
    await pump(
      tester,
      PriceData(
        prices: const {'chf': 60000},
        changes24h: const {'chf': 2.5},
        fetchedAt: DateTime.now(),
      ),
    );
    expect(find.text('BTC Fr60,000.00'), findsOneWidget);
    expect(find.text('+2.50% · 24h'), findsOneWidget);
  });

  testWidgets('gold formats as ounces', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NetWorthCard(
          currencyCode: 'xau',
          portfolio: portfolio,
          priceData: PriceData(
            prices: const {'xau': 17.75},
            changes24h: const {},
            fetchedAt: DateTime.now(),
          ),
        ),
      ),
    ));
    expect(find.text('XAU'), findsOneWidget);
    expect(find.text('8.875 oz'), findsOneWidget);
    expect(find.text('BTC 17.75 oz'), findsOneWidget);
  });
}
