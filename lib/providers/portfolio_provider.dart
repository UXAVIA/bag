import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../models/portfolio.dart';
import '../services/wallet/wallet_store.dart';
import 'shared_preferences_provider.dart';

/// Total BTC amount loaded from secure storage before `runApp`.
///
/// Overridden in `main()` for the same reason as `initialWalletsProvider`:
/// the value is encrypted, so it cannot be read synchronously in `build()`.
/// Defaults to 0 for tests and screenshot builds.
final initialBtcAmountProvider = Provider<double>((ref) => 0.0);

final portfolioProvider = NotifierProvider<PortfolioNotifier, Portfolio>(
  PortfolioNotifier.new,
);

class PortfolioNotifier extends Notifier<Portfolio> {
  late SharedPreferences _prefs;

  @override
  Portfolio build() {
    _prefs = ref.read(sharedPreferencesProvider);

    // Currency selection is a display preference, not financial data — it
    // stays in SharedPreferences. The amount does not.
    final currencies =
        _prefs.getStringList(AppConstants.keySelectedCurrencies) ??
            List<String>.from(AppConstants.defaultCurrencies);

    return Portfolio(
      btcAmount: ref.read(initialBtcAmountProvider),
      selectedCurrencies: currencies,
    );
  }

  Future<void> setBtcAmount(double amount) async {
    await saveBtcAmount(amount);
    state = state.copyWith(btcAmount: amount);
  }

  Future<void> setCurrencies(List<String> currencies) async {
    await _prefs.setStringList(AppConstants.keySelectedCurrencies, currencies);
    // Price provider watches portfolioProvider, so changing state auto-triggers
    // a price refetch for the new currency set.
    state = state.copyWith(selectedCurrencies: currencies);
  }
}
