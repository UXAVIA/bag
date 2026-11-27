/// Task B3: the Pro sheet leads with what you get.
///
/// The layout is new (a hero figure, the headline, the feature list and a
/// footer with the price, "No subscription", the buy button and restore);
/// the purchase, restore and direct-flavor key logic is the one the sheet
/// always had. The store flavor runs on the host through the sheet's test
/// seams (`debugProSheetFlavor`, `debugProSheetStore`) with a fake store
/// that implements the IAP stub, the same surface CI swaps for
/// `package:in_app_purchase`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// url_launcher's platform seam; url_launcher depends on it and doesn't
// re-export it.
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:bag/core/iap/iap.dart';
import 'package:bag/core/theme/app_theme.dart';
import 'package:bag/features/settings/presentation/pro_upgrade_sheet.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/services/sentinel_service.dart';

// The copy, exactly as in the B3 brief (fee body per ruling R-B3c).
const _caption = 'What Bag Pro adds up for you';
const _routeLabels = ['Your phone', 'Three Tor relays', 'Explorer'];
const _title = 'Your real balance, looked up privately';
const _body =
    "Add your wallet's public key once. Bag keeps the balance current on its "
    'own, and every lookup goes through Tor built into Bag.';
const _watchOnly = (
  'Watch-only wallets',
  'Single-sig, multisig and Bitkey, from a public key or descriptor. '
      'Read-only: Bag can never spend.',
);
const _tor = (
  'Tor built in',
  'Wallet and price lookups go through Tor inside Bag. No other app to '
      'install.',
);
const _health = (
  'Bitcoin Health Check',
  'A privacy score for your coins, with what to fix first.',
);
const _sentinel = (
  'Sentinel',
  'A notification the moment a payment touches one of your wallets.',
);
const _node = (
  'Your own node or proxy',
  'Point Bag at your own Esplora server, or route through your SOCKS5 or '
      'HTTP proxy.',
);
const _fees = (
  'Fee estimates and alerts',
  'Mempool fees on the home screen, and a ping when they reach your target.',
);
/// On iPhone Sentinel runs as Sentinel Lite, in the background refresh
/// (spec D9), with its own honest line.
const _sentinelLite = (
  'Sentinel Lite',
  'Alerts when a payment touches one of your wallets, checked in the '
      'background when iOS allows.',
);
const _iosFeatures = [_watchOnly, _tor, _health, _sentinelLite, _node, _fees];
const _androidFeatures = [_watchOnly, _tor, _health, _sentinel, _node, _fees];

const _noSubscription = 'No subscription';
const _oneTime = 'One-time purchase';
const _loading = 'Loading…';
const _restore = 'Restore purchase';
const _restoreIos = 'Restores on any device with your Apple ID';
const _restoreAndroid = 'Restores on any phone with your Google account';
const _thanks = 'Pro unlocked — thank you!';

Finder get _sheet => find.byKey(proUpgradeSheetKey);

/// A store that implements the IAP stub's surface and records what the sheet
/// asks of it. [hold] keeps the product query pending until it completes.
class _FakeStore implements InAppPurchase {
  _FakeStore({
    this.available = true,
    this.products = const [],
    this.notFound = const [],
  });

  bool available;
  List<ProductDetails> products;
  List<String> notFound;
  Completer<void>? hold;
  Completer<void>? holdBuy;

  /// Thrown by the next buy call, as StoreKit throws a PlatformException
  /// while a transaction is already pending.
  Object? buyThrows;
  int queries = 0;
  int restores = 0;
  final bought = <PurchaseParam>[];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<ProductDetailsResponse> queryProductDetails(
    Set<String> identifiers,
  ) async {
    queries++;
    await hold?.future;
    return ProductDetailsResponse(
      productDetails: products,
      notFoundIDs: notFound,
    );
  }

  @override
  Future<void> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    bought.add(purchaseParam);
    await holdBuy?.future;
    final error = buyThrows;
    buyThrows = null;
    if (error != null) throw error;
  }

  @override
  Future<void> restorePurchases() async => restores++;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => const Stream.empty();
  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {}
}

