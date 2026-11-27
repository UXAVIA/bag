import 'dart:io';

import 'package:bag/core/utils/btc_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The sat symbol is Bag's own drawing (plain geometry), not a font glyph:
// the SatoshiSymbol font it replaced was licensed for non-commercial use only.

const _orange = Color(0xFFF7931A);
const _white = Color(0xFFFFFFFF);

Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: Center(child: child)),
  ),
);

Finder get _glyph => find.byWidgetPredicate(
  (w) => w is CustomPaint && w.painter is SatsSymbolPainter,
);

void main() {
  testWidgets('sats mode draws the symbol and uses no font', (tester) async {
    await tester.pumpWidget(
      _host(const BtcUnitIcon(satsMode: true, color: _orange, size: 20)),
    );
    expect(_glyph, findsOneWidget);
    final fonts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.style?.fontFamily)
        .whereType<String>();
    expect(fonts, isEmpty);
  });

  testWidgets('it reads as "sats" to a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(const BtcUnitIcon(satsMode: true, color: _orange, size: 20)),
    );
    expect(find.bySemanticsLabel('sats'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('BTC mode is still the bitcoin icon', (tester) async {
    await tester.pumpWidget(
      _host(const BtcUnitIcon(satsMode: false, color: _orange, size: 20)),
    );
    expect(find.byIcon(Icons.currency_bitcoin), findsOneWidget);
    expect(_glyph, findsNothing);
  });

  test('the symbol is a vertical stroke crossed by three bars, in the '
      'colour given (light or dark)', () {
    for (final color in [_orange, _white, Colors.black]) {
      const size = Size(12, 20);
      expect(
        (Canvas canvas) => SatsSymbolPainter(color: color).paint(canvas, size),
        paints
          ..rect(color: color)
          ..rect(color: color)
          ..rect(color: color)
          ..rect(color: color),
      );
    }
  });

  testWidgets('it scales with the text scale', (tester) async {
    await tester.pumpWidget(
      _host(
        const BtcUnitIcon(satsMode: true, color: _orange, size: 20),
        textScale: 2,
      ),
    );
    expect(tester.getSize(find.byType(BtcUnitIcon)), const Size(40, 40));
    final glyph = tester.getRect(_glyph);
    expect(glyph.height, moreOrLessEquals(40, epsilon: 0.01));
    expect(glyph.width, moreOrLessEquals(24, epsilon: 0.01));
  });

  testWidgets('inline, it sits on the text baseline at the text size', (
    tester,
  ) async {
    const fontSize = 24.0;
    const lineBaseline = 50.0;
    // Baseline puts the text's alphabetic baseline at a known height.
    await tester.pumpWidget(
      _host(
        Baseline(
          baseline: lineBaseline,
          baselineType: TextBaseline.alphabetic,
          child: Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: '21 '),
                satsSymbolSpan(fontSize: fontSize, color: _orange),
              ],
            ),
            style: const TextStyle(fontSize: fontSize),
          ),
        ),
      ),
    );
    final top = tester.getTopLeft(find.byType(Baseline)).dy;
    final glyph = tester.getRect(_glyph);
    expect(glyph.height, moreOrLessEquals(fontSize, epsilon: 0.01));
    expect(
      glyph.top + glyph.height * SatsSymbolPainter.baseline,
      moreOrLessEquals(top + lineBaseline, epsilon: 0.5),
    );
  });

  test('no font ships with the app', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, isNot(contains('fonts:')));
    expect(pubspec, isNot(contains('SatoshiSymbol')));
    expect(File('assets/fonts/satoshi_symbol.ttf').existsSync(), isFalse);
  });
}
