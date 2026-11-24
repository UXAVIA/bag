/// iOS: the widget refreshes itself in the background through Bag's
/// built-in Tor (Task A4).
///
/// The workmanager plugin runs `backgroundWidgetCallback` for the
/// BGAppRefreshTask `app.bitbag.widget-refresh` in a background engine of
/// its own, and iOS gives that run about 30 s. With Tor the run leases the
/// process's one Tor client (TorHost) with 22 s for it to be ready, fetches
/// the price and the widget's chart through it, writes what the widget shows
/// (price, net worth and the chart set, with the keys and formats the
/// foreground writes) and redraws the widget once. The whole run has a 25 s
/// deadline, and the lease is given back within what is left of it, at most
/// 4 s.
///
/// - Tor not ready within 22 s: no request, nothing marked fresh (Review
///   Focus 3); the only write is `widget_route_ok = false`, so the widget
///   shows "Paused since" (Task A5). A fetch that fails writes nothing for
///   it, and a run that got no price says so the same way.
/// - Direct, a proxy, unreadable proxy settings: the run does nothing at
///   all; the Swift widget fetches for itself there.
/// - A dormant client the app's UI isolate owns is woken by the run's
///   acquire and put back to sleep by its release (real isolates, the real
///   IsolateNameServer).
/// - A keychain that can't be read (a locked device): price and chart are
///   still pushed, and the last net worth stays.
/// - The fee row, gated as on Android (`backgroundFeePlan(prefs)
///   .showInWidget`: Pro and "Show in widget" on): the fast fee over the
///   same routed Dio and under the run's deadline, written as the app
///   writes it. No fee alert is checked and `keyFeeCache` is never written.
/// - No wallet scan, no Sentinel: only what the widget shows.
/// - Requests are recorded on the run's own routed Dio (the hook can only
///   add interceptors), and end to end through the client's SOCKS port.
/// - The task is asked for only while Tor is the route: at launch, on every
///   route change, and a run on another route cancels it. Prefs without
///   `onboarding_complete` (empty, or only a stray pref) or a read past
///   3 s leave the schedule alone.
/// - A run that throws still succeeds, with the lease given back.
/// - The task id in Dart, Info.plist and AppDelegate.swift agree, and the
///   App Group id is one constant.
///
/// The fake native client stands in for the plugin; a fake registry stands
/// in for the IsolateNameServer except in the real-isolate case.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/core/constants/supported_currencies.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/services/embedded_tor_service.dart';
import 'package:bag/services/price_service.dart' show krakenGoldPair;
import 'package:bag/services/tor_host.dart';
import 'package:bag/services/tor_service.dart';
import 'package:bag/services/wallet/wallet_store.dart';
import 'package:bag/services/widget_service.dart';

import '../network/fake_proxies.dart';

const _backgroundChannel = MethodChannel(
  'be.tramckrijte.workmanager/background_channel_work_manager',
);
const _foregroundChannel = MethodChannel(
  'be.tramckrijte.workmanager/foreground_channel_work_manager',
);

/// The keys a successful run writes: the price and the chart set, and the
/// price's freshness (Task A5).
const _pushedKeys = {
  'widget_currency',
  'widget_price',
  'widget_net_worth',
  'widget_change',
  'widget_change_positive',
  'widget_fetched_at',
  'widget_route_ok',
  'widget_chart_prices',
  'widget_chart_change',
  'widget_chart_days',
};

/// When the earlier push's price was fetched (`widget_fetched_at`, epoch
/// seconds, Task A5).
const _earlierFetch = 1763880000;

/// What an earlier push left in the App Group. The Swift timeline wrote
/// `widget_timeframe_days`.
const _cachedWidget = <String, Object?>{
  'widget_currency': 'usd',
  'widget_price': r'$40,000.00',
  'widget_net_worth': r'$20,000.00',
  'widget_change': '+1.0%',
  'widget_change_positive': true,
  'widget_fetched_at': _earlierFetch,
  'widget_route_ok': true,
  'widget_chart_prices': '[39000.0,40000.0]',
  'widget_chart_change': '+2.6%',
  'widget_chart_days': 7,
  'widget_timeframe_days': 7,
};

/// A native client like the plugin's: a start can be held open, a stop
/// cancels a held start and can itself be held.
class _Native implements EmbeddedTorBackend {
  _Native({this.socksPort = 47123, this.ledger});

  int socksPort;

  /// Where a peer isolate's client reports its dormancy.
  final SendPort? ledger;
  int startCalls = 0;
  int stopCalls = 0;
  final List<bool> dormantCalls = [];

  /// The next start waits on this.
  Completer<void>? hold;

  /// A stop waits on this (a native teardown that hangs).
  Completer<void>? stopGate;

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
    final held = _held = hold;
    hold = null;
    if (held != null) await held.future;
    if (_cancelled) return;
    _bootstrapped = true;
  }

  @override
  Future<void> bootstrap() async {}

  @override
  Future<void> setDormant(bool dormant) async {
    dormantCalls.add(dormant);
    ledger?.send(['dormant', dormant]);
  }

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

/// Every request the run makes, recorded on the run's own Dio (the one
/// `buildRoutedJsonDio` built; the hook can only add interceptors to it),
/// with the route the run named and the Tor client as the run saw it at that
/// moment.
/// A path in [holds] waits for its completer first. Answers come from
/// [respond], then [bodies] by path; with [passThrough] anything else goes
/// out over the run's route, otherwise it fails (no network).
class _Requests {
  final seen = <({Uri uri, EmbeddedTorState state, int port})>[];
  final routes = <NetworkRoute>[];
  final Map<String, Object> bodies = {};
  final Map<String, Completer<void>> holds = {};
  Object? Function(Uri uri)? respond;
  bool passThrough = false;

  List<String> get paths => [for (final r in seen) r.uri.path];

  void watch(Interceptors interceptors, NetworkRoute route) {
    routes.add(route);
    interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          seen.add((
            uri: options.uri,
            state: EmbeddedTorService.state,
            port: await TorHost.port(),
          ));
          await holds[options.uri.path]?.future;
          final body = respond?.call(options.uri) ?? bodies[options.uri.path];
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
}

/// A TLS endpoint behind the fake SOCKS proxy: records the first bytes of
/// each connection (a ClientHello names its server in plain text) and hangs
/// up, so the client's TLS fails and nothing is answered.
class _TlsTarget {
  _TlsTarget._(this._server) {
    _server.listen((socket) {
      socket.listen(
        (bytes) {
          hellos.add(latin1.decode(bytes));
          socket.destroy();
        },
        onError: (_) {},
        cancelOnError: true,
      );
    });
  }

