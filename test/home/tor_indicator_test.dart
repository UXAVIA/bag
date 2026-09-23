/// Regression tests for the Tor-unavailable indicator on the home screen.
///
/// The price cascade answers a dead Orbot with cached data rather than an
/// error — deliberately, so no clearnet request can escape. The cost is that a
/// frozen price is indistinguishable from a live one unless the UI names the
/// cause. These cover both halves of that: the stale-but-showing case and the
/// nothing-cached case, plus the guard that neither leaks to non-Tor users.
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
import 'package:bag/models/price_data.dart';
import 'package:bag/providers/price_provider.dart';
import 'package:bag/providers/tor_status_provider.dart';
import 'package:bag/services/price_service.dart';
import 'package:bag/services/tor_service.dart';

class _UnavailableTorNotifier extends TorStatusNotifier {
  @override
  Future<TorStatus> build() async => TorStatus.unavailable;
}

class _AvailableTorNotifier extends TorStatusNotifier {
  @override
  Future<TorStatus> build() async => TorStatus.available;
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
  Future<PriceData> build() async => throw const TorUnavailableException();
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
    required bool useTor,
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
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overridesForScene(ScreenshotScene.homeWithWallet, prefs: prefs),
          ...overrides,
        ],
        child: const BagApp(onboardingComplete: true, initialLocation: '/'),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 3));
  }

  testWidgets('names Orbot as the cause when a cached price is being served',
      (tester) async {
    await pumpHome(
      tester,
      useTor: true,
      overrides: [
        priceProvider.overrideWith(_CachedPriceNotifier.new),
        torStatusProvider.overrideWith(_UnavailableTorNotifier.new),
      ],
    );

    expect(find.textContaining('Orbot not detected'), findsOneWidget);
    expect(find.textContaining('prices paused since'), findsOneWidget);
    // The generic wording would leave the user hunting their connection.
    expect(find.textContaining('Stale data'), findsNothing);
    expect(find.text('Re-check'), findsOneWidget);
  });

  testWidgets('explains the empty state when there is no cached price',
      (tester) async {
    await pumpHome(
      tester,
      useTor: true,
      overrides: [
        priceProvider.overrideWith(_TorBlockedPriceNotifier.new),
        torStatusProvider.overrideWith(_UnavailableTorNotifier.new),
      ],
    );

    expect(find.text('Orbot not detected'), findsOneWidget);
    expect(find.textContaining('never fetched over clearnet'), findsOneWidget);
    expect(find.text('Re-check Orbot'), findsOneWidget);
    // Blaming the network here would point the user at the wrong thing: the
    // app declined to make the request.
    expect(find.text('Unable to fetch price'), findsNothing);
  });

  testWidgets('stays out of the way when Tor is switched off', (tester) async {
    await pumpHome(
      tester,
      useTor: false,
      overrides: [
        priceProvider.overrideWith(_CachedPriceNotifier.new),
        // Unavailable on purpose: with Tor off it is irrelevant and must not
        // reach the UI, since nothing is being blocked.
        torStatusProvider.overrideWith(_UnavailableTorNotifier.new),
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
        torStatusProvider.overrideWith(_AvailableTorNotifier.new),
      ],
    );

    expect(find.textContaining('Orbot'), findsNothing);
    expect(find.textContaining('Updated'), findsWidgets);
  });
}
