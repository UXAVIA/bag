/// Task B4: the "Let Bag read your wallet" card on Home.
///
/// A free user who types their amount in is the one who gains most from a
/// watch-only wallet, so Home offers it once, directly below the net-worth
/// card. The card shows only to a free user with no wallets of any kind
/// (watch-only or typed in) who hasn't dismissed it (ruling R-B4c), and
/// "Not now" writes its pref before the card goes, so it never comes back.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/app.dart';
import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/core/theme/app_theme.dart';
import 'package:bag/features/home/presentation/home_wallet_card.dart';
import 'package:bag/features/wallets/presentation/wallets_pitch_card.dart';
import 'package:bag/mock/mock_data.dart';
import 'package:bag/mock/mock_providers.dart';
import 'package:bag/mock/scenes.dart';
import 'package:bag/models/portfolio.dart';
import 'package:bag/models/price_data.dart';
import 'package:bag/models/wallet_entry.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/portfolio_provider.dart';
import 'package:bag/providers/price_provider.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/providers/wallets_provider.dart';
import 'package:bag/widgets/net_worth_card.dart';

// The copy, exactly as in the B4 brief.
const _title = 'Let Bag read your wallet';
const _body =
    'Paste your Bitkey, hardware wallet or multisig public key. Your balance '
    'updates by itself instead of you typing it in.';
const _add = 'Add a wallet';
const _notNow = 'Not now';
const _footnote = 'Part of Bag Pro · read-only, Bag can never spend';

Finder get card => find.byType(HomeWalletCard);
Finder get title => find.text(_title);

const _manual = WalletEntry(
  id: 'manual-kraken',
  label: 'Kraken',
  kind: WalletKind.manual,
  lastSats: 4240000,
);

class _TestPro extends ProUnlockedNotifier {
  _TestPro(this._initial);
  final bool _initial;

  @override
  bool build() => _initial;

  void set(bool value) => state = value;
}

class _FixedWallets extends WalletsNotifier {
  _FixedWallets(this._wallets);
  final List<WalletEntry> _wallets;

  @override
  List<WalletEntry> build() => _wallets;
}

/// Prices that never arrive: Home's loading layout.
class _LoadingPrice extends PriceNotifier {
  @override
  Future<PriceData> build() => Completer<PriceData>().future;
}

/// Prices that fail with nothing cached: Home's error layout.
class _FailingPrice extends PriceNotifier {
  @override
  Future<PriceData> build() async => throw Exception('offline');
}

/// Prefs whose write of the dismissed flag fails: `setBool` answers false,
/// or throws when [throws]. Only what the card touches is implemented.
class _FailingPrefs implements SharedPreferences {
  _FailingPrefs({this.throws = false});
  final bool throws;
  int writes = 0;

  @override
  bool? getBool(String key) => null;