  final ServerSocket _server;

  /// The first chunk of every connection, as Latin-1.
  final hellos = <String>[];

  int get port => _server.port;

  /// Whether a TLS ClientHello for [host] arrived.
  bool sawClientHello(String host) =>
      hellos.any((h) => h.startsWith('\x16') && h.contains(host));

  static Future<_TlsTarget> start() async =>
      _TlsTarget._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> close() => _server.close();
}

/// A keychain that refuses every read and write, as iOS does for an item
/// that isn't accessible yet (`errSecInteractionNotAllowed`).
class _LockedKeychain extends MapBase<String, String> {
  Never _locked() => throw PlatformException(
    code: '-25308',
    message: 'errSecInteractionNotAllowed',
  );

  @override
  String? operator [](Object? key) => _locked();

  @override
  void operator []=(String key, String value) => _locked();

  @override
  void clear() => _locked();

  @override
  Iterable<String> get keys => _locked();

  @override
  String? remove(Object? key) => _locked();
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

// ── The app's UI isolate, in a peer isolate ──────────────────────────────

/// The UI isolate of the same process: owns the Tor client (it follows the
/// route), and goes to the background, which puts the client to sleep.
class _UiPeer {
  _UiPeer._(this._isolate, this._commands, this._exit, this.dormant);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _exit;

  /// Every `setDormant` the peer's native client got, in order.
  final List<bool> dormant;

  static Future<_UiPeer> spawn({required int socksPort}) async {
    final hello = ReceivePort();
    final exit = ReceivePort();
    final ledger = ReceivePort();
    final dormant = <bool>[];
    ledger.listen((m) {
      final event = m as List;
      if (event[0] == 'dormant') dormant.add(event[1] as bool);
    });
    final isolate = await Isolate.spawn(_uiPeerMain, [
      hello.sendPort,
      ledger.sendPort,
      socksPort,
    ], onExit: exit.sendPort);
    final commands = await hello.first as SendPort;
    return _UiPeer._(isolate, commands, exit, dormant);
  }

  Future<Map> call(String cmd) async {
    final reply = ReceivePort();
    _commands.send({'cmd': cmd, 'reply': reply.sendPort});
    return await reply.first.timeout(const Duration(seconds: 15)) as Map;
  }

  Future<void> kill() async {
    _isolate.kill(priority: Isolate.immediate);
    await _exit.first.timeout(const Duration(seconds: 5));
  }
}

void _uiPeerMain(List<Object?> args) {
  final hello = args[0]! as SendPort;
  final native = _Native(
    ledger: args[1]! as SendPort,
    socksPort: args[2]! as int,
  );
  EmbeddedTorService.debugBackend = native;
  // The sleep after `paused` is deferred (I1); short here, in real time.
  TorHost.debugSleepDelay = const Duration(milliseconds: 50);

  final commands = ReceivePort();
  hello.send(commands.sendPort);
  commands.listen((message) async {
    final m = message as Map;
    switch (m['cmd']) {
      case 'tor':
        TorService.followRoute(const TorRoute());
        while (EmbeddedTorService.state != EmbeddedTorState.ready) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      case 'pause':
        await EmbeddedTorService.onPause();
    }
    (m['reply'] as SendPort).send({
      'state': EmbeddedTorService.state.name,
      'startCalls': native.startCalls,
      'stopCalls': native.stopCalls,
    });
  });
}

void main() {
  // The binding is needed for the platform channels, but it also installs
  // HttpOverrides that answer every request with a canned 400 without
  // touching a socket. The proxy in the route cases is a real socket.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _Native native;
  late _Registry registry;
  late _Requests requests;

  // The App Group (HomeWidget), and every channel call in order:
  // `group:<id>`, `get:<key>`, `save:<key>` and `reload`.
  final widgetStore = <String, Object?>{};
  final widgetLog = <String>[];
  final foregroundCalls = <MethodCall>[];

  /// While set, every App Group read waits on it (a local call that hangs).
  Completer<void>? holdWidgetReads;

  /// Every App Group write throws (no widget host).
  var failWidgetWrites = false;

  /// The workmanager calls that cancel the iOS task, by unique name.
  List<Object?> cancels() => [
    for (final c in foregroundCalls)
      if (c.method == 'cancelTaskByUniqueName')
        (c.arguments as Map)['uniqueName'],
  ];

  /// The workmanager calls that ask for the iOS task, by unique name.
  List<Object?> schedules() => [
    for (final c in foregroundCalls)
      if (c.method == 'registerPeriodicTask')
        (c.arguments as Map)['uniqueName'],
  ];

  List<String> saves() => [
    for (final e in widgetLog)
      if (e.startsWith('save:')) e.substring(5),
  ];
  int redraws() => widgetLog.where((e) => e == 'reload').length;

  setUpAll(() {
    messenger.setMockMethodCallHandler(const MethodChannel('home_widget'), (
      call,
    ) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      switch (call.method) {
        case 'setAppGroupId':
          widgetLog.add('group:${args['groupId']}');
          return true;
        case 'saveWidgetData':
          if (failWidgetWrites) {
            throw PlatformException(code: 'no-widget-host');
          }
          final id = args['id'] as String;
          widgetLog.add('save:$id');
          final data = args['data'];
          if (data == null) {
            widgetStore.remove(id);
          } else {
            widgetStore[id] = data;
          }
          return true;
        case 'getWidgetData':
          widgetLog.add('get:${args['id']}');
          await holdWidgetReads?.future;
          return widgetStore[args['id']];
        case 'updateWidget':
          widgetLog.add('reload');
          return true;
      }
      return null;
    });
    // The plugin's "ready" call when the task is registered.
    messenger.setMockMethodCallHandler(_backgroundChannel, (call) async {
      return null;
    });
    messenger.setMockMethodCallHandler(_foregroundChannel, (call) async {
      foregroundCalls.add(call);
      return true;
    });
  });

