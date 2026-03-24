import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:socks5_proxy/socks.dart';

import '../core/constants/app_constants.dart';
import '../models/price_data.dart';
import '../providers/network_settings_provider.dart';

// Rebuilds whenever the user toggles Tor so all subsequent fetches use the
// correct network path — no clearnet leak when Tor is enabled.
final priceServiceProvider = Provider<PriceService>((ref) {
  final useTor = ref.watch(networkSettingsProvider.select((s) => s.useTor));
  return PriceService(useTor: useTor);
});

// Kraken supports weekly BTC OHLC back to 2013 for free, no API key needed.
// Used for 5Y and ALL-time charts; CoinGecko free tier is capped at 365 days.
// Pair names are Kraken's canonical identifiers (verified against live API).
const _krakenPairs = {
  'usd': 'XXBTZUSD',
  'eur': 'XXBTZEUR',
  'gbp': 'XXBTZGBP',
  'cad': 'XXBTZCAD',
  'jpy': 'XXBTZJPY',
  'chf': 'XBTCHF',
  'aud': 'XBTAUD',
};

class PriceService {
  final Dio _dio;
  final Dio _krakenDio;
  final Dio _mempoolDio;
  final Dio _bitfinexDio;

  // When Tor is enabled, raise timeouts to 60 s — Tor circuit establishment
  // alone can take 10–20 s. Clearnet uses 15 s which is ample.
  PriceService({bool useTor = false})
      : _dio = _buildDio(useTor, AppConstants.coinGeckoBase),
        _krakenDio = _buildDio(useTor, 'https://api.kraken.com/0/public'),
        _mempoolDio = _buildDio(useTor, AppConstants.mempoolBase),
        _bitfinexDio = _buildDio(useTor, AppConstants.bitfinexBase);

