/// Regression tests for the Tor-unavailable indicator on the home screen.
///
/// The price cascade answers a Tor client that isn't connected with cached
/// data rather than an error — deliberately, so no clearnet request can
/// escape. The cost is that a frozen price is indistinguishable from a live
/// one unless the UI names the cause. These cover both halves of that: the
/// stale-but-showing case and the nothing-cached case, plus the guard that
/// neither leaks to non-Tor users. Tor is built in on both platforms, so the
/// Tor cases run with `TorService.debugIsIOS` true and false; the client is
/// never started here (`off`), which on `TorRoute` reads as "couldn't
/// connect".
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/app.dart';
import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/mock/mock_data.dart';
import 'package:bag/mock/mock_providers.dart';
import 'package:bag/mock/scenes.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/price_data.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/price_provider.dart';
import 'package:bag/providers/route_status_provider.dart';
import 'package:bag/services/price_service.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/services/tor_service.dart';

class _UnavailableTorNotifier extends RouteStatusNotifier {
  @override
  Future<RouteStatus> build() async => RouteStatus.unavailable;
}

class _AvailableTorNotifier extends RouteStatusNotifier {
  @override
  Future<RouteStatus> build() async => RouteStatus.available;
}

/// Serves cached data, exactly as the real cascade does when the Tor gate
/// trips and a cached price exists.
class _CachedPriceNotifier extends PriceNotifier {
  @override
  Future<PriceData> build() async => mockPriceData;
}

/// The no-cache path: [PriceService.fetchCurrentPrice] rethrows once there is
/// nothing to fall back on.
class _TorBlockedPriceNotifier extends PriceNotifier {
  @override
  Future<PriceData> build() async => throw const RouteUnavailableException();
}

/// Counts forced refreshes, so a test can tell a re-check that pulled prices
/// from one that only flipped the badge.
class _RecordingPriceNotifier extends PriceNotifier {
  static int forced = 0;

  @override
  Future<PriceData> build() async => mockPriceData;

  @override
  Future<void> refresh({bool force = false}) async {
    if (force) forced++;
  }
}

/// Down on the first probe (build), back on every later one (recheck).
class _RecoveringStatusNotifier extends RouteStatusNotifier {
  @override
  Future<RouteStatus> build() async => RouteStatus.unavailable;

