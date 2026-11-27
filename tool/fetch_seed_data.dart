// ignore_for_file: avoid_print
/// Fetches historical BTC price data from Kraken and writes it to assets/seed/
/// so every app install ships with pre-populated chart cache.
///
/// Run before building a release APK:
/// ```
///   dart run tool/fetch_seed_data.dart
/// ```
/// Or use the release build script which does both:
/// ```
///   ./scripts/build_release.sh
/// ```
/// What gets fetched (7 Kraken requests total — no API key, no rate limiting):
///   - Kraken weekly OHLC ALL-time for USD/EUR/GBP/CAD/JPY/CHF/AUD
///   - 5Y and 1Y data derived from ALL-time (no extra requests)
///
/// The 1Y seed uses weekly granularity (~52 points). The in-app prewarm
/// replaces it with daily CoinGecko data on first launch.
///
/// Pass --force to overwrite existing seed files (default: skip existing).
///
/// Output format matches the app's Hive cache envelope:
///   {"ts": epochMs, "d": [[timestampMs, price], ...]}
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

const _krakenPairs = {
  'usd': 'XXBTZUSD',
  'eur': 'XXBTZEUR',
  'gbp': 'XXBTZGBP',
  'cad': 'XXBTZCAD',
  'jpy': 'XXBTZJPY',
  'chf': 'XBTCHF',
  'aud': 'XBTAUD',
};

const _outputDir = 'assets/seed';

void main(List<String> args) async {
  final force = args.contains('--force');

  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Accept': 'application/json'},
    ),
  );

  Directory(_outputDir).createSync(recursive: true);

  final now = DateTime.now().millisecondsSinceEpoch;
  final oneYearAgoMs =
      DateTime.now().subtract(const Duration(days: 365)).millisecondsSinceEpoch;
  final fiveYearsAgoMs =
      DateTime.now().subtract(const Duration(days: 1825)).millisecondsSinceEpoch;

  var written = 0;
  var skipped = 0;
  var failed = 0;

  for (final MapEntry(:key, :value) in _krakenPairs.entries) {
    final currency = key;
    final pair = value;

    stdout.write('[$currency] Kraken ALL-time ($pair)... ');
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.kraken.com/0/public/OHLC',
        queryParameters: {'pair': pair, 'interval': 10080},
      );

      final data = response.data!;
      final errors = data['error'] as List<dynamic>;
      if (errors.isNotEmpty) throw Exception('Kraken error: $errors');

      final resultMap = data['result'] as Map<String, dynamic>;
      final ohlc = (resultMap[pair] ??
          resultMap[resultMap.keys.firstWhere(
            (k) => k != 'last',
            orElse: () => pair,
          )]) as List<dynamic>;

      // Convert OHLC rows → [timestampMs, closePrice]
      final allPoints = ohlc.map((row) {
        final r = row as List<dynamic>;
        return [(r[0] as int) * 1000, double.parse(r[4] as String)];
      }).toList();

      // ALL-time
      final wAll = _writeAsset(
        '$_outputDir/btc_${currency}_0.json', now, allPoints, force: force,
      );

      // 5Y: filter to last 1825 days
      final points5y =
          allPoints.where((p) => (p[0] as int) >= fiveYearsAgoMs).toList();
      final w5y = _writeAsset(
        '$_outputDir/btc_${currency}_1825.json', now, points5y, force: force,
      );

      // 1Y: filter to last 365 days (weekly candles, ~52 points)
      final points1y =
          allPoints.where((p) => (p[0] as int) >= oneYearAgoMs).toList();
      final w1y = _writeAsset(
        '$_outputDir/btc_${currency}_365.json', now, points1y, force: force,
      );

      final counts = [
        'ALL=${allPoints.length}',
        '5Y=${points5y.length}',
        '1Y=${points1y.length}',
      ].join('  ');
      print('✓  $counts candles');

      for (final w in [wAll, w5y, w1y]) {
        if (w) {
          written++;
        } else {
          skipped++;
        }
      }

      await Future.delayed(const Duration(milliseconds: 500));
    } catch (e) {
      print('✗  $e');
      failed++;
    }
  }

  print('');
  print('$written file(s) written, $skipped skipped (already exist), '
      '$failed failed.');
  if (skipped > 0) print('Run with --force to overwrite existing files.');
  if (failed > 0) {
    print('Failed currencies will load from network on first launch.');
  }
  exit(failed > 0 ? 1 : 0);
}

/// Writes [data] to [path] with the cache envelope. Returns true if written,
/// false if skipped because the file already existed and [force] is false.
bool _writeAsset(
  String path,
  int ts,
  List<dynamic> data, {
  bool force = false,
}) {
  final file = File(path);
  if (!force && file.existsSync()) return false;
  file.writeAsStringSync(jsonEncode({'ts': ts, 'd': data}));
  return true;
}
