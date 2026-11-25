class AppConstants {
  /// Web guide linked from the add-wallet sheet (descriptor kind).
  static const bitkeyGuideUrl = 'https://bitbag.app/bitkey-watch-only/';

  // Build flavor — injected at build time via --dart-define=FLAVOR=direct|store.
  // direct: all non-Play/App-Store channels (website APK, F-Droid, sideload) — OpenNode/Ed25519 unlock.
  // store: Google Play + App Store — in_app_purchase replaces the token path.
  static const kFlavor =
      String.fromEnvironment('FLAVOR', defaultValue: 'direct');

  // App version — keep in sync with pubspec.yaml
  static const String appVersion = '2.0.1';

  // Store product ID for the Pro one-time purchase (store flavor only).
  static const String iapProProductId = 'bag_pro';

  // SharedPreferences keys
  // NOTE: keyBtcAmount is now a *secure storage* key — the total holding is
  // financial data. Read/write it through wallet_store.dart, never prefs.
  static const String keyBtcAmount = 'btc_amount';
  static const String keySelectedCurrencies = 'selected_currencies';
  static const String keyThemeMode = 'theme_mode';
  static const String keyOnboardingComplete = 'onboarding_complete';
  // Retired (M-12): onboarding's "How do you hold your bitcoin?" answer,
  // written only by unreleased 2.0.0 development builds. Never written now;
  // removeRetiredPrefs deletes it.
  static const String keyOnboardingHolding = 'onboarding_holding';
  // Set by "Not now" on the home "Let Bag read your wallet" card; once true,
  // the card never comes back.
  static const String keyHomeWalletCardDismissed = 'home_wallet_card_dismissed';
  static const String keySatsMode = 'sats_mode';
  static const String keyProUnlocked = 'pro_unlocked';
  // Stored in FlutterSecureStorage (Android Keystore AES-256-GCM), NOT SharedPreferences.
  // Re-verified on every cold start to confirm the signature is still valid.
  static const String keyLicenseToken = 'license_token';
  static const String keyPriceAlerts = 'price_alerts';

  // Watch-only wallets.
  //
  // Wallet metadata (labels, per-wallet balances, scan cursors) now lives in
  // FlutterSecureStorage — see `biometric_storage_service.dart`. This key is
  // only read once, to migrate pre-1.3.0 installs out of SharedPreferences.
  @Deprecated('Migrated to secure storage; read only by readWalletsMetadata()')
  static const String keyWalletsLegacy = 'wallets';

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
  // Only the on/off bool lives in prefs; host, port and credentials are in
  // secure storage under keyNetworkProxy.
  static const String keyUseProxy = 'use_proxy';
  static const String keyNetworkProxy = 'network_proxy';

  /// The iOS App Group the app and its widget extension share: home_widget's
  /// UserDefaults suite, and the keychain access group of the proxy entry
  /// above. ios/BagWidget/BagWidget.swift and the entitlements name it too.
  static const String iosAppGroupId = 'group.app.bitbag.shared';
  // Whether the one-time migration hint is due (TorService.recordOrbotMigration
  // and TorService.showOrbotMigrationHint), one key per platform. Written
  // once, on the first launch with built-in Tor, and never re-evaluated:
  // 'show' if Tor was already on (it ran through another app), else 'none';
  // dismissing the hint sets 'dismissed'. Both keys take the same values.
  static const String keyIosTorMigrated = 'ios_tor_migrated';
  static const String keyAndroidTorMigrated = 'android_tor_migrated';
  static const String torMigratedShow = 'show';
  static const String torMigratedNone = 'none';
  static const String torMigratedDismissed = 'dismissed';

  // Block explorer base URLs
  static const String explorerBlockstream = 'https://blockstream.info/api';
  static const String explorerMempool = 'https://mempool.space/api';
  // mempool.space's own onion service (listed on mempool.space). Used for
  // the mempool preset over Tor, because mempool.space refuses connections
  // from Tor exits. An onion address authenticates the server itself, so
  // plain http is end-to-end encrypted here.
  static const String explorerMempoolOnion =
      'http://mempoolhqx4isw62xs7abwphsq7ldayuidyx2v2oethdhhj6mlo2r6ad.onion/api';

  // The embedded Tor client's SOCKS5 host. Its port moves after every
  // restart, and may belong to another isolate's client: read
  // TorHost.port() per connection.
  static const String torHost = '127.0.0.1';

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

  // Scan timing: every tick checks the mempool; the full balance scan
  // (BIP32 + all addresses) runs every sentinelFullScanEveryNTicks ticks,
  // so every 10 min at the 2-min sentinelScanIntervalMinutes.
  static const int sentinelFullScanEveryNTicks = 5;

  // Unused addresses watched past each chain's frontier: the next ones on
  // the receive chain (from WalletBalance.nextExternalIndex), for incoming
  // payments, and on the change chain (nextChangeIndex), for a spend's
  // change.
  static const int sentinelFrontierCount = 5;

  // Drop unseen/unconfirmed mempool txids after this many hours.
  static const int sentinelSeenTxMaxAgeHours = 24;

  // Sentinel tick interval (minutes); every tick checks the mempool. A
  // foreground service is not WorkManager, so there is no 15-min OS floor.
  static const int sentinelScanIntervalMinutes = 2;

  // Max minutes Sentinel waits for its private route (Tor or a proxy) before
  // its notification changes to "Paused".
  static const int sentinelRouteMaxWaitMinutes = 60;

  // DCA — the purchase log is encrypted at rest (see services/dca_store.dart).
  // The legacy plaintext box is read once, migrated, then deleted.
  static const String dcaBoxEncrypted = 'dca_entries_v2';
  static const String dcaBoxLegacy = 'dca_entries';

  // Hive
  static const String priceBox = 'price_cache';
  static const String priceHistoryBox = 'price_hist_v2';
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

  /// The chart timeframes the home screen offers, in its order: its
  /// selector's buttons, and what pull-to-refresh and Tor recovery re-read
  /// (`HomeRefresh.chartTimeframeDays`).
  static const chartTimeframes = [
    (label: '1D', days: 1),
    (label: '1W', days: 7),
    (label: '1M', days: 30),
    (label: '1Y', days: 365),
    (label: '5Y', days: timeframe5YDays),
    (label: 'ALL', days: timeframeAllDays),
  ];

  // Chart cache stale durations — older data changes less frequently.
  static const Duration chartStale1D = Duration(minutes: 15);
  static const Duration chartStale1W = Duration(hours: 1);
  static const Duration chartStale1M = Duration(hours: 4);
  static const Duration chartStale1Y = Duration(hours: 24);
  static const Duration chartStale5YAll = Duration(days: 7);

  // Defaults
  static const List<String> defaultCurrencies = ['usd', 'eur', 'gbp'];
  static const Duration priceRefreshInterval = Duration(minutes: 5);
  // bitbag.app's spot answer older than this is skipped (its cron writes
  // every 6 min), so a stalled cron falls through to the next source.
  static const Duration backendSpotMaxAge = Duration(minutes: 15);
  static const int maxSelectedCurrencies = 3;

  // Network Fees (Pro)
  static const String keyShowFeeEstimates = 'show_fee_estimates';
  static const String keyFeeCompact = 'fee_compact_display'; // true = compact row
  static const String keyWidgetShowFee = 'widget_show_fee';
  static const String keyFeeAlerts = 'fee_alerts';
  static const String keyBiometricLock = 'biometric_lock';
  static const String keyFeeCache = 'fee_cache';
  static const Duration feeRefreshInterval = Duration(minutes: 5);

  // Notifications — fee alerts (high priority)
  static const String notifChannelIdFeeAlerts = 'fee_alerts';
  static const String notifChannelNameFeeAlerts = 'Network Fee Alerts';
  static const String notifChannelDescFeeAlerts =
      'Notifies when Bitcoin network fees hit your target';
}