  @override
  Future<void> recheck() async {
    state = const AsyncValue.data(RouteStatus.available);
  }
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/local_auth'),
      (call) async {
        if (call.method == 'isDeviceSupported') return true;
        if (call.method == 'isAvailable') return true;
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('app.bitbag/widget'),
      (call) async => call.method == 'getSdkVersion' ? 31 : null,
    );
  });

  /// Pumps the home screen with the scene mocks, then layers the Tor/price
  /// state this test cares about on top. A tall surface keeps the whole page
  /// laid out so the last-updated row — which sits below the chart — is built.
  Future<void> pumpHome(
    WidgetTester tester, {
    bool useTor = false,
    bool useProxy = false,
    ProxyConfig? proxy,
    required List<Override> overrides,
  }) async {
    tester.view.physicalSize = const Size(1100, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues({
      if (useTor) AppConstants.keyUseTor: true,
      if (useProxy) AppConstants.keyUseProxy: true,
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overridesForScene(ScreenshotScene.homeWithWallet, prefs: prefs),
          initialProxyConfigProvider.overrideWithValue(proxy),
          ...overrides,
        ],
        child: const BagApp(onboardingComplete: true, initialLocation: '/'),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 3));
  }

  for (final ios in [true, false]) {
    final platform = ios ? 'iOS' : 'Android';

    testWidgets('$platform: names Tor as the cause when a cached price is '
        'being served', (tester) async {
      TorService.debugIsIOS = ios;
      addTearDown(() => TorService.debugIsIOS = null);
      await pumpHome(
        tester,
        useTor: true,
        overrides: [
          priceProvider.overrideWith(_CachedPriceNotifier.new),
          routeStatusProvider.overrideWith(_UnavailableTorNotifier.new),
        ],
      );

      expect(
        find.textContaining("Tor couldn't connect — prices paused since"),
        findsOneWidget,
      );
      // The generic wording would leave the user hunting their connection.
      expect(find.textContaining('Stale data'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.textContaining('Orbot'), findsNothing);
    });

    testWidgets('$platform: explains the empty state when there is no cached '
        'price', (tester) async {
      TorService.debugIsIOS = ios;
      addTearDown(() => TorService.debugIsIOS = null);
      await pumpHome(
        tester,
        useTor: true,
        overrides: [
          priceProvider.overrideWith(_TorBlockedPriceNotifier.new),
          routeStatusProvider.overrideWith(_UnavailableTorNotifier.new),
        ],
      );

      expect(find.text("Tor couldn't connect"), findsOneWidget);
      expect(
        find.text('Check your internet connection, then retry.'),
        findsOneWidget,
      );
      expect(find.text('Retry Tor'), findsOneWidget);
      expect(find.textContaining('Orbot'), findsNothing);
      // Blaming the network here would point the user at the wrong thing: the
      // app declined to make the request.
      expect(find.text('Unable to fetch price'), findsNothing);
    });
  }

  testWidgets('stays out of the way when Tor is switched off', (tester) async {
    await pumpHome(
      tester,
      useTor: false,
      overrides: [
        priceProvider.overrideWith(_CachedPriceNotifier.new),
        // Unavailable on purpose: with Tor off it is irrelevant and must not
        // reach the UI, since nothing is being blocked.
        routeStatusProvider.overrideWith(_UnavailableTorNotifier.new),
      ],
    );

    expect(find.textContaining('Orbot'), findsNothing);
    expect(find.textContaining('Updated'), findsWidgets);
  });

  testWidgets('shows the normal row when Tor is on and working',
      (tester) async {
    await pumpHome(
      tester,
      useTor: true,
      overrides: [
        priceProvider.overrideWith(_CachedPriceNotifier.new),
        routeStatusProvider.overrideWith(_AvailableTorNotifier.new),
      ],
    );

    expect(find.textContaining('Orbot'), findsNothing);
    expect(find.textContaining('Updated'), findsWidgets);
  });

  group('proxy', () {
    const proxy = ProxyConfig(
      type: ProxyType.socks5,
      host: '10.0.0.5',
      port: 1080,
    );

    // None of these may reach a Tor or direct user.
    void expectNoProxyCopy() {
      expect(find.textContaining('Proxy'), findsNothing);
      expect(find.textContaining('proxy'), findsNothing);
    }

    testWidgets('names the proxy in the row when a cached price is served',
        (tester) async {
      await pumpHome(
        tester,
        useProxy: true,
        proxy: proxy,
        overrides: [
          priceProvider.overrideWith(_CachedPriceNotifier.new),
          routeStatusProvider.overrideWith(_UnavailableTorNotifier.new),
        ],
      );

      expect(find.textContaining('Proxy unreachable — prices paused since'),
          findsOneWidget);
      expect(find.textContaining('Orbot'), findsNothing);
      expect(find.textContaining('Stale data'), findsNothing);
      expect(find.text('Re-check'), findsOneWidget);
    });

    testWidgets('names the proxy in the empty state when nothing is cached',
        (tester) async {
      await pumpHome(
        tester,
        useProxy: true,
        proxy: proxy,
        overrides: [
          priceProvider.overrideWith(_TorBlockedPriceNotifier.new),
          routeStatusProvider.overrideWith(_UnavailableTorNotifier.new),
        ],
      );

      expect(find.text('Proxy unreachable'), findsOneWidget);
      expect(find.text('Check your proxy is running, then re-check.'),
          findsOneWidget);
      expect(find.text('Re-check proxy'), findsOneWidget);
      expect(find.textContaining('Orbot'), findsNothing);
      expect(find.text('Unable to fetch price'), findsNothing);
    });

    testWidgets('an unreadable proxy config says so in the row',
        (tester) async {
      await pumpHome(
        tester,
        useProxy: true, // enabled, but no config: MisconfiguredProxyRoute
        overrides: [
          priceProvider.overrideWith(_CachedPriceNotifier.new),
          routeStatusProvider.overrideWith(_UnavailableTorNotifier.new),
        ],
      );

      expect(
          find.textContaining('Proxy settings unreadable — prices paused since'),
          findsOneWidget);
      expect(find.textContaining('Orbot'), findsNothing);
    });

    testWidgets('an unreadable proxy config says so in the empty state',
        (tester) async {
      await pumpHome(
        tester,
        useProxy: true,
        overrides: [
          priceProvider.overrideWith(_TorBlockedPriceNotifier.new),
          routeStatusProvider.overrideWith(_UnavailableTorNotifier.new),
        ],
      );

      expect(find.text('Proxy settings unreadable'), findsOneWidget);
      expect(find.text('Re-enter your proxy in Wallets → Network.'), findsOneWidget);
      expect(find.text('Re-check proxy'), findsOneWidget);
      expect(find.textContaining('Orbot'), findsNothing);
    });

    testWidgets('Tor users never see proxy copy', (tester) async {
      await pumpHome(
        tester,
        useTor: true,
        overrides: [
          priceProvider.overrideWith(_CachedPriceNotifier.new),
          routeStatusProvider.overrideWith(_UnavailableTorNotifier.new),
        ],
      );

      expect(
        find.textContaining("Tor couldn't connect — prices paused since"),
        findsOneWidget,
      );
      expectNoProxyCopy();
    });

    testWidgets('direct users never see proxy copy', (tester) async {
      await pumpHome(
        tester,
        overrides: [
          priceProvider.overrideWith(_CachedPriceNotifier.new),
          // Unavailable on purpose: irrelevant on a direct route.
          routeStatusProvider.overrideWith(_UnavailableTorNotifier.new),
        ],
      );

      expectNoProxyCopy();
      expect(find.textContaining('Orbot'), findsNothing);
      expect(find.textContaining('Updated'), findsWidgets);
    });

    testWidgets('re-check force-refreshes once the proxy is back',
        (tester) async {
      _RecordingPriceNotifier.forced = 0;
      await pumpHome(
        tester,
        useProxy: true,
        proxy: proxy,
        overrides: [
          priceProvider.overrideWith(_RecordingPriceNotifier.new),
          routeStatusProvider.overrideWith(_RecoveringStatusNotifier.new),
        ],
      );
      expect(find.textContaining('Proxy unreachable'), findsOneWidget);
      expect(_RecordingPriceNotifier.forced, 0);

      await tester.tap(find.text('Re-check'));
      await tester.pumpAndSettle(const Duration(seconds: 3));

      expect(_RecordingPriceNotifier.forced, 1);
      expect(find.textContaining('Proxy unreachable'), findsNothing);
    });
  });
}
