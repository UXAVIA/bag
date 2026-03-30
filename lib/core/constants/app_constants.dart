class AppConstants {
  // Build flavor — injected at build time via --dart-define=FLAVOR=direct|store.
  // direct: all non-Play/App-Store channels (website APK, F-Droid, sideload) — OpenNode/Ed25519 unlock.
  // store: Google Play + App Store — in_app_purchase replaces the token path.
  static const kFlavor =
      String.fromEnvironment('FLAVOR', defaultValue: 'direct');

  // App version — keep in sync with pubspec.yaml
  static const String appVersion = '1.2.2';

  // Store product ID for the Pro one-time purchase (store flavor only).
  static const String iapProProductId = 'bag_pro';

  // SharedPreferences keys
  static const String keyBtcAmount = 'btc_amount';
  static const String keySelectedCurrencies = 'selected_currencies';
  static const String keyThemeMode = 'theme_mode';
  static const String keyOnboardingComplete = 'onboarding_complete';
  static const String keySatsMode = 'sats_mode';
  static const String keyProUnlocked = 'pro_unlocked';
  // Stored in FlutterSecureStorage (Android Keystore AES-256-GCM), NOT SharedPreferences.
  // Re-verified on every cold start to confirm the signature is still valid.
  static const String keyLicenseToken = 'license_token';
  static const String keyPriceAlerts = 'price_alerts';

  // Watch-only wallets (multi-wallet format)
  static const String keyWallets = 'wallets'; // JSON array of WalletEntry metadata

  // Legacy single-wallet keys — kept for migration only, do not write new data here
  static const String keyWalletConnected = 'wallet_connected';
  static const String keyWalletLastSats = 'wallet_last_sats';
  static const String keyWalletLastScanAt = 'wallet_last_scan_at';
  static const String keyWalletUsedAddresses = 'wallet_used_addresses';

  // Bitcoin Health Check — persisted result per wallet
  // Key format: '$keyHealthCheckPrefix{walletId}'
  static const String keyHealthCheckPrefix = 'health_check_';

  // Network / privacy settings
  static const String keyExplorerPreset = 'explorer_preset';
  static const String keyExplorerCustomUrl = 'explorer_custom_url';
  static const String keyUseTor = 'use_tor';

  // Block explorer base URLs
  static const String explorerBlockstream = 'https://blockstream.info/api';
  static const String explorerMempool = 'https://mempool.space/api';

  // Tor SOCKS5 proxy (Orbot default)
  static const String torHost = '127.0.0.1';
  static const int torPort = 9050;

  // Notifications — price alerts
  static const String notifChannelId = 'price_alerts';
  static const String notifChannelName = 'Price Alerts';
  static const String notifChannelDesc = 'Notifies when BTC hits your target price';

  // Notifications — Sentinel foreground service (persistent, silent)
  static const String notifChannelIdSentinelService = 'sentinel_service';
  static const String notifChannelNameSentinelService = 'Sentinel';

  // Notifications — Sentinel balance alerts (high priority)
  static const String notifChannelIdSentinelAlerts = 'sentinel_alerts';
  static const String notifChannelNameSentinelAlerts = 'Sentinel Alerts';
  static const String notifChannelDescSentinelAlerts =
      'Notifies when your wallet balance changes unexpectedly';

  // Sentinel foreground notification ID (fixed — updated in place, never dismissed)
  static const int sentinelServiceNotifId = 1001;

  // Sentinel SharedPreferences keys
  static const String keySentinelEnabled = 'sentinel_enabled';
  static const String keySentinelLastScan = 'sentinel_last_scan';
  // JSON map of walletId → lastKnownSats (int), used for balance diffing
  static const String keySentinelBalances = 'sentinel_balances';

  // Sentinel mempool monitoring
  // JSON map: address → {walletId, walletLabel} for addresses to watch
  static const String keySentinelWatchMap = 'sentinel_watch_map';
  // JSON map: txid → {walletId, walletLabel, dir, sats, seenAt, notifId} for deduplication
  static const String keySentinelSeenTxids = 'sentinel_seen_txids';

  // Scan timing: short interval drives mempool checks every tick;
  // full balance scan (BIP32 + all addresses) runs every kFullScanTicks ticks.
  // sentinelScanIntervalMinutes = 2 (down from 10)
  // sentinelFullScanEveryNTicks = 5  → full scan every 10 min
  static const int sentinelFullScanEveryNTicks = 5;

  // Extra external gap addresses beyond lastExternalIndex to watch for incoming.
  static const int sentinelFrontierCount = 5;

  // Drop unseen/unconfirmed mempool txids after this many hours.
  static const int sentinelSeenTxMaxAgeHours = 24;

  // Sentinel scan interval (minutes). Foreground service is not WorkManager —
  // no 15-min OS floor, but 10 min is a sensible balance for battery vs latency.
  static const int sentinelScanIntervalMinutes = 2;

  // Max minutes to wait for Tor before changing notification to "Paused".
  static const int sentinelTorMaxWaitMinutes = 60;

  // DCA
  static const String dcaBox = 'dca_entries';

  // Hive
  static const String priceBox = 'price_cache';
  static const String priceKey = 'latest_price';
  static const String chartKeyPrefix = 'chart_';

  // API
  static const String coinGeckoBase = 'https://api.coingecko.com/api/v3';
  static const String mempoolBase = 'https://mempool.space';
  static const String mempoolPriceUrl = 'https://mempool.space/api/v1/prices';
  static const String bitfinexBase = 'https://api-pub.bitfinex.com/v2';
  static const String bitbagApiBase = 'https://bitbag.app/api';

  // Timeframe sentinel values
  // days > 0 && <= 365 → CoinGecko
  // days == 0          → ALL-time via Kraken (no date filter)
  // days == 1825       → 5Y via Kraken (filtered to last 5 years)
  static const int timeframeAllDays = 0;
  static const int timeframe5YDays = 1825; // 5 × 365

  // Chart cache stale durations — older data changes less frequently.
  static const Duration chartStale1D = Duration(minutes: 15);
  static const Duration chartStale1W = Duration(hours: 1);
  static const Duration chartStale1M = Duration(hours: 4);
  static const Duration chartStale1Y = Duration(hours: 24);
  static const Duration chartStale5YAll = Duration(days: 7);

  // Defaults
  static const List<String> defaultCurrencies = ['usd', 'eur', 'gbp'];
  static const Duration priceRefreshInterval = Duration(minutes: 5);
  static const int maxSelectedCurrencies = 3;

  // Network Fees (Pro)
  static const String keyShowFeeEstimates = 'show_fee_estimates';
  static const String keyFeeCompact = 'fee_compact_display'; // true = compact row
  static const String keyWidgetShowFee = 'widget_show_fee';
  static const String keyFeeAlerts = 'fee_alerts';
  static const String keyBiometricLock = 'biometric_lock';
  static const String keyFeeCache = 'fee_cache';
  static const String mempoolFeesUrl =
      'https://mempool.space/api/v1/fees/recommended';
  static const Duration feeRefreshInterval = Duration(minutes: 5);

  // Notifications — fee alerts (high priority)
  static const String notifChannelIdFeeAlerts = 'fee_alerts';
  static const String notifChannelNameFeeAlerts = 'Network Fee Alerts';
  static const String notifChannelDescFeeAlerts =
      'Notifies when Bitcoin network fees hit your target';
}
