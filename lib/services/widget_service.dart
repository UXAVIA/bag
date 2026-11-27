import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../core/constants/app_constants.dart';
import '../core/constants/supported_currencies.dart';
import '../core/utils/serial_chain.dart';
import '../models/dca_entry.dart';
import '../models/fee_estimate.dart';
import '../models/network_route.dart';
import '../models/portfolio.dart';
import '../models/price_alert.dart';
import '../models/price_data.dart';
import '../models/wallet_entry.dart';
import 'embedded_tor_service.dart';
import 'fee_service.dart';
import 'network/network_route_store.dart';
import 'network/route_gate.dart';
import 'network/routed_http.dart';
import 'notification_service.dart';
import 'price_service.dart';
import 'sentinel_ios_check.dart';
import 'sentinel_records.dart';
import 'tor_host.dart';
import 'tor_service.dart';
import 'wallet/biometric_storage_service.dart' as bio;
import 'wallet/esplora_client.dart';
import 'wallet/wallet_scanner.dart';
import 'wallet/wallet_store.dart';

const _widgetName = 'BagWidget';
const _androidWidgetName = 'app.bitbag.BagWidget';
const _taskId = 'bag_widget_refresh';
const _widgetChannel = MethodChannel('app.bitbag/widget');

// The widget's freshness (Task A5). Kotlin (BagWidget.kt,
// NativeChartRefreshWorker.kt) and Swift (BagWidget.swift) read these names.
//
// When the price the widget shows was fetched: an int, epoch seconds. The
// data's own fetch time, never "now" for data that wasn't fetched now
// (R-A5d). Read type-safely on both sides: an int lands as an Int or Long
// in HomeWidgetPreferences and as an NSNumber in the App Group. It replaces
// `widget_updated_at`, an "HH:mm" string a `getString` reader shared.
const _keyFetchedAt = 'widget_fetched_at';

// Whether the last fetch attempt got its price through the route (bool).
// The badge is derived from the route flags `writeWidgetRouteFlags` writes;
// this says whether that route is delivering ("Updated" vs "Paused since").
const _keyRouteOk = 'widget_route_ok';

