import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:home_widget/home_widget.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../core/constants/app_constants.dart';
import '../models/dca_entry.dart';
import '../models/fee_estimate.dart';
import '../models/network_settings.dart';
import '../models/price_alert.dart';
import '../models/price_data.dart';
import '../models/portfolio.dart';
import '../models/wallet_entry.dart';
import 'fee_service.dart';
import 'wallet/biometric_storage_service.dart' as bio;
import 'wallet/esplora_client.dart';
import 'wallet/wallet_engine.dart';
import 'wallet/wallet_scanner.dart';

const _widgetName = 'BagWidget';
const _androidWidgetName = 'com.bagapp.bag.BagWidget';
const _taskId = 'bag_widget_refresh';
const _widgetChannel = MethodChannel('com.bagapp.bag/widget');

// Kraken pairs — duplicated here so the background isolate is self-contained.
const _widgetKrakenPairs = {
  'usd': 'XXBTZUSD',
  'eur': 'XXBTZEUR',
  'gbp': 'XXBTZGBP',
  'cad': 'XXBTZCAD',
  'jpy': 'XXBTZJPY',
  'chf': 'XBTCHF',
  'aud': 'XBTAUD',
};

/// Background entry point — runs in a separate Dart isolate via WorkManager.
/// Must be a top-level function annotated vm:entry-point.
@pragma('vm:entry-point')
void backgroundWidgetCallback() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();

    // Read portfolio settings from SharedPreferences — safe in background isolate.
    final prefs = await SharedPreferences.getInstance();
    final btcAmount = prefs.getDouble(AppConstants.keyBtcAmount) ?? 0.0;
    final currencies =
        prefs.getStringList(AppConstants.keySelectedCurrencies) ??
            AppConstants.defaultCurrencies;
    final currency = currencies.first.toLowerCase();

    // Timeframe is written to Flutter SharedPreferences by the configure activity
    // (key: flutter.widget_timeframe_days) so it's reliably readable here.
    // HomeWidget.getWidgetData uses a platform channel that can fail in background
    // isolates, so we read from the standard prefs instead.
    final timeframeDays = prefs.getInt('widget_timeframe_days') ?? 7;

    // ── Tor pre-flight (single probe, shared by all network calls) ────────────
    // Price, chart, fee and wallet scan all use one result — probe once.
    // When Tor is enabled every outbound request MUST go through Orbot.
    // No clearnet fallback — that would leak the user's IP to CoinGecko,
    // Kraken, mempool.space and the block explorer against their explicit choice.
    final useTor = prefs.getBool(AppConstants.keyUseTor) ?? false;
    final torOk = !useTor || await _probeTor();
    if (useTor && !torOk) {
      if (kDebugMode) debugPrint('[WidgetBg] Tor required but Orbot unreachable — skipping network fetches');
    }
    // Single Dio instance for price + chart, Tor-routed when enabled.
    final dio = buildFeeDio(useTor);

    // ── Fetch current price ───────────────────────────────────────────────────

    double? price;
    double? change24h;
    if (!useTor || torOk) {
      try {
        final response = await dio.get<Map<String, dynamic>>(
          '${AppConstants.coinGeckoBase}/simple/price',
          queryParameters: {
            'ids': 'bitcoin',
            'vs_currencies': currency,
            'include_24hr_change': 'true',
          },
        );

        final btcData = response.data!['bitcoin'] as Map<String, dynamic>;
        price = (btcData[currency] as num).toDouble();
        final changeKey = '${currency}_24h_change';
        change24h = btcData.containsKey(changeKey)
            ? (btcData[changeKey] as num).toDouble()
            : null;
      } catch (e) {
        if (kDebugMode) debugPrint('[WidgetBg] price fetch failed: $e');
      }
    }

    // ── Fetch chart data from Kraken ──────────────────────────────────────────
    // Always uses Kraken so no API key or CoinGecko rate-limit is needed.
    // The close prices are saved as a JSON array and rendered natively in Kotlin.

    List<double>? chartPrices;
    double? tfChange; // timeframe % change (replaces 24h change if available)
    if (!useTor || torOk) {
      try {
        final pair = _widgetKrakenPairs[currency];
        if (pair != null) {
          final params = _krakenParamsForWidget(pair, timeframeDays);
          final response = await dio.get<Map<String, dynamic>>(
            'https://api.kraken.com/0/public/OHLC',
            queryParameters: params,
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

          final fetched = ohlc.map((row) {
            final r = row as List<dynamic>;
            return double.parse(r[4] as String); // close price
          }).toList();
          chartPrices = fetched;

          if (fetched.length >= 2) {
            final first = fetched.first;
            final last = fetched.last;
            if (first > 0) tfChange = (last - first) / first * 100;
          }

          if (kDebugMode) debugPrint('[WidgetBg] Kraken chart: ${fetched.length} candles for $currency (${timeframeDays}d)');
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[WidgetBg] chart fetch failed: $e');
      }
    }

    // ── Check price alerts ────────────────────────────────────────────────────

    if (price != null) {
      await _checkAlerts(prefs, currency, price);
    }

    // ── Fetch fees and check fee alerts ──────────────────────────────────────
    // We fetch fees if:
    //   a) There are active fee alerts to check, OR
    //   b) The user has enabled "show fee in widget"
    // Tor safety is already handled above — reuse torOk, no second probe.
    final showFeeInWidget = prefs.getBool(AppConstants.keyWidgetShowFee) ?? false;
    final feeAlertsRaw = prefs.getString(AppConstants.keyFeeAlerts);
    final hasActiveFeeAlerts =
        feeAlertsRaw != null && feeAlertsRaw.isNotEmpty;

    FeeEstimate? feeEstimate;
    if ((showFeeInWidget || hasActiveFeeAlerts) && (!useTor || torOk)) {
      try {
        feeEstimate = await fetchFeeEstimate(dio);
        if (feeEstimate != null) {
          await prefs.setString(
              AppConstants.keyFeeCache, feeEstimate.toJsonString());
          if (hasActiveFeeAlerts) {
            await checkFeeAlerts(prefs, feeEstimate.fast);
          }
          if (kDebugMode) debugPrint('[WidgetBg] fee estimate: ${feeEstimate.fast} sat/vB');
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[WidgetBg] fee fetch failed: $e');
      }
    }

    // ── Background wallet scan (all wallets, stale ones only) ────────────────
    // Reads zpubs from secure storage (no auth needed), derives addresses
    // on-device, queries Esplora. Updates SharedPreferences so the next app
    // launch picks up fresh balances without waiting for a scan.
    //
    // Tor safety is already handled above — reuse torOk, no second probe.

    double effectiveBtcAmount = btcAmount;
    final walletsJson = prefs.getString(AppConstants.keyWallets);
    if (walletsJson != null && walletsJson.isNotEmpty) {
      // Build Esplora client from stored network settings (no Riverpod here).
      final presetIndex = prefs.getInt(AppConstants.keyExplorerPreset) ?? 0;
      final customUrl =
          prefs.getString(AppConstants.keyExplorerCustomUrl) ?? '';
      final preset = ExplorerPreset.values[presetIndex.clamp(
        0,
        ExplorerPreset.values.length - 1,
      )];
      final baseUrl = switch (preset) {
        ExplorerPreset.blockstream => AppConstants.explorerBlockstream,
        ExplorerPreset.mempool => AppConstants.explorerMempool,
        ExplorerPreset.custom =>
          customUrl.isNotEmpty ? customUrl : AppConstants.explorerBlockstream,
      };

      // Reuse the torOk result from the pre-flight probe above.
      // Skip wallet scans rather than leak the user's IP over clearnet.
      // We do NOT return early — the widget must still be updated so it doesn't
      // go blank when Orbot drops.
      bool skipWalletScan = useTor && !torOk;
      if (skipWalletScan) {
        if (kDebugMode) debugPrint('[WidgetBg] Tor enabled but Orbot unreachable — skipping wallet scans');
      }

      if (!skipWalletScan) {
        final client = EsploraClient(baseUrl: baseUrl, useTor: useTor);

        List<WalletEntry> wallets;
        try {
          wallets = WalletEntry.listFromJson(walletsJson);
        } catch (e) {
          if (kDebugMode) debugPrint('[WidgetBg] failed to parse wallets: $e');
          wallets = [];
        }

        final updatedWallets = <WalletEntry>[];
        for (final wallet in wallets) {
          if (!wallet.isStale) {
            updatedWallets.add(wallet);
            continue;
          }

          try {
            final zpub = await bio.readZpubForScanningById(wallet.id);
            if (zpub == null) {
              updatedWallets.add(wallet);
              continue;
            }
            final root = parseZpub(zpub);
            final balance = await scanWallet(root, client);
            final now = DateTime.now();
            updatedWallets.add(wallet.copyWith(
              lastSats: balance.totalSats,
              lastScanAt: now,
              usedAddresses: balance.usedAddressCount,
            ));
            if (kDebugMode) {
              debugPrint(
                  '[WidgetBg] scanned ${wallet.label}: ${balance.totalSats} sats');
            }
          } on EsploraException catch (e) {
            if (kDebugMode) debugPrint('[WidgetBg] scan failed (${wallet.label}): $e');
            updatedWallets.add(wallet);
          } catch (e) {
            if (kDebugMode) debugPrint('[WidgetBg] scan error (${wallet.label}): $e');
            updatedWallets.add(wallet);
          }
        }

        // Persist updated metadata and compute total.
        if (updatedWallets.isNotEmpty) {
          await prefs.setString(
            AppConstants.keyWallets,
            WalletEntry.listToJsonString(updatedWallets),
          );
          final totalSats =
              updatedWallets.fold<int>(0, (s, w) => s + (w.lastSats ?? 0));
          if (totalSats > 0) {
            await prefs.setDouble(
                AppConstants.keyBtcAmount, totalSats / 1e8);
            effectiveBtcAmount = totalSats / 1e8;
          }
        }
      } else {
        // Tor enabled but Orbot unreachable: use cached wallet sats for net worth display.
        final walletsForDisplay = WalletEntry.listFromJson(walletsJson);
        final totalSats =
            walletsForDisplay.fold<int>(0, (s, w) => s + (w.lastSats ?? 0));
        if (totalSats > 0) effectiveBtcAmount = totalSats / 1e8;
      }
    }

    // ── Save to widget SharedPreferences and redraw ───────────────────────────

    final currencyFmt = NumberFormat.simpleCurrency(name: currency.toUpperCase());
    final displayChange = tfChange ?? change24h;

    final saves = <Future>[
      HomeWidget.saveWidgetData<bool>('widget_show_fee', showFeeInWidget),
      HomeWidget.saveWidgetData<String>(
        'widget_fast_fee',
        showFeeInWidget && feeEstimate != null
            ? '${feeEstimate.fast.toStringAsFixed(0)} sat/vB'
            : null,
      ),
      HomeWidget.saveWidgetData<String>(
          'widget_price', price != null ? currencyFmt.format(price) : null),
      HomeWidget.saveWidgetData<String>(
        'widget_net_worth',
        price != null && effectiveBtcAmount > 0
            ? currencyFmt.format(price * effectiveBtcAmount)
            : null,
      ),
      HomeWidget.saveWidgetData<String>(
        'widget_change',
        displayChange != null
            ? '${displayChange >= 0 ? '+' : ''}${displayChange.toStringAsFixed(1)}%'
            : null,
      ),
      HomeWidget.saveWidgetData<bool>(
          'widget_change_positive', displayChange != null && displayChange >= 0),
      HomeWidget.saveWidgetData<String>(
          'widget_updated_at', DateFormat('HH:mm').format(DateTime.now())),
      if (chartPrices != null)
        HomeWidget.saveWidgetData<String>(
            'widget_chart_prices', jsonEncode(chartPrices)),
    ];
    await Future.wait(saves);

    await HomeWidget.updateWidget(
        name: _widgetName, qualifiedAndroidName: _androidWidgetName);

    if (kDebugMode) debugPrint('[WidgetBg] updated — BTC $currency: $price');
    return true;
  });
}

