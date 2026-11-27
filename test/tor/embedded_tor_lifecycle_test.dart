/// The embedded Tor client follows the selected route and the app
/// lifecycle, and is the source of `routeStatusProvider` on `TorRoute`
/// (ruling R2). Built in on both platforms: the whole suite runs twice, with
/// `TorService.debugIsIOS` true (iOS) and false (Android).
///
/// - Turning Tor on starts it, switching to Direct or a proxy stops it, inside
///   `NetworkSettingsNotifier`'s serial chain.
/// - Paused → dormant, resumed → awake, or restarted when the circuit was lost
///   while suspended; requests in between are refused.
/// - starting → checking, ready → available, failed/off → unavailable. The
///   transition to ready forces exactly one price refresh, and a request the
///   price gate blocks while Tor bootstraps can't turn "checking" into
///   "unavailable".
/// - Switching Tor off while it bootstraps: no late ready (Review Focus 5).
library;

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/app.dart';
import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/mock/mock_data.dart';
import 'package:bag/mock/mock_providers.dart';
import 'package:bag/mock/scenes.dart';
import 'package:bag/models/dca_entry.dart';
import 'package:bag/models/fee_estimate.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/price_data.dart';
import 'package:bag/models/wallet_entry.dart';
import 'package:bag/providers/dca_provider.dart';
import 'package:bag/providers/fee_provider.dart';
import 'package:bag/providers/home_refresh_provider.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/portfolio_provider.dart';
import 'package:bag/providers/price_provider.dart';
import 'package:bag/providers/route_status_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/providers/wallets_provider.dart';
import 'package:bag/services/embedded_tor_service.dart';
import 'package:bag/services/tor_host.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/services/network/routed_http.dart';
import 'package:bag/services/price_service.dart';
import 'package:bag/services/tor_service.dart';

import '../network/fake_proxies.dart';

const _proxy = ProxyConfig(
  type: ProxyType.socks5,
  host: '10.0.0.5',
  port: 1080,
);

/// A scriptable embedded Tor client.
class _LifecycleBackend implements EmbeddedTorBackend {
  /// The port reported while bootstrapped.
  int socksPort = 47123;

  int startCalls = 0;
  int stopCalls = 0;
  final List<bool> dormantCalls = [];

  /// Backend calls in order, to pin "stop before the next start".
  final List<String> calls = [];

  /// Like [calls], plus `start-returned` when a native start finishes, so a
  /// test can tell a start issued while another was still running.
  final List<String> log = [];

  /// When set, the next `start()` waits on it (and clears it), holding the
  /// state at `starting`. Like the plugin, a `stop()` meanwhile cancels that
  /// start: it returns at once (`start-cancelled`) without a circuit.
  Completer<void>? hold;

  Completer<void>? _held;
  bool _cancelled = false;

  /// When true, the next `start()` throws (once).
  bool failNextStart = false;
  bool _bootstrapped = false;
  final _failures = StreamController<Object>.broadcast();
  final _events = StreamController<int>.broadcast();

  /// The OS tore the circuit down while the app was suspended. Unlike a
  /// crash, nothing is reported: the client just isn't bootstrapped any more.
  void loseCircuit() => _bootstrapped = false;

  /// The plugin's SOCKS proxy exited on its own.
  void dieOnItsOwn() {
    _bootstrapped = false;
    _failures.add('proxy exited');
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
    calls.add('start');
    log.add('start');
    if (failNextStart) {
      failNextStart = false;
      throw StateError('bootstrap failed');
    }
    final pending = _held = hold;
    hold = null;
    _cancelled = false;
    if (pending != null) await pending.future;
    _held = null;
    if (_cancelled) {
      log.add('start-cancelled');
      return;
    }
    _bootstrapped = true;
    log.add('start-returned');
  }

  @override
  Future<void> bootstrap() async => calls.add('bootstrap');

