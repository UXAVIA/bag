/// Task B4: "How do you hold your bitcoin?" as onboarding's second page.
///
/// The answer picks the route through onboarding (ruling R-B4d):
/// - an exchange: the amount page, then currencies;
/// - a hardware wallet or a multisig: the Pro sheet (closing it continues,
///   and so does buying), then the amount page, then currencies;
/// - just the price: currencies.
///
/// The answer is kept in memory only and written nowhere (M-12: nothing
/// read it, and it labels the user as a self-custodian in plaintext); the
/// `onboarding_holding` key earlier builds wrote is deleted at launch. Skip
/// completes onboarding exactly as before, and Android back steps back
/// through the pages without skipping the question.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/app.dart';
import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/core/iap/iap.dart';
import 'package:bag/core/theme/app_theme.dart';
import 'package:bag/features/onboarding/presentation/onboarding_screen.dart';
import 'package:bag/services/retired_prefs.dart';
import 'package:bag/features/settings/presentation/pro_upgrade_sheet.dart';
import 'package:bag/mock/mock_providers.dart';
import 'package:bag/mock/scenes.dart';
import 'package:bag/models/portfolio.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/portfolio_provider.dart';
import 'package:bag/providers/purchase_provider.dart';

// The copy, exactly as in the B4 brief.
const _title = 'How do you hold your bitcoin?';
const _body =
    'Pick the closest one. It decides how Bag finds your balance, and you can '
    'change it later.';
const _options = <(String, String, String)>[
  (
    'exchange',
    'On an exchange',
    'Coinbase, Kraken, Strike and the like. You type your amount.',
  ),
  (
    'hardware',
    'On a hardware wallet',
    'Bitkey, Coldcard, Trezor, Ledger, Jade',
  ),
  (
    'multisig',
    'In a multisig',
    '2-of-3 or more, set up in Bitkey, Sparrow or Nunchuk',
  ),
  ('price', 'I just follow the price', 'No amount for now'),
];
const _exchange = 'On an exchange';
const _hardware = 'On a hardware wallet';
const _multisig = 'In a multisig';
const _price = 'I just follow the price';
const _note =
    "Bag can read the balance straight from your wallet's public key, so you "
    "never type it in. That's part of Bag Pro. Next we'll show you what it "
    'includes.';

// The pages around it, unchanged.
const _welcomeTitle = 'Your Bitcoin net worth,\nalways in view.';
const _amountTitle = 'How much Bitcoin\ndo you own?';
const _currencyTitle = 'Choose your\ndisplay currencies';
const _later = "I'll set this later";

// The amount page's old Pro teaser card, removed in fix round 0: the pitch
// lives in the Pro sheet and the home wallet card now.
const _oldTeaserTitle = 'Go Pro for full privacy';
const _oldTeaserBody =
    'Watch-only wallet · Tor routing · Custom node · Privacy health check';

Finder get _proSheet => find.byKey(proUpgradeSheetKey);

/// Pro, settable. [verifyAndUnlock] accepts only [validToken], as the
/// website's signed token would verify.
class _TestPro extends ProUnlockedNotifier {
  _TestPro([this._initial = false]);
  final bool _initial;

  static const validToken = 'valid-token';

  @override
  bool build() => _initial;

  void set(bool value) => state = value;

  @override
  Future<bool> verifyAndUnlock(String token) async {
    if (token != validToken) return false;
    state = true;
    return true;
  }
}

/// Records what onboarding saves instead of writing secure storage.
class _RecordingPortfolio extends PortfolioNotifier {
  double? savedAmount;
  List<String>? savedCurrencies;

  @override
  Portfolio build() => Portfolio(
    btcAmount: 0,
    selectedCurrencies: List.of(AppConstants.defaultCurrencies),
  );

  @override
  Future<void> setBtcAmount(double amount) async {
    savedAmount = amount;
    state = state.copyWith(btcAmount: amount);
  }

  @override
  Future<void> setCurrencies(List<String> currencies) async {
    savedCurrencies = currencies;
    state = state.copyWith(selectedCurrencies: currencies);
  }
}

