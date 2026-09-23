import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
import 'providers/network_settings_provider.dart';
import 'providers/portfolio_provider.dart';
import 'providers/shared_preferences_provider.dart';
import 'providers/wallets_provider.dart';
import 'services/wallet/wallet_store.dart';
import 'services/dca_store.dart';
import 'services/notification_service.dart';
import 'services/price_service.dart';
import 'services/sentinel_service.dart';
import 'services/widget_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await WidgetService.initialise();
  await WidgetService.scheduleRefresh();
  if (Platform.isAndroid) {
    SentinelService.initialise(); // register config before restoreIfEnabled / BootReceiver
    await SentinelService.restoreIfEnabled();
  }
  await NotificationService.initialise();
  await Hive.initFlutter();
  await Hive.openBox<String>(AppConstants.priceBox);
  await openEncryptedDcaBox();
  await PriceService.seedFromAssets();

  final prefs = await SharedPreferences.getInstance();
  final onboardingComplete =
      prefs.getBool(AppConstants.keyOnboardingComplete) ?? false;

  // Wallet metadata (labels + balances) and the aggregate BTC amount are
  // encrypted at rest, so they have to be decrypted before the first frame —
  // otherwise the portfolio would flash empty on every cold start.
  final wallets = await loadWalletsFromStorage();
  final btcAmount = await loadBtcAmount();
  final explorerUrl = await loadExplorerCustomUrl();

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        initialWalletsProvider.overrideWithValue(wallets),
        initialBtcAmountProvider.overrideWithValue(btcAmount),
        initialExplorerUrlProvider.overrideWithValue(explorerUrl),
      ],
      child: BagApp(onboardingComplete: onboardingComplete),
    ),
  );
}
