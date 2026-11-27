/// Android's background isolates on built-in Tor (Task A3).
///
/// - The WorkManager task, run the way the workmanager plugin runs it
///   (`backgroundWidgetCallback` registers it, then the platform calls it on
///   the background channel). With Tor it takes a TorHost lease before any
///   request and gives it back afterwards, also when the task throws, and
///   the release is bounded: TorHost gives a native stop that never
///   returns up after 90 s (N-b), inside the job's own 3-min backstop,
///   which alone bounds a job that holds no role when it gives the lease
///   back. With Tor not ready inside 90 s, or a
///   proxy that is down or unreadable, it makes no request, leaves the
///   widget's price, net worth, change and time as they were, and keeps the
///   wallets' cached sats (R-A3a); it only says the route is paused
///   (`widget_route_ok`, Task A5).
/// - Sentinel holds one lease while the route is Tor: taken once at start,
///   given back when the route leaves Tor, taken again when it comes back or
///   the client is failed or off, and given back in onDestroy, bounded at
///   30 s. A tick that finds Tor starting waits for it, saying so.
/// - Neither path dials Orbot's 127.0.0.1:9050. Nothing in lib/, android/
///   or ios/ names that port, and the Kotlin chart worker skips with Tor on.
///
/// The fake native client stands in for the plugin; a fake registry stands
/// in for the IsolateNameServer (tor_host_test covers the real one).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart'
    show TaskStarter;
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show AndroidFlutterLocalNotificationsPlugin;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/core/constants/supported_currencies.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/network_settings.dart';
import 'package:bag/models/price_alert.dart';
import 'package:bag/models/wallet_entry.dart';
import 'package:bag/services/embedded_tor_service.dart';
import 'package:bag/services/network/network_route_store.dart';
import 'package:bag/services/sentinel_service.dart';
import 'package:bag/services/sentinel_store.dart';
import 'package:bag/services/tor_host.dart';
import 'package:bag/services/tor_service.dart';
import 'package:bag/services/wallet/esplora_client.dart';
import 'package:bag/services/wallet/wallet_store.dart';
import 'package:bag/services/widget_service.dart';

import '../network/fake_proxies.dart';

/// BIP84's test vector account (abandon … about), watch-only.
const _zpub =
    'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs';

const _workmanagerChannel = MethodChannel(
  'be.tramckrijte.workmanager/background_channel_work_manager',
);

/// The widget keys a run writes only when it got a price (R-A3a).
const _freshKeys = {
  'widget_price',
  'widget_net_worth',
  'widget_change',
  'widget_change_positive',
  'widget_fetched_at',
  'widget_chart_prices',
};

/// When the earlier run's price was fetched (`widget_fetched_at`, epoch
/// seconds, Task A5).
const _earlierFetch = 1763880000;

/// What an earlier, successful run left on the widget.
const _cachedWidget = <String, Object?>{
  'widget_price': r'$40,000.00',
  'widget_net_worth': r'$20,000.00',
  'widget_change': '+1.0%',
  'widget_change_positive': true,
  'widget_fetched_at': _earlierFetch,
  'widget_route_ok': true,
  'widget_chart_prices': '[39000.0,40000.0]',
};

/// A native client like the plugin's: a start can be held open or made to
/// fail once, a stop cancels a held start and can itself be held.
class _Native implements EmbeddedTorBackend {
  int socksPort = 47123;
  int startCalls = 0;
  int stopCalls = 0;

  /// The next start waits on this.
  Completer<void>? hold;

  /// A stop waits on this (a native teardown that hangs).
  Completer<void>? stopGate;

  /// The next start throws.
  bool failNext = false;

  /// Every start throws.
  bool failAlways = false;

  Completer<void>? _held;
  bool _cancelled = false;
  bool _bootstrapped = false;
  final _failures = StreamController<Object>.broadcast();
  final _events = StreamController<int>.broadcast();

  void releaseStart() {
    final held = _held;
    if (held != null && !held.isCompleted) held.complete();
  }

  void releaseStop() {
    final gate = stopGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  /// The client dies on its own, as the plugin reports it: port -1 first,
  /// then the failure.
  void die() {
    _bootstrapped = false;
    _events.add(-1);
    _failures.add(StateError('proxy exited'));
  }

  @override
  Stream<Object> get failures => _failures.stream;

  @override
  Stream<int> get events => _events.stream;

  @override
  bool get bootstrapped => _bootstrapped;

  @override
  int get port => _bootstrapped ? socksPort : -1;

  @override
  Future<void> start() async {
    startCalls++;
    _cancelled = false;
    if (failNext || failAlways) {
      failNext = false;
      throw StateError('bootstrap failed');
    }
    final held = _held = hold;
    hold = null;
    if (held != null) await held.future;
    if (_cancelled) return;
    _bootstrapped = true;
  }

  @override
  Future<void> bootstrap() async {}

  @override
  Future<void> setDormant(bool dormant) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
    _bootstrapped = false;
    _cancelled = true;
    releaseStart();
    final gate = stopGate;
    if (gate != null) await gate.future;
  }
}

/// The IsolateNameServer's contract, in memory.
class _Registry implements TorPortRegistry {
  static const _markNames = {TorHost.usedPortName, TorHost.unsweptPortName};

  final Map<String, SendPort> names = {};

  /// The process-wide marks (a Tor client has run, [TorHost.usedPortName];
  /// a takeover not swept yet, [TorHost.unsweptPortName]), kept apart so
  /// [names] holds only an owner's mappings.
  final Map<String, SendPort> marks = {};

  Map<String, SendPort> _holding(String name) =>
      _markNames.contains(name) ? marks : names;

  @override
  SendPort? lookup(String name) => _holding(name)[name];

  @override
  bool register(SendPort port, String name) {
    final map = _holding(name);
    if (map.containsKey(name)) return false;
    map[name] = port;
    return true;
  }

  @override
  bool remove(String name) => _holding(name).remove(name) != null;
}

/// Every request the WorkManager task makes through its Dio, with the Tor
/// client as the task saw it at that moment. A path in [holds] waits for
/// its completer first. Answers from [bodies] by path; with [passThrough]
/// anything else goes out over the route, otherwise it fails (no network).
class _Requests {
  final seen = <({Uri uri, EmbeddedTorState state, int port})>[];
  final Map<String, Object> bodies = {};
  final Map<String, Completer<void>> holds = {};
  bool passThrough = false;

  void watch(Interceptors interceptors, NetworkRoute route) => interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        seen.add((
          uri: options.uri,
          state: EmbeddedTorService.state,
          port: await TorHost.port(),
        ));
        await holds[options.uri.path]?.future;
        final body = bodies[options.uri.path];
        if (body != null) {
          handler.resolve(
            Response(requestOptions: options, data: body, statusCode: 200),
          );
        } else if (passThrough) {
          handler.next(options);
        } else {
          handler.reject(
            DioException(requestOptions: options, error: 'no canned body'),
          );
        }
      },
    ),
  );
}

/// An Esplora server whose every address is unused except those in
/// [funded], so a scan completes. With [failing] every answer is malformed,
/// so every scan fails.
class _Esplora {
  _Esplora._(this._server) {
    _server.listen((request) async {
      hits++;
      final segments = request.uri.pathSegments;
      final address = segments.length > 2 ? segments[2] : '';
      addressHits[address] = (addressHits[address] ?? 0) + 1;
      final before = beforeFirstAnswer;
      beforeFirstAnswer = null;
      if (before != null) await before();
      request.response
        ..headers.contentType = ContentType.json
        ..write(
          failing
              ? '{"ok":true}'
              : request.uri.path.endsWith('/txs/mempool')
              ? '[]'
              : _address(funded[address] ?? 0),
        );
      request.response.close();
    });
  }

  static String _address(int sats) =>
      '{"chain_stats":{"tx_count":${sats > 0 ? 1 : 0},'
      '"funded_txo_sum":$sats,"spent_txo_sum":0},'
      '"mempool_stats":{"tx_count":0,"funded_txo_sum":0,"spent_txo_sum":0}}';

  final HttpServer _server;
  int hits = 0;

  /// Requests per address queried (`/address/<addr>…`).
  final Map<String, int> addressHits = {};

  /// Run, once, before the first answer goes out.
  Future<void> Function()? beforeFirstAnswer;
  bool failing = false;
  final Map<String, int> funded = {};

  int get port => _server.port;

  static Future<_Esplora> start() async =>
      _Esplora._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> close() => _server.close(force: true);
}

