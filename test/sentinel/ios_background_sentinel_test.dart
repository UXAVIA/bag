/// iOS Sentinel Lite in the background refresh (Task 4; spec D2, D5, D7).
///
/// The BGAppRefreshTask `app.bitbag.widget-refresh` is now also asked for
/// while Sentinel Lite is on and Pro is unlocked, on any route but unreadable
/// proxy settings. A run does its widget part only on Tor (unchanged) and its
/// Sentinel part when Sentinel is on and the Pro bool is set: on Tor through
/// the run's lease, on a proxy once the proxy answers its probe, on Direct
/// straight away. Both parts run inside the run's 25 s deadline.
///
/// - The Sentinel part reads the watch map, the seen records and its own
///   state from the keychain; a read that fails means "can't check": no
///   request, nothing written. A malformed state blob reads as empty (R10).
/// - Requests are single-attempt, at most 2 at a time on a private route and
///   4 on Direct, none after deadline − 4 s, and the Esplora client is closed
///   at the deadline.
/// - State (counts, cursor, seen records) is saved before any alert is
///   shown, and `sentinel_last_scan` after, only when an address was
///   checked. A run stopped by a route change, Sentinel or Pro switched off,
///   or a wallet removed, saves and shows nothing; the next run finds the
///   same transactions again.
/// - Fail closed: no Pro, Sentinel off, unreadable keychain, Tor not ready,
///   a proxy that is down, unreadable proxy settings → no Sentinel request.
/// - The schedule follows `iosBackgroundRunWanted`; a doubtful prefs read
///   changes nothing (M-a).
///
/// Tor runs with Sentinel off are covered, unchanged, by
/// test/tor/ios_background_refresh_test.dart. Esplora requests are answered
/// by interceptors on the client's own routed Dio
/// (`EsploraClient.debugInterceptDio`) or, end to end, by a loopback server.
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
import 'package:bag/services/sentinel_ios_check.dart';
import 'package:bag/services/sentinel_records.dart';
import 'package:bag/services/tor_host.dart';
import 'package:bag/services/tor_service.dart';
import 'package:bag/services/wallet/biometric_storage_service.dart' as bio;
import 'package:bag/services/wallet/esplora_client.dart';
import 'package:bag/services/widget_service.dart';

import '../network/fake_proxies.dart';

const _backgroundChannel = MethodChannel(
  'be.tramckrijte.workmanager/background_channel_work_manager',
);
const _foregroundChannel = MethodChannel(
  'be.tramckrijte.workmanager/foreground_channel_work_manager',
);

const _cold = SentinelWatchEntry(walletId: 'w1', walletLabel: 'Cold');
const _spending = SentinelWatchEntry(walletId: 'w2', walletLabel: 'Spending');

/// A watched address; the engine sorts them, so [n] orders them.
String _addr(int n) => 'bc1qwatched$n';

/// A 64-hex txid whose first 8 hex chars are [n], so `sentinelNotifId`
/// reads back [n].
String _txid(int n) => n.toRadixString(16).padLeft(8, '0') + '0' * 56;

/// Esplora's `/address/:addr` answer.
Map<String, dynamic> _stats(int chain, int mempool) => {
  'chain_stats': {'tx_count': chain, 'funded_txo_sum': 0, 'spent_txo_sum': 0},
  'mempool_stats': {
    'tx_count': mempool,
    'funded_txo_sum': 0,
    'spent_txo_sum': 0,
  },
};

/// A transaction as Esplora lists it.
Map<String, dynamic> _tx(
  String txid, {
  List<(String, int)> inputs = const [],
  List<(String, int)> outputs = const [],
}) => {
  'txid': txid,
  'vin': [
    for (final (a, v) in inputs)
      {
        'prevout': {'scriptpubkey_address': a, 'value': v},
      },
  ],
  'vout': [
    for (final (a, v) in outputs) {'scriptpubkey_address': a, 'value': v},
  ],
};

String _watchJson(Map<String, SentinelWatchEntry> map) =>
    jsonEncode(map.map((k, v) => MapEntry(k, v.toJson())));

/// [n] addresses of [entry], from [from] on.
Map<String, SentinelWatchEntry> _watch(
  SentinelWatchEntry entry,
  int n, {
  int from = 0,
}) => {for (var i = from; i < from + n; i++) _addr(i): entry};

/// A native client like the plugin's: a start can be held open, a stop
/// cancels a held start.
class _Native implements EmbeddedTorBackend {
  int socksPort = 47123;
  int startCalls = 0;
  int stopCalls = 0;

  /// The next start waits on this.
  Completer<void>? hold;

  Completer<void>? _held;
  bool _cancelled = false;
  bool _bootstrapped = false;
  final _failures = StreamController<Object>.broadcast();
  final _events = StreamController<int>.broadcast();

  void releaseStart() {
    final held = _held;
    if (held != null && !held.isCompleted) held.complete();
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
  Future<void> setDormant(bool dormant) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
    _bootstrapped = false;
    _cancelled = true;
    releaseStart();
  }
}

/// The IsolateNameServer's contract, in memory.
class _Registry implements TorPortRegistry {
  static const _markNames = {TorHost.usedPortName, TorHost.unsweptPortName};

  final Map<String, SendPort> names = {};
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

/// One Esplora request as the client's own routed Dio sent it.
typedef _Request = ({
  String key,
  String host,
  NetworkRoute route,
  EmbeddedTorState tor,
  int port,
});

/// Answers the Sentinel part's Esplora requests on the client's own Dio
/// (`EsploraClient.debugInterceptDio`; the hook can only add interceptors).
/// A request's key is the address, `<address>/txs/mempool` or
/// `<address>/txs/chain`. A key in [holds] waits for its completer, one in
/// [failing] fails as a refused connection, and anything unscripted goes out
/// over the route with [passThrough], or fails.
class _Esplora {
  final routes = <NetworkRoute>[];
  final requests = <_Request>[];
  final stats = <String, Map<String, dynamic>>{};
  final mempool = <String, List<Map<String, dynamic>>>{};
  final chain = <String, List<Map<String, dynamic>>>{};
  final holds = <String, Completer<void>>{};
  final failing = <String>{};
  bool passThrough = false;
  int inFlight = 0;
  int maxInFlight = 0;

  List<String> get keys => [for (final r in requests) r.key];

  static String keyOf(Uri uri) {
    final segments = uri.pathSegments;
    final i = segments.indexOf('address');
    return [segments[i + 1], ...segments.sublist(i + 2)].join('/');
  }

  Object? _answer(String key) {
    final parts = key.split('/');
    final address = parts.first;
    return switch (parts.sublist(1).join('/')) {
      '' => stats[address],
      'txs/mempool' => mempool[address] ?? const [],
      'txs/chain' => chain[address] ?? const [],
      _ => null,
    };
  }