  setUp(() {
    native = _Native();
    registry = _Registry();
    requests = _Requests();
    EmbeddedTorService.debugBackend = native;
    TorHost.debugRegistry = registry;
    TorService.debugIsIOS = true;
    WidgetService.debugInterceptBackgroundDio = requests.watch;
    widgetStore
      ..clear()
      ..addAll(_cachedWidget);
    widgetLog.clear();
    foregroundCalls.clear();
    holdWidgetReads = null;
    failWidgetWrites = false;
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
    WidgetService.debugIosRoutePrefs = null;
  });

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
    'wallet_zpub_w1':
        'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs',
  };

  /// Seeds prefs and secure storage for one run: onboarded, Tor on unless
  /// [prefs] says otherwise, 0.5 BTC held.
  void seed([
    Map<String, Object> prefs = const {AppConstants.keyUseTor: true},
    Map<String, String> secure = const {},
  ]) {
    SharedPreferences.setMockInitialValues({
      // Prefs the route read trusts: only a launch that onboarded writes
      // this key.
      AppConstants.keyOnboardingComplete: true,
      AppConstants.keySelectedCurrencies: ['usd'],
      ...prefs,
    });
    FlutterSecureStorage.setMockInitialValues({
      AppConstants.keyBtcAmount: '0.5',
      ...secure,
    });
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

  /// Runs the task as the workmanager plugin does on iOS: the callback
  /// registers it, then the platform calls it on the background channel
  /// with the BGTaskScheduler identifier. Returns its result.
  Future<Object?> runTask([String taskName = iosWidgetRefreshTaskId]) async {
    backgroundWidgetCallback();
    const codec = StandardMethodCodec();
    final reply = await messenger.handlePlatformMessage(
      _backgroundChannel.name,
      codec.encodeMethodCall(
        MethodCall('onResultSend', {
          'be.tramckrijte.workmanager.DART_TASK': taskName,
        }),
      ),
      null,
    );
    return codec.decodeEnvelope(reply!);
  }

  /// A run that got no price: the widget's prices, chart and their time
  /// stay, and the only write says the route is paused, then one redraw
  /// shows it (Task A5).
  void expectOnlyPaused() {
    expect(saves(), ['widget_route_ok'], reason: 'wrote a price key');
    expect(widgetStore['widget_route_ok'], isFalse);
    expect(redraws(), 1);
    expect(widgetLog.last, 'reload');
    for (final e in _cachedWidget.entries) {
      if (e.key == 'widget_route_ok') continue;
      expect(widgetStore, containsPair(e.key, e.value));
    }
  }

  test('the budgets and the task id: 25 s for the run, 22 s for Tor, at most '
      '4 s for giving the lease back', () {
    expect(iosWidgetRefreshTaskId, 'app.bitbag.widget-refresh');
    expect(iosBackgroundTaskBudget, const Duration(seconds: 25));
    expect(iosBackgroundTorBudget, const Duration(seconds: 22));
    expect(iosBackgroundReleaseBudget, const Duration(seconds: 4));
  });

  test('Tor ready within budget: the price, net worth and chart set are '
      'pushed through the lease with today\'s keys and formats, the widget '
      'is redrawn once, last, and the lease is given back', () async {
    seed({
      AppConstants.keyUseTor: true,
      // Pro, fee alerts and a stale wallet, with the fee row off: none of it
      // is background work on iOS (R-A4c; the fee row is "the fee row" below).
      AppConstants.keyProUnlocked: true,
      AppConstants.keyFeeAlerts: '[{"id":"a","targetRate":5,"above":true}]',
    }, staleWallet);
    answerPriceAndChart();
    final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    expect(await runTask(), isTrue);

    final after = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(requests.routes, everyElement(isA<TorRoute>()));
    expect(
      requests.paths,
      unorderedEquals(['/api/price', '/api/chart']),
      reason: 'no fee, explorer or other request',
    );
    for (final r in requests.seen) {
      expect(r.state, EmbeddedTorState.ready, reason: '${r.uri}');
      expect(r.port, native.socksPort, reason: '${r.uri}');
    }
    final chart = requests.seen.singleWhere((r) => r.uri.path == '/api/chart');
    expect(chart.uri.queryParameters, {'currency': 'usd', 'days': '7'});

    // The App Group is set before anything is read or written: the
    // background engine may be the first in the process to use it.
    expect(widgetLog.first, 'group:group.app.bitbag.shared');

    final usd = currencyFormatter('usd');
    expect(widgetStore['widget_currency'], 'usd');
    expect(widgetStore['widget_price'], usd.format(50000));
    expect(widgetStore['widget_net_worth'], usd.format(25000));
    expect(widgetStore['widget_change'], '+1.5%');
    expect(widgetStore['widget_change_positive'], isTrue);
    expect(widgetStore['widget_fetched_at'], inInclusiveRange(before, after));
    expect(widgetStore['widget_route_ok'], isTrue);
    expect(widgetStore['widget_chart_prices'], '[49000.0,50000.0]');
    expect(widgetStore['widget_chart_change'], '+2.0%');
    expect(widgetStore['widget_chart_days'], 7);

    // The chart set goes out as one: days removed first, set last.
    final chartSaves = saves()
        .where((k) => k.startsWith('widget_chart_'))
        .toList();
    expect(chartSaves, [
      'widget_chart_days',
      'widget_chart_prices',
      'widget_chart_change',
      'widget_chart_days',
    ]);
    expect(saves().toSet(), _pushedKeys, reason: 'only what the widget shows');
    expect(redraws(), 1);
    expect(widgetLog.last, 'reload');

    // Nothing else touched: the fee row, the wallet.
    expect(widgetStore.containsKey('widget_fast_fee'), isFalse);
    final wallet = (await loadWalletsFromStorage()).single;
    expect(wallet.lastSats, 1234);
    expect(wallet.lastScanAt, DateTime(2026));

    // Given back: this isolate ran the client and held the only lease.
    expect(native.startCalls, 1);
    expect(native.stopCalls, 1);
    expect(EmbeddedTorService.state, EmbeddedTorState.off);
    expect(await TorHost.port(), -1);
    expect(registry.names, isEmpty);
  });

  test('Tor not ready within 22 s: no request at all, nothing marked fresh, '
      'the widget shows its route paused, and the lease is given back '
      '(Review Focus 3)', () async {
    final target = await _TlsTarget.start();
    addTearDown(target.close);
    final proxy = await FakeSocks5Proxy.start(targetPort: target.port);
    addTearDown(proxy.close);
    native.socksPort = proxy.port;
    fakeAsync((async) {
      seed();
      answerPriceAndChart();
      requests.passThrough = true;
      native.hold = Completer<void>();
      Object? result;
      runTask().then((r) => result = r);

      async.elapse(const Duration(seconds: 21, milliseconds: 900));
      expect(result, isNull, reason: 'gave up on Tor before 22 s');
      expect(native.startCalls, 1);
      expect(requests.seen, isEmpty);

      async.elapse(const Duration(milliseconds: 200));
      expect(result, isTrue, reason: 'success: a retry would only repeat it');
      async.elapse(const Duration(minutes: 1));
      expect(requests.seen, isEmpty);
      expectOnlyPaused();
      // A background engine may be the first in the process to use the
      // App Group: it is set before the paused state is written.
      expect(
        widgetLog.indexOf('group:group.app.bitbag.shared'),
        allOf(isNonNegative, lessThan(widgetLog.indexOf('save:widget_route_ok'))),
      );
      expect(native.stopCalls, greaterThanOrEqualTo(1));
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(registry.names, isEmpty);
    });
    // In real time: a connection the run had opened would have landed.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(proxy.connections, 0, reason: 'reached the SOCKS port');
    expect(target.hellos, isEmpty);
  });

  test('Tor ready, end to end: the run\'s own Dio goes through the client\'s '
      'SOCKS port naming each host, and the target behind it gets the TLS '
      'request; a TLS that fails writes nothing', () async {
    final target = await _TlsTarget.start();
    addTearDown(target.close);
    final proxy = await FakeSocks5Proxy.start(targetPort: target.port);
    addTearDown(proxy.close);
    native.socksPort = proxy.port;
    seed();
    // Nothing canned: every request goes out over the run's route.
    requests.passThrough = true;

    expect(await runTask(), isTrue);

    expect(requests.paths, isNotEmpty);
    expect(proxy.connectHosts, contains('bitbag.app'));
    expect(proxy.connectHosts.toSet(), {
      'bitbag.app',
      'api.coingecko.com',
      'api.kraken.com',
    });
    expect(proxy.connections, proxy.connectHosts.length);
    expect(target.sawClientHello('bitbag.app'), isTrue);
    expectOnlyPaused();
    expect(native.stopCalls, 1);
    expect(registry.names, isEmpty);
  });

  test('a throw inside the run (the widget host refuses writes): logged by '
      'type, the run still succeeds, and the lease is given back', () async {
    seed();
    answerPriceAndChart();
    failWidgetWrites = true;

    expect(await runTask(), isTrue);

    expect(requests.paths, unorderedEquals(['/api/price', '/api/chart']));
    expect(native.stopCalls, 1);
    expect(EmbeddedTorService.state, EmbeddedTorState.off);
    expect(registry.names, isEmpty);
  });

  group('the fee row (gated as on Android)', () {
    // The default explorer (blockstream.info) is a plain Esplora, so the
    // fee comes from its /fee-estimates (fetchFeeEstimate).
    const feePath = '/api/fee-estimates';
    const firingAlert = '[{"id":"a","targetRate":10,"above":true}]';

    void answerFee() {
      requests.bodies[feePath] = <String, dynamic>{'1': 21, '3': 12, '6': 8};
    }

    test('Pro with the row on: the fast fee comes over the same routed Dio '
        'and lease as the price, is written as the app writes it, and no '
        'fee alert fires and nothing is cached in prefs', () async {
      seed({
        AppConstants.keyUseTor: true,
        AppConstants.keyProUnlocked: true,
        AppConstants.keyWidgetShowFee: true,
        AppConstants.keyFeeAlerts: firingAlert,
      });
      answerPriceAndChart();
      answerFee();

      expect(await runTask(), isTrue);

      expect(
        requests.paths,
        unorderedEquals(['/api/price', '/api/chart', feePath]),
      );
      expect(requests.routes, [isA<TorRoute>()], reason: 'one routed Dio');
      final fee = requests.seen.singleWhere((r) => r.uri.path == feePath);
      expect(fee.uri.host, 'blockstream.info');
      expect(fee.state, EmbeddedTorState.ready);
      expect(fee.port, native.socksPort);

      expect(widgetStore['widget_show_fee'], isTrue);
      expect(widgetStore['widget_fast_fee'], '21 sat/vB');
      expect(redraws(), 1);

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getString(AppConstants.keyFeeCache), isNull);
      expect(prefs.getString(AppConstants.keyFeeAlerts), firingAlert);
      expect(native.stopCalls, 1);
    });

    test('TB-4: a free user (a lapsed Pro) with the row on: no fee request, '
        'and the row is cleared as clearFee clears it, then drawn', () async {
      seed({
        AppConstants.keyUseTor: true,
        AppConstants.keyFeeAlerts: firingAlert,
        AppConstants.keyWidgetShowFee: true,
      });
      widgetStore['widget_show_fee'] = true;
      widgetStore['widget_fast_fee'] = '30 sat/vB';
      answerPriceAndChart();
      answerFee();

      expect(await runTask(), isTrue);

      expect(requests.paths, unorderedEquals(['/api/price', '/api/chart']));
      expect(widgetStore['widget_show_fee'], isFalse);
      expect(widgetStore.containsKey('widget_fast_fee'), isFalse);
      expect(saves(), containsAll(['widget_show_fee', 'widget_fast_fee']));
      expect(redraws(), 1);
    });

    test('TB-4: a free user whose price and chart both fail: the row is '
        'still cleared, and drawn', () async {
      seed({
        AppConstants.keyUseTor: true,
        AppConstants.keyWidgetShowFee: true,
      });
      widgetStore['widget_show_fee'] = true;
      widgetStore['widget_fast_fee'] = '30 sat/vB';

      expect(await runTask(), isTrue);

      expect(widgetStore['widget_show_fee'], isFalse);
      expect(widgetStore.containsKey('widget_fast_fee'), isFalse);
      expect(redraws(), 1);
    });

    for (final (name, prefs) in [
      (
        'Pro with the row off',
        {AppConstants.keyProUnlocked: true},
      ),
    ]) {
      test('$name: no fee request, and the row is left as it is', () async {
        seed({
          AppConstants.keyUseTor: true,
          AppConstants.keyFeeAlerts: firingAlert,
          ...prefs,
        });
        widgetStore['widget_show_fee'] = true;
        widgetStore['widget_fast_fee'] = '30 sat/vB';
        answerPriceAndChart();
        answerFee();

        expect(await runTask(), isTrue);

        expect(requests.paths, unorderedEquals(['/api/price', '/api/chart']));
        expect(saves(), isNot(contains('widget_show_fee')));
        expect(saves(), isNot(contains('widget_fast_fee')));
        expect(widgetStore['widget_fast_fee'], '30 sat/vB');
      });
    }

    test('a fee request that fails writes nothing for the row', () async {
      seed({
        AppConstants.keyUseTor: true,
        AppConstants.keyProUnlocked: true,
        AppConstants.keyWidgetShowFee: true,
      });
      widgetStore['widget_show_fee'] = true;
      widgetStore['widget_fast_fee'] = '30 sat/vB';
      answerPriceAndChart();

      expect(await runTask(), isTrue);

      expect(requests.paths, contains(feePath));
      expect(saves(), isNot(contains('widget_fast_fee')));
      expect(widgetStore['widget_fast_fee'], '30 sat/vB');
      expect(widgetStore['widget_price'], currencyFormatter('usd').format(50000));
    });

    test('a fee request that hangs carries the run\'s token: cancelled at the '
        '25 s deadline, it writes nothing even when it answers later', () {
      fakeAsync((async) {
        seed({
          AppConstants.keyUseTor: true,
          AppConstants.keyProUnlocked: true,
          AppConstants.keyWidgetShowFee: true,
        });
        answerPriceAndChart();
        answerFee();
        final fee = requests.holds[feePath] = Completer<void>();
        // Held for good, as in the deadline group: a chart write must not
        // start inside fakeAsync (the static chart chain would wait on it).
        requests.holds['/api/chart'] = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 25, milliseconds: 100));
        expect(result, isTrue);
        expect(requests.paths, contains(feePath));
        expect(widgetStore['widget_price'], currencyFormatter('usd').format(50000));

        fee.complete();
        async.elapse(const Duration(minutes: 1));
        expect(saves(), isNot(contains('widget_fast_fee')));
        expect(saves(), isNot(contains('widget_show_fee')));
        expect(widgetStore.containsKey('widget_fast_fee'), isFalse);
      });
    });