int _epochSeconds(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

/// Redraws the widget from what is saved: WidgetKit reloads its timelines,
/// and Android sends `BagWidget` its update broadcast.
Future<void> _redraw() => HomeWidget.updateWidget(
    name: _widgetName,
    iOSName: _widgetName,
    qualifiedAndroidName: _androidWidgetName);

/// Whether the background task may do Pro work (wallet scans, fee estimates
/// and fee alerts): read from prefs as Sentinel does, since this isolate has
/// no Riverpod. The licence re-check in the app removes the bool when the
/// licence is invalid.
@visibleForTesting
bool backgroundProAllowed(SharedPreferences prefs) =>
    prefs.getBool(AppConstants.keyProUnlocked) ?? false;

/// Whether the iOS background refresh is asked for (spec D2): while Tor is
/// the route, for the widget, or while Sentinel Lite is on with Pro, for its
/// checks, on any route but unreadable proxy settings, which reach nothing.
@visibleForTesting
bool iosBackgroundRunWanted({
  required NetworkRoute route,
  required bool sentinelOn,
  required bool pro,
}) =>
    route is TorRoute ||
    _iosSentinelPartWanted(route: route, sentinelOn: sentinelOn, pro: pro);

/// Whether an iOS run does its Sentinel part: Sentinel Lite on, the Pro bool
/// set, and a route that can carry a request. The route being up (Tor ready,
/// the proxy answering) is checked by the run itself.
bool _iosSentinelPartWanted({
  required NetworkRoute route,
  required bool sentinelOn,
  required bool pro,
}) =>
    sentinelOn && pro && route is! MisconfiguredProxyRoute;

/// [iosBackgroundRunWanted] for [route], with Sentinel Lite and Pro as
/// [prefs] has them; a value of another type reads as off (R20).
bool _iosRunWanted(NetworkRoute route, SharedPreferences prefs) =>
    iosBackgroundRunWanted(
      route: route,
      sentinelOn: prefs.get(AppConstants.keySentinelEnabled) == true,
      pro: prefs.get(AppConstants.keyProUnlocked) == true,
    );

/// The background task's fee work: show the fast fee on the widget, check
/// fee alerts, and (for either) fetch an estimate. All of it is Pro, as in
/// the foreground, where `feeProvider` returns null without Pro and the
/// "Show in widget" switch is in the Pro-only Network fees section. A free
/// user's run fetches no estimate and evaluates no alert, and the widget
/// hides its fee row.
@visibleForTesting
({bool showInWidget, bool checkAlerts}) backgroundFeePlan(
  SharedPreferences prefs,
) {
  final pro = backgroundProAllowed(prefs);
  final alertsRaw = prefs.getString(AppConstants.keyFeeAlerts);
  return (
    showInWidget: pro && (prefs.getBool(AppConstants.keyWidgetShowFee) ?? false),
    checkAlerts: pro && alertsRaw != null && alertsRaw.isNotEmpty,
  );
}

/// Background entry point — runs in a separate Dart isolate via WorkManager.
/// Must be a top-level function annotated vm:entry-point.
@pragma('vm:entry-point')
void backgroundWidgetCallback() {
  final androidTask = _whileTorLeased((taskName, inputData, pastDeadline) async {
    WidgetsFlutterBinding.ensureInitialized();

    // Read portfolio settings from SharedPreferences — safe in background isolate.
    // Reload: this isolate can outlive a settings change, and a cached
    // `use_proxy = false` after the user switched the proxy on would send
    // every request below direct.
    final prefs = await reloadedPrefs();
    // The portfolio amount is encrypted at rest — read it through the store,
    // never straight from SharedPreferences.
    final btcAmount = await loadBtcAmount();
    final currencies =
        prefs.getStringList(AppConstants.keySelectedCurrencies) ??
            AppConstants.defaultCurrencies;
    // An empty stored list falls back as the iOS refresh does (TB-8).
    final currency =
        currencies.isNotEmpty ? currencies.first.toLowerCase() : 'usd';
    final currencyFmt = currencyFormatter(currency);

    // Timeframe is written to Flutter SharedPreferences by the configure activity
    // (key: flutter.widget_timeframe_days) so it's reliably readable here.
    // HomeWidget.getWidgetData uses a platform channel that can fail in background
    // isolates, so we read from the standard prefs instead.
    final timeframeDays = prefs.getInt('widget_timeframe_days') ?? 7;

    // ── Route pre-flight (single probe, shared by all network calls) ──────────
    // Price, chart, fee and wallet scan all use one result — probe once.
    // With Tor or a proxy selected every outbound request MUST go through it.
    // No clearnet fallback — that would leak the user's IP to CoinGecko,
    // Kraken, mempool.space and the block explorer against their explicit choice.
    // With Tor the probe reads the client this run leases (_whileTorLeased).
    final route = await readNetworkRoute(prefs);
    final routeOk = !route.isPrivate ||
        await RouteGate.probe(route) == RouteStatus.available;
    if (!routeOk) {
      if (kDebugMode) debugPrint('[WidgetBg] private route unavailable — skipping network fetches');
    }
    // Single Dio instance for price + chart, routed over the selected route.
    final dio = _backgroundDio(route);

    // A route change reaches this run too (R-6): the route is read again
    // (reloaded prefs) before every stage, every wallet and every write
    // group, and once it is no longer [route] the run stops there, with no
    // further request and no further write ([_stillOnRoute]).
    var routeMoved = false;
    Future<bool> stopForRoute() async =>
        routeMoved || (routeMoved = !await _stillOnRoute(route));
    if (await stopForRoute()) return true;

    // ── Fetch current price ───────────────────────────────────────────────────
    // bitbag.app (multi-source averaged, all 28 currencies), then CoinGecko:
    // the iOS refresh's fetch (_widgetSpot), so the two can't drift.

    double? price;
    double? change24h;
    if (routeOk) {
      final spot = await _widgetSpot(dio, currency);
      price = spot?.price;
      change24h = spot?.change;
    }
    // When the price came in: the widget's `widget_fetched_at` (Task A5).
    final priceFetchedAt = DateTime.now();
    if (await stopForRoute()) return true;
    // The price stage's keys go out now, not with the final batch: a run its
    // deadline cuts off in a later stage (chart, fee, wallets) must not
    // leave the last run's route_ok, price and time behind (M6). Every run
    // says whether its price came through the route (`widget_route_ok`):
    // the price is the headline, so a chart alone doesn't count. The final
    // batch writes the net worth again, after the wallet scan.
    await Future.wait([
      HomeWidget.saveWidgetData<bool>(_keyRouteOk, price != null),
      if (price != null) ...[
        HomeWidget.saveWidgetData<String>(
            'widget_price', currencyFmt.format(price)),
        HomeWidget.saveWidgetData<String>(
          'widget_net_worth',
          btcAmount > 0 ? currencyFmt.format(price * btcAmount) : null,
        ),
        HomeWidget.saveWidgetData<int>(
            _keyFetchedAt, _epochSeconds(priceFetchedAt)),
      ],
    ]);

    // ── Fetch chart data ──────────────────────────────────────────────────────
    // bitbag.app for 1D/7D/30D in its currencies, Kraken otherwise or as its
    // fallback (gold divided by PAXG): the iOS refresh's fetch
    // (_widgetCloses), as the app's PriceService routes it.

    List<double>? chartPrices;
    double? tfChange; // timeframe % change (replaces 24h change if available)
    // Past the job's deadline no new stage starts (I1): not this one, the fee
    // or a further wallet.
    if (await stopForRoute()) return true;
    if (routeOk && !pastDeadline()) {
      chartPrices = await _widgetCloses(dio, currency, timeframeDays);
      if (chartPrices != null) {
        tfChange = WidgetService._timeframeChange(chartPrices);
      }
    }

    // ── Check price alerts ────────────────────────────────────────────────────

    if (await stopForRoute()) return true;
    if (price != null) {
      await _checkAlerts(prefs, currency, price);
    }

    // ── Fetch fees and check fee alerts ──────────────────────────────────────
    // We fetch fees if:
    //   a) There are active fee alerts to check, OR
    //   b) The user has enabled "show fee in widget"
    // and only with Pro (backgroundFeePlan).
    // Route safety is already handled above — reuse routeOk, no second probe.
    final feePlan = backgroundFeePlan(prefs);
    final showFeeInWidget = feePlan.showInWidget;
    final hasActiveFeeAlerts = feePlan.checkAlerts;

    FeeEstimate? feeEstimate;
    if ((showFeeInWidget || hasActiveFeeAlerts) && routeOk && !pastDeadline()) {
      try {
        feeEstimate = await fetchFeeEstimate(dio,
            explorerBase: await resolveExplorerBaseUrl(route));
        if (await stopForRoute()) return true;
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
    // on-device, queries Esplora. Updates the stored wallets and BTC amount
    // (secure storage) so the next app launch picks up fresh balances
    // without waiting for a scan.

    double effectiveBtcAmount = btcAmount;
    final wallets = await loadWalletsFromStorage();
    if (wallets.isNotEmpty) {
      // Build Esplora client from stored network settings (no Riverpod here).
      // A custom URL lives in secure storage, so this has to be awaited.
      final baseUrl = await resolveExplorerBaseUrl(route);

      // Route safety is already handled above — reuse routeOk, no second
      // probe. Skip wallet scans rather than leak the user's IP over clearnet.
      // We do NOT return early — the widget must still be updated so it doesn't
      // go blank when Tor or the proxy is down.
      bool skipWalletScan = !routeOk;
      if (skipWalletScan) {
        if (kDebugMode) debugPrint('[WidgetBg] private route unavailable — skipping wallet scans');
      }
      // Live balances are Pro, as in WalletsNotifier.scan: without it the
      // wallets keep their last balance and nothing is scanned (R-B2g).
      if (!backgroundProAllowed(prefs)) skipWalletScan = true;

      if (!skipWalletScan) {
        final client = EsploraClient(baseUrl: baseUrl, route: route);

        // What this run's scans found, by wallet id: only the scan's own
        // fields, applied onto each wallet as stored when the run saves.
        final scanned = <String, WalletEntry Function(WalletEntry)>{};
        for (final listed in wallets) {
          // Manual entries have no addresses, fresh wallets need no scan,
          // and past the job's deadline no further scan starts.
          if (!listed.isWatchOnly || !listed.isStale || pastDeadline()) {
            continue;
          }
          if (await stopForRoute()) return true;
          // The periodic job and the configure activity's one-off can run
          // at once (TB-5): the other may have scanned this wallet while
          // this run scanned the ones before it, or it may be gone.
          final wallet = await _storedWallet(listed.id);
          if (wallet == null || !wallet.isWatchOnly || !wallet.isStale) {
            continue;
          }

          try {
            final secret = await bio.readWalletSecretForScanningById(wallet.id);
            if (secret == null) continue;
            final source = buildAddressSource(wallet.kind, secret);
            final balance = await scanWallet(source, client);
            final scannedAt = DateTime.now();
            scanned[wallet.id] = (current) => current.copyWith(
              lastSats: balance.totalSats,
              lastScanAt: scannedAt,
              usedAddresses: balance.usedAddressCount,
              lastExternalIndex: balance.lastExternalIndex,
              lastChangeIndex: balance.lastChangeIndex,
              scanError: null,
            );
            // Never log the label or the balance — the widget isolate's log
            // output is readable by anyone with adb access on a dev device.
            if (kDebugMode) debugPrint('[WidgetBg] wallet scanned');
          } on EsploraException catch (e) {
            if (kDebugMode) debugPrint('[WidgetBg] scan failed: $e');
          } catch (e) {
            if (kDebugMode) debugPrint('[WidgetBg] scan error: $e');
          }
        }

        // Persist and compute the total from the wallets as stored now, with
        // this run's scans in them: a wallet the other run scanned, or the
        // user added or removed, meanwhile is kept as it is (TB-5). A scanned
        // wallet gets only the scan's fields (balance, used addresses,
        // indices, scan time, no error), so an edit made meanwhile, such as
        // a rename, is kept, not reverted to the run's snapshot of it.
        if (await stopForRoute()) return true;
        final updatedWallets = [
          for (final w in await loadWalletsFromStorage())
            scanned[w.id]?.call(w) ?? w,
        ];
        await saveWalletsToStorage(updatedWallets);
        final totalSats =
            updatedWallets.fold<int>(0, (s, w) => s + (w.lastSats ?? 0));
        if (totalSats > 0) {
          await saveBtcAmount(totalSats / 1e8);
          effectiveBtcAmount = totalSats / 1e8;
        }
      } else {
        // No scan (the private route is down, or no Pro): use cached wallet
        // sats for net worth display.
        final totalSats = wallets.fold<int>(0, (s, w) => s + (w.lastSats ?? 0));
        if (totalSats > 0) effectiveBtcAmount = totalSats / 1e8;
      }
    }

    // ── Save to widget SharedPreferences and redraw ───────────────────────────

    if (await stopForRoute()) return true;

    // The timeframe may have changed while this run fetched (the configure
    // activity, M5): a chart for the old one would be mislabelled, so it
    // isn't written, and the change shown is the 24 h one.
    if (chartPrices != null) {
      await prefs.reload();
      if ((prefs.getInt('widget_timeframe_days') ?? 7) != timeframeDays) {
        chartPrices = null;
        tfChange = null;
      }
    }

    final displayChange = tfChange ?? change24h;

    // No fake freshness (R-A3a). A run that got no price (the route was
    // unavailable, or every source failed) blanks nothing and stamps no
    // time: the widget keeps its last values and the time they are from.
    // Only what this run fetched is written, and a fee row switched off
    // is still hidden. The price, its time and route_ok went out after the
    // price stage (above).
    await Future.wait([
      HomeWidget.saveWidgetData<bool>('widget_show_fee', showFeeInWidget),
      if (price != null || feeEstimate != null || !showFeeInWidget)
        HomeWidget.saveWidgetData<String>(
          'widget_fast_fee',
          showFeeInWidget && feeEstimate != null
              ? WidgetService._formatFee(feeEstimate)
              : null,
        ),
      if (price != null)
        HomeWidget.saveWidgetData<String>(
          'widget_net_worth',
          effectiveBtcAmount > 0
              ? currencyFmt.format(price * effectiveBtcAmount)
              : null,
        ),
      if (price != null || displayChange != null) ...[
        HomeWidget.saveWidgetData<String>(
          'widget_change',
          displayChange != null
              ? WidgetService._formatChange(displayChange)
              : null,
        ),
        HomeWidget.saveWidgetData<bool>(
            'widget_change_positive', displayChange != null && displayChange >= 0),
      ],
      if (chartPrices != null)
        HomeWidget.saveWidgetData<String>(
            'widget_chart_prices', jsonEncode(chartPrices)),
    ]);

    await _redraw();

    if (kDebugMode) debugPrint('[WidgetBg] updated — BTC $currency: $price');
    return true;
  });
  // On iOS the plugin runs this callback in a background engine of its own
  // for the BGAppRefreshTask [iosWidgetRefreshTaskId] (Task A4): the widget
  // refresh, fetching what the widget shows and nothing else (R-A4c), and
  // Sentinel Lite's checks. Android runs the job above.
  Workmanager().executeTask((taskName, inputData) => TorService.isIOS
      ? _iosWidgetRefresh(taskName)
      : androidTask(taskName, inputData));
}

// ── iOS: the widget's background refresh (Task A4) ─────────────────────────

/// The BGTaskScheduler identifier of the iOS widget refresh. The same string
/// is registered in ios/Runner/AppDelegate.swift and listed under
/// `BGTaskSchedulerPermittedIdentifiers` in ios/Runner/Info.plist; the three
/// must agree, or iOS never runs the task.
const iosWidgetRefreshTaskId = 'app.bitbag.widget-refresh';

/// The iOS run's deadline, from the callback's start. iOS gives a background
/// app refresh about 30 s and may end an app whose task overruns. Past it no
/// request starts, those still running are cancelled, and the run returns
/// success.
const iosBackgroundTaskBudget = Duration(seconds: 25);

/// How long the iOS run waits for Tor to be ready. The route check before it
/// gets the rest of [iosBackgroundTaskBudget] (3 s), so the wait always ends
/// inside the run's deadline.
const iosBackgroundTorBudget = Duration(seconds: 22);

/// At most this long for the iOS run's Tor lease to be given back, and never
/// past [iosBackgroundTaskBudget]. The native stop goes out at the start of
/// the release, so connections see port -1 at once either way.
const iosBackgroundReleaseBudget = Duration(seconds: 4);

/// No Sentinel request of the iOS run starts later than this before its
/// deadline (spec D5): the time kept for saving the check's state and
/// showing its alerts.
const iosSentinelSaveMargin = Duration(seconds: 4);

/// This long before the iOS run's deadline its Sentinel check is ended
/// (R19): the Esplora client is closed, so an address still in flight fails
/// and keeps its old counts, and the check returns what it found. One hung
/// request (a private route allows 60 s) would otherwise hold the check
/// past the deadline, and the run would save nothing, every time.
const iosSentinelSaveCutOff = Duration(seconds: 1);

/// How long after [iosSentinelSaveCutOff] the check may take to wind down
/// (its abandoned requests failing) and still save. A save starts no later,
/// so it has the rest of the run, not a moment before the engine goes.
const iosSentinelWindDown = Duration(milliseconds: 250);

/// The iOS run's one redraw (R28) is issued once both of its parts are done,
/// or this long before its deadline if they aren't by then, so what it
/// wrote early (the price at a few seconds) is drawn even when the other part
/// (a Sentinel save, a hung chart) runs to the end.
const iosRedrawMargin = Duration(milliseconds: 500);

/// iOS's background refresh, in two parts that run at once (spec D2):
/// - the widget part, only while Tor is the route: it fetches what the
///   widget shows (the price, net worth and chart set, and the fee row when
///   it is shown) through the process's one Tor client: the app's, if its UI
///   isolate runs it, or one this run starts. On any other route the widget
///   extension fetches for itself (R-A4d);
/// - the Sentinel part, while Sentinel Lite is on and the Pro bool is set
///   ([_iosSentinelPart]): on Tor through the same lease, on a proxy once
///   the proxy answers its probe, on Direct straight away, and never with
///   unreadable proxy settings.
///
/// Bounded by [iosBackgroundTaskBudget] from its start: the route check gets
/// 3 s, Tor [iosBackgroundTorBudget], the fetches what is left. No Sentinel
/// request starts later than [iosSentinelSaveMargin] before the deadline,
/// and its Esplora client is closed [iosSentinelSaveCutOff] before it, so
/// what it found is saved in time (R19). At the deadline every request still
/// running is cancelled (the widget's token, the Sentinel client closed if it
/// isn't yet), none starts after it, and the run returns success. The lease
/// is given back in `finally`, within what is left of the deadline and at
/// most [iosBackgroundReleaseBudget].
///
/// One redraw per run (R3, R28), whenever it wrote a widget key (the price
/// set, the chart set, the fee row, Sentinel Lite's status), also when a
/// part threw after writing: issued once both parts are done, or at
/// deadline − [iosRedrawMargin] if they aren't by then. A price still
/// missing then is said to be missing just before it (`widget_route_ok`
/// false). The redraw is awaited within the deadline, and no redraw or
/// Sentinel status write is issued after the deadline or once the run has
/// returned.
///
/// Fail closed (Review Focus 3, spec D7): Tor not ready in time means no
/// request and nothing stamped, so the widget keeps its last values and the
/// time they are from; it only says its route is paused (`widget_route_ok`
/// false and, with Sentinel Lite on, `widget_sentinel_ok` false, then one
/// redraw, Task A5). A fetch that fails writes nothing for its part, and a
/// run that got no price says so the same way. A proxy that doesn't answer
/// its probe: no Sentinel request, the status paused.
///
/// A run without the Sentinel part still keeps Sentinel Lite's status true
/// (R33), in the same one redraw: paused while Sentinel Lite is on (no Pro
/// bool, unreadable proxy settings), removed once it is off. A doubtful
/// prefs read does nothing at all.
///
/// The task is asked for only while one of the parts is wanted
/// ([iosBackgroundRunWanted], I3), so a run that wants neither cancels the
/// next run the plugin has already asked for. A run that throws logs the
/// error's type and still succeeds; the lease is given back either way (M1).
Future<bool> _iosWidgetRefresh(String taskName) async {
  // The only task registered on iOS. Anything else (the legacy background
  // fetch, which BGTaskSchedulerPermittedIdentifiers switches off) is not
  // ours to run.
  if (taskName != iosWidgetRefreshTaskId) return true;
  final budget = (kReleaseMode ? null : WidgetService.debugIosTaskBudget) ??
      iosBackgroundTaskBudget;
  final cancel = CancelToken();
  // The Sentinel part's Esplora client, once built.
  final explorers = <EsploraClient>[];
  void closeExplorers() {
    for (final client in explorers) {
      if (!client.isClosed) client.close();
    }
  }

  final expired = Completer<bool>();
  final deadline = Timer(budget, () {
    if (kDebugMode) debugPrint('[WidgetBg] iOS refresh deadline reached');
    cancel.cancel('the iOS refresh deadline passed');
    closeExplorers();
    expired.complete(true);
  });
  // Past it the Sentinel part starts no request. A budget inside the margin
  // (a test's) leaves it no time at all.
  final sentinelWindow = budget - iosSentinelSaveMargin;
  final sentinelCutOff =
      sentinelWindow > Duration.zero ? Timer(sentinelWindow, () {}) : null;
  // At the save cut-off the check is ended; it may save until its wind-down
  // is over (R19).
  final saveCutOffAt = budget - iosSentinelSaveCutOff;
  final sentinelSaveCutOff = Timer(
    saveCutOffAt > Duration.zero ? saveCutOffAt : Duration.zero,
    closeExplorers,
  );
  final sentinelSaveWindow = Timer(
    saveCutOffAt + iosSentinelWindDown > Duration.zero
        ? saveCutOffAt + iosSentinelWindDown
        : Duration.zero,
    () {},
  );
  bool pastDeadline() => !deadline.isActive;
  // The run's one redraw (R3, R28), for whatever it wrote: the widget
  // part's keys and Sentinel Lite's status. Issued once both parts are done,
  // or at deadline − [iosRedrawMargin] if they aren't, whichever comes
  // first, and only before the deadline: once it passes, or the run has
  // returned (the timer is cancelled in `finally`), no redraw and no
  // Sentinel status write is issued.
  var wroteKey = false;
  var ended = false;
  void noteWrite() => wroteKey = true;
  bool mayWrite() => !ended && deadline.isActive;
  Future<void>? redraw;
  Future<void> redrawOnce() {
    if (redraw != null) return redraw!;
    if (!wroteKey || !mayWrite()) return Future<void>.value();
    return redraw = _redraw().catchError((Object e) {
      debugPrint('[WidgetBg] iOS redraw failed: ${e.runtimeType}');
    });
  }

  // What the widget part still has to say before the due redraw: that the
  // price hasn't come (Task A5), so the redraw shows the route paused.
  Future<void> Function()? beforeDueRedraw;
  Future<void> dueRedraw() async {
    try {
      await beforeDueRedraw?.call();
    } catch (e) {
      debugPrint('[WidgetBg] iOS no-price write failed: ${e.runtimeType}');
    }
    await redrawOnce();
  }

  final redrawAt = budget - iosRedrawMargin;
  final redrawDue = Timer(
    redrawAt > Duration.zero ? redrawAt : Duration.zero,
    () => unawaited(dueRedraw()),
  );
  TorHostLease? lease;
  try {
    // A fresh route read; a doubtful one does nothing at all.
    final read = await _iosRouteRead();
    if (read == null) return true;
    final route = read.route;
    final tor = route is TorRoute;
    final sentinel = _iosSentinelPartWanted(
      route: route,
      sentinelOn: read.sentinelOn,
      pro: read.pro,
    );
    // Sentinel Lite's widget status (Task 7), which the run's one redraw
    // draws.
    Future<void> sentinelStatus(bool? checked) async {
      if (await _saveIosSentinelStatus(checked, mayWrite: mayWrite)) {
        noteWrite();
      }
    }

    // The status of a run that checks nothing (R33): paused while Sentinel
    // Lite is on, none while it is off.
    Future<void> notCheckedStatus() async {
      if (await _saveIosSentinelNotChecked(
        sentinelOn: read.sentinelOn,
        mayWrite: mayWrite,
      )) {
        noteWrite();
      }
    }

    if (!tor && !sentinel) {
      // Neither part: the status says so in one redraw, then the schedule
      // ends.
      await Future.any<Object?>([notCheckedStatus(), expired.future]);
      await Future.any<Object?>([redrawOnce(), expired.future]);
      await Future.any<Object?>([
        WidgetService._iosRefreshFollows(want: false),
        expired.future,
      ]);
      return true;
    }

    // The Sentinel part, then its widget status.
    Future<void> sentinelPart() => _iosSentinelPart(
          route: route,
          mayStart: () => sentinelCutOff?.isActive ?? false,
          maySave: () => sentinelSaveWindow.isActive,
          onClient: (client) {
            explorers.add(client);
            // Built after the save cut-off: closed at once.
            if (!sentinelSaveCutOff.isActive) closeExplorers();
          },
        ).then(sentinelStatus);
    if (!tor) {
      // The Sentinel part alone, on Direct or a proxy that answers.
      if (route.isPrivate &&
          await Future.any<Object?>([RouteGate.probe(route), expired.future]) !=
              RouteStatus.available) {
        if (kDebugMode) {
          debugPrint('[Sentinel] iOS check: proxy unreachable — no request');
        }
        await Future.any<Object?>([sentinelStatus(false), expired.future]);
        await Future.any<Object?>([redrawOnce(), expired.future]);
        return true;
      }
      await Future.any<Object?>([sentinelPart(), expired.future]);
      await Future.any<Object?>([redrawOnce(), expired.future]);
      return true;
    }
    lease = await TorHost.acquire(
      bootstrapBudget: iosBackgroundTorBudget,
      stillTor: torRouteStillSelected,
    );
    if (pastDeadline() ||
        await RouteGate.probe(const TorRoute()) != RouteStatus.available) {
      if (kDebugMode) {
        debugPrint('[WidgetBg] Tor not ready — no request, the route paused');
      }
      // No request; the widget only says its route is paused (Task A5), and
      // Sentinel Lite, while on, that it couldn't check (R33: none while
      // off): both keys first, then the one redraw `recordNoPrice` makes,
      // and none of it past the deadline (R28).
      Future<void> paused() async {
        await _saveIosSentinelNotChecked(
          sentinelOn: read.sentinelOn,
          mayWrite: mayWrite,
        );
        if (!mayWrite()) return;
        await WidgetService.recordNoPrice(appGroupId: AppConstants.iosAppGroupId);
      }

      await Future.any<Object?>([paused(), expired.future]);
      return true;
    }
    // At the deadline the run stops waiting for the body. Whatever the body
    // still awaits then (a cancelled request, a local call) can start no
    // request: every widget request carries the cancelled token, and the
    // Sentinel part's client is closed. One redraw for both parts (R28),
    // also when the widget part threw after writing.
    final widget = _iosPushWidget(
      cancel,
      onWrote: noteWrite,
      onNoPriceYet: (write) => beforeDueRedraw = write,
    ).then<void>(
      (_) {},
      onError: (Object e) {
        debugPrint('[WidgetBg] iOS widget part failed: ${e.runtimeType}');
      },
    );
    await Future.any<Object?>([
      Future.wait<void>([
        widget,
        if (sentinel) sentinelPart() else notCheckedStatus(),
      ]),
      expired.future,
    ]);
    await Future.any<Object?>([redrawOnce(), expired.future]);
    return true;
  } catch (e) {
    // The type only: a message can carry a host or a path.
    debugPrint('[WidgetBg] iOS refresh failed: ${e.runtimeType}');
    return true;
  } finally {
    ended = true;
    redrawDue.cancel();
    if (lease != null) await _giveBackBy(lease, expired.future);
    deadline.cancel();
    sentinelCutOff?.cancel();
    sentinelSaveCutOff.cancel();
    sentinelSaveWindow.cancel();
    closeExplorers();
    if (!cancel.isCancelled) cancel.cancel('the iOS refresh ended');
  }
}

/// What an iOS background run or launch reads from prefs to decide what to
/// do: the route, and whether Sentinel Lite is on and Pro unlocked.
typedef _IosRouteRead = ({NetworkRoute route, bool sentinelOn, bool pro});

/// The prefs the iOS route reads use: reloaded, since another engine (the
/// app's) may have written them since this one cached them.
Future<SharedPreferences> _iosPrefs() =>
    ((kReleaseMode ? null : WidgetService.debugIosRoutePrefs) ??
        reloadedPrefs)();

/// The route (unreadable proxy settings are `MisconfiguredProxyRoute`),
/// Sentinel Lite and Pro, as a background run or launch on iOS can read
/// them, or null when prefs can't be trusted. That is a read that throws or takes longer
/// than its window (the rest of [iosBackgroundTaskBudget] after
/// [iosBackgroundTorBudget], 3 s), or prefs without
/// [AppConstants.keyOnboardingComplete] (M-a). Only an onboarded install
/// has that key, and replaying onboarding changes only its value. Without
/// it, prefs are those of a fresh install, or what iOS returns before the
/// first unlock after a reboot: empty, or just a key a `main()` running then
/// wrote (`recordOrbotMigration`), which would otherwise read as Direct and
/// cancel the schedule. Null leaves the schedule as it is and starts
/// nothing.
Future<_IosRouteRead?> _iosRouteRead() async {
  Future<_IosRouteRead?> read() async {
    final prefs = await _iosPrefs();
    if (!prefs.containsKey(AppConstants.keyOnboardingComplete)) return null;
    // A value of another type reads as off, not as a doubtful read (R20).
    return (
      route: await readNetworkRoute(prefs),
      sentinelOn: prefs.get(AppConstants.keySentinelEnabled) == true,
      pro: prefs.get(AppConstants.keyProUnlocked) == true,
    );
  }

  try {
    return await read()
        .timeout(iosBackgroundTaskBudget - iosBackgroundTorBudget);
  } catch (_) {
    return null;
  }
}

/// Gives [lease] back, waiting at most [iosBackgroundReleaseBudget] and not
/// past [deadline]. Never throws: an error here must not replace the run's
/// own outcome.
Future<void> _giveBackBy(TorHostLease lease, Future<Object?> deadline) async {
  final cap = Completer<void>();
  final timer = Timer(iosBackgroundReleaseBudget, cap.complete);
  try {
    await Future.any<Object?>([lease.release(), cap.future, deadline]);
  } catch (e) {
    if (kDebugMode) debugPrint('[WidgetBg] Tor lease not given back: $e');
  } finally {
    timer.cancel();
  }
}

/// The iOS run's network part, through the leased Tor client. The price, the
/// widget's chart and, when the row is shown, the fast fee are fetched at
/// once. Each is written as soon as it is in, the price set as
/// [WidgetService.update] writes it, the chart set as `_pushTorChart` does
/// and the fee row as [WidgetService.updateFee] does, and then the widget
/// is redrawn once by the caller, with the Sentinel Lite status when the
/// run has a Sentinel part too (R3). A part that fails writes nothing,
/// except that a run without a price says its route is paused
/// (`widget_route_ok`, Task A5):
/// the price is the headline, so a chart or a fee alone doesn't count.
///
/// The fee row is gated as the Android job gates it,
/// `backgroundFeePlan(prefs).showInWidget` (Pro and "Show in widget" on);
/// otherwise no fee request goes out. Without Pro (it lapsed) the row is
/// hidden as [WidgetService.clearFee] hides it (TB-4); Pro with the row
/// off leaves it as it is, since switching it off clears it at once. The fee
/// request uses the same routed Dio and token as the price. No fee alert is
/// checked here and no estimate is cached in prefs: both belong to the app.
///
/// Left alone: the DCA P&L keys (the log is an encrypted Hive box this engine
/// must not open next to the app's), the route flags (only the app's
/// serialised writer writes them), and the wallets, which are not scanned
/// (R-A4c).
///
/// True when it wrote a key. Each write is also reported to [onWrote] as it
/// finishes, so the caller's one redraw draws it.
Future<bool> _iosPushWidget(
  CancelToken cancel, {
  required void Function() onWrote,
  required void Function(Future<void> Function() write) onNoPriceYet,
}) async {
  // This engine may be the first in the process to use home_widget (iOS
  // launched the app for this task alone), and the group is process-wide.
  await HomeWidget.setAppGroupId(AppConstants.iosAppGroupId);

  // "No price" is said once: by the spot's answer, or, if it hasn't come by
  // the run's redraw (deadline − [iosRedrawMargin], R28), just before that
  // redraw, so the widget reads "Paused since" (Task A5). A price that comes
  // after that is still written; the next redraw shows it.
  var priceSettled = false;
  Future<bool> sayNoPrice() async {
    if (priceSettled) return false;
    priceSettled = true;
    await HomeWidget.saveWidgetData<bool>(_keyRouteOk, false);
    return true;
  }
  // Reloaded by the route check just before.
  final prefs = await SharedPreferences.getInstance();
  final currencies =
      prefs.getStringList(AppConstants.keySelectedCurrencies) ??
          AppConstants.defaultCurrencies;
  final currency =
      currencies.isNotEmpty ? currencies.first.toLowerCase() : 'usd';
  final days = await WidgetService._configuredWidgetDays();
  final showFee = backgroundFeePlan(prefs).showInWidget;
  final pro = backgroundProAllowed(prefs);

  // Every request carries [cancel]. Cancelled at the deadline (and when the
  // run ends), it aborts the requests still running, and Dio never
  // dispatches one whose token is already cancelled: its interceptor chain,
  // which always starts with Dio's own content-type interceptor, fails
  // before the dispatch step. So no request starts past the deadline.
  final dio = _backgroundDio(const TorRoute());

  // Tells [onWrote] once a write has finished, or failed (it may have
  // written part), so the run's redraw (R28) draws it even while another
  // part is still running.
  Future<bool> writing(Future<bool> Function() write) async {
    var wrote = true;
    try {
      return wrote = await write();
    } finally {
      if (wrote) onWrote();
    }
  }

  onNoPriceYet(() => writing(sayNoPrice));

  // Every part runs to its end (Future.wait's default): one that fails
  // fails the call only once the others have written.
  final wrote = await Future.wait([
    _widgetSpot(dio, currency, cancel: cancel).then((spot) {
      // Also after the deadline cancelled it: the refresh got no price.
      if (spot == null) return writing(sayNoPrice);
      priceSettled = true;
      return writing(() async {
        await _saveWidgetSpot(currency, spot, fetchedAt: DateTime.now());
        return true;
      });
    }),
    _widgetCloses(dio, currency, days, cancel: cancel).then((closes) async {
      if (closes == null) return false;
      return writing(
          () => WidgetService._saveWidgetChart(prices: closes, days: days));
    }),
    if (showFee)
      resolveExplorerBaseUrl(const TorRoute())
          .then((base) =>
              fetchFeeEstimate(dio, explorerBase: base, cancelToken: cancel))
          // The custom URL is a keychain read, which can throw before the
          // first unlock: no fee then, but the price and chart still redraw.
          .catchError((Object _) => null)
          .then((fee) async {
        if (fee == null) return false;
        return writing(() async {
          await WidgetService._saveFee(fee);
          return true;
        });
      }),
    if (!pro) writing(WidgetService._hideFeeRowIfShown),
  ]);
  if (kDebugMode) debugPrint('[WidgetBg] iOS refresh done: $wrote');
  return wrote.contains(true);
}

/// The iOS run's Sentinel part (Sentinel Lite, spec D4–D7): checks the
/// watched addresses with [runIosSentinelCheck] over [route], saves what it
/// found and shows the alerts.
///
/// - The watch map, the seen records and the check's own state
///   (`sentinel_ios_activity`) come from the keychain. A read that fails
///   (before the first unlock after a reboot) means no check at all: no
///   request, nothing written (D7). A blob that isn't in its format reads as
///   empty: the state (R10; it only re-baselines counts, which alerts nothing
///   for confirmed history) and, as Android's service reads them, the seen
///   records and the watch map. No wallet on the watch map: nothing to do.
/// - One single-attempt [EsploraClient] to the user's explorer, handed to
///   [onClient] so the run closes it at the save cut-off
///   ([iosSentinelSaveCutOff], R19): an address still in flight then fails
///   and keeps its old counts, and what the others found is still saved. At
///   most 2 requests at a time over a private route, 4 direct; none once
///   [mayStart] says no.
/// - Before each address the route is read again, with Sentinel Lite and
///   Pro ([_iosSentinelStillWanted]); a change stops the check.
/// - What it found is saved only if the check wasn't stopped, at least one
///   address answered, the save may still start ([maySave]: until the save
///   cut-off's wind-down, so a save never starts in the moments before the
///   engine goes), and nothing changed under it: the route, Sentinel Lite, Pro,
///   and no wallet of the watch map removed (its records would come back
///   otherwise). Then the state and the seen records are written, and only
///   then the alerts shown, so a run iOS ends after an alert never alerts
///   twice; `sentinel_last_scan` is stamped last. A run that saves nothing
///   shows nothing, and the next run finds the same transactions again.
/// - The one exception to R16 (R37): a run in which no address answered but
///   which moved the round-robin on ([IosSentinelResult.advanced]: it
///   deferred an address that goes first but hangs, or its cursor passed
///   addresses that hung) writes the state alone, after the same checks, and
///   still reads paused. Without it, addresses that hang every run would take
///   its first requests every run. Nothing else is written, shown or
///   stamped (no address answered, so nothing was found).
///
/// Answers what the widget's Sentinel Lite status should say
/// ([_saveIosSentinelStatus], Task 7): true when it checked and saved, false
/// when it was wanted but couldn't (the keychain unreadable, nothing
/// answered, its state saved alone or not, stopped by a change of route,
/// Sentinel Lite or Pro, or out of time), null when there is nothing to say
/// (no wallet on the watch map, or one removed during the check, which the
/// next run checks again).
///
/// Never throws. Logs carry no address, txid, amount, label or message:
/// counts and error types only.
Future<bool?> _iosSentinelPart({
  required NetworkRoute route,
  required bool Function() mayStart,
  required bool Function() maySave,
  required void Function(EsploraClient client) onClient,
}) async {
  try {
    if (!mayStart()) return false;
    final Map<String, SentinelWatchEntry> watchMap;
    final Map<String, SentinelSeenTx> seen;
    final IosSentinelState state;
    final String baseUrl;
    try {
      watchMap = await loadSentinelWatchMap();
      // Nothing watched: no entry, or only retired ones past their 30 days
      // (R31), which the check skips.
      final now = DateTime.now();
      if (watchMap.values.every((e) => e.expiredAt(now))) return null;
      seen = _decodeSentinelSeen(
        await bio.readSecureBlob(AppConstants.keySentinelSeenTxids),
      );
      state = _decodeIosSentinelState(
        await bio.readSecureBlob(AppConstants.keySentinelIosActivity),
      );
      // The custom explorer's URL is a keychain read too.
      baseUrl = await resolveExplorerBaseUrl(route);
    } catch (e) {
      debugPrint('[Sentinel] iOS check: keychain unreadable '
          '(${e.runtimeType}), nothing checked');
      return false;
    }
    if (!mayStart()) return false;

    final client = EsploraClient(
      baseUrl: baseUrl,
      route: route,
      singleAttempt: true,
    );
    onClient(client);
    final IosSentinelResult result;
    try {
      result = await runIosSentinelCheck(
        explorer: EsploraSentinelExplorer(client),
        watchMap: watchMap,
        seen: seen,
        state: state,
        mayStart: mayStart,
        stillOnRoute: () => _iosSentinelStillWanted(route),
        concurrency: route.isPrivate ? 2 : 4,
      );
    } finally {
      if (!client.isClosed) client.close();
    }
    // Nothing answered: only a run that moved on saves, its state alone
    // (R37).
    final stateOnly = result.checked == 0;
    if (result.stopped || (stateOnly && !result.advanced) || !maySave()) {
      if (kDebugMode) {
        debugPrint('[Sentinel] iOS check saved nothing '
            '(stopped: ${result.stopped}, checked: ${result.checked})');
      }
      return false;
    }
    if (!await _iosSentinelStillWanted(route)) {
      if (kDebugMode) {
        debugPrint('[Sentinel] iOS check: changed during the run, saved '
            'nothing');
      }
      return false;
    }
    if (!await _iosSentinelSameWallets(watchMap)) {
      if (kDebugMode) {
        debugPrint('[Sentinel] iOS check: a wallet was removed during the '
            'run, saved nothing');
      }
      return null;
    }
    if (!maySave()) return false;

    await bio.writeSecureBlob(
      AppConstants.keySentinelIosActivity,
      jsonEncode(result.state.toJson()),
    );
    if (stateOnly) {
      if (kDebugMode) {
        debugPrint('[Sentinel] iOS check: nothing answered, state saved '
            '(${result.state.later.length} waiting for the rotation)');
      }
      return false;
    }
    await bio.writeSecureBlob(
      AppConstants.keySentinelSeenTxids,
      jsonEncode(result.seen.map((k, v) => MapEntry(k, v.toJson()))),
    );
    for (final alert in result.alerts) {
      await NotificationService.showSentinelAlert(alert);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        AppConstants.keySentinelLastScan, DateTime.now().toIso8601String());
    if (kDebugMode) {
      debugPrint('[Sentinel] iOS check: ${result.checked} checked, '
          '${result.alerts.length} alerts');
    }
    return true;
  } catch (e) {
    debugPrint('[Sentinel] iOS check failed: ${e.runtimeType}');
    return false;
  }
}

/// Sentinel Lite's status on the widget (spec D11, Task 7), for a run whose
/// Sentinel part answered [checked] ([_iosSentinelPart]): true writes
/// `widget_sentinel_checked_at` now (epoch seconds) and `widget_sentinel_ok`
/// true; false writes `widget_sentinel_ok` false and leaves the time, unless
/// it is false already (R29: nothing would change, so nothing is written and
/// nothing redrawn); null writes nothing. Nothing either when Sentinel Lite
/// has been switched off since the run began (reloaded prefs): turning it off
/// removed both keys ([WidgetService.clearSentinelStatus], R24), and they
/// must not come back. Each write is issued only while [mayWrite] holds (the
/// run's deadline hasn't passed, R28). A time and a bool only: no balance,
/// address, txid or count.
///
/// True when it issued a write (also one that then failed), so the run
/// redraws. Never throws.
Future<bool> _saveIosSentinelStatus(
  bool? checked, {
  required bool Function() mayWrite,
}) async {
  if (checked == null) return false;
  var wrote = false;
  try {
    final prefs = await _iosPrefs();
    if (prefs.get(AppConstants.keySentinelEnabled) != true) return false;
    if (!mayWrite()) return false;
    // This engine may be the first in the process to use home_widget.
    await HomeWidget.setAppGroupId(AppConstants.iosAppGroupId);
    if (!checked) {
      bool? stored;
      try {
        stored = await HomeWidget.getWidgetData<bool>(
            AppConstants.keyWidgetSentinelOk);
      } catch (_) {
        // Unreadable: write it.
      }
      if (stored == false) return false;
    }
    if (!mayWrite()) return false;
    if (checked) {
      wrote = true;
      await HomeWidget.saveWidgetData<int>(
          AppConstants.keyWidgetSentinelCheckedAt,
          _epochSeconds(DateTime.now()));
      if (!mayWrite()) return true;
    }
    wrote = true;
    await HomeWidget.saveWidgetData<bool>(
        AppConstants.keyWidgetSentinelOk, checked);
    return true;
  } catch (e) {
    debugPrint('[Sentinel] iOS widget status not written: ${e.runtimeType}');
    return wrote;
  }
}

/// Sentinel Lite's status on the widget for a run that checks nothing, as
/// its prefs (read, not doubtful) have Sentinel Lite: on ([sentinelOn]) but
/// unable to check (no Pro bool, unreadable proxy settings, Tor not ready),
/// it reads paused ([_saveIosSentinelStatus] with false: nothing when it is
/// paused already, R29); off, a status still on the widget is removed
/// ([_clearIosSentinelStatus]), since nothing else would take it away once
/// turning it off failed to (R33). True when it issued a write, so the run
/// redraws once. Never throws.
Future<bool> _saveIosSentinelNotChecked({
  required bool sentinelOn,
  required bool Function() mayWrite,
}) =>
    sentinelOn
        ? _saveIosSentinelStatus(false, mayWrite: mayWrite)
        : _clearIosSentinelStatus(mayWrite: mayWrite);

/// Removes Sentinel Lite's status from the widget (both keys) when either is
/// still there, without a redraw: the run's one redraw draws it (R33). Only
/// once Sentinel Lite has been turned off (`sentinel_enabled` false in
/// reloaded prefs): a status is written only while it is on, so an install
/// that never turned it on has none and its run touches no App Group key,
/// and one switched on since the run read it gets its status from the next
/// run. Each write is issued only while [mayWrite] holds. A key that can't
/// be read counts as there.
///
/// True when it issued a write (also one that then failed). Never throws.
Future<bool> _clearIosSentinelStatus({
  required bool Function() mayWrite,
}) async {
  var wrote = false;
  try {
    final prefs = await _iosPrefs();
    if (prefs.get(AppConstants.keySentinelEnabled) != false) return false;
    if (!mayWrite()) return false;
    // This engine may be the first in the process to use home_widget.
    await HomeWidget.setAppGroupId(AppConstants.iosAppGroupId);
    Future<bool> shown(String key) async {
      try {
        return await HomeWidget.getWidgetData<Object>(key) != null;
      } catch (_) {
        return true; // Unreadable: remove it.
      }
    }

    if (!await shown(AppConstants.keyWidgetSentinelOk) &&
        !await shown(AppConstants.keyWidgetSentinelCheckedAt)) {
      return false;
    }
    if (!mayWrite()) return false;
    wrote = true;
    await Future.wait([
      HomeWidget.saveWidgetData<bool>(AppConstants.keyWidgetSentinelOk, null),
      HomeWidget.saveWidgetData<int>(
          AppConstants.keyWidgetSentinelCheckedAt, null),
    ]);
    return true;
  } catch (e) {
    debugPrint('[Sentinel] iOS widget status not removed: ${e.runtimeType}');
    return wrote;
  }
}

/// Whether the Sentinel part may go on: [route] is still the route, and
/// Sentinel Lite and Pro are still on (reloaded prefs). A read that throws
/// is the caller's "no".
Future<bool> _iosSentinelStillWanted(NetworkRoute route) async {
  final prefs = await _iosPrefs();
  return await readNetworkRoute(prefs) == route &&
      _iosSentinelPartWanted(
        route: route,
        sentinelOn: prefs.get(AppConstants.keySentinelEnabled) == true,
        pro: prefs.get(AppConstants.keyProUnlocked) == true,
      );
}

/// Whether every wallet of [watchMap] is still on the stored watch map, so
/// none was removed while the check ran. A read that fails throws.
Future<bool> _iosSentinelSameWallets(
  Map<String, SentinelWatchEntry> watchMap,
) async {
  final stored = {
    for (final entry in (await loadSentinelWatchMap()).values) entry.walletId,
  };
  return watchMap.values.every((entry) => stored.contains(entry.walletId));
}

/// The seen records as stored (`keySentinelSeenTxids`); empty when there are
/// none or the blob isn't in their format, as Android's service reads them.
Map<String, SentinelSeenTx> _decodeSentinelSeen(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map(
      (k, v) => MapEntry(k, SentinelSeenTx.fromJson(v as Map<String, dynamic>)),
    );
  } catch (_) {
    return {};
  }
}

/// The check's state as stored (`keySentinelIosActivity`); empty when there
/// is none or the blob isn't in its format (R10).
IosSentinelState _decodeIosSentinelState(String? raw) {
  if (raw == null || raw.isEmpty) return IosSentinelState.empty;
  try {
    return IosSentinelState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (_) {
    return IosSentinelState.empty;
  }
}

/// The routed Dio of both background paths, the Android job and the iOS
/// refresh: [buildRoutedJsonDio] for [route], handed to
/// [WidgetService.debugInterceptBackgroundDio] outside release builds.
Dio _backgroundDio(NetworkRoute route) {
  final dio = buildRoutedJsonDio(route);
  if (!kReleaseMode) {
    WidgetService.debugInterceptBackgroundDio?.call(dio.interceptors, route);
  }
  return dio;
}

/// The widget currency's spot price and 24 h change: bitbag.app, then
/// CoinGecko (also when bitbag.app doesn't quote the currency). Null when
/// neither answers. The one price fetch of both background paths, the
/// Android job and the iOS refresh; [cancel] is the iOS run's deadline.
Future<({double price, double? change})?> _widgetSpot(
  Dio dio,
  String currency, {
  CancelToken? cancel,
}) async {
  try {
    final response = await dio.get<Map<String, dynamic>>(
      '${AppConstants.bitbagApiBase}/price',
      cancelToken: cancel,
    );
    final prices = response.data!['prices'] as Map<String, dynamic>;
    final changes =
        response.data!['changes24h'] as Map<String, dynamic>? ?? const {};
    final price = prices[currency] as num?;
    if (price != null &&
        !isBackendSpotStale(response.data!['fetchedAt'], DateTime.now())) {
      return (
        price: price.toDouble(),
        change: (changes[currency] as num?)?.toDouble(),
      );
    }
  } catch (e) {
    if (kDebugMode) debugPrint('[WidgetBg] bitbag.app price failed: $e');
  }
  try {
    final response = await dio.get<Map<String, dynamic>>(
      '${AppConstants.coinGeckoBase}/simple/price',
      queryParameters: {
        'ids': 'bitcoin',
        'vs_currencies': currency,
        'include_24hr_change': 'true',
      },
      cancelToken: cancel,
    );
    final btc = response.data!['bitcoin'] as Map<String, dynamic>;
    final price = btc[currency] as num?;
    if (price != null) {
      return (
        price: price.toDouble(),
        change: (btc['${currency}_24h_change'] as num?)?.toDouble(),
      );
    }
  } catch (e) {
    if (kDebugMode) debugPrint('[WidgetBg] CoinGecko price failed: $e');
  }
  return null;
}

/// The widget chart's close prices for [days], oldest first: bitbag.app for
/// 1D/1W/1M in the currencies it serves, Kraken otherwise or as its
/// fallback (gold divided by PAXG), the sources the widget's own fetch
/// uses too. Null with fewer than two points or no answer. The one chart
/// fetch of both background paths, the Android job and the iOS refresh;
/// [cancel] is the iOS run's deadline.
Future<List<double>?> _widgetCloses(
  Dio dio,
  String currency,
  int days, {
  CancelToken? cancel,
}) async {
  if ([1, 7, 30].contains(days) &&
      PriceService.bitbagChartCurrencies.contains(currency)) {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        '${AppConstants.bitbagApiBase}/chart',
        queryParameters: {'currency': currency, 'days': days},
        cancelToken: cancel,
      );
      final closes = [
        for (final row in response.data!['d'] as List<dynamic>)
          ((row as List<dynamic>)[1] as num).toDouble(),
      ];
      if (closes.length >= 2) return closes;
    } catch (e) {
      if (kDebugMode) debugPrint('[WidgetBg] bitbag.app chart failed: $e');
    }
  }
  try {
    final List<double> closes;
    if (currency == krakenGoldCurrency) {
      final btcUsd = await _widgetKrakenCloses(
          dio, krakenPairs['usd']!, days,
          cancelToken: cancel);
      await Future.delayed(const Duration(milliseconds: 1100));
      final paxgUsd = await _widgetKrakenCloses(dio, krakenGoldPair, days,
          cancelToken: cancel);
      closes = divideAlignedTails(btcUsd, paxgUsd);
    } else {
      final pair = krakenPairs[currency];
      if (pair == null) return null;
      closes = await _widgetKrakenCloses(dio, pair, days, cancelToken: cancel);
    }
    if (closes.length >= 2) return closes;
  } catch (e) {
    if (kDebugMode) debugPrint('[WidgetBg] Kraken chart failed: $e');
  }
  return null;
}

/// Writes the price set as [WidgetService.update] does: `widget_currency`,
/// `widget_price`, `widget_net_worth`, `widget_change` (24 h) and
/// `widget_change_positive`, with `widget_fetched_at` ([fetchedAt], when the
/// price came in) and `widget_route_ok` true. The net worth uses
/// the aggregate BTC amount `update` uses (`btc_amount`, a `first_unlock`
/// keychain item). If the keychain can't be read, as before the first unlock
/// after a reboot, the last net worth is left as it is; the price is still
/// written.
Future<void> _saveWidgetSpot(
  String currency,
  ({double price, double? change}) spot, {
  required DateTime fetchedAt,
}) async {
  double? btcAmount;
  try {
    btcAmount = await loadBtcAmount();
  } catch (e) {
    // The type only: the message could name the keychain item.
    debugPrint('[WidgetBg] BTC amount unreadable (${e.runtimeType}); '
        'the widget keeps its last net worth');
  }
  final fmt = currencyFormatter(currency);
  final change = spot.change;
  await Future.wait([
    HomeWidget.saveWidgetData<String>('widget_currency', currency),
    HomeWidget.saveWidgetData<String>('widget_price', fmt.format(spot.price)),
    if (btcAmount != null)
      HomeWidget.saveWidgetData<String>(
        'widget_net_worth',
        btcAmount > 0 ? fmt.format(spot.price * btcAmount) : null,
      ),
    HomeWidget.saveWidgetData<String>(
      'widget_change',
      change != null ? WidgetService._formatChange(change) : null,
    ),
    HomeWidget.saveWidgetData<bool>(
        'widget_change_positive', change != null && change >= 0),
    HomeWidget.saveWidgetData<int>(_keyFetchedAt, _epochSeconds(fetchedAt)),
    HomeWidget.saveWidgetData<bool>(_keyRouteOk, true),
  ]);
}

/// The WorkManager job's own deadline, from its start, Tor's wait
/// included (I1). Past it no new stage starts, and the job stops waiting
/// for one still running and returns success (a failure would only be
/// retried into the same hang). With [backgroundTorReleaseBudget] after it,
/// the job returns before about 8 min, inside WorkManager's 10-minute cap.
const backgroundTaskBudget = Duration(minutes: 5);

/// How long the WorkManager task waits for Tor to be ready before this run
/// gives up on the network (a first bootstrap on a slow network takes
/// 20–60 s).
const backgroundTorBudget = Duration(seconds: 90);

/// How long the WorkManager task waits for its Tor lease to be given back.
/// It returns inside WorkManager's 10-minute cap rather than being stopped
/// (`onStopped` ends the engine with no Dart callback, R-A2e). Returning
/// first leaves no request behind: the stop is issued at the start of the
/// release, so connections see port -1, and a mapping left behind is taken
/// over after [TorHost.lookupTimeout]. A client left behind anyway (the
/// engine went first) is stopped by the next TorHost sweep (Task A2c, which
/// closes R-A2e); with the fork's eager stop (Task A2b) the native stop is
/// not queued behind another plugin call. An owner's release is bounded
/// sooner by TorHost itself (`bootstrapTimeout`, N-b); this bound alone
/// applies to a job that holds no role when it gives the lease back but ran
/// a client earlier, so its stop still reaches a native stop that may never
/// return.
const backgroundTorReleaseBudget = Duration(minutes: 3);

/// What `Workmanager.executeTask` runs (the plugin doesn't export its
/// typedef).
typedef _BackgroundTask = Future<bool> Function(
    String taskName, Map<String, dynamic>? inputData);

/// The job's body: [pastDeadline] turns true at [backgroundTaskBudget].
typedef _BoundedTask = Future<bool> Function(String taskName,
    Map<String, dynamic>? inputData, bool Function() pastDeadline);

/// [task] bounded by [backgroundTaskBudget], with a lease on the process's
/// one Tor client (TorHost) while the route is Tor: this job's own client,
/// or the one the app or Sentinel runs. The lease is taken before [task]
/// runs, so before its route probe and every request, with
/// [backgroundTorBudget] to get ready. Past the deadline [task] starts no
/// new stage, and the job stops waiting for it and returns success. The
/// lease is given back afterwards, whatever [task] did, so a client this
/// job runs stops before its engine goes; a [task] still running then is
/// refused every Tor connection.
_BackgroundTask _whileTorLeased(_BoundedTask task) =>
    (taskName, inputData) async {
      final expired = Completer<bool>();
      final deadline = Timer(
        (kReleaseMode ? null : WidgetService.debugBackgroundTaskBudget) ??
            backgroundTaskBudget,
        () {
          if (kDebugMode) debugPrint('[WidgetBg] job deadline reached');
          expired.complete(true);
        },
      );
      bool pastDeadline() => !deadline.isActive;
      TorHostLease? lease;
      try {
        if (await torRouteStillSelected()) {
          lease = await TorHost.acquire(
            bootstrapBudget: backgroundTorBudget,
            stillTor: torRouteStillSelected,
          );
        }
        var finished = false;
        final result = await Future.any([
          task(taskName, inputData, pastDeadline)
              .whenComplete(() => finished = true),
          expired.future,
        ]);
        // The deadline won: draw what the body stored (the price stage's
        // keys, M6), so a run cut off later shows "Paused" at once rather
        // than at the next redraw (round 2). Bounded, never throws.
        if (!finished) {
          try {
            await _redraw().timeout(const Duration(seconds: 5));
          } catch (e) {
            if (kDebugMode) debugPrint('[WidgetBg] deadline redraw failed: $e');
          }
        }
        return result;
      } finally {
        deadline.cancel();
        if (lease != null) await _giveBack(lease);
      }
    };

/// Gives [lease] back within [backgroundTorReleaseBudget]. Never throws:
/// nothing after it needs Tor, and an error here must not replace the
/// task's own.
Future<void> _giveBack(TorHostLease lease) async {
  try {
    await lease.release().timeout(backgroundTorReleaseBudget);
  } catch (e) {
    if (kDebugMode) debugPrint('[WidgetBg] Tor lease not given back yet: $e');
  }
}

/// The Android job's route check (R-6): true while the route selected now
/// (reloaded prefs) is still [route], the one the run started on. Otherwise
/// the run stops: no further request and no further write, and nothing is
/// stamped. A read that throws counts as a change (fail closed). The one
/// write it makes: `widget_route_ok` false, and a redraw, when the new
/// route has the same widget flags (one proxy edited into another), since
/// nothing else would then say the route is paused. When the flags change
/// the app's flag writer has said so for the new route already, and a
/// write here could overwrite what that route has since delivered.
Future<bool> _stillOnRoute(NetworkRoute route) async {
  NetworkRoute? now;
  try {
    now = await readNetworkRoute(await reloadedPrefs());
  } catch (_) {
    now = null;
  }
  if (now == route) return true;
  if (kDebugMode) debugPrint('[WidgetBg] the route changed — run stopped');
  if (now != null &&
      mapEquals(
        WidgetService._widgetRouteFlags(now),
        WidgetService._widgetRouteFlags(route),
      )) {
    try {
      await HomeWidget.saveWidgetData<bool>(_keyRouteOk, false);
      await _redraw();
    } catch (e) {
      if (kDebugMode) debugPrint('[WidgetBg] route_ok after a route change: $e');
    }
  }
  return false;
}

/// [id]'s entry as the wallets are stored now, or null if it is gone.
Future<WalletEntry?> _storedWallet(String id) async {
  for (final w in await loadWalletsFromStorage()) {
    if (w.id == id) return w;
  }
  return null;
}

/// Checks stored price alerts against [price] for [currency], fires local
/// notifications for triggered alerts, and marks them as fired in prefs.
///
/// The periodic job and the configure activity's one-off can run at once,
/// each in its own engine with its own prefs cache (TB-5). So the alerts
/// are read afresh right before choosing what fires, and those chosen are
/// stored as fired before any is shown: a run that overlaps this one reads
/// them as fired and fires none of them again.
Future<void> _checkAlerts(
    SharedPreferences prefs, String currency, double price) async {
  await prefs.reload();
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

  // Fired before shown: mark them in SharedPreferences first (the app's UI
  // reads it on its next open too).
  final updated = alerts.map((a) => toFire.any((f) => f.id == a.id) ? a.copyWith(fired: true) : a).toList();
  await prefs.setString(AppConstants.keyPriceAlerts, PriceAlert.listToJsonString(updated));

  // Initialise the notification plugin inside the background isolate.
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    ),
  );

  final fmt = currencyFormatter(currency);
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
}