  @override
  Future<void> setDormant(bool dormant) async {
    calls.add('dormant:$dormant');
    dormantCalls.add(dormant);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    calls.add('stop');
    log.add('stop');
    _bootstrapped = false;
    final held = _held;
    if (held != null && !held.isCompleted) {
      _cancelled = true;
      held.complete();
    }
  }
}

/// Counts forced refreshes — the call the home "Re-check" makes.
class _RecordingPriceNotifier extends PriceNotifier {
  static int forced = 0;

  @override
  Future<PriceData> build() async => mockPriceData;

  @override
  Future<void> refresh({bool force = false}) async {
    if (force) forced++;
  }
}

/// Records what the ready transition asks of the chart layer (I2).
class _CountingPriceService extends PriceService {
  _CountingPriceService() : super(route: const TorRoute());

  final bulkCharts = <String>[];
  final chartReads = <int>[];

  @override
  Future<void> fetchAllCharts(String currency) async => bulkCharts.add(currency);

  @override
  Future<List<(DateTime, double)>> fetchChartData(
    String currency,
    int days, {
    void Function()? onRefreshed,
  }) async {
    chartReads.add(days);
    return const [];
  }
}

/// Records each `scanAllIfStale` call and whether it included the wallets
/// the route refused.
class _RecordingWallets extends WalletsNotifier {
  static final calls = <bool>[];

  @override
  List<WalletEntry> build() => const [];

  @override
  Future<void> scanAllIfStale({bool includeRouteBlocked = false}) async =>
      calls.add(includeRouteBlocked);
}

/// Counts fee builds: the first, and one per refresh.
class _CountingFee extends FeeNotifier {
  static int builds = 0;

  @override
  Future<FeeEstimate?> build() async {
    builds++;
    return null;
  }
}

class _EmptyDcaNotifier extends DcaNotifier {
  @override
  List<DcaEntry> build() => [];
}

/// What [PriceService] reports when its route gate trips and a cached price
/// exists: the cached data, and `lastRequestBlockedByRoute`.
class _BlockedPriceService extends PriceService {
  _BlockedPriceService(NetworkRoute route) : super(route: route);

  @override
  bool get lastRequestBlockedByRoute => true;

  @override
  PriceData? getCachedPrice() => null;

  @override
  Future<PriceData> fetchCurrentPrice(List<String> currencies) async =>
      mockPriceData;

  @override
  Future<void> prewarmCharts(String currency) async {}

  @override
  Future<List<(DateTime, double)>> fetchChartData(
    String currency,
    int days, {
    void Function()? onRefreshed,
  }) async => const [];
}

/// testWidgets replaces every HttpClient with one that answers 400; the base
/// [HttpOverrides] builds real ones again.
class _RealHttp extends HttpOverrides {}

/// GETs `http://bag-test.invalid:<port>/` over Tor, with a real client.
Future<int> _get(int port) =>
    HttpOverrides.runWithHttpOverrides(() => _getOnce(port), _RealHttp());

Future<int> _getOnce(int port) async {
  final c = routeHttpClient(HttpClient(), const TorRoute());
  try {
    final request = await c.getUrl(Uri.parse('http://bag-test.invalid:$port/'));
    request.persistentConnection = false;
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    c.close(force: true);
  }
}

void main() {
  for (final ios in [true, false]) {
    group(ios ? 'iOS' : 'Android', () => _suite(ios: ios));
  }
}

