import 'package:intl/intl.dart';

class CurrencyInfo {
  final String code;
  final String name;
  final String symbol;
  final int decimalDigits;

  /// Whether [symbol] reads as a unit after the number ("17.75 oz") rather
  /// than a sign before it ("\$17.75"). Only gold needs this.
  final bool symbolAfter;

  const CurrencyInfo({
    required this.code,
    required this.name,
    required this.symbol,
    this.decimalDigits = 2,
    this.symbolAfter = false,
  });

  /// Formatter for amounts in this currency. [decimalDigits] overrides the
  /// currency default (the card shows the spot price with 2 regardless).
  NumberFormat formatter({int? decimalDigits}) => NumberFormat.currency(
        locale: 'en_US',
        symbol: symbol,
        decimalDigits: decimalDigits ?? this.decimalDigits,
        // A non-breaking space keeps "17.75 oz" on one line when it wraps.
        customPattern: symbolAfter ? '#,##0.00\u00a0\u00a4' : null,
      );
}

/// Formatter for [code], falling back to the bare code as a prefix for
/// anything not in [supportedCurrencies]. Every place the app prints money
/// goes through here so gold's unit-suffix form is honoured everywhere.
NumberFormat currencyFormatter(String code, {int? decimalDigits}) {
  final info = supportedCurrencies[code.toLowerCase()];
  if (info != null) return info.formatter(decimalDigits: decimalDigits);
  return NumberFormat.currency(
    locale: 'en_US',
    symbol: code.toUpperCase(),
    decimalDigits: decimalDigits ?? 2,
  );
}

const Map<String, CurrencyInfo> supportedCurrencies = {
  'usd': CurrencyInfo(code: 'USD', name: 'US Dollar', symbol: '\$'),
  'eur': CurrencyInfo(code: 'EUR', name: 'Euro', symbol: '€'),
  'gbp': CurrencyInfo(code: 'GBP', name: 'British Pound', symbol: '£'),
  'jpy': CurrencyInfo(code: 'JPY', name: 'Japanese Yen', symbol: '¥', decimalDigits: 0),
  'cad': CurrencyInfo(code: 'CAD', name: 'Canadian Dollar', symbol: 'CA\$'),
  'aud': CurrencyInfo(code: 'AUD', name: 'Australian Dollar', symbol: 'A\$'),
  'chf': CurrencyInfo(code: 'CHF', name: 'Swiss Franc', symbol: 'Fr'),
  'inr': CurrencyInfo(code: 'INR', name: 'Indian Rupee', symbol: '₹'),
  'brl': CurrencyInfo(code: 'BRL', name: 'Brazilian Real', symbol: 'R\$'),
  'mxn': CurrencyInfo(code: 'MXN', name: 'Mexican Peso', symbol: 'MX\$'),
  'krw': CurrencyInfo(code: 'KRW', name: 'South Korean Won', symbol: '₩', decimalDigits: 0),
  'hkd': CurrencyInfo(code: 'HKD', name: 'Hong Kong Dollar', symbol: 'HK\$'),
  'sgd': CurrencyInfo(code: 'SGD', name: 'Singapore Dollar', symbol: 'S\$'),
  'nzd': CurrencyInfo(code: 'NZD', name: 'New Zealand Dollar', symbol: 'NZ\$'),
  'sek': CurrencyInfo(code: 'SEK', name: 'Swedish Krona', symbol: 'kr'),
  'nok': CurrencyInfo(code: 'NOK', name: 'Norwegian Krone', symbol: 'kr'),
  'dkk': CurrencyInfo(code: 'DKK', name: 'Danish Krone', symbol: 'kr'),
  'pln': CurrencyInfo(code: 'PLN', name: 'Polish Złoty', symbol: 'zł'),
  'czk': CurrencyInfo(code: 'CZK', name: 'Czech Koruna', symbol: 'Kč'),
  'huf': CurrencyInfo(code: 'HUF', name: 'Hungarian Forint', symbol: 'Ft', decimalDigits: 0),
  'try': CurrencyInfo(code: 'TRY', name: 'Turkish Lira', symbol: '₺'),
  'zar': CurrencyInfo(code: 'ZAR', name: 'South African Rand', symbol: 'R'),
  'aed': CurrencyInfo(code: 'AED', name: 'UAE Dirham', symbol: 'AED'),
  'sar': CurrencyInfo(code: 'SAR', name: 'Saudi Riyal', symbol: 'SR'),
  'myr': CurrencyInfo(code: 'MYR', name: 'Malaysian Ringgit', symbol: 'RM'),
  'idr': CurrencyInfo(code: 'IDR', name: 'Indonesian Rupiah', symbol: 'Rp', decimalDigits: 0),
  'php': CurrencyInfo(code: 'PHP', name: 'Philippine Peso', symbol: '₱'),
  'thb': CurrencyInfo(code: 'THB', name: 'Thai Baht', symbol: '฿'),
  'ils': CurrencyInfo(code: 'ILS', name: 'Israeli Shekel', symbol: '₪'),
  'rub': CurrencyInfo(code: 'RUB', name: 'Russian Ruble', symbol: '₽'),
  // BTC priced in troy ounces of gold. Sourced as BTC/USD ÷ PAXG/USD (Kraken),
  // with CoinGecko's xau quote as the fallback. A whole coin is ~18 oz, so
  // three decimals keep a small stack readable.
  'xau': CurrencyInfo(
    code: 'XAU',
    name: 'Gold (troy ounce)',
    symbol: 'oz',
    decimalDigits: 3,
    symbolAfter: true,
  ),
};
