/// The Wallets tab (Home | Wallets | DCA | Settings) and the routes that moved
/// out of Settings with it.
///
/// Wallet & Privacy, the health check and Sentinel used to live under
/// `/settings`. Anything that still names those paths — a deep link, a
/// screenshot mock — has to land on the new screen, never on a crash or a
/// blank page, including when the router starts cold with the old path as its
/// initial location.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/app.dart';
import 'package:bag/core/theme/app_theme.dart';
import 'package:bag/mock/mock_providers.dart';
import 'package:bag/mock/scenes.dart';
import 'package:bag/services/sentinel_service.dart';

/// Old location -> where it lives now.
const _legacyToCurrent = <String, String>{
  '/settings/wallet-privacy': '/wallets',
  '/settings/wallet-privacy/health-check': '/wallets/health-check',
  '/settings/sentinel': '/wallets/sentinel',
};

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
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

  // `/wallets/sentinel` exists only where Sentinel does (Android); the
  // router sends iOS to `/wallets` (test/pro/action_locks_test.dart).
  setUp(() => SentinelService.debugIsAndroid = true);
  tearDown(() => SentinelService.debugIsAndroid = null);

  /// Starts the real app (router, shell, bottom bar) on [location] with the
  /// scene mocks, Pro unlocked.
  Future<void> pumpApp(
    WidgetTester tester,
    String location, {
    ScreenshotScene scene = ScreenshotScene.walletPrivacy,
  }) async {
    tester.view.physicalSize = const Size(1100, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: overridesForScene(scene, prefs: prefs),
        child: BagApp(onboardingComplete: true, initialLocation: location),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 3));
  }

  Finder navLabel(String label) => find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  );

  GoRouter routerOf(WidgetTester tester) =>
      GoRouter.of(tester.element(find.byType(NavigationBar)));

  String locationOf(WidgetTester tester) =>
      routerOf(tester).routerDelegate.currentConfiguration.uri.toString();

  /// The screen title in the app bar (the bottom bar also says "Wallets").
  Finder appBarTitle(String title) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(title));

  int selectedTab(WidgetTester tester) =>
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

  group('bottom bar', () {
    testWidgets('has Home, Wallets, DCA, Settings in that order', (
      tester,
    ) async {
      await pumpApp(tester, '/', scene: ScreenshotScene.homeWithWallet);

      final labels = tester
          .widgetList<NavigationDestination>(find.byType(NavigationDestination))
          .map((d) => d.label)
          .toList();
      expect(labels, ['Home', 'Wallets', 'DCA', 'Settings']);
    });

    testWidgets('Wallets uses the wallet icon, primary when selected', (
      tester,
    ) async {
      await pumpApp(tester, '/', scene: ScreenshotScene.homeWithWallet);

      final wallets = tester
          .widgetList<NavigationDestination>(find.byType(NavigationDestination))
          .elementAt(1);
      expect(
        (wallets.icon as Icon).icon,
        Icons.account_balance_wallet_outlined,
      );
      final selected = wallets.selectedIcon! as Icon;
      expect(selected.icon, Icons.account_balance_wallet);
      expect(selected.color, AppColors.primary);
    });

    testWidgets('tapping Wallets shows the Wallets screen at /wallets', (
      tester,
    ) async {
      await pumpApp(tester, '/', scene: ScreenshotScene.homeWithWallet);

      await tester.tap(navLabel('Wallets'));
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(selectedTab(tester), 1);
      expect(appBarTitle('Wallets'), findsOneWidget);
    });

    testWidgets('DCA is index 2 and Settings index 3', (tester) async {
      await pumpApp(tester, '/', scene: ScreenshotScene.homeWithWallet);

      await tester.tap(navLabel('DCA'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/dca');
      expect(selectedTab(tester), 2);

      await tester.tap(navLabel('Settings'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/settings');
      expect(selectedTab(tester), 3);
    });
  });

  group('old paths redirect', () {
    for (final entry in _legacyToCurrent.entries) {
      testWidgets('cold start at ${entry.key} lands on ${entry.value}', (
        tester,
      ) async {
        await pumpApp(
          tester,
          entry.key,
          scene: entry.key.endsWith('sentinel')
              ? ScreenshotScene.sentinelActive
              : ScreenshotScene.healthCheck,
        );

        expect(locationOf(tester), entry.value);
        expect(selectedTab(tester), 1, reason: 'the Wallets tab owns it now');
        expect(tester.takeException(), isNull);
        expect(
          appBarTitle(switch (entry.value) {
            '/wallets' => 'Wallets',
            '/wallets/health-check' => 'Portfolio Health Check',
            _ => 'Sentinel',
          }),
          findsOneWidget,
        );
      });

      testWidgets('going to ${entry.key} while running lands on '
          '${entry.value}', (tester) async {
        await pumpApp(tester, '/', scene: ScreenshotScene.healthCheck);

        routerOf(tester).go(entry.key);
        await tester.pumpAndSettle();

        expect(locationOf(tester), entry.value);
        expect(selectedTab(tester), 1);
        expect(tester.takeException(), isNull);
      });
    }

    test('redirectLegacyLocation maps the three old locations', () {
      for (final entry in _legacyToCurrent.entries) {
        expect(redirectLegacyLocation(Uri.parse(entry.key)), entry.value);
      }
    });

    test('redirectLegacyLocation tolerates a trailing slash and keeps the '
        'query', () {
      expect(
        redirectLegacyLocation(Uri.parse('/settings/wallet-privacy/')),
        '/wallets',
      );
      expect(
        redirectLegacyLocation(
          Uri.parse('/settings/wallet-privacy/health-check?from=notification'),
        ),
        '/wallets/health-check?from=notification',
      );
    });

    test('redirectLegacyLocation leaves every other location alone', () {
      for (final path in [
        '/',
        '/dca',
        '/settings',
        '/wallets',
        '/wallets/health-check',
        '/wallets/sentinel',
        '/unlock',
        '/settings/wallet-privacy-extra',
        '/settings/sentinels',
      ]) {
        expect(redirectLegacyLocation(Uri.parse(path)), isNull, reason: path);
      }
    });
  });

  group('reset to root', () {
    testWidgets('Wallets from /wallets/health-check returns to /wallets', (
      tester,
    ) async {
      await pumpApp(
        tester,
        '/wallets/health-check',
        scene: ScreenshotScene.healthCheck,
      );
      expect(find.text('Portfolio Health Check'), findsWidgets);

      await tester.tap(navLabel('Wallets'));
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(find.text('Portfolio Health Check'), findsNothing);
      expect(appBarTitle('Wallets'), findsOneWidget);
    });

    testWidgets('Wallets from /wallets/sentinel returns to /wallets', (
      tester,
    ) async {
      await pumpApp(
        tester,
        '/wallets/sentinel',
        scene: ScreenshotScene.sentinelActive,
      );
      expect(find.text('Sentinel'), findsWidgets);

      await tester.tap(navLabel('Wallets'));
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(appBarTitle('Wallets'), findsOneWidget);
    });

    testWidgets('leaving Wallets deep and coming back lands on its root', (
      tester,
    ) async {
      await pumpApp(
        tester,
        '/wallets/health-check',
        scene: ScreenshotScene.healthCheck,
      );

      await tester.tap(navLabel('DCA'));
      await tester.pumpAndSettle();
      await tester.tap(navLabel('Wallets'));
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(find.text('Portfolio Health Check'), findsNothing);
    });

    testWidgets('Settings always opens at /settings', (tester) async {
      await pumpApp(
        tester,
        '/wallets/health-check',
        scene: ScreenshotScene.healthCheck,
      );

      await tester.tap(navLabel('Settings'));
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/settings');
      expect(selectedTab(tester), 3);
    });
  });

  group('Android back', () {
    for (final tab in ['Wallets', 'DCA', 'Settings']) {
      testWidgets('from $tab goes Home', (tester) async {
        await pumpApp(tester, '/', scene: ScreenshotScene.homeWithWallet);

        await tester.tap(navLabel(tab));
        await tester.pumpAndSettle();
        expect(selectedTab(tester), isNot(0));

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        expect(locationOf(tester), '/');
        expect(selectedTab(tester), 0);
      });
    }

    testWidgets('from /wallets/health-check goes up to /wallets, then Home', (
      tester,
    ) async {
      await pumpApp(
        tester,
        '/wallets/health-check',
        scene: ScreenshotScene.healthCheck,
      );

      // The first back closes the sub-screen, as everywhere else on Android.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/wallets');
      expect(selectedTab(tester), 1);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/');
      expect(selectedTab(tester), 0);
    });
  });
}
