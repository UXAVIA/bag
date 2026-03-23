import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_constants.dart';
import '../models/dca_entry.dart';
import '../models/price_data.dart';
import '../services/price_service.dart';
import '../services/widget_service.dart';
import 'dca_provider.dart';
import 'portfolio_provider.dart';

final priceProvider = AsyncNotifierProvider<PriceNotifier, PriceData>(
  PriceNotifier.new,
);

class PriceNotifier extends AsyncNotifier<PriceData> {
  Timer? _timer;

  @override
  Future<PriceData> build() async {
    // Watching currencies means this provider rebuilds automatically when the
    // user changes their selected currencies in settings.
    final currencies = ref.watch(
      portfolioProvider.select((p) => p.selectedCurrencies),
    );

    ref.onDispose(() => _timer?.cancel());
    _startRefreshTimer();

    // When DCA entries change (add/delete) while we already have price data,
    // push an immediate widget update so P/L reflects the new entries without
    // waiting for the next price refresh.
    ref.listen<List<DcaEntry>>(dcaProvider, (_, entries) {
      final priceData = state.valueOrNull;
      if (priceData == null) return;
      WidgetService.update(
        priceData: priceData,
        portfolio: ref.read(portfolioProvider),
        dcaEntries: entries,
      ).ignore();
    });

    final priceData =
        await ref.read(priceServiceProvider).fetchCurrentPrice(currencies);

    // Pre-warm chart data for all timeframes in background.
    // Staggered internally to avoid rate-limit spikes.
    if (currencies.isNotEmpty) {
      ref.read(priceServiceProvider).prewarmCharts(currencies.first).ignore();
      // Proactively save chart prices for the widget's configured timeframe.
      // This runs on every price refresh so the widget chart stays current
      // regardless of whether the user has the home screen open.
      _saveWidgetChartData(currencies.first).ignore();
    }

    // Push latest data to the home screen widget (including DCA P/L if available).
    final portfolio = ref.read(portfolioProvider);
    final dcaEntries = ref.read(dcaProvider);
    WidgetService.update(
      priceData: priceData,
      portfolio: portfolio,
      dcaEntries: dcaEntries,
    ).ignore(); // fire-and-forget

    return priceData;
  }

  void _startRefreshTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(AppConstants.priceRefreshInterval, (_) {
      ref.invalidateSelf();
    });
  }

  Future<void> refresh() async {
    _timer?.cancel();
    ref.invalidateSelf();
  }

  /// Fetches chart data for the widget's configured timeframe and saves the
  /// close prices so Kotlin's NativeChartRenderer can draw the sparkline.
  /// Uses the Hive cache so no extra network request is made if data is fresh.
  Future<void> _saveWidgetChartData(String currency) async {
    try {
      final widgetDays = await WidgetService.getTimeframeDays();
      final chartData = await ref
          .read(priceServiceProvider)
          .fetchChartData(currency, widgetDays);
      await WidgetService.saveChartPricesForWidget(
        chartData: chartData,
        days: widgetDays,
      );
    } catch (e) {
      debugPrint('[PriceNotifier] widget chart save failed: $e');
    }
  }
}

// Chart data — family provider keyed by (currency, days).
// Not autoDisposed: keeps data in memory for the session to avoid re-fetching
// on every rebuild / timeframe switch and to respect CoinGecko rate limits.
final chartDataProvider = FutureProvider
    .family<List<(DateTime, double)>, (String, int)>((ref, params) async {
  final (currency, days) = params;
  return ref.read(priceServiceProvider).fetchChartData(currency, days);
});

// Selected timeframe for the chart — 1, 7, 30, or 365 days.
final selectedTimeframeDaysProvider = StateProvider<int>((ref) => 7);
