import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../models/portfolio.dart';
import 'shared_preferences_provider.dart';

final portfolioProvider = NotifierProvider<PortfolioNotifier, Portfolio>(
  PortfolioNotifier.new,
);

class PortfolioNotifier extends Notifier<Portfolio> {
  late SharedPreferences _prefs;

  @override
  Portfolio build() {
    _prefs = ref.read(sharedPreferencesProvider);

    final amount = _prefs.getDouble(AppConstants.keyBtcAmount) ?? 0.0;
    final currencies =
        _prefs.getStringList(AppConstants.keySelectedCurrencies) ??
            List<String>.from(AppConstants.defaultCurrencies);

    return Portfolio(btcAmount: amount, selectedCurrencies: currencies);
  }

  Future<void> setBtcAmount(double amount) async {
    await _prefs.setDouble(AppConstants.keyBtcAmount, amount);
    state = state.copyWith(btcAmount: amount);
  }

  Future<void> setCurrencies(List<String> currencies) async {
    await _prefs.setStringList(AppConstants.keySelectedCurrencies, currencies);
    // Price provider watches portfolioProvider, so changing state auto-triggers
    // a price refetch for the new currency set.
    state = state.copyWith(selectedCurrencies: currencies);
  }
}
