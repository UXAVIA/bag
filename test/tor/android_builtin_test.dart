/// Android runs Tor itself (Task A1): the Orbot path is gone.
///
/// Every case runs with `TorService.debugIsIOS = false`, the Android branch
/// on the test host, and a fake embedded backend.
///
/// - The Tor card, the home row and error card, `routeUnavailableMessage`
///   and the notification copy are the built-in ones, the same as iOS. No
///   rendered string on any screen names Orbot, except the one-time
///   migration hint.
/// - Orbot still listening on 127.0.0.1:9050 after an upgrade gets no
///   connection at all: while Bag's own client bootstraps every Tor request
///   is refused, and once it is ready traffic goes to its port only
///   (Review Focus 5).
/// - An upgrade with Tor on records `android_tor_migrated = 'show'` once; a
///   fresh install records `'none'`.
/// - The lifecycle follows Phase B: start at launch and on the toggle,
///   dormant on pause, retry on resume.
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/app.dart';
import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/core/theme/app_theme.dart';
import 'package:bag/features/settings/presentation/pro_upgrade_sheet.dart';
import 'package:bag/features/settings/presentation/sentinel_screen.dart';
import 'package:bag/features/wallets/presentation/wallets_screen.dart';
import 'package:bag/mock/mock_data.dart';
import 'package:bag/mock/mock_providers.dart';
import 'package:bag/mock/scenes.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/price_data.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/price_provider.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/route_status_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/services/embedded_tor_service.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/services/network/routed_http.dart';
import 'package:bag/services/price_service.dart';
import 'package:bag/services/sentinel_service.dart';
import 'package:bag/services/tor_host.dart';
import 'package:bag/services/tor_service.dart';

import '../network/fake_proxies.dart';

// The copy, exactly as in the brief (and Phase B's iOS copy).
const _cardSubtitle =
    "Built-in Tor — only Bag's traffic goes through Tor. No other app needed.";
const _connecting = 'Connecting to Tor…';
const _connected = 'Connected through Tor';
const _cardFailed = "Couldn't connect to Tor";
const _retry = 'Retry';
const _hint = "Bag now runs Tor itself. You can turn off Orbot's VPN.";
const _rowFailedPrefix = "Tor couldn't connect — prices paused since";
const _errorTitle = "Tor couldn't connect";
const _errorBody = 'Check your internet connection, then retry.';
const _errorButton = 'Retry Tor';
const _connectingBody = 'Prices will appear once Tor has connected.';
const _sentinelPaused = "Paused — Tor couldn't connect";
const _sentinelBullet = 'Tor-aware: waits for Tor instead of leaking your IP';

/// Orbot's SOCKS port, which a 1.3.5 user may still have open.
const _orbotPort = orbotSocksPort;

/// A scriptable embedded client. Starts at once unless [hold] is set (the
/// state then stays `starting` until it completes) or [failNext] is (the
/// start throws once). Like the plugin, a stop cancels a held start.
class _AndroidBackend implements EmbeddedTorBackend {
  /// The port reported while bootstrapped.
  int socksPort = 47123;

  int startCalls = 0;
  int stopCalls = 0;
  final List<bool> dormantCalls = [];

  Completer<void>? hold;

  /// The hold the running start is waiting on.
  Completer<void>? held;
  bool failNext = false;
  bool _bootstrapped = false;
  final _failures = StreamController<Object>.broadcast();
  final _events = StreamController<int>.broadcast();

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
    if (failNext) {
      failNext = false;
      throw StateError('bootstrap failed');
    }
    final pending = held = hold;
    hold = null;
    if (pending != null) await pending.future;
    _bootstrapped = true;
  }

  @override
  Future<void> bootstrap() async {}

  @override
  Future<void> setDormant(bool dormant) async => dormantCalls.add(dormant);

  @override
  Future<void> stop() async {
    stopCalls++;
    _bootstrapped = false;
  }
}

/// Cached prices; counts forced refreshes.
class _CachedPriceNotifier extends PriceNotifier {
  static int forced = 0;

  @override
  Future<PriceData> build() async => mockPriceData;