  void releaseAll() {
    for (final hold in holds.values) {
      if (!hold.isCompleted) hold.complete();
    }
  }

  void watch(Interceptors interceptors, NetworkRoute route) {
    routes.add(route);
    interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final key = keyOf(options.uri);
          requests.add((
            key: key,
            host: options.uri.host,
            route: route,
            tor: EmbeddedTorService.state,
            port: route is TorRoute ? await TorHost.port() : -1,
          ));
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          try {
            await holds[key]?.future;
            // A few event-loop turns, so concurrent requests overlap.
            await Future<void>.delayed(Duration.zero);
            await Future<void>.delayed(Duration.zero);
          } finally {
            inFlight--;
          }
          if (failing.contains(key)) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                error: 'refused',
              ),
            );
            return;
          }
          final body = _answer(key);
          if (body != null) {
            handler.resolve(
              Response(
                requestOptions: options,
                data: jsonDecode(jsonEncode(body)),
                statusCode: 200,
              ),
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

/// The widget part's requests (the run's background Dio), answered with a
/// price and a chart.
class _WidgetRequests {
  final routes = <NetworkRoute>[];
  final paths = <String>[];

  /// A path here waits for its completer first.
  final holds = <String, Completer<void>>{};

  void watch(Interceptors interceptors, NetworkRoute route) {
    routes.add(route);
    interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          paths.add(options.uri.path);
          await holds[options.uri.path]?.future;
          final body = switch (options.uri.path) {
            '/api/price' => <String, dynamic>{
              'prices': {'usd': 50000.0},
              'changes24h': {'usd': 1.5},
            },
            '/api/chart' => <String, dynamic>{
              'd': [
                [0, 49000.0],
                [1, 50000.0],
              ],
            },
            _ => null,
          };
          if (body == null) {
            handler.reject(
              DioException(requestOptions: options, error: 'no canned body'),
            );
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

/// A keychain whose every write takes [writeDelay], as a keychain write on a
/// busy device may.
class _SlowWrites extends TestFlutterSecureStoragePlatform {
  _SlowWrites(super.data);

  static const writeDelay = Duration(milliseconds: 100);

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    await Future<void>.delayed(writeDelay);
    return super.write(key: key, value: value, options: options);
  }
}

/// A keychain whose reads of [locked] keys (every key with [all]) fail, as
/// iOS refuses an item that isn't accessible yet
/// (`errSecInteractionNotAllowed`). Writes land in [data].
class _Keychain extends MapBase<String, String> {
  _Keychain(this.data, {this.locked = const {}, this.all = false});

  final Map<String, String> data;
  final Set<String> locked;
  final bool all;

  Never _refuse() => throw PlatformException(
    code: '-25308',
    message: 'errSecInteractionNotAllowed',
  );

  @override
  String? operator [](Object? key) {
    if (all || locked.contains(key)) _refuse();
    return data[key];
  }

  @override
  void operator []=(String key, String value) {
    if (all) _refuse();
    data[key] = value;
  }

  @override
  void clear() => all ? _refuse() : data.clear();

  @override
  Iterable<String> get keys => all ? _refuse() : data.keys;

  @override
  String? remove(Object? key) => all ? _refuse() : data.remove(key);
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
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  // The binding is needed for the platform channels, but it also installs
  // HttpOverrides that answer every request with a canned 400 without
  // touching a socket. The loopback explorer and the proxy are real sockets.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _Native native;
  late _Registry registry;
  late _Esplora esplora;
  late _WidgetRequests widgetRequests;

  // The App Group (HomeWidget), and every channel call in order:
  // `group:<id>`, `get:<key>`, `save:<key>` and `reload`.
  final widgetStore = <String, Object?>{};
  final widgetLog = <String>[];
  final foregroundCalls = <MethodCall>[];

  /// Every alert shown, through `NotificationService.debugShow`.
  final shown = <({int id, String title, String body})>[];

  List<Object?> cancels() => [
    for (final c in foregroundCalls)
      if (c.method == 'cancelTaskByUniqueName')
        (c.arguments as Map)['uniqueName'],
  ];

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

  /// [saves] but the Sentinel Lite status (Task 7, R2), which a run that
  /// wanted the Sentinel part writes on every route.
  List<String> widgetKeySaves() => [
    for (final key in saves())
      if (key != AppConstants.keyWidgetSentinelOk &&
          key != AppConstants.keyWidgetSentinelCheckedAt)
        key,
  ];

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
          return widgetStore[args['id']];
        case 'updateWidget':
          widgetLog.add('reload');
          return true;
      }
      return null;
    });
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
    esplora = _Esplora();
    widgetRequests = _WidgetRequests();
    EmbeddedTorService.debugBackend = native;
    TorHost.debugRegistry = registry;
    TorService.debugIsIOS = true;
    EsploraClient.debugInterceptDio = esplora.watch;
    WidgetService.debugInterceptBackgroundDio = widgetRequests.watch;
    NotificationService.debugShow = (id, title, body) async {
      shown.add((id: id, title: title, body: body));
    };
    widgetStore.clear();
    widgetLog.clear();
    foregroundCalls.clear();
    shown.clear();
  });

  tearDown(() async {
    esplora.releaseAll();
    native.releaseStart();
    await EmbeddedTorService.stop();
    EmbeddedTorService.debugReset();
    EmbeddedTorService.debugBackend = null;
    TorHost.debugRegistry = null;
    TorService.debugIsIOS = null;
    EsploraClient.debugInterceptDio = null;
    EsploraClient.debugRetryDelayUnit = const Duration(seconds: 1);
    WidgetService.debugInterceptBackgroundDio = null;
    WidgetService.debugIosRoutePrefs = null;
    WidgetService.debugIosTaskBudget = null;
    NotificationService.debugShow = null;
  });

  /// Seeds prefs and the keychain for one run: onboarded, Direct unless
  /// [prefs] says otherwise, Sentinel Lite on and Pro unless told not to,
  /// [watch] as the watch map.
  void seed({
    Map<String, Object> prefs = const {},
    Map<String, String> secure = const {},
    Map<String, SentinelWatchEntry> watch = const {},
    bool sentinel = true,
    bool pro = true,
    bool onboarded = true,
  }) {
    SharedPreferences.setMockInitialValues({
      if (onboarded) AppConstants.keyOnboardingComplete: true,
      AppConstants.keySelectedCurrencies: ['usd'],
      if (sentinel) AppConstants.keySentinelEnabled: true,
      if (pro) AppConstants.keyProUnlocked: true,
      ...prefs,
    });
    FlutterSecureStorage.setMockInitialValues({
      AppConstants.keyBtcAmount: '0.5',
      if (watch.isNotEmpty) AppConstants.keySentinelWatchMap: _watchJson(watch),
      ...secure,
    });
  }

  /// Every watched address answers with no transactions at all.
  void answerQuiet(Iterable<String> addresses) {
    for (final a in addresses) {
      esplora.stats[a] = _stats(0, 0);
    }
  }

  /// [address] holds one pending payment of [sats] into it.
  String answerPendingIn(String address, int sats, {int txid = 0x1001}) {
    final id = _txid(txid);
    esplora.stats[address] = _stats(0, 1);
    esplora.mempool[address] = [
      _tx(
        id,
        inputs: [('bc1qsomeoneelse', sats + 500)],
        outputs: [(address, sats)],
      ),
    ];
    return id;
  }

  /// Runs the task as the workmanager plugin does on iOS.
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

  Future<SharedPreferences> prefsNow() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs;
  }

  Future<String?> lastScan() async =>
      (await prefsNow()).getString(AppConstants.keySentinelLastScan);

  Future<IosSentinelState?> storedState() async {
    final raw = await bio.readSecureValue(AppConstants.keySentinelIosActivity);
    if (raw == null) return null;
    return IosSentinelState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>?> storedSeen() async {
    final raw = await bio.readSecureValue(AppConstants.keySentinelSeenTxids);
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Nothing of Sentinel's was written, stamped or shown.
  Future<void> expectNothingSaved() async {
    expect(shown, isEmpty, reason: 'showed an alert');
    expect(await lastScan(), isNull, reason: 'stamped sentinel_last_scan');
    expect(
      await bio.readSecureValue(AppConstants.keySentinelIosActivity),
      isNull,
      reason: 'wrote the activity blob',
    );
    expect(
      await bio.readSecureValue(AppConstants.keySentinelSeenTxids),
      isNull,
      reason: 'wrote the seen records',
    );
  }

  group('iosBackgroundRunWanted', () {
    test('matrix: Tor always; Direct or a proxy with Sentinel Lite and Pro; '
        'never unreadable proxy settings without Tor', () {
      final proxy = ProxyRoute(
        ProxyConfig(type: ProxyType.socks5, host: '127.0.0.1', port: 9999),
      );
      final routes = <NetworkRoute>[
        const TorRoute(),
        const DirectRoute(),
        proxy,
        const MisconfiguredProxyRoute(),
      ];
      for (final route in routes) {
        for (final sentinelOn in [false, true]) {
          for (final pro in [false, true]) {
            final expected =
                route is TorRoute ||
                (sentinelOn && pro && route is! MisconfiguredProxyRoute);
            expect(
              iosBackgroundRunWanted(
                route: route,
                sentinelOn: sentinelOn,
                pro: pro,
              ),
              expected,
              reason: '$route sentinel=$sentinelOn pro=$pro',
            );
          }
        }
      }
      // The brief's named cases.
      expect(
        iosBackgroundRunWanted(
          route: const TorRoute(),
          sentinelOn: false,
          pro: false,
        ),
        isTrue,
      );
      expect(
        iosBackgroundRunWanted(
          route: const DirectRoute(),
          sentinelOn: true,
          pro: true,
        ),
        isTrue,
      );
      expect(
        iosBackgroundRunWanted(route: proxy, sentinelOn: true, pro: true),
        isTrue,
      );
      expect(
        iosBackgroundRunWanted(
          route: const DirectRoute(),
          sentinelOn: true,
          pro: false,
        ),
        isFalse,
      );
      expect(
        iosBackgroundRunWanted(
          route: const MisconfiguredProxyRoute(),
          sentinelOn: true,
          pro: true,
        ),
        isFalse,
      );
      expect(
        iosBackgroundRunWanted(
          route: const DirectRoute(),
          sentinelOn: false,
          pro: true,
        ),
        isFalse,
      );
    });
  });

  group('Direct', () {
    test('Direct with Sentinel on runs only the Sentinel part: Esplora '
        'requests at most 4 at a time, one alert for a pending payment, '
        'state saved, sentinel_last_scan written, no widget key but the '
        'Sentinel Lite status and one redraw', () async {
      final watch = _watch(_cold, 6);
      seed(watch: watch);
      answerQuiet(watch.keys);
      final txid = answerPendingIn(_addr(0), 50000);
      final before = DateTime.now();

      expect(await runTask(), isTrue);

      // The Sentinel part only: no Tor, no widget request, nothing in the
      // App Group but the Sentinel Lite status, one redraw for it (R2, R3).
      expect(native.startCalls, 0);
      expect(widgetRequests.routes, isEmpty, reason: 'built the widget Dio');
      expect(widgetKeySaves(), isEmpty, reason: 'wrote a widget key');
      expect(redraws(), 1, reason: 'the Sentinel status redraw (R3)');
      expect(widgetStore[AppConstants.keyWidgetSentinelOk], isTrue);

      // One client, Direct, to the default explorer; every address once,
      // and the pending one's mempool list.
      expect(esplora.routes, [const DirectRoute()]);
      expect(
        esplora.keys,
        unorderedEquals([
          for (final a in watch.keys) a,
          '${_addr(0)}/txs/mempool',
        ]),
      );
      expect(esplora.requests.map((r) => r.host).toSet(), {'blockstream.info'});
      expect(esplora.maxInFlight, 4);

      expect(shown, [
        (
          id: sentinelNotifId(txid),
          title: '⚡ Incoming — Cold',
          body: '+₿0.0005 (unconfirmed)',
        ),
      ]);

      final state = await storedState();
      expect(state, isNotNull);
      expect(state!.counts.keys.toSet(), watch.keys.toSet());
      expect(state.counts[_addr(0)], (chain: 0, mempool: 1));
      final seen = await storedSeen();
      expect(seen, contains(txid));
      expect(
        SentinelSeenTx.fromJson(seen![txid] as Map<String, dynamic>).walletId,
        'w1',
      );

      final stamp = DateTime.parse((await lastScan())!);
      expect(
        stamp.isBefore(before.subtract(const Duration(seconds: 1))),
        isFalse,
      );

      // The task stays asked for: nothing cancelled, nothing re-asked.
      expect(foregroundCalls, isEmpty);
    });

    test('state is saved before alerts are shown: the seen records and the '
        'counts are stored when the alert goes out, the last-check stamp '
        'after it, and a second run alerts nothing again', () async {
      final watch = _watch(_cold, 2);
      seed(watch: watch);
      answerQuiet(watch.keys);
      final txid = answerPendingIn(_addr(1), 120000);
      final atShow =
          <
            ({
              Map<String, dynamic>? seen,
              IosSentinelState? state,
              String? lastScan,
            })
          >[];
      NotificationService.debugShow = (id, title, body) async {
        atShow.add((
          seen: await storedSeen(),
          state: await storedState(),
          lastScan: await lastScan(),
        ));
        shown.add((id: id, title: title, body: body));
      };

      expect(await runTask(), isTrue);

      expect(shown, hasLength(1));
      expect(atShow.single.seen, contains(txid));
      expect(atShow.single.state?.counts[_addr(1)], (chain: 0, mempool: 1));
      expect(atShow.single.lastScan, isNull, reason: 'stamped before showing');
      expect(await lastScan(), isNotNull);

      // iOS may end the engine right after the alert: the next run finds
      // the transaction in the seen records and shows nothing.
      esplora.requests.clear();
      expect(await runTask(), isTrue);
      expect(esplora.keys, contains('${_addr(1)}/txs/mempool'));
      expect(shown, hasLength(1), reason: 'alerted twice');
    });

    test('a malformed activity blob reads as empty and is overwritten '
        '(R10): a first sight records counts without alerting confirmed '
        'history', () async {
      for (final malformed in ['not json', '{"c":3,"i":"x"}', '[]']) {
        final watch = _watch(_cold, 2);
        seed(
          watch: watch,
          secure: {AppConstants.keySentinelIosActivity: malformed},
        );
        esplora.stats[_addr(0)] = _stats(40, 0);
        esplora.stats[_addr(1)] = _stats(3, 0);
        shown.clear();

        expect(await runTask(), isTrue, reason: malformed);

        expect(shown, isEmpty, reason: '$malformed: alerted history');
        final state = await storedState();
        expect(state?.counts, {
          _addr(0): (chain: 40, mempool: 0),
          _addr(1): (chain: 3, mempool: 0),
        }, reason: malformed);
        expect(await lastScan(), isNotNull, reason: malformed);
      }
    });

    test('an empty watch map (no wallets): no client, no request, nothing '
        'written', () async {
      seed();

      expect(await runTask(), isTrue);

      expect(esplora.routes, isEmpty);
      expect(esplora.requests, isEmpty);
      await expectNothingSaved();
      expect(cancels(), isEmpty);
    });

    test('an explorer that fails for every address seen before: nothing '
        'checked and nothing moved on, so nothing written or stamped (D7, '
        'R16)', () async {
      final watch = _watch(_cold, 3);
      final activity = jsonEncode(
        IosSentinelState(
          counts: {for (final a in watch.keys) a: (chain: 0, mempool: 0)},
          cursor: 0,
        ).toJson(),
      );
      seed(
        watch: watch,
        secure: {AppConstants.keySentinelIosActivity: activity},
      );
      esplora.failing.addAll(watch.keys);

      expect(await runTask(), isTrue);

      expect(esplora.keys, unorderedEquals(watch.keys));
      expect(
        await bio.readSecureValue(AppConstants.keySentinelIosActivity),
        activity,
      );
      expect(await storedSeen(), isNull);
      expect(await lastScan(), isNull);
      expect(shown, isEmpty);
    });
  });

  group('nothing answered, but the run moved on (R37)', () {
    test('never-seen addresses the explorer fails for are deferred: the '
        'activity blob alone is written, nothing else saved, shown or '
        'stamped, and the status reads paused', () async {
      final watch = _watch(_cold, 3);
      seed(watch: watch);
      esplora.failing.addAll(watch.keys);

      expect(await runTask(), isTrue);

      final state = await storedState();
      expect(state?.later, watch.keys.toSet());
      expect(state?.counts, isEmpty);
      expect(await storedSeen(), isNull);
      expect(await lastScan(), isNull);
      expect(shown, isEmpty);
      expect(widgetStore[AppConstants.keyWidgetSentinelOk], isFalse);
      expect(redraws(), 1);

      // The next run, the explorer back: they are checked in the rotation
      // and leave `later` with their baseline.
      esplora.failing.clear();
      answerQuiet(watch.keys);
      expect(await runTask(), isTrue);
      final next = await storedState();
      expect(next?.later, isEmpty);
      expect(next?.counts.keys.toSet(), watch.keys.toSet());
      expect(await lastScan(), isNotNull);
      expect(widgetStore[AppConstants.keyWidgetSentinelOk], isTrue);
    });

    test('addresses that hang at the cursor until the client is closed: the '
        'moved cursor is saved alone, and the next run starts past them',
        () async {
      final watch = _watch(_cold, 6);
      final counts = {for (final a in watch.keys) a: (chain: 0, mempool: 0)};
      fakeAsync((async) {
        seed(
          watch: watch,
          secure: {
            AppConstants.keySentinelIosActivity: jsonEncode(
              IosSentinelState(counts: counts, cursor: 0).toJson(),
            ),
          },
        );
        answerQuiet(watch.keys);
        // Direct: 4 at a time, all 4 in flight past the end of the run.
        for (var i = 0; i < 4; i++) {
          esplora.holds[_addr(i)] = Completer<void>();
        }
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 26));
        expect(result, isTrue);
        expect(esplora.keys, [_addr(0), _addr(1), _addr(2), _addr(3)]);
        esplora.releaseAll();
        async.elapse(const Duration(minutes: 1));
      });
      final state = await storedState();
      expect(state?.cursor, 4);
      expect(state?.counts, counts);
      expect(state?.later, isEmpty);
      expect(await storedSeen(), isNull);
      expect(await lastScan(), isNull);
      expect(widgetStore[AppConstants.keyWidgetSentinelOk], isFalse);

      esplora
        ..holds.clear()
        ..requests.clear();
      expect(await runTask(), isTrue);
      expect(esplora.keys.take(2), [_addr(4), _addr(5)]);
    });

    test('R38, over Tor: two pending addresses that answer but whose mempool '
        'lists hang every run are deferred, and run 2 reaches the rotation',
        () async {
      final watch = _watch(_cold, 6);
      final activity = jsonEncode(
        IosSentinelState(
          counts: {
            for (final a in watch.keys) a: (chain: 0, mempool: 0),
            _addr(0): (chain: 0, mempool: 1),
            _addr(1): (chain: 0, mempool: 1),
          },
          cursor: 0,
        ).toJson(),
      );

      /// One run over Tor, both mempool lists in flight past its end. The
      /// widget's chart is held too: the chart set's write chain is a static
      /// future, which must not be created inside a fake zone.
      List<String> run(Map<String, String> secure) {
        esplora
          ..requests.clear()
          ..holds.clear();
        late List<String> keys;
        fakeAsync((async) {
          widgetRequests.holds['/api/chart'] = Completer<void>();
          seed(
            prefs: const {AppConstants.keyUseTor: true},
            watch: watch,
            secure: secure,
          );
          answerQuiet(watch.keys);
          esplora
            ..stats[_addr(0)] = _stats(0, 1)
            ..stats[_addr(1)] = _stats(0, 1);
          for (final a in [_addr(0), _addr(1)]) {
            esplora.holds['$a/txs/mempool'] = Completer<void>();
          }
          Object? result;
          runTask().then((r) => result = r);
          async.elapse(const Duration(seconds: 26));
          expect(result, isTrue);
          keys = esplora.keys;
          esplora.releaseAll();
          widgetRequests.holds['/api/chart']!.complete();
          async.elapse(const Duration(seconds: 5));
        });
        return keys;
      }

      final run1 = run({AppConstants.keySentinelIosActivity: activity});
      expect(run1, [
        _addr(0),
        _addr(1),
        '${_addr(0)}/txs/mempool',
        '${_addr(1)}/txs/mempool',
      ], reason: 'both slots held to the end, nothing else started');
      final after1 = await storedState();
      expect(after1?.later, {_addr(0), _addr(1)});
      expect(after1?.counts[_addr(0)], (chain: 0, mempool: 1));

      final run2 = run({
        AppConstants.keySentinelIosActivity: jsonEncode(after1!.toJson()),
      });
      expect(run2.take(4), [_addr(2), _addr(3), _addr(4), _addr(5)]);
    });

    for (final (name, change) in <(String, Future<void> Function())>[
      (
        'Sentinel Lite is switched off',
        () async => (await SharedPreferences.getInstance()).setBool(
          AppConstants.keySentinelEnabled,
          false,
        ),
      ),
      (
        'a wallet is removed',
        () => bio.writeSecureBlob(
          AppConstants.keySentinelWatchMap,
          _watchJson(_watch(_cold, 3)),
        ),
      ),
    ]) {
      test('$name while nothing answered: no state is written', () async {
        final watch = {..._watch(_cold, 3), ..._watch(_spending, 1, from: 3)};
        seed(watch: watch);
        esplora.failing.addAll(watch.keys);
        for (final a in watch.keys) {
          esplora.holds[a] = Completer<void>();
        }

        final run = runTask();
        await _until(
          () => esplora.requests.length == 4,
          reason: 'four requests in flight',
        );
        await change();
        esplora.releaseAll();

        expect(await run, isTrue);
        await expectNothingSaved();
      });
    }
  });

  group('fail closed (D7)', () {
    for (final (name, prefs, secure, pro, sentinel)
        in <(String, Map<String, Object>, Map<String, String>, bool, bool)>[
          ('free user: no Sentinel request', const {}, const {}, false, true),
          ('Sentinel off', const {}, const {}, true, false),
          (
            'unreadable proxy settings',
            const {AppConstants.keyUseProxy: true},
            const {AppConstants.keyNetworkProxy: 'not json'},
            true,
            true,
          ),
        ]) {
      test('$name (Direct or no route): zero Esplora requests, nothing '
          'written, and the task is cancelled', () async {
        seed(
          prefs: prefs,
          secure: secure,
          watch: _watch(_cold, 3),
          pro: pro,
          sentinel: sentinel,
        );
        answerQuiet(_watch(_cold, 3).keys);

        expect(await runTask(), isTrue);

        expect(esplora.routes, isEmpty, reason: 'built an Esplora client');
        expect(esplora.requests, isEmpty);
        // No widget key but Sentinel Lite's status (R2): paused while it is
        // on, nothing while it is off and shows none (R33), one redraw.
        expect(widgetKeySaves(), isEmpty);
        if (sentinel) {
          expect(saves(), [AppConstants.keyWidgetSentinelOk]);
          expect(widgetStore[AppConstants.keyWidgetSentinelOk], isFalse);
          expect(redraws(), 1);
        } else {
          expect(saves(), isEmpty);
          expect(redraws(), 0);
        }
        await expectNothingSaved();
        expect(cancels(), [iosWidgetRefreshTaskId]);
        expect(schedules(), isEmpty);
      });
    }

    test('unreadable keychain: no request, nothing written, and the task '
        'stays asked for', () async {
      final watch = _watch(_cold, 3);
      seed(watch: watch);
      answerQuiet(watch.keys);
      FlutterSecureStorage.setMockInitialValues(_Keychain({}, all: true));

      expect(await runTask(), isTrue);

      expect(esplora.routes, isEmpty, reason: 'built an Esplora client');
      expect(esplora.requests, isEmpty);
      expect(shown, isEmpty);
      expect(await lastScan(), isNull);
      expect(widgetKeySaves(), isEmpty);
      expect(foregroundCalls, isEmpty);
    });

    for (final key in [
      AppConstants.keySentinelIosActivity,
      AppConstants.keySentinelSeenTxids,
      AppConstants.keySentinelWatchMap,
    ]) {
      test('a keychain read of $key that fails (R10: not "malformed"): no '
          'request, nothing written', () async {
        final watch = _watch(_cold, 2);
        final data = <String, String>{
          AppConstants.keyBtcAmount: '0.5',
          AppConstants.keySentinelWatchMap: _watchJson(watch),
        };
        seed(watch: watch);
        FlutterSecureStorage.setMockInitialValues(
          _Keychain(data, locked: {key}),
        );
        answerQuiet(watch.keys);

        expect(await runTask(), isTrue);

        expect(esplora.routes, isEmpty, reason: 'built an Esplora client');
        expect(esplora.requests, isEmpty);
        expect(shown, isEmpty);
        expect(await lastScan(), isNull);
        expect(data.keys.toSet(), {
          AppConstants.keyBtcAmount,
          AppConstants.keySentinelWatchMap,
        }, reason: 'wrote to the keychain');
      });
    }

    test('proxy down: the probe fails, so no Sentinel request and nothing '
        'written', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final watch = _watch(_cold, 2);
      seed(
        prefs: const {AppConstants.keyUseProxy: true},
        secure: {
          AppConstants.keyNetworkProxy: jsonEncode(
            ProxyConfig(
              type: ProxyType.socks5,
              host: '127.0.0.1',
              port: port,
            ).toJson(),
          ),
        },
        watch: watch,
      );
      answerQuiet(watch.keys);

      expect(await runTask(), isTrue);

      expect(esplora.routes, isEmpty, reason: 'built an Esplora client');
      expect(esplora.requests, isEmpty);
      expect(widgetKeySaves(), isEmpty);
      await expectNothingSaved();
      expect(cancels(), isEmpty, reason: 'a proxy down is not "unwanted"');
    });

    test('Tor not ready within 22 s: no Sentinel request; the widget only '
        'says its route is paused', () {
      fakeAsync((async) {
        final watch = _watch(_cold, 2);
        seed(prefs: const {AppConstants.keyUseTor: true}, watch: watch);
        answerQuiet(watch.keys);
        native.hold = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 23));
        expect(result, isTrue);
        expect(esplora.routes, isEmpty, reason: 'built an Esplora client');
        expect(esplora.requests, isEmpty);
        expect(widgetKeySaves(), ['widget_route_ok']);
        expect(widgetStore['widget_route_ok'], isFalse);
        // Sentinel Lite says it couldn't check, in the same redraw (R3).
        expect(widgetStore[AppConstants.keyWidgetSentinelOk], isFalse);
        expect(redraws(), 1);
        expect(shown, isEmpty);
      });
    });
  });

  group('a proxy and Tor', () {
    test('a proxy that answers its probe: the Sentinel part runs over it, 2 '
        'at a time, one attempt per request', () async {
      final proxy = await FakeSocks5Proxy.start(targetPort: 9);
      addTearDown(proxy.close);
      // A retry would come at once: one request per key proves there is none.
      EsploraClient.debugRetryDelayUnit = Duration.zero;
      final watch = _watch(_cold, 5);
      seed(
        prefs: const {AppConstants.keyUseProxy: true},
        secure: {
          AppConstants.keyNetworkProxy: jsonEncode(
            ProxyConfig(
              type: ProxyType.socks5,
              host: '127.0.0.1',
              port: proxy.port,
            ).toJson(),
          ),
        },
        watch: watch,
      );
      answerQuiet(watch.keys);
      esplora.failing.add(_addr(2));

      expect(await runTask(), isTrue);

      expect(esplora.routes, [isA<ProxyRoute>()]);
      expect(esplora.keys, unorderedEquals(watch.keys), reason: 'retried');
      expect(esplora.maxInFlight, 2);
      expect(widgetKeySaves(), isEmpty);
      final state = await storedState();
      expect(
        state?.counts.keys.toSet(),
        watch.keys.toSet().difference({_addr(2)}),
        reason: 'the failed address stays unseen',
      );
      expect(await lastScan(), isNotNull);
      expect(foregroundCalls, isEmpty);
    });

    test('Tor with Sentinel on: the widget part and the Sentinel part run '
        'through the same lease, the Sentinel part 2 at a time, one '
        'redraw, and the lease is given back', () async {
      final watch = _watch(_cold, 5);
      seed(prefs: const {AppConstants.keyUseTor: true}, watch: watch);
      answerQuiet(watch.keys);
      final txid = answerPendingIn(_addr(3), 7000);

      expect(await runTask(), isTrue);

      // The widget part, as without Sentinel.
      expect(widgetRequests.routes, [const TorRoute()]);
      expect(
        widgetRequests.paths,
        unorderedEquals(['/api/price', '/api/chart']),
      );
      expect(widgetStore['widget_route_ok'], isTrue);
      expect(redraws(), 1);

      // The Sentinel part, through the same client.
      expect(esplora.routes, [const TorRoute()]);
      expect(esplora.requests, isNotEmpty);
      for (final r in esplora.requests) {
        expect(r.tor, EmbeddedTorState.ready, reason: r.key);
        expect(r.port, native.socksPort, reason: r.key);
      }
      expect(esplora.maxInFlight, 2);
      expect(shown.single.id, sentinelNotifId(txid));
      expect(await storedSeen(), contains(txid));
      expect(await lastScan(), isNotNull);

      expect(native.startCalls, 1, reason: 'one client for both parts');
      expect(native.stopCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(registry.names, isEmpty);
    });

    test('Tor with Sentinel on, the deadline wins (the widget chart hangs): '
        'the Sentinel part is saved, the run is back at 25 s and the lease '
        'is given back', () async {
      fakeAsync((async) {
        final watch = _watch(_cold, 3);
        seed(prefs: const {AppConstants.keyUseTor: true}, watch: watch);
        answerQuiet(watch.keys);
        widgetRequests.holds['/api/chart'] = Completer<void>();
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 24, milliseconds: 900));
        expect(result, isNull);
        async.elapse(const Duration(milliseconds: 200));
        expect(result, isTrue);
        async.elapse(const Duration(seconds: 5));
        expect(native.startCalls, 1);
        expect(native.stopCalls, 1, reason: 'the lease was not given back');
        expect(EmbeddedTorService.state, EmbeddedTorState.off);
        expect(registry.names, isEmpty);
        widgetRequests.holds['/api/chart']!.complete();
        async.elapse(const Duration(seconds: 1));
      });
      expect(
        (await storedState())?.counts.keys.toSet(),
        _watch(_cold, 3).keys.toSet(),
      );
      expect(await lastScan(), isNotNull);
    });

    test('Tor with Sentinel on but no Pro: the widget part only', () async {
      final watch = _watch(_cold, 2);
      seed(
        prefs: const {AppConstants.keyUseTor: true},
        watch: watch,
        pro: false,
      );
      answerQuiet(watch.keys);

      expect(await runTask(), isTrue);

      expect(widgetRequests.paths, isNotEmpty);
      expect(esplora.routes, isEmpty);
      await expectNothingSaved();
      expect(foregroundCalls, isEmpty);
    });
  });

  group('a change during the run saves and shows nothing', () {
    // Prefs changes are read before each address (the route, Sentinel Lite,
    // Pro), so the check stops before its next one; a removed wallet is
    // found when the run would save, as Android's full scan re-reads the
    // wallets before writing its balances.
    for (final (name, change, stopsRequests)
        in <(String, Future<void> Function(), bool)>[
          (
            'the route changes (Direct → Tor)',
            () async => (await SharedPreferences.getInstance()).setBool(
              AppConstants.keyUseTor,
              true,
            ),
            true,
          ),
          (
            'Sentinel Lite is switched off',
            () async => (await SharedPreferences.getInstance()).setBool(
              AppConstants.keySentinelEnabled,
              false,
            ),
            true,
          ),
          (
            'Pro lapses',
            () async => (await SharedPreferences.getInstance()).remove(
              AppConstants.keyProUnlocked,
            ),
            true,
          ),
          (
            'a wallet is removed',
            () => bio.writeSecureBlob(
              AppConstants.keySentinelWatchMap,
              _watchJson(_watch(_cold, 3)),
            ),
            false,
          ),
        ]) {
      test(
        '$name: the pending payment it found is neither saved nor shown'
        '${stopsRequests ? ', and no further address is checked' : ''}',
        () async {
          final watch = {..._watch(_cold, 3), ..._watch(_spending, 3, from: 3)};
          seed(watch: watch);
          answerQuiet(watch.keys);
          answerPendingIn(_addr(3), 9000);
          for (final key in [
            _addr(0),
            _addr(1),
            _addr(2),
            _addr(3),
            '${_addr(3)}/txs/mempool',
          ]) {
            esplora.holds[key] = Completer<void>();
          }

          final run = runTask();
          await _until(
            () => esplora.requests.length == 4,
            reason: 'four requests in flight',
          );
          await change();
          // The address under way finishes its own requests: its pending
          // payment is found after the change.
          esplora.holds[_addr(3)]!.complete();
          await _until(
            () => esplora.keys.contains('${_addr(3)}/txs/mempool'),
            reason: 'the pending address fetched its mempool list',
          );
          esplora.releaseAll();

          expect(await run, isTrue);
          if (stopsRequests) {
            expect(
              esplora.keys,
              isNot(anyOf(contains(_addr(4)), contains(_addr(5)))),
              reason: 'an address checked after the change',
            );
          }
          await expectNothingSaved();

          if (!stopsRequests) return;
          // Put back: the next run finds what this one dropped.
          seed(watch: watch);
          esplora.holds.clear();
          expect(await runTask(), isTrue);
          expect(shown, hasLength(1));
          expect(shown.single.title, '⚡ Incoming — Spending');
        },
      );
    }
  });

  group('the deadline', () {
    test('a hanging explorer: no request starts after deadline − 4 s; at '
        'deadline − 1 s the client is closed, the addresses still in flight '
        'keep their old counts, what was found is saved, and the run is back '
        'before 25 s', () async {
      fakeAsync((async) {
        final watch = _watch(_cold, 6);
        seed(watch: watch);
        answerQuiet(watch.keys);
        answerPendingIn(_addr(5), 1000);
        for (final a in watch.keys) {
          esplora.holds[a] = Completer<void>();
        }
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 1));
        expect(esplora.keys, [_addr(0), _addr(1), _addr(2), _addr(3)]);

        // Before the request cut-off (deadline − 4 s = 21 s) an answer frees
        // a worker, which starts the next address…
        async.elapse(const Duration(seconds: 19, milliseconds: 500));
        esplora.holds[_addr(0)]!.complete();
        async.elapse(const Duration(milliseconds: 100));
        expect(esplora.keys.last, _addr(4), reason: 'stopped before 21 s');

        // …and past it, nothing more.
        async.elapse(const Duration(seconds: 1));
        esplora.holds[_addr(1)]!.complete();
        async.elapse(const Duration(milliseconds: 100));
        expect(esplora.requests, hasLength(5), reason: 'started past 21 s');

        // The save cut-off (deadline − 1 s = 24 s): the three still hanging
        // are abandoned, and the two that answered are saved.
        // 21.7 s now.
        async.elapse(const Duration(seconds: 2, milliseconds: 200));
        expect(result, isNull, reason: 'back before the save cut-off');
        async.elapse(const Duration(milliseconds: 400));
        expect(result, isTrue, reason: 'still waiting after the save cut-off');

        // Answers after it go nowhere.
        esplora.releaseAll();
        async.elapse(const Duration(minutes: 1));
        expect(esplora.keys, isNot(contains(_addr(5))));
      });
      final state = await storedState();
      expect(state?.counts, {
        _addr(0): (chain: 0, mempool: 0),
        _addr(1): (chain: 0, mempool: 0),
      }, reason: 'an abandoned address keeps its (absent) counts');
      expect(await lastScan(), isNotNull);
      expect(shown, isEmpty);
    });

    test('one address that never answers does not hide another\'s pending '
        'payment: it is saved and shown before 25 s (R19)', () async {
      fakeAsync((async) {
        final watch = _watch(_cold, 2);
        seed(watch: watch);
        answerQuiet(watch.keys);
        answerPendingIn(_addr(1), 64000);
        esplora.holds[_addr(0)] = Completer<void>(); // never answers
        Object? result;
        runTask().then((r) => result = r);

        async.elapse(const Duration(seconds: 23, milliseconds: 900));
        expect(result, isNull);
        expect(shown, isEmpty, reason: 'shown before the check ended');
        async.elapse(const Duration(milliseconds: 400));
        expect(result, isTrue, reason: 'not back before 25 s');
        expect(shown, hasLength(1));
        expect(shown.single.title, '⚡ Incoming — Cold');
      });
      expect(await storedSeen(), contains(_txid(0x1001)));
      final state = await storedState();
      expect(state?.counts.keys, [
        _addr(1),
      ], reason: 'the hung one stays unseen');
      expect(await lastScan(), isNotNull);
    });

    for (final answerAt in const [
      Duration(seconds: 22),
      Duration(seconds: 23, milliseconds: 800),
      Duration(seconds: 23, milliseconds: 990),
      Duration(seconds: 24, milliseconds: 10),
    ]) {
      final early = answerAt < const Duration(seconds: 24);
      test('keychain writes of 100 ms, the last answer at $answerAt: '
          '${early ? 'all saved and shown' : 'the payment is left for next run'}'
          ', never half', () async {
        final data = <String, String>{};
        fakeAsync((async) {
          final watch = _watch(_cold, 2);
          seed(watch: watch);
          data.addAll({
            AppConstants.keyBtcAmount: '0.5',
            AppConstants.keySentinelWatchMap: _watchJson(watch),
          });
          FlutterSecureStoragePlatform.instance = _SlowWrites(data);
          answerQuiet(watch.keys);
          answerPendingIn(_addr(1), 5000);
          // The other address keeps the check going until the save cut-off.
          esplora.holds[_addr(0)] = Completer<void>();
          esplora.holds['${_addr(1)}/txs/mempool'] = Completer<void>();
          Object? result;
          runTask().then((r) => result = r);

          async.elapse(answerAt);
          esplora.holds['${_addr(1)}/txs/mempool']!.complete();
          async.elapse(const Duration(seconds: 25) - answerAt);
          expect(result, isTrue);
          async.elapse(const Duration(minutes: 1));
        });
        final seen = data[AppConstants.keySentinelSeenTxids] ?? '{}';
        final saved = seen.contains(_txid(0x1001));
        expect(shown.isNotEmpty, saved, reason: 'shown without saved, or not');
        expect(saved, early);
        if (early) {
          expect(data, contains(AppConstants.keySentinelIosActivity));
          expect(await lastScan(), isNotNull);
        }
      });
    }

    test('a hanging explorer, end to end: the client is closed at the save '
        'cut-off (debugIosTaskBudget 5 s, so at 4 s), dropping its '
        'connection, and nothing is written', () async {
      final silent = await SilentServer.start();
      addTearDown(silent.close);
      WidgetService.debugIosTaskBudget = const Duration(seconds: 5);
      EsploraClient.debugInterceptDio = null;
      final watch = _watch(_cold, 1);
      // Seen before, so it is in the rotation: its failure moves nothing on
      // and nothing is saved. (A never-seen one would be deferred and its
      // state saved alone, R37; the fakeAsync tests above pin that.)
      final activity = jsonEncode(
        IosSentinelState(
          counts: {_addr(0): (chain: 0, mempool: 0)},
          cursor: 0,
        ).toJson(),
      );
      seed(
        prefs: const {
          AppConstants.keyExplorerPreset: 2, // custom
        },
        secure: {
          AppConstants.keyExplorerCustomUrl: 'http://127.0.0.1:${silent.port}',
          AppConstants.keySentinelIosActivity: activity,
        },
        watch: watch,
      );
      final watchStart = Stopwatch()..start();

      expect(await runTask(), isTrue);

      expect(watchStart.elapsed, lessThan(const Duration(seconds: 5)));
      expect(
        watchStart.elapsed,
        greaterThan(const Duration(milliseconds: 3500)),
      );
      await silent.clientClosed.timeout(
        const Duration(seconds: 1),
        onTimeout: () => fail('the connection outlived the save cut-off'),
      );
      expect(
        await bio.readSecureValue(AppConstants.keySentinelIosActivity),
        activity,
      );
      expect(await storedSeen(), isNull);
      expect(await lastScan(), isNull);
      expect(shown, isEmpty);
    });

    test('a run shorter than the margin (debugIosTaskBudget 2 s) starts no '
        'Sentinel request: back within 3 s, nothing written', () async {
      WidgetService.debugIosTaskBudget = const Duration(seconds: 2);
      final watch = _watch(_cold, 3);
      seed(watch: watch);
      for (final a in watch.keys) {
        esplora.holds[a] = Completer<void>();
      }
      final watchStart = Stopwatch()..start();

      expect(await runTask(), isTrue);

      expect(watchStart.elapsed, lessThan(const Duration(seconds: 3)));
      expect(esplora.requests, isEmpty);
      await expectNothingSaved();
    });
  });

  group('scheduling', () {
    test('a launch on Direct with Sentinel Lite on and Pro asks for the '
        'task, not before 15 min from now', () async {
      seed();

      await WidgetService.scheduleRefresh();

      final periodic = foregroundCalls.singleWhere(
        (c) => c.method == 'registerPeriodicTask',
      );
      final args = periodic.arguments as Map;
      expect(args['uniqueName'], iosWidgetRefreshTaskId);
      expect(args['initialDelaySeconds'], 15 * 60);
      expect(cancels(), isEmpty);
    });

    for (final (name, prefs, secure, pro, wanted)
        in <(String, Map<String, Object>, Map<String, String>, bool, bool)>[
          (
            'a proxy',
            const {AppConstants.keyUseProxy: true},
            {
              AppConstants.keyNetworkProxy: jsonEncode(
                const ProxyConfig(
                  type: ProxyType.socks5,
                  host: '127.0.0.1',
                  port: 9999,
                ).toJson(),
              ),
            },
            true,
            true,
          ),
          (
            'unreadable proxy settings',
            const {AppConstants.keyUseProxy: true},
            const {},
            true,
            false,
          ),
          ('Direct without Pro', const {}, const {}, false, false),
        ]) {
      test('a launch on $name with Sentinel Lite on: '
          '${wanted ? 'asked for' : 'cancelled'}', () async {
        seed(prefs: prefs, secure: secure, pro: pro);

        await WidgetService.iosBackgroundFollows();

        if (wanted) {
          expect(schedules(), [iosWidgetRefreshTaskId]);
          expect(cancels(), isEmpty);
        } else {
          expect(schedules(), isEmpty);
          expect(cancels(), [iosWidgetRefreshTaskId]);
        }
      });
    }

    test('a route change follows Sentinel Lite too: to Direct keeps the '
        'task, to unreadable proxy settings cancels it', () async {
      seed();

      await WidgetService.backgroundRefreshFollows(const DirectRoute());
      expect(schedules(), [iosWidgetRefreshTaskId]);
      expect(cancels(), isEmpty);

      await WidgetService.backgroundRefreshFollows(
        const MisconfiguredProxyRoute(),
      );
      expect(cancels(), [iosWidgetRefreshTaskId]);
    });

    test('a doubtful read with Sentinel Lite on changes nothing (M-a): no '
        'onboarding_complete, or a read past 3 s', () async {
      seed(onboarded: false);

      await WidgetService.scheduleRefresh();
      await WidgetService.iosBackgroundFollows();
      expect(await runTask(), isTrue);

      expect(foregroundCalls, isEmpty);
      expect(esplora.requests, isEmpty);
      await expectNothingSaved();

      fakeAsync((async) {
        seed();
        WidgetService.debugIosRoutePrefs = () =>
            Completer<SharedPreferences>().future;
        var done = false;
        WidgetService.iosBackgroundFollows().then((_) => done = true);
        async.elapse(const Duration(seconds: 3, milliseconds: 100));
        expect(done, isTrue);
        expect(foregroundCalls, isEmpty);
      });
    });

    test('R20: a wrong-typed sentinel_enabled or pro_unlocked reads as off, '
        'not as a doubtful read', () async {
      seed(
        prefs: const {
          AppConstants.keyUseTor: true,
          AppConstants.keySentinelEnabled: 'yes',
        },
        sentinel: false,
      );
      await WidgetService.scheduleRefresh();
      expect(schedules(), [iosWidgetRefreshTaskId], reason: 'Tor');

      foregroundCalls.clear();
      seed(prefs: const {AppConstants.keyProUnlocked: 1}, pro: false);
      await WidgetService.scheduleRefresh();
      expect(cancels(), [iosWidgetRefreshTaskId], reason: 'Direct, no Pro');
    });

    test('R20: a route change reads the app\'s own prefs, not the background '
        'route read (no reload, no seam)', () async {
      seed();
      WidgetService.debugIosRoutePrefs = () =>
          Completer<SharedPreferences>().future;
      final watchStart = Stopwatch()..start();

      await WidgetService.backgroundRefreshFollows(const DirectRoute());

      expect(watchStart.elapsed, lessThan(const Duration(seconds: 1)));
      expect(schedules(), [iosWidgetRefreshTaskId]);
    });

    test('a run that wants neither part cancels the task; one that wants the '
        'Sentinel part leaves it', () async {
      seed(pro: false);
      expect(await runTask(), isTrue);
      expect(cancels(), [iosWidgetRefreshTaskId]);

      foregroundCalls.clear();
      seed(watch: _watch(_cold, 1));
      answerQuiet(_watch(_cold, 1).keys);
      expect(await runTask(), isTrue);
      expect(foregroundCalls, isEmpty);
    });
  });

  group('NotificationService.showSentinelAlert', () {
    test('title and body from sentinelAlertCopy, id from the alert', () async {
      const alert = SentinelAlert(
        kind: SentinelAlertKind.pendingOut,
        walletLabel: 'Cold',
        sats: 250000,
        notifId: 4242,
      );

      await NotificationService.showSentinelAlert(alert);

      final copy = sentinelAlertCopy(alert);
      expect(shown, [(id: 4242, title: copy.title, body: copy.body)]);
    });
  });
}