    test('source: the iOS run checks no fee alert and caches no estimate', () {
      final src = File('lib/services/widget_service.dart').readAsStringSync();
      final start = src.indexOf('Future<bool> _iosWidgetRefresh(');
      final end = src.indexOf('/// The widget currency\'s spot price', start);
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final ios = src.substring(start, end);
      expect(ios, contains('backgroundFeePlan(prefs).showInWidget'));
      for (final banned in ['checkFeeAlerts', 'keyFeeAlerts', 'keyFeeCache']) {
        expect(ios, isNot(contains(banned)), reason: banned);
      }
    });
  });

  group('sources', () {
    test('chart only (the price fails everywhere): the chart set is pushed, '
        'and nothing is stamped fresh', () async {
      seed();
      requests.bodies['/api/chart'] = <String, dynamic>{
        'd': [
          [0, 49000.0],
          [1, 50000.0],
        ],
      };

      expect(await runTask(), isTrue);

      expect(widgetStore['widget_chart_prices'], '[49000.0,50000.0]');
      expect(widgetStore['widget_chart_days'], 7);
      expect(saves().toSet(), {
        'widget_chart_days',
        'widget_chart_prices',
        'widget_chart_change',
        'widget_route_ok',
      });
      // The price is the headline: no price, so the route reads paused and
      // the price keeps its time (Task A5).
      expect(widgetStore['widget_route_ok'], isFalse);
      expect(widgetStore['widget_fetched_at'], _earlierFetch);
      expect(widgetStore['widget_price'], r'$40,000.00');
      expect(redraws(), 1);
    });

    test('bitbag.app has no price: CoinGecko answers, with its 24 h '
        'change', () async {
      seed();
      requests.bodies['/api/chart'] = <String, dynamic>{
        'd': [
          [0, 49000.0],
          [1, 50000.0],
        ],
      };
      requests.bodies['/api/v3/simple/price'] = <String, dynamic>{
        'bitcoin': {'usd': 51000.0, 'usd_24h_change': -0.5},
      };

      expect(await runTask(), isTrue);

      final spot = requests.seen.where((r) => r.uri.path.endsWith('price'));
      expect(spot.map((r) => r.uri.host), ['bitbag.app', 'api.coingecko.com']);
      expect(spot.last.uri.queryParameters, {
        'ids': 'bitcoin',
        'vs_currencies': 'usd',
        'include_24hr_change': 'true',
      });
      final usd = currencyFormatter('usd');
      expect(widgetStore['widget_price'], usd.format(51000));
      expect(widgetStore['widget_net_worth'], usd.format(25500));
      expect(widgetStore['widget_change'], '-0.5%');
      expect(widgetStore['widget_change_positive'], isFalse);
    });

    /// Kraken's OHLC answer for [pair] with these closes.
    Map<String, dynamic> ohlc(String pair, List<double> closes) => {
      'error': <Object>[],
      'result': {
        pair: [
          for (var i = 0; i < closes.length; i++)
            [i, '0', '0', '0', '${closes[i]}', '0', '0', 1],
        ],
        'last': closes.length,
      },
    };

    test('a timeframe bitbag.app doesn\'t serve (1Y): Kraken\'s daily '
        'closes', () async {
      seed();
      widgetStore['widget_timeframe_days'] = 365;
      answerPriceAndChart();
      requests.respond = (uri) => uri.path == '/0/public/OHLC'
          ? ohlc(uri.queryParameters['pair']!, [49000, 50000])
          : null;

      expect(await runTask(), isTrue);

      expect(requests.paths, isNot(contains('/api/chart')));
      final kraken = requests.seen.singleWhere(
        (r) => r.uri.path == '/0/public/OHLC',
      );
      expect(kraken.uri.queryParameters['pair'], 'XXBTZUSD');
      expect(kraken.uri.queryParameters['interval'], '1440');
      expect(widgetStore['widget_chart_prices'], '[49000.0,50000.0]');
      expect(widgetStore['widget_chart_change'], '+2.0%');
      expect(widgetStore['widget_chart_days'], 365);
    });

    test('gold on a Kraken timeframe: BTC/USD divided by PAXG/USD, candle by '
        'candle', () async {
      seed({
        AppConstants.keyUseTor: true,
        AppConstants.keySelectedCurrencies: ['xau'],
      });
      widgetStore['widget_timeframe_days'] = 365;
      requests.bodies['/api/price'] = <String, dynamic>{
        'prices': {'xau': 17.75},
        'changes24h': {'xau': 0.3},
      };
      requests.respond = (uri) => uri.path != '/0/public/OHLC'
          ? null
          : uri.queryParameters['pair'] == krakenGoldPair
          ? ohlc(krakenGoldPair, [2500, 3000])
          : ohlc(uri.queryParameters['pair']!, [50000, 66000]);

      expect(await runTask(), isTrue);

      final pairs = [
        for (final r in requests.seen)
          if (r.uri.path == '/0/public/OHLC') r.uri.queryParameters['pair'],
      ];
      expect(pairs, ['XXBTZUSD', krakenGoldPair]);
      expect(widgetStore['widget_currency'], 'xau');
      expect(
        widgetStore['widget_price'],
        currencyFormatter('xau').format(17.75),
      );
      expect(widgetStore['widget_chart_prices'], '[20.0,22.0]');
      expect(widgetStore['widget_chart_change'], '+10.0%');
    });
  });

  test('every fetch fails: nothing is marked fresh, the last push stays, and '
      'the widget shows its route paused', () async {
    seed();
    // No canned bodies: every request fails.

    expect(await runTask(), isTrue);

    expect(
      requests.paths.toSet(),
      containsAll(['/api/price', '/api/chart']),
      reason: 'the fetch was tried',
    );
    expectOnlyPaused();
    expect(native.stopCalls, 1);
    expect(registry.names, isEmpty);
  });

  group('not Tor: the run does nothing (the Swift widget fetches itself)', () {
    late FakeSocks5Proxy proxy;

    setUp(() async {
      proxy = await FakeSocks5Proxy.start(targetPort: 9);
    });

    tearDown(() => proxy.close());

    final cases =
        <(String, Map<String, Object>, Map<String, String> Function())>[
          ('Direct', const {}, () => const {}),
          (
            'a proxy',
            const {AppConstants.keyUseProxy: true},
            () => {
              AppConstants.keyNetworkProxy: jsonEncode(
                ProxyConfig(
                  type: ProxyType.socks5,
                  host: '127.0.0.1',
                  port: proxy.port,
                ).toJson(),
              ),
            },
          ),
          (
            'unreadable proxy settings',
            const {AppConstants.keyUseProxy: true},
            () => const {AppConstants.keyNetworkProxy: 'not json'},
          ),
        ];
    for (final (name, prefs, secure) in cases) {
      test('$name: no Tor, no request, no probe, nothing written', () async {
        seed(prefs, secure());
        answerPriceAndChart();
        final torStates = <EmbeddedTorState>[];
        final sub = EmbeddedTorService.changes.listen(torStates.add);
        addTearDown(sub.cancel);

        expect(await runTask(), isTrue);

        await pumpEventQueue();
        expect(torStates, isEmpty, reason: 'asked TorHost for a lease');
        expect(native.startCalls, 0);
        expect(EmbeddedTorService.state, EmbeddedTorState.off);
        expect(registry.names, isEmpty);
        expect(requests.seen, isEmpty);
        expect(requests.routes, isEmpty, reason: 'built a client');
        expect(proxy.connections, 0, reason: 'probed or used the proxy');
        expect(widgetLog, isEmpty);
        // The plugin asked for the next run before this one started: that
        // request goes, so iOS stops launching Bag for nothing.
        expect(cancels(), [iosWidgetRefreshTaskId]);
        expect(schedules(), isEmpty);
      });
    }

    test('prefs that read empty (before the first unlock after a reboot, '
        'or a fresh install): nothing, and the schedule stays', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});

      expect(await runTask(), isTrue);

      expect(native.startCalls, 0);
      expect(requests.seen, isEmpty);
      expect(widgetLog, isEmpty);
      expect(foregroundCalls, isEmpty, reason: 'cancelled on a doubtful read');
    });

    test('prefs holding only what main() writes before the first unlock '
        '(the migration pref): doubtful, so nothing, and the schedule stays '
        '(M-a)', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyIosTorMigrated: AppConstants.torMigratedNone,
      });
      FlutterSecureStorage.setMockInitialValues({});

      expect(await runTask(), isTrue);

      expect(native.startCalls, 0);
      expect(requests.seen, isEmpty);
      expect(widgetLog, isEmpty);
      expect(foregroundCalls, isEmpty, reason: 'read a stray pref as Direct');
    });

    test('a cancel that hangs (BGTaskScheduler never answers): the run is '
        'still back at 25 s', () {
      final hung = Completer<Object?>();
      messenger.setMockMethodCallHandler(_foregroundChannel, (call) {
        foregroundCalls.add(call);
        return hung.future;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(_foregroundChannel, (
          call,
        ) async {
          foregroundCalls.add(call);
          return true;
        }),
      );
      fakeAsync((async) {
        seed(const {});
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 24, milliseconds: 900));
        expect(cancels(), [iosWidgetRefreshTaskId]);
        expect(result, isNull);
        async.elapse(const Duration(milliseconds: 200));
        expect(result, isTrue);
        expect(native.startCalls, 0);
      });
    });

    test('the route check is capped at 3 s: a prefs read that hangs counts '
        'as doubtful, and the run starts no Tor', () {
      fakeAsync((async) {
        seed();
        answerPriceAndChart();
        WidgetService.debugIosRoutePrefs = () =>
            Completer<SharedPreferences>().future;
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 2, milliseconds: 900));
        expect(result, isNull);
        async.elapse(const Duration(milliseconds: 200));
        expect(result, isTrue);
        expect(native.startCalls, 0);
        expect(registry.names, isEmpty);
        expect(requests.seen, isEmpty);
        expect(widgetLog, isEmpty);
        expect(foregroundCalls, isEmpty);
      });
    });

    test('another task id (the legacy background fetch): nothing, Tor on '
        'or not', () async {
      seed();
      answerPriceAndChart();

      expect(await runTask('iOSPerformFetch'), isTrue);

      expect(native.startCalls, 0);
      expect(requests.seen, isEmpty);
      expect(widgetLog, isEmpty);
      expect(foregroundCalls, isEmpty);
    });
  });

  group('the 25 s deadline', () {
    test('a fetch that hangs: the run returns at 25 s with the lease given '
        'back, and starts no request after it', () {
      fakeAsync((async) {
        seed();
        answerPriceAndChart();
        final price = requests.holds['/api/price'] = Completer<void>();
        final chart = requests.holds['/api/chart'] = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 24, milliseconds: 900));
        expect(result, isNull);
        expect(requests.paths, unorderedEquals(['/api/price', '/api/chart']));
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);

        async.elapse(const Duration(milliseconds: 200));
        expect(result, isTrue, reason: 'past the deadline, success');
        expect(native.stopCalls, 1);
        expect(EmbeddedTorService.state, EmbeddedTorState.off);
        expect(registry.names, isEmpty);

        // The held requests answer after all: no fallback (CoinGecko,
        // Kraken) starts past the deadline, and nothing is written.
        price.complete();
        chart.complete();
        async.elapse(const Duration(minutes: 1));
        expect(requests.paths, unorderedEquals(['/api/price', '/api/chart']));
        expectOnlyPaused();
      });
    });

    test('the price answered, the chart hangs: the price is pushed, the '
        'chart set keeps the last push, no fallback starts after 25 s', () {
      fakeAsync((async) {
        seed();
        answerPriceAndChart();
        requests.holds['/api/chart'] = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 25, milliseconds: 100));
        expect(result, isTrue);
        async.elapse(const Duration(minutes: 1));
        expect(
          widgetStore['widget_price'],
          currencyFormatter('usd').format(50000),
        );
        expect(saves().where((k) => k.startsWith('widget_chart_')), isEmpty);
        expect(widgetStore['widget_chart_prices'], '[39000.0,40000.0]');
        expect(widgetStore['widget_chart_days'], 7);
        expect(
          requests.paths,
          unorderedEquals(['/api/price', '/api/chart']),
          reason: 'a Kraken fallback started past the deadline',
        );
        expect(native.stopCalls, 1);
      });
    });

    test('giving the lease back is bounded at 4 s, after the native stop '
        'has gone out', () {
      fakeAsync((async) {
        seed();
        answerPriceAndChart();
        // No chart write here: the chart set's write chain is a static
        // future an earlier test completed in its own zone, and a future
        // from another zone runs its callbacks outside fakeAsync's reach.
        requests.bodies.remove('/api/chart');
        native.stopGate = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(milliseconds: 100));
        expect(
          widgetStore['widget_price'],
          currencyFormatter('usd').format(50000),
        );
        expect(native.stopCalls, 1, reason: 'the native stop goes out first');
        expect(result, isNull);

        async.elapse(const Duration(seconds: 3, milliseconds: 800));
        expect(result, isNull, reason: 'gave up on the release before 4 s');
        async.elapse(const Duration(milliseconds: 200));
        expect(result, isTrue);
        native.releaseStop();
        async.flushMicrotasks();
      });
    });

    test('a local read that hangs (the App Group): still back at 25 s with '
        'the lease given back, and no request after it', () {
      fakeAsync((async) {
        seed();
        answerPriceAndChart();
        holdWidgetReads = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 24, milliseconds: 900));
        expect(result, isNull);
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);
        async.elapse(const Duration(milliseconds: 200));
        expect(result, isTrue, reason: 'waited on a call it can\'t cancel');
        expect(native.stopCalls, 1);
        expect(registry.names, isEmpty);

        holdWidgetReads!.complete();
        async.elapse(const Duration(minutes: 1));
        expect(requests.seen, isEmpty, reason: 'fetched past the deadline');
        // The abandoned body got no price: it can only say so (Task A5).
        expect(saves(), ['widget_route_ok']);
        expect(widgetStore['widget_route_ok'], isFalse);
      });
    });

    test('a fetch that hangs and a release that hangs: still back by 25 s, '
        'not 29 s', () {
      fakeAsync((async) {
        seed();
        answerPriceAndChart();
        requests.holds['/api/price'] = Completer<void>();
        requests.holds['/api/chart'] = Completer<void>();
        native.stopGate = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 24, milliseconds: 900));
        expect(result, isNull);
        async.elapse(const Duration(milliseconds: 200));
        expect(result, isTrue, reason: 'the release got what was left: none');
        expect(native.stopCalls, 1);
        native.releaseStop();
        async.flushMicrotasks();
      });
    });
  });

  test('a keychain that can\'t be read (a locked device): price and chart '
      'are still pushed, and the last net worth stays', () async {
    seed();
    FlutterSecureStorage.setMockInitialValues(_LockedKeychain());
    answerPriceAndChart();

    expect(await runTask(), isTrue);

    final usd = currencyFormatter('usd');
    expect(widgetStore['widget_price'], usd.format(50000));
    expect(widgetStore['widget_chart_prices'], '[49000.0,50000.0]');
    expect(widgetStore['widget_chart_days'], 7);
    expect(saves(), isNot(contains('widget_net_worth')));
    expect(widgetStore['widget_net_worth'], r'$20,000.00');
    expect(widgetStore['widget_fetched_at'], isNot(_earlierFetch));
    expect(widgetStore['widget_route_ok'], isTrue);
    expect(redraws(), 1);
  });

  test('the app\'s UI isolate owns a dormant client: the run\'s acquire '
      'wakes it, the requests use its port, and the last release puts it '
      'back to sleep', () async {
    // The real IsolateNameServer, as between the UI and the background
    // engine of one process.
    TorHost.debugRegistry = null;
    final ui = await _UiPeer.spawn(socksPort: 47999);
    addTearDown(() async {
      await ui.kill();
      IsolateNameServer.removePortNameMapping(TorHost.portName);
      IsolateNameServer.removePortNameMapping(TorHost.isolatePortName);
    });
    expect((await ui.call('tor'))['state'], 'ready');
    await ui.call('pause');
    await _until(() => ui.dormant.length == 1, reason: 'the UI client slept');
    expect(ui.dormant, [true]);

    seed();
    answerPriceAndChart();

    expect(await runTask(), isTrue);

    expect(native.startCalls, 0, reason: 'started a second client');
    expect(requests.paths, unorderedEquals(['/api/price', '/api/chart']));
    for (final r in requests.seen) {
      expect(r.state, EmbeddedTorState.ready, reason: '${r.uri}');
      expect(r.port, 47999, reason: '${r.uri}: not the UI\'s client');
    }
    expect(widgetStore['widget_price'], currencyFormatter('usd').format(50000));

    await _until(() => ui.dormant.length == 3, reason: 'never slept again');
    expect(ui.dormant, [true, false, true]);
    final status = await ui.call('status');
    expect(status['state'], 'ready', reason: 'the UI keeps its client');
    expect(status['startCalls'], 1);
    expect(status['stopCalls'], 0);
    expect(EmbeddedTorService.state, EmbeddedTorState.off);
  });

  group('scheduling on iOS: only while Tor is the route', () {
    test('a launch on Tor: initialise registers the callback and '
        'scheduleRefresh asks for the BGAppRefreshTask, not before 15 min '
        'from now', () async {
      seed();
      await WidgetService.initialise();
      await WidgetService.scheduleRefresh();

      expect(widgetLog, contains('group:group.app.bitbag.shared'));
      final init = foregroundCalls.singleWhere((c) => c.method == 'initialize');
      expect((init.arguments as Map)['callbackHandle'], isA<int>());
      final periodic = foregroundCalls.singleWhere(
        (c) => c.method == 'registerPeriodicTask',
      );
      final args = periodic.arguments as Map;
      expect(args['uniqueName'], iosWidgetRefreshTaskId);
      expect(args['taskName'], iosWidgetRefreshTaskId);
      // A launch, background ones included, never asks for a run "now":
      // the app has just updated the widget.
      expect(args['initialDelaySeconds'], 15 * 60);
      expect(cancels(), isEmpty);
    });

    for (final (name, prefs) in <(String, Map<String, Object>)>[
      ('Direct', const {}),
      ('a proxy', const {AppConstants.keyUseProxy: true}),
    ]) {
      test('a launch on $name asks for nothing, and drops a request left '
          'from before', () async {
        seed(prefs);

        await WidgetService.scheduleRefresh();

        expect(schedules(), isEmpty);
        expect(cancels(), [iosWidgetRefreshTaskId]);
      });
    }

    test('a launch whose prefs read empty leaves the schedule alone', () async {
      SharedPreferences.setMockInitialValues({});

      await WidgetService.scheduleRefresh();

      expect(foregroundCalls, isEmpty);
    });

    test('a launch whose prefs hold only the migration pref (main() before '
        'the first unlock) leaves the schedule alone (M-a)', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyIosTorMigrated: AppConstants.torMigratedNone,
      });

      await WidgetService.scheduleRefresh();

      expect(foregroundCalls, isEmpty);
    });

    for (final (name, prefs) in <(String, Map<String, Object>)>[
      ('Tor', const {AppConstants.keyUseTor: true}),
      ('Direct', const {}),
    ]) {
      test('a launch on $name whose workmanager calls fail still completes: '
          'main() doesn\'t await it, so nothing may escape', () async {
        seed(prefs);
        messenger.setMockMethodCallHandler(_foregroundChannel, (call) async {
          foregroundCalls.add(call);
          throw PlatformException(code: 'bg-task-scheduler');
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(_foregroundChannel, (
            call,
          ) async {
            foregroundCalls.add(call);
            return true;
          }),
        );

        await expectLater(WidgetService.scheduleRefresh(), completes);
        expect(foregroundCalls, hasLength(1));
      });
    }

    test(
      'switching to Tor asks for the task; leaving Tor cancels it',
      () async {
        SharedPreferences.setMockInitialValues({
          AppConstants.keySelectedCurrencies: ['usd'],
        });
        FlutterSecureStorage.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final container = ProviderContainer(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        );
        addTearDown(container.dispose);
        final notifier = container.read(networkSettingsProvider.notifier);

        await notifier.setUseTor(true);
        await pumpEventQueue();
        expect(schedules(), [iosWidgetRefreshTaskId]);
        expect(cancels(), isEmpty);

        await notifier.setUseTor(false);
        await pumpEventQueue();
        expect(schedules(), [iosWidgetRefreshTaskId]);
        expect(cancels(), [iosWidgetRefreshTaskId]);
      },
    );

    test('Android: the route never touches the iOS task', () async {
      TorService.debugIsIOS = false;

      await WidgetService.backgroundRefreshFollows(const TorRoute());
      await WidgetService.backgroundRefreshFollows(const DirectRoute());

      expect(foregroundCalls, isEmpty);
    });
  });

  test('the App Group id is one constant: lib/ names it only in '
      'AppConstants (M5)', () {
    const id = 'group.app.bitbag.shared';
    expect(AppConstants.iosAppGroupId, id);
    final naming = [
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File &&
            f.path.endsWith('.dart') &&
            f.readAsStringSync().contains(id))
          f.path,
    ];
    expect(naming, ['lib/core/constants/app_constants.dart']);
  });

  group('native setup (skipped without ios/, as in the public snapshot)', () {
    final plist = File('ios/Runner/Info.plist');
    final delegate = File('ios/Runner/AppDelegate.swift');
    final skip = plist.existsSync() ? null : 'ios/ is absent';

    test('Info.plist permits the task id and the fetch background mode, '
        'nothing more', () {
      final text = plist.readAsStringSync();
      expect(
        RegExp(
          r'<key>BGTaskSchedulerPermittedIdentifiers</key>\s*<array>\s*'
          '<string>${RegExp.escape(iosWidgetRefreshTaskId)}</string>'
          r'\s*</array>',
        ).hasMatch(text),
        isTrue,
      );
      expect(
        RegExp(
          r'<key>UIBackgroundModes</key>\s*<array>\s*<string>fetch</string>'
          r'\s*</array>',
        ).hasMatch(text),
        isTrue,
      );
    }, skip: skip);

    test('AppDelegate registers the plugins for the background engine and '
        'the periodic task, before launch finishes', () {
      final text = delegate.readAsStringSync();
      expect(text, contains('import workmanager'));
      final callback = text.indexOf(
        'WorkmanagerPlugin.setPluginRegistrantCallback',
      );
      final task = text.indexOf(
        'WorkmanagerPlugin.registerPeriodicTask(\n'
        '      withIdentifier: "$iosWidgetRefreshTaskId",\n'
        '      frequency: NSNumber(value: 15 * 60))',
      );
      final launched = text.indexOf(
        'return super.application(application, didFinishLaunchingWithOptions',
      );
      expect(callback, greaterThan(0));
      expect(task, greaterThan(0));
      expect(launched, greaterThan(task));
      expect(launched, greaterThan(callback));
      expect(
        text.substring(callback, task),
        contains('GeneratedPluginRegistrant.register(with: registry)'),
      );
    }, skip: skip);
  });
}