  @override
  Future<void> refresh({bool force = false}) async {
    if (force) forced++;
  }
}

/// Nothing cached: the route gate's rethrow.
class _BlockedPriceNotifier extends PriceNotifier {
  @override
  Future<PriceData> build() async => throw const RouteUnavailableException();

  @override
  Future<void> refresh({bool force = false}) async {}
}

/// Every rendered string (and tooltip) that mentions Orbot, offstage
/// included, other than the migration hint.
List<String> _orbotStrings(WidgetTester tester) => [
  ...tester
      .widgetList<RichText>(find.byType(RichText, skipOffstage: false))
      .map((r) => r.text.toPlainText()),
  ...tester
      .widgetList<Tooltip>(find.byType(Tooltip, skipOffstage: false))
      .map((t) => t.message ?? ''),
].where((s) => s.contains('Orbot') && s != _hint).toList();

/// testWidgets replaces every HttpClient with one that answers 400; the base
/// [HttpOverrides] builds real ones again.
class _RealHttp extends HttpOverrides {}

/// The Tor card lives in the Wallets tab's Pro layout; a free user has none.
class _ProUser extends ProUnlockedNotifier {
  @override
  bool build() => true;
}

/// GETs `http://bag-test.invalid:<port>/` over [TorRoute] with a real client.
/// `.invalid` never resolves (RFC 6761), so a hit proves the proxy did.
Future<int> _get(int port) => HttpOverrides.runWithHttpOverrides(() async {
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
}, _RealHttp());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _AndroidBackend backend;

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
    backend = _AndroidBackend();
    EmbeddedTorService.debugBackend = backend;
    TorService.debugIsIOS = false;
    // The UI isolate with Tor selected: TorHost starts nothing with neither
    // a route nor a route check (N-f).
    TorHost.routeChanged(tor: true);
    RouteGate.invalidateCache();
    _CachedPriceNotifier.forced = 0;
  });

  tearDown(() async {
    for (final hold in [backend.hold, backend.held]) {
      if (hold != null && !hold.isCompleted) hold.complete();
    }
    await EmbeddedTorService.stop();
    // A start a failed case left held can't stall the next case.
    EmbeddedTorService.debugReset();
    EmbeddedTorService.debugBackend = null;
    TorService.debugIsIOS = null;
    RouteGate.debugProbeOverride = null;
    RouteGate.invalidateCache();
  });

  /// Puts the embedded client in [state] (`starting` is held open).
  Future<void> torIn(EmbeddedTorState state) async {
    switch (state) {
      case EmbeddedTorState.starting:
        backend.hold = Completer<void>();
        unawaited(EmbeddedTorService.ensureStarted());
      case EmbeddedTorState.ready:
        await EmbeddedTorService.ensureStarted();
      case EmbeddedTorState.failed:
        backend.failNext = true;
        await EmbeddedTorService.ensureStarted();
      case EmbeddedTorState.off:
        break;
    }
    expect(EmbeddedTorService.state, state);
  }

  void releaseHeldStart() {
    final held = backend.held;
    if (held != null && !held.isCompleted) held.complete();
  }

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  Future<void> pumpPrivacy(
    WidgetTester tester,
    SharedPreferences sp, {
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        // A fresh scope per call: a relaunch, not a rebuild.
        key: UniqueKey(),
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sp),
          initialProxyConfigProvider.overrideWithValue(null),
          priceProvider.overrideWith(_CachedPriceNotifier.new),
          proUnlockedProvider.overrideWith(_ProUser.new),
          ...overrides,
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const WalletsScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    required PriceNotifier Function() prices,
  }) async {
    tester.view.physicalSize = const Size(1100, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final prefs = await prefsWith({AppConstants.keyUseTor: true});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overridesForScene(ScreenshotScene.homeWithWallet, prefs: prefs),
          initialProxyConfigProvider.overrideWithValue(null),
          // The real notifier: with built-in Tor it follows the client.
          routeStatusProvider.overrideWith(RouteStatusNotifier.new),
          priceProvider.overrideWith(prices),
        ],
        child: const BagApp(onboardingComplete: true, initialLocation: '/'),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 3));
  }

  // ── Copy ────────────────────────────────────────────────────────────────

  group('Tor card (Wallet & Privacy)', () {
    testWidgets('the built-in subtitle and the Phase B states, never Orbot', (
      tester,
    ) async {
      final sp = await prefsWith({AppConstants.keyUseTor: true});

      await torIn(EmbeddedTorState.starting);
      await pumpPrivacy(tester, sp);
      expect(find.text(_cardSubtitle), findsOneWidget);
      expect(find.text(_connecting), findsOneWidget);
      expect(find.text(_retry), findsNothing);
      expect(find.byTooltip('Re-check Orbot'), findsNothing);
      expect(_orbotStrings(tester), isEmpty);

      releaseHeldStart();
      await tester.pump();
      await tester.pump();
      expect(find.text(_connected), findsOneWidget);
      expect(find.text(_retry), findsNothing);
      expect(_orbotStrings(tester), isEmpty);

      await EmbeddedTorService.stop();
      await torIn(EmbeddedTorState.failed);
      await pumpPrivacy(tester, sp);
      expect(find.text(_cardFailed), findsOneWidget);
      expect(find.text(_retry), findsOneWidget);
      expect(
        find.text('Details: StateError: Bad state: bootstrap failed'),
        findsOneWidget,
      );
      expect(_orbotStrings(tester), isEmpty);

      // Retry restarts the client; its ready transition refreshes once.
      _CachedPriceNotifier.forced = 0;
      await tester.tap(find.text(_retry));
      await tester.pump();
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(find.text(_connected), findsOneWidget);
      expect(_CachedPriceNotifier.forced, 1);
    });

    testWidgets('Tor off: "Tor is off" under the built-in subtitle', (
      tester,
    ) async {
      await pumpPrivacy(tester, await prefsWith({}));

      expect(find.text('Tor is off'), findsOneWidget);
      expect(find.text(_cardSubtitle), findsOneWidget);
      expect(find.textContaining('Requires'), findsNothing);
      expect(_orbotStrings(tester), isEmpty);
    });
  });

  group('home', () {
    testWidgets('starting: the row reads "Connecting to Tor…"', (tester) async {
      await torIn(EmbeddedTorState.starting);
      await pumpHome(tester, prices: _CachedPriceNotifier.new);

      expect(find.text(_connecting), findsOneWidget);
      expect(find.textContaining('prices paused since'), findsNothing);
      expect(_orbotStrings(tester), isEmpty);

      releaseHeldStart();
      await tester.pumpAndSettle();
    });

    testWidgets('failed: "Tor couldn\'t connect — prices paused since HH:mm" '
        '+ Retry', (tester) async {
      await torIn(EmbeddedTorState.failed);
      await pumpHome(tester, prices: _CachedPriceNotifier.new);

      expect(
        find.textContaining(RegExp('^$_rowFailedPrefix \\d\\d:\\d\\d\$')),
        findsOneWidget,
      );
      expect(find.text(_retry), findsOneWidget);
      expect(find.text('Re-check'), findsNothing);
      expect(_orbotStrings(tester), isEmpty);
    });

    testWidgets('nothing cached: the built-in error cards', (tester) async {
      await torIn(EmbeddedTorState.failed);
      await pumpHome(tester, prices: _BlockedPriceNotifier.new);
      expect(find.text(_errorTitle), findsOneWidget);
      expect(find.text(_errorBody), findsOneWidget);
      expect(find.text(_errorButton), findsOneWidget);
      expect(find.text('Unable to fetch price'), findsNothing);
      expect(_orbotStrings(tester), isEmpty);

      // Retry Tor restarts it: the card says connecting, with no button.
      backend.hold = Completer<void>();
      await tester.tap(find.text(_errorButton));
      await tester.pumpAndSettle();
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(find.text(_connecting), findsOneWidget);
      expect(find.text(_connectingBody), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(_orbotStrings(tester), isEmpty);

      releaseHeldStart();
      await tester.pumpAndSettle();
    });
  });

  test(
    'routeUnavailableMessage(TorRoute) matches iOS in every state',
    () async {
      String both() {
        TorService.debugIsIOS = true;
        final ios = routeUnavailableMessage(const TorRoute());
        TorService.debugIsIOS = false;
        final android = routeUnavailableMessage(const TorRoute());
        expect(android, ios);
        expect(android, isNot(contains('Orbot')));
        return android;
      }

      expect(both(), 'Tor is still connecting. Try again in a moment.');
      await torIn(EmbeddedTorState.starting);
      expect(both(), 'Tor is still connecting. Try again in a moment.');
      releaseHeldStart();
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      await EmbeddedTorService.stop();
      await torIn(EmbeddedTorState.failed);
      expect(
        both(),
        "Tor couldn't connect. Check your internet connection, then retry.",
      );
    },
  );

  group('no screen names Orbot, except the migration hint', () {
    testWidgets('Settings (About)', (tester) async {
      tester.view.physicalSize = const Size(1100, 8000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final prefs = await prefsWith({AppConstants.keyUseTor: true});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overridesForScene(
              ScreenshotScene.settingsProLocked,
              prefs: prefs,
            ),
            initialProxyConfigProvider.overrideWithValue(null),
          ],
          child: const BagApp(
            onboardingComplete: true,
            initialLocation: '/settings',
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));

      expect(find.text('Source Code'), findsOneWidget); // About is built
      expect(
        find.textContaining(
          'Pro unlocks watch-only wallet tracking, built-in '
          'Tor routing, custom Esplora node support, Bitcoin Health Check '
          'with privacy scoring, and Sentinel — always-on balance alerts.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('orbot.app'), findsNothing);
      expect(_orbotStrings(tester), isEmpty);
    });

    testWidgets('the Pro sheet sells "Tor built in"', (tester) async {
      tester.view.physicalSize = const Size(1100, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final prefs = await prefsWith({});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showProUpgradeSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Tor built in'), findsOneWidget);
      expect(_orbotStrings(tester), isEmpty);
    });

    testWidgets('Wallet & Privacy with the hint showing: the hint is the only '
        'one', (tester) async {
      final sp = await prefsWith({AppConstants.keyUseTor: true});
      await TorService.recordOrbotMigration(sp);
      for (final state in [
        EmbeddedTorState.starting,
        EmbeddedTorState.ready,
        EmbeddedTorState.failed,
      ]) {
        await EmbeddedTorService.stop();
        await torIn(state);
        await pumpPrivacy(tester, sp);
        expect(find.text(_hint), findsOneWidget, reason: '$state');
        expect(_orbotStrings(tester), isEmpty, reason: '$state');
        releaseHeldStart();
        await tester.pump();
      }
    });
  });

  // ── Review Focus 5: Orbot still running after the upgrade ───────────────

  test('Orbot on 127.0.0.1:9050 gets no connection: refused while Bag\'s '
      'client starts, then the embedded port only', () async {
    final target = await TargetServer.start();
    addTearDown(target.close);
    final orbot = await startOrbotStandIn(targetPort: target.port);
    addTearDown(orbot.close);
    final embedded = await FakeSocks5Proxy.start(targetPort: target.port);
    addTearDown(embedded.close);
    backend.socksPort = embedded.port;

    // The 1.3.5 user's launch: Tor on, Bag's client bootstrapping.
    backend.hold = Completer<void>();
    TorService.followRoute(const TorRoute());
    expect(EmbeddedTorService.state, EmbeddedTorState.starting);

    // Something answering on 9050 does not make Tor "available".
    expect(await RouteGate.probe(const TorRoute()), RouteStatus.unavailable);
    expect(
      await RouteGate.probeCached(const TorRoute()),
      RouteStatus.unavailable,
    );
    await expectLater(
      _get(target.port),
      throwsA(
        isA<SocketException>().having(
          (e) => e.message,
          'message',
          'Tor is not connected',
        ),
      ),
    );
    // The Dio path every price, chart and Esplora request takes.
    final dio = buildRoutedDio(
      route: const TorRoute(),
      clearnetTimeout: const Duration(seconds: 5),
    );
    addTearDown(() => dio.close(force: true));
    await HttpOverrides.runWithHttpOverrides(
      () => expectLater(
        dio.get<Object?>('http://bag-test.invalid:${target.port}/'),
        // Refused by the route itself, not a stray network error.
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'error',
            isA<SocketException>().having(
              (e) => e.message,
              'message',
              'Tor is not connected',
            ),
          ),
        ),
      ),
      _RealHttp(),
    );
    await pumpEventQueue();
    expect(orbot.connections, 0);
    expect(embedded.connections, 0);
    expect(target.hits, 0);

    releaseHeldStart();
    await pumpEventQueue();
    expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    expect(await RouteGate.probe(const TorRoute()), RouteStatus.available);
    expect(await _get(target.port), 200);
    expect(embedded.connectHosts, ['bag-test.invalid']);
    expect(target.hits, 1);
    // The Dio path too, now through the embedded port.
    final ready = await HttpOverrides.runWithHttpOverrides(
      () => dio.get<Object?>('http://bag-test.invalid:${target.port}/'),
      _RealHttp(),
    );
    expect(ready.statusCode, 200);
    expect(embedded.connectHosts, ['bag-test.invalid', 'bag-test.invalid']);
    expect(target.hits, 2);
    expect(orbot.connections, 0);
  });

  // ── Orbot migration hint (R8) ───────────────────────────────────────────

  group('Orbot migration hint', () {
    test(
      'an upgrade with Tor on records "show" under android_tor_migrated',
      () async {
        expect(AppConstants.keyAndroidTorMigrated, 'android_tor_migrated');
        final sp = await prefsWith({AppConstants.keyUseTor: true});
        await TorService.recordOrbotMigration(sp);

        expect(sp.getString(AppConstants.keyAndroidTorMigrated), 'show');
        expect(sp.containsKey(AppConstants.keyIosTorMigrated), isFalse);
        expect(TorService.showOrbotMigrationHint(sp), isTrue);
      },
    );

    test('a fresh install records "none"', () async {
      final sp = await prefsWith({});
      await TorService.recordOrbotMigration(sp);

      expect(sp.getString(AppConstants.keyAndroidTorMigrated), 'none');
      expect(TorService.showOrbotMigrationHint(sp), isFalse);
    });

    test('written once: turning Tor on later never shows it', () async {
      final sp = await prefsWith({});
      await TorService.recordOrbotMigration(sp);
      await sp.setBool(AppConstants.keyUseTor, true);
      await TorService.recordOrbotMigration(sp);

      expect(sp.getString(AppConstants.keyAndroidTorMigrated), 'none');
      expect(TorService.showOrbotMigrationHint(sp), isFalse);
    });

    test('the iOS pref does not count on Android', () async {
      final sp = await prefsWith({AppConstants.keyIosTorMigrated: 'show'});
      await TorService.recordOrbotMigration(sp);

      expect(sp.getString(AppConstants.keyAndroidTorMigrated), 'none');
      expect(TorService.showOrbotMigrationHint(sp), isFalse);
    });

    testWidgets('shown once: dismissing it removes it for good', (
      tester,
    ) async {
      final sp = await prefsWith({AppConstants.keyUseTor: true});
      await TorService.recordOrbotMigration(sp);
      await torIn(EmbeddedTorState.ready);
      await pumpPrivacy(tester, sp);
      expect(find.text(_hint), findsOneWidget);

      await tester.tap(find.byKey(const Key('orbot-hint-dismiss')));
      await tester.pump();
      expect(find.text(_hint), findsNothing);
      expect(sp.getString(AppConstants.keyAndroidTorMigrated), 'dismissed');

      // Next launch: still dismissed, still gone.
      await TorService.recordOrbotMigration(sp);
      expect(sp.getString(AppConstants.keyAndroidTorMigrated), 'dismissed');
      await pumpPrivacy(tester, sp);
      expect(find.text(_hint), findsNothing);
    });

    testWidgets('a fresh install never shows it', (tester) async {
      final sp = await prefsWith({});
      await TorService.recordOrbotMigration(sp);
      await pumpPrivacy(tester, sp);
      expect(find.text(_hint), findsNothing);
    });
  });

  // ── Sentinel ────────────────────────────────────────────────────────────

  group('Sentinel', () {
    test('notification copy while Tor is down', () {
      expect(sentinelRouteDownCopy(const TorRoute()), 'Waiting for Tor…');
      expect(
        sentinelRouteDownCopy(const TorRoute(), paused: true),
        _sentinelPaused,
      );
    });

    testWidgets('the screen has no Orbot tip, and its bullet waits for Tor', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Android's screen (iOS has Sentinel Lite's, with no such bullet).
      SentinelService.debugIsAndroid = true;
      addTearDown(() => SentinelService.debugIsAndroid = null);
      // Tor on: the old Orbot tip showed only then.
      final prefs = await prefsWith({AppConstants.keyUseTor: true});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overridesForScene(ScreenshotScene.sentinelActive, prefs: prefs),
            initialProxyConfigProvider.overrideWithValue(null),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const SentinelScreen(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text(_sentinelBullet), findsOneWidget);
      expect(
        find.textContaining('Tor is enabled — two steps for reliability'),
        findsNothing,
      );
      expect(find.textContaining('Keep Sentinel running'), findsOneWidget);
      expect(_orbotStrings(tester), isEmpty);
    });
  });

  // ── Lifecycle (Phase B, now on Android) ─────────────────────────────────

  group('lifecycle', () {
    Future<ProviderContainer> container({bool useTor = false}) async {
      final prefs = await prefsWith({if (useTor) AppConstants.keyUseTor: true});
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          initialProxyConfigProvider.overrideWithValue(null),
          priceProvider.overrideWith(_CachedPriceNotifier.new),
        ],
      );
      addTearDown(c.dispose);
      c.listen(routeStatusProvider, (_, _) {});
      return c;
    }

    Future<void> pumpApp(WidgetTester tester, {Key? key}) async {
      final prefs = await prefsWith({AppConstants.keyUseTor: true});
      await tester.pumpWidget(
        ProviderScope(
          key: key,
          overrides: overridesForScene(
            ScreenshotScene.dcaTracker,
            prefs: prefs,
          ),
          child: const BagApp(onboardingComplete: true, initialLocation: '/'),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));
    }

    void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
      for (final s in states) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
    }

    test(
      'launch with Tor on starts the client, without waiting for it',
      () async {
        backend.hold = Completer<void>();
        // What main() does before runApp: returns at once, already starting.
        TorService.followRoute(const TorRoute());
        expect(EmbeddedTorService.state, EmbeddedTorState.starting);

        await pumpEventQueue();
        expect(backend.startCalls, 1);
        expect(EmbeddedTorService.state, EmbeddedTorState.starting);
        releaseHeldStart();
        await pumpEventQueue();
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      },
    );

    test('the toggle starts it and stops it; the status follows the client '
        '(R2)', () async {
      final c = await container();
      final settings = c.read(networkSettingsProvider.notifier);
      final hold = backend.hold = Completer<void>();

      await settings.setUseTor(true);
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(backend.startCalls, 1);
      expect(c.read(routeStatusProvider).valueOrNull, RouteStatus.checking);

      hold.complete();
      await pumpEventQueue();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(c.read(routeStatusProvider).valueOrNull, RouteStatus.available);
      // The ready transition refreshed prices once.
      expect(_CachedPriceNotifier.forced, 1);

      await settings.setUseTor(false);
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(backend.stopCalls, 1);
    });

    testWidgets('paused → dormant, resumed → awake', (tester) async {
      await EmbeddedTorService.ensureStarted();
      await pumpApp(tester);

      lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      await tester.pump();
      expect(backend.dormantCalls, isEmpty, reason: 'the sleep waits (I1)');
      await tester.pump(TorHost.sleepDelay);
      expect(backend.dormantCalls, [true]);

      lifecycle(tester, [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await tester.pump();
      expect(backend.dormantCalls, [true, false]);
      expect(backend.startCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    });

    testWidgets('paused while starting: the client sleeps once it is ready, '
        'and wakes on resume (M3)', (tester) async {
      await pumpApp(tester);
      backend.hold = Completer<void>();
      TorService.followRoute(const TorRoute());
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);

      lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      await tester.pump();
      expect(backend.dormantCalls, isEmpty, reason: 'nothing to put to sleep');

      releaseHeldStart();
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      await tester.pump(TorHost.sleepDelay);
      expect(backend.dormantCalls, [true]);

      lifecycle(tester, [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await tester.pump();
      expect(backend.dormantCalls, [true, false]);
      expect(backend.startCalls, 1);
    });

    testWidgets('paused and resumed while starting: it stays awake once '
        'ready (M3)', (tester) async {
      await pumpApp(tester);
      backend.hold = Completer<void>();
      TorService.followRoute(const TorRoute());
      await tester.pump();

      lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await tester.pump();
      releaseHeldStart();
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      await tester.pump(TorHost.sleepDelay * 2);
      expect(backend.dormantCalls, isEmpty);
    });

    testWidgets('detached: the UI stops the client it runs before its engine '
        'goes (R-A2a)', (tester) async {
      TorService.followRoute(const TorRoute());
      await pumpApp(tester);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(await TorHost.port(), backend.socksPort);

      lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]);
      // Issued from the detached event itself: nothing later may run.
      expect(backend.stopCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      await tester.pump();
      expect(await TorHost.port(), -1);
      expect(backend.startCalls, 1);
      // The binding's lifecycle carries into the next case.
      lifecycle(tester, [AppLifecycleState.resumed]);
      await tester.pump();
    });

    testWidgets('resumed after detached: the route is applied again, since '
        'the engine was kept after all (M8)', (tester) async {
      TorService.followRoute(const TorRoute());
      await pumpApp(tester);
      lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]);
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.off);

      lifecycle(tester, [AppLifecycleState.resumed]);
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(backend.startCalls, 2);
      expect(await TorHost.port(), backend.socksPort);

      // Only the first resume after a detached re-applies it.
      lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await tester.pump();
      expect(backend.startCalls, 2);
    });

    testWidgets('the detached flag outlives the app State: on a kept engine '
        'with a rebuilt widget tree, the first resume still applies the '
        'route (N-e)', (tester) async {
      TorService.followRoute(const TorRoute());
      await pumpApp(tester);
      lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]);
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.off);

      // The activity comes back on the same engine (`inactive`, then
      // `resumed`), and the widget tree is rebuilt in between: the resume
      // reaches a new State, not the one that saw `detached`.
      lifecycle(tester, [AppLifecycleState.inactive]);
      await pumpApp(tester, key: UniqueKey());
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      lifecycle(tester, [AppLifecycleState.resumed]);
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(backend.startCalls, 2);
    });

    testWidgets('resume retries a failed client (R6)', (tester) async {
      await torIn(EmbeddedTorState.failed);
      await pumpApp(tester);
      expect(backend.startCalls, 1);

      lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await tester.pump();
      await tester.pump();
      expect(backend.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    });
  });

  // ── Source shape ────────────────────────────────────────────────────────

  group('lib/', () {
    Iterable<(String, int, String)> dartLines() sync* {
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      for (final f in files) {
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          yield (f.path, i + 1, lines[i]);
        }
      }
    }

    test('names Orbot only for the migration hint', () {
      final offenders = [
        for (final (path, n, line) in dartLines())
          if (line.contains('Orbot') &&
              !line.contains('OrbotMigration') &&
              !line.contains(_hint))
            '$path:$n: ${line.trim()}',
      ];
      expect(offenders, isEmpty);
    });

    test("never names Orbot's port", () {
      final offenders = [
        for (final (path, n, line) in dartLines())
          if (line.contains('$_orbotPort')) '$path:$n: ${line.trim()}',
      ];
      expect(offenders, isEmpty);
    });
  });
}
