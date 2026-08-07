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
  bool _disposed = false;

  @override
  Future<PriceData> build() async {
    _disposed = false;
    // Rebuild only when the SET of currencies changes (add/remove), not on
    // reorder. List uses reference equality so a reordered list would
    // unnecessarily trigger a price refetch and a loading-state flash.
    ref.watch(
      portfolioProvider.select((p) => p.selectedCurrencies.toSet()),
    );
    // Read the ordered list for the actual fetch and pre-warm calls.
    final currencies = ref.read(portfolioProvider).selectedCurrencies;

    ref.onDispose(() {
      _timer?.cancel();
      _disposed = true;
    });
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

    // If we have any cached price, return it immediately so the home screen
    // is never stuck on a loading spinner. A background refresh runs in
    // parallel — state is updated silently when fresh data arrives.
    final cached = ref.read(priceServiceProvider).getCachedPrice();
    if (cached != null) {
      // Pre-warm the chart provider for the active timeframe NOW so that by the
      // time _ChartSection builds it the FutureProvider is already resolved or
      // in-flight rather than starting from AsyncLoading.
      if (currencies.isNotEmpty) {
        final days = ref.read(selectedTimeframeDaysProvider);
        ref.read(chartDataProvider((currencies.first, days)));
      }

      // Push cached price to the widget immediately — don't wait for the
      // background network fetch to finish.
      final portfolio = ref.read(portfolioProvider);
      final dcaEntries = ref.read(dcaProvider);
      WidgetService.update(
        priceData: cached,
        portfolio: portfolio,
        dcaEntries: dcaEntries,
      ).ignore();

      _backgroundRefresh(currencies);
      return cached;
    }

    // No cache (first launch or cleared) — blocking fetch with fallback chain.
    return _fetchAndSideEffects(currencies);
  }

  /// Fetches fresh price data and runs the post-fetch side effects
  /// (chart pre-warm, widget update). Used for both blocking and background fetches.
  ///
  /// [prewarmCharts] is disabled for an explicit pull-to-refresh, where the
  /// home screen refreshes charts itself and a pre-warm would duplicate the
  /// bulk request.
  Future<PriceData> _fetchAndSideEffects(
    List<String> currencies, {
    bool prewarmCharts = true,
  }) async {
    final priceData =
        await ref.read(priceServiceProvider).fetchCurrentPrice(currencies);

    if (currencies.isNotEmpty) {
      if (prewarmCharts) {
        ref.read(priceServiceProvider).prewarmCharts(currencies.first).ignore();
      }
      _saveWidgetChartData(currencies.first).ignore();
    }

    final portfolio = ref.read(portfolioProvider);
    final dcaEntries = ref.read(dcaProvider);
    WidgetService.update(
      priceData: priceData,
      portfolio: portfolio,
      dcaEntries: dcaEntries,
    ).ignore();

    return priceData;
  }

  /// Fetches fresh data after `build()` has already returned cached data.
  /// Updates `state` silently when complete; errors are swallowed so cached
  /// data keeps showing rather than replacing it with an error state.
  void _backgroundRefresh(List<String> currencies) {
    Future(() async {
      try {
        final fresh = await _fetchAndSideEffects(currencies);
        if (!_disposed && state is AsyncData) state = AsyncData(fresh);
      } catch (_) {
        // Keep showing cached data — do not surface an error.
      }
    });
  }

  void _startRefreshTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(AppConstants.priceRefreshInterval, (_) {
      ref.invalidateSelf();
    });
  }

  /// Re-runs the price fetch.
  ///
  /// Without [force] this just invalidates the provider, which rebuilds from
  /// cache immediately and refreshes in the background — right for timers and
  /// incidental refreshes.
  ///
  /// With [force] the fetch runs on this instance and the returned future does
  /// not complete until fresh data has actually landed, so pull-to-refresh can
  /// await it. Deliberately avoids `invalidateSelf()`: that disposes this
  /// notifier, leaving nothing valid to await.
  ///
  /// `state` is left untouched until the result arrives, so existing data stays
  /// on screen behind the RefreshIndicator rather than flashing loading cards.
  Future<void> refresh({bool force = false}) async {
    _timer?.cancel();

    if (!force) {
      ref.invalidateSelf();
      return;
    }

    try {
      final currencies = ref.read(portfolioProvider).selectedCurrencies;
      final fresh =
          await _fetchAndSideEffects(currencies, prewarmCharts: false);
      if (!_disposed) state = AsyncData(fresh);
    } catch (e) {
      // A failed manual refresh should not replace working data with an error.
      if (kDebugMode) debugPrint('[PriceNotifier] forced refresh failed: $e');
    } finally {
      if (!_disposed) _startRefreshTimer();
    }
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
      if (kDebugMode) {
        debugPrint('[PriceNotifier] widget chart save failed: $e');
      }
    }
  }
}

// Chart data — family provider keyed by (currency, days).
// Not autoDisposed: keeps data in memory for the session to avoid re-fetching
// on every rebuild / timeframe switch and to respect CoinGecko rate limits.
final chartDataProvider = FutureProvider
    .family<List<(DateTime, double)>, (String, int)>((ref, params) async {
  final (currency, days) = params;

  // When the service hands back a stale cache entry it refreshes in the
  // background; re-read once that lands so the chart repaints instead of
  // holding the stale series for the rest of the session.
  //
  // This cannot loop: the background fetch writes a fresh timestamp, so the
  // rebuild takes the fresh-cache path and schedules no further refresh.
  var disposed = false;
  ref.onDispose(() => disposed = true);

  return ref.read(priceServiceProvider).fetchChartData(
        currency,
        days,
        onRefreshed: () {
          if (!disposed) ref.invalidateSelf();
        },
      );
});

// Selected timeframe for the chart — 1, 7, 30, or 365 days.
final selectedTimeframeDaysProvider = StateProvider<int>((ref) => 7);