/// Checks stored price alerts against [price] for [currency], fires local
/// notifications for triggered alerts, and marks them as fired in prefs.
Future<void> _checkAlerts(
    SharedPreferences prefs, String currency, double price) async {
  final raw = prefs.getString(AppConstants.keyPriceAlerts);
  if (raw == null || raw.isEmpty) return;

  List<PriceAlert> alerts;
  try {
    alerts = PriceAlert.listFromJsonString(raw);
  } catch (_) {
    return;
  }

  final toFire = alerts.where((a) => a.currency == currency && a.shouldFire(price)).toList();
  if (toFire.isEmpty) return;

  // Initialise the notification plugin inside the background isolate.
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    ),
  );

  final fmt = NumberFormat.simpleCurrency(name: currency.toUpperCase());
  var notifId = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  for (final alert in toFire) {
    final direction = alert.above ? 'reached' : 'dropped to';
    await plugin.show(
      notifId++,
      'BTC price alert',
      'BTC has $direction ${fmt.format(alert.targetPrice)}. Current: ${fmt.format(price)}',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          AppConstants.notifChannelId,
          AppConstants.notifChannelName,
          channelDescription: AppConstants.notifChannelDesc,
          importance: Importance.high,
          priority: Priority.high,
          visibility: NotificationVisibility.secret,
          icon: 'ic_notification',
        ),
      ),
    );
    if (kDebugMode) debugPrint('[WidgetBg] fired alert ${alert.id}: BTC $direction ${alert.targetPrice}');
  }

  // Mark fired alerts in SharedPreferences so the app UI reflects it on next open.
  final updated = alerts.map((a) => toFire.any((f) => f.id == a.id) ? a.copyWith(fired: true) : a).toList();
  await prefs.setString(AppConstants.keyPriceAlerts, PriceAlert.listToJsonString(updated));
}

