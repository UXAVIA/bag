/// Sentinel Lite on the iOS widget (Task 7, spec D11).
///
/// The background run's Sentinel part writes two App Group keys, a time and
/// a bool and nothing else: `widget_sentinel_checked_at` (epoch seconds, the
/// last run that checked at least one address and saved what it found) and
/// `widget_sentinel_ok` (whether the last run that wanted to check did).
/// A run that wanted the Sentinel part but couldn't check (keychain
/// unreadable, the route down, stopped) writes `ok = false` and leaves the
/// time. A run whose Sentinel part isn't wanted, or that finds Sentinel
/// switched off by the time it would write, writes neither. The run redraws
/// the widget once (R3). Turning Sentinel Lite off removes both keys (R24).
///
/// The Swift side is checked by its source shape, skipped without `ios/`
/// (the public snapshot).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/services/embedded_tor_service.dart';
import 'package:bag/services/notification_service.dart';
import 'package:bag/services/sentinel_records.dart';
import 'package:bag/services/tor_host.dart';
import 'package:bag/services/tor_service.dart';
import 'package:bag/services/wallet/esplora_client.dart';
import 'package:bag/services/widget_service.dart';

const _backgroundChannel = MethodChannel(
  'be.tramckrijte.workmanager/background_channel_work_manager',
);
const _foregroundChannel = MethodChannel(
  'be.tramckrijte.workmanager/foreground_channel_work_manager',
);

const _okKey = 'widget_sentinel_ok';
const _checkedAtKey = 'widget_sentinel_checked_at';

/// Prefs of an install that turned Sentinel Lite on once and off again.
const _turnedOff = {AppConstants.keySentinelEnabled: false};

const _cold = SentinelWatchEntry(walletId: 'w1', walletLabel: 'Cold');

String _addr(int n) => 'bc1qwatched$n';

String _watchJson(int n) =>
    jsonEncode({for (var i = 0; i < n; i++) _addr(i): _cold.toJson()});

/// A native Tor client that is ready at once, unless [hold] keeps its start
/// open (a stop releases it, as the plugin's cancel does).
class _Native implements EmbeddedTorBackend {
  bool _bootstrapped = false;
  Completer<void>? hold;
  bool _cancelled = false;
  final _failures = StreamController<Object>.broadcast();
  final _events = StreamController<int>.broadcast();

  @override
  Stream<Object> get failures => _failures.stream;

  @override
  Stream<int> get events => _events.stream;

  @override
  bool get bootstrapped => _bootstrapped;

  @override
  int get port => _bootstrapped ? 47123 : -1;

  @override
  Future<void> start() async {
    _cancelled = false;
    final held = hold;
    if (held != null) await held.future;
    if (!_cancelled) _bootstrapped = true;
  }

  @override
  Future<void> bootstrap() async {}

  @override
  Future<void> setDormant(bool dormant) async {}

  @override
  Future<void> stop() async {
    _bootstrapped = false;
    _cancelled = true;
    final held = hold;
    if (held != null && !held.isCompleted) held.complete();
  }
}

/// The IsolateNameServer's contract, in memory.
class _Registry implements TorPortRegistry {
  final Map<String, SendPort> names = {};

  @override
  SendPort? lookup(String name) => names[name];

  @override
  bool register(SendPort port, String name) {
    if (names.containsKey(name)) return false;
    names[name] = port;
    return true;
  }

  @override
  bool remove(String name) => names.remove(name) != null;
}

/// Answers every Esplora address lookup with no transactions; a key in
/// [holds] waits for its completer first.
void Function(Interceptors, NetworkRoute) _quietExplorer(
  List<String> requests,
  Map<String, Completer<void>> holds,
) => (interceptors, route) {
  interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        final segments = options.uri.pathSegments;
        final address = segments[segments.indexOf('address') + 1];
        requests.add(address);
        await holds[address]?.future;
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'chain_stats': {
                'tx_count': 0,
                'funded_txo_sum': 0,
                'spent_txo_sum': 0,
              },
              'mempool_stats': {
                'tx_count': 0,
                'funded_txo_sum': 0,
                'spent_txo_sum': 0,
              },
            },
          ),
        );
      },
    ),
  );
};