  static Dio _buildDio(bool useTor, String baseUrl) {
    final timeout =
        useTor ? const Duration(seconds: 60) : const Duration(seconds: 15);
    final dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: timeout,
      receiveTimeout: timeout,
      headers: {'Accept': 'application/json'},
    ));
    if (useTor) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          SocksTCPClient.assignToHttpClient(client, [
            ProxySettings(
              InternetAddress(AppConstants.torHost),
              AppConstants.torPort,
            ),
          ]);
          return client;
        },
      );
    }
    return dio;
  }

  // ── Current price ──────────────────────────────────────────────────────────

  /// Fetches the current BTC price with a three-source fallback cascade:
  ///   1. CoinGecko  — full coverage, 24 h change included
  ///   2. mempool.space — USD/EUR/GBP/CAD/JPY/CHF/AUD, no 24 h change
  ///   3. Bitfinex   — USD/EUR/GBP/JPY, 24 h change included
  ///   4. Stale Hive cache — served as last resort before throwing
  Future<PriceData> fetchCurrentPrice(List<String> currencies) async {
    // 1. CoinGecko (primary)
    try {
      return await _fetchFromCoinGecko(currencies);
    } catch (e) {
      if (kDebugMode) debugPrint('[PriceService] CoinGecko failed, trying mempool: $e');
    }

    // 2. mempool.space (covers USD/EUR/GBP/CAD/JPY/CHF/AUD)
    try {
      final data = await _fetchFromMempool(currencies);
      if (data != null) return data;
    } catch (e) {
      if (kDebugMode) debugPrint('[PriceService] mempool.space price failed, trying Bitfinex: $e');
    }

    // 3. Bitfinex (covers USD/EUR/GBP/JPY + 24 h change)
    try {
      final data = await _fetchFromBitfinex(currencies);
      if (data != null) return data;
    } catch (e) {
      if (kDebugMode) debugPrint('[PriceService] Bitfinex failed: $e');
    }

    // 4. Stale Hive cache — better than an error screen
    final cached = _cachedPrice();
    if (cached != null) {
      if (kDebugMode) debugPrint('[PriceService] all sources failed, serving stale cache');
      return cached;
    }

    throw Exception('All price sources unavailable');
  }

  Future<PriceData> _fetchFromCoinGecko(List<String> currencies) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/simple/price',
      queryParameters: {
        'ids': 'bitcoin',
        'vs_currencies': currencies.join(','),
        'include_24hr_change': 'true',
      },
    );
    if (kDebugMode) debugPrint('[PriceService] CoinGecko price: ${response.statusCode}');

    final btcData = response.data!['bitcoin'] as Map<String, dynamic>;
    final prices = <String, double>{};
    final changes = <String, double>{};

    for (final currency in currencies) {
      final lower = currency.toLowerCase();
      prices[lower] = (btcData[lower] as num).toDouble();
      final changeKey = '${lower}_24h_change';
      if (btcData.containsKey(changeKey)) {
        changes[lower] = (btcData[changeKey] as num).toDouble();
      }
    }

    final priceData = PriceData(
      prices: prices,
      changes24h: changes,
      fetchedAt: DateTime.now(),
    );
    _cachePriceData(priceData);
    return priceData;
  }

  // mempool.space /api/v1/prices supports exactly these currencies.
  static const _mempoolSupportedCurrencies = {
    'usd', 'eur', 'gbp', 'cad', 'jpy', 'chf', 'aud',
  };

  Future<PriceData?> _fetchFromMempool(List<String> currencies) async {
    final response = await _mempoolDio.get<Map<String, dynamic>>('/api/v1/prices');
    if (kDebugMode) debugPrint('[PriceService] mempool.space price: ${response.statusCode}');

    final data = response.data!;
    final prices = <String, double>{};

    for (final currency in currencies) {
      final lower = currency.toLowerCase();
      if (!_mempoolSupportedCurrencies.contains(lower)) continue;
      final upper = lower.toUpperCase();
      if (data.containsKey(upper)) {
        prices[lower] = (data[upper] as num).toDouble();
      }
    }

    if (prices.isEmpty) return null;

    // mempool.space does not return 24 h change — omit rather than fabricate.
    final priceData = PriceData(
      prices: prices,
      changes24h: const {},
      fetchedAt: DateTime.now(),
    );
    _cachePriceData(priceData);
    return priceData;
  }

  // Bitfinex v2 /tickers supports these currencies as tBTCXXX pairs.
  static const _bitfinexSupportedCurrencies = {'usd', 'eur', 'gbp', 'jpy'};

  Future<PriceData?> _fetchFromBitfinex(List<String> currencies) async {
    final supported = currencies
        .map((c) => c.toLowerCase())
        .where((c) => _bitfinexSupportedCurrencies.contains(c))
        .toList();
    if (supported.isEmpty) return null;

    final symbols = supported.map((c) => 'tBTC${c.toUpperCase()}').join(',');
    final response = await _bitfinexDio.get<List<dynamic>>(
      '/tickers',
      queryParameters: {'symbols': symbols},
    );
    if (kDebugMode) debugPrint('[PriceService] Bitfinex tickers: ${response.statusCode}');

    final prices = <String, double>{};
    final changes = <String, double>{};

    for (final ticker in response.data!) {
      final arr = ticker as List<dynamic>;
      final symbol = arr[0] as String; // e.g. 'tBTCUSD'
      final currency = symbol.substring(4).toLowerCase(); // 'usd'
      prices[currency] = (arr[7] as num).toDouble(); // last price
      // arr[6] = daily_change_relative (fraction) → multiply by 100 for %
      changes[currency] = (arr[6] as num).toDouble() * 100;
    }

    if (prices.isEmpty) return null;

    final priceData = PriceData(
      prices: prices,
      changes24h: changes,
      fetchedAt: DateTime.now(),
    );
    _cachePriceData(priceData);
    return priceData;
  }

  void _cachePriceData(PriceData priceData) {
    Hive.box<String>(AppConstants.priceBox).put(
      AppConstants.priceKey,
      priceData.toJsonString(),
    );
  }

  PriceData? _cachedPrice() {
    final raw =
        Hive.box<String>(AppConstants.priceBox).get(AppConstants.priceKey);
    if (raw == null) return null;
    return PriceData.fromJsonString(raw);
  }

  PriceData? getCachedPrice() => _cachedPrice();

  // ── Seed from bundled assets ────────────────────────────────────────────────

  /// Populates Hive chart cache from bundled asset files for any key that
  /// doesn't already have data. Call once from main() after Hive is open.
  ///
  /// Assets are written by `dart run tool/fetch_seed_data.dart` at release time.
  /// Covers ALL-time, 5Y, and 1Y for USD/EUR/GBP/CAD/JPY/CHF/AUD.
  /// Missing assets (e.g. first run before script has executed) are skipped
  /// silently — the normal network fetch handles them.
  static Future<void> seedFromAssets() async {
    final box = Hive.box<String>(AppConstants.priceBox);
    const currencies = ['usd', 'eur', 'gbp', 'cad', 'jpy', 'chf', 'aud'];
    const timeframes = [0, 1825, 365]; // ALL, 5Y, 1Y

    for (final currency in currencies) {
      for (final days in timeframes) {
        final cacheKey = '${AppConstants.chartKeyPrefix}${currency}_$days';
        if (box.containsKey(cacheKey)) continue; // never overwrite live data

        try {
          final raw = await rootBundle.loadString(
            'assets/seed/btc_${currency}_$days.json',
          );
          await box.put(cacheKey, raw);
          if (kDebugMode) debugPrint('[PriceService] seeded $cacheKey from asset');
        } catch (_) {
          // Asset not present — skip silently, network fetch will handle it.
        }
      }
    }
  }

  // ── Historical price (single date) ─────────────────────────────────────────

  /// Returns the BTC closing price in [currency] on [date].
  ///
  /// Strategy:
  ///   1. Today → live cached price (CoinGecko /history gives incomplete
  ///      intraday data and Kraken's latest candle may not be closed yet).
  ///   2. Kraken-supported currencies → Kraken daily OHLC. Free, no API key,
  ///      no meaningful rate limit, data back to ~2013. Cached permanently.
  ///   3. Other currencies → CoinGecko /history fallback. Cached permanently.
  Future<double?> fetchHistoricalPrice(String currency, DateTime date) async {
    final lower = currency.toLowerCase();
    final now = DateTime.now();
    final isToday = date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;

    if (isToday) return _cachedPrice()?.priceFor(lower);

    // Permanent Hive cache — historical prices never change.
    final dateKey =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final cacheKey = 'hist_${lower}_$dateKey';
    final box = Hive.box<String>(AppConstants.priceBox);

    final cached = box.get(cacheKey);
    if (cached != null) return double.tryParse(cached);

    if (_krakenPairs.containsKey(lower)) {
      final price = await _historicalFromKraken(lower, date, cacheKey, box);
      if (price != null) return price;
      // Kraken has no data this far back for this pair — fall through to CoinGecko.
    }
    return _historicalFromCoinGecko(lower, date, cacheKey, box);
  }

  /// Fetches the daily closing price from Kraken for the given date.
  /// Requests daily candles (interval=1440) anchored just before [date] so the
  /// target candle is always included. Picks the candle whose open time is
  /// closest to the start of [date] in UTC.
  Future<double?> _historicalFromKraken(
    String currency,
    DateTime date,
    String cacheKey,
    Box<String> box,
  ) async {
    try {
      final pair = _krakenPairs[currency]!;
      final dayStartSec =
          DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/
              1000;

      final response = await _krakenDio.get<Map<String, dynamic>>(
        '/OHLC',
        queryParameters: {
          'pair': pair,
          'interval': 1440,
          'since': dayStartSec - 86400, // one day buffer so the candle is included
        },
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

      // Pick the candle whose open time is closest to the start of the target day.
      List<dynamic>? best;
      int bestDiff = 0x7fffffffffffffff;
      for (final row in ohlc) {
        final r = row as List<dynamic>;
        final t = r[0] as int;
        final diff = (t - dayStartSec).abs();
        if (diff < bestDiff) {
          bestDiff = diff;
          best = r;
        }
        if (t > dayStartSec + 86400) break;
      }

      // If the closest candle is more than 2 days from the target the pair
      // simply doesn't have data that far back — return null so the caller
      // can try a different source rather than returning a wildly wrong price.
      if (best == null || bestDiff > 2 * 86400) return null;

      final price = double.parse(best[4] as String); // index 4 = close
      await box.put(cacheKey, price.toString());
      if (kDebugMode) debugPrint('[PriceService] Kraken historical $currency ${date.toIso8601String().substring(0, 10)}: $price');
      return price;
    } catch (e) {
      if (kDebugMode) debugPrint('[PriceService] Kraken historical error ($currency ${date.toIso8601String().substring(0, 10)}): $e');
      return null;
    }
  }

  /// CoinGecko /history fallback for currencies Kraken does not carry.
  Future<double?> _historicalFromCoinGecko(
    String currency,
    DateTime date,
    String cacheKey,
    Box<String> box,
  ) async {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final dateStr = '$day-$month-${date.year}';
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/coins/bitcoin/history',
        queryParameters: {'date': dateStr, 'localization': 'false'},
      );
      if (kDebugMode) debugPrint('[PriceService] CoinGecko historical $currency $dateStr: ${response.statusCode}');
      final priceMap = response.data!['market_data']?['current_price']
          as Map<String, dynamic>?;
      final price = (priceMap?[currency] as num?)?.toDouble();
      if (price != null) await box.put(cacheKey, price.toString());
      return price;
    } catch (e) {
      if (kDebugMode) debugPrint('[PriceService] CoinGecko historical error ($dateStr $currency): $e');
      return null;
    }
  }

  // ── Chart data ──────────────────────────────────────────────────────────────

  /// Fetches chart data for [currency] over [days].
  /// - days 1–365 → CoinGecko (auto-granularity)
  /// - days == 1825 (5Y sentinel) → Kraken weekly, filtered to last 5 years
  /// - days == 0 (ALL sentinel) → Kraken weekly, all history since 2013
  ///
  /// Uses a tiered stale cache: short timeframes refresh more often.
  Future<List<(DateTime, double)>> fetchChartData(
    String currency,
    int days,
  ) async {
    final cacheKey = '${AppConstants.chartKeyPrefix}${currency}_$days';
    final box = Hive.box<String>(AppConstants.priceBox);
    final cached = box.get(cacheKey);

    if (cached != null && !_isCacheStale(cached, days)) {
      // Fresh cache — serve immediately, no background refresh needed.
      return _readCacheData(cached)!;
    }

    if (cached != null) {
      // Stale cache — serve stale data instantly, refresh in background.
      _doFetch(currency, days, cacheKey, box).ignore();
      return _readCacheData(cached)!;
    }

    // No cache at all — blocking fetch.
    return _doFetch(currency, days, cacheKey, box);
  }

  /// Pre-warms chart data for all timeframes of [currency] in background.
  /// Staggered to avoid hitting CoinGecko rate limits.
  /// Safe to call on every app open — stale check prevents redundant requests.
  Future<void> prewarmCharts(String currency) async {
    const timeframes = [1, 7, 30, 365, AppConstants.timeframe5YDays, AppConstants.timeframeAllDays];
    for (final days in timeframes) {
      await Future.delayed(const Duration(milliseconds: 400));
      fetchChartData(currency, days).ignore();
    }
    if (kDebugMode) debugPrint('[PriceService] chart pre-warm queued for $currency');
  }

  /// Removes the cached chart for [currency]/[days] so the next fetch goes to
  /// the network. Used by pull-to-refresh on the home screen.
  void clearChartCache(String currency, int days) {
    final key = '${AppConstants.chartKeyPrefix}${currency}_$days';
    Hive.box<String>(AppConstants.priceBox).delete(key);
    if (kDebugMode) debugPrint('[PriceService] cleared chart cache: $key');
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  Future<List<(DateTime, double)>> _doFetch(
    String currency,
    int days,
    String cacheKey,
    Box<String> box,
  ) async {
    try {
      final List<(DateTime, double)> result;

      if (days == AppConstants.timeframeAllDays ||
          days == AppConstants.timeframe5YDays) {
        result = await _fetchKraken(currency, days);
      } else {
        final response = await _dio.get<Map<String, dynamic>>(
          '/coins/bitcoin/market_chart',
          queryParameters: {
            'vs_currency': currency,
            'days': days,
            'precision': '2',
          },
        );
        if (kDebugMode) debugPrint('[PriceService] CoinGecko chart ${days}d: ${response.statusCode}');
        final rawPrices = response.data!['prices'] as List<dynamic>;
        _writeCache(box, cacheKey, rawPrices);
        return _parseChartPrices(rawPrices);
      }

      _writeCache(
        box,
        cacheKey,
        result.map((e) => [e.$1.millisecondsSinceEpoch, e.$2]).toList(),
      );
      return result;
    } catch (e, st) {
      if (kDebugMode) debugPrint('[PriceService] fetchChartData error (${days}d): $e\n$st');
      final cached = box.get(cacheKey);
      if (cached != null) {
        return _readCacheData(cached) ?? (throw e);
      }
      rethrow;
    }
  }

  /// Fetches weekly BTC OHLC from Kraken.
  /// [days] == 0 → all history; [days] == 1825 → last 5 years.
  /// Falls back to CoinGecko 365-day data for currencies Kraken doesn't carry.
  Future<List<(DateTime, double)>> _fetchKraken(
    String currency,
    int days,
  ) async {
    final pair = _krakenPairs[currency.toLowerCase()];
    if (pair == null) {
      if (kDebugMode) debugPrint('[PriceService] Kraken: $currency not supported, using CoinGecko 365d');
      final response = await _dio.get<Map<String, dynamic>>(
        '/coins/bitcoin/market_chart',
        queryParameters: {
          'vs_currency': currency,
          'days': 365,
          'precision': '2',
        },
      );
      return _parseChartPrices(response.data!['prices'] as List<dynamic>);
    }

    // For 5Y, pass a `since` timestamp so Kraken returns data from 5yr ago.
    // For ALL, omit `since` to get all history.
    final queryParams = <String, dynamic>{'pair': pair, 'interval': 10080};
    if (days == AppConstants.timeframe5YDays) {
      final since = DateTime.now()
          .subtract(const Duration(days: AppConstants.timeframe5YDays))
          .millisecondsSinceEpoch ~/
          1000;
      queryParams['since'] = since;
    }

    final response = await _krakenDio.get<Map<String, dynamic>>(
      '/OHLC',
      queryParameters: queryParams,
    );

    final data = response.data!;
    final errors = data['error'] as List<dynamic>;
    if (errors.isNotEmpty) throw Exception('Kraken error: $errors');

    // Kraken returns the canonical pair name as the result key; try both
    // the requested name and a fallback without the 'X' prefix.
    final resultMap = data['result'] as Map<String, dynamic>;
    final ohlc = (resultMap[pair] ??
        resultMap[resultMap.keys.firstWhere(
          (k) => k != 'last',
          orElse: () => pair,
        )]) as List<dynamic>;

    if (kDebugMode) debugPrint('[PriceService] Kraken ${days == 0 ? 'ALL' : '5Y'}: ${ohlc.length} weekly candles for $pair');

    return ohlc.map((row) {
      final r = row as List<dynamic>;
      return (
        DateTime.fromMillisecondsSinceEpoch((r[0] as int) * 1000),
        double.parse(r[4] as String), // close price
      );
    }).toList();
  }

  // ── Cache helpers ──────────────────────────────────────────────────────────

  /// Cache entry format: {"ts": epochMs, "d": [[ms, price], ...]}
  /// Older entries may be raw lists — treated as stale for a clean migration.
  void _writeCache(Box<String> box, String key, List<dynamic> prices) {
    box.put(
      key,
      jsonEncode({
        'ts': DateTime.now().millisecondsSinceEpoch,
        'd': prices,
      }),
    );
  }

  List<(DateTime, double)>? _readCacheData(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is Map && json.containsKey('d')) {
        return _parseChartPrices(json['d'] as List<dynamic>);
      }
      // Old format (raw list) — still parseable.
      if (json is List) return _parseChartPrices(json);
      return null;
    } catch (_) {
      return null;
    }
  }

  bool _isCacheStale(String raw, int days) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map || !json.containsKey('ts')) return true; // old format
      final ts = json['ts'] as int;
      final age = DateTime.now().millisecondsSinceEpoch - ts;
      return age > _staleMs(days);
    } catch (_) {
      return true;
    }
  }

  int _staleMs(int days) {
    if (days <= 1) return AppConstants.chartStale1D.inMilliseconds;
    if (days <= 7) return AppConstants.chartStale1W.inMilliseconds;
    if (days <= 30) return AppConstants.chartStale1M.inMilliseconds;
    if (days <= 365) return AppConstants.chartStale1Y.inMilliseconds;
    return AppConstants.chartStale5YAll.inMilliseconds; // 5Y and ALL
  }

  List<(DateTime, double)> _parseChartPrices(List<dynamic> raw) {
    return raw.map((entry) {
      final pair = entry as List<dynamic>;
      return (
        DateTime.fromMillisecondsSinceEpoch(pair[0] as int),
        (pair[1] as num).toDouble(),
      );
    }).toList();
  }
}
