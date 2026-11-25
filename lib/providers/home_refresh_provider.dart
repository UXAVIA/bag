import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_constants.dart';
import '../services/price_service.dart';
import 'fee_provider.dart';
import 'portfolio_provider.dart';
import 'price_provider.dart';
import 'wallets_provider.dart';

/// What the home screen's pull-to-refresh refreshes, in one place: the
/// gesture calls it, and so does `routeStatusProvider` when the built-in
/// Tor becomes ready (everything that ran while it was connecting was
/// refused).
final homeRefreshProvider = Provider<HomeRefresh>(HomeRefresh.new);

class HomeRefresh {
  HomeRefresh(this._ref);

  final Ref _ref;

  /// Every chart timeframe the home screen offers.
  ///
  /// 1D/7D/30D come from bitbag.app's bulk chart endpoint, one request for
  /// all three. 1Y/5Y/ALL come from Kraken and refresh on their own
  /// staleness schedule (24 h for 1Y, 7 d for 5Y/ALL): re-reading them only
  /// fetches once their cache has aged out.
  static final List<int> chartTimeframeDays = List.unmodifiable(
      [for (final timeframe in AppConstants.chartTimeframes) timeframe.days]);

  /// Charts, spot price and wallet balances refresh concurrently, so a
  /// pull-to-refresh spinner reflects the slowest rather than their sum.
  ///
  /// `fetchAllCharts` pulls 1D/7D/30D in a single request, so switching
  /// timeframes afterwards needs no further fetch. Every timeframe is then
  /// re-read from the updated cache: a fresh one makes that a no-op, a stale
  /// one kicks off a background refresh that repaints when it lands.
  ///
  /// [afterRouteRecovered]: the private route has just come back (the
  /// built-in Tor client reached ready). Wallets whose scan the route
  /// refused are rescanned even if their last good scan is recent, the fee
  /// estimate is re-fetched (the poll that ran meanwhile came back empty),
  /// and a failed bulk chart fetch doesn't stop the charts from being
  /// re-read. Pull-to-refresh leaves fees to their own timer, as before.
  Future<void> refreshAll({bool afterRouteRecovered = false}) async {
    final currency = _ref.read(portfolioProvider).primaryCurrency;

    var charts = _ref.read(priceServiceProvider).fetchAllCharts(currency);
    if (afterRouteRecovered) {
      charts = charts.catchError((Object e) {
        if (kDebugMode) debugPrint('[HomeRefresh] bulk charts failed: $e');
      });
    }
    await Future.wait([
      charts,
      _ref.read(priceProvider.notifier).refresh(force: true),
      _ref
          .read(walletsProvider.notifier)
          .scanAllIfStale(includeRouteBlocked: afterRouteRecovered),
      // Only if something keeps the estimate alive: reading it would start
      // a poll nobody asked for.
      if (afterRouteRecovered && _ref.exists(feeProvider))
        _ref.read(feeProvider.notifier).refresh(),
    ]);

    for (final days in chartTimeframeDays) {
      _ref.invalidate(chartDataProvider((currency, days)));
    }
  }
}