/// Polls [condition] until it holds.
Future<void> _until(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String reason = '',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  // The binding is needed for the platform channels, but it also installs
  // HttpOverrides that answer every request with a canned 400 without
  // touching a socket. The proxies here are real sockets.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _Native native;
  late _Registry registry;
  late _Requests requests;
  final previousRetryUnit = EsploraClient.debugRetryDelayUnit;

  // The widget host (HomeWidgetPreferences).
  final widgetStore = <String, Object?>{};
  final widgetWrites = <String>[];
  var widgetRedraws = 0;
  var failWidgetWrites = false;

  // Sentinel's ongoing notification.
  final notifications = <String>[];

  // Local notifications shown (price alerts), each with the price alerts as
  // the platform store held them at that moment.
  final shown = <({Object? args, String? alertsStored})>[];

  // Run, once, when the next local notification is shown.
  Future<void> Function()? onShow;

  // Run on every widget key written.
  Future<void> Function(String id)? onWidgetWrite;

  setUpAll(() {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    messenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async {
        if (call.method == 'show') {
          // What another engine would read now: the store, not a cache.
          final store = await SharedPreferences.getInstance();
          await store.reload();
          shown.add((
            args: call.arguments,
            alertsStored: store.getString(AppConstants.keyPriceAlerts),
          ));
          final hook = onShow;
          onShow = null;
          if (hook != null) await hook();
        }
        return call.method == 'initialize' ? true : null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async {
        switch (call.method) {
          case 'isRunningService':
            return true;
          case 'updateService':
            final text = (call.arguments as Map)['notificationContentText'];
            if (text is String) notifications.add(text);
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(const MethodChannel('home_widget'), (
      call,
    ) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      switch (call.method) {
        case 'saveWidgetData':
          if (failWidgetWrites) {
            throw PlatformException(code: 'no-widget-host');
          }
          final id = args['id'] as String;
          widgetWrites.add(id);
          widgetStore[id] = args['data'];
          final hook = onWidgetWrite;
          if (hook != null) await hook(id);
          return true;
        case 'getWidgetData':
          return widgetStore[args['id']];
        case 'updateWidget':
          widgetRedraws++;
          return true;
      }
      return null;
    });
    // The plugin's "ready" call when the task is registered.
    messenger.setMockMethodCallHandler(_workmanagerChannel, (call) async {
      return null;
    });
  });

  setUp(() {
    native = _Native();
    registry = _Registry();
    requests = _Requests();
    EmbeddedTorService.debugBackend = native;
    TorHost.debugRegistry = registry;
    TorService.debugIsIOS = false;
    WidgetService.debugInterceptBackgroundDio = requests.watch;
    EsploraClient.debugRetryDelayUnit = Duration.zero;
    widgetStore
      ..clear()
      ..addAll(_cachedWidget);
    widgetWrites.clear();
    widgetRedraws = 0;
    failWidgetWrites = false;
    notifications.clear();
    shown.clear();
    onShow = null;
    onWidgetWrite = null;
  });

  tearDown(() async {
    native.releaseStart();
    native.releaseStop();
    await EmbeddedTorService.stop();
    EmbeddedTorService.debugReset();
    EmbeddedTorService.debugBackend = null;
    TorHost.debugRegistry = null;
    TorService.debugIsIOS = null;
    WidgetService.debugInterceptBackgroundDio = null;
    WidgetService.debugBackgroundTaskBudget = null;
    EsploraClient.debugRetryDelayUnit = previousRetryUnit;
  });

  /// Seeds prefs and secure storage for one run. Pro by default: the job's
  /// wallet-scan and fee stages are Pro (B2's `backgroundProAllowed` and
  /// `backgroundFeePlan`), and these tests exercise them (A3 M2b). A test
  /// passes `keyProUnlocked: false` to run as a free user.
  void seed(
    Map<String, Object> prefs, [
    Map<String, String> secure = const {},
  ]) {
    SharedPreferences.setMockInitialValues({
      AppConstants.keySelectedCurrencies: ['usd'],
      AppConstants.keyProUnlocked: true,
      ...prefs,
    });
    FlutterSecureStorage.setMockInitialValues({
      AppConstants.keyBtcAmount: '0.5',
      ...secure,
    });
  }

  /// A watch-only wallet whose last scan is stale, with cached sats.
  final staleWallet = {
    'wallets_metadata': jsonEncode([
      {
        'id': 'w1',
        'label': 'Cold',
        'kind': 'zpub',
        'lastSats': 1234,
        'lastScanAt': DateTime(2026).millisecondsSinceEpoch,
      },
    ]),
    'wallet_zpub_w1': _zpub,
  };

  // ── The WorkManager task ────────────────────────────────────────────────

  group('the WorkManager task', () {
    /// Runs the task as the workmanager plugin does: the callback registers
    /// it, then the platform calls it on the background channel. Returns
    /// its result, or throws its error.
    Future<Object?> runTask() async {
      backgroundWidgetCallback();
      const codec = StandardMethodCodec();
      final reply = await messenger.handlePlatformMessage(
        _workmanagerChannel.name,
        codec.encodeMethodCall(
          const MethodCall('onResultSend', {
            'be.tramckrijte.workmanager.DART_TASK': 'bag_widget_refresh',
          }),
        ),
        null,
      );
      return codec.decodeEnvelope(reply!);
    }

    void answerPriceAndChart() {
      requests.bodies['/api/price'] = <String, dynamic>{
        'prices': {'usd': 50000.0},
        'changes24h': {'usd': 1.5},
      };
      requests.bodies['/api/chart'] = <String, dynamic>{
        'd': [
          [0, 49000.0],
          [1, 50000.0],
        ],
      };
    }

    /// A run that got no price: nothing blanked or stamped, and the widget
    /// says its route is paused (Task A5).
    void expectCachedWidgetKept() {
      expect(
        widgetWrites.where(_freshKeys.contains),
        isEmpty,
        reason: 'blanked or stamped what this run did not fetch',
      );
      expect(widgetStore, containsPair('widget_price', r'$40,000.00'));
      expect(widgetStore, containsPair('widget_fetched_at', _earlierFetch));
      expect(widgetStore, containsPair('widget_route_ok', false));
      expect(widgetRedraws, 1, reason: 'the paused state never drawn');
    }

    test('the budgets: 5 min for the job, 90 s for Tor, 3 min for giving '
        'the lease back', () {
      expect(backgroundTaskBudget, const Duration(minutes: 5));
      expect(backgroundTorBudget, const Duration(seconds: 90));
      expect(backgroundTorReleaseBudget, const Duration(minutes: 3));
    });

    test('a request that hangs: the job returns at its 5-min deadline with '
        'the lease given back, and nothing new starts after it (I1)', () {
      fakeAsync((async) {
        seed({
          AppConstants.keyUseTor: true,
          AppConstants.keyWidgetShowFee: true,
        }, staleWallet);
        answerPriceAndChart();
        final hang = requests.holds['/api/price'] = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(minutes: 4, seconds: 59));
        expect(result, isNull);
        expect(requests.seen.map((r) => r.uri.path), ['/api/price']);
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);

        async.elapse(const Duration(seconds: 2));
        expect(result, isTrue, reason: 'past the deadline, no retry storm');
        expect(native.stopCalls, 1);
        expect(EmbeddedTorService.state, EmbeddedTorState.off);
        expect(registry.names, isEmpty);

        // The abandoned body gets its price after all: it starts no chart,
        // fee or wallet stage past the deadline.
        hang.complete();
        async.elapse(const Duration(minutes: 1));
        expect(requests.seen.map((r) => r.uri.path), ['/api/price']);
      });
    });

    test('past the deadline no new stage starts: not the chart, not the fee, '
        'not a further wallet', () async {
      final esplora = await _Esplora.start();
      addTearDown(esplora.close);
      // Direct, so a wallet scan would reach the explorer and show up.
      WidgetService.debugBackgroundTaskBudget = const Duration(
        milliseconds: 300,
      );
      seed(
        {
          AppConstants.keyWidgetShowFee: true,
          AppConstants.keyExplorerPreset: ExplorerPreset.custom.index,
        },
        {
          ...staleWallet,
          AppConstants.keyExplorerCustomUrl:
              'http://127.0.0.1:${esplora.port}/api',
        },
      );
      answerPriceAndChart();
      final hang = requests.holds['/api/price'] = Completer<void>();
      final clock = Stopwatch()..start();

      expect(await runTask(), isTrue);
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      // The deadline redraws what is stored (round 2).
      expect(widgetRedraws, 1);

      hang.complete();
      await _until(() => widgetRedraws == 2, reason: 'the body never ended');
      expect(requests.seen.map((r) => r.uri.path), ['/api/price']);
      expect(esplora.hits, 0);
      expect((await loadWalletsFromStorage()).single.lastSats, 1234);
    });

    test('Tor with a stale wallet: the scan and the fee fetch go through the '
        'leased port, the wallet\'s sats update, Orbot on 127.0.0.1:9050 gets '
        'nothing', () async {
      final esplora = await _Esplora.start();
      addTearDown(esplora.close);
      final orbot = await startOrbotStandIn(targetPort: esplora.port);
      addTearDown(orbot.close);
      final embedded = await FakeSocks5Proxy.start(targetPort: esplora.port);
      addTearDown(embedded.close);
      native.socksPort = embedded.port;
      esplora.funded[buildAddressSource(
            WalletKind.zpub,
            _zpub,
          ).addressAt(0, 0)] =
          5000;
      seed(
        {
          AppConstants.keyUseTor: true,
          AppConstants.keyWidgetShowFee: true,
          AppConstants.keyExplorerPreset: ExplorerPreset.custom.index,
        },
        {
          ...staleWallet,
          AppConstants.keyExplorerCustomUrl:
              'http://bag-test.invalid:${esplora.port}/api',
        },
      );
      answerPriceAndChart();
      // The fee request goes to the selected explorer, over the route.
      requests.passThrough = true;

      expect(await runTask(), isTrue);

      final fee = requests.seen.singleWhere(
        (r) => r.uri.path == '/api/v1/fees/recommended',
      );
      expect(fee.state, EmbeddedTorState.ready);
      expect(fee.port, native.socksPort);
      expect(fee.uri.host, 'bag-test.invalid');
      expect(embedded.connectHosts, everyElement('bag-test.invalid'));
      expect(esplora.hits, greaterThan(0));
      expect(orbot.connections, 0);
      final wallet = (await loadWalletsFromStorage()).single;
      expect(wallet.lastSats, 5000);
      expect(wallet.lastScanAt, isNot(DateTime(2026)));
      expect(await loadBtcAmount(), 5000 / 1e8);
      expect(
        widgetStore['widget_net_worth'],
        currencyFormatter('usd').format(50000 * 5000 / 1e8),
      );
      expect(native.stopCalls, 1);
      expect(registry.names, isEmpty);
    });

    test('Tor: the lease is taken before any request, the fetched price is '
        'written and stamped, and the lease is given back', () async {
      seed({AppConstants.keyUseTor: true});
      answerPriceAndChart();
      final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      expect(await runTask(), isTrue);

      final after = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(requests.seen.map((r) => r.uri.path), [
        '/api/price',
        '/api/chart',
      ]);
      for (final r in requests.seen) {
        expect(r.state, EmbeddedTorState.ready, reason: '${r.uri}');
        expect(r.port, native.socksPort, reason: '${r.uri}');
      }
      expect(native.startCalls, 1);

      final usd = currencyFormatter('usd');
      expect(widgetStore['widget_price'], usd.format(50000));
      expect(widgetStore['widget_net_worth'], usd.format(25000));
      expect(widgetStore['widget_change'], '+2.0%');
      expect(widgetStore['widget_change_positive'], isTrue);
      expect(widgetStore['widget_fetched_at'], inInclusiveRange(before, after));
      expect(widgetStore['widget_route_ok'], isTrue);
      expect(widgetStore['widget_chart_prices'], '[49000.0,50000.0]');
      expect(widgetRedraws, 1);

      // Given back: this isolate ran the client and held the only lease.
      expect(native.stopCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(await TorHost.port(), -1);
      expect(registry.names, isEmpty);
    });

    test('a currency bitbag.app doesn\'t quote comes from CoinGecko, through '
        'the leased port: the iOS refresh\'s price fetch, not a copy (D1)', () async {
      seed({AppConstants.keyUseTor: true});
      requests.bodies['/api/price'] = <String, dynamic>{
        'prices': {'eur': 46000.0},
        'changes24h': {'eur': 1.0},
      };
      requests.bodies['/api/v3/simple/price'] = <String, dynamic>{
        'bitcoin': {'usd': 51000.0, 'usd_24h_change': -0.5},
      };

      expect(await runTask(), isTrue);

      expect(requests.seen.map((r) => r.uri.path).take(2), [
        '/api/price',
        '/api/v3/simple/price',
      ]);
      for (final r in requests.seen) {
        expect(r.state, EmbeddedTorState.ready, reason: '${r.uri}');
        expect(r.port, native.socksPort, reason: '${r.uri}');
      }
      expect(widgetStore['widget_price'], currencyFormatter('usd').format(51000));
      expect(widgetStore['widget_change'], '-0.5%');
      expect(widgetStore['widget_route_ok'], isTrue);
    });

    test('a bitbag.app answer older than 15 minutes is skipped: the price '
        'comes from CoinGecko (backend audit, 2.0.1)', () async {
      seed({AppConstants.keyUseTor: true});
      requests.bodies['/api/price'] = <String, dynamic>{
        'prices': {'usd': 40000.0},
        'changes24h': {'usd': 9.0},
        'fetchedAt': DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 2))
            .toIso8601String(),
      };
      requests.bodies['/api/v3/simple/price'] = <String, dynamic>{
        'bitcoin': {'usd': 51000.0, 'usd_24h_change': -0.5},
      };

      expect(await runTask(), isTrue);

      expect(requests.seen.map((r) => r.uri.path).take(2), [
        '/api/price',
        '/api/v3/simple/price',
      ]);
      expect(widgetStore['widget_price'], currencyFormatter('usd').format(51000));
      expect(widgetStore['widget_change'], '-0.5%');
    });

    test('a free user with Tor still on (R-B2g): the lease is taken and the '
        'price and chart come through it, never direct; no fee request and '
        'no wallet scan, and the kept wallet still counts (R-A3d)', () async {
      final esplora = await _Esplora.start();
      addTearDown(esplora.close);
      // A scan, if one ran, would reach the explorer through the leased port.
      final embedded = await FakeSocks5Proxy.start(targetPort: esplora.port);
      addTearDown(embedded.close);
      native.socksPort = embedded.port;
      seed(
        {
          AppConstants.keyProUnlocked: false,
          AppConstants.keyUseTor: true,
          AppConstants.keyWidgetShowFee: true,
          AppConstants.keyExplorerPreset: ExplorerPreset.custom.index,
        },
        {
          ...staleWallet,
          AppConstants.keyExplorerCustomUrl:
              'http://bag-test.invalid:${esplora.port}/api',
        },
      );
      answerPriceAndChart();

      expect(await runTask(), isTrue);

      expect(requests.seen.map((r) => r.uri.path), [
        '/api/price',
        '/api/chart',
      ]);
      for (final r in requests.seen) {
        expect(r.state, EmbeddedTorState.ready, reason: '${r.uri}');
        expect(r.port, native.socksPort, reason: '${r.uri}');
      }
      expect(native.startCalls, 1);
      expect(embedded.connectHosts, isNot(contains('bag-test.invalid')));
      expect(esplora.hits, 0);
      expect((await loadWalletsFromStorage()).single.lastSats, 1234);

      final usd = currencyFormatter('usd');
      expect(widgetStore['widget_price'], usd.format(50000));
      expect(widgetStore['widget_net_worth'], usd.format(50000 * 1234 / 1e8));
      expect(widgetStore['widget_route_ok'], isTrue);
      expect(widgetStore['widget_show_fee'], isFalse);
      expect(native.stopCalls, 1);
      expect(registry.names, isEmpty);
    });

    test('Tor not ready within 90 s: no request, nothing blanked or stamped, '
        'the cached sats kept; the lease is given back', () {
      fakeAsync((async) {
        seed({AppConstants.keyUseTor: true}, staleWallet);
        answerPriceAndChart();
        native.hold = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 89));
        expect(result, isNull, reason: 'gave up on Tor before 90 s');
        expect(native.startCalls, 1);
        expect(requests.seen, isEmpty);

        async.elapse(const Duration(seconds: 2));
        expect(result, isTrue);
        expect(requests.seen, isEmpty);
        expectCachedWidgetKept();

        List<WalletEntry>? wallets;
        double? btc;
        loadWalletsFromStorage().then((w) => wallets = w);
        loadBtcAmount().then((b) => btc = b);
        async.flushMicrotasks();
        expect(wallets!.single.lastSats, 1234);
        expect(wallets!.single.lastScanAt, DateTime(2026));
        expect(btc, 0.5);

        expect(native.stopCalls, greaterThanOrEqualTo(1));
        expect(EmbeddedTorService.state, EmbeddedTorState.off);
        expect(registry.names, isEmpty);
      });
    });

    test('Tor: requests go through Bag\'s own port, never 127.0.0.1:9050; '
        'when every one fails nothing is blanked or stamped, and the lease '
        'is given back', () async {
      final target = await TargetServer.start();
      addTearDown(target.close);
      final orbot = await startOrbotStandIn(targetPort: target.port);
      addTearDown(orbot.close);
      final embedded = await FakeSocks5Proxy.start(targetPort: target.port);
      addTearDown(embedded.close);
      native.socksPort = embedded.port;
      seed({AppConstants.keyUseTor: true});
      // Out over the route; TLS to the plain-HTTP target then fails.
      requests.passThrough = true;

      expect(await runTask(), isTrue);

      expect(requests.seen, isNotEmpty);
      expect(embedded.connectHosts.toSet(), {
        'bitbag.app',
        'api.coingecko.com',
        'api.kraken.com',
      });
      expect(orbot.connections, 0);
      expectCachedWidgetKept();
      expect(native.stopCalls, 1);
      expect(registry.names, isEmpty);
    });

    test('Tor: the lease is given back when the task throws', () async {
      seed({AppConstants.keyUseTor: true});
      answerPriceAndChart();
      failWidgetWrites = true;

      await expectLater(runTask(), throwsA(isA<PlatformException>()));

      expect(requests.seen, isNotEmpty);
      expect(native.stopCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(registry.names, isEmpty);
    });

    test('Tor: giving the lease back is bounded, after the native stop has '
        'gone out: TorHost gives a stop that never returns up after 90 s '
        '(N-b), inside the 3-min backstop', () {
      fakeAsync((async) {
        seed({AppConstants.keyUseTor: true});
        answerPriceAndChart();
        native.stopGate = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 1));
        expect(
          widgetStore['widget_price'],
          currencyFormatter('usd').format(50000),
        );
        expect(native.stopCalls, 1, reason: 'the native stop goes out first');
        expect(result, isNull);

        async.elapse(
          EmbeddedTorService.bootstrapTimeout - const Duration(seconds: 2),
        );
        expect(result, isNull, reason: 'gave up on the release too early');
        async.elapse(const Duration(seconds: 2));
        expect(result, isTrue);
        expect(
          EmbeddedTorService.bootstrapTimeout,
          lessThan(backgroundTorReleaseBudget),
        );
        native.releaseStop();
        async.flushMicrotasks();
      });
    });

    test(
      'Tor: a job that holds no role when it gives the lease back, whose '
      'native stop never returns, is bounded by the 3-min backstop alone',
      () {
        fakeAsync((async) {
          // This isolate ran a client earlier, so a stop here reaches the
          // native client even while it holds no role.
          TorHost.acquire(
            bootstrapBudget: const Duration(seconds: 5),
            stillTor: () async => true,
          ).then((lease) => lease.release());
          async.flushMicrotasks();
          expect(native.startCalls, 1);
          expect(native.stopCalls, 1);
          expect(registry.names, isEmpty);

          // A dead owner's mapping, which the job's acquire waits 500 ms on.
          final dead = RawReceivePort();
          registry.register(dead.sendPort, TorHost.portName);
          dead.close();
          seed({AppConstants.keyUseTor: true});
          answerPriceAndChart();
          native.stopGate = Completer<void>(); // never completes
          Object? result;
          runTask().then((r) => result = r);
          async.elapse(const Duration(milliseconds: 250));
          // Tor is switched off meanwhile: after removing the dead mapping the
          // job's route check fails, so it claims nothing and holds no role.
          SharedPreferences.setMockInitialValues({
            AppConstants.keySelectedCurrencies: ['usd'],
          });
          async.elapse(const Duration(seconds: 1));
          expect(native.startCalls, 1, reason: 'no claim, no native start');
          expect(native.stopCalls, 2, reason: 'the release\'s native stop');
          expect(EmbeddedTorService.state, EmbeddedTorState.off);
          expect(result, isNull);

          async.elapse(backgroundTorReleaseBudget - const Duration(seconds: 3));
          expect(result, isNull, reason: 'gave up on the release too early');
          async.elapse(const Duration(seconds: 3));
          expect(result, isTrue);
          native.releaseStop();
          async.flushMicrotasks();
        });
      },
    );

    for (final (name, prefs, secure) in [
      (
        'unreadable proxy settings',
        {AppConstants.keyUseProxy: true},
        <String, String>{},
      ),
      (
        'a proxy that is down',
        {AppConstants.keyUseProxy: true},
        {
          AppConstants.keyNetworkProxy: jsonEncode(
            const ProxyConfig(
              type: ProxyType.socks5,
              host: '127.0.0.1',
              port: 1, // nothing listens on port 1
            ).toJson(),
          ),
        },
      ),
    ]) {
      test('$name: no Tor, no request, nothing blanked or stamped, the cached '
          'sats kept', () async {
        seed(prefs, {...staleWallet, ...secure});
        answerPriceAndChart();

        expect(await runTask(), isTrue);

        expect(native.startCalls, 0);
        expect(requests.seen, isEmpty);
        expectCachedWidgetKept();
        final wallets = await loadWalletsFromStorage();
        expect(wallets.single.lastSats, 1234);
        expect(await loadBtcAmount(), 0.5);
      });
    }

    group('R-6: a route change reaches a run already going', () {
      Future<void> untilRequested(String path) => _until(
        () => requests.seen.any((r) => r.uri.path == path),
        reason: 'no $path request',
      );

      test('Direct, switched to Tor while the price was in flight: the run '
          'stops. The price it got is not written, no chart, fee or wallet '
          'request goes out, nothing is saved, and no route_ok (the flags '
          'changed, and the app\'s flag writer says paused for Tor)',
          () async {
        final esplora = await _Esplora.start();
        addTearDown(esplora.close);
        seed(
          {
            AppConstants.keyWidgetShowFee: true,
            AppConstants.keyExplorerPreset: ExplorerPreset.custom.index,
          },
          {
            ...staleWallet,
            AppConstants.keyExplorerCustomUrl:
                'http://127.0.0.1:${esplora.port}/api',
          },
        );
        answerPriceAndChart();
        final hold = requests.holds['/api/price'] = Completer<void>();
        final run = runTask();
        await untilRequested('/api/price');

        await (await SharedPreferences.getInstance()).setBool(
          AppConstants.keyUseTor,
          true,
        );
        hold.complete();

        expect(await run, isTrue);
        expect(requests.seen.map((r) => r.uri.path), ['/api/price']);
        expect(esplora.hits, 0);
        expect(widgetWrites, isEmpty);
        expect(widgetRedraws, 0);
        expect(native.startCalls, 0, reason: 'a Direct run started Tor');
        expect((await loadWalletsFromStorage()).single.lastSats, 1234);
        expect(await loadBtcAmount(), 0.5);
      });

      test('Direct, switched to Tor while the first wallet scanned: no '
          'further wallet is scanned, and nothing more is saved or drawn',
          () async {
        final esplora = await _Esplora.start();
        addTearDown(esplora.close);
        final firstAddress =
            buildAddressSource(WalletKind.zpub, _zpub).addressAt(0, 0);
        seed(
          {AppConstants.keyExplorerPreset: ExplorerPreset.custom.index},
          {
            'wallets_metadata': jsonEncode([
              for (final id in ['w1', 'w2'])
                {
                  'id': id,
                  'label': id,
                  'kind': 'zpub',
                  'lastSats': 1234,
                  'lastScanAt': DateTime(2026).millisecondsSinceEpoch,
                },
            ]),
            'wallet_zpub_w1': _zpub,
            'wallet_zpub_w2': _zpub,
            AppConstants.keyExplorerCustomUrl:
                'http://127.0.0.1:${esplora.port}/api',
          },
        );
        answerPriceAndChart();
        esplora.beforeFirstAnswer = () async {
          await (await SharedPreferences.getInstance()).setBool(
            AppConstants.keyUseTor,
            true,
          );
        };

        expect(await runTask(), isTrue);

        expect(esplora.addressHits[firstAddress], 1, reason: 'w2 scanned');
        // The price stage went out before the switch; the final batch
        // didn't.
        expect(widgetWrites, isNot(contains('widget_chart_prices')));
        expect(widgetRedraws, 0);
        for (final w in await loadWalletsFromStorage()) {
          expect(w.lastSats, 1234, reason: '${w.id} saved after the switch');
        }
        expect(await loadBtcAmount(), 0.5);
      });

      test('Direct, switched to Tor while the only wallet scanned: its scan '
          'is not saved, and the final batch is not written', () async {
        final esplora = await _Esplora.start();
        addTearDown(esplora.close);
        seed(
          {AppConstants.keyExplorerPreset: ExplorerPreset.custom.index},
          {
            ...staleWallet,
            AppConstants.keyExplorerCustomUrl:
                'http://127.0.0.1:${esplora.port}/api',
          },
        );
        esplora.funded[buildAddressSource(
              WalletKind.zpub,
              _zpub,
            ).addressAt(0, 0)] =
            5000;
        answerPriceAndChart();
        esplora.beforeFirstAnswer = () async {
          await (await SharedPreferences.getInstance()).setBool(
            AppConstants.keyUseTor,
            true,
          );
        };

        expect(await runTask(), isTrue);

        expect(esplora.hits, greaterThan(0));
        expect((await loadWalletsFromStorage()).single.lastSats, 1234);
        expect(await loadBtcAmount(), 0.5);
        expect(widgetWrites, isNot(contains('widget_chart_prices')));
        expect(widgetRedraws, 0);
      });

      test('Direct, switched to Tor while a price alert was shown (no fee, '
          'no wallet): the final batch is not written', () async {
        seed({
          AppConstants.keyPriceAlerts: jsonEncode([
            {
              'id': 'a1',
              'targetPrice': 45000.0,
              'currency': 'usd',
              'above': true,
              'fired': false,
            },
          ]),
        });
        answerPriceAndChart();
        onShow = () async {
          await (await SharedPreferences.getInstance()).setBool(
            AppConstants.keyUseTor,
            true,
          );
        };

        expect(await runTask(), isTrue);

        expect(shown, hasLength(1));
        expect(widgetWrites, isNot(contains('widget_chart_prices')));
        expect(widgetWrites, isNot(contains('widget_show_fee')));
        expect(widgetRedraws, 0);
      });

      Future<void> switchToTor() async => (await SharedPreferences.getInstance())
          .setBool(AppConstants.keyUseTor, true);
      // The default explorer, blockstream.info, answers /fee-estimates.
      const feePath = '/api/fee-estimates';
      final firingAlert = jsonEncode([
        {
          'id': 'a1',
          'targetPrice': 45000.0,
          'currency': 'usd',
          'above': true,
          'fired': false,
        },
      ]);

      test('switched while the price stage was written: no chart request',
          () async {
        seed({});
        answerPriceAndChart();
        var switched = false;
        onWidgetWrite = (id) async {
          if (id != 'widget_price' || switched) return;
          switched = true;
          await switchToTor();
        };

        expect(await runTask(), isTrue);

        expect(switched, isTrue);
        expect(requests.seen.map((r) => r.uri.path), ['/api/price']);
      });

      test('switched while the chart was in flight: no alert, no fee request',
          () async {
        seed({
          AppConstants.keyWidgetShowFee: true,
          AppConstants.keyPriceAlerts: firingAlert,
        });
        answerPriceAndChart();
        final hold = requests.holds['/api/chart'] = Completer<void>();
        final run = runTask();
        await untilRequested('/api/chart');
        await switchToTor();
        hold.complete();

        expect(await run, isTrue);
        expect(shown, isEmpty);
        expect(requests.seen.map((r) => r.uri.path), isNot(contains(feePath)));
      });

      test('switched while the fee was in flight: the estimate is not cached '
          'and no fee alert is checked', () async {
        seed({
          AppConstants.keyWidgetShowFee: true,
          AppConstants.keyFeeAlerts:
              '[{"id":"f","targetRate":10,"above":true}]',
        });
        answerPriceAndChart();
        requests.bodies[feePath] = <String, dynamic>{'1': 21, '3': 12, '6': 8};
        final hold = requests.holds[feePath] = Completer<void>();
        final run = runTask();
        await untilRequested(feePath);
        await switchToTor();
        hold.complete();

        expect(await run, isTrue);
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        expect(prefs.getString(AppConstants.keyFeeCache), isNull);
        expect(shown, isEmpty);
        expect(widgetWrites, isNot(contains('widget_fast_fee')));
      });

      test('one proxy edited to another while the price was in flight (the '
          'widget flags are unchanged): the run stops, and only says its '
          'route is paused, since nothing else would', () async {
        final first = await FakeSocks5Proxy.start(targetPort: 1);
        addTearDown(first.close);
        String proxy(int port) => jsonEncode(
          ProxyConfig(
            type: ProxyType.socks5,
            host: '127.0.0.1',
            port: port,
          ).toJson(),
        );
        seed(
          {AppConstants.keyUseProxy: true},
          {AppConstants.keyNetworkProxy: proxy(first.port)},
        );
        answerPriceAndChart();
        final hold = requests.holds['/api/price'] = Completer<void>();
        final run = runTask();
        await untilRequested('/api/price');

        await const FlutterSecureStorage().write(
          key: AppConstants.keyNetworkProxy,
          value: proxy(first.port + 1),
        );
        hold.complete();

        expect(await run, isTrue);
        expect(requests.seen.map((r) => r.uri.path), ['/api/price']);
        expect(widgetWrites, ['widget_route_ok']);
        expect(widgetStore['widget_route_ok'], isFalse);
        expect(widgetStore['widget_fetched_at'], _earlierFetch);
        expect(widgetRedraws, 1);
      });
    });

    test('TB-8: no selected currency stored: the run falls back to usd, as '
        'the iOS refresh and the foreground do, instead of throwing',
        () async {
      seed({AppConstants.keySelectedCurrencies: <String>[]});
      answerPriceAndChart();

      expect(await runTask(), isTrue);

      expect(
        widgetStore['widget_price'],
        currencyFormatter('usd').format(50000),
      );
      expect(widgetStore['widget_route_ok'], isTrue);
    });

    group('the periodic job and the configure activity\'s one-off overlap '
        '(TB-5)', () {
      String alerts({required bool fired}) => jsonEncode([
        {
          'id': 'a1',
          'targetPrice': 45000.0,
          'currency': 'usd',
          'above': true,
          'fired': fired,
        },
      ]);

      test('an alert another run fired while this one fetched is not fired '
          'again; one this run fires is stored as fired before it is shown',
          () async {
        seed({AppConstants.keyPriceAlerts: alerts(fired: false)});
        answerPriceAndChart();
        final hold = requests.holds['/api/price'] = Completer<void>();
        final run = runTask();
        await _until(
          () => requests.seen.any((r) => r.uri.path == '/api/price'),
          reason: 'no price request',
        );
        // The other engine's run fired it meanwhile and stored that. Its
        // prefs are its own: this run's cache still says not fired.
        SharedPreferences.setMockInitialValues({
          AppConstants.keySelectedCurrencies: ['usd'],
          AppConstants.keyProUnlocked: true,
          AppConstants.keyPriceAlerts: alerts(fired: true),
        });
        hold.complete();

        expect(await run, isTrue);
        expect(shown, isEmpty, reason: 'the alert fired twice');

        // A run on its own fires it once, and has stored it as fired by
        // the time it is shown, so a run that overlaps it reads it so.
        seed({AppConstants.keyPriceAlerts: alerts(fired: false)});
        expect(await runTask(), isTrue);
        expect(shown, hasLength(1));
        expect(
          PriceAlert.listFromJsonString(shown.single.alertsStored!).single.fired,
          isTrue,
          reason: 'shown before it was stored as fired',
        );
        // And the next run, sharing those prefs, fires nothing.
        expect(await runTask(), isTrue);
        expect(shown, hasLength(1));
      });

      test('a wallet another run scanned while this one scanned the one '
          'before it is not scanned again, and its fresh balance is kept',
          () async {
        final esplora = await _Esplora.start();
        addTearDown(esplora.close);
        final firstAddress =
            buildAddressSource(WalletKind.zpub, _zpub).addressAt(0, 0);
        seed(
          {AppConstants.keyExplorerPreset: ExplorerPreset.custom.index},
          {
            'wallets_metadata': jsonEncode([
              for (final id in ['w1', 'w2'])
                {
                  'id': id,
                  'label': id,
                  'kind': 'zpub',
                  'lastSats': 1234,
                  'lastScanAt': DateTime(2026).millisecondsSinceEpoch,
                },
            ]),
            'wallet_zpub_w1': _zpub,
            'wallet_zpub_w2': _zpub,
            AppConstants.keyExplorerCustomUrl:
                'http://127.0.0.1:${esplora.port}/api',
          },
        );
        answerPriceAndChart();
        // While this run scans w1, the other run scans w2 and stores it.
        esplora.beforeFirstAnswer = () async {
          final stored = await loadWalletsFromStorage();
          await saveWalletsToStorage([
            for (final w in stored)
              w.id == 'w2'
                  ? w.copyWith(lastSats: 7777, lastScanAt: DateTime.now())
                  : w,
          ]);
        };

        expect(await runTask(), isTrue);

        expect(
          esplora.addressHits[firstAddress],
          1,
          reason: 'w2 was scanned again',
        );
        final wallets = {
          for (final w in await loadWalletsFromStorage()) w.id: w,
        };
        expect(wallets['w2']!.lastSats, 7777);
        expect(wallets['w1']!.lastSats, 0, reason: 'w1 was not scanned');
      });

      // tor-bg note 1: the run applies only what its scan found onto the
      // wallet as stored when it saves, so an edit the user made meanwhile
      // (a rename in the app) is kept, not reverted to the run's snapshot.
      test('a wallet renamed while this run scanned it keeps the new name, '
          'and gets the scan\'s balance', () async {
        final esplora = await _Esplora.start();
        addTearDown(esplora.close);
        final before = DateTime(2026);
        seed(
          {AppConstants.keyExplorerPreset: ExplorerPreset.custom.index},
          {
            'wallets_metadata': jsonEncode([
              {
                'id': 'w1',
                'label': 'Cold',
                'kind': 'zpub',
                'lastSats': 1234,
                'lastScanAt': before.millisecondsSinceEpoch,
              },
            ]),
            'wallet_zpub_w1': _zpub,
            AppConstants.keyExplorerCustomUrl:
                'http://127.0.0.1:${esplora.port}/api',
          },
        );
        answerPriceAndChart();
        esplora.beforeFirstAnswer = () async {
          final stored = await loadWalletsFromStorage();
          await saveWalletsToStorage([
            for (final w in stored) w.copyWith(label: 'Savings'),
          ]);
        };

        expect(await runTask(), isTrue);

        final w1 = (await loadWalletsFromStorage()).single;
        expect(w1.label, 'Savings', reason: 'the rename was reverted');
        expect(w1.lastSats, 0, reason: 'the scan was not applied');
        expect(w1.lastScanAt!.isAfter(before), isTrue);
      });
    });

    group('widget route keys (Task A5)', () {
      // The rules the foreground follows (test/widget/widget_route_keys_test
      // .dart): `widget_route_ok` says whether this run's price came through
      // the route, and `widget_fetched_at` when the price on the widget was
      // fetched, written only with a price.

      test('Direct, a price: fetched_at is when it was fetched, route_ok '
          'true, and nothing writes widget_updated_at', () async {
        seed({});
        answerPriceAndChart();
        final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;

        expect(await runTask(), isTrue);

        final after = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        expect(widgetStore['widget_fetched_at'], inInclusiveRange(before, after));
        expect(widgetStore['widget_route_ok'], isTrue);
        expect(widgetWrites, isNot(contains('widget_updated_at')));
        expect(widgetRedraws, 1);
      });

      test('Direct, every source fails: route_ok false, the price and its '
          'time kept (Direct has no dot; its time shows paused)', () async {
        seed({});
        // No canned bodies: every request fails.

        expect(await runTask(), isTrue);

        expect(requests.seen, isNotEmpty, reason: 'the fetch was tried');
        expectCachedWidgetKept();
      });

      test('Tor, the chart came but the price didn\'t: route_ok is the '
          'price\'s, false, and fetched_at stays', () async {
        seed({AppConstants.keyUseTor: true});
        requests.bodies['/api/chart'] = <String, dynamic>{
          'd': [
            [0, 49000.0],
            [1, 50000.0],
          ],
        };

        expect(await runTask(), isTrue);

        expect(widgetStore['widget_chart_prices'], '[49000.0,50000.0]');
        expect(widgetStore['widget_route_ok'], isFalse);
        expect(widgetStore['widget_fetched_at'], _earlierFetch);
        expect(widgetStore['widget_price'], r'$40,000.00');
      });

      test('the price stage is on the widget as soon as it is done: a run '
          'cut off later at its deadline has written its price, time and '
          'route_ok (M6)', () async {
        WidgetService.debugBackgroundTaskBudget = const Duration(
          milliseconds: 300,
        );
        seed({});
        answerPriceAndChart();
        final hang = requests.holds['/api/chart'] = Completer<void>();
        final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;

        expect(await runTask(), isTrue);

        final after = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        // One redraw, the deadline's (round 2): the final batch hasn't run.
        expect(widgetRedraws, 1);
        final usd = currencyFormatter('usd');
        expect(widgetStore['widget_price'], usd.format(50000));
        expect(widgetStore['widget_net_worth'], usd.format(25000));
        expect(widgetStore['widget_route_ok'], isTrue);
        expect(
          widgetStore['widget_fetched_at'],
          inInclusiveRange(before, after),
        );
        hang.complete();
        await _until(() => widgetRedraws == 2, reason: 'the body never ended');
      });

      test('a run whose price failed has said so before a later stage hangs '
          'past its deadline, so no stale route_ok true is left (M6), and '
          'the deadline redraws at once, so "Paused" shows (round 2)', () async {
        WidgetService.debugBackgroundTaskBudget = const Duration(
          milliseconds: 300,
        );
        seed({});
        // No price anywhere; the chart answers, but only after the deadline.
        requests.bodies['/api/chart'] = <String, dynamic>{
          'd': [
            [0, 49000.0],
            [1, 50000.0],
          ],
        };
        final hang = requests.holds['/api/chart'] = Completer<void>();

        expect(await runTask(), isTrue);

        expect(widgetStore['widget_route_ok'], isFalse);
        expect(widgetStore['widget_fetched_at'], _earlierFetch);
        expect(widgetStore['widget_price'], r'$40,000.00');
        expect(widgetRedraws, 1, reason: 'the paused state not drawn');
        hang.complete();
        await _until(() => widgetRedraws == 2, reason: 'the body never ended');
      });

      test('the timeframe changed while the run fetched (the configure '
          'activity): the chart it fetched for the old one is not written, '
          'the price still is (M5)', () async {
        seed({'widget_timeframe_days': 7});
        answerPriceAndChart();
        final hold = requests.holds['/api/chart'] = Completer<void>();
        final run = runTask();
        await _until(
          () => requests.seen.any((r) => r.uri.path == '/api/chart'),
          reason: 'no chart request',
        );

        await (await SharedPreferences.getInstance()).setInt(
          'widget_timeframe_days',
          30,
        );
        hold.complete();

        expect(await run, isTrue);
        expect(widgetWrites, isNot(contains('widget_chart_prices')));
        expect(widgetStore['widget_chart_prices'], '[39000.0,40000.0]');
        expect(
          widgetStore['widget_price'],
          currencyFormatter('usd').format(50000),
        );
        // The change the widget shows is then the 24 h one, not the old
        // timeframe's.
        expect(widgetStore['widget_change'], '+1.5%');
      });
    });
  });

  // ── Sentinel ────────────────────────────────────────────────────────────

  group('Sentinel', () {
    late _Esplora esplora;
    late FakeSocks5Proxy embedded;

    setUp(() async {
      esplora = await _Esplora.start();
      embedded = await FakeSocks5Proxy.start(targetPort: esplora.port);
      native.socksPort = embedded.port;
    });

    tearDown(() async {
      await embedded.close();
      await esplora.close();
    });

    /// Pro, Tor on, and (with [wallet]) one watch-only wallet on a custom
    /// explorer at [explorerHost] that only [esplora] answers, through the
    /// SOCKS proxy (or directly, at 127.0.0.1).
    void seedSentinel({
      bool wallet = true,
      String explorerHost = 'bag-test.invalid',
      bool tor = true,
      Map<String, String> secure = const {},
    }) => seed(
      {
        AppConstants.keyProUnlocked: true,
        AppConstants.keyUseTor: tor,
        AppConstants.keyExplorerPreset: ExplorerPreset.custom.index,
      },
      {
        if (wallet) ...{
          'wallets_metadata': jsonEncode([
            {'id': 'w1', 'label': 'Cold', 'kind': 'zpub'},
          ]),
          'wallet_zpub_w1': _zpub,
        },
        AppConstants.keyExplorerCustomUrl:
            'http://$explorerHost:${esplora.port}/api',
        ...secure,
      },
    );

    Future<String?> readSecure(String key) =>
        const FlutterSecureStorage().read(key: key);

    Future<void> writeWallets(List<Map<String, Object>> wallets) =>
        const FlutterSecureStorage().write(
          key: 'wallets_metadata',
          value: jsonEncode(wallets),
        );

    Future<void> tick(SentinelTaskHandler handler) {
      handler.onRepeatEvent(DateTime.now());
      return handler.debugTick;
    }

    Future<void> setUseTor(bool on) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(AppConstants.keyUseTor, on);
    }

    test(
      'onStart takes one lease and waits for Tor, saying so; the scan and '
      'every tick go through Bag\'s own port, never 127.0.0.1:9050',
      () async {
        final orbot = await startOrbotStandIn(targetPort: esplora.port);
        addTearDown(orbot.close);
        seedSentinel();
        native.hold = Completer<void>();
        final handler = SentinelTaskHandler();

        final starting = handler.onStart(DateTime.now(), TaskStarter.developer);
        await _until(
          () => notifications.contains('Waiting for Tor…'),
          reason: 'the wait for Tor is not shown',
        );
        expect(esplora.hits, 0);
        expect(native.startCalls, 1);

        native.releaseStart();
        await starting;
        await _until(
          () => notifications.last.startsWith('Wallets & mempool · '),
          reason: 'the full scan did not complete',
        );
        expect(esplora.hits, greaterThan(0));
        expect(embedded.connectHosts.toSet(), {'bag-test.invalid'});

        for (var i = 0; i < 2; i++) {
          final hits = esplora.hits;
          notifications.clear();
          await tick(handler);
          await _until(
            () => notifications.any((n) => n.startsWith('Mempool checked · ')),
            reason: 'tick ${i + 1} did not complete',
          );
          expect(esplora.hits, greaterThan(hits));
        }
        expect(native.startCalls, 1, reason: 'one lease, taken once');
        expect(orbot.connections, 0);

        await handler.onDestroy(DateTime.now());
      },
    );

    group('R-6: a route change reaches a tick already going', () {
      void seedTwoWallets() => seedSentinel(
        explorerHost: '127.0.0.1',
        tor: false,
        secure: {
          'wallets_metadata': jsonEncode([
            {'id': 'w1', 'label': 'Cold', 'kind': 'zpub'},
            {'id': 'w2', 'label': 'Warm', 'kind': 'zpub'},
          ]),
          'wallet_zpub_w2': _zpub,
        },
      );

      test('Direct, switched to Tor while the first wallet scanned: the '
          'second is not scanned, nothing is saved or stamped, and the next '
          'tick is a full scan', () async {
        seedTwoWallets();
        final firstAddress =
            buildAddressSource(WalletKind.zpub, _zpub).addressAt(0, 0);
        esplora.beforeFirstAnswer = () => setUseTor(true);
        final handler = SentinelTaskHandler();

        await handler.onStart(DateTime.now(), TaskStarter.developer);

        // Its mempool check would query the address again too.
        expect(esplora.addressHits[firstAddress], 1, reason: 'w2 scanned');
        expect(await readSecure(AppConstants.keySentinelWatchMap), isNull);
        expect(await readSecure(AppConstants.keySentinelBalances), isNull);
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        expect(prefs.getString(AppConstants.keySentinelLastScan), isNull);
        expect(
          notifications.where((n) => n.startsWith('Wallets & mempool')),
          isEmpty,
        );
        expect(native.startCalls, 0, reason: 'the Direct tick started Tor');

        // The next tick, whatever its number, scans in full on Tor.
        await tick(handler);
        expect(native.startCalls, 1);
        await handler.onDestroy(DateTime.now());
      });

      test('Direct, switched to Tor while the only wallet scanned: no watch '
          'map is saved and no mempool address queried', () async {
        seedSentinel(explorerHost: '127.0.0.1', tor: false);
        final firstAddress =
            buildAddressSource(WalletKind.zpub, _zpub).addressAt(0, 0);
        esplora.beforeFirstAnswer = () => setUseTor(true);
        final handler = SentinelTaskHandler();

        await handler.onStart(DateTime.now(), TaskStarter.developer);

        expect(esplora.addressHits[firstAddress], 1);
        expect(await readSecure(AppConstants.keySentinelWatchMap), isNull);
        expect(await readSecure(AppConstants.keySentinelBalances), isNull);
        await handler.onDestroy(DateTime.now());
      });

      test('Direct, switched to Tor during a mempool tick: no further '
          'watched address is queried, and the tick stamps nothing', () async {
        seedSentinel(explorerHost: '127.0.0.1', tor: false);
        final handler = SentinelTaskHandler();
        await handler.onStart(DateTime.now(), TaskStarter.developer);
        final watched = jsonDecode(
          (await readSecure(AppConstants.keySentinelWatchMap))!,
        ) as Map;
        expect(watched.length, greaterThan(2));
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final stamped = prefs.getString(AppConstants.keySentinelLastScan);
        expect(stamped, isNotNull);

        esplora.addressHits.clear();
        var mempoolHits = 0;
        esplora.beforeFirstAnswer = () => setUseTor(true);
        await tick(handler);
        for (final e in esplora.addressHits.entries) {
          mempoolHits += e.value;
        }

        expect(mempoolHits, 1, reason: 'queried after the switch');
        await prefs.reload();
        expect(prefs.getString(AppConstants.keySentinelLastScan), stamped);
        expect(
          notifications.where((n) => n.startsWith('Mempool checked')),
          isEmpty,
        );
        await handler.onDestroy(DateTime.now());
      });
    });

    test('each tick follows the route: the lease is given back when it '
        'leaves Tor and taken again when it returns', () async {
      seedSentinel(explorerHost: '127.0.0.1');
      final handler = SentinelTaskHandler();
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(native.startCalls, 1);
      expect(await TorHost.port(), native.socksPort);

      await setUseTor(false);
      await tick(handler);
      expect(native.stopCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(await TorHost.port(), -1);
      expect(registry.names, isEmpty);

      await setUseTor(true);
      await tick(handler);
      expect(native.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);

      await handler.onDestroy(DateTime.now());
    });

    test('a failed client is taken again on the next tick, and so is one '
        'the app switched off while the route is Tor again', () async {
      seedSentinel();
      native.failNext = true;
      final handler = SentinelTaskHandler();
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(native.startCalls, 1);
      // Sentinel runs the client; other isolates find it under this port.
      final owner = registry.lookup(TorHost.portName);
      expect(owner, isNotNull);

      await tick(handler);
      expect(native.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      // Taken again before the old lease went: ownership was never given
      // up, so nobody leasing it was handed over.
      expect(registry.lookup(TorHost.portName), owner);

      // The app switched Tor off, and on again before this tick.
      owner!.send(const {'op': 'stop'});
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.off);
      await tick(handler);
      expect(native.startCalls, 3);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(registry.lookup(TorHost.portName), owner);

      await handler.onDestroy(DateTime.now());
    });

    test('onDestroy gives the lease back: the client Sentinel runs stops and '
        'its mapping goes', () async {
      seedSentinel();
      final handler = SentinelTaskHandler();
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(registry.names, isNotEmpty);

      await handler.onDestroy(DateTime.now());

      expect(native.stopCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(await TorHost.port(), -1);
      expect(registry.names, isEmpty);

      // A tick that still arrives takes no new lease.
      await tick(handler);
      expect(native.startCalls, 1);
    });

    test('onDestroy while a tick waits for Tor: the lease is already in '
        'hand, so it is given back and nothing is fetched', () async {
      seedSentinel();
      native.hold = Completer<void>();
      final handler = SentinelTaskHandler();
      final starting = handler.onStart(DateTime.now(), TaskStarter.developer);
      await _until(() => notifications.contains('Waiting for Tor…'));

      await handler.onDestroy(DateTime.now());
      expect(native.stopCalls, 1);
      expect(registry.names, isEmpty);

      await starting;
      expect(esplora.hits, 0);
      expect(embedded.connections, 0);
    });

    test('onDestroy is bounded at 30 s when the native stop hangs', () {
      fakeAsync((async) {
        seedSentinel();
        // Held, so no scan reaches a socket in fake time.
        native.hold = Completer<void>();
        final handler = SentinelTaskHandler();
        handler.onStart(DateTime.now(), TaskStarter.developer);
        async.elapse(const Duration(seconds: 1));
        expect(EmbeddedTorService.state, EmbeddedTorState.starting);

        native.stopGate = Completer<void>();
        var destroyed = false;
        handler.onDestroy(DateTime.now()).then((_) => destroyed = true);
        async.elapse(const Duration(seconds: 1));
        expect(native.stopCalls, 1, reason: 'the native stop goes out first');
        expect(destroyed, isFalse);

        async.elapse(const Duration(seconds: 28));
        expect(destroyed, isFalse, reason: 'gave up before 30 s');
        async.elapse(const Duration(seconds: 2));
        expect(destroyed, isTrue);
        native.releaseStop();
        async.flushMicrotasks();
      });
    });

    // ── Ruling 2: a lease only while there are wallets to watch ─────────

    test('no watch-only wallets: no lease, no Tor started, the registry '
        'stays empty', () async {
      seedSentinel(wallet: false);
      final handler = SentinelTaskHandler();
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      await tick(handler);
      await tick(handler);

      expect(native.startCalls, 0);
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(registry.names, isEmpty);
      await _until(() => notifications.contains('No wallets connected'));
      await handler.onDestroy(DateTime.now());
    });

    test('a wallet added: the next full scan takes the lease; mempool ticks '
        'before it take none', () async {
      seedSentinel(wallet: false);
      final handler = SentinelTaskHandler();
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      await writeWallets([
        {'id': 'w1', 'label': 'Cold', 'kind': 'zpub'},
      ]);
      await const FlutterSecureStorage().write(
        key: 'wallet_zpub_w1',
        value: _zpub,
      );

      for (var t = 1; t < AppConstants.sentinelFullScanEveryNTicks; t++) {
        await tick(handler);
        expect(native.startCalls, 0, reason: 'mempool tick $t');
      }
      await tick(handler); // the full scan
      expect(native.startCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(esplora.hits, greaterThan(0));
      await handler.onDestroy(DateTime.now());
    });

    test(
      'wallets removed: mempool ticks keep the lease until the next full '
      'scan, which gives it back and stops the client Sentinel ran',
      () async {
        seedSentinel();
        final handler = SentinelTaskHandler();
        await handler.onStart(DateTime.now(), TaskStarter.developer);
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);
        await writeWallets([]);

        for (var t = 1; t < AppConstants.sentinelFullScanEveryNTicks; t++) {
          await tick(handler);
          expect(native.stopCalls, 0, reason: 'mempool tick $t');
        }
        await tick(handler); // the full scan
        expect(native.stopCalls, 1);
        expect(EmbeddedTorService.state, EmbeddedTorState.off);
        expect(registry.names, isEmpty);

        // The old watch map is still there, but the last full scan had no
        // wallets: a mempool tick takes no lease for it.
        await tick(handler);
        expect(native.startCalls, 1);
        await handler.onDestroy(DateTime.now());
      },
    );

    test('wallets that have not scanned yet: mempool ticks keep the lease '
        'over an empty watch map', () async {
      seedSentinel();
      esplora.failing = true;
      final handler = SentinelTaskHandler();
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);

      await tick(handler);
      await tick(handler);
      expect(native.stopCalls, 0);
      expect(native.startCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      await handler.onDestroy(DateTime.now());
    });

    // ── Ruling 1: a failed client backs off ─────────────────────────────

    test('a failed client is retried on the 1st, 3rd and 7th tick after it '
        'was seen, then every 5th (retries 2, 4 and 8 min apart, then every '
        '10 min); the copy is unchanged', () {
      fakeAsync((async) {
        seedSentinel();
        native.failAlways = true;
        final handler = SentinelTaskHandler();
        handler.onStart(DateTime.now(), TaskStarter.developer);
        async.elapse(const Duration(seconds: 1));
        expect(native.startCalls, 1);
        expect(EmbeddedTorService.state, EmbeddedTorState.failed);

        final retries = <int>[];
        for (var t = 1; t <= 15; t++) {
          final before = native.startCalls;
          handler.onRepeatEvent(DateTime.now());
          async.elapse(const Duration(minutes: 2));
          if (native.startCalls > before) retries.add(t);
        }
        expect(retries, [1, 3, 7, 12]);
        expect(notifications.last, 'Waiting for Tor…');

        handler.onDestroy(DateTime.now());
        async.elapse(const Duration(seconds: 1));
      });
    });

    test('the backoff resets once the client is ready; the first tick after '
        'recovery is a full scan; a client switched off is taken again on '
        'the next tick, backoff or not', () async {
      seedSentinel();
      native.failAlways = true;
      final handler = SentinelTaskHandler();
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      await tick(handler); // tick 1: retried, fails again
      expect(native.startCalls, 2);

      native.failAlways = false;
      await tick(handler); // tick 2: no retry due
      expect(native.startCalls, 2);
      notifications.clear();
      await tick(handler); // tick 3: retried, ready
      expect(native.startCalls, 3);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      await _until(
        () => notifications.any((n) => n.startsWith('Wallets & mempool · ')),
        reason: 'tick 3 was not a full scan',
      );

      // It dies; its one automatic retry fails too (M2).
      native.failAlways = true;
      native.die();
      await _until(
        () =>
            native.startCalls == 4 &&
            EmbeddedTorService.state == EmbeddedTorState.failed,
      );
      // Seen anew on tick 4, so retried on ticks 5, 7 and 11: the schedule
      // started again rather than going on from the first failure (that
      // would be tick 7 only).
      final retries = <int>[];
      for (var t = 4; t <= 11; t++) {
        final before = native.startCalls;
        await tick(handler);
        if (native.startCalls > before) retries.add(t);
      }
      expect(retries, [5, 7, 11]);

      // Tick 12 is no retry tick, but a client the app switched off (the
      // route is Tor again by now) is taken again at once.
      registry.lookup(TorHost.portName)!.send(const {'op': 'stop'});
      await _until(() => EmbeddedTorService.state == EmbeddedTorState.off);
      final before = native.startCalls;
      await tick(handler);
      expect(native.startCalls, before + 1);

      await handler.onDestroy(DateTime.now());
    });

    // ── N1: no watching once the wallets are gone ───────────────────────

    test('the last wallet removed: the next full scan deletes the watch map '
        'and the seen txids, and mempool ticks query nothing after it '
        '(Direct)', () async {
      seedSentinel(
        tor: false,
        explorerHost: '127.0.0.1',
        secure: {
          AppConstants.keySentinelSeenTxids: jsonEncode({
            'ab' * 32: {
              'wid': 'w1',
              'wlabel': 'Cold',
              'dir': 'in',
              'sats': 1000,
              'seenAt': DateTime.now().toIso8601String(),
              'nid': 1,
              'conf': false,
            },
          }),
        },
      );
      final handler = SentinelTaskHandler();
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      expect(await readSecure(AppConstants.keySentinelWatchMap), isNotNull);
      expect(await readSecure(AppConstants.keySentinelSeenTxids), isNotNull);

      await writeWallets([]);
      for (var t = 1; t <= AppConstants.sentinelFullScanEveryNTicks; t++) {
        await tick(handler); // ticks 1–4 mempool, tick 5 the full scan
      }
      expect(await readSecure(AppConstants.keySentinelWatchMap), isNull);
      expect(await readSecure(AppConstants.keySentinelSeenTxids), isNull);

      final hits = esplora.hits;
      await tick(handler);
      await tick(handler);
      expect(esplora.hits, hits);
      await handler.onDestroy(DateTime.now());
    });

    test('a mempool tick never queries a watch map that no full scan of '
        'wallets stands behind', () async {
      seedSentinel(
        wallet: false,
        tor: false,
        explorerHost: '127.0.0.1',
        secure: {
          AppConstants.keySentinelWatchMap: jsonEncode({
            'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu': {
              'wid': 'w1',
              'wlabel': 'Cold',
            },
          }),
        },
      );
      // No full scan has found wallets in this handler.
      final handler = SentinelTaskHandler();
      await tick(handler);
      expect(esplora.hits, 0);
      await handler.onDestroy(DateTime.now());
    });

    test('Tor: once there are no wallets, no "Waiting for Tor…"', () async {
      seedSentinel();
      final handler = SentinelTaskHandler();
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      await writeWallets([]);
      for (var t = 1; t < AppConstants.sentinelFullScanEveryNTicks; t++) {
        await tick(handler);
      }
      notifications.clear();
      await tick(handler); // the full scan: lease given back
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      await tick(handler);
      await tick(handler);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(notifications, contains('No wallets connected'));
      expect(notifications, isNot(contains('Waiting for Tor…')));
      await handler.onDestroy(DateTime.now());
    });

    // ── M8 ──────────────────────────────────────────────────────────────

    // net R-3: the balances blob is pruned to the wallets as stored when it
    // is written. A removal that raced the scan (its purge ran while the
    // scan still held the removed wallet's balance), or one whose entry an
    // earlier scan wrote back, leaves no balance behind.
    test('a full scan writes balances only for wallets that still exist',
        () async {
      seedSentinel(
        explorerHost: '127.0.0.1',
        tor: false,
        secure: {
          'wallets_metadata': jsonEncode([
            {'id': 'w1', 'label': 'Cold', 'kind': 'zpub'},
            {'id': 'w2', 'label': 'Warm', 'kind': 'zpub'},
          ]),
          'wallet_zpub_w2': _zpub,
          AppConstants.keySentinelBalances:
              jsonEncode({'w1': 0, 'w2': 0, 'gone': 5000}),
        },
      );
      // While the scan works on w1, the user removes w2.
      esplora.beforeFirstAnswer = () async {
        await writeWallets([
          {'id': 'w1', 'label': 'Cold', 'kind': 'zpub'},
        ]);
        await purgeSentinelWallet('w2');
      };
      final handler = SentinelTaskHandler();

      await handler.onStart(DateTime.now(), TaskStarter.developer);

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(
        prefs.getString(AppConstants.keySentinelLastScan),
        isNotNull,
        reason: 'the full scan did not complete',
      );
      expect(
        jsonDecode((await readSecure(AppConstants.keySentinelBalances))!),
        {'w1': 0},
      );

      // And once no watch-only wallet is left, no balance is kept at all.
      await writeWallets([]);
      await const FlutterSecureStorage().write(
        key: AppConstants.keySentinelBalances,
        value: jsonEncode({'w1': 0}),
      );
      for (var t = 1; t <= AppConstants.sentinelFullScanEveryNTicks; t++) {
        await tick(handler); // ticks 1–4 mempool, tick 5 the full scan
      }
      expect(await readSecure(AppConstants.keySentinelBalances), isNull);
      await handler.onDestroy(DateTime.now());
    });

    test('a full scan in which no wallet scanned keeps the previous watch map '
        'and shows no success copy', () async {
      seedSentinel();
      final handler = SentinelTaskHandler();
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      final watchMap = await const FlutterSecureStorage().read(
        key: AppConstants.keySentinelWatchMap,
      );
      expect(jsonDecode(watchMap!) as Map, isNotEmpty);

      esplora.failing = true;
      for (var t = 1; t < AppConstants.sentinelFullScanEveryNTicks; t++) {
        await tick(handler);
      }
      notifications.clear();
      await tick(handler); // the full scan
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        await const FlutterSecureStorage().read(
          key: AppConstants.keySentinelWatchMap,
        ),
        watchMap,
      );
      expect(
        notifications.where((n) => n.startsWith('Wallets & mempool')),
        isEmpty,
      );
      await handler.onDestroy(DateTime.now());
    });
  });

  // ── The route re-check background isolates pass to TorHost.acquire ──────

  group('torRouteStillSelected', () {
    test('true only for Tor, read from reloaded prefs', () async {
      SharedPreferences.setMockInitialValues({AppConstants.keyUseTor: true});
      expect(await torRouteStillSelected(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(AppConstants.keyUseTor, false);
      expect(await torRouteStillSelected(), isFalse);

      FlutterSecureStorage.setMockInitialValues({});
      await prefs.setBool(AppConstants.keyUseProxy, true);
      expect(await torRouteStillSelected(), isFalse);
    });

    test('a read that throws is false', () async {
      expect(
        await torRouteStillSelected(
          loadPrefs: () => Future.error(StateError('prefs unreadable')),
        ),
        isFalse,
      );
    });

    test('a read that takes longer than 5 s is false', () {
      fakeAsync((async) {
        bool? answer;
        torRouteStillSelected(
          loadPrefs: () => Completer<SharedPreferences>().future,
        ).then((a) => answer = a);
        async.elapse(const Duration(milliseconds: 4900));
        expect(answer, isNull);
        async.elapse(const Duration(milliseconds: 200));
        expect(answer, isFalse);
      });
    });
  });

  // ── Source shape ────────────────────────────────────────────────────────

  group('source', () {
    /// Generated or vendored trees under android/ and ios/.
    const skipped = {
      'build',
      '.gradle',
      '.cxx',
      '.dart_tool',
      'Pods',
      'ephemeral',
      '.symlinks',
    };
    const textExtensions = {
      '.dart',
      '.kt',
      '.kts',
      '.java',
      '.gradle',
      '.xml',
      '.properties',
      '.pro',
      '.swift',
      '.m',
      '.h',
      '.plist',
      '.pbxproj',
      '.entitlements',
      '.xcconfig',
      '.json',
    };

    Iterable<File> sources(String root) sync* {
      final dir = Directory(root);
      if (!dir.existsSync()) return; // ios/ is absent in the public snapshot
      final pending = [dir];
      while (pending.isNotEmpty) {
        for (final entity in pending.removeLast().listSync()) {
          final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
          if (entity is Directory) {
            if (!skipped.contains(name)) pending.add(entity);
          } else if (entity is File &&
              textExtensions.any((ext) => name.endsWith(ext))) {
            yield entity;
          }
        }
      }
    }

    test('the Android job fetches the widget\'s price and chart through the '
        'helpers the iOS refresh uses, with no copy of its own (D1)', () {
      final src = File('lib/services/widget_service.dart').readAsStringSync();
      final start = src.indexOf('void backgroundWidgetCallback()');
      final end = src.indexOf('Workmanager().executeTask(', start);
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final body = src.substring(start, end);
      expect(body, contains('await _widgetSpot(dio, currency)'));
      expect(body, contains('await _widgetCloses(dio, currency, timeframeDays)'));
      for (final copy in [
        '/price',
        '/chart',
        '/simple/price',
        '_widgetKrakenCloses(',
        'divideAlignedTails(',
      ]) {
        expect(body, isNot(contains(copy)), reason: copy);
      }
    });

    test('nothing in lib/, android/ or ios/ names port 9050', () {
      final orbotPort = RegExp(r'\b9050\b');
      final offenders = [
        for (final root in ['lib', 'android', 'ios'])
          for (final file in sources(root))
            for (final (i, line) in file.readAsLinesSync().indexed)
              if (orbotPort.hasMatch(line)) '${file.path}:${i + 1}: $line',
      ];
      expect(offenders, isEmpty);
    });

    test('the Kotlin chart worker skips with Tor on, before any request, '
        'and has no SOCKS proxy left', () {
      final file = File(
        'android/app/src/main/kotlin/app/bitbag/NativeChartRefreshWorker.kt',
      );
      final source = file.readAsStringSync();
      final skip = RegExp(
        r'if \(flutterPrefs\.getBoolean\("flutter\.use_tor", false\)\) \{\s*'
        r'Log\.i\(TAG, "Built-in Tor on: skipping native chart refresh"\)\s*'
        r'return Result\.success\(\)\s*\}',
      ).firstMatch(source);
      expect(skip, isNotNull, reason: 'no early skip with Tor on');
      final firstFetch = source.indexOf('fetchKrakenPrices(pair');
      expect(firstFetch, greaterThan(skip!.end));
      // Re-read right before the request: a route switched on since then.
      final open = source.indexOf('openConnection(');
      final recheck = source.lastIndexOf(
        'if (applicationContext.privateRouteOn())',
        open,
      );
      expect(
        recheck,
        greaterThan(source.indexOf('private fun fetchKrakenPrices(')),
        reason: 'no re-check in fetchKrakenPrices before the request',
      );
      for (final gone in [
        'isOrbotReachable',
        'Proxy.Type.SOCKS',
        'InetSocketAddress',
        'Orbot',
      ]) {
        expect(source, isNot(contains(gone)), reason: gone);
      }
    });

    test('R-6: the Kotlin chart worker re-reads the route immediately before '
        'each request: nothing but the connection\'s own setup sits between '
        'the check and the read that connects, and every request goes '
        'through that one function', () {
      final source = File(
        'android/app/src/main/kotlin/app/bitbag/NativeChartRefreshWorker.kt',
      ).readAsStringSync();
      final code = source.replaceAll(RegExp(r'//.*$', multiLine: true), '');
      final request = RegExp(
        r'if \(applicationContext\.privateRouteOn\(\)\) \{\s*'
        r'Log\.i\(TAG, "[^"]*"\)\s*'
        r'return null\s*\}\s*'
        r'val conn = URL\(urlStr\)\.openConnection\(Proxy\.NO_PROXY\) '
        r'as HttpURLConnection\s*'
        r'conn\.apply \{[^{}]*\}\s*'
        r'val body = conn\.inputStream',
      );
      expect(
        request.allMatches(code),
        hasLength(1),
        reason: 'the re-check is not right before the request',
      );
      // The one request in the file.
      expect(RegExp(r'openConnection\(').allMatches(code), hasLength(1));
      expect(RegExp(r'\.inputStream').allMatches(code), hasLength(1));
      // Inside fetchKrakenPrices, which every fetch (gold's two included)
      // calls.
      final fn = code.indexOf('private fun fetchKrakenPrices(');
      final end = code.indexOf('companion object', fn);
      expect(fn, isNonNegative);
      expect(code.indexOf('openConnection('), inExclusiveRange(fn, end));
      expect(
        code.indexOf('fun ', fn + 'private fun fetchKrakenPrices('.length),
        anyOf(-1, greaterThan(end)),
      );
    });
  });
}
