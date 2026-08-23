import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

const int satsPerBtc = 100000000;

/// Icon that shows ₿ in BTC mode and the Satoshi Symbol in sats mode.
///
/// The sat glyph uses the SatoshiSymbol font (satsymbol.com), a community
/// design by the Bitcoin Design Community (CC BY-NC 4.0).
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
    // used as a TextField prefixIcon or anywhere else Icons are expected.
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Text(
          'S',
          style: TextStyle(
            fontFamily: 'SatoshiSymbol',
            fontSize: size,
            color: color,
            height: 1,
          ),
        ),
      ),
    );
  }
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
