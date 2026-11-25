import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/app.dart';
import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/mock/mock_providers.dart';
import 'package:bag/mock/scenes.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/network_settings.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/services/network/route_gate.dart';

import 'fake_proxies.dart';

/// The custom-explorer Test and Save buttons talk to the user's own node,
/// whose address identifies them. With Tor not ready they must not even try:
/// a fresh probe refuses them first and names Tor as the reason. (The
/// routing layer would refuse the request too — the built-in client's port
/// is -1 until it is ready — so [TargetServer] counting no hit is the second
/// guard, not the one under test.)
void main() {
  late TargetServer target;
  final probed = <NetworkRoute>[];

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Real sockets: the binding's HttpOverrides would answer every request
    // with a canned 400 and hide a leak.
    HttpOverrides.global = null;
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

  tearDown(() {
    RouteGate.debugProbeOverride = null;
    RouteGate.invalidateCache();
    probed.clear();
  });

  Future<ProviderContainer> pumpPrivacyScreen(WidgetTester tester) async {
    target = (await tester.runAsync(TargetServer.start))!;
    addTearDown(() => tester.runAsync(target.close));
    RouteGate.debugProbeOverride = (route) async {
      probed.add(route);
      return RouteStatus.unavailable;
    };

    tester.view.physicalSize = const Size(1100, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues({
      AppConstants.keyUseTor: true,
      AppConstants.keyExplorerPreset: ExplorerPreset.custom.index,
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overridesForScene(ScreenshotScene.walletPrivacy, prefs: prefs),
          initialExplorerUrlProvider.overrideWithValue(
            'http://127.0.0.1:${target.port}',
          ),
        ],
        child: const BagApp(
          onboardingComplete: true,
          initialLocation: '/wallets',
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 3));
    return ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
  }

  /// Taps [finder] in the real zone, so the handler's sockets and timers are
  /// real and an ungated request would actually reach [target], then gives
  /// that traffic time to land before settling the UI.
  Future<void> tapForReal(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('Test connection with Tor down never reaches the node', (
    tester,
  ) async {
    await pumpPrivacyScreen(tester);

    final testButton = find.byTooltip('Test connection');
    await tester.ensureVisible(testButton);
    await tapForReal(tester, testButton);

    expect(probed, [const TorRoute()]);
    expect(
      find.text(routeUnavailableMessage(const TorRoute())),
      findsOneWidget,
    );
    expect(target.hits, 0);
  });

  testWidgets('Save with Tor down never reaches the node and saves nothing', (
    tester,
  ) async {
    final container = await pumpPrivacyScreen(tester);
    final saved = container.read(networkSettingsProvider).customUrl;

    final editButton = find.byTooltip('Edit URL');
    await tester.ensureVisible(editButton);
    await tester.tap(editButton);
    await tester.pumpAndSettle();
    // The proxy card above has its own text fields and Save button, so pick
    // the explorer's by its hint, and the last Save (it sits below the card).
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'http://yournode.onion',
      ),
      'http://127.0.0.1:${target.port}/',
    );
    await tapForReal(tester, find.text('Save').last);

    expect(probed, [const TorRoute()]);
    expect(
      find.text(routeUnavailableMessage(const TorRoute())),
      findsOneWidget,
    );
    expect(target.hits, 0);
    expect(container.read(networkSettingsProvider).customUrl, saved);
  });
}
