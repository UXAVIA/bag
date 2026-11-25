/// Copy for the built-in Tor (Phase B Task 4, Android since Task A1): the
/// Tor card, the home row and error card, `routeUnavailableMessage`, the
/// About text and the Pro sheet, plus the one-time Orbot migration hint
/// (ruling R8). The whole suite runs twice, with `TorService.debugIsIOS`
/// true (iOS) and false (Android), each with a fake embedded backend: the
/// copy is the same on both.
///
/// No rendered string may mention Orbot, except the migration hint.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tor/tor.dart' show TorProxyFailure;

import 'package:bag/app.dart';
import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/core/theme/app_theme.dart';
import 'package:bag/features/settings/presentation/pro_upgrade_sheet.dart';
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
import 'package:bag/services/tor_host.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/services/price_service.dart';
import 'package:bag/services/tor_service.dart';

// The copy, exactly as in the Task 4 brief.
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
const _notReady = 'Tor is still connecting. Try again in a moment.';
// Ruling R9: the error card while Tor is starting and nothing is cached.
const _connectingBody = 'Prices will appear once Tor has connected.';

/// Starts at once, unless [hold] is set (the state then stays `starting`
/// until it completes) or [failNext] is (the start throws once).
class _CopyBackend implements EmbeddedTorBackend {
  int startCalls = 0;
  Completer<void>? hold;

  /// The hold the running start is waiting on.
  Completer<void>? held;
  bool failNext = false;
  bool _bootstrapped = false;
  final _failures = StreamController<Object>.broadcast();
  final _events = StreamController<int>.broadcast();

  /// The plugin's proxy is going away: port -1 on `events`, before any
  /// `failures` report (M1).
  void losePort() {
    _bootstrapped = false;
    _events.add(-1);
  }

  /// The plugin's report that follows [losePort].
  void reportFailure(Object failure) => _failures.add(failure);

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
  Future<void> setDormant(bool dormant) async {}

  @override
  Future<void> stop() async => _bootstrapped = false;
}

/// Cached prices; counts forced refreshes (the Re-check / ready refresh).
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

/// The Tor card lives in the Wallets tab's Pro layout; a free user has none.
class _ProUser extends ProUnlockedNotifier {
  @override
  bool build() => true;
}

/// Status `unavailable` whatever the embedded state (R3: `starting` still
/// reads as connecting).
class _UnavailableStatus extends RouteStatusNotifier {
  @override
  Future<RouteStatus> build() async => RouteStatus.unavailable;
}