/// The widget part's price and chart. A path in [holds] waits for its
/// completer first; without [chart] the chart (bitbag.app and Kraken)
/// fails, so no chart set is written (the chart set's write chain is a
/// static future, which a fakeAsync test must not wait on).
class _WidgetAnswers {
  final holds = <String, Completer<void>>{};
  bool chart = true;

  void watch(Interceptors interceptors, NetworkRoute route) {
    interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          await holds[options.uri.path]?.future;
          final body = switch (options.uri.path) {
            '/api/price' => <String, dynamic>{
              'prices': {'usd': 50000.0},
              'changes24h': {'usd': 1.5},
            },
            '/api/chart' when chart => <String, dynamic>{
              'd': [
                [0, 49000.0],
                [1, 50000.0],
              ],
            },
            _ => null,
          };
          if (body == null) {
            handler.reject(DioException(requestOptions: options));
          } else {
            handler.resolve(
              Response(requestOptions: options, data: body, statusCode: 200),
            );
          }
        },
      ),
    );
  }
}

/// A keychain whose every write takes [delay].
class _SlowWrites extends TestFlutterSecureStoragePlatform {
  _SlowWrites(super.data, this.delay);

  final Duration delay;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    await Future<void>.delayed(delay);
    return super.write(key: key, value: value, options: options);
  }
}

/// A keychain every read of which fails, as before the first unlock.
class _LockedKeychain extends MapBase<String, String> {
  Never _refuse() => throw PlatformException(
    code: '-25308',
    message: 'errSecInteractionNotAllowed',
  );

  @override
  String? operator [](Object? key) => _refuse();

  @override
  void operator []=(String key, String value) => _refuse();

  @override
  void clear() => _refuse();

  @override
  Iterable<String> get keys => _refuse();

  @override
  String? remove(Object? key) => _refuse();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final widgetStore = <String, Object?>{};
  final widgetLog = <String>[];
  late List<String> explorerRequests;
  late Map<String, Completer<void>> explorerHolds;
  late _Native native;
  late _WidgetAnswers widgetAnswers;

