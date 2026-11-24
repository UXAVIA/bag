import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
import 'core/licenses/register_licenses.dart';
import 'providers/network_settings_provider.dart';
import 'providers/portfolio_provider.dart';
import 'providers/shared_preferences_provider.dart';
import 'providers/wallets_provider.dart';
import 'models/network_route.dart';
import 'models/network_settings.dart';
import 'services/network/network_route_store.dart';
import 'services/wallet/wallet_store.dart';
import 'services/dca_store.dart';
import 'services/notification_service.dart';
import 'services/price_history_store.dart';
import 'services/price_service.dart';
import 'services/retired_prefs.dart';
import 'services/sentinel_service.dart';
import 'services/tor_host.dart';
import 'services/tor_service.dart';
import 'services/widget_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Rust crates and Android libraries, next to the Dart packages Flutter
  // lists itself. Read only when the licence page opens.
  registerThirdPartyLicenses();

  await WidgetService.initialise();
  // Not awaited: on iOS it reads the route first (at most 3 s), and nothing
  // before runApp needs it. It never throws.
  unawaited(WidgetService.scheduleRefresh());
  if (Platform.isAndroid) {
    SentinelService.initialise(); // register config before restoreIfEnabled / BootReceiver
    await SentinelService.restoreIfEnabled();
  }
  await NotificationService.initialise();
  await Hive.initFlutter();
  await Hive.openBox<String>(AppConstants.priceBox);
  await openEncryptedDcaBox();
  // After the DCA box, and never throws: it can't stand in the DCA log's way.
  await PriceHistoryStore.open();
  await PriceService.seedFromAssets();

  final prefs = await SharedPreferences.getInstance();
  await removeRetiredPrefs(prefs);
  final onboardingComplete =
      prefs.getBool(AppConstants.keyOnboardingComplete) ?? false;
  // Remember, once, whether this install had Tor on before built-in Tor
  // replaced the separate Tor app — only those users get the hint
  // (TorService.showOrbotMigrationHint).
  await TorService.recordOrbotMigration(prefs);

  // Wallet metadata (labels + balances) and the aggregate BTC amount are
  // encrypted at rest, so they have to be decrypted before the first frame —
  // otherwise the portfolio would flash empty on every cold start.
  final wallets = await loadWalletsFromStorage();
  final btcAmount = await loadBtcAmount();
  final explorerUrl = await loadExplorerCustomUrl();
  // An unreadable proxy entry becomes null: a use_proxy user then resolves to
  // MisconfiguredProxyRoute and every network path fails closed.
  final proxyConfig = await loadProxyConfigOrNull();

  // Tor runs inside the app. Start it now, not awaited — a bootstrap takes
  // tens of seconds, and cached prices show meanwhile; every Tor request is
  // refused until it is ready.
  final route = NetworkSettings(
    useTor: prefs.getBool(AppConstants.keyUseTor) ?? false,
    useProxy: prefs.getBool(AppConstants.keyUseProxy) ?? false,
    proxy: proxyConfig,
  ).route;
  if (route is TorRoute) {
    TorService.followRoute(route);
  } else {
    // Tells TorHost this is the UI, whose route it obeys, and stops a Tor
    // client another isolate of the process may still run (M9).
    TorHost.routeChanged(tor: false);
  }

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        initialWalletsProvider.overrideWithValue(wallets),
        initialBtcAmountProvider.overrideWithValue(btcAmount),
        initialExplorerUrlProvider.overrideWithValue(explorerUrl),
        initialProxyConfigProvider.overrideWithValue(proxyConfig),
      ],
      child: BagApp(onboardingComplete: onboardingComplete),
    ),
  );
}