class _AvailableStatus extends RouteStatusNotifier {
  @override
  Future<RouteStatus> build() async => RouteStatus.available;
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

void main() {
  for (final ios in [true, false]) {
    group(ios ? 'iOS' : 'Android', () => _suite(ios: ios));
  }
}

void _suite({required bool ios}) {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CopyBackend backend;
  // The migration pref is per platform; its values are shared.
  final migratedKey = ios
      ? AppConstants.keyIosTorMigrated
      : AppConstants.keyAndroidTorMigrated;

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
    backend = _CopyBackend();
    EmbeddedTorService.debugBackend = backend;
    TorService.debugIsIOS = ios;
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
    RouteGate.invalidateCache();
  });

  /// Puts the embedded client in [state] (`starting` is held open; release
  /// it with [release] before the test ends).
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

  // ── Tor card (Wallet & Privacy) ────────────────────────────────────────

  group('Tor card', () {
    Future<SharedPreferences> pumpCard(
      WidgetTester tester, {
      Map<String, Object> prefs = const {AppConstants.keyUseTor: true},
      bool recordMigration = false,
      List<Override> overrides = const [],
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      final sp = await SharedPreferences.getInstance();
      if (recordMigration) await TorService.recordOrbotMigration(sp);
      tester.view.physicalSize = const Size(800, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
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
      return sp;
    }

    testWidgets('starting: subtitle and "Connecting to Tor…"', (tester) async {
      await torIn(EmbeddedTorState.starting);
      await pumpCard(tester);

      expect(find.text(_cardSubtitle), findsOneWidget);
      expect(find.text(_connecting), findsOneWidget);
      expect(find.text(_retry), findsNothing);
      expect(_orbotStrings(tester), isEmpty);

      releaseHeldStart();
      await tester.pump();
    });

    testWidgets('ready: "Connected through Tor"', (tester) async {
      await torIn(EmbeddedTorState.ready);
      await pumpCard(tester);

      expect(find.text(_cardSubtitle), findsOneWidget);
      expect(find.text(_connected), findsOneWidget);
      expect(find.text(_retry), findsNothing);
      expect(_orbotStrings(tester), isEmpty);
    });

    testWidgets('failed: "Couldn\'t connect to Tor" + Retry, which calls '
        'ensureStarted', (tester) async {
      await torIn(EmbeddedTorState.failed);
      await pumpCard(tester);

      expect(find.text(_cardFailed), findsOneWidget);
      expect(find.text(_retry), findsOneWidget);
      expect(_orbotStrings(tester), isEmpty);
      expect(backend.startCalls, 1);

      backend.hold = Completer<void>();
      await tester.tap(find.text(_retry));
      await tester.pump();
      expect(backend.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(find.text(_connecting), findsOneWidget);

      releaseHeldStart();
      await tester.pump();
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(find.text(_connected), findsOneWidget);
      // The ready transition refreshes prices once.
      expect(_CachedPriceNotifier.forced, 1);
    });

    testWidgets('failed: the last error shows under "Couldn\'t connect to '
        'Tor"; gone once ready (M3)', (tester) async {
      await torIn(EmbeddedTorState.failed);
      await pumpCard(tester);

      expect(EmbeddedTorService.lastError, isNotNull);
      final details = find.text(
        'Details: ${EmbeddedTorService.lastError}',
      );
      expect(details, findsOneWidget);
      expect(
        find.text('Details: StateError: Bad state: bootstrap failed'),
        findsOneWidget,
      );
      // In the card's hint style (bodySmall).
      final style = tester.widget<Text>(details).style;
      final context = tester.element(details);
      expect(style?.fontSize, Theme.of(context).textTheme.bodySmall?.fontSize);

      await tester.tap(find.text(_retry));
      await tester.pump();
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(EmbeddedTorService.lastError, isNull);
      expect(find.textContaining('Details:'), findsNothing);
    });

    testWidgets('starting and ready: no details line (M3)', (tester) async {
      await torIn(EmbeddedTorState.starting);
      await pumpCard(tester);
      expect(find.textContaining('Details:'), findsNothing);
      releaseHeldStart();
      await tester.pump();
      await tester.pump();
      expect(find.text(_connected), findsOneWidget);
      expect(find.textContaining('Details:'), findsNothing);
    });

    testWidgets('ready, then the port is lost: the card reads failed (M1)', (
      tester,
    ) async {
      await torIn(EmbeddedTorState.ready);
      await pumpCard(tester);
      expect(find.text(_connected), findsOneWidget);

      backend.failNext = true;
      backend.losePort();
      await tester.pump();
      await tester.pump();

      expect(find.text(_cardFailed), findsOneWidget);
      expect(find.text(_retry), findsOneWidget);
    });

    testWidgets('FW-BG addendum: the details line follows the plugin\'s '
        'report that replaces the lost-port reason while the card stays '
        'failed', (tester) async {
      await torIn(EmbeddedTorState.ready);
      await pumpCard(tester);

      backend.losePort();
      await tester.pump();
      await tester.pump();
      expect(find.text(_cardFailed), findsOneWidget);
      expect(
        find.text('Details: Tor client lost its SOCKS port'),
        findsOneWidget,
      );

      // Another isolate's sweep ended it: no automatic retry, so the card
      // stays failed while the reason changes.
      backend.reportFailure(
        TorProxyFailure(
          'Tor proxy was stopped by a process-wide stop',
          processWideStop: true,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(find.text(_cardFailed), findsOneWidget);
      expect(
        find.text(
          'Details: TorProxyFailure: Tor proxy was stopped by a '
          'process-wide stop',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('lost its SOCKS port'), findsNothing);
    });

    testWidgets('Tor not the route: "Tor is off", nothing about Orbot', (
      tester,
    ) async {
      await pumpCard(
        tester,
        prefs: const {},
        overrides: [routeStatusProvider.overrideWith(_AvailableStatus.new)],
      );

      expect(find.text('Tor is off'), findsOneWidget);
      expect(find.text(_cardSubtitle), findsOneWidget);
      expect(find.text(_connected), findsNothing);
      expect(find.text(_retry), findsNothing);
      expect(_orbotStrings(tester), isEmpty);
    });
  });

  // ── Orbot migration hint (R8) ──────────────────────────────────────────

  group('Orbot migration hint (R8)', () {
    Future<SharedPreferences> launch(
      WidgetTester tester,
      Map<String, Object> prefs,
    ) async {
      SharedPreferences.setMockInitialValues(prefs);
      final sp = await SharedPreferences.getInstance();
      await TorService.recordOrbotMigration(sp);
      return sp;
    }

    Future<void> pumpCard(WidgetTester tester, SharedPreferences sp) async {
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
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const WalletsScreen(),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('an upgrade with Tor on shows the hint', (tester) async {
      final sp = await launch(tester, {AppConstants.keyUseTor: true});
      expect(sp.getString(migratedKey), 'show');
      await torIn(EmbeddedTorState.ready);
      await pumpCard(tester, sp);

      expect(find.text(_hint), findsOneWidget);
      // The hint is the one string allowed to name Orbot.
      expect(_orbotStrings(tester), isEmpty);
    });

    testWidgets('an upgrade with Tor off, then Tor turned on, never shows it', (
      tester,
    ) async {
      final sp = await launch(tester, {});
      expect(sp.getString(migratedKey), 'none');
      await pumpCard(tester, sp);
      expect(find.text(_hint), findsNothing);

      // Turn Tor on, then relaunch: the pref is never re-evaluated.
      await sp.setBool(AppConstants.keyUseTor, true);
      await TorService.recordOrbotMigration(sp);
      expect(sp.getString(migratedKey), 'none');
      await torIn(EmbeddedTorState.ready);
      await pumpCard(tester, sp);

      expect(find.text(_hint), findsNothing);
    });

    testWidgets('dismissing removes it for good', (tester) async {
      final sp = await launch(tester, {AppConstants.keyUseTor: true});
      await torIn(EmbeddedTorState.ready);
      await pumpCard(tester, sp);
      expect(find.text(_hint), findsOneWidget);

      await tester.tap(find.byKey(const Key('orbot-hint-dismiss')));
      await tester.pump();
      expect(find.text(_hint), findsNothing);
      expect(sp.getString(migratedKey), 'dismissed');

      // Next launch: still dismissed, still gone.
      await TorService.recordOrbotMigration(sp);
      expect(sp.getString(migratedKey), 'dismissed');
      await pumpCard(tester, sp);
      expect(find.text(_hint), findsNothing);
    });

    test('each platform records and reads only its own key', () async {
      final otherKey = ios
          ? AppConstants.keyAndroidTorMigrated
          : AppConstants.keyIosTorMigrated;
      SharedPreferences.setMockInitialValues({AppConstants.keyUseTor: true});
      final sp = await SharedPreferences.getInstance();
      await TorService.recordOrbotMigration(sp);
      expect(sp.getString(migratedKey), 'show');
      expect(sp.containsKey(otherKey), isFalse);

      // The other platform's 'show' alone never shows it here.
      SharedPreferences.setMockInitialValues({otherKey: 'show'});
      final other = await SharedPreferences.getInstance();
      await TorService.recordOrbotMigration(other);
      expect(other.getString(migratedKey), 'none');
      expect(TorService.showOrbotMigrationHint(other), isFalse);
    });
  });

  // ── Home row and error card ────────────────────────────────────────────

  group('home', () {
    Future<void> pumpHome(
      WidgetTester tester, {
      required List<Override> overrides,
    }) async {
      tester.view.physicalSize = const Size(1100, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({AppConstants.keyUseTor: true});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overridesForScene(ScreenshotScene.homeWithWallet, prefs: prefs),
            initialProxyConfigProvider.overrideWithValue(null),
            // The real notifier: on Tor it follows the embedded state.
            routeStatusProvider.overrideWith(RouteStatusNotifier.new),
            ...overrides,
          ],
          child: const BagApp(onboardingComplete: true, initialLocation: '/'),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));
    }

    testWidgets('starting (status checking): the row reads "Connecting to '
        'Tor…"', (tester) async {
      await torIn(EmbeddedTorState.starting);
      await pumpHome(
        tester,
        overrides: [priceProvider.overrideWith(_CachedPriceNotifier.new)],
      );

      expect(find.text(_connecting), findsOneWidget);
      expect(find.textContaining('prices paused since'), findsNothing);
      expect(find.text(_retry), findsNothing);
      expect(find.text('Re-check'), findsNothing);
      expect(find.textContaining('Updated'), findsNothing);
      expect(_orbotStrings(tester), isEmpty);

      releaseHeldStart();
      await tester.pumpAndSettle();
    });

    testWidgets('starting with status unavailable still reads "Connecting to '
        'Tor…" (R3)', (tester) async {
      await torIn(EmbeddedTorState.starting);
      await pumpHome(
        tester,
        overrides: [
          priceProvider.overrideWith(_CachedPriceNotifier.new),
          routeStatusProvider.overrideWith(_UnavailableStatus.new),
        ],
      );

      expect(find.text(_connecting), findsOneWidget);
      expect(find.textContaining(_rowFailedPrefix), findsNothing);
      expect(_orbotStrings(tester), isEmpty);

      releaseHeldStart();
      await tester.pumpAndSettle();
    });

    testWidgets('failed: "Tor couldn\'t connect — prices paused since HH:mm" '
        '+ Retry; Retry restarts Tor and refreshes once, when ready', (
      tester,
    ) async {
      await torIn(EmbeddedTorState.failed);
      await pumpHome(
        tester,
        overrides: [priceProvider.overrideWith(_CachedPriceNotifier.new)],
      );

      expect(
        find.textContaining(RegExp('^$_rowFailedPrefix \\d\\d:\\d\\d\$')),
        findsOneWidget,
      );
      expect(find.text(_retry), findsOneWidget);
      expect(find.text('Re-check'), findsNothing);
      expect(_orbotStrings(tester), isEmpty);
      expect(backend.startCalls, 1);

      backend.hold = Completer<void>();
      await tester.tap(find.text(_retry));
      await tester.pumpAndSettle();
      expect(backend.startCalls, 2);
      expect(find.text(_connecting), findsOneWidget);
      // Nothing refreshed yet: Tor isn't ready.
      expect(_CachedPriceNotifier.forced, 0);

      releaseHeldStart();
      await tester.pumpAndSettle();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(find.text(_connecting), findsNothing);
      expect(find.textContaining(_rowFailedPrefix), findsNothing);
      expect(find.textContaining('Updated'), findsWidgets);
      // Exactly one: the ready transition's. Retry adds none of its own.
      expect(_CachedPriceNotifier.forced, 1);
    });

    testWidgets('ready, then the plugin loses its port: the row and the '
        'status read failed before any failure report (M1)', (tester) async {
      await torIn(EmbeddedTorState.ready);
      await pumpHome(
        tester,
        overrides: [priceProvider.overrideWith(_CachedPriceNotifier.new)],
      );
      expect(find.textContaining('Updated'), findsWidgets);

      // The automatic retry (M2) fails, so failed is what stays.
      backend.failNext = true;
      backend.losePort();
      await tester.pumpAndSettle();

      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(
        find.textContaining(RegExp('^$_rowFailedPrefix \\d\\d:\\d\\d\$')),
        findsOneWidget,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BagApp)),
      );
      expect(
        container.read(routeStatusProvider).valueOrNull,
        RouteStatus.unavailable,
      );
      expect(_orbotStrings(tester), isEmpty);
    });

    testWidgets('ready with nothing cached, then the port is lost: the error '
        'card reads failed (M1)', (tester) async {
      await torIn(EmbeddedTorState.ready);
      await pumpHome(
        tester,
        overrides: [priceProvider.overrideWith(_BlockedPriceNotifier.new)],
      );

      backend.failNext = true;
      backend.losePort();
      await tester.pumpAndSettle();

      expect(find.text(_errorTitle), findsOneWidget);
      expect(find.text(_errorButton), findsOneWidget);
      expect(find.text('Unable to fetch price'), findsNothing);
    });

    testWidgets('ready: the normal row', (tester) async {
      await torIn(EmbeddedTorState.ready);
      await pumpHome(
        tester,
        overrides: [priceProvider.overrideWith(_CachedPriceNotifier.new)],
      );

      expect(find.textContaining('Updated'), findsWidgets);
      expect(find.text(_connecting), findsNothing);
      expect(_orbotStrings(tester), isEmpty);
    });

    testWidgets('failed, nothing cached: the error card, and "Retry Tor" '
        'restarts Tor', (tester) async {
      await torIn(EmbeddedTorState.failed);
      await pumpHome(
        tester,
        overrides: [priceProvider.overrideWith(_BlockedPriceNotifier.new)],
      );

      expect(find.text(_errorTitle), findsOneWidget);
      expect(find.text(_errorBody), findsOneWidget);
      expect(find.text(_errorButton), findsOneWidget);
      expect(find.text('Unable to fetch price'), findsNothing);
      expect(_orbotStrings(tester), isEmpty);

      backend.hold = Completer<void>();
      await tester.tap(find.text(_errorButton));
      await tester.pumpAndSettle();
      expect(backend.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(find.text(_connecting), findsOneWidget);
      expect(find.text(_errorButton), findsNothing);

      releaseHeldStart();
      await tester.pumpAndSettle();
    });

    testWidgets('starting, nothing cached: the error card says connecting, '
        'with nothing to retry', (tester) async {
      await torIn(EmbeddedTorState.starting);
      await pumpHome(
        tester,
        overrides: [priceProvider.overrideWith(_BlockedPriceNotifier.new)],
      );

      expect(find.text(_connecting), findsOneWidget);
      expect(find.text(_connectingBody), findsOneWidget);
      expect(find.textContaining('never fetched over clearnet'), findsNothing);
      // No button at all: not Retry Tor, not the generic Retry.
      expect(find.byType(TextButton), findsNothing);
      expect(find.text(_errorButton), findsNothing);
      expect(find.text('Unable to fetch price'), findsNothing);
      expect(_orbotStrings(tester), isEmpty);

      releaseHeldStart();
      await tester.pumpAndSettle();
    });
  });

  // ── routeUnavailableMessage ────────────────────────────────────────────

  test('routeUnavailableMessage(TorRoute) while not ready', () {
    expect(routeUnavailableMessage(const TorRoute()), _notReady);
  });

  test('routeUnavailableMessage(TorRoute): starting says connecting, '
      'failed says it couldn\'t connect (M7)', () async {
    await torIn(EmbeddedTorState.starting);
    expect(routeUnavailableMessage(const TorRoute()), _notReady);
    releaseHeldStart();
    await pumpEventQueue();

    await EmbeddedTorService.stop();
    await torIn(EmbeddedTorState.failed);
    final failed = routeUnavailableMessage(const TorRoute());
    expect(
      failed,
      "Tor couldn't connect. Check your internet connection, then retry.",
    );
    expect(failed, isNot(contains('Orbot')));
    expect(_notReady, isNot(contains('Orbot')));
  });

  // ── Settings: About text and the Pro sheet ─────────────────────────────

  group('Settings and Pro sheet', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1100, 8000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
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
    }

    testWidgets('the About section lists built-in Tor as Pro and never '
        'mentions Orbot (R10)', (tester) async {
      await pumpSettings(tester);

      expect(find.text('Source Code'), findsOneWidget); // About is built
      expect(find.text('Orbot — Tor for Mobile'), findsNothing);
      expect(
        find.textContaining('Pro unlocks watch-only wallet tracking, built-in '
            'Tor routing, custom Esplora node support, Bitcoin Health Check '
            'with privacy scoring, and Sentinel — always-on balance alerts.'),
        findsOneWidget,
      );
      expect(_orbotStrings(tester), isEmpty);
    });

    Future<void> pumpSheet(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1100, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
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
    }

    // Runs on both platforms (the suite does): B3's features list says
    // "Tor built in" on Android too, now that Tor is built in there.
    testWidgets('the Pro sheet sells "Tor built in", not Tor via Orbot '
        '(R10)', (tester) async {
      await pumpSheet(tester);

      expect(find.text('Your own node or proxy'), findsOneWidget);
      expect(find.text('Tor built in'), findsOneWidget);
      expect(find.textContaining('Tor routing via Orbot'), findsNothing);
      expect(find.text('Built-in Tor routing'), findsNothing);
      expect(_orbotStrings(tester), isEmpty);
    });
  });
}