  @override
  Future<bool> setBool(String key, bool value) async {
    writes++;
    if (throws) throw Exception('disk full');
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixedPortfolio extends PortfolioNotifier {
  _FixedPortfolio(this._amount);
  final double _amount;

  @override
  Portfolio build() => Portfolio(
    btcAmount: _amount,
    selectedCurrencies: const ['usd', 'eur', 'gbp'],
  );
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

  /// Starts the real app on Home. [amount] null keeps the scene's holding.
  Future<(ProviderContainer, SharedPreferences, _TestPro)> pumpHome(
    WidgetTester tester, {
    bool pro = false,
    List<WalletEntry> wallets = const [],
    double? amount,
    Map<String, Object> prefs = const {},
    List<Override> overrides = const [],
    bool settle = true,
  }) async {
    tester.view.physicalSize = const Size(1100, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(prefs);
    final sp = await SharedPreferences.getInstance();
    final proNotifier = _TestPro(pro);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overridesForScene(ScreenshotScene.settingsProLocked, prefs: sp),
          initialProxyConfigProvider.overrideWithValue(null),
          proUnlockedProvider.overrideWith(() => proNotifier),
          walletsProvider.overrideWith(() => _FixedWallets(wallets)),
          if (amount != null)
            portfolioProvider.overrideWith(() => _FixedPortfolio(amount)),
          ...overrides,
        ],
        child: const BagApp(onboardingComplete: true, initialLocation: '/'),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle(const Duration(seconds: 3));
    } else {
      // A spinner never settles: let the router and the first frames run.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    final container = ProviderScope.containerOf(
      tester.element(find.byType(NavigationBar)),
    );
    return (container, sp, proNotifier);
  }

  String locationOf(WidgetTester tester) => GoRouter.of(
    tester.element(find.byType(NavigationBar)),
  ).routerDelegate.currentConfiguration.last.matchedLocation;

  group('who sees it', () {
    testWidgets('a free user with no wallets sees it, with its copy', (
      tester,
    ) async {
      await pumpHome(tester);

      expect(card, findsOneWidget);
      for (final text in [_title, _body, _add, _notNow, _footnote]) {
        expect(
          find.descendant(of: card, matching: find.text(text)),
          findsOneWidget,
          reason: text,
        );
      }
    });

    testWidgets('it sits directly below the net-worth cards, above the '
        'chart', (tester) async {
      await pumpHome(tester);

      final cards = find.byType(NetWorthCard);
      expect(cards, findsWidgets);
      final lastCardBottom = tester
          .widgetList(cards)
          .map((w) => tester.getBottomLeft(find.byWidget(w)).dy)
          .reduce((a, b) => a > b ? a : b);
      final top = tester.getTopLeft(card).dy;
      expect(top, greaterThanOrEqualTo(lastCardBottom));
      // Nothing else fits in between: the gap is the list's own spacing.
      expect(top - lastCardBottom, lessThanOrEqualTo(20));
      expect(
        tester.getBottomLeft(card).dy,
        lessThan(tester.getTopLeft(find.text('PRICE CHART')).dy),
      );
    });

    testWidgets('without an amount it sits below the set-up prompt', (
      tester,
    ) async {
      await pumpHome(tester, amount: 0);

      final prompt = find.text('Set up your portfolio');
      expect(prompt, findsOneWidget);
      expect(card, findsOneWidget);
      expect(
        tester.getTopLeft(card).dy,
        greaterThan(tester.getBottomLeft(prompt).dy),
      );
      expect(
        tester.getBottomLeft(card).dy,
        lessThan(tester.getTopLeft(find.text('PRICE CHART')).dy),
      );
    });

    testWidgets('loading layout: below the loading cards, above the chart '
        '(M5)', (tester) async {
      await pumpHome(
        tester,
        settle: false,
        overrides: [priceProvider.overrideWith(_LoadingPrice.new)],
      );

      expect(find.byType(NetWorthCard), findsNothing);
      expect(card, findsOneWidget);
      expect(
        tester.getBottomLeft(card).dy,
        lessThan(tester.getTopLeft(find.text('PRICE CHART')).dy),
      );
    });

    testWidgets('error layout: below the error card, above the chart (M5)', (
      tester,
    ) async {
      await pumpHome(
        tester,
        overrides: [priceProvider.overrideWith(_FailingPrice.new)],
      );

      final error = find.text('Unable to fetch price');
      expect(error, findsOneWidget);
      expect(card, findsOneWidget);
      expect(
        tester.getTopLeft(card).dy,
        greaterThan(tester.getBottomLeft(error).dy),
      );
      expect(
        tester.getBottomLeft(card).dy,
        lessThan(tester.getTopLeft(find.text('PRICE CHART')).dy),
      );
    });

    testWidgets('Pro: no card', (tester) async {
      await pumpHome(tester, pro: true);
      expect(card, findsNothing);
      expect(title, findsNothing);
    });

    testWidgets('a watch-only wallet: no card', (tester) async {
      await pumpHome(tester, wallets: [mockWallet]);
      expect(title, findsNothing);
    });

    testWidgets('a typed-in balance: no card', (tester) async {
      await pumpHome(tester, wallets: [_manual]);
      expect(title, findsNothing);
    });

    testWidgets('dismissed before: no card', (tester) async {
      await pumpHome(
        tester,
        prefs: {AppConstants.keyHomeWalletCardDismissed: true},
      );
      expect(title, findsNothing);
    });

    testWidgets('Pro arriving hides it at once', (tester) async {
      final (_, _, pro) = await pumpHome(tester);
      expect(title, findsOneWidget);

      pro.set(true);
      await tester.pumpAndSettle();

      expect(title, findsNothing);
    });
  });

  group('actions', () {
    testWidgets('Add a wallet opens /wallets (the pitch, for a free user)', (
      tester,
    ) async {
      await pumpHome(tester);

      await tester.tap(find.text(_add));
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(find.byType(WalletsPitchCard), findsOneWidget);
    });

    testWidgets('Not now writes the pref before the card goes, and the card '
        'stays gone on the next launch', (tester) async {
      final (container, sp, _) = await pumpHome(tester);

      // What the pref said at the moment the card was hidden.
      final prefAtHide = <bool?>[];
      container.listen<bool>(homeWalletCardDismissedProvider, (_, hidden) {
        if (hidden) {
          prefAtHide.add(
            container
                .read(sharedPreferencesProvider)
                .getBool(AppConstants.keyHomeWalletCardDismissed),
          );
        }
      });

      await tester.tap(find.text(_notNow));
      await tester.pumpAndSettle();

      expect(title, findsNothing);
      expect(prefAtHide, [true]);
      expect(sp.getBool(AppConstants.keyHomeWalletCardDismissed), isTrue);
      expect(locationOf(tester), '/');

      // A fresh start with what was stored.
      await tester.pumpWidget(const SizedBox());
      await pumpHome(
        tester,
        prefs: {AppConstants.keyHomeWalletCardDismissed: true},
      );
      expect(title, findsNothing);
    });
  });

  group('a failed write (M4)', () {
    for (final throws in [false, true]) {
      testWidgets('setBool ${throws ? 'throws' : 'answers false'}: the card '
          'stays, nothing escapes', (tester) async {
        final prefs = _FailingPrefs(throws: throws);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              proUnlockedProvider.overrideWith(() => _TestPro(false)),
              walletsProvider.overrideWith(() => _FixedWallets(const [])),
            ],
            child: MaterialApp(
              theme: AppTheme.dark,
              // Home's rule for showing the card.
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) =>
                      ref.watch(showHomeWalletCardProvider)
                      ? const HomeWalletCard()
                      : const SizedBox(),
                ),
              ),
            ),
          ),
        );
        expect(title, findsOneWidget);