/// Pro starts locked. [unlock] stands in for the purchase stream reporting a
/// purchase; [verifyAndUnlock] accepts only [validKey].
class _TestPro extends ProUnlockedNotifier {
  static const validKey = 'valid-key';
  final tokens = <String>[];

  @override
  bool build() => false;

  void unlock() => state = true;

  @override
  Future<bool> verifyAndUnlock(String token) async {
    tokens.add(token);
    if (token != validKey) return false;
    state = true;
    return true;
  }
}

class _FakeLauncher extends UrlLauncherPlatform {
  final launched = <String>[];
  final modes = <PreferredLaunchMode>[];

  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> canLaunch(String url) async => true;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    modes.add(options.mode);
    return true;
  }
}

void main() {
  late _TestPro pro;

  setUp(() {
    pro = _TestPro();
  });

  tearDown(() {
    debugProSheetFlavor = null;
    debugProSheetStore = null;
    SentinelService.debugIsAndroid = null;
  });

  /// Opens the sheet on a 390×844 phone. [price] is what
  /// `proPriceProvider` answers.
  Future<void> openSheet(
    WidgetTester tester, {
    String flavor = 'direct',
    _FakeStore? store,
    String? price,
    ThemeData? theme,
    Size size = const Size(390, 844),
    double textScale = 1.0,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    debugProSheetFlavor = flavor;
    debugProSheetStore = store;
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          proUnlockedProvider.overrideWith(() => pro),
          proPriceProvider.overrideWith((ref) async => price),
        ],
        child: MaterialApp(
          theme: theme ?? AppTheme.dark,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showProUpgradeSheet(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder inSheet(Finder finder) =>
      find.descendant(of: _sheet, matching: finder);

  /// The feature titles and bodies, top to bottom.
  List<(String, String)> features(WidgetTester tester) {
    final all = [..._androidFeatures, _sentinelLite];
    final shown = [
      for (final f in all)
        if (tester.any(inSheet(find.text(f.$1)))) f,
    ];
    for (final f in shown) {
      expect(inSheet(find.text(f.$2)), findsOneWidget, reason: f.$1);
    }
    shown.sort(
      (a, b) => tester
          .getTopLeft(inSheet(find.text(a.$1)))
          .dy
          .compareTo(tester.getTopLeft(inSheet(find.text(b.$1))).dy),
    );
    return shown;
  }

  /// The one button whose semantics label (or tooltip, for an icon button)
  /// is [label]: flagged as a button, tappable when [enabled], with a tap
  /// target of at least 48×48 (Android's guideline, stricter than 44).
  void expectButton(WidgetTester tester, String label, {bool enabled = true}) {
    final nodes = find.semantics
        .byPredicate((node) {
          if (node.isMergedIntoParent) return false;
          final data = node.getSemanticsData();
          return data.label == label || data.tooltip == label;
        })
        .evaluate()
        .toList();
    expect(nodes, hasLength(1), reason: label);
    final data = nodes.single.getSemanticsData();
    expect(data.flagsCollection.isButton, isTrue, reason: label);
    expect(data.hasAction(SemanticsAction.tap), enabled, reason: label);
    final size = nodes.single.rect.size;
    expect(size.width, greaterThanOrEqualTo(48), reason: '$label: $size');
    expect(size.height, greaterThanOrEqualTo(48), reason: '$label: $size');
  }

  // ── Header, figure and features ─────────────────────────────────────────

  group('header and figure', () {
    testWidgets('the figure, the headline and the body, verbatim', (
      tester,
    ) async {
      await openSheet(tester);

      for (final text in [_caption, ..._routeLabels, _title, _body]) {
        expect(inSheet(find.text(text)), findsOneWidget, reason: text);
      }
      // Three wallet rows adding up to the total.
      for (final text in [
        'Bitkey',
        'Coldcard',
        'Kraken',
        '0.5000',
        '0.2100',
        '0.0424',
        '\$71,482',
        '0.7524 BTC',
      ]) {
        expect(
          inSheet(find.textContaining(text, findRichText: true)),
          findsWidgets,
          reason: text,
        );
      }
      // The figure leads, then the headline, then the body.
      final y = [
        _caption,
        _title,
        _body,
      ].map((t) => tester.getTopLeft(inSheet(find.text(t))).dy).toList();
      expect(y, orderedEquals([...y]..sort()));
      // The old header is gone.
      expect(inSheet(find.text('Bag Pro')), findsNothing);
    });

    testWidgets('the figure is real widgets: no image asset, no network', (
      tester,
    ) async {
      await openSheet(tester);

      expect(inSheet(find.byType(Image)), findsNothing);
      // The route reads as one sentence to a screen reader.
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(
          'Your phone connects to the block explorer through three Tor '
          'relays',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('the headline is a semantics header', (tester) async {
      await openSheet(tester);
      final handle = tester.ensureSemantics();
      final data = tester.getSemantics(find.text(_title)).getSemanticsData();
      expect(data.flagsCollection.isHeader, isTrue);
      handle.dispose();
    });
  });

  group('features', () {
    testWidgets('iOS: six features, Sentinel Lite after the Health Check', (
      tester,
    ) async {
      SentinelService.debugIsAndroid = false;
      await openSheet(tester);

      expect(features(tester), _iosFeatures);
      expect(inSheet(find.text(_sentinel.$2)), findsNothing);
    });

    testWidgets('Android: six features, Sentinel after the Health Check', (
      tester,
    ) async {
      SentinelService.debugIsAndroid = true;
      await openSheet(tester);

      expect(features(tester), _androidFeatures);
    });

    testWidgets('no old feature copy is left (R-B3c "reach", no Orbot)', (
      tester,
    ) async {
      SentinelService.debugIsAndroid = true;
      await openSheet(tester);

      for (final old in [
        'drop to your target',
        'Watch-only wallet tracking',
        'Built-in Tor routing',
        'Tor routing via Orbot',
        'Custom Esplora node support',
        'always-on balance alerts',
        'Network fee estimates',
        'Orbot',
      ]) {
        expect(
          inSheet(find.textContaining(old, findRichText: true)),
          findsNothing,
          reason: old,
        );
      }
    });
  });

  // ── Store flavor ─────────────────────────────────────────────────────────

  group('store flavor', () {
    testWidgets('the price comes from ProductDetails.price', (tester) async {
      final store = _FakeStore(products: [ProductDetails(price: '£6.99')]);
      await openSheet(tester, flavor: 'store', store: store);

      expect(store.queries, 1);
      expect(inSheet(find.text('£6.99 once')), findsOneWidget);
      expect(inSheet(find.text(_noSubscription)), findsOneWidget);
      expect(inSheet(find.text('Unlock Pro for £6.99')), findsOneWidget);
      expect(inSheet(find.text(_restore)), findsOneWidget);
      // Nothing from the direct flavor's purchase path; the key entry is
      // there, collapsed.
      expect(inSheet(find.text('Buy Pro')), findsNothing);
      expect(inSheet(find.text('Already have a key?')), findsOneWidget);
      expect(inSheet(find.byType(TextField)), findsNothing);
    });

    testWidgets('while the product loads: Loading…, and the price line falls '
        'back to "One-time purchase"', (tester) async {
      final store = _FakeStore(products: [ProductDetails(price: '\$7.99')])
        ..hold = Completer<void>();
      await openSheet(tester, flavor: 'store', store: store);

      expect(inSheet(find.text(_oneTime)), findsOneWidget);
      expect(inSheet(find.text(_noSubscription)), findsOneWidget);
      final handle = tester.ensureSemantics();
      expectButton(tester, _loading, enabled: false);
      handle.dispose();
      expect(inSheet(find.textContaining('Unlock Pro')), findsNothing);

      store.hold!.complete();
      await tester.pumpAndSettle();
      expect(inSheet(find.text('\$7.99 once')), findsOneWidget);
      expect(inSheet(find.text('Unlock Pro for \$7.99')), findsOneWidget);
      expect(inSheet(find.text(_oneTime)), findsNothing);
    });

    testWidgets('while the product loads, a known proPriceProvider price '
        'already shows; the button keeps Loading…', (tester) async {
      final store = _FakeStore(products: [ProductDetails(price: '\$7.99')])
        ..hold = Completer<void>();
      await openSheet(tester, flavor: 'store', store: store, price: '\$7.99');

      expect(inSheet(find.text('\$7.99 once')), findsOneWidget);
      expect(inSheet(find.text(_loading)), findsOneWidget);
      store.hold!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('store unavailable: the existing error and Retry, then the '
        'button once the store answers', (tester) async {
      final store = _FakeStore(
        available: false,
        products: [ProductDetails(price: '\$7.99')],
      );
      await openSheet(tester, flavor: 'store', store: store);

      expect(
        inSheet(
          find.text('App Store unavailable. Check your device settings.'),
        ),
        findsOneWidget,
      );
      expect(inSheet(find.text(_oneTime)), findsOneWidget);
      expect(inSheet(find.text(_noSubscription)), findsOneWidget);
      expect(inSheet(find.textContaining('Unlock Pro')), findsNothing);
      expect(inSheet(find.text(_restore)), findsOneWidget);
      final handle = tester.ensureSemantics();
      expectButton(tester, 'Retry');
      handle.dispose();

      store.available = true;
      await tester.tap(inSheet(find.text('Retry')));
      await tester.pumpAndSettle();
      expect(inSheet(find.text('Unlock Pro for \$7.99')), findsOneWidget);
      expect(inSheet(find.text('Retry')), findsNothing);
    });

    testWidgets('product not found: the existing error and Retry', (
      tester,
    ) async {
      final store = _FakeStore(notFound: ['bag_pro']);
      await openSheet(tester, flavor: 'store', store: store);

      expect(inSheet(find.text('Product not found (bag_pro)')), findsOneWidget);
      expect(inSheet(find.text('Retry')), findsOneWidget);
      expect(inSheet(find.text(_oneTime)), findsOneWidget);
    });

    testWidgets(
      'iOS: the restore note names the Apple ID',
      (tester) async {
        final store = _FakeStore(products: [ProductDetails(price: '\$7.99')]);
        await openSheet(tester, flavor: 'store', store: store);

        expect(inSheet(find.text(_restoreIos)), findsOneWidget);
        expect(inSheet(find.text(_restoreAndroid)), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'Android: the restore note names the Google account',
      (tester) async {
        final store = _FakeStore(products: [ProductDetails(price: '\$7.99')]);
        await openSheet(tester, flavor: 'store', store: store);

        expect(inSheet(find.text(_restoreAndroid)), findsOneWidget);
        expect(inSheet(find.text(_restoreIos)), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets('Restore purchase asks the store to restore', (tester) async {
      final store = _FakeStore(products: [ProductDetails(price: '\$7.99')]);
      await openSheet(tester, flavor: 'store', store: store);

      await tester.tap(inSheet(find.text(_restore)));
      await tester.pump();
      expect(store.restores, 1);
    });

    testWidgets('buying: the button buys this product, waits, and the '
        'purchase closes the sheet with the thank-you snackbar', (
      tester,
    ) async {
      final product = ProductDetails(price: '\$7.99');
      final store = _FakeStore(products: [product])
        ..holdBuy = Completer<void>();
      await openSheet(tester, flavor: 'store', store: store);

      await tester.tap(inSheet(find.text('Unlock Pro for \$7.99')));
      await tester.pump();
      expect(store.bought, hasLength(1));
      expect(store.bought.single.productDetails, same(product));
      // Pending: a spinner, and the button can't be pressed twice.
      expect(inSheet(find.byType(CircularProgressIndicator)), findsOneWidget);
      final handle = tester.ensureSemantics();
      expectButton(tester, 'Unlock Pro for \$7.99', enabled: false);
      handle.dispose();
      await tester.tap(inSheet(find.text('Unlock Pro for \$7.99')));
      await tester.pump();
      expect(store.bought, hasLength(1));

      store.holdBuy!.complete();
      await tester.pump();
      expect(inSheet(find.byType(CircularProgressIndicator)), findsNothing);

      // The purchase stream reports the purchase; the notifier unlocks.
      pro.unlock();
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
      expect(find.text(_thanks), findsOneWidget);
    });

    testWidgets('an empty store price reads "Unlock Pro" and "One-time '
        'purchase"', (tester) async {
      final store = _FakeStore(products: [ProductDetails(price: '')]);
      await openSheet(tester, flavor: 'store', store: store);

      expect(inSheet(find.text('Unlock Pro')), findsOneWidget);
      expect(inSheet(find.text(_oneTime)), findsOneWidget);
      expect(inSheet(find.textContaining('Unlock Pro for')), findsNothing);
    });

    testWidgets('a buy call that throws: the button comes back from pending, '
        'the error line says so, and Retry brings the button back', (
      tester,
    ) async {
      final store = _FakeStore(products: [ProductDetails(price: '\$7.99')])
        ..buyThrows = PlatformException(
          code: 'storekit_duplicate_product_object',
          message: 'There is a pending transaction for the same product.',
        );
      await openSheet(tester, flavor: 'store', store: store);

      await tester.tap(inSheet(find.text('Unlock Pro for \$7.99')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(store.bought, hasLength(1));
      expect(inSheet(find.byType(CircularProgressIndicator)), findsNothing);
      expect(
        inSheet(find.text("Couldn't start the purchase. Try again.")),
        findsOneWidget,
      );
      // The store's own message never reaches the screen.
      expect(inSheet(find.textContaining('pending transaction')), findsNothing);
      expect(inSheet(find.text('Retry')), findsOneWidget);
      expect(inSheet(find.text(_restore)), findsOneWidget);

      await tester.tap(inSheet(find.text('Retry')));
      await tester.pumpAndSettle();
      await tester.tap(inSheet(find.text('Unlock Pro for \$7.99')));
      await tester.pumpAndSettle();
      expect(store.bought, hasLength(2));
      expect(
        inSheet(find.text("Couldn't start the purchase. Try again.")),
        findsNothing,
      );
    });

    testWidgets('every button is labelled and at least 48×48', (tester) async {
      SentinelService.debugIsAndroid = true;
      final store = _FakeStore(products: [ProductDetails(price: '\$7.99')]);
      await openSheet(tester, flavor: 'store', store: store);

      final handle = tester.ensureSemantics();
      for (final label in ['Unlock Pro for \$7.99', _restore, 'Close']) {
        expectButton(tester, label);
      }
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  });

  // ── Direct flavor ────────────────────────────────────────────────────────

  group('direct flavor', () {
    testWidgets('Buy Pro and the key entry; no store price, no restore', (
      tester,
    ) async {
      final store = _FakeStore(products: [ProductDetails(price: '\$7.99')]);
      await openSheet(tester, store: store);

      // The same header, figure and features as the store flavor.
      for (final text in [_caption, _title, _body, _watchOnly.$1, _fees.$1]) {
        expect(inSheet(find.text(text)), findsOneWidget, reason: text);
      }
      expect(inSheet(find.text(_oneTime)), findsOneWidget);
      expect(inSheet(find.text(_noSubscription)), findsOneWidget);
      expect(inSheet(find.text('Buy Pro')), findsOneWidget);
      expect(inSheet(find.text('Already have a key?')), findsOneWidget);
      for (final text in [_restore, _restoreIos, _restoreAndroid, _loading]) {
        expect(inSheet(find.text(text)), findsNothing, reason: text);
      }
      expect(inSheet(find.textContaining('Unlock Pro')), findsNothing);
      // The direct flavor never asks the store.
      expect(store.queries, 0);
    });

    testWidgets('Buy Pro opens bitbag.app/pro', (tester) async {
      final launcher = _FakeLauncher();
      final previous = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() => UrlLauncherPlatform.instance = previous);
      await openSheet(tester);

      await tester.tap(inSheet(find.text('Buy Pro')));
      await tester.pump();
      expect(launcher.launched, ['https://bitbag.app/pro']);
      expect(launcher.modes, [PreferredLaunchMode.externalApplication]);
    });

    testWidgets('a valid key unlocks, closes the sheet and thanks the user', (
      tester,
    ) async {
      await openSheet(tester);

      expect(inSheet(find.byType(TextField)), findsNothing);
      await tester.tap(inSheet(find.text('Already have a key?')));
      await tester.pumpAndSettle();
      await tester.enterText(inSheet(find.byType(TextField)), 'wrong');
      await tester.tap(inSheet(find.text('Verify key')));
      await tester.pumpAndSettle();
      expect(
        inSheet(find.text('Invalid key. Check for typos or contact support.')),
        findsOneWidget,
      );

      await tester.enterText(
        inSheet(find.byType(TextField)),
        _TestPro.validKey,
      );
      await tester.tap(inSheet(find.text('Verify key')));
      await tester.pumpAndSettle();
      expect(pro.tokens, ['wrong', _TestPro.validKey]);
      expect(_sheet, findsNothing);
      expect(find.text(_thanks), findsOneWidget);
    });

    testWidgets('a paste that answers after the sheet closed does nothing', (
      tester,
    ) async {
      final clipboard = Completer<Map<String, dynamic>?>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? clipboard.future : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await openSheet(tester);
      await tester.tap(inSheet(find.text('Already have a key?')));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Paste from clipboard'));
      await tester.pump();
      Navigator.of(tester.element(_sheet)).pop();
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);

      clipboard.complete({'text': _TestPro.validKey});
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('every button is labelled and at least 48×48, key entry '
        'open', (tester) async {
      await openSheet(tester);
      await tester.tap(inSheet(find.text('Already have a key?')));
      await tester.pumpAndSettle();

      final handle = tester.ensureSemantics();
      for (final label in [
        'Buy Pro',
        'Already have a key?',
        'Verify key',
        'Paste from clipboard',
        'Close',
      ]) {
        expectButton(tester, label);
      }
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  });

  // ── Closing, themes, text scale ─────────────────────────────────────────

  group('store flavor key entry', () {
    testWidgets('Already have a key? sits under Restore purchase and opens '
        'the field with Verify key', (tester) async {
      final store = _FakeStore(products: [ProductDetails(price: '\$7.99')]);
      await openSheet(tester, flavor: 'store', store: store);

      final restoreY = tester.getTopLeft(inSheet(find.text(_restore))).dy;
      final keyY = tester.getTopLeft(inSheet(find.text('Already have a key?'))).dy;
      expect(keyY, greaterThan(restoreY));
      expect(inSheet(find.byType(TextField)), findsNothing);

      await tester.tap(inSheet(find.text('Already have a key?')));
      await tester.pumpAndSettle();
      expect(inSheet(find.byType(TextField)), findsOneWidget);
      expect(inSheet(find.text('Verify key')), findsOneWidget);
    });

    testWidgets('names no website and no Bitcoin, before and after '
        'expanding', (tester) async {
      final store = _FakeStore(products: [ProductDetails(price: '\$7.99')]);
      await openSheet(tester, flavor: 'store', store: store);
      final banned = RegExp('bitbag|Bitcoin|BTC|OpenNode', caseSensitive: false);
      // The feature list is the sheet's own pitch; only the footer is checked.
      Finder footer() => inSheet(find.textContaining(banned));
      final before = footer().evaluate().length;

      await tester.tap(inSheet(find.text('Already have a key?')));
      await tester.pumpAndSettle();
      await tester.enterText(inSheet(find.byType(TextField)), 'wrong');
      await tester.tap(inSheet(find.text('Verify key')));
      await tester.pumpAndSettle();

      expect(footer().evaluate().length, before);
      expect(inSheet(find.text('Invalid key. Check for typos.')), findsOneWidget);
      expect(
        inSheet(find.textContaining('contact support')),
        findsNothing,
      );
      // No hint or tooltip names the site either.
      expect(find.textContaining('bitbag.app'), findsNothing);
    });

    testWidgets('a valid key closes the sheet and turns Pro on', (
      tester,
    ) async {
      final store = _FakeStore(products: [ProductDetails(price: '\$7.99')]);
      await openSheet(tester, flavor: 'store', store: store);

      await tester.tap(inSheet(find.text('Already have a key?')));
      await tester.pumpAndSettle();
      await tester.enterText(
        inSheet(find.byType(TextField)),
        _TestPro.validKey,
      );
      await tester.tap(inSheet(find.text('Verify key')));
      await tester.pumpAndSettle();
      expect(pro.tokens, [_TestPro.validKey]);
      expect(_sheet, findsNothing);
      expect(find.text(_thanks), findsOneWidget);
    });
  });

  group('layout', () {
    testWidgets('Close dismisses the sheet', (tester) async {
      await openSheet(tester);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
    });

    testWidgets('the footer stays put while the features scroll', (
      tester,
    ) async {
      SentinelService.debugIsAndroid = true;
      final store = _FakeStore(products: [ProductDetails(price: '\$7.99')]);
      await openSheet(
        tester,
        flavor: 'store',
        store: store,
        size: const Size(360, 640),
      );

      final button = inSheet(find.text('Unlock Pro for \$7.99'));
      final before = tester.getTopLeft(button);
      // Scroll the body (dragging on the figure, which is on screen) to its
      // end.
      await tester.drag(inSheet(find.text(_caption)), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(button), before);
      // The last feature scrolled into view above the footer.
      expect(
        tester.getBottomLeft(inSheet(find.text(_fees.$2))).dy,
        lessThanOrEqualTo(
          tester.getTopLeft(inSheet(find.text('\$7.99 once'))).dy,
        ),
      );
      expect(
        tester.getTopLeft(inSheet(find.text(_fees.$2))).dy,
        greaterThan(0),
      );
    });

    // Every state with its own text, in both themes, on a screen tall
    // enough that nothing is scrolled out of view.
    for (final (name, theme) in [
      ('dark', AppTheme.dark),
      ('light', AppTheme.light),
    ]) {
      for (final state in ['loaded', 'store unavailable', 'direct key open']) {
        testWidgets('$name, $state: text contrast meets the guideline', (
          tester,
        ) async {
          final store = _FakeStore(
            available: state != 'store unavailable',
            products: [ProductDetails(price: '\$7.99')],
          );
          await openSheet(
            tester,
            flavor: state == 'direct key open' ? 'direct' : 'store',
            store: store,
            theme: theme,
            size: const Size(390, 1400),
          );
          if (state == 'direct key open') {
            await tester.tap(inSheet(find.text('Already have a key?')));
            await tester.pumpAndSettle();
            expect(inSheet(find.text('Verify key')), findsOneWidget);
          } else if (state == 'store unavailable') {
            expect(inSheet(find.text('Retry')), findsOneWidget);
          }

          final handle = tester.ensureSemantics();
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          handle.dispose();
        });
      }
    }

    testWidgets('light: the error line is text-coloured with a red error '
        'icon; dark keeps the red text', (tester) async {
      for (final (theme, light) in [
        (AppTheme.light, true),
        (AppTheme.dark, false),
      ]) {
        final store = _FakeStore(available: false);
        await openSheet(tester, flavor: 'store', store: store, theme: theme);

        final cs = theme.colorScheme;
        final text = tester.widget<Text>(
          inSheet(
            find.text('App Store unavailable. Check your device settings.'),
          ),
        );
        expect(text.style?.color, light ? cs.onSurface : cs.error);
        final icons = tester.widgetList<Icon>(
          inSheet(find.byIcon(Icons.error_outline)),
        );
        if (light) {
          expect(icons.single.color, cs.error);
        } else {
          expect(icons, isEmpty);
        }
        Navigator.of(tester.element(_sheet)).pop();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('keyboard up at 1.5×: the footer takes the room, and Verify '
        'key sits fully above the keyboard', (tester) async {
      const screen = Size(412, 915);
      const keyboard = 320.0;
      await openSheet(tester, size: screen, textScale: 1.5, keyboard: keyboard);
      await tester.tap(inSheet(find.text('Already have a key?')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final verify = tester.getRect(
        find.ancestor(
          of: inSheet(find.text('Verify key')),
          matching: find.byType(OutlinedButton),
        ),
      );
      final buy = tester.getRect(
        find.ancestor(
          of: inSheet(find.text('Buy Pro')),
          matching: find.byType(FilledButton),
        ),
      );
      expect(verify.bottom, lessThanOrEqualTo(screen.height - keyboard));
      expect(verify.height, greaterThanOrEqualTo(48));
      // The footer fits whole: nothing in it is scrolled away.
      final footer = tester.state<ScrollableState>(
        find.ancestor(
          of: inSheet(find.text('Buy Pro')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(footer.position.maxScrollExtent, 0);
      expect(buy.height, greaterThanOrEqualTo(52));
    });

    for (final scale in [1.5, 2.0]) {
      testWidgets('text scale $scale: no overflow in either flavor', (
        tester,
      ) async {
        SentinelService.debugIsAndroid = true;
        final store = _FakeStore(products: [ProductDetails(price: '\$7.99')]);
        await openSheet(
          tester,
          flavor: 'store',
          store: store,
          size: const Size(360, 640),
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        expect(inSheet(find.text('Unlock Pro for \$7.99')), findsOneWidget);
        Navigator.of(tester.element(_sheet)).pop();
        await tester.pumpAndSettle();

        debugProSheetFlavor = 'direct';
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(inSheet(find.text('Already have a key?')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(inSheet(find.text('Verify key')), findsOneWidget);
      });
    }
  });

  // ── CI import swap (R-B3b) ───────────────────────────────────────────────

  group('CI import swap', () {
    const path = 'lib/features/settings/presentation/pro_upgrade_sheet.dart';
    const stubImport = "import '../../../core/iap/iap.dart';";

    test('the sheet imports the IAP stub exactly as CI\'s sed expects', () {
      final lines = File(path).readAsLinesSync();
      expect(lines.where((l) => l == stubImport), hasLength(1));
      // Nothing else in the file names the stub, or the sed would rewrite it.
      expect(lines.where((l) => l.contains('core/iap/')), hasLength(1));

      // What CI's sed (s|../../../core/iap/iap.dart|package:...|) produces.
      final swapped = lines
          .map(
            (l) => l.replaceFirst(
              RegExp(r'../../../core/iap/iap.dart'),
              'package:in_app_purchase/in_app_purchase.dart',
            ),
          )
          .toList();
      expect(
        swapped.where(
          (l) => l == "import 'package:in_app_purchase/in_app_purchase.dart';",
        ),
        hasLength(1),
      );
      expect(swapped.where((l) => l.contains('core/iap/')), isEmpty);
    });

    test('both release jobs still swap the sheet\'s import', () {
      final workflow = File('.github/workflows/release.yml');
      if (!workflow.existsSync()) {
        markTestSkipped('.github is stripped from the public snapshot');
        return;
      }
      final swaps = workflow
          .readAsLinesSync()
          .where(
            (l) =>
                l.contains(
                  's|../../../core/iap/iap.dart|'
                  'package:in_app_purchase/in_app_purchase.dart|',
                ) &&
                l.trim().endsWith(path),
          )
          .toList();
      expect(swaps, hasLength(2)); // build-aab and build-ipa
    });
  });
}