  /// A save of one of these keys fails, as a home_widget call can.
  final failSaves = <String>{};

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
          final id = args['id'] as String;
          if (failSaves.contains(id)) {
            throw PlatformException(code: 'save failed');
          }
          widgetLog.add('save:$id');
          final data = args['data'];
          if (data == null) {
            widgetStore.remove(id);
          } else {
            widgetStore[id] = data;
          }
          return true;
        case 'getWidgetData':
          return widgetStore[args['id']];
        case 'updateWidget':
          widgetLog.add('reload');
          return true;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_backgroundChannel, (_) async => null);
    messenger.setMockMethodCallHandler(_foregroundChannel, (_) async => true);
  });

  setUp(() {
    explorerRequests = [];
    explorerHolds = {};
    native = _Native();
    widgetAnswers = _WidgetAnswers();
    failSaves.clear();
    EmbeddedTorService.debugBackend = native;
    TorHost.debugRegistry = _Registry();
    TorService.debugIsIOS = true;
    EsploraClient.debugInterceptDio = _quietExplorer(
      explorerRequests,
      explorerHolds,
    );
    WidgetService.debugInterceptBackgroundDio = widgetAnswers.watch;
    NotificationService.debugShow = (id, title, body) async {};
    widgetStore.clear();
    widgetLog.clear();
  });

  tearDown(() async {
    for (final hold in [
      ...explorerHolds.values,
      ...widgetAnswers.holds.values,
    ]) {
      if (!hold.isCompleted) hold.complete();
    }
    final held = native.hold;
    if (held != null && !held.isCompleted) held.complete();
    await EmbeddedTorService.stop();
    EmbeddedTorService.debugReset();
    EmbeddedTorService.debugBackend = null;
    TorHost.debugRegistry = null;
    TorService.debugIsIOS = null;
    EsploraClient.debugInterceptDio = null;
    WidgetService.debugInterceptBackgroundDio = null;
    NotificationService.debugShow = null;
  });

  void seed({
    Map<String, Object> prefs = const {},
    int addresses = 1,
    bool sentinel = true,
    bool pro = true,
  }) {
    SharedPreferences.setMockInitialValues({
      AppConstants.keyOnboardingComplete: true,
      AppConstants.keySelectedCurrencies: ['usd'],
      if (pro) AppConstants.keyProUnlocked: true,
      if (sentinel) AppConstants.keySentinelEnabled: true,
      ...prefs,
    });
    FlutterSecureStorage.setMockInitialValues({
      AppConstants.keyBtcAmount: '0.5',
      if (addresses > 0)
        AppConstants.keySentinelWatchMap: _watchJson(addresses),
    });
  }

  Future<Object?> runTask() async {
    backgroundWidgetCallback();
    const codec = StandardMethodCodec();
    final reply = await messenger.handlePlatformMessage(
      _backgroundChannel.name,
      codec.encodeMethodCall(
        MethodCall('onResultSend', {
          'be.tramckrijte.workmanager.DART_TASK': iosWidgetRefreshTaskId,
        }),
      ),
      null,
    );
    return codec.decodeEnvelope(reply!);
  }

  test('the key names are the constants Swift reads', () {
    expect(AppConstants.keyWidgetSentinelOk, _okKey);
    expect(AppConstants.keyWidgetSentinelCheckedAt, _checkedAtKey);
  });

  test('a run that checks writes ok and the time', () async {
    seed();
    final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    expect(await runTask(), isTrue);

    expect(explorerRequests, [_addr(0)]);
    expect(widgetStore[_okKey], isTrue);
    final at = widgetStore[_checkedAtKey];
    expect(at, isA<int>());
    expect((at as int) - before, inInclusiveRange(-5, 5));
    // The App Group is set before the keys, and the run redraws once.
    expect(widgetLog.first, 'group:${AppConstants.iosAppGroupId}');
    expect(redraws(), 1);
    expect(widgetLog.last, 'reload');
    // A time and a bool, nothing else.
    expect(saves().toSet(), {_okKey, _checkedAtKey});
  });

  test('a run that can\'t check writes paused and keeps the time', () async {
    seed();
    widgetStore[_checkedAtKey] = 1000;
    FlutterSecureStorage.setMockInitialValues(_LockedKeychain());

    expect(await runTask(), isTrue);

    expect(explorerRequests, isEmpty);
    expect(widgetStore[_okKey], isFalse);
    expect(widgetStore[_checkedAtKey], 1000);
    expect(saves(), [_okKey]);
    expect(redraws(), 1);
  });

  test('a proxy that is down: paused, nothing checked', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    seed(prefs: const {AppConstants.keyUseProxy: true});
    FlutterSecureStorage.setMockInitialValues({
      AppConstants.keySentinelWatchMap: _watchJson(1),
      AppConstants.keyNetworkProxy: jsonEncode(
        ProxyConfig(
          type: ProxyType.socks5,
          host: '127.0.0.1',
          port: port,
        ).toJson(),
      ),
    });

    expect(await runTask(), isTrue);

    expect(explorerRequests, isEmpty);
    expect(saves(), [_okKey]);
    expect(widgetStore[_okKey], isFalse);
    expect(redraws(), 1);
  });

  test('no wallet on the watch map: nothing to say, nothing written', () async {
    seed(addresses: 0);

    expect(await runTask(), isTrue);

    expect(widgetLog, isEmpty);
  });

  test('Sentinel switched off during the run: neither key written', () async {
    seed(addresses: 2);
    explorerHolds[_addr(0)] = Completer<void>();
    explorerHolds[_addr(1)] = Completer<void>();
    final run = runTask();
    while (explorerRequests.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await (await SharedPreferences.getInstance()).setBool(
      AppConstants.keySentinelEnabled,
      false,
    );
    for (final hold in explorerHolds.values) {
      hold.complete();
    }

    expect(await run, isTrue);

    expect(saves(), isNot(contains(_okKey)));
    expect(saves(), isNot(contains(_checkedAtKey)));
    expect(redraws(), 0);
  });

  test('Sentinel off writes nothing: a Tor widget run leaves both keys '
      'alone', () async {
    seed(prefs: const {AppConstants.keyUseTor: true}, sentinel: false);

    expect(await runTask(), isTrue);

    expect(widgetStore['widget_route_ok'], isTrue, reason: 'the widget part');
    expect(saves(), isNot(contains(_okKey)));
    expect(saves(), isNot(contains(_checkedAtKey)));
    // Unchanged: the widget part's keys, then its one redraw, last.
    expect(redraws(), 1);
    expect(widgetLog.last, 'reload');
    expect(
      saves(),
      containsAll([
        'widget_price',
        'widget_route_ok',
        'widget_fetched_at',
        'widget_chart_prices',
        'widget_chart_days',
      ]),
    );
  });

  test('Tor with Sentinel on but no Pro: the widget part, and Sentinel Lite '
      'reads paused, in the one redraw (R33)', () async {
    seed(prefs: const {AppConstants.keyUseTor: true}, pro: false);
    widgetStore[_checkedAtKey] = 1000;

    expect(await runTask(), isTrue);

    expect(widgetStore['widget_price'], isNotNull);
    expect(explorerRequests, isEmpty);
    expect(widgetStore[_okKey], isFalse);
    expect(widgetStore[_checkedAtKey], 1000);
    expect(saves(), isNot(contains(_checkedAtKey)));
    expect(redraws(), 1);
    expect(widgetLog.last, 'reload');
  });

  group('R33: a run without the Sentinel part says what holds', () {
    for (final (name, prefs, secure, pro)
        in <(String, Map<String, Object>, Map<String, String>, bool)>[
      ('Direct without Pro', const {}, const {}, false),
      (
        'unreadable proxy settings',
        const {AppConstants.keyUseProxy: true},
        const {AppConstants.keyNetworkProxy: 'not json'},
        true,
      ),
    ]) {
      test('$name, Sentinel Lite on: paused, the time kept, one redraw, no '
          'request', () async {
        seed(prefs: prefs, pro: pro);
        FlutterSecureStorage.setMockInitialValues({
          AppConstants.keySentinelWatchMap: _watchJson(1),
          ...secure,
        });
        widgetStore[_okKey] = true;
        widgetStore[_checkedAtKey] = 1000;

        expect(await runTask(), isTrue);

        expect(explorerRequests, isEmpty);
        expect(widgetStore[_okKey], isFalse);
        expect(widgetStore[_checkedAtKey], 1000);
        expect(saves(), [_okKey]);
        expect(redraws(), 1);
        expect(widgetLog.last, 'reload');
      });

      test('$name, already paused: no write and no redraw (R29)', () async {
        seed(prefs: prefs, pro: pro);
        FlutterSecureStorage.setMockInitialValues({
          AppConstants.keySentinelWatchMap: _watchJson(1),
          ...secure,
        });
        widgetStore[_okKey] = false;
        widgetStore[_checkedAtKey] = 1000;

        expect(await runTask(), isTrue);

        expect(saves(), isEmpty);
        expect(redraws(), 0);
      });
    }

    test('Direct, Sentinel Lite off with its status still shown: both keys '
        'removed, one redraw', () async {
      seed(prefs: _turnedOff, sentinel: false);
      widgetStore[_okKey] = true;
      widgetStore[_checkedAtKey] = 1000;

      expect(await runTask(), isTrue);

      expect(widgetStore.containsKey(_okKey), isFalse);
      expect(widgetStore.containsKey(_checkedAtKey), isFalse);
      expect(saves().toSet(), {_okKey, _checkedAtKey});
      expect(redraws(), 1);
      expect(widgetLog.last, 'reload');
    });

    test('Direct, Sentinel Lite off with only the time left: removed too',
        () async {
      seed(prefs: _turnedOff, sentinel: false);
      widgetStore[_checkedAtKey] = 1000;

      expect(await runTask(), isTrue);

      expect(widgetStore.containsKey(_checkedAtKey), isFalse);
      expect(redraws(), 1);
    });

    test('Direct, Sentinel Lite off and no status: no write, no redraw',
        () async {
      seed(prefs: _turnedOff, sentinel: false);

      expect(await runTask(), isTrue);

      expect(saves(), isEmpty);
      expect(redraws(), 0);
    });

    test('Sentinel Lite never turned on (no flag): no App Group call at all',
        () async {
      seed(sentinel: false);
      widgetStore[_okKey] = true;

      expect(await runTask(), isTrue);

      expect(widgetLog, isEmpty);
    });

    test('Tor, Sentinel Lite off with its status still shown: both keys '
        'removed, in the widget part\'s one redraw', () async {
      seed(
        prefs: const {AppConstants.keyUseTor: true, ..._turnedOff},
        sentinel: false,
      );
      widgetStore[_okKey] = false;
      widgetStore[_checkedAtKey] = 1000;

      expect(await runTask(), isTrue);

      expect(widgetStore['widget_price'], isNotNull);
      expect(widgetStore.containsKey(_okKey), isFalse);
      expect(widgetStore.containsKey(_checkedAtKey), isFalse);
      expect(redraws(), 1);
      expect(widgetLog.last, 'reload');
    });

    test('Tor not ready, no Pro: Sentinel Lite paused and the route paused, '
        'one redraw', () {
      fakeAsync((async) {
        seed(prefs: const {AppConstants.keyUseTor: true}, pro: false);
        native.hold = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 23));
        expect(result, isTrue);
        expect(widgetStore[_okKey], isFalse);
        expect(widgetStore['widget_route_ok'], isFalse);
        async.elapse(const Duration(minutes: 1));
        expect(redraws(), 1);
      });
    });

    test('Tor not ready, Sentinel Lite off with its status shown: removed, '
        'one redraw', () {
      fakeAsync((async) {
        seed(
          prefs: const {AppConstants.keyUseTor: true, ..._turnedOff},
          sentinel: false,
        );
        widgetStore[_okKey] = true;
        widgetStore[_checkedAtKey] = 1000;
        native.hold = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 23));
        expect(result, isTrue);
        expect(widgetStore.containsKey(_okKey), isFalse);
        expect(widgetStore.containsKey(_checkedAtKey), isFalse);
        async.elapse(const Duration(minutes: 1));
        expect(redraws(), 1);
      });
    });

    test('a doubtful prefs read (no onboarding_complete) leaves the status '
        'alone', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keySelectedCurrencies: ['usd'],
        ..._turnedOff,
      });
      widgetStore[_okKey] = true;
      widgetStore[_checkedAtKey] = 1000;

      expect(await runTask(), isTrue);

      expect(widgetLog, isEmpty);
      expect(widgetStore[_okKey], isTrue);
      expect(widgetStore[_checkedAtKey], 1000);
    });

    test('Sentinel Lite switched on since the run read it: its status is '
        'not removed', () async {
      seed(prefs: _turnedOff, sentinel: false);
      widgetStore[_okKey] = true;
      widgetStore[_checkedAtKey] = 1000;
      // The run's first read says off; the status writer's re-read says on.
      var reads = 0;
      WidgetService.debugIosRoutePrefs = () async {
        final prefs = await SharedPreferences.getInstance();
        if (++reads == 2) {
          await prefs.setBool(AppConstants.keySentinelEnabled, true);
        }
        return prefs;
      };
      addTearDown(() => WidgetService.debugIosRoutePrefs = null);

      expect(await runTask(), isTrue);

      expect(widgetStore[_okKey], isTrue);
      expect(widgetStore[_checkedAtKey], 1000);
      expect(redraws(), 0);
    });
  });

  test('R29: paused when it was already paused (no new time) is no write '
      'and no redraw', () async {
    seed();
    widgetStore[_okKey] = false;
    widgetStore[_checkedAtKey] = 1000;
    FlutterSecureStorage.setMockInitialValues(_LockedKeychain());

    expect(await runTask(), isTrue);

    expect(saves(), isEmpty);
    expect(redraws(), 0);
    expect(widgetStore[_okKey], isFalse);
    expect(widgetStore[_checkedAtKey], 1000);
  });

  test(
    'R29: checked after a pause writes ok, a new time and redraws',
    () async {
      seed();
      widgetStore[_okKey] = false;
      widgetStore[_checkedAtKey] = 1000;

      expect(await runTask(), isTrue);

      expect(widgetStore[_okKey], isTrue);
      expect(widgetStore[_checkedAtKey], isNot(1000));
      expect(redraws(), 1);
    },
  );

  test('Tor not ready: widget_sentinel_ok and widget_route_ok false first, '
      'then one redraw', () {
    fakeAsync((async) {
      seed(prefs: const {AppConstants.keyUseTor: true});
      native.hold = Completer<void>();
      Object? result;
      runTask().then((r) => result = r);

      async.elapse(const Duration(seconds: 23));
      expect(result, isTrue);
      expect(explorerRequests, isEmpty);
      expect(widgetLog.where((e) => e.startsWith('save:') || e == 'reload'), [
        'save:$_okKey',
        'save:widget_route_ok',
        'reload',
      ]);
      expect(widgetStore[_okKey], isFalse);
      expect(widgetStore['widget_route_ok'], isFalse);
      async.elapse(const Duration(minutes: 1));
      expect(redraws(), 1);
    });
  });

  group('R28: one redraw per Tor run, never after it returns', () {
    test('the widget part done early, the Sentinel save running past 25 s: '
        'one redraw at deadline − 0.5 s, before the result, and no status '
        'write after it', () {
      fakeAsync((async) {
        seed(prefs: const {AppConstants.keyUseTor: true}, addresses: 2);
        // The saves (keychain writes of 2 s) start at the save cut-off,
        // 24 s, so they end past 25 s.
        FlutterSecureStoragePlatform.instance = _SlowWrites({
          AppConstants.keyBtcAmount: '0.5',
          AppConstants.keySentinelWatchMap: _watchJson(2),
        }, const Duration(seconds: 2));
        widgetAnswers.chart = false;
        // One address never answers, so the check runs to the cut-off.
        explorerHolds[_addr(1)] = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 5));
        expect(widgetStore['widget_price'], isNotNull, reason: 'the price');
        expect(redraws(), 0, reason: 'redrew before the Sentinel part');

        async.elapse(const Duration(seconds: 19, milliseconds: 400));
        expect(redraws(), 0, reason: 'redrew before deadline − 0.5 s');
        async.elapse(const Duration(milliseconds: 200));
        expect(redraws(), 1, reason: 'no redraw by deadline − 0.5 s');
        expect(result, isNull);

        async.elapse(const Duration(milliseconds: 500));
        expect(result, isTrue);
        async.elapse(const Duration(minutes: 1));
        expect(redraws(), 1, reason: 'a redraw after the run returned');
        expect(saves(), isNot(contains(_okKey)));
        expect(saves(), isNot(contains(_checkedAtKey)));
      });
    });

    test('the price written, then the chart hangs: one redraw by deadline − '
        '0.5 s', () {
      fakeAsync((async) {
        seed(prefs: const {AppConstants.keyUseTor: true}, sentinel: false);
        final chart = widgetAnswers.holds['/api/chart'] = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 24, milliseconds: 400));
        expect(widgetStore['widget_price'], isNotNull);
        expect(redraws(), 0);
        async.elapse(const Duration(milliseconds: 200));
        expect(redraws(), 1);
        expect(result, isNull);
        async.elapse(const Duration(milliseconds: 500));
        expect(result, isTrue);

        chart.complete();
        async.elapse(const Duration(minutes: 1));
        expect(redraws(), 1, reason: 'a redraw after the run returned');
      });
    });

    test('the widget part throws after the price write: still one redraw, '
        'after the price', () async {
      seed(prefs: const {AppConstants.keyUseTor: true}, sentinel: false);
      failSaves.add('widget_chart_change');

      expect(await runTask(), isTrue);

      expect(widgetStore['widget_price'], isNotNull);
      expect(redraws(), 1);
      expect(widgetLog.last, 'reload');
      expect(
        widgetLog.indexOf('save:widget_price'),
        lessThan(widgetLog.indexOf('reload')),
      );
    });
  });

  test('Tor with Sentinel on: one redraw covers both parts, after both '
      'wrote', () async {
    seed(prefs: const {AppConstants.keyUseTor: true});

    expect(await runTask(), isTrue);

    expect(widgetStore['widget_route_ok'], isTrue);
    expect(widgetStore[_okKey], isTrue);
    expect(redraws(), 1);
    expect(widgetLog.last, 'reload');
  });

  test('turning Sentinel Lite off clears the status', () async {
    widgetStore[_okKey] = true;
    widgetStore[_checkedAtKey] = 1000;

    await WidgetService.clearSentinelStatus();

    expect(widgetStore.containsKey(_okKey), isFalse);
    expect(widgetStore.containsKey(_checkedAtKey), isFalse);
    expect(saves().toSet(), {_okKey, _checkedAtKey});
    expect(redraws(), 1);
  });

  group('BagWidget.swift (skipped without ios/)', () {
    final swift = File('ios/BagWidget/BagWidget.swift');
    final skip = swift.existsSync() ? null : 'ios/ is absent';

    test('reads both keys type-safely and draws the status', () {
      final src = swift.readAsStringSync();
      expect(src, contains('"$_okKey"'));
      expect(src, contains('"$_checkedAtKey"'));
      expect(src, contains('object(forKey: "$_checkedAtKey") as? NSNumber'));
      expect(src, contains('object(forKey: "$_okKey") as? Bool'));
      expect(src, isNot(contains('integer(forKey: "$_checkedAtKey")')));
      expect(src, isNot(contains('bool(forKey: "$_okKey")')));
      expect(src, contains('"Sentinel Lite · checked'));
      expect(src, contains('"Sentinel Lite · paused"'));
      expect(src, contains('Image(systemName: "shield.fill")'));
    }, skip: skip);

    /// [src] from [start] to the first [end] after it, whitespace collapsed.
    String section(String src, String start, String end) {
      final from = src.indexOf(start);
      expect(from, greaterThan(-1), reason: start);
      final to = src.indexOf(end, from + start.length);
      expect(to, greaterThan(-1), reason: end);
      return src.substring(from, to).replaceAll(RegExp(r'\s+'), ' ');
    }

    test('nothing is drawn without widget_sentinel_ok', () {
      final status = section(
        swift.readAsStringSync(),
        'struct SentinelStatus {',
        'struct BagEntry: TimelineEntry {',
      );
      expect(
        status,
        contains(
          'guard let ok = ud?.object(forKey: "$_okKey") as? Bool '
          'else { return nil }',
        ),
      );
    }, skip: skip);

    test('both families draw only inside `if let sentinel`', () {
      final src = swift.readAsStringSync();
      final small = section(
        src,
        'struct SmallView: View {',
        'struct MediumView',
      );
      final medium = section(
        src,
        'struct MediumView: View {',
        'struct BagWidgetEntryView',
      );
      for (final (name, view) in [('small', small), ('medium', medium)]) {
        expect(view, contains('if let sentinel = e.sentinel {'), reason: name);
        // Every use of the status is through the unwrapped `sentinel`.
        expect(view, isNot(contains('e.sentinel?')), reason: name);
        expect(view, isNot(contains('e.sentinel!')), reason: name);
      }
      expect(
        small,
        contains(
          'if let sentinel = e.sentinel { // Sentinel Lite: '
          'green only when checked today (R30), grey otherwise. '
          'Image(systemName: "shield.fill")',
        ),
      );
      expect(
        medium,
        contains(
          'if let sentinel = e.sentinel { Text(sentinel.text(now: e.date))',
        ),
      );
    }, skip: skip);

    test('the status reaches the entry on every path, the Tor push '
        '(loadPushed) included', () {
      final src = swift.readAsStringSync();
      final load = section(
        src,
        'static func load(showChange: Bool = true) -> BagEntry {',
        'static func loadPushed(',
      );
      expect(load, contains('sentinel: SentinelStatus.load(ud))'));
      final pushed = section(
        src,
        'static func loadPushed(',
        'static var placeholder: BagEntry {',
      );
      expect('sentinel: base.sentinel)'.allMatches(pushed), hasLength(2));
    }, skip: skip);

    test('R30: the shield is green only for a check from today, and the '
        'midnight entry follows the check time too', () {
      final src = swift.readAsStringSync();
      final status = section(
        src,
        'struct SentinelStatus {',
        'struct BagEntry: TimelineEntry {',
      );
      expect(
        status,
        contains(
          'func checkedToday(now: Date) -> Bool { '
          'guard ok, let checkedAt = checkedAt else { return false } '
          'return Calendar.current.isDate(checkedAt, inSameDayAs: now) }',
        ),
      );
      final small = section(
        src,
        'struct SmallView: View {',
        'struct MediumView',
      );
      expect(
        small,
        contains(
          '.foregroundColor(sentinel.checkedToday(now: e.date) '
          '? routeOkDot : mutedText)',
        ),
      );
      expect(small, isNot(contains('sentinel.checking ? routeOkDot')));
      final entry = section(src, 'var hasTimeFromToday: Bool {', '\n    }\n');
      expect(entry, contains('status.fetchedAt'));
      expect(entry, contains('sentinel?.checkedAt'));
      expect(
        entry,
        contains('Calendar.current.isDate(\$0, inSameDayAs: date)'),
      );
      final timeline = section(
        src,
        'func timeline(for configuration: BagWidgetIntent',
        'return Timeline(entries: entries',
      );
      expect(
        timeline,
        contains(
          'var entries = [entry] if entry.hasTimeFromToday, let midnight',
        ),
      );
    }, skip: skip);
  });
}