/// A store for the store-flavor sheet: it has the product, and buying is
/// reported through the Pro notifier, as the purchase stream would.
class _FakeStore implements InAppPurchase {
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<ProductDetailsResponse> queryProductDetails(
    Set<String> identifiers,
  ) async =>
      ProductDetailsResponse(productDetails: [ProductDetails(price: '\$7.99')]);
  @override
  Future<void> buyNonConsumable({required PurchaseParam purchaseParam}) async {}
  @override
  Future<void> restorePurchases() async {}
  @override
  Stream<List<PurchaseDetails>> get purchaseStream => const Stream.empty();
  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {}
}

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

  late _TestPro pro;
  late _RecordingPortfolio portfolio;
  late SharedPreferences prefs;
  late GoRouter router;

  tearDown(() {
    debugProSheetFlavor = null;
    debugProSheetStore = null;
  });

  /// Starts the real app on `/onboarding`, as a first launch does, or on
  /// [location]. [proAtStart] is Pro at start (a reinstall whose purchase was
  /// restored); [done] marks onboarding as already completed.
  Future<void> pumpOnboarding(
    WidgetTester tester, {
    String? themeMode,
    double textScale = 1.0,
    Size size = const Size(390, 844),
    bool proAtStart = false,
    bool done = false,
    String location = '/onboarding',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({
      if (themeMode != null) AppConstants.keyThemeMode: themeMode,
      if (done) AppConstants.keyOnboardingComplete: true,
    });
    prefs = await SharedPreferences.getInstance();
    pro = _TestPro(proAtStart);
    portfolio = _RecordingPortfolio();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overridesForScene(ScreenshotScene.onboarding, prefs: prefs),
          initialProxyConfigProvider.overrideWithValue(null),
          proUnlockedProvider.overrideWith(() => pro),
          portfolioProvider.overrideWith(() => portfolio),
        ],
        child: BagApp(onboardingComplete: done, initialLocation: location),
      ),
    );
    await tester.pumpAndSettle();
    router = GoRouter.of(tester.element(find.byType(Navigator).first));
  }

  String location() => router.routerDelegate.currentConfiguration.uri.path;

  Future<void> tapText(WidgetTester tester, String text) async {
    final finder = find.text(text);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Lets the "Pro unlocked" snackbar time out: it floats over the bottom
  /// button and would take the next tap.
  Future<void> waitOutSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  Future<void> toQuestion(WidgetTester tester) =>
      tapText(tester, 'Get Started');

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  ElevatedButton continueButton(WidgetTester tester) =>
      tester.widget<ElevatedButton>(
        find.ancestor(
          of: find.text('Continue'),
          matching: find.byType(ElevatedButton),
        ),
      );

  /// Picks [option] and continues past the question.
  Future<void> answer(WidgetTester tester, String option) async {
    await tapText(tester, option);
    await tapText(tester, 'Continue');
  }

  String? stored() => prefs.getString(AppConstants.keyOnboardingHolding);

  bool completed() =>
      prefs.getBool(AppConstants.keyOnboardingComplete) == true &&
      location() == '/';

  group('the question is page 2', () {
    testWidgets('Get Started leads to it, with its copy and four options', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpOnboarding(tester);
      expect(find.text(_welcomeTitle), findsOneWidget);
      expect(find.bySemanticsLabel('Step 1 of 4'), findsOneWidget);

      await toQuestion(tester);

      expect(find.text(_title), findsOneWidget);
      expect(find.text(_body), findsOneWidget);
      for (final (_, title, body) in _options) {
        expect(find.text(title), findsOneWidget, reason: title);
        expect(find.text(body), findsOneWidget, reason: body);
      }
      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text(_note), findsNothing);
      expect(find.bySemanticsLabel('Step 2 of 4'), findsOneWidget);
      // The old Pro teaser page is gone.
      expect(find.text('Take control of your\nBitcoin privacy.'), findsNothing);
      expect(
        tester.getSemantics(find.text(_title)),
        isSemantics(isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('Continue does nothing until an option is picked', (
      tester,
    ) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);

      expect(continueButton(tester).onPressed, isNull);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text(_title), findsOneWidget);
      expect(stored(), isNull);

      await tapText(tester, _exchange);
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('radio semantics: one node per option, title and body; at '
        'most one checked, exactly one once chosen', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpOnboarding(tester);
      await toQuestion(tester);

      SemanticsNode node(String title) => tester.getSemantics(find.text(title));

      final nodes = {for (final (_, t, _) in _options) t: node(t)};
      // Four separate nodes: each option is its own, and its body is in it.
      expect(nodes.values.map((n) => n.id).toSet(), hasLength(4));

      /// The options that are checked, by title.
      List<String> checked() => [
        for (final (_, title, _) in _options)
          if (node(title).getSemanticsData().flagsCollection.isChecked ==
              CheckedState.isTrue)
            title,
      ];

      // At most one checked: nothing is preselected.
      expect(checked(), isEmpty);
      for (final (_, title, body) in _options) {
        expect(
          node(title),
          isSemantics(
            label: '$title\n$body',
            hasCheckedState: true,
            isChecked: false,
            isInMutuallyExclusiveGroup: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
          ),
          reason: title,
        );
        expect(node(body).id, node(title).id, reason: body);
      }

      // Exactly one once chosen: the one tapped last.
      for (final (_, picked, _) in [..._options, _options.first]) {
        await tapText(tester, picked);
        expect(checked(), [picked]);
        for (final (_, title, _) in _options) {
          expect(
            node(title),
            isSemantics(isChecked: title == picked),
            reason: 'picked $picked, checking $title',
          );
        }
      }
      handle.dispose();
    });

    testWidgets('the Pro note shows for a hardware wallet or a multisig only', (
      tester,
    ) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);

      for (final (option, shows) in [
        (_exchange, false),
        (_hardware, true),
        (_price, false),
        (_multisig, true),
      ]) {
        await tapText(tester, option);
        expect(
          find.text(_note),
          shows ? findsOneWidget : findsNothing,
          reason: option,
        );
      }
    });
  });

  group('each answer routes as drawn', () {
    testWidgets('exchange: amount page, then currencies; no Pro sheet', (
      tester,
    ) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);
      await answer(tester, _exchange);

      expect(_proSheet, findsNothing);
      expect(find.text(_amountTitle), findsOneWidget);
      expect(stored(), isNull);

      await tester.enterText(find.byType(TextField), '0.5');
      await tapText(tester, 'Continue');
      expect(find.text(_currencyTitle), findsOneWidget);
      expect(find.text('Skip'), findsNothing);

      await tapText(tester, 'Continue');
      expect(completed(), isTrue);
      expect(portfolio.savedAmount, 0.5);
      expect(portfolio.savedCurrencies, AppConstants.defaultCurrencies);
    });

    testWidgets('hardware: the Pro sheet; closing it continues to the amount '
        'page, which can be left for later', (tester) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);
      await answer(tester, _hardware);

      expect(_proSheet, findsOneWidget);
      expect(stored(), isNull);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(_proSheet, findsNothing);
      expect(find.text(_amountTitle), findsOneWidget);
      expect(find.text(_later), findsOneWidget);

      await tapText(tester, _later);
      expect(find.text(_currencyTitle), findsOneWidget);
      await tapText(tester, 'Continue');
      expect(completed(), isTrue);
      expect(portfolio.savedAmount, 0.0);
    });

    testWidgets('multisig: the Pro sheet; Android back closes it and '
        'continues to the amount page', (tester) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);
      await answer(tester, _multisig);

      expect(_proSheet, findsOneWidget);
      expect(stored(), isNull);

      await back(tester);

      expect(_proSheet, findsNothing);
      expect(find.text(_amountTitle), findsOneWidget);
    });

    testWidgets('hardware: buying in the sheet continues to the amount page', (
      tester,
    ) async {
      debugProSheetFlavor = 'store';
      debugProSheetStore = _FakeStore();
      await pumpOnboarding(tester);
      await toQuestion(tester);
      await answer(tester, _hardware);
      expect(_proSheet, findsOneWidget);

      pro.set(true); // the purchase stream reports the purchase
      await tester.pumpAndSettle();

      expect(_proSheet, findsNothing);
      expect(find.text(_amountTitle), findsOneWidget);
    });

    testWidgets('the amount page pitches no Pro on any route', (tester) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);

      void expectNoTeaser(String route) {
        expect(find.text(_amountTitle), findsOneWidget, reason: route);
        expect(find.text(_oldTeaserTitle), findsNothing, reason: route);
        expect(find.text(_oldTeaserBody), findsNothing, reason: route);
        expect(find.byIcon(Icons.lock_outline), findsNothing, reason: route);
      }

      await answer(tester, _exchange);
      expectNoTeaser('exchange');
      await back(tester);

      for (final route in [_hardware, _multisig]) {
        await answer(tester, route);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expectNoTeaser(route);
        await back(tester);
      }
    });

    testWidgets('price: straight to currencies; no amount page, no Pro sheet', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpOnboarding(tester);
      await toQuestion(tester);
      await tapText(tester, _price);
      // Three steps on this route.
      expect(find.bySemanticsLabel('Step 2 of 3'), findsOneWidget);

      await tapText(tester, 'Continue');

      expect(_proSheet, findsNothing);
      expect(find.text(_amountTitle), findsNothing);
      expect(find.text(_currencyTitle), findsOneWidget);
      expect(find.bySemanticsLabel('Step 3 of 3'), findsOneWidget);
      expect(stored(), isNull);

      await tapText(tester, 'Continue');
      expect(completed(), isTrue);
      expect(portfolio.savedAmount, 0.0);
      handle.dispose();
    });

    testWidgets('price after typing an amount on the exchange route: no '
        'amount is saved', (tester) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);
      await answer(tester, _exchange);
      await tester.enterText(find.byType(TextField), '0.5');
      await back(tester);

      await answer(tester, _price);
      expect(stored(), isNull);
      await tapText(tester, 'Continue');

      expect(completed(), isTrue);
      expect(portfolio.savedAmount, 0.0);
    });

    testWidgets('the answer is written nowhere', (tester) async {
      await pumpOnboarding(tester);
      final before = prefs.getKeys();
      await toQuestion(tester);
      await answer(tester, _hardware);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tapText(tester, _later);
      await tapText(tester, 'Continue');
      expect(completed(), isTrue);

      final holding = [
        for (final key in prefs.getKeys())
          if ('${prefs.get(key)}'.contains('hardware')) key,
      ];
      expect(holding, isEmpty);
      expect(prefs.containsKey(AppConstants.keyOnboardingHolding), isFalse);
      // The flow itself adds only onboarding_complete.
      expect(prefs.getKeys().difference(before), {
        AppConstants.keyOnboardingComplete,
      });
    });
  });

  group('the retired onboarding_holding key (M-12)', () {
    test('is deleted at launch, and nothing else is', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyOnboardingHolding: 'multisig',
        AppConstants.keyOnboardingComplete: true,
      });
      final prefs = await SharedPreferences.getInstance();

      await removeRetiredPrefs(prefs);

      expect(prefs.containsKey(AppConstants.keyOnboardingHolding), isFalse);
      expect(prefs.getBool(AppConstants.keyOnboardingComplete), isTrue);
      // A second launch finds nothing to do.
      await removeRetiredPrefs(prefs);
      expect(prefs.getKeys(), {AppConstants.keyOnboardingComplete});
    });

    test('main() runs it before runApp', () {
      final src = File('lib/main.dart').readAsStringSync();
      final remove = src.indexOf('await removeRetiredPrefs(prefs);');
      expect(remove, greaterThan(0));
      expect(remove, lessThan(src.indexOf('runApp(')));
    });
  });

  group('Skip completes onboarding as before', () {
    testWidgets('on the welcome page', (tester) async {
      await pumpOnboarding(tester);

      await tapText(tester, 'Skip');

      expect(completed(), isTrue);
      expect(portfolio.savedAmount, 0.0);
      expect(portfolio.savedCurrencies, AppConstants.defaultCurrencies);
      expect(stored(), isNull);
    });

    testWidgets('on the question, with an option picked: no Pro sheet, no '
        'stored answer', (tester) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);
      await tapText(tester, _hardware);

      await tapText(tester, 'Skip');

      expect(_proSheet, findsNothing);
      expect(completed(), isTrue);
      expect(stored(), isNull);
    });

    testWidgets('on the amount page, keeping the typed amount', (tester) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);
      await answer(tester, _exchange);
      await tester.enterText(find.byType(TextField), '0.3');

      await tapText(tester, 'Skip');

      expect(completed(), isTrue);
      expect(portfolio.savedAmount, 0.3);
    });
  });

  group('Android back', () {
    testWidgets('steps back through the exchange route', (tester) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);
      await answer(tester, _exchange);
      await tapText(tester, 'Continue');
      expect(find.text(_currencyTitle), findsOneWidget);

      await back(tester);
      expect(find.text(_amountTitle), findsOneWidget);

      await back(tester);
      expect(find.text(_title), findsOneWidget);
      // The answer is kept.
      final handle = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.text(_exchange)),
        isSemantics(isChecked: true),
      );
      handle.dispose();

      await back(tester);
      expect(find.text(_welcomeTitle), findsOneWidget);
      expect(location(), '/onboarding');
    });

    testWidgets('price: from currencies back to the question, not past it', (
      tester,
    ) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);
      await answer(tester, _price);
      expect(find.text(_currencyTitle), findsOneWidget);

      await back(tester);

      expect(find.text(_title), findsOneWidget);
      expect(find.text(_amountTitle), findsNothing);
    });

    testWidgets('hardware: from the amount page back to the question; the '
        'Pro sheet does not reopen', (tester) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);
      await answer(tester, _hardware);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text(_amountTitle), findsOneWidget);

      await back(tester);

      expect(find.text(_title), findsOneWidget);
      expect(_proSheet, findsNothing);
    });

    testWidgets('on the welcome page, back is left to the system', (
      tester,
    ) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpOnboarding(tester);

      await back(tester);

      expect(calls, contains('SystemNavigator.pop'));
      expect(find.text(_welcomeTitle), findsOneWidget);
    });
  });

  group('a user who is already Pro (fix round 1, I1)', () {
    for (final (option, name) in [
      (_hardware, 'hardware'),
      (_multisig, 'multisig'),
    ]) {
      testWidgets('Pro at start, $name: no note, no sheet, straight to the '
          'amount page', (tester) async {
        await pumpOnboarding(tester, proAtStart: true);
        await toQuestion(tester);
        await tapText(tester, option);
        expect(find.text(_note), findsNothing);

        await tapText(tester, 'Continue');

        expect(_proSheet, findsNothing);
        expect(find.text(_amountTitle), findsOneWidget);
        expect(stored(), isNull);
      });
    }

    testWidgets('bought in the sheet, back, Continue: the sheet does not '
        'open again', (tester) async {
      debugProSheetFlavor = 'store';
      debugProSheetStore = _FakeStore();
      await pumpOnboarding(tester);
      await toQuestion(tester);
      await answer(tester, _hardware);
      expect(_proSheet, findsOneWidget);
      pro.set(true); // the purchase stream reports the purchase
      await tester.pumpAndSettle();
      expect(find.text(_amountTitle), findsOneWidget);

      await back(tester);
      expect(find.text(_title), findsOneWidget);
      expect(find.text(_note), findsNothing);
      await waitOutSnackBar(tester);
      await tapText(tester, 'Continue');

      expect(_proSheet, findsNothing);
      expect(find.text(_amountTitle), findsOneWidget);
    });
  });

  testWidgets('Continue tapped twice before anything settles opens one Pro '
      'sheet (M1)', (tester) async {
    await pumpOnboarding(tester);
    await toQuestion(tester);
    await tapText(tester, _hardware);

    // Both taps land before the first one's `await` yields, as when two
    // taps arrive in one pointer packet. (A tap after the sheet's push is
    // absorbed by the Navigator until the next frame anyway.)
    final onPressed = continueButton(tester).onPressed!;
    onPressed();
    onPressed();
    await tester.pumpAndSettle();

    expect(_proSheet, findsOneWidget);
  });

  group('website unlock before onboarding is done (M2)', () {
    testWidgets('a valid token mid-onboarding restarts onboarding, now Pro: '
        'no sheet for a hardware wallet', (tester) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);
      // The App Link arrives (the user paid on bitbag.app/pro).
      router.go('/unlock?token=${_TestPro.validToken}');
      await tester.pumpAndSettle();

      expect(location(), '/onboarding');
      expect(find.text(_welcomeTitle), findsOneWidget);
      expect(find.text('Pro unlocked — thank you!'), findsOneWidget);
      expect(prefs.getBool(AppConstants.keyOnboardingComplete), isNull);

      await waitOutSnackBar(tester);
      await toQuestion(tester);
      await answer(tester, _hardware);
      expect(_proSheet, findsNothing);
      expect(find.text(_amountTitle), findsOneWidget);
    });

    testWidgets('the thank-you stays above Get Started, which takes the tap '
        'while it shows (N2)', (tester) async {
      await pumpOnboarding(tester);
      await toQuestion(tester);
      router.go('/unlock?token=${_TestPro.validToken}');
      await tester.pumpAndSettle();

      final thanks = find.text('Pro unlocked — thank you!');
      final getStarted = find.text('Get Started');
      expect(thanks, findsOneWidget);
      // The snackbar's visible card (its Material), not its margin.
      expect(
        tester
            .getRect(
              find.ancestor(of: thanks, matching: find.byType(Material)).first,
            )
            .bottom,
        lessThanOrEqualTo(
          tester
              .getRect(
                find.ancestor(
                  of: getStarted,
                  matching: find.byType(ElevatedButton),
                ),
              )
              .top,
        ),
      );
      // Get Started is what a tap on it hits, not the snackbar.
      final hits = tester.hitTestOnBinding(tester.getCenter(getStarted)).path;
      final button = tester.renderObject(
        find.ancestor(of: getStarted, matching: find.byType(ElevatedButton)),
      );
      expect(hits.any((entry) => entry.target == button), isTrue);

      await tester.tap(getStarted);
      await tester.pumpAndSettle();
      expect(find.text(_title), findsOneWidget);
    });

    testWidgets('a token that fails also returns to onboarding', (
      tester,
    ) async {
      await pumpOnboarding(tester, location: '/unlock?token=forged');

      expect(location(), '/onboarding');
      expect(
        find.text('Unlock failed: invalid or missing license key.'),
        findsOneWidget,
      );
    });

    testWidgets('after onboarding, a valid token goes Home', (tester) async {
      await pumpOnboarding(
        tester,
        done: true,
        location: '/unlock?token=${_TestPro.validToken}',
      );

      expect(location(), '/');
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.text('Pro unlocked — thank you!'), findsOneWidget);
    });
  });

  group('a deep link to /onboarding once it is done', () {
    test(
      'the redirect: / once onboarding is done, composed with the others',
      () {
        for (final path in ['/onboarding', '/Onboarding/', '/onboarding?x=1']) {
          expect(
            redirectLocation(
              Uri.parse(path),
              proUnlocked: false,
              onboardingComplete: true,
            ),
            '/',
            reason: path,
          );
        }
        expect(
          redirectLocation(
            Uri.parse('/onboarding'),
            proUnlocked: true,
            onboardingComplete: false,
          ),
          isNull,
        );
        expect(
          redirectLocation(
            Uri.parse('/'),
            proUnlocked: false,
            onboardingComplete: true,
          ),
          isNull,
        );
        expect(
          redirectLocation(
            Uri.parse('/settings/sentinel'),
            proUnlocked: false,
            onboardingComplete: true,
          ),
          '/wallets',
        );
      },
    );

    testWidgets('cold start: lands on / and overwrites nothing', (
      tester,
    ) async {
      await pumpOnboarding(tester, done: true);

      expect(location(), '/');
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(portfolio.savedAmount, isNull);
      expect(portfolio.savedCurrencies, isNull);
    });

    testWidgets('mid-session: lands on /', (tester) async {
      await pumpOnboarding(tester, done: true, location: '/');

      router.go('/onboarding');
      await tester.pumpAndSettle();

      expect(location(), '/');
      expect(find.byType(OnboardingScreen), findsNothing);
    });

    testWidgets('Debug "Reset onboarding" still opens it', (tester) async {
      await pumpOnboarding(
        tester,
        done: true,
        location: '/settings',
        size: const Size(390, 4000),
      );

      await tapText(tester, 'Reset');

      expect(location(), '/onboarding');
      expect(find.text(_welcomeTitle), findsOneWidget);
    });
  });

  group('look', () {
    for (final mode in ['dark', 'light']) {
      for (final scale in [1.0, 1.5]) {
        testWidgets('$mode, ${scale}x: text contrast meets the guideline', (
          tester,
        ) async {
          final handle = tester.ensureSemantics();
          await pumpOnboarding(
            tester,
            themeMode: mode,
            textScale: scale,
            size: const Size(390, 1400),
          );
          await toQuestion(tester);
          await tapText(tester, _hardware); // the note shows
          expect(find.text(_note), findsOneWidget);
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          handle.dispose();
        });
      }

      testWidgets('$mode: tiles take their colours from the colour scheme', (
        tester,
      ) async {
        await pumpOnboarding(tester, themeMode: mode);
        await toQuestion(tester);
        await tapText(tester, _hardware);
        final cs =
            (mode == 'dark' ? AppTheme.dark : AppTheme.light).colorScheme;

        Material tile(String title) => tester.widget<Material>(
          find
              .ancestor(of: find.text(title), matching: find.byType(Material))
              .first,
        );
        BorderSide side(String title) =>
            (tile(title).shape! as RoundedRectangleBorder).side;

        expect(tile(_exchange).color, cs.surface);
        expect(side(_exchange).color, cs.outline);
        expect(side(_hardware).color, cs.primary);
        expect(
          tester.widget<Text>(find.text(_options.first.$3)).style?.color,
          cs.secondary,
        );
        expect(
          tester.widget<Text>(find.text(_exchange)).style?.color,
          cs.onSurface,
        );
      });
    }

    for (final mode in ['dark', 'light']) {
      testWidgets('$mode: the unselected radio ring is at least 3:1 against '
          'its tile (M3)', (tester) async {
        await pumpOnboarding(tester, themeMode: mode);
        await toQuestion(tester);
        await tapText(tester, _hardware);

        Finder inTile(String title) => find.descendant(
          of: find
              .ancestor(of: find.text(title), matching: find.byType(Material))
              .first,
          matching: find.byType(AnimatedContainer),
        );
        Color ring(String title) =>
            ((tester.widget<AnimatedContainer>(inTile(title)).decoration!
                            as BoxDecoration)
                        .border!
                    as Border)
                .top
                .color;
        final tile = tester
            .widget<Material>(
              find
                  .ancestor(
                    of: find.text(_exchange),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .color!;

        double contrast(Color a, Color b) {
          final la = a.computeLuminance(), lb = b.computeLuminance();
          return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
        }

        expect(contrast(ring(_exchange), tile), greaterThanOrEqualTo(3.0));
        // The selected ring stays as drawn: Bitcoin orange.
        final cs =
            (mode == 'dark' ? AppTheme.dark : AppTheme.light).colorScheme;
        expect(ring(_hardware), cs.primary);
      });
    }

    testWidgets('tap targets meet the guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpOnboarding(tester);
      await toQuestion(tester);
      await tapText(tester, _multisig);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('2x text on a 320 px phone: no overflow, and Continue is '
        'reachable', (tester) async {
      await pumpOnboarding(tester, textScale: 2.0, size: const Size(320, 568));
      await toQuestion(tester);
      await tapText(tester, _hardware);
      expect(tester.takeException(), isNull);
      await tapText(tester, 'Continue');
      expect(_proSheet, findsOneWidget);
    });
  });
}