        await tester.tap(find.text(_notNow));
        await tester.pumpAndSettle();

        expect(prefs.writes, 1);
        expect(tester.takeException(), isNull);
        expect(title, findsOneWidget);
      });
    }
  });

  group('look', () {
    /// The card alone, on a phone-width screen.
    Future<void> pumpCard(
      WidgetTester tester, {
      ThemeData? theme,
      double textScale = 1.0,
      Size size = const Size(390, 844),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final sp = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(sp)],
          child: MaterialApp(
            theme: theme ?? AppTheme.dark,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: HomeWalletCard(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final (name, theme) in [
      ('dark', AppTheme.dark),
      ('light', AppTheme.light),
    ]) {
      for (final scale in [1.0, 1.5]) {
        testWidgets('$name, ${scale}x: text contrast meets the guideline', (
          tester,
        ) async {
          final handle = tester.ensureSemantics();
          await pumpCard(tester, theme: theme, textScale: scale);
          expect(title, findsOneWidget);
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          handle.dispose();
        });
      }

      testWidgets('$name: surface and text colours come from the colour '
          'scheme', (tester) async {
        await pumpCard(tester, theme: theme);
        final cs = theme.colorScheme;

        final box = tester.widget<Container>(
          find.descendant(of: card, matching: find.byType(Container)).first,
        );
        expect((box.decoration! as BoxDecoration).color, cs.surface);
        expect(tester.widget<Text>(title).style?.color, cs.onSurface);
        expect(
          tester.widget<Text>(find.text(_footnote)).style?.color,
          cs.secondary,
        );
        final notNow = tester.widget<TextButton>(
          find.ancestor(
            of: find.text(_notNow),
            matching: find.byType(TextButton),
          ),
        );
        expect(notNow.style?.foregroundColor?.resolve({}), cs.secondary);
        final add = tester.widget<FilledButton>(
          find.ancestor(
            of: find.text(_add),
            matching: find.byType(FilledButton),
          ),
        );
        expect(add.style?.backgroundColor?.resolve({}), cs.primary);
        expect(add.style?.foregroundColor?.resolve({}), cs.onPrimary);
      });
    }

    testWidgets('buttons are labelled, flagged as buttons and at least 48 px', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCard(tester);

      for (final label in [_add, _notNow]) {
        final node = tester.getSemantics(find.text(label));
        expect(
          node,
          isSemantics(label: label, isButton: true, hasTapAction: true),
          reason: label,
        );
        expect(node.rect.height, greaterThanOrEqualTo(48), reason: label);
        expect(node.rect.width, greaterThanOrEqualTo(48), reason: label);
      }
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('the title is a header; the icon is not read out', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCard(tester);

      expect(
        tester.getSemantics(title),
        isSemantics(label: _title, isHeader: true),
      );
      expect(
        find.descendant(
          of: card,
          matching: find.byWidgetPredicate(
            (w) => w is Icon && w.semanticLabel != null,
          ),
        ),
        findsNothing,
      );
      handle.dispose();
    });

    testWidgets('2x text on a 320 px phone: no overflow', (tester) async {
      await pumpCard(tester, textScale: 2.0, size: const Size(320, 568));
      expect(tester.takeException(), isNull);
      expect(find.text(_notNow), findsOneWidget);
    });
  });
}