/// Close prices for [pair] over the widget timeframe, oldest first.
Future<List<double>> _widgetKrakenCloses(
  Dio dio,
  String pair,
  int timeframeDays, {
  CancelToken? cancelToken,
}) async {
  final response = await dio.get<Map<String, dynamic>>(
    'https://api.kraken.com/0/public/OHLC',
    queryParameters: _krakenParamsForWidget(pair, timeframeDays),
    cancelToken: cancelToken,
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
  return ohlc.map((row) {
    final r = row as List<dynamic>;
    return double.parse(r[4] as String);
  }).toList();
}

/// Point-wise quotient of two close series that share their most recent
/// candle. Kraken aligns every pair to the same interval boundaries and the
/// request `since` is identical, so the tails line up; only the *starts*
/// differ when one pair's history is shorter (PAXG began in 2019), which is
/// why alignment is from the end. Sparklines carry no timestamps to join on.
List<double> divideAlignedTails(List<double> numerator, List<double> denominator) {
  final n = numerator.length < denominator.length
      ? numerator.length
      : denominator.length;
  final a = numerator.sublist(numerator.length - n);
  final b = denominator.sublist(denominator.length - n);
  return [
    for (var i = 0; i < n; i++)
      if (b[i] > 0) a[i] / b[i],
  ];
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
  /// Test seam: called with the interceptors of the Dio the WorkManager task
  /// and the iOS refresh build with [buildRoutedJsonDio] for their route, so
  /// a test can add a request recorder. It can't replace that Dio or its
  /// adapter, so every request still goes out over the route. Ignored in
  /// release builds. Reset it in tearDown.
  @visibleForTesting
  static void Function(Interceptors interceptors, NetworkRoute route)?
      debugInterceptBackgroundDio;

  /// Test seam: loads prefs for the iOS route read instead of a reloaded
  /// [SharedPreferences.getInstance]. Ignored in release builds. Reset it in
  /// tearDown.
  @visibleForTesting
  static Future<SharedPreferences> Function()? debugIosRoutePrefs;

  /// Test seam: a shorter [backgroundTaskBudget], for cases that run in
  /// real time. Ignored in release builds. Reset it in tearDown.
  @visibleForTesting
  static Duration? debugBackgroundTaskBudget;

  /// Test seam: a shorter [iosBackgroundTaskBudget] for the iOS run's
  /// deadline (the Sentinel part's cut-off moves with it), for cases that
  /// run in real time. The route read and the Tor wait keep their own
  /// bounds. Ignored in release builds. Reset it in tearDown.
  @visibleForTesting
  static Duration? debugIosTaskBudget;

  /// Test seam: called instead of [iosBackgroundFollows] (whatever its
  /// route). Ignored in release builds. Reset it in tearDown.
  @visibleForTesting
  static Future<void> Function()? debugIosBackgroundFollows;

  /// Initialise HomeWidget and WorkManager. Call once from main().
  static Future<void> initialise() async {
    await HomeWidget.setAppGroupId(
        TorService.isIOS ? AppConstants.iosAppGroupId : 'app.bitbag');
    await HomeWidget.registerInteractivityCallback(_interactivityCallback);

    // Android's WorkManager job, and iOS's BGAppRefreshTask (Task A4): the
    // task itself is registered in AppDelegate.swift, and this stores the
    // callback the plugin's background engine runs.
    if (Platform.isAndroid || TorService.isIOS) {
      try {
        await Workmanager().initialize(
          backgroundWidgetCallback,
          isInDebugMode: false,
        );
      } catch (e) {
        if (kDebugMode) debugPrint('[WidgetService] WorkManager init failed: $e');
      }
    }
  }

  /// Schedule (or keep existing) 15-min background refresh. On iOS while
  /// Tor is the route or Sentinel Lite is on with Pro
  /// ([iosBackgroundFollows]); prefs that can't be trusted leave it as it
  /// is. Never throws: `main()` doesn't await it, and every branch catches
  /// its own errors.
  static Future<void> scheduleRefresh() async {
    if (TorService.isIOS) {
      await iosBackgroundFollows();
      return;
    }
    if (!Platform.isAndroid) return;
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

  /// The iOS background refresh follows the selected [route]
  /// ([iosBackgroundFollows] with it): asked for with Tor, and on another
  /// route while Sentinel Lite is on with Pro, cancelled otherwise (I3).
  /// Called on every route change (`NetworkSettingsNotifier._applyRoute`).
  /// Android's job doesn't depend on the route, so this does nothing there.
  static Future<void> backgroundRefreshFollows(NetworkRoute route) async {
    if (!TorService.isIOS) return;
    await iosBackgroundFollows(route: route);
  }

  /// Asks BGTaskScheduler for the iOS background refresh, or cancels it, as
  /// [iosBackgroundRunWanted] says for the route and for Sentinel Lite and
  /// Pro in reloaded prefs. Call it whenever one of them changes. Never
  /// throws.
  ///
  /// Without [route] the route is read from prefs under the doubt rules of
  /// a background read (`_iosRouteRead`, M-a): prefs that can't be trusted
  /// (no `onboarding_complete`, a throw, longer than 3 s) change nothing.
  /// With [route], the route the app has just applied, Tor needs no read,
  /// and another route reads only Sentinel Lite and Pro from the app's own
  /// prefs (no reload, R20), as a route change always has (it never asked
  /// for `onboarding_complete`); a read that takes longer than 3 s changes
  /// nothing.
  static Future<void> iosBackgroundFollows({NetworkRoute? route}) async {
    final seam = kReleaseMode ? null : debugIosBackgroundFollows;
    if (seam != null) return seam();
    final want = await _iosBackgroundWanted(route);
    if (want != null) await _iosRefreshFollows(want: want);
  }

  /// What [iosBackgroundFollows] does: true to ask for the task, false to
  /// cancel it, null to leave it as it is.
  static Future<bool?> _iosBackgroundWanted(NetworkRoute? route) async {
    if (route is TorRoute) return true;
    if (route == null) {
      final read = await _iosRouteRead();
      if (read == null) return null;
      return iosBackgroundRunWanted(
        route: read.route,
        sentinelOn: read.sentinelOn,
        pro: read.pro,
      );
    }
    try {
      // The app's own prefs, which it has just written: no reload (R20).
      final prefs = await SharedPreferences.getInstance()
          .timeout(iosBackgroundTaskBudget - iosBackgroundTorBudget);
      return _iosRunWanted(route, prefs);
    } catch (_) {
      return null;
    }
  }

  /// With [want], asks BGTaskScheduler for the iOS background refresh;
  /// without it, cancels the request. iOS decides when a run happens, from
  /// how the app is used: typically every 15 min to a few hours, and never
  /// in Low Power Mode, with Background App Refresh off, or after the user
  /// force-quits Bag (until it is opened again). The plugin ignores the
  /// frequency and constraints here: the 15 min between runs is set where
  /// the task is registered, in AppDelegate.swift, and each run asks for the
  /// next one. The first run is asked for no earlier than 15 min from now,
  /// because every launch calls this, background launches included, and an
  /// app that has just updated the widget, or a run that is still going,
  /// needs no run at once. Errors are logged, never thrown.
  static Future<void> _iosRefreshFollows({required bool want}) async {
    try {
      if (want) {
        await Workmanager().registerPeriodicTask(
          iosWidgetRefreshTaskId,
          iosWidgetRefreshTaskId,
          frequency: const Duration(minutes: 15),
          initialDelay: const Duration(minutes: 15),
        );
      } else {
        await Workmanager().cancelByUniqueName(iosWidgetRefreshTaskId);
      }
      if (kDebugMode) debugPrint('[WidgetService] iOS background refresh ${want ? 'requested' : 'cancelled'}');
    } catch (e) {
      if (kDebugMode) debugPrint('[WidgetService] iOS background refresh request failed: $e');
    }
  }

  /// Cancel the background refresh.
  static Future<void> cancelRefresh() async {
    if (!Platform.isAndroid) return;
    await Workmanager().cancelByUniqueName(_taskId);
    if (kDebugMode) debugPrint('[WidgetService] background refresh cancelled');
  }

  /// Serialises the [writeWidgetRouteFlags] calls.
  static final _routeFlagsChain = SerialChain();

  /// Mirrors the selected route to the widget's App Group flags:
  /// `widget_use_tor` for Tor, `widget_use_proxy` for a proxy (including one
  /// whose settings are unreadable, so the widget fails closed). The iOS
  /// widget extension fetches charts itself and can only learn the route
  /// here; both false means direct.
  ///
  /// The only writer of these flags. Calls run one at a time, and each reads
  /// the route from (reloaded) prefs once it holds the lock rather than
  /// taking it as an argument, so the last call always writes the final
  /// route. Within a call, flags becoming true go first, so a Tor <-> proxy
  /// switch passes through "both set" and never through "neither set".
  /// Overlapping writers with separate snapshots could interleave into
  /// exactly that state.
  static Future<void> writeWidgetRouteFlags() =>
      _routeFlagsChain.run(_writeRouteFlagsNow);

  static Future<void> _writeRouteFlagsNow() async {
    final prefs = await reloadedPrefs();
    final route = await readNetworkRoute(prefs);
    final flags = _widgetRouteFlags(route);
    // A route change: nothing has come through the new route yet, so the
    // widget reads "Paused since" until the first fetch on it (Task A5).
    // Written before the flags, so a redraw in between (the fee row, the
    // configure activity) never shows a green dot for the new route.
    if (await _routeFlagsChange(flags)) {
      try {
        await HomeWidget.saveWidgetData<bool>(_keyRouteOk, false);
      } catch (err) {
        if (kDebugMode) debugPrint('[WidgetService] widget route_ok: $err');
      }
    }
    for (final e in [
      ...flags.entries.where((e) => e.value),
      ...flags.entries.where((e) => !e.value),
    ]) {
      try {
        await HomeWidget.saveWidgetData<bool>(e.key, e.value);
      } catch (err) {
        // No widget host (tests, unsupported platform): the route still
        // applies to the app itself.
        if (kDebugMode) debugPrint('[WidgetService] widget flag ${e.key}: $err');
      }
    }
  }

  /// The widget's route flags for [route]: `widget_use_tor` for Tor,
  /// `widget_use_proxy` for a proxy, a misconfigured one included.
  static Map<String, bool> _widgetRouteFlags(NetworkRoute route) => {
        'widget_use_tor': route is TorRoute,
        'widget_use_proxy':
            route is ProxyRoute || route is MisconfiguredProxyRoute,
      };

  /// A fetch attempt that got no price: the widget keeps its prices and
  /// their time and says its route is paused (Task A5). The foreground
  /// calls it when its fetch threw (nothing cached to fall back on), and the
  /// iOS background refresh when Tor wasn't ready; that one passes
  /// [appGroupId], set first, since its engine may be the first in the
  /// process to use home_widget.
  static Future<void> recordNoPrice({String? appGroupId}) async {
    if (appGroupId != null) await HomeWidget.setAppGroupId(appGroupId);
    await HomeWidget.saveWidgetData<bool>(_keyRouteOk, false);
    await _redraw();
  }

  /// Whether [flags] differ from the stored ones. Flags not written yet (an
  /// upgrade) or unreadable count as a change.
  static Future<bool> _routeFlagsChange(Map<String, bool> flags) async {
    try {
      for (final e in flags.entries) {
        if (await HomeWidget.getWidgetData<bool>(e.key) != e.value) return true;
      }
      return false;
    } catch (_) {
      return true;
    }
  }

  /// Save the current fast fee rate to the widget's storage and redraw.
  /// Called from [feeProvider] whenever a fresh estimate is available.
  static Future<void> updateFee(FeeEstimate estimate) async {
    await _saveFee(estimate);
    await _redraw();
  }

  /// The fee row's keys for [estimate], without a redraw: [updateFee] and
  /// the iOS background refresh write the row the same way.
  static Future<void> _saveFee(FeeEstimate estimate) => Future.wait([
        HomeWidget.saveWidgetData<bool>('widget_show_fee', true),
        HomeWidget.saveWidgetData<String>(
            'widget_fast_fee', _formatFee(estimate)),
      ]);

  /// "21 sat/vB": the fast fee as the widget's fee row shows it.
  static String _formatFee(FeeEstimate estimate) =>
      '${formatFeeRate(estimate.fast)} sat/vB';

  /// Clear the fee row from the widget immediately when the user disables it.
  static Future<void> clearFee() async {
    await _saveNoFee();
    await _redraw();
  }

  /// Removes Sentinel Lite's status from the widget (both keys, spec D11)
  /// and redraws once. Called when Sentinel Lite is turned off on iOS
  /// (R24), so the widget no longer says it is watching.
  static Future<void> clearSentinelStatus() async {
    await Future.wait([
      HomeWidget.saveWidgetData<bool>(AppConstants.keyWidgetSentinelOk, null),
      HomeWidget.saveWidgetData<int>(
          AppConstants.keyWidgetSentinelCheckedAt, null),
    ]);
    await _redraw();
  }

  /// The hidden fee row's keys, without a redraw: [clearFee] and the iOS
  /// background refresh without Pro write it the same way.
  static Future<void> _saveNoFee() => Future.wait([
        HomeWidget.saveWidgetData<bool>('widget_show_fee', false),
        HomeWidget.saveWidgetData<String>('widget_fast_fee', null),
      ]);

  /// The iOS background refresh without Pro (TB-4): the fee row a lapsed
  /// Pro user's widget still shows is hidden as [clearFee] hides it, and
  /// the run's redraw draws that. A widget with no row to hide gets no
  /// write; one whose keys can't be read is cleared anyway. True when it
  /// wrote.
  static Future<bool> _hideFeeRowIfShown() async {
    try {
      final shown =
          await HomeWidget.getWidgetData<bool>('widget_show_fee') == true ||
              await HomeWidget.getWidgetData<String>('widget_fast_fee') !=
                  null;
      if (!shown) return false;
    } catch (_) {
      // Unreadable: hide it, as if it were shown.
    }
    await _saveNoFee();
    return true;
  }

  /// Write current price + portfolio data to the widget's storage and
  /// trigger a visual redraw. Called from PriceNotifier after every price
  /// fetch, for its cached first frame, and when the DCA log changes.
  static Future<void> update({
    required PriceData priceData,
    required Portfolio portfolio,
    List<DcaEntry>? dcaEntries,
    // The routed service the home chart uses. Only used on iOS with Tor on,
    // to fetch the widget's chart through the app's Tor; see [_pushTorChart].
    PriceService? priceService,
    // When the price fetch behind this push began, if it follows one (see
    // the freshness note below). Null for a push of data already held: the
    // cached first frame, a DCA change.
    DateTime? attemptedAt,
  }) async {
    final currency = portfolio.primaryCurrency.toLowerCase();

    final price = priceData.priceFor(currency);
    final change = priceData.changeFor(currency);

    // Guard against the brief window where portfolioProvider hasn't yet
    // reflected the latest wallet scan or settings write. If btcAmount is 0
    // here, saving null for widget_net_worth would wipe the previously
    // correct value written by the background task. Read the stored amount
    // (`loadBtcAmount`) as a fallback so the widget never goes blank
    // unnecessarily. If the keychain can't be read (before the first unlock
    // after a reboot), the price still goes out and the last net worth
    // stays, as in `_saveWidgetSpot` (TB-9).
    double? btcAmount = portfolio.btcAmount;
    if (btcAmount == 0) {
      try {
        btcAmount = await loadBtcAmount();
      } catch (e) {
        // The type only: the message could name the keychain item.
        debugPrint('[WidgetService] BTC amount unreadable (${e.runtimeType}); '
            'the widget keeps its last net worth');
        btcAmount = null;
      }
    }

    final currencyFmt =
        currencyFormatter(currency);

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

    // The iOS widget extension fetches charts itself and fails closed on
    // the route flags. Written here (foreground, runs on iOS), so a user who
    // had a private route on before the flags existed gets them on the next
    // widget update. Never by backgroundWidgetCallback: on iOS it runs only
    // with Tor on, in its own isolate, outside this serialised writer.
    await writeWidgetRouteFlags();

    // Freshness (Task A5). `widget_fetched_at` is when the price on the
    // widget was fetched, from the data itself, never now (R-A5d): a push
    // of cached prices says how old they are. A price carried over from an
    // older cache has no fetch time of its own, so the last one stays.
    // After a fetch attempt `widget_route_ok` says whether it got the price
    // through the route: false when the price layer served data from before
    // the attempt (its route gate tripped, or every source failed) or
    // carried this currency over.
    // A fetch time after now (the clock set back) can't be this attempt's
    // either (I3).
    final carried = priceData.isCarriedOver(currency);
    final hasOwnTime = price != null && !carried;
    final fetchedThisTime = attemptedAt != null &&
        hasOwnTime &&
        !priceData.fetchedAt.isBefore(attemptedAt) &&
        !priceData.fetchedAt.isAfter(DateTime.now());
    // A carried-over price is older than any the widget may already show
    // for that currency (a background run's): leave its price keys as they
    // are (M4). For another currency they are written, so the price and its
    // currency agree.
    final keepShownPrice =
        carried && await _shownWidgetCurrency() == currency;

    await Future.wait([
      // widget_currency lets NativeChartRefreshWorker know which pair to fetch.
      HomeWidget.saveWidgetData<String>('widget_currency', currency),
      if (!keepShownPrice) ...[
        HomeWidget.saveWidgetData<String>(
            'widget_price', price != null ? currencyFmt.format(price) : null),
        if (btcAmount != null)
          HomeWidget.saveWidgetData<String>(
            'widget_net_worth',
            price != null && btcAmount > 0
                ? currencyFmt.format(price * btcAmount)
                : null,
          ),
        HomeWidget.saveWidgetData<String>(
          'widget_change',
          change != null ? _formatChange(change) : null,
        ),
        HomeWidget.saveWidgetData<bool>(
            'widget_change_positive', change != null && change >= 0),
        HomeWidget.saveWidgetData<String>('widget_pnl_amount', pnlAmountStr),
        HomeWidget.saveWidgetData<String>('widget_pnl_pct', pnlPctStr),
        HomeWidget.saveWidgetData<bool>('widget_pnl_positive', pnlPositive),
      ],
      if (hasOwnTime)
        HomeWidget.saveWidgetData<int>(
            _keyFetchedAt, _epochSeconds(priceData.fetchedAt)),
      if (attemptedAt != null)
        HomeWidget.saveWidgetData<bool>(_keyRouteOk, fetchedThisTime),
    ]);

    await _redraw();

    // After the price reload, not before it: a chart fetch over Tor can take
    // tens of seconds, and the price shouldn't wait for it.
    if (priceService != null) await _pushTorChart(priceService, currency);
  }

  /// The currency the widget shows (`widget_currency`), or null when it
  /// can't be read.
  static Future<String?> _shownWidgetCurrency() async {
    try {
      return await HomeWidget.getWidgetData<String>('widget_currency');
    } catch (_) {
      return null;
    }
  }

  /// The timeframes the iOS widget offers (`ChartTimeframe.days` in
  /// ios/BagWidget/BagWidget.swift: 1D 1W 1M 1Y 5Y ALL). They are the same
  /// day counts [PriceService.fetchChartData] takes, so no mapping is needed.
  static const _widgetTimeframes = {
    1,
    7,
    30,
    365,
    AppConstants.timeframe5YDays,
    AppConstants.timeframeAllDays,
  };

  /// The widget intent's default timeframe (`.week1`).
  static const _widgetDefaultDays = 7;

  /// Whether the app pushes the widget's chart itself over [route]: iOS
  /// with Tor on ([_pushTorChart]). There `PriceNotifier` stands down, so
  /// the chart isn't fetched twice over Tor.
  static bool appPushesChart(NetworkRoute route) =>
      TorService.isIOS && route is TorRoute;

  /// iOS with Tor on: the widget extension never goes online (it can't run
  /// Tor in its memory budget), so the app fetches the widget's chart
  /// through its own Tor and pushes it.
  ///
  /// Runs only while the embedded client is [EmbeddedTorState.ready]. In any
  /// other state, on any other route, on Android, or when the fetch throws
  /// (Tor dropped mid-fetch), nothing chart-related is written and the
  /// widget keeps the last push.
  ///
  /// [priceService]'s own route decides, so the decision and the request can
  /// never disagree: the fetch goes through exactly the route checked here.
  ///
  /// Coalesced: a call while a push for the same currency is in flight
  /// shares it — one fetch over Tor, one write. `PriceNotifier.build()`'s
  /// cached path and its background refresh both update the widget within
  /// the same cycle.
  static Future<void> _pushTorChart(
    PriceService priceService,
    String currency,
  ) {
    if (!appPushesChart(priceService.route) ||
        EmbeddedTorService.state != EmbeddedTorState.ready) {
      return Future<void>.value();
    }
    final inFlight = _torChartPush;
    if (inFlight != null && inFlight.currency == currency) return inFlight.push;
    late final Future<void> push;
    push = _fetchAndPushTorChart(priceService, currency).whenComplete(() {
      if (identical(_torChartPush?.push, push)) _torChartPush = null;
    });
    _torChartPush = (currency: currency, push: push);
    return push;
  }

  /// The Tor chart push in flight, if any ([_pushTorChart]).
  static ({String currency, Future<void> push})? _torChartPush;

  static Future<void> _fetchAndPushTorChart(
    PriceService priceService,
    String currency,
  ) async {
    try {
      final days = await _configuredWidgetDays();
      final chart = await priceService.fetchChartData(currency, days);
      final prices = chart.map((p) => p.$2).toList();
      if (await _saveWidgetChart(prices: prices, days: days)) await _redraw();
    } catch (e) {
      if (kDebugMode) debugPrint('[WidgetService] Tor chart push skipped: $e');
    }
  }

  /// The timeframe the widget timeline saved (`widget_timeframe_days`), or the
  /// widget's default when it is missing, not an int, or not one the widget
  /// offers.
  static Future<int> _configuredWidgetDays() async {
    Object? raw;
    try {
      raw = await HomeWidget.getWidgetData<Object>('widget_timeframe_days');
    } catch (_) {
      raw = null;
    }
    return raw is int && _widgetTimeframes.contains(raw)
        ? raw
        : _widgetDefaultDays;
  }

  /// `(last − first) / first` in percent, or null when there is no change to
  /// show (fewer than two points, or a non-positive first price) — the same
  /// rule as the Swift self-fetch.
  static double? _timeframeChange(List<double> prices) {
    if (prices.length < 2 || prices.first <= 0) return null;
    return (prices.last - prices.first) / prices.first * 100;
  }

  /// "+2.4%" / "-1.3%": the format the widget shows for the 24 h and the
  /// timeframe change alike (the Swift self-fetch writes
  /// `"\(sign)\(String(format: "%.1f", tfChange))%"`).
  static String _formatChange(double change) =>
      '${change >= 0 ? '+' : ''}${change.toStringAsFixed(1)}%';

  /// Serialises the [_saveWidgetChart] writes.
  static final _chartWriteChain = SerialChain();

  /// Writes [prices] as the widget's chart for [days], as one set:
  /// `widget_chart_prices` (JSON closes, oldest first), `widget_chart_change`
  /// (their [_timeframeChange], as [_formatChange] writes it) and
  /// `widget_chart_days` (the timeframe they cover). The Swift timeline draws
  /// the pushed chart only when `widget_chart_days` equals the configured
  /// timeframe. With no change to show nothing is written, and it returns
  /// false.
  ///
  /// `widget_chart_days` is removed first and written last, and calls run one
  /// at a time, so a timeline reading mid-write sees no days (no sparkline)
  /// rather than one timeframe's label on another's prices. A write that
  /// fails part-way leaves the days absent, which renders the same way.
  static Future<bool> _saveWidgetChart({
    required List<double> prices,
    required int days,
  }) async {
    final change = _timeframeChange(prices);
    if (change == null) return false;
    await _chartWriteChain.run(() async {
      await HomeWidget.saveWidgetData<int>('widget_chart_days', null);
      await HomeWidget.saveWidgetData<String>(
          'widget_chart_prices', jsonEncode(prices));
      await HomeWidget.saveWidgetData<String>(
          'widget_chart_change', _formatChange(change));
      await HomeWidget.saveWidgetData<int>('widget_chart_days', days);
    });
    return true;
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
  ///
  /// iOS: the prices go out with the timeframe they cover, as the same set
  /// the Tor push writes ([_saveWidgetChart]), so `widget_chart_days` always
  /// describes `widget_chart_prices` whoever wrote them last.
  static Future<void> saveChartPricesForWidget({
    required List<(DateTime, double)> chartData,
    required int days,
  }) async {
    if (chartData.isEmpty) return;

    final prices = chartData.map((p) => p.$2).toList();

    final saves = <Future>[];
    if (TorService.isIOS) {
      await _saveWidgetChart(prices: prices, days: days);
    } else {
      saves.add(HomeWidget.saveWidgetData<String>(
          'widget_chart_prices', jsonEncode(prices)));
    }

    // Override widget_change with the actual timeframe % change.
    if (chartData.length >= 2) {
      final first = chartData.first.$2;
      final last = chartData.last.$2;
      if (first > 0) {
        final change = (last - first) / first * 100;
        saves.addAll([
          HomeWidget.saveWidgetData<String>('widget_change', _formatChange(change)),
          HomeWidget.saveWidgetData<bool>('widget_change_positive', change >= 0),
        ]);
      }
    }

    await Future.wait(saves);
    await _redraw();
  }

  /// Returns the timeframe (days) the user configured for the widget: one
  /// the widget offers, or its default (1 week) when it is missing, not an
  /// int or not offered, as the Tor push reads it (TB-7).
  static Future<int> getTimeframeDays() => _configuredWidgetDays();

  /// Request the system widget picker to pin the widget to the home screen.
  static Future<bool> requestPinWidget() async {
    if (!Platform.isAndroid) return false;
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
    if (!Platform.isAndroid) return 0;
    try {
      final v = await _widgetChannel.invokeMethod<int>('getSdkVersion');
      return v ?? 0;
    } on PlatformException {
      return 0;
    }
  }
}

@pragma('vm:entry-point')
Future<void> _interactivityCallback(Uri? uri) async {
  // Reserved for future interactive widget actions (e.g. refresh tap).
}