/// Returns Kraken OHLC query params for the given timeframe.
/// ALL (days == 0) → weekly, full history.
/// Each other timeframe uses the coarsest interval that gives ~50–400 candles.
Map<String, dynamic> _krakenParamsForWidget(String pair, int timeframeDays) {
  final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final params = <String, dynamic>{'pair': pair};

  if (timeframeDays == 0) {
    // ALL: weekly, no since filter
    params['interval'] = 10080;
  } else if (timeframeDays <= 1) {
    params['interval'] = 60; // hourly
    params['since'] = nowSecs - 90000; // 25 h
  } else if (timeframeDays <= 7) {
    params['interval'] = 60; // hourly
    params['since'] = nowSecs - 691200; // 8 days
  } else if (timeframeDays <= 30) {
    params['interval'] = 1440; // daily
    params['since'] = nowSecs - 2764800; // 32 days
  } else if (timeframeDays <= 365) {
    params['interval'] = 1440; // daily
    params['since'] = nowSecs - 31968000; // ~370 days
  } else {
    // 5Y (1825 days): weekly
    params['interval'] = 10080;
    params['since'] = nowSecs - 157766400; // 5 years + buffer
  }

  return params;
}

class WidgetService {
  /// Initialise HomeWidget and WorkManager. Call once from main().
  static Future<void> initialise() async {
    await HomeWidget.setAppGroupId('com.bagapp.bag');
    await HomeWidget.registerInteractivityCallback(_interactivityCallback);

    try {
      await Workmanager().initialize(
        backgroundWidgetCallback,
        isInDebugMode: false,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[WidgetService] WorkManager init failed: $e');
    }
  }

  /// Schedule (or keep existing) 15-min background refresh.
  static Future<void> scheduleRefresh() async {
    try {
      await Workmanager().registerPeriodicTask(
        _taskId,
        _taskId,
        frequency: const Duration(minutes: 15),
        existingWorkPolicy: ExistingWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
      );
      if (kDebugMode) debugPrint('[WidgetService] background refresh scheduled');
    } catch (e) {
      if (kDebugMode) debugPrint('[WidgetService] WorkManager schedule failed: $e');
    }
  }

  /// Cancel the background refresh.
  static Future<void> cancelRefresh() async {
    await Workmanager().cancelByUniqueName(_taskId);
    if (kDebugMode) debugPrint('[WidgetService] background refresh cancelled');
  }

  /// Write current price + portfolio data to widget shared storage and
  /// trigger a visual redraw. Called from PriceNotifier on every fetch.
  /// Save the current fast fee rate to widget SharedPreferences and redraw.
  /// Called from [feeProvider] whenever a fresh estimate is available.
  static Future<void> updateFee(FeeEstimate estimate) async {
    await Future.wait([
      HomeWidget.saveWidgetData<bool>('widget_show_fee', true),
      HomeWidget.saveWidgetData<String>(
          'widget_fast_fee',
          '${estimate.fast.toStringAsFixed(0)} sat/vB'),
    ]);
    await HomeWidget.updateWidget(
        name: _widgetName, qualifiedAndroidName: _androidWidgetName);
  }

  /// Clear the fee row from the widget immediately when the user disables it.
  static Future<void> clearFee() async {
    await Future.wait([
      HomeWidget.saveWidgetData<bool>('widget_show_fee', false),
      HomeWidget.saveWidgetData<String>('widget_fast_fee', null),
    ]);
    await HomeWidget.updateWidget(
        name: _widgetName, qualifiedAndroidName: _androidWidgetName);
  }

  static Future<void> update({
    required PriceData priceData,
    required Portfolio portfolio,
    List<DcaEntry>? dcaEntries,
  }) async {
    final currency = portfolio.selectedCurrencies.isNotEmpty
        ? portfolio.selectedCurrencies.first.toLowerCase()
        : 'usd';

    final price = priceData.priceFor(currency);
    final change = priceData.changeFor(currency);

    // Guard against the brief window where portfolioProvider hasn't yet
    // reflected the latest wallet scan or settings write. If btcAmount is 0
    // here, saving null for widget_net_worth would wipe the previously
    // correct value written by the background task. Read SharedPreferences
    // directly as a fallback so the widget never goes blank unnecessarily.
    double btcAmount = portfolio.btcAmount;
    if (btcAmount == 0) {
      final prefs = await SharedPreferences.getInstance();
      btcAmount = prefs.getDouble(AppConstants.keyBtcAmount) ?? 0.0;
    }

    final currencyFmt =
        NumberFormat.simpleCurrency(name: currency.toUpperCase());

    // Compute DCA P/L.
    String? pnlAmountStr;
    String? pnlPctStr;
    bool pnlPositive = true;
    if (dcaEntries != null && dcaEntries.isNotEmpty && price != null) {
      final filtered = dcaEntries
          .where((e) => e.currency.toLowerCase() == currency)
          .toList();
      if (filtered.isNotEmpty) {
        final stats = DcaStats.fromEntries(
          filtered,
          viewCurrency: currency,
          currentPrices: priceData.prices,
        );
        if (stats.hasPriceData && stats.pnl != null && stats.pnlPercent != null) {
          final sign = stats.pnl! >= 0 ? '+' : '';
          pnlAmountStr = '$sign${currencyFmt.format(stats.pnl!)}';
          pnlPctStr = '$sign${stats.pnlPercent!.toStringAsFixed(1)}%';
          pnlPositive = stats.isProfit;
        }
      }
    }

    await Future.wait([
      // widget_currency lets NativeChartRefreshWorker know which pair to fetch.
      HomeWidget.saveWidgetData<String>('widget_currency', currency),
      HomeWidget.saveWidgetData<String>(
          'widget_price', price != null ? currencyFmt.format(price) : null),
      HomeWidget.saveWidgetData<String>(
        'widget_net_worth',
        price != null && btcAmount > 0
            ? currencyFmt.format(price * btcAmount)
            : null,
      ),
      HomeWidget.saveWidgetData<String>(
        'widget_change',
        change != null
            ? '${change >= 0 ? '+' : ''}${change.toStringAsFixed(1)}%'
            : null,
      ),
      HomeWidget.saveWidgetData<bool>(
          'widget_change_positive', change != null && change >= 0),
      HomeWidget.saveWidgetData<String>(
          'widget_updated_at', DateFormat('HH:mm').format(DateTime.now())),
      HomeWidget.saveWidgetData<String>('widget_pnl_amount', pnlAmountStr),
      HomeWidget.saveWidgetData<String>('widget_pnl_pct', pnlPctStr),
      HomeWidget.saveWidgetData<bool>('widget_pnl_positive', pnlPositive),
    ]);

    await HomeWidget.updateWidget(
        name: _widgetName, qualifiedAndroidName: _androidWidgetName);
  }

  /// Save chart close prices to widget SharedPreferences and trigger a redraw.
  /// Kotlin's NativeChartRenderer reads these prices and draws the sparkline.
  ///
  /// Also overrides widget_change with the selected timeframe's % change
  /// (rather than the 24h change stored by [update]).
  ///
  /// Only call this when [days] matches the user's configured widget timeframe
  /// (check with [getTimeframeDays]) to avoid pushing the wrong timeframe's
  /// chart to the widget.
  static Future<void> saveChartPricesForWidget({
    required List<(DateTime, double)> chartData,
    required int days,
  }) async {
    if (chartData.isEmpty) return;

    final prices = chartData.map((p) => p.$2).toList();

    final saves = <Future>[
      HomeWidget.saveWidgetData<String>(
          'widget_chart_prices', jsonEncode(prices)),
    ];

    // Override widget_change with the actual timeframe % change.
    if (chartData.length >= 2) {
      final first = chartData.first.$2;
      final last = chartData.last.$2;
      if (first > 0) {
        final change = (last - first) / first * 100;
        saves.addAll([
          HomeWidget.saveWidgetData<String>(
            'widget_change',
            '${change >= 0 ? '+' : ''}${change.toStringAsFixed(1)}%',
          ),
          HomeWidget.saveWidgetData<bool>('widget_change_positive', change >= 0),
        ]);
      }
    }

    await Future.wait(saves);
    await HomeWidget.updateWidget(
        name: _widgetName, qualifiedAndroidName: _androidWidgetName);
  }

  /// Returns the timeframe (days) the user configured for the widget.
  static Future<int> getTimeframeDays() async {
    final v = await HomeWidget.getWidgetData<int>('widget_timeframe_days');
    return v ?? 7;
  }

  /// Request the system widget picker to pin the widget to the home screen.
  static Future<bool> requestPinWidget() async {
    try {
      final result =
          await _widgetChannel.invokeMethod<bool>('requestPinWidget');
      return result ?? false;
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('[WidgetService] requestPinWidget error: ${e.message}');
      return false;
    }
  }

  /// Returns the device Android SDK version.
  static Future<int> getSdkVersion() async {
    try {
      final v = await _widgetChannel.invokeMethod<int>('getSdkVersion');
      return v ?? 0;
    } on PlatformException {
      return 0;
    }
  }
}

/// TCP probe for the local Orbot SOCKS5 port.
/// Used in the background isolate where TorService (Riverpod) is unavailable.
Future<bool> _probeTor() async {
  try {
    final socket = await Socket.connect(
      AppConstants.torHost,
      AppConstants.torPort,
      timeout: const Duration(seconds: 5),
    );
    await socket.close();
    return true;
  } catch (_) {
    return false;
  }
}

@pragma('vm:entry-point')
Future<void> _interactivityCallback(Uri? uri) async {
  // Reserved for future interactive widget actions (e.g. refresh tap).
}
