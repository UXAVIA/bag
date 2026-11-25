import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';

const int satsPerBtc = 100000000;

/// Icon that shows ₿ in BTC mode and the sat symbol in sats mode.
///
/// The sat symbol is Bag's own drawing ([SatsSymbolPainter]), so no font
/// ships for it. It reads as "sats" to a screen reader and scales with the
/// text scale, as the text next to it does.
class BtcUnitIcon extends StatelessWidget {
  final bool satsMode;
  final double size;
  final Color color;

  const BtcUnitIcon({
    super.key,
    required this.satsMode,
    required this.color,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) {
    if (!satsMode) {
      return Icon(Icons.currency_bitcoin, size: size, color: color);
    }
    // Mirror the layout Flutter's Icon widget uses: explicit SizedBox + Center
    // so the glyph sits in the same position as Icons.currency_bitcoin when
    // used as a TextField prefixIcon or anywhere else Icons are expected. The
    // box grows with the text scale, which the WidgetSpan applies to the
    // glyph, so a large text setting can't clip it.
    final box = MediaQuery.textScalerOf(context).scale(size);
    return SizedBox(
      width: box,
      height: box,
      child: Center(
        child: Text.rich(
          satsSymbolSpan(fontSize: size, color: color),
          style: TextStyle(fontSize: size, height: 1),
        ),
      ),
    );
  }
}

/// The sat symbol inline in text: it sits on the line's baseline at
/// [fontSize] in [color] (pass the surrounding text's), and scales with the
/// text scale like the text around it.
WidgetSpan satsSymbolSpan({required double fontSize, required Color color}) =>
    WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: Semantics(
        label: 'sats',
        child: _GlyphBaseline(
          child: CustomPaint(
            size: Size(fontSize * SatsSymbolPainter.aspect, fontSize),
            painter: SatsSymbolPainter(color: color),
          ),
        ),
      ),
    );

/// The sat symbol: a vertical stroke crossed by three horizontal bars, drawn
/// as plain rectangles in an em box (height = the font size). The bars span
/// the cap height and the stroke runs past them at both ends, crossing the
/// baseline the way a dollar sign's does.
class SatsSymbolPainter extends CustomPainter {
  final Color color;

  const SatsSymbolPainter({required this.color});

  /// Width of the em box, as a fraction of its height.
  static const double aspect = 0.6;

  /// Where the baseline is, from the top, as a fraction of the height.
  static const double baseline = 0.8;

  static const double _stroke = 0.09;
  static const double _barWidth = 0.52;
  static const List<double> _barCentres = [0.22, 0.45, 0.68];
  static const double _stemTop = 0.08;
  static const double _stemBottom = 0.88;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final stroke = h * _stroke;
    final paint = Paint()..color = color;
    final barWidth = h * _barWidth;
    final left = (size.width - barWidth) / 2;
    for (final centre in _barCentres) {
      canvas.drawRect(
          Rect.fromLTWH(left, h * centre - stroke / 2, barWidth, stroke),
          paint);
    }
    canvas.drawRect(
        Rect.fromLTWH((size.width - stroke) / 2, h * _stemTop, stroke,
            h * (_stemBottom - _stemTop)),
        paint);
  }

  @override
  bool shouldRepaint(SatsSymbolPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Reports the em box's baseline ([SatsSymbolPainter.baseline] of its
/// height), so a baseline-aligned WidgetSpan puts the symbol on the line's
/// baseline rather than standing it on it.
class _GlyphBaseline extends SingleChildRenderObjectWidget {
  const _GlyphBaseline({required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderGlyphBaseline();
}

class _RenderGlyphBaseline extends RenderProxyBox {
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      size.height * SatsSymbolPainter.baseline;

  @override
  double? computeDryBaseline(
          BoxConstraints constraints, TextBaseline baseline) =>
      getDryLayout(constraints).height * SatsSymbolPainter.baseline;
}

final _satsFormatter = NumberFormat('#,##0');

/// Formats a BTC amount for display.
/// - BTC mode:  "0.00123456 BTC"
/// - Sats mode: "123,456 sats"
String formatBtcAmount(double btc, {required bool satsMode}) {
  if (satsMode) {
    return '${_satsFormatter.format((btc * satsPerBtc).round())} sats';
  }
  final s = btc.toStringAsFixed(8);
  return '${s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')} BTC';
}

/// Just the unit label — "BTC" or "sats".
String btcUnit(bool satsMode) => satsMode ? 'sats' : 'BTC';

/// Formats a BTC amount as a bare editable string (no unit).
/// - BTC mode:  up to 8 decimal places, trailing zeros stripped
/// - Sats mode: whole integer
String btcToFieldString(double btc, {required bool satsMode}) {
  if (satsMode) return (btc * satsPerBtc).round().toString();
  final s = btc.toStringAsFixed(8);
  return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}

/// Parses a user-entered string to a BTC double.
/// In sats mode the input is whole sats; in BTC mode it's a decimal BTC value.
/// Returns null if the string is not a valid positive number.
double? parseBtcInput(String text, {required bool satsMode}) {
  final v = double.tryParse(text.trim());
  if (v == null || v < 0) return null;
  return satsMode ? v / satsPerBtc : v;
}