void _suite({required bool ios}) {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _LifecycleBackend backend;
  late List<EmbeddedTorState> emitted;
  late StreamSubscription<EmbeddedTorState> emittedSub;

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('home_widget'),
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/local_auth'),
      (call) async =>
          call.method == 'isDeviceSupported' || call.method == 'isAvailable'
          ? true
          : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('app.bitbag/widget'),
      (call) async => call.method == 'getSdkVersion' ? 31 : null,
    );
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    backend = _LifecycleBackend();
    EmbeddedTorService.debugBackend = backend;
    TorService.debugIsIOS = ios;
    // The UI isolate with Tor selected: TorHost starts nothing with neither
    // a route nor a route check (N-f).
    TorHost.routeChanged(tor: true);
    RouteGate.invalidateCache();
    _RecordingPriceNotifier.forced = 0;
    _RecordingWallets.calls.clear();
    _CountingFee.builds = 0;
    emitted = [];
    emittedSub = EmbeddedTorService.changes.listen(emitted.add);
  });

  tearDown(() async {
    await emittedSub.cancel();
    await EmbeddedTorService.stop();
    // A start a failed case left held can't stall the next case.
    EmbeddedTorService.debugReset();
    EmbeddedTorService.debugBackend = null;
    TorService.debugIsIOS = null;
    RouteGate.debugProbeOverride = null;
    RouteGate.invalidateCache();
  });

  /// A container over mock prefs, with `routeStatusProvider` kept alive the
  /// way the home screen keeps it alive.
  Future<ProviderContainer> container({
    bool useTor = false,
    ProxyConfig? proxy,
    bool recordRefreshes = true,
    List<Override> overrides = const [],
  }) async {
    SharedPreferences.setMockInitialValues({
      if (useTor) AppConstants.keyUseTor: true,
    });
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        initialProxyConfigProvider.overrideWithValue(proxy),
        if (recordRefreshes)
          priceProvider.overrideWith(_RecordingPriceNotifier.new),
        ...overrides,
      ],
    );
    addTearDown(c.dispose);
    c.listen(routeStatusProvider, (_, _) {});
    return c;
  }

  RouteStatus? status(ProviderContainer c) =>
      c.read(routeStatusProvider).valueOrNull;

  group('the route drives the client', () {
    test('turning Tor on starts it, without waiting for the bootstrap; the '
        'status goes checking → available', () async {
      final c = await container();
      final hold = backend.hold = Completer<void>();

      await c.read(networkSettingsProvider.notifier).setUseTor(true);
      await pumpEventQueue();

      // The setter returned while Tor is still bootstrapping.
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(backend.startCalls, 1);
      expect(status(c), RouteStatus.checking);

      hold.complete();
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(status(c), RouteStatus.available);
    });

    test('switching to Direct stops it', () async {
      final c = await container();
      final settings = c.read(networkSettingsProvider.notifier);
      await settings.setUseTor(true);
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);

      await settings.setUseTor(false);
      // Issued inside the chain: off by the time the setter returns.
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(backend.stopCalls, 1);
      await pumpEventQueue();
      expect(c.read(networkSettingsProvider).route, const DirectRoute());
      expect(status(c), RouteStatus.available);
    });

    test('switching to a proxy stops it', () async {
      RouteGate.debugProbeOverride = (route) async => RouteStatus.available;
      final c = await container(proxy: _proxy);
      final settings = c.read(networkSettingsProvider.notifier);
      await settings.setUseTor(true);
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);

      await settings.setUseProxy(true);
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(backend.stopCalls, 1);
      expect(c.read(networkSettingsProvider).route, const ProxyRoute(_proxy));
    });

    test('a setter that keeps TorRoute leaves a ready client alone', () async {
      final c = await container(proxy: _proxy);
      final settings = c.read(networkSettingsProvider.notifier);
      await settings.setUseTor(true);
      await pumpEventQueue();

      // Route stays TorRoute: Tor wins over the (off) proxy.
      await settings.clearProxy();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(backend.startCalls, 1);
      expect(backend.stopCalls, 0);
    });

    test('Tor switched off while bootstrapping: no late ready reaches '
        'routeStatusProvider (Review Focus 5)', () async {
      // A proxy that is down, so a late "available" would be visible.
      RouteGate.debugProbeOverride = (route) async => RouteStatus.unavailable;
      final c = await container(proxy: _proxy);
      final settings = c.read(networkSettingsProvider.notifier);
      final hold = backend.hold = Completer<void>();
      final seen = <RouteStatus?>[];
      c.listen(routeStatusProvider, (_, next) => seen.add(next.valueOrNull));

      await settings.setUseTor(true);
      await pumpEventQueue();
      expect(status(c), RouteStatus.checking);
      seen.clear();

      // The setter doesn't wait for the stop (R7), and the native stop goes
      // out at once (I3): it cancels the native start still running, as the
      // plugin's stop does. The state is off at once.
      final toProxy = settings.setUseProxy(true);
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(backend.log, ['start', 'stop', 'start-cancelled']);

      await toProxy;
      await pumpEventQueue();
      expect(hold.isCompleted, isTrue);
      expect(status(c), RouteStatus.unavailable);

      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(EmbeddedTorService.port, -1);
      // The cancelled start brought nothing up, and needs no second stop.
      expect(backend.log, ['start', 'stop', 'start-cancelled']);
      expect(backend.bootstrapped, isFalse);
      expect(emitted, isNot(contains(EmbeddedTorState.ready)));
      expect(status(c), RouteStatus.unavailable);
      expect(seen, isNot(contains(RouteStatus.available)));
      expect(_RecordingPriceNotifier.forced, 0);
    });

    test('Tor → Direct → Tor in quick succession: the stop goes out at '
        'once and cancels the first start, one native start at a time, and '
        'the abandoned start never publishes', () async {
      final c = await container();
      final settings = c.read(networkSettingsProvider.notifier);
      backend.hold = Completer<void>();

      // Not awaited one by one: three taps in a row.
      final taps = [
        settings.setUseTor(true),
        settings.setUseTor(false),
        settings.setUseTor(true),
      ];
      await Future.wait(taps);
      await pumpEventQueue();

      // The second start began only after the first had returned.
      expect(backend.log, [
        'start',
        'stop',
        'start-cancelled',
        'start',
        'start-returned',
      ]);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(backend.bootstrapped, isTrue);
      expect(emitted.where((s) => s == EmbeddedTorState.ready), hasLength(1));
      expect(_RecordingPriceNotifier.forced, 1);
      expect(status(c), RouteStatus.available);
    });
  });

  group('routeStatusProvider follows the client (R2)', () {
    test('starting → checking, ready → available, failed → unavailable, '
        'off → unavailable', () async {
      final c = await container(useTor: true);
      expect(status(c), RouteStatus.unavailable); // off

      final hold = backend.hold = Completer<void>();
      final start = EmbeddedTorService.ensureStarted();
      await pumpEventQueue();
      expect(status(c), RouteStatus.checking);

      hold.complete();
      await start;
      await pumpEventQueue();
      expect(status(c), RouteStatus.available);

      // The automatic retry (M2) fails, so failed is what stays.
      backend.failNextStart = true;
      backend.dieOnItsOwn();
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(status(c), RouteStatus.unavailable);
    });

    test('the ready transition forces exactly one price refresh', () async {
      final c = await container(useTor: true);
      await EmbeddedTorService.ensureStarted();
      await pumpEventQueue();
      expect(status(c), RouteStatus.available);
      expect(_RecordingPriceNotifier.forced, 1);

      // Nothing that keeps it ready refreshes again.
      await EmbeddedTorService.ensureStarted();
      await EmbeddedTorService.onPause();
      await EmbeddedTorService.onResume();
      await c.read(routeStatusProvider.notifier).recheck();
      await c.read(priceProvider.notifier).refresh(force: true);
      await pumpEventQueue();
      expect(_RecordingPriceNotifier.forced, 2); // 1 + the explicit one above

      // A new transition (crash, then restart) refreshes once more.
      backend.dieOnItsOwn();
      await pumpEventQueue();
      await EmbeddedTorService.ensureStarted();
      await pumpEventQueue();
      expect(_RecordingPriceNotifier.forced, 3);
    });

    test('the ready transition refreshes what Tor blocked — price, bulk '
        'charts, the chart on screen, wallet scans (route-blocked included) '
        'and the fee estimate — each exactly once (I2)', () async {
      final prices = _CountingPriceService();
      final c = await container(
        useTor: true,
        overrides: [
          priceServiceProvider.overrideWithValue(prices),
          walletsProvider.overrideWith(_RecordingWallets.new),
          feeProvider.overrideWith(_CountingFee.new),
        ],
      );
      final currency = c.read(portfolioProvider).selectedCurrencies.first;
      // What the home screen keeps alive.
      c.listen(feeProvider, (_, _) {});
      c.listen(chartDataProvider((currency, 7)), (_, _) {});

      final hold = backend.hold = Completer<void>();
      unawaited(EmbeddedTorService.ensureStarted());
      await pumpEventQueue();
      // While connecting, the chart and the fee poll ran (and the route
      // refused them); nothing was refreshed yet.
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(prices.chartReads, [7]);
      expect(_CountingFee.builds, 1);
      expect(_RecordingWallets.calls, isEmpty);
      expect(prices.bulkCharts, isEmpty);
      expect(_RecordingPriceNotifier.forced, 0);

      hold.complete();
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(_RecordingPriceNotifier.forced, 1);
      expect(prices.bulkCharts, [currency]);
      // Every timeframe is re-read from the cache, the one on screen too —
      // exactly what pull-to-refresh does.
      expect(prices.chartReads.first, 7);
      expect(
        prices.chartReads.skip(1),
        unorderedEquals(HomeRefresh.chartTimeframeDays),
      );
      expect(_RecordingWallets.calls, [true]);
      expect(_CountingFee.builds, 2);
      final reads = prices.chartReads.length;

      // Nothing that keeps it ready refreshes again.
      await EmbeddedTorService.ensureStarted();
      await c.read(routeStatusProvider.notifier).recheck();
      await EmbeddedTorService.onPause();
      await EmbeddedTorService.onResume();
      await pumpEventQueue();
      expect(_RecordingPriceNotifier.forced, 1);
      expect(prices.bulkCharts, [currency]);
      expect(prices.chartReads, hasLength(reads));
      expect(_RecordingWallets.calls, [true]);
      expect(_CountingFee.builds, 2);
    });

    test('the ready transition leaves an unwatched fee estimate alone '
        '(I2)', () async {
      final c = await container(
        useTor: true,
        overrides: [
          priceServiceProvider.overrideWithValue(_CountingPriceService()),
          walletsProvider.overrideWith(_RecordingWallets.new),
          feeProvider.overrideWith(_CountingFee.new),
        ],
      );
      await EmbeddedTorService.ensureStarted();
      await pumpEventQueue();
      expect(_RecordingWallets.calls, [true]);
      expect(c.exists(feeProvider), isFalse);
      expect(_CountingFee.builds, 0);
    });

    test('a rebuild before the deferred refresh runs does not lose it '
        '(M4)', () async {
      SharedPreferences.setMockInitialValues({AppConstants.keyUseTor: true});
      final prefs = await SharedPreferences.getInstance();
      await EmbeddedTorService.ensureStarted();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          priceProvider.overrideWith(_RecordingPriceNotifier.new),
        ],
      );
      addTearDown(c.dispose);

      // Build 1 finds Tor ready and defers the refresh; build 2 replaces it
      // before that microtask runs.
      c.listen(routeStatusProvider, (_, _) {});
      c.invalidate(routeStatusProvider);
      c.read(routeStatusProvider);
      await pumpEventQueue();

      expect(_RecordingPriceNotifier.forced, 1);
      expect(status(c), RouteStatus.available);
    });

    test('the forced refresh itself cannot re-trigger one (real '
        'PriceNotifier)', () async {
      final c = await container(
        useTor: true,
        recordRefreshes: false,
        overrides: [
          dcaProvider.overrideWith(_EmptyDcaNotifier.new),
          priceServiceProvider.overrideWith(
            (ref) => _BlockedPriceService(const TorRoute()),
          ),
        ],
      );
      await c.read(priceProvider.future);
      await EmbeddedTorService.ensureStarted();
      await pumpEventQueue();
      await pumpEventQueue();

      expect(emitted.where((s) => s == EmbeddedTorState.ready), hasLength(1));
      expect(backend.startCalls, 1);
      expect(status(c), RouteStatus.available);
    });

    test('a price request blocked while Tor bootstraps leaves the status at '
        'checking', () async {
      final c = await container(
        useTor: true,
        recordRefreshes: false,
        overrides: [
          dcaProvider.overrideWith(_EmptyDcaNotifier.new),
          priceServiceProvider.overrideWith(
            (ref) => _BlockedPriceService(const TorRoute()),
          ),
        ],
      );
      final hold = backend.hold = Completer<void>();
      unawaited(EmbeddedTorService.ensureStarted());
      await pumpEventQueue();
      expect(status(c), RouteStatus.checking);

      // The build fetch and a forced refresh both hit the tripped gate.
      await c.read(priceProvider.future);
      await c.read(priceProvider.notifier).refresh(force: true);
      await pumpEventQueue();

      expect(status(c), RouteStatus.checking);
      hold.complete();
    });

    test(
      'off Tor (a proxy) the price layer still mirrors a blocked request',
      () async {
        RouteGate.debugProbeOverride = (route) async => RouteStatus.available;
        final c = await container(
          proxy: _proxy,
          recordRefreshes: false,
          overrides: [
            dcaProvider.overrideWith(_EmptyDcaNotifier.new),
            priceServiceProvider.overrideWith(
              (ref) => _BlockedPriceService(const ProxyRoute(_proxy)),
            ),
          ],
        );
        await c.read(networkSettingsProvider.notifier).setUseProxy(true);
        await c.read(routeStatusProvider.future);
        expect(status(c), RouteStatus.available);

        await c.read(priceProvider.future);
        expect(status(c), RouteStatus.unavailable);
      },
    );

    test('recheck reads the client state instead of probing', () async {
      final c = await container(useTor: true);
      final hold = backend.hold = Completer<void>();
      unawaited(EmbeddedTorService.ensureStarted());
      await pumpEventQueue();

      await c.read(routeStatusProvider.notifier).recheck();
      expect(status(c), RouteStatus.checking);
      hold.complete();
    });
  });

  group('the app lifecycle drives the client', () {
    Future<void> pumpApp(WidgetTester tester, {required bool useTor}) async {
      tester.view.physicalSize = const Size(1100, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      SharedPreferences.setMockInitialValues({
        if (useTor) AppConstants.keyUseTor: true,
      });
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: overridesForScene(
            ScreenshotScene.dcaTracker,
            prefs: prefs,
          ),
          child: const BagApp(onboardingComplete: true, initialLocation: '/'),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));
    }

    void lifecycle(WidgetTester tester, AppLifecycleState state) =>
        tester.binding.handleAppLifecycleStateChanged(state);

    testWidgets('paused → dormant, resumed → awake', (tester) async {
      await EmbeddedTorService.ensureStarted();
      await pumpApp(tester, useTor: true);

      lifecycle(tester, AppLifecycleState.inactive);
      lifecycle(tester, AppLifecycleState.hidden);
      await tester.pump();
      expect(backend.dormantCalls, isEmpty);

      lifecycle(tester, AppLifecycleState.paused);
      await tester.pump();
      expect(backend.dormantCalls, isEmpty, reason: 'the sleep waits (I1)');
      await tester.pump(TorHost.sleepDelay);
      expect(backend.dormantCalls, [true]);

      lifecycle(tester, AppLifecycleState.hidden);
      lifecycle(tester, AppLifecycleState.inactive);
      lifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
      expect(backend.dormantCalls, [true, false]);
      expect(backend.startCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    });

    testWidgets('the route is read at event time, not at startup', (
      tester,
    ) async {
      await pumpApp(tester, useTor: false);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BagApp)),
      );
      // Real async: the setter goes through prefs, secure storage and the
      // widget channel.
      await tester.runAsync(() async {
        await container.read(networkSettingsProvider.notifier).setUseTor(true);
        await pumpEventQueue();
      });
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);

      lifecycle(tester, AppLifecycleState.inactive);
      lifecycle(tester, AppLifecycleState.hidden);
      lifecycle(tester, AppLifecycleState.paused);
      await tester.pump(TorHost.sleepDelay);
      expect(backend.dormantCalls, [true]);
    });

    testWidgets('resume after the circuit was lost re-bootstraps; requests in '
        'between are refused', (tester) async {
      late TargetServer target;
      late FakeSocks5Proxy proxy;
      await tester.runAsync(() async {
        target = await TargetServer.start();
        proxy = await FakeSocks5Proxy.start(targetPort: target.port);
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await proxy.close();
          await target.close();
        });
      });
      backend.socksPort = proxy.port;
      await EmbeddedTorService.ensureStarted();
      await pumpApp(tester, useTor: true);

      lifecycle(tester, AppLifecycleState.inactive);
      lifecycle(tester, AppLifecycleState.hidden);
      lifecycle(tester, AppLifecycleState.paused);
      await tester.pump();
      backend.loseCircuit();

      // Suspended without a circuit: refused, nothing reaches the target.
      Object? error;
      await tester.runAsync(() async {
        try {
          await _get(target.port);
        } catch (e) {
          error = e;
        }
      });
      expect(error, isA<SocketException>());

      final restart = backend.hold = Completer<void>();
      lifecycle(tester, AppLifecycleState.hidden);
      lifecycle(tester, AppLifecycleState.inactive);
      lifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(backend.startCalls, 2);

      // Re-bootstrapping: still refused.
      error = null;
      await tester.runAsync(() async {
        try {
          await _get(target.port);
        } catch (e) {
          error = e;
        }
      });
      expect(error, isA<SocketException>());
      expect(target.hits, 0);
      expect(proxy.connectHosts, isEmpty);

      restart.complete();
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);

      int? code;
      await tester.runAsync(() async => code = await _get(target.port));
      expect(code, 200);
      expect(target.hits, 1);
    });
  });

  group('resume retries a failed client (R6)', () {
    Future<void> pumpApp(WidgetTester tester, {required bool useTor}) async {
      SharedPreferences.setMockInitialValues({
        if (useTor) AppConstants.keyUseTor: true,
      });
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: overridesForScene(
            ScreenshotScene.dcaTracker,
            prefs: prefs,
          ),
          child: const BagApp(onboardingComplete: true, initialLocation: '/'),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));
    }

    void resume(WidgetTester tester) {
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
    }

    testWidgets('failed → resume → starting → ready', (tester) async {
      await EmbeddedTorService.ensureStarted();
      // Dies in the background: no automatic retry (M2) until resume.
      await EmbeddedTorService.onPause();
      backend.dieOnItsOwn();
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      await pumpApp(tester, useTor: true);

      final restart = backend.hold = Completer<void>();
      resume(tester);
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(backend.startCalls, 2);
      expect(EmbeddedTorService.port, -1);

      restart.complete();
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(EmbeddedTorService.port, backend.socksPort);
    });

    testWidgets('off (route is not Tor): resume starts nothing', (
      tester,
    ) async {
      await pumpApp(tester, useTor: false);
      resume(tester);
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(backend.startCalls, 0);
    });

    test('onResume itself: failed restarts, off stays off', () {
      fakeAsync((async) {
        EmbeddedTorService.onResume();
        async.flushMicrotasks();
        expect(EmbeddedTorService.state, EmbeddedTorState.off);
        expect(backend.startCalls, 0);

        EmbeddedTorService.ensureStarted();
        async.flushMicrotasks();
        // Asleep in the background (the sleep waits TorHost.sleepDelay, I1),
        // then dies there: no automatic retry (M2) until resume.
        EmbeddedTorService.onPause();
        async.elapse(TorHost.sleepDelay);
        backend.dieOnItsOwn();
        async.flushMicrotasks();
        expect(EmbeddedTorService.state, EmbeddedTorState.failed);

        EmbeddedTorService.onResume();
        async.flushMicrotasks();
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);
        expect(backend.calls, ['start', 'dormant:true', 'stop', 'start']);
      });
    });
  });
}
