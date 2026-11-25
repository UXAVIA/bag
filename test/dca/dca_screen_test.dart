/// GitHub issue #8: purchases can be edited after the fact and each tile
/// shows how that one purchase is doing.
///
/// The notifier is swapped for an in-memory one so no Hive box is needed;
/// the screen is otherwise the real thing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/features/dca/presentation/dca_screen.dart';
import 'package:bag/models/dca_entry.dart';
import 'package:bag/models/price_data.dart';
import 'package:bag/providers/dca_provider.dart';
import 'package:bag/providers/price_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';

final _entry = DcaEntry(
  id: 'e1',
  btcAmount: 0.02,
  pricePerBtc: 50000,
  currency: 'usd',
  date: DateTime(2024, 3, 18),
  note: 'Pre-halving buy',
);

class _MemoryDcaNotifier extends DcaNotifier {
  @override
  List<DcaEntry> build() => [_entry];

  @override
  Future<void> updateEntry({
    required String id,
    required double btcAmount,
    required double pricePerBtc,
    required String currency,
    required DateTime date,
    String? note,
  }) async {
    state = [
      for (final e in state)
        if (e.id == id)
          DcaEntry(
            id: id,
            btcAmount: btcAmount,
            pricePerBtc: pricePerBtc,
            currency: currency,
            date: date,
            note: note?.trim().isEmpty == true ? null : note?.trim(),
          )
        else
          e,
    ];
  }
}

class _FixedPriceNotifier extends PriceNotifier {
  @override
  Future<PriceData> build() async => PriceData(
        prices: const {'usd': 80000},
        changes24h: const {},
        fetchedAt: DateTime.now(),
      );
}

class _NoPriceNotifier extends PriceNotifier {
  @override
  Future<PriceData> build() async => PriceData(
        prices: const {'eur': 70000}, // USD unquoted
        changes24h: const {},
        fetchedAt: DateTime.now(),
      );
}

void main() {
  Future<void> pump(WidgetTester tester, {bool priced = true}) async {
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues({
      AppConstants.keySelectedCurrencies: ['usd'],
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          dcaProvider.overrideWith(_MemoryDcaNotifier.new),
          priceProvider.overrideWith(
            priced ? _FixedPriceNotifier.new : _NoPriceNotifier.new,
          ),
        ],
        child: const MaterialApp(home: DcaScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('each purchase shows its own value and P&L', (tester) async {
    await pump(tester);
    expect(find.text('Value \$1,600.00'), findsOneWidget);
    expect(find.text('+\$600.00 · +60.00%'), findsOneWidget);
  });

  testWidgets('no quote in the entry currency hides the row', (tester) async {
    await pump(tester, priced: false);
    expect(find.textContaining('Value '), findsNothing);
    // The purchase itself is still listed.
    expect(find.text('@ \$50,000.00'), findsOneWidget);
  });

  testWidgets('tapping a purchase opens it pre-filled and saves changes',
      (tester) async {
    await pump(tester);

    await tester.tap(find.text('Pre-halving buy'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Purchase'), findsOneWidget);
    // Pre-filled from the entry, not from a historical-price fetch.
    expect(find.widgetWithText(TextField, '0.02'), findsOneWidget);
    expect(find.widgetWithText(TextField, '50000'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Pre-halving buy'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '50000'), '45000');
    await tester.enterText(
        find.widgetWithText(TextField, 'Pre-halving buy'), '');
    await tester.tap(find.text('Save Changes'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Purchase'), findsNothing);
    expect(find.text('@ \$45,000.00'), findsOneWidget);
    expect(find.text('Pre-halving buy'), findsNothing); // note cleared
    // Same entry (same id), so still exactly one tile.
    expect(find.textContaining('@ \$'), findsOneWidget);
    // P&L recomputed against the corrected cost basis (0.02 × 45,000 = 900).
    expect(find.text('+\$700.00 · +77.78%'), findsOneWidget);
  });
}
