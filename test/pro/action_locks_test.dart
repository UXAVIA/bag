/// Task B2: action-level locks replace `ProGate`.
///
/// A free user sees what Pro includes (the pitch card and the "Also in Pro"
/// rows on the Wallets tab, the Bag Pro row in Settings) and every lock opens
/// the Pro sheet. No Pro control exists in the free layout at all: not dimmed,
/// not overlaid, absent (ruling R-B2a). The router sends a free user who opens
/// a Pro sub-route back to `/wallets` (R-B2b), and the screens behind those
/// routes refuse their Pro actions on their own as well.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// The platform seam the gated storage plugs into; flutter_secure_storage
// depends on it and doesn't re-export it.
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/app.dart';
import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/core/iap/iap.dart';
import 'package:bag/core/theme/app_theme.dart';
import 'package:bag/core/utils/btc_format.dart';
import 'package:bag/features/settings/presentation/pro_upgrade_sheet.dart';
import 'package:bag/features/settings/presentation/proxy_section.dart';
import 'package:bag/features/settings/presentation/sentinel_screen.dart';
import 'package:bag/features/settings/presentation/utxo_inspector_screen.dart';
import 'package:bag/features/wallets/presentation/wallets_pitch_card.dart';
import 'package:bag/features/wallets/presentation/wallets_screen.dart';
import 'package:bag/mock/mock_data.dart';
import 'package:bag/mock/mock_providers.dart';
import 'package:bag/mock/scenes.dart';
import 'package:bag/models/chain_analysis.dart';
import 'package:bag/models/fee_alert.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/network_settings.dart';
import 'package:bag/models/wallet_entry.dart';
import 'package:bag/providers/esplora_client_provider.dart';
import 'package:bag/providers/fee_alerts_provider.dart';
import 'package:bag/providers/fee_settings_provider.dart';
import 'package:bag/providers/health_check_provider.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/portfolio_provider.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/sentinel_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/providers/wallets_provider.dart';
import 'package:bag/services/sentinel_service.dart';
import 'package:bag/services/wallet/esplora_client.dart';
import 'package:bag/services/widget_service.dart';
import 'package:bag/widgets/pro_locked_row.dart';
import 'package:bag/widgets/route_status_pill.dart';
import 'package:bag/widgets/wallet_section.dart';

// The copy, exactly as in the B2 brief.
const _pitchTitle = 'Let Bag read your wallets';
const _pitchBody =
    'Add a public key or multisig descriptor once. Bag keeps every balance '
    'current, and Bag can never spend.';
const _pitchLink = 'See everything Pro includes';
const _alsoInPro = 'Also in Pro';
const _rows = <(String, String)>[
  ('Route through Tor', 'Built in, no other app needed'),
  ('Custom proxy', 'SOCKS5 or HTTP'),
  ('Your own node', 'Any Esplora server, including .onion'),
  ('Bitcoin Health Check', 'A privacy score for your coins'),
];
const _sentinelRow = (
  'Sentinel',
  'Notifies you when a payment touches a wallet',
);
const _lockLabel = 'Locked, part of Pro';
const _bagProBody =
    'Watch-only wallets, Tor built in and a privacy health check.';
const _amountLink = 'Or let Bag read it from your wallet';

/// A widget by its concrete (possibly private) type name. The Tor card and the
/// explorer picker are private to wallets_screen.dart; matching the
/// runtime type pins the real widgets, not just their text.
Finder _byTypeName(String name) => find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == name,
  description: 'widget of type $name',
);

/// Every Pro control the Wallets tab has, by concrete type. None may exist in
/// the free layout.
final _proControls = <String, Finder>{
  'Tor card (_TorSection)': _byTypeName('_TorSection'),
  'proxy card (ProxySection)': find.byType(ProxySection),
  'explorer picker (_ExplorerSelector)': _byTypeName('_ExplorerSelector'),
  'explorer option (_ExplorerTile)': _byTypeName('_ExplorerTile'),
  'add-wallet form (AddWalletForm)': find.byType(AddWalletForm),
  'wallet card (_WalletCard)': _byTypeName('_WalletCard'),
  'wallet menu (_WalletMenu)': _byTypeName('_WalletMenu'),
  'health check card (_PortfolioHealthCard)': _byTypeName(
    '_PortfolioHealthCard',
  ),
  'Sentinel card (_SentinelCard)': _byTypeName('_SentinelCard'),
  'any Switch': find.byType(Switch),
  'any TextField': find.byType(TextField),
};

Finder get _proSheet => find.byKey(proUpgradeSheetKey);

/// Every widget that reacts to a tap or a long press.
final _tapTargets = find.byWidgetPredicate(
  (w) =>
      (w is GestureDetector && (w.onTap != null || w.onLongPress != null)) ||
      (w is InkResponse && (w.onTap != null || w.onLongPress != null)) ||
      (w is ButtonStyleButton &&
          (w.onPressed != null || w.onLongPress != null)),
  description: 'tap or long-press target',
);

bool _hasLongPress(Widget w) => switch (w) {
  GestureDetector(:final onLongPress) => onLongPress != null,
  InkResponse(:final onLongPress) => onLongPress != null,
  ButtonStyleButton(:final onLongPress) => onLongPress != null,
  _ => false,
};

Future<void> _closeProSheet(WidgetTester tester) async {
  Navigator.of(tester.element(_proSheet)).pop();
  await tester.pumpAndSettle();
}

class _FixedPro extends ProUnlockedNotifier {
  _FixedPro(this._value);
  final bool _value;

  @override
  bool build() => _value;
}

/// Records every route/explorer setter, with its argument, instead of
/// running it. The three a free user may call (R-B2g) also update the state,
/// so a switched-off row can disappear; none of them touches storage.
class _RecordingNetworkSettings extends NetworkSettingsNotifier {
  _RecordingNetworkSettings(this.calls);
  final List<String> calls;

  @override
  Future<void> setPreset(ExplorerPreset preset) async {
    calls.add('setPreset(${preset.name})');
    state = state.copyWith(preset: preset);
  }

  @override
  Future<void> setCustomUrl(String url) async => calls.add('setCustomUrl');
  @override
  Future<void> setUseTor(bool value) async {
    calls.add('setUseTor($value)');
    state = state.copyWith(useTor: value);
  }

  @override
  Future<void> setUseProxy(bool value) async {
    calls.add('setUseProxy($value)');
    state = state.copyWith(useProxy: value);
  }

  @override
  Future<void> saveProxy(ProxyConfig config) async => calls.add('saveProxy');
  @override
  Future<void> clearProxy() async => calls.add('clearProxy');
  @override
  Future<void> reloadProxy() async => calls.add('reloadProxy');
}

class _RecordingWallets extends WalletsNotifier {
  _RecordingWallets(this.calls, this._initial);
  final List<String> calls;
  final List<WalletEntry> _initial;

  @override
  List<WalletEntry> build() => _initial;
  @override
  Future<void> addWallet(String zpub, {String? label}) async =>
      calls.add('addWallet');
  @override
  Future<void> addDescriptorWallet(String descriptor, {String? label}) async =>
      calls.add('addDescriptorWallet');
  @override
  Future<void> addManualEntry({required int sats, String? label}) async =>
      calls.add('addManualEntry');
  @override
  Future<void> updateManualEntry(String id, int sats) async =>
      calls.add('updateManualEntry');
  @override
  Future<void> removeWallet(String id) async {
    calls.add('removeWallet($id)');
    state = state.where((w) => w.id != id).toList();
  }

  @override
  Future<void> renameWallet(String id, String label) async =>
      calls.add('renameWallet');
  @override
  Future<void> scan(String id) async => calls.add('scan');
  @override
  Future<void> scanAll() async => calls.add('scanAll');
}

class _RecordingSentinel extends SentinelNotifier {
  _RecordingSentinel(this.calls);
  final List<String> calls;

  @override
  SentinelState build() => const SentinelDisabled();
  @override
  Future<void> enable() async => calls.add('sentinel.enable');
  @override
  Future<void> disable() async => calls.add('sentinel.disable');
}

class _RecordingHealthCheck extends PortfolioHealthCheckNotifier {
  _RecordingHealthCheck(this.calls, this._initial);
  final List<String> calls;
  final HealthCheckState _initial;

  @override
  HealthCheckState build() => _initial;
  @override
  Future<void> run() async => calls.add('healthCheck.run');
  @override
  Future<void> clear() async => calls.add('healthCheck.clear');
}

class _RecordingFeeAlerts extends FeeAlertsNotifier {
  _RecordingFeeAlerts(this.calls);
  final List<String> calls;

  @override
  List<FeeAlert> build() => [];
  @override
  Future<void> add({required double targetRate, required bool above}) async =>
      calls.add('feeAlerts.add');
  @override
  Future<void> delete(String id) async => calls.add('feeAlerts.delete');
  @override
  Future<void> clearFired() async => calls.add('feeAlerts.clearFired');
}

class _RecordingFeeSettings extends FeeSettingsNotifier {
  _RecordingFeeSettings(this.calls);
  final List<String> calls;

  @override
  Future<void> setShowOnHome(bool value) async => calls.add('setShowOnHome');
  @override
  Future<void> setCompact(bool value) async => calls.add('setCompact');
  @override
  Future<void> setShowInWidget(bool value) async =>
      calls.add('setShowInWidget');
}

/// The real WalletsNotifier (its build and listeners), counting the stale
/// rescans instead of running them.
class _StaleScanCounter extends WalletsNotifier {
  int staleScans = 0;

  @override
  Future<void> scanAllIfStale({bool includeRouteBlocked = false}) async =>
      staleScans++;
}

/// In-memory secure storage whose deletes and reads can be held. A held
/// read answers with the value stored when it was issued, as a platform
/// that serves reads and deletes out of order would.
class _GatedSecureStorage extends TestFlutterSecureStoragePlatform {
  _GatedSecureStorage(super.data);

  Completer<void>? _deletes;
  Completer<void>? _reads;
  int pendingReads = 0;

  void holdDeletes() => _deletes = Completer<void>();
  void releaseDeletes() => _deletes?.complete();
  void holdReads() => _reads = Completer<void>();
  void releaseReads() => _reads?.complete();

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    await _deletes?.future;
    data.remove(key);
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    final value = data[key];
    final gate = _reads;
    if (gate != null) {
      pendingReads++;
      await gate.future;
      pendingReads--;
    }
    return value;
  }
}

/// An explorer that counts every request and answers none.
final class _CountingEsplora extends EsploraClient {
  _CountingEsplora()
    : super(baseUrl: 'http://unused.invalid', route: const DirectRoute());

  int requests = 0;

  Never _count() {
    requests++;
    throw const EsploraException('counted');
  }

  @override
  Future<AddressStats> fetchAddress(String address) async => _count();
  @override
  Future<List<RawUtxo>> fetchUtxos(String address) async => _count();
  @override
  Future<RawTransaction> fetchTransaction(String txid) async => _count();
  @override
  Future<List<MempoolTx>> fetchMempoolTxs(String address) async => _count();
}

/// A store for [loadProPrice]: implements the IAP stub's surface.
class _FakeStore implements InAppPurchase {
  _FakeStore({this.available = true, this.products = const [], this.throws});

  final bool available;
  final List<ProductDetails> products;
  final Object? throws;
  int queries = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<ProductDetailsResponse> queryProductDetails(
    Set<String> identifiers,
  ) async {
    queries++;
    if (throws != null) throw throws!;
    return ProductDetailsResponse(productDetails: products);
  }

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => const Stream.empty();
  @override
  Future<void> restorePurchases() async {}
  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {}
  @override
  Future<void> buyNonConsumable({required PurchaseParam purchaseParam}) async {}
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

  tearDown(() => SentinelService.debugIsAndroid = null);

  /// Starts the real app (router, shell, bottom bar) on [location] with the
  /// scene's mocks. [pro] overrides the scene's Pro state.
  Future<ProviderContainer> pumpApp(
    WidgetTester tester,
    String location, {
    ScreenshotScene scene = ScreenshotScene.walletPrivacy,
    bool? pro,
    Map<String, Object> prefs = const {},
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(1100, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(prefs);
    final sp = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overridesForScene(scene, prefs: sp),
          initialProxyConfigProvider.overrideWithValue(null),
          if (pro != null)
            proUnlockedProvider.overrideWith(() => _FixedPro(pro)),
          ...overrides,
        ],
        child: BagApp(onboardingComplete: true, initialLocation: location),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 3));
    return ProviderScope.containerOf(
      tester.element(find.byType(NavigationBar)),
    );
  }

  GoRouter routerOf(WidgetTester tester) =>
      GoRouter.of(tester.element(find.byType(NavigationBar)));

  /// Where the user is: the leaf of the current match list. Unlike
  /// `currentConfiguration.uri`, this includes a route opened with `push`.
  String locationOf(WidgetTester tester) =>
      routerOf(tester).routerDelegate.currentConfiguration.last.matchedLocation;

  Finder inWallets(Finder finder) =>
      find.descendant(of: find.byType(WalletsScreen), matching: finder);

  /// [finder] in the Wallets screen's body, below its app bar (whose title
  /// is "Wallets" too).
  Finder inWalletsBody(Finder finder) => find.descendant(
    of: inWallets(find.byType(SingleChildScrollView)),
    matching: finder,
  );

  // ── Free user on /wallets ──────────────────────────────────────────────

  group('free user on /wallets', () {
    testWidgets('sees the pitch card with its example figure', (tester) async {
      await pumpApp(tester, '/wallets', pro: false);

      expect(find.byType(WalletsPitchCard), findsOneWidget);
      expect(find.text(_pitchTitle), findsOneWidget);
      expect(find.text(_pitchBody), findsOneWidget);
      // The direct flavor has no store price: the button drops it.
      expect(find.text('Unlock Pro'), findsOneWidget);
      expect(find.text(_pitchLink), findsOneWidget);
      // A static illustration.
      for (final text in [
        'Bitkey 2-of-3',
        '0.5000',
        'Coldcard',
        '0.2100',
        'Kraken typed in',
        '0.0424',
        '\$71,482',
        'looked up over Tor',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
    });

    testWidgets('with a store price the button names it', (tester) async {
      await pumpApp(
        tester,
        '/wallets',
        pro: false,
        overrides: [proPriceProvider.overrideWith((ref) async => '\$7.99')],
      );

      expect(find.text('Unlock Pro for \$7.99'), findsOneWidget);
      expect(find.text('Unlock Pro'), findsNothing);
    });

    testWidgets('Android: "Also in Pro" lists every row, Sentinel last', (
      tester,
    ) async {
      SentinelService.debugIsAndroid = true;
      await pumpApp(tester, '/wallets', pro: false);

      expect(find.text(_alsoInPro), findsOneWidget);
      final rows = tester
          .widgetList<ProLockedRow>(find.byType(ProLockedRow))
          .map((r) => (r.title, r.body))
          .toList();
      expect(rows, [..._rows, _sentinelRow]);
      for (final (title, body) in [..._rows, _sentinelRow]) {
        expect(find.text(title), findsOneWidget, reason: title);
        expect(find.text(body), findsOneWidget, reason: body);
      }
    });

    testWidgets('iOS: no Sentinel row', (tester) async {
      SentinelService.debugIsAndroid = false;
      await pumpApp(tester, '/wallets', pro: false);

      final rows = tester
          .widgetList<ProLockedRow>(find.byType(ProLockedRow))
          .map((r) => (r.title, r.body))
          .toList();
      expect(rows, _rows);
      expect(find.text(_sentinelRow.$1), findsNothing);
    });

    testWidgets('every row is at full opacity with a "Locked, part of Pro" '
        'lock', (tester) async {
      SentinelService.debugIsAndroid = true;
      final semantics = tester.ensureSemantics();
      await pumpApp(tester, '/wallets', pro: false);

      final rows = find.byType(ProLockedRow);
      expect(rows, findsNWidgets(5));
      for (var i = 0; i < 5; i++) {
        final lock = find.descendant(
          of: rows.at(i),
          matching: find.byIcon(Icons.lock_outline),
        );
        expect(lock, findsOneWidget);
        expect(tester.widget<Icon>(lock).semanticLabel, _lockLabel);
      }
      expect(
        find.bySemanticsLabel(RegExp('Locked, part of Pro')),
        findsNWidgets(5),
      );
      // Not dimmed and not pointer-blocked, unlike the old ProGate.
      expect(
        find.ancestor(
          of: rows.first,
          matching: find.byWidgetPredicate(
            (w) =>
                (w is Opacity && w.opacity < 1) ||
                (w is IgnorePointer && w.ignoring),
          ),
        ),
        findsNothing,
      );
      semantics.dispose();
    });

    testWidgets('no Pro control exists in the free layout (R-B2a)', (
      tester,
    ) async {
      SentinelService.debugIsAndroid = true;
      await pumpApp(tester, '/wallets', pro: false);

      for (final entry in _proControls.entries) {
        expect(inWallets(entry.value), findsNothing, reason: entry.key);
      }
    });

    testWidgets('a free user who still has wallets sees none of them', (
      tester,
    ) async {
      // e.g. Pro revoked on a device that had wallets.
      await pumpApp(
        tester,
        '/wallets',
        pro: false,
        overrides: [
          walletsProvider.overrideWith(
            () => _RecordingWallets([], [mockWallet]),
          ),
        ],
      );

      expect(inWallets(_byTypeName('_WalletCard')), findsNothing);
      expect(find.text(mockWallet.label), findsNothing);
      expect(find.byType(WalletsPitchCard), findsOneWidget);
    });

    testWidgets('every tap target opens the Pro sheet and calls no setter', (
      tester,
    ) async {
      SentinelService.debugIsAndroid = true;
      final calls = <String>[];
      // Direct route, default explorer, no wallets: nothing Pro is left on,
      // so there is nothing to switch off (R-B2g) and every target is a lock.
      await pumpApp(
        tester,
        '/wallets',
        pro: false,
        overrides: [
          networkSettingsProvider.overrideWith(
            () => _RecordingNetworkSettings(calls),
          ),
          walletsProvider.overrideWith(() => _RecordingWallets(calls, [])),
          sentinelProvider.overrideWith(() => _RecordingSentinel(calls)),
          portfolioHealthCheckProvider.overrideWith(
            () => _RecordingHealthCheck(calls, const HealthCheckIdle()),
          ),
        ],
      );

      expect(inWallets(_byTypeName('_SwitchOffRow')), findsNothing);
      expect(inWalletsBody(find.text('Network')), findsNothing);
      expect(inWalletsBody(find.text('Wallets')), findsNothing);

      // The app bar's one target is the connection pill, which only opens
      // this tab (test/widgets/route_status_pill_test.dart): tapping it here
      // opens nothing and calls nothing.
      await tester.tap(inWallets(find.byType(RouteStatusPill)));
      await tester.pumpAndSettle();
      expect(_proSheet, findsNothing);
      expect(calls, isEmpty);

      final targets = inWalletsBody(_tapTargets);
      final count = targets.evaluate().length;
      // At least the button, the link and the five rows.
      expect(count, greaterThanOrEqualTo(7));

      for (var i = 0; i < count; i++) {
        final target = targets.at(i);
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(_proSheet, findsOneWidget, reason: 'tap target $i');
        await _closeProSheet(tester);
        if (_hasLongPress(tester.widget(target))) {
          await tester.longPress(target, warnIfMissed: false);
          await tester.pumpAndSettle();
          expect(_proSheet, findsOneWidget, reason: 'long press $i');
          await _closeProSheet(tester);
        }
      }

      // Each named target explicitly, too.
      for (final label in [
        'Unlock Pro',
        _pitchLink,
        for (final (title, _) in [..._rows, _sentinelRow]) title,
      ]) {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(_proSheet, findsOneWidget, reason: label);
        await _closeProSheet(tester);
      }

      expect(calls, isEmpty);
      expect(locationOf(tester), '/wallets');
    });
  });

  // ── Pro user on /wallets ───────────────────────────────────────────────

  group('Pro user on /wallets', () {
    testWidgets('sees no pitch card and no lock', (tester) async {
      SentinelService.debugIsAndroid = true;
      final semantics = tester.ensureSemantics();
      await pumpApp(tester, '/wallets', pro: true);

      expect(find.byType(WalletsPitchCard), findsNothing);
      expect(find.byType(ProLockedRow), findsNothing);
      expect(find.text(_alsoInPro), findsNothing);
      expect(find.text(_pitchTitle), findsNothing);
      expect(find.bySemanticsLabel(RegExp(_lockLabel)), findsNothing);
      semantics.dispose();
    });

    testWidgets('has every Pro control (so the free-layout check is real)', (
      tester,
    ) async {
      SentinelService.debugIsAndroid = true;
      await pumpApp(tester, '/wallets', pro: true);

      for (final name in [
        '_TorSection',
        '_ExplorerSelector',
        '_WalletCard',
        '_WalletMenu',
        '_PortfolioHealthCard',
        '_SentinelCard',
      ]) {
        expect(inWallets(_byTypeName(name)), findsOneWidget, reason: name);
      }
      // blockstream, mempool.space, custom.
      expect(inWallets(_byTypeName('_ExplorerTile')), findsNWidgets(3));
      expect(inWallets(find.byType(ProxySection)), findsOneWidget);
      expect(inWallets(find.byType(AddWalletForm)), findsOneWidget);
      expect(inWallets(find.byType(Switch)), findsWidgets);
    });

    testWidgets('sections in the order Wallets, Network, Watching', (
      tester,
    ) async {
      SentinelService.debugIsAndroid = true;
      await pumpApp(tester, '/wallets', pro: true);

      double top(String heading) => tester
          .getTopLeft(
            find
                .descendant(
                  of: find.byType(SingleChildScrollView),
                  matching: find.text(heading),
                )
                .first,
          )
          .dy;

      final wallets = top('Wallets');
      final network = top('Network');
      final watching = top('Watching');
      expect(wallets, lessThan(network));
      expect(network, lessThan(watching));

      double topOf(Finder f) => tester.getTopLeft(inWallets(f)).dy;
      // The wallet list sits under Wallets…
      expect(
        topOf(_byTypeName('_WalletCard')),
        inExclusiveRange(wallets, network),
      );
      expect(
        topOf(find.byType(AddWalletForm)),
        inExclusiveRange(wallets, network),
      );
      // …Tor, the proxy and the explorer under Network…
      for (final f in [
        _byTypeName('_TorSection'),
        find.byType(ProxySection),
        _byTypeName('_ExplorerSelector'),
      ]) {
        expect(topOf(f), inExclusiveRange(network, watching));
      }
      // …and the health check and Sentinel under Watching.
      expect(topOf(_byTypeName('_PortfolioHealthCard')), greaterThan(watching));
      expect(topOf(_byTypeName('_SentinelCard')), greaterThan(watching));
    });

    testWidgets('the screen is titled Wallets', (tester) async {
      await pumpApp(tester, '/wallets', pro: true);

      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Wallets'),
        ),
        findsOneWidget,
      );
      expect(find.text('Wallet & Privacy'), findsNothing);
    });
  });

  // ── Settings ───────────────────────────────────────────────────────────

  group('Settings', () {
    for (final pro in [false, true]) {
      testWidgets('${pro ? 'Pro' : 'free'}: no Wallet & privacy section', (
        tester,
      ) async {
        await pumpApp(tester, '/settings', pro: pro);

        for (final text in [
          'WALLET & PRIVACY',
          'Wallet & privacy',
          'Wallet & Privacy',
          'Connect wallet · Explorer · Tor',
          'Watch-only wallet connected',
        ]) {
          expect(find.text(text), findsNothing, reason: text);
        }
      });
    }

    testWidgets('section headings are sentence case', (tester) async {
      await pumpApp(tester, '/settings', pro: false);

      for (final heading in [
        'Portfolio',
        'Display',
        'Security',
        'Home screen',
        'Network fees',
        'About',
      ]) {
        expect(find.text(heading), findsOneWidget, reason: heading);
        expect(find.text(heading.toUpperCase()), findsNothing, reason: heading);
      }
    });

    testWidgets('free: the Bag Pro row names the price', (tester) async {
      await pumpApp(
        tester,
        '/settings',
        pro: false,
        overrides: [proPriceProvider.overrideWith((ref) async => '\$7.99')],
      );

      expect(find.text('Bag Pro'), findsOneWidget);
      expect(find.text('$_bagProBody \$7.99 once.'), findsOneWidget);
    });

    testWidgets('free, no price: the row drops "{price} once."', (
      tester,
    ) async {
      await pumpApp(tester, '/settings', pro: false);

      expect(find.text('Bag Pro'), findsOneWidget);
      expect(find.text(_bagProBody), findsOneWidget);
      expect(find.textContaining('once.'), findsNothing);
    });

    for (final (label, wallets, text) in [
      (
        'only typed-in balances',
        [
          const WalletEntry(
            id: 'manual-kraken',
            label: 'Kraken',
            kind: WalletKind.manual,
            lastSats: 4240000,
          ),
        ],
        'Balance managed by your typed-in balances',
      ),
      (
        'a watch-only wallet',
        [mockWallet],
        'Balance managed by watch-only wallet',
      ),
    ]) {
      testWidgets('with $label, Settings says what manages the balance', (
        tester,
      ) async {
        await pumpApp(
          tester,
          '/settings',
          pro: false,
          overrides: [
            walletsProvider.overrideWith(() => _RecordingWallets([], wallets)),
          ],
        );

        expect(find.text(text), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
      });
    }

    testWidgets('Pro: no Bag Pro row', (tester) async {
      await pumpApp(tester, '/settings', pro: true);

      expect(find.text('Bag Pro'), findsNothing);
      expect(find.textContaining(_bagProBody), findsNothing);
    });

    testWidgets('free: Network fees is one row with a Pro label; it opens the '
        'Pro sheet and no fee setting is operable', (tester) async {
      final calls = <String>[];
      await pumpApp(
        tester,
        '/settings',
        pro: false,
        overrides: [
          feeSettingsProvider.overrideWith(() => _RecordingFeeSettings(calls)),
        ],
      );

      final row = find.text('Network fees on home');
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: find.ancestor(of: row, matching: find.byType(InkWell)).first,
          matching: find.text('Pro'),
        ),
        findsOneWidget,
      );
      expect(find.text('Show on home screen'), findsNothing);
      expect(find.text('Show in widget'), findsNothing);
      expect(find.text('Display mode'), findsNothing);

      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(_proSheet, findsOneWidget);
      expect(calls, isEmpty);
    });

    testWidgets('Pro: Network fees keeps its controls', (tester) async {
      await pumpApp(tester, '/settings', pro: true);

      expect(find.text('Network fees on home'), findsNothing);
      expect(find.text('Show on home screen'), findsOneWidget);
      expect(find.text('Show in widget'), findsOneWidget);
    });

    testWidgets('About has an Open-source licences tile that opens the '
        'licence page', (tester) async {
      await pumpApp(tester, '/settings', pro: false);

      final tile = find.text('Open-source licences');
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      // The licence list loads asynchronously; the page itself is enough.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LicensePage), findsOneWidget);
    });
  });

  // ── proPriceProvider ───────────────────────────────────────────────────

  group('loadProPrice', () {
    test('direct flavor: null, and the store is never asked', () async {
      final store = _FakeStore(products: [ProductDetails(price: '\$7.99')]);
      expect(await loadProPrice('direct', store), isNull);
      expect(store.queries, 0);
    });

    test('store flavor: the product\'s price', () async {
      final store = _FakeStore(products: [ProductDetails(price: '€8,99')]);
      expect(await loadProPrice('store', store), '€8,99');
    });

    test(
      'store unavailable, no product, empty price or an error: null',
      () async {
        expect(
          await loadProPrice('store', _FakeStore(available: false)),
          isNull,
        );
        expect(await loadProPrice('store', _FakeStore()), isNull);
        expect(
          await loadProPrice('store', _FakeStore(products: [ProductDetails()])),
          isNull,
        );
        expect(
          await loadProPrice(
            'store',
            _FakeStore(throws: StateError('offline')),
          ),
          isNull,
        );
      },
    );

    test('the provider is null in this (direct) build', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(await container.read(proPriceProvider.future), isNull);
    });
  });

  // ── ProGate is gone ────────────────────────────────────────────────────

  test('no ProGate is left in lib/', () {
    final hits = [
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File &&
            f.path.endsWith('.dart') &&
            f.readAsStringSync().contains('ProGate('))
          f.path,
    ];
    expect(hits, isEmpty);
    expect(File('lib/widgets/pro_gate.dart').existsSync(), isFalse);
  });

  // ── Route-level Pro gate (R-B2b) and the legacy map (R-B2c) ────────────

  group('redirectLocation', () {
    test('free: every Pro sub-route, in any case, lands on /wallets', () {
      for (final path in [
        '/wallets/health-check',
        '/wallets/sentinel',
        '/wallets/sentinel/',
        '/wallets/health-check?from=link',
        '/Wallets/Health-Check',
        '/WALLETS/SENTINEL',
        // Legacy first, then Pro.
        '/settings/sentinel',
        '/settings/wallet-privacy/health-check',
        '/Settings/Wallet-Privacy/Health-Check',
      ]) {
        expect(
          redirectLocation(Uri.parse(path), proUnlocked: false),
          '/wallets',
          reason: path,
        );
      }
    });

    test('free: the Wallets root and everything else are left alone', () {
      for (final path in [
        '/',
        '/wallets',
        '/wallets/',
        '/dca',
        '/settings',
        '/unlock',
        '/walletsx/health-check',
      ]) {
        expect(
          redirectLocation(Uri.parse(path), proUnlocked: false),
          isNull,
          reason: path,
        );
      }
      // The old Wallet & Privacy root is not Pro-only: it still moves.
      expect(
        redirectLocation(
          Uri.parse('/settings/wallet-privacy'),
          proUnlocked: false,
        ),
        '/wallets',
      );
    });

    test('Pro on Android: sub-routes stay; legacy paths still move', () {
      SentinelService.debugIsAndroid = true;
      for (final path in ['/wallets/health-check', '/wallets/sentinel', '/']) {
        expect(
          redirectLocation(Uri.parse(path), proUnlocked: true),
          isNull,
          reason: path,
        );
      }
      expect(
        redirectLocation(Uri.parse('/settings/sentinel'), proUnlocked: true),
        '/wallets/sentinel',
      );
      expect(
        redirectLocation(
          Uri.parse('/settings/wallet-privacy/health-check?from=x'),
          proUnlocked: true,
        ),
        '/wallets/health-check?from=x',
      );
    });

    test(
      'iOS: Sentinel does not exist, so even Pro lands on /wallets (M6)',
      () {
        SentinelService.debugIsAndroid = false;
        for (final path in [
          '/wallets/sentinel',
          '/Wallets/Sentinel/',
          '/settings/sentinel',
        ]) {
          expect(
            redirectLocation(Uri.parse(path), proUnlocked: true),
            '/wallets',
            reason: path,
          );
        }
        expect(
          redirectLocation(
            Uri.parse('/wallets/health-check'),
            proUnlocked: true,
          ),
          isNull,
        );
      },
    );

    test('the legacy map is case-insensitive, like go_router (R-B2c)', () {
      expect(
        redirectLegacyLocation(Uri.parse('/Settings/Wallet-Privacy')),
        '/wallets',
      );
      expect(
        redirectLegacyLocation(Uri.parse('/SETTINGS/SENTINEL')),
        '/wallets/sentinel',
      );
      expect(
        redirectLegacyLocation(
          Uri.parse('/Settings/Wallet-Privacy/Health-Check/?q=1'),
        ),
        '/wallets/health-check?q=1',
      );
    });
  });

  group('router Pro gate', () {
    // Mixed case ('/Wallets/Health-Check') is covered by the redirectLocation
    // tests above, not here: go_router 14.8.1 asserts, in debug builds only,
    // that a nested path starts with its parent's lower-case location, so the
    // match throws before any redirect runs. In release that assert is off,
    // the match is case-insensitive and the redirect sees the original case,
    // which is why redirectProLocation lower-cases.
    const gated = [
      '/wallets/health-check',
      '/wallets/sentinel',
      '/wallets/sentinel/',
      '/settings/sentinel',
      '/settings/wallet-privacy/health-check',
    ];

    for (final path in gated) {
      testWidgets('free, cold start at $path lands on /wallets', (
        tester,
      ) async {
        await pumpApp(
          tester,
          path,
          scene: ScreenshotScene.healthCheck,
          pro: false,
        );

        expect(locationOf(tester), '/wallets');
        expect(find.byType(WalletsPitchCard), findsOneWidget);
        expect(find.byType(UtxoInspectorScreen), findsNothing);
        expect(find.byType(SentinelScreen), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('free, going to $path mid-session lands on /wallets', (
        tester,
      ) async {
        await pumpApp(
          tester,
          '/',
          scene: ScreenshotScene.healthCheck,
          pro: false,
        );

        routerOf(tester).go(path);
        await tester.pumpAndSettle();

        expect(locationOf(tester), '/wallets');
        expect(find.byType(WalletsPitchCard), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('free, pushing /wallets/health-check lands on /wallets', (
      tester,
    ) async {
      await pumpApp(
        tester,
        '/wallets',
        scene: ScreenshotScene.healthCheck,
        pro: false,
      );

      routerOf(tester).push('/wallets/health-check');
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(find.byType(UtxoInspectorScreen), findsNothing);
    });

    testWidgets('Pro, cold start: sub-routes open; legacy paths move', (
      tester,
    ) async {
      await pumpApp(
        tester,
        '/wallets/health-check',
        scene: ScreenshotScene.healthCheck,
        pro: true,
      );
      expect(locationOf(tester), '/wallets/health-check');
      expect(find.byType(UtxoInspectorScreen), findsOneWidget);
    });

    testWidgets('Pro, cold start at /settings/sentinel lands on '
        '/wallets/sentinel', (tester) async {
      SentinelService.debugIsAndroid = true;
      await pumpApp(
        tester,
        '/settings/sentinel',
        scene: ScreenshotScene.sentinelActive,
        pro: true,
      );
      expect(locationOf(tester), '/wallets/sentinel');
      expect(find.byType(SentinelScreen), findsOneWidget);
    });

    testWidgets('Pro, mid-session: sub-routes open', (tester) async {
      SentinelService.debugIsAndroid = true;
      await pumpApp(tester, '/', scene: ScreenshotScene.healthCheck, pro: true);

      routerOf(tester).go('/wallets/sentinel');
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/wallets/sentinel');

      routerOf(tester).go('/wallets/health-check');
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/wallets/health-check');
    });

    testWidgets('Pro revoked while on a Pro sub-route: back to /wallets', (
      tester,
    ) async {
      final container = await pumpApp(
        tester,
        '/wallets/health-check',
        scene: ScreenshotScene.healthCheck,
        pro: true,
      );
      expect(find.byType(UtxoInspectorScreen), findsOneWidget);

      await container.read(proUnlockedProvider.notifier).setUnlocked(false);
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(find.byType(WalletsPitchCard), findsOneWidget);
    });

    // A pushed screen is not part of the location, so re-running the
    // redirect would not reach it (M1).
    testWidgets('Pro revoked after the UTXOs push: back to /wallets', (
      tester,
    ) async {
      final container = await pumpApp(tester, '/wallets', pro: true);
      final utxos = find.text('UTXOs');
      await tester.ensureVisible(utxos);
      await tester.pumpAndSettle();
      await tester.tap(utxos);
      await tester.pumpAndSettle();
      expect(find.byType(UtxoInspectorScreen), findsOneWidget);

      await container.read(proUnlockedProvider.notifier).setUnlocked(false);
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(find.byType(UtxoInspectorScreen), findsNothing);
      expect(find.byType(WalletsPitchCard), findsOneWidget);
    });

    testWidgets('Pro revoked after the Sentinel card push: back to /wallets', (
      tester,
    ) async {
      SentinelService.debugIsAndroid = true;
      final container = await pumpApp(tester, '/wallets', pro: true);
      final card = inWallets(_byTypeName('_SentinelCard'));
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byType(SentinelScreen), findsOneWidget);

      await container.read(proUnlockedProvider.notifier).setUnlocked(false);
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(find.byType(SentinelScreen), findsNothing);
      expect(find.byType(WalletsPitchCard), findsOneWidget);
    });

    testWidgets('Pro revoked elsewhere: the user stays where they are', (
      tester,
    ) async {
      final container = await pumpApp(tester, '/dca', pro: true);

      await container.read(proUnlockedProvider.notifier).setUnlocked(false);
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/dca');
    });

    for (final cold in [true, false]) {
      testWidgets('iOS, Pro: ${cold ? 'cold start at' : 'going to'} '
          '/wallets/sentinel lands on /wallets (M6)', (tester) async {
        SentinelService.debugIsAndroid = false;
        await pumpApp(
          tester,
          cold ? '/wallets/sentinel' : '/',
          scene: ScreenshotScene.sentinelActive,
          pro: true,
        );
        if (!cold) {
          routerOf(tester).go('/wallets/sentinel');
          await tester.pumpAndSettle();
        }

        expect(locationOf(tester), '/wallets');
        expect(find.byType(SentinelScreen), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  });

  // ── Defence in depth behind the route gate ─────────────────────────────

  group('the Pro screens refuse a free user on their own', () {
    Future<List<String>> pumpScreen(
      WidgetTester tester,
      Widget screen, {
      required bool pro,
      HealthCheckState health = const HealthCheckIdle(),
    }) async {
      tester.view.physicalSize = const Size(1100, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final calls = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            initialProxyConfigProvider.overrideWithValue(null),
            proUnlockedProvider.overrideWith(() => _FixedPro(pro)),
            walletsProvider.overrideWith(
              () => _RecordingWallets(calls, [mockWallet]),
            ),
            sentinelProvider.overrideWith(() => _RecordingSentinel(calls)),
            portfolioHealthCheckProvider.overrideWith(
              () => _RecordingHealthCheck(calls, health),
            ),
          ],
          child: MaterialApp(theme: AppTheme.dark, home: screen),
        ),
      );
      await tester.pumpAndSettle();
      return calls;
    }

    final healthButtons = <String, HealthCheckState>{
      'Run Health Check': const HealthCheckIdle(),
      'Restart Health Check': const HealthCheckIncomplete(),
      'Try Again': const HealthCheckError('Analysis failed'),
      'Re-run': HealthCheckDone(mockHealthResult),
    };

    for (final MapEntry(key: label, value: state) in healthButtons.entries) {
      testWidgets(
        'health check "$label": free user gets the Pro sheet, no run',
        (tester) async {
          final calls = await pumpScreen(
            tester,
            const UtxoInspectorScreen(),
            pro: false,
            health: state,
          );

          await tester.ensureVisible(find.text(label));
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();

          expect(_proSheet, findsOneWidget);
          expect(calls, isEmpty);
        },
      );

      testWidgets('health check "$label": Pro user runs it', (tester) async {
        final calls = await pumpScreen(
          tester,
          const UtxoInspectorScreen(),
          pro: true,
          health: state,
        );

        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();

        expect(_proSheet, findsNothing);
        expect(calls, ['healthCheck.run']);
      });
    }

    testWidgets('Sentinel toggle: free user gets the Pro sheet, Sentinel '
        'stays off', (tester) async {
      final calls = await pumpScreen(
        tester,
        const SentinelScreen(),
        pro: false,
      );

      final toggle = find.byType(SwitchListTile);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(_proSheet, findsOneWidget);
      expect(find.text('Enable Sentinel?'), findsNothing);
      expect(calls, isEmpty);
    });

    testWidgets('Sentinel toggle: the screen is not dimmed or overlaid', (
      tester,
    ) async {
      await pumpScreen(tester, const SentinelScreen(), pro: false);

      expect(
        find.ancestor(
          of: find.byType(SwitchListTile),
          matching: find.byWidgetPredicate(
            (w) =>
                (w is Opacity && w.opacity < 1) ||
                (w is IgnorePointer && w.ignoring),
          ),
        ),
        findsNothing,
      );
    });

    testWidgets('Sentinel toggle: Pro user gets the disclosure', (
      tester,
    ) async {
      await pumpScreen(tester, const SentinelScreen(), pro: true);

      final toggle = find.byType(SwitchListTile);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(find.text('Enable Sentinel?'), findsOneWidget);
      expect(_proSheet, findsNothing);
    });
  });

  // ── Fee alerts (I1) ────────────────────────────────────────────────────

  group('fee alerts', () {
    Finder feeAlertsRow() => find.byWidgetPredicate(
      (w) =>
          w is ProLockedRow &&
          w.title == 'Fee alerts' &&
          w.body == 'Get notified when fees reach your target',
    );

    Future<List<String>> openFeesTab(
      WidgetTester tester, {
      required bool pro,
    }) async {
      final calls = <String>[];
      await pumpApp(
        tester,
        '/',
        scene: ScreenshotScene.alertsSheet,
        pro: pro,
        overrides: [
          feeAlertsProvider.overrideWith(() => _RecordingFeeAlerts(calls)),
        ],
      );
      await tester.tap(find.byTooltip('Price alerts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fees'));
      await tester.pumpAndSettle();
      return calls;
    }

    testWidgets('free: a locked row that opens the Pro sheet; no alert is '
        'touched', (tester) async {
      final calls = await openFeesTab(tester, pro: false);

      expect(feeAlertsRow(), findsOneWidget);
      expect(find.text('Fee alerts are a Pro feature'), findsNothing);

      await tester.tap(feeAlertsRow());
      await tester.pumpAndSettle();

      expect(_proSheet, findsOneWidget);
      expect(calls, isEmpty);
    });

    testWidgets('Pro: the fee alert controls, no lock', (tester) async {
      await openFeesTab(tester, pro: true);

      expect(feeAlertsRow(), findsNothing);
      expect(find.byType(ProLockedRow), findsNothing);
    });
  });

  // ── Semantics (M2) ─────────────────────────────────────────────────────

  group('semantics', () {
    testWidgets('a locked row is one button that names its lock', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, '/wallets', pro: false);

      final node = tester.getSemantics(find.byType(ProLockedRow).first);
      expect(node.label, contains('Route through Tor'));
      expect(node.label, contains('Built in, no other app needed'));
      expect(node.label, contains(_lockLabel));
      expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });

    testWidgets('Settings: the locked Network fees row is a button that names '
        'its lock', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, '/settings', pro: false);

      final node = tester.getSemantics(
        find
            .ancestor(
              of: find.text('Network fees on home'),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(node.label, contains('Network fees on home'));
      expect(node.label, contains(_lockLabel));
      expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });
  });

  // ── Switching Pro features off without Pro (R-B2g) ─────────────────────

  group('a free user can switch Pro features off, never on (R-B2g)', () {
    const offBody =
        'Part of Pro. You can switch it off; switching it back on needs Pro.';
    const proxy = ProxyConfig(
      type: ProxyType.socks5,
      host: '10.0.0.5',
      port: 1080,
    );
    final manual = WalletEntry(
      id: 'manual-kraken',
      label: 'Kraken',
      kind: WalletKind.manual,
      lastSats: 4240000,
    );

    Future<(List<String>, ProviderContainer)> pumpFree(
      WidgetTester tester, {
      Map<String, Object> prefs = const {},
      ProxyConfig? savedProxy,
      List<WalletEntry> wallets = const [],
    }) async {
      final calls = <String>[];
      final container = await pumpApp(
        tester,
        '/wallets',
        pro: false,
        prefs: prefs,
        overrides: [
          initialProxyConfigProvider.overrideWithValue(savedProxy),
          networkSettingsProvider.overrideWith(
            () => _RecordingNetworkSettings(calls),
          ),
          walletsProvider.overrideWith(() => _RecordingWallets(calls, wallets)),
        ],
      );
      return (calls, container);
    }

    Finder rowTitled(String title) => find.ancestor(
      of: find.text(title),
      matching: _byTypeName('_SwitchOffRow'),
    );

    Future<void> tapRowAction(
      WidgetTester tester,
      String title,
      String action,
    ) async {
      final button = find.descendant(
        of: rowTitled(title),
        matching: find.widgetWithText(TextButton, action),
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    Future<void> tapDialog(WidgetTester tester, String label) async {
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, label),
        ),
      );
      await tester.pumpAndSettle();
    }

    test('"Use default" means the preset a fresh install gets', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      expect(
        container.read(networkSettingsProvider).preset,
        ExplorerPreset.blockstream,
      );
    });

    final cases = [
      (
        name: 'Tor on',
        prefs: <String, Object>{AppConstants.keyUseTor: true},
        savedProxy: null as ProxyConfig?,
        wallets: <WalletEntry>[],
        heading: 'Network',
        title: 'Tor is on',
        body: offBody,
        action: 'Switch off',
        dialogTitle: 'Switch Tor off?',
        dialogBody: 'Prices will then be fetched directly, without Tor.',
        confirm: 'Switch off',
        call: 'setUseTor(false)',
      ),
      (
        name: 'proxy on',
        prefs: <String, Object>{AppConstants.keyUseProxy: true},
        savedProxy: proxy as ProxyConfig?,
        wallets: <WalletEntry>[],
        heading: 'Network',
        title: 'Custom proxy is on',
        body: offBody,
        action: 'Switch off',
        dialogTitle: 'Switch the proxy off?',
        dialogBody: 'Prices will then be fetched directly, without your proxy.',
        confirm: 'Switch off',
        call: 'setUseProxy(false)',
      ),
      (
        name: 'proxy on but unreadable',
        prefs: <String, Object>{AppConstants.keyUseProxy: true},
        savedProxy: null as ProxyConfig?,
        wallets: <WalletEntry>[],
        heading: 'Network',
        title: 'Custom proxy is on, but its settings could not be read',
        body: offBody,
        action: 'Switch off',
        dialogTitle: 'Switch the proxy off?',
        dialogBody: 'Prices will then be fetched directly, without your proxy.',
        confirm: 'Switch off',
        call: 'setUseProxy(false)',
      ),
      (
        name: 'own node selected',
        prefs: <String, Object>{
          AppConstants.keyExplorerPreset: ExplorerPreset.custom.index,
        },
        savedProxy: null as ProxyConfig?,
        wallets: <WalletEntry>[mockWallet],
        heading: 'Network',
        title: 'Your own node is selected',
        body: 'Part of Pro. You can switch back to the default explorer.',
        action: 'Use default',
        dialogTitle: 'Use the default explorer?',
        dialogBody:
            'If you get Pro back, wallet scans will use the default explorer '
            'instead of your node.',
        confirm: 'Use default',
        call: 'setPreset(blockstream)',
      ),
      (
        name: 'watch-only wallets kept',
        prefs: <String, Object>{},
        savedProxy: null as ProxyConfig?,
        wallets: <WalletEntry>[mockWallet, manual],
        heading: 'Wallets',
        title: 'Your watch-only wallets are kept',
        body: 'Their balances stopped updating. Live balances are part of Pro.',
        action: 'Remove wallets',
        dialogTitle: 'Remove watch-only wallets?',
        dialogBody:
            'Bag deletes their public keys and descriptors from this device. '
            'Your coins are not affected.',
        confirm: 'Remove',
        call: 'removeWallet(${mockWallet.id})',
      ),
      (
        name: 'typed-in balances kept',
        prefs: <String, Object>{},
        savedProxy: null as ProxyConfig?,
        wallets: <WalletEntry>[mockWallet, manual],
        heading: 'Wallets',
        title: 'Your typed-in balances are kept',
        body:
            'They still count toward your net worth. Adding or editing them '
            'is part of Pro.',
        action: 'Remove',
        dialogTitle: 'Remove typed-in balances?',
        // Watch-only wallets remain, so Settings won't take a total yet.
        dialogBody: 'Bag deletes them from this device.',
        confirm: 'Remove',
        call: 'removeWallet(${manual.id})',
      ),
      (
        name: 'typed-in balances, the only entries',
        prefs: <String, Object>{},
        savedProxy: null as ProxyConfig?,
        wallets: <WalletEntry>[manual],
        heading: 'Wallets',
        title: 'Your typed-in balances are kept',
        body:
            'They still count toward your net worth. Adding or editing them '
            'is part of Pro.',
        action: 'Remove',
        dialogTitle: 'Remove typed-in balances?',
        dialogBody:
            'Bag deletes them from this device. You can then type your total '
            'in Settings.',
        confirm: 'Remove',
        call: 'removeWallet(${manual.id})',
      ),
    ];

    for (final c in cases) {
      testWidgets('${c.name}: the row, above the pitch card', (tester) async {
        await pumpFree(
          tester,
          prefs: c.prefs,
          savedProxy: c.savedProxy,
          wallets: c.wallets,
        );

        final row = rowTitled(c.title);
        expect(row, findsOneWidget);
        expect(
          find.descendant(of: row, matching: find.text(c.body)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: row,
            matching: find.widgetWithText(TextButton, c.action),
          ),
          findsOneWidget,
        );
        final heading = inWalletsBody(find.text(c.heading));
        expect(heading, findsOneWidget);
        final pitch = tester.getTopLeft(find.byType(WalletsPitchCard)).dy;
        expect(tester.getTopLeft(heading).dy, lessThan(pitch));
        expect(tester.getTopLeft(row).dy, lessThan(pitch));
        // A button and a dialog, never a switch.
        expect(inWallets(find.byType(Switch)), findsNothing);
      });

      testWidgets('${c.name}: Cancel calls nothing', (tester) async {
        final (calls, _) = await pumpFree(
          tester,
          prefs: c.prefs,
          savedProxy: c.savedProxy,
          wallets: c.wallets,
        );

        await tapRowAction(tester, c.title, c.action);
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(c.dialogTitle),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(c.dialogBody),
          ),
          findsOneWidget,
        );
        await tapDialog(tester, 'Cancel');

        expect(calls, isEmpty);
        expect(rowTitled(c.title), findsOneWidget);
      });

      testWidgets('${c.name}: confirming makes exactly that one call and the '
          'row goes', (tester) async {
        final (calls, container) = await pumpFree(
          tester,
          prefs: c.prefs,
          savedProxy: c.savedProxy,
          wallets: c.wallets,
        );

        await tapRowAction(tester, c.title, c.action);
        await tapDialog(tester, c.confirm);

        expect(calls, [c.call]);
        expect(rowTitled(c.title), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        if (c.name == 'watch-only wallets kept') {
          // Manual entries stay.
          expect(container.read(walletsProvider), [manual]);
        }
        if (c.name == 'typed-in balances kept') {
          // Watch-only wallets stay.
          expect(container.read(walletsProvider), [mockWallet]);
        }
        if (c.name == 'typed-in balances, the only entries') {
          expect(container.read(walletsProvider), isEmpty);
        }
      });
    }

    testWidgets('own node selected but only typed-in balances: no node row, '
        'only the typed-in row', (tester) async {
      await pumpFree(
        tester,
        prefs: {AppConstants.keyExplorerPreset: ExplorerPreset.custom.index},
        wallets: [manual],
      );

      expect(rowTitled('Your own node is selected'), findsNothing);
      expect(inWalletsBody(find.text('Network')), findsNothing);
      expect(rowTitled('Your watch-only wallets are kept'), findsNothing);
      expect(rowTitled('Your typed-in balances are kept'), findsOneWidget);
      expect(_byTypeName('_SwitchOffRow'), findsOneWidget);
    });

    testWidgets('everything on: every target opens the Pro sheet or a '
        'switch-off dialog, and nothing reachable turns a Pro feature on', (
      tester,
    ) async {
      SentinelService.debugIsAndroid = true;
      final (calls, _) = await pumpFree(
        tester,
        prefs: {
          AppConstants.keyUseTor: true,
          AppConstants.keyExplorerPreset: ExplorerPreset.custom.index,
        },
        wallets: [mockWallet, manual],
      );
      expect(_byTypeName('_SwitchOffRow'), findsNWidgets(4));
      for (final entry in _proControls.entries) {
        expect(inWallets(entry.value), findsNothing, reason: entry.key);
      }

      // The connection pill (the app bar's one target) says Tor is on and
      // only opens this tab: no sheet, no dialog, no call.
      await tester.tap(inWallets(find.byType(RouteStatusPill)));
      await tester.pumpAndSettle();
      expect(_proSheet, findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(calls, isEmpty);

      final targets = inWalletsBody(_tapTargets);
      final count = targets.evaluate().length;
      var dialogs = 0;
      for (var i = 0; i < count; i++) {
        final target = targets.at(i);
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target, warnIfMissed: false);
        await tester.pumpAndSettle();
        if (find.byType(AlertDialog).evaluate().isNotEmpty) {
          dialogs++;
          await tapDialog(tester, 'Cancel');
        } else {
          expect(_proSheet, findsOneWidget, reason: 'tap target $i');
          await _closeProSheet(tester);
        }
      }
      expect(dialogs, greaterThanOrEqualTo(4));
      expect(calls, isEmpty, reason: 'every dialog was cancelled');

      for (final (title, action, confirm) in [
        ('Your watch-only wallets are kept', 'Remove wallets', 'Remove'),
        ('Your typed-in balances are kept', 'Remove', 'Remove'),
        ('Tor is on', 'Switch off', 'Switch off'),
        ('Your own node is selected', 'Use default', 'Use default'),
      ]) {
        // Removing the wallets also removes the own-node row, which only
        // shows while there are watch-only wallets.
        if (rowTitled(title).evaluate().isEmpty) continue;
        await tapRowAction(tester, title, action);
        await tapDialog(tester, confirm);
      }

      expect(calls, [
        'removeWallet(${mockWallet.id})',
        'removeWallet(${manual.id})',
        'setUseTor(false)',
      ]);
      expect(_byTypeName('_SwitchOffRow'), findsNothing);
      expect(inWalletsBody(find.text('Network')), findsNothing);
      for (final call in calls) {
        expect(call, isNot(contains('true')));
        expect(call, isNot(anyOf('saveProxy', 'setCustomUrl', 'clearProxy')));
        expect(call, isNot(startsWith('add')));
      }
    });

    // The real WalletsNotifier and health check over mocked secure storage
    // (M4, M5, Important 1): what the rows delete, and that a free user who
    // removed everything can type their total again.
    testWidgets('real removal: secrets, metadata and the health check go, '
        'net worth follows, and Settings takes a typed total again', (
      tester,
    ) async {
      const zpub =
          'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs';
      final watch = WalletEntry(
        id: 'w1',
        label: 'Cold',
        lastSats: 50000000,
        lastScanAt: DateTime(2020),
      );
      FlutterSecureStorage.setMockInitialValues({
        'wallet_zpub_w1': zpub,
        'wallets_metadata': WalletEntry.listToJsonString([watch, manual]),
        'health_check_portfolio': mockHealthResult.toJsonString(),
      });
      final container = await pumpApp(
        tester,
        '/wallets',
        pro: false,
        overrides: [
          initialWalletsProvider.overrideWithValue([watch, manual]),
          walletsProvider.overrideWith(WalletsNotifier.new),
          portfolioHealthCheckProvider.overrideWith(
            PortfolioHealthCheckNotifier.new,
          ),
        ],
      );
      Future<Map<String, String>> stored() =>
          const FlutterSecureStorage().readAll();
      List<String> storedIds(Map<String, String> all) =>
          WalletEntry.listFromJson(
            all['wallets_metadata']!,
          ).map((w) => w.id).toList();

      // The cached result loads asynchronously once the provider is built
      // (on Home, the chip builds it).
      container.read(portfolioHealthCheckProvider);
      await tester.pumpAndSettle();
      expect(
        container.read(portfolioHealthCheckProvider),
        isA<HealthCheckDone>(),
      );
      expect(container.read(portfolioProvider).btcAmount, 0.5424);

      // 1. Watch-only wallets: secret, metadata and health check go; the
      //    typed-in balance stays and is the whole net worth now.
      await tapRowAction(
        tester,
        'Your watch-only wallets are kept',
        'Remove wallets',
      );
      await tapDialog(tester, 'Remove');
      var all = await stored();
      expect(all.containsKey('wallet_zpub_w1'), isFalse);
      expect(storedIds(all), [manual.id]);
      expect(all.containsKey('health_check_portfolio'), isFalse);
      expect(
        container.read(portfolioHealthCheckProvider),
        isA<HealthCheckIdle>(),
      );
      expect(container.read(walletsProvider), [manual]);
      expect(container.read(portfolioProvider).btcAmount, 0.0424);

      // 2. Typed-in balances. No watch-only wallet is left, so the dialog
      //    points to Settings.
      await tapRowAction(tester, 'Your typed-in balances are kept', 'Remove');
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(
            'Bag deletes them from this device. You can then type your total '
            'in Settings.',
          ),
        ),
        findsOneWidget,
      );
      await tapDialog(tester, 'Remove');
      all = await stored();
      expect(storedIds(all), isEmpty);
      expect(container.read(walletsProvider), isEmpty);
      expect(_byTypeName('_SwitchOffRow'), findsNothing);

      // 3. Settings shows the amount field again, and saving works.
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Settings'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Balance managed by watch-only wallet'), findsNothing);
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      await tester.enterText(field, '0.5');
      await tester.pump();
      await tester.tap(find.text('Save Amount'));
      await tester.pumpAndSettle();
      expect(container.read(portfolioProvider).btcAmount, 0.5);
      expect(find.text('Amount saved'), findsOneWidget);
    });
  });

  // ── Wallet scans are Pro (R-B2g) ───────────────────────────────────────

  group('wallet scans are Pro (R-B2g)', () {
    const zpub =
        'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs';
    final stale = WalletEntry(
      id: 'stale',
      label: 'Stale',
      lastSats: 50000000,
      lastScanAt: DateTime(2020),
    );

    Future<(ProviderContainer, _CountingEsplora)> container({
      required bool pro,
    }) async {
      FlutterSecureStorage.setMockInitialValues({'wallet_zpub_stale': zpub});
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final esplora = _CountingEsplora();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          initialProxyConfigProvider.overrideWithValue(null),
          initialWalletsProvider.overrideWithValue([stale]),
          esploraClientProvider.overrideWithValue(esplora),
          proUnlockedProvider.overrideWith(() => _FixedPro(pro)),
        ],
      );
      addTearDown(c.dispose);
      return (c, esplora);
    }

    test('free: no scan path makes a request; the last balance stays and '
        'still counts toward net worth', () async {
      final (c, esplora) = await container(pro: false);
      final wallets = c.read(walletsProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      await wallets.scan('stale');
      await wallets.scanAll();
      await wallets.scanAllIfStale();
      await wallets.scanAllIfStale(includeRouteBlocked: true);

      expect(esplora.requests, 0);
      final kept = c.read(walletsProvider).single;
      expect(kept.lastSats, 50000000);
      expect(kept.scanError, isNull);
      expect(kept.isScanning, isFalse);
      expect(c.read(portfolioProvider).btcAmount, 0.5);
    });

    test(
      'Pro: the same scan reaches the explorer (so the count is real)',
      () async {
        final (c, esplora) = await container(pro: true);
        await c.read(walletsProvider.notifier).scan('stale');
        expect(esplora.requests, greaterThan(0));
      },
    );

    test('free: the health check makes no request (M2)', () async {
      final (c, esplora) = await container(pro: false);
      await c.read(portfolioHealthCheckProvider.notifier).run();
      expect(esplora.requests, 0);
      expect(c.read(portfolioHealthCheckProvider), isA<HealthCheckIdle>());
    });

    test(
      'Pro: the health check reaches the explorer (so the count is real)',
      () async {
        final (c, esplora) = await container(pro: true);
        await c.read(portfolioHealthCheckProvider.notifier).run();
        expect(esplora.requests, greaterThan(0));
      },
    );

    Future<(_StaleScanCounter, ProUnlockedNotifier)> scanCounter({
      required bool pro,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          initialProxyConfigProvider.overrideWithValue(null),
          initialWalletsProvider.overrideWithValue([stale]),
          walletsProvider.overrideWith(_StaleScanCounter.new),
          proUnlockedProvider.overrideWith(() => _FixedPro(pro)),
        ],
      );
      addTearDown(c.dispose);
      return (
        c.read(walletsProvider.notifier) as _StaleScanCounter,
        c.read(proUnlockedProvider.notifier),
      );
    }

    test(
      'Pro turning on rescans stale wallets once; nothing else does (M3)',
      () async {
        final (wallets, pro) = await scanCounter(pro: false);
        expect(wallets.staleScans, 0);

        await pro.setUnlocked(true); // false → true
        expect(wallets.staleScans, 1);
        await pro.setUnlocked(true); // true → true
        expect(wallets.staleScans, 1);
        await pro.setUnlocked(false); // true → false
        expect(wallets.staleScans, 1);
        await pro.setUnlocked(true); // bought again
        expect(wallets.staleScans, 2);
      },
    );

    test('two concurrent stale rescans scan once; a later scan still runs '
        '(round 3)', () async {
      final (single, singleEsplora) = await container(pro: true);
      await single.read(walletsProvider.notifier).scan('stale');
      final oneScan = singleEsplora.requests;
      expect(oneScan, greaterThan(0));

      final (c, esplora) = await container(pro: true);
      final wallets = c.read(walletsProvider.notifier);
      await Future.wait([
        wallets.scanAllIfStale(), // app resume
        wallets.scanAllIfStale(includeRouteBlocked: true), // Tor came back
      ]);
      expect(esplora.requests, oneScan);

      // The guard is per scan, not a latch: the next scan runs.
      await wallets.scan('stale');
      expect(esplora.requests, 2 * oneScan);
    });

    test('Pro turning on during a resume rescan: one scan, not two '
        '(round 3)', () async {
      final (single, singleEsplora) = await container(pro: true);
      await single.read(walletsProvider.notifier).scan('stale');
      final oneScan = singleEsplora.requests;

      final (c, esplora) = await container(pro: false);
      final wallets = c.read(walletsProvider.notifier);
      final turnOn = c.read(proUnlockedProvider.notifier).setUnlocked(true);
      final resume = wallets.scanAllIfStale();
      await turnOn;
      await resume;
      // The Pro-on rescan is fire-and-forget; let it finish.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(esplora.requests, oneScan);
    });

    test('a Pro user from the start gets no extra scan', () async {
      final (wallets, pro) = await scanCounter(pro: true);
      await pro.setUnlocked(true);
      expect(wallets.staleScans, 0);
    });

    test(
      'the background task needs Pro for wallet scans and fees (M6)',
      () async {
        SharedPreferences.setMockInitialValues({
          AppConstants.keyWidgetShowFee: true,
          AppConstants.keyFeeAlerts:
              '[{"id":"a","targetRate":5,"above":false}]',
        });
        final prefs = await SharedPreferences.getInstance();
        expect(backgroundProAllowed(prefs), isFalse);
        var plan = backgroundFeePlan(prefs);
        expect((plan.showInWidget, plan.checkAlerts), (false, false));

        await prefs.setBool(AppConstants.keyProUnlocked, false);
        expect(backgroundProAllowed(prefs), isFalse);
        plan = backgroundFeePlan(prefs);
        expect((plan.showInWidget, plan.checkAlerts), (false, false));

        await prefs.setBool(AppConstants.keyProUnlocked, true);
        expect(backgroundProAllowed(prefs), isTrue);
        plan = backgroundFeePlan(prefs);
        expect((plan.showInWidget, plan.checkAlerts), (true, true));

        // Pro, nothing asked for: no fee work either.
        await prefs.remove(AppConstants.keyWidgetShowFee);
        await prefs.remove(AppConstants.keyFeeAlerts);
        plan = backgroundFeePlan(prefs);
        expect((plan.showInWidget, plan.checkAlerts), (false, false));

        // …and the WorkManager callback uses both before any request: the fee
        // fetch only runs for the plan, wallet scans only with Pro.
        final src = File('lib/services/widget_service.dart').readAsStringSync();
        final start = src.indexOf('void backgroundWidgetCallback()');
        final feePlan = src.indexOf('backgroundFeePlan(prefs)', start);
        final feeGate = src.indexOf(
          'if ((showFeeInWidget || hasActiveFeeAlerts) && routeOk && '
          '!pastDeadline()) {',
          start,
        );
        final feeFetch = src.indexOf('fetchFeeEstimate(dio,', start);
        final scanGuard = src.indexOf(
          'if (!backgroundProAllowed(prefs)) skipWalletScan = true;',
          start,
        );
        final skip = src.indexOf('if (!skipWalletScan) {', start);
        final scan = src.indexOf('await scanWallet(', start);
        expect(start, isNonNegative);
        expect(feePlan, greaterThan(start));
        expect(feeGate, greaterThan(feePlan));
        expect(feeFetch, greaterThan(feeGate));
        expect(scanGuard, greaterThan(start));
        expect(skip, greaterThan(scanGuard));
        expect(scan, greaterThan(skip));
        expect(src.contains('backgroundWalletScanAllowed'), isFalse);
      },
    );
  });

  // ── The health check's cached result and clear() (round 3) ─────────────

  group('health check: clear() wins over the cached-result restore', () {
    late _GatedSecureStorage storage;

    setUp(() {
      storage = _GatedSecureStorage({
        'health_check_portfolio': mockHealthResult.toJsonString(),
      });
      FlutterSecureStoragePlatform.instance = storage;
    });

    tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

    Future<ProviderContainer> container() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          proUnlockedProvider.overrideWith(() => _FixedPro(false)),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('clearing before the provider was ever built: the restore never '
        'resurrects the result', () async {
      final c = await container();
      // The platform answers the restore's read (issued after the delete)
      // with the old value, and only once the delete has finished.
      storage.holdDeletes();
      storage.holdReads();
      final clearing = c.read(portfolioHealthCheckProvider.notifier).clear();
      await settle();
      storage.releaseDeletes();
      await clearing;
      storage.releaseReads();
      for (var i = 0; i < 5; i++) {
        await settle();
      }

      expect(c.read(portfolioHealthCheckProvider), isA<HealthCheckIdle>());
      expect(storage.data.containsKey('health_check_portfolio'), isFalse);
    });

    test('clearing while an earlier restore is still reading: the old '
        'result is dropped', () async {
      final c = await container();
      storage.holdReads();
      c.read(portfolioHealthCheckProvider); // build: the restore starts
      await settle();
      expect(storage.pendingReads, 1);

      await c.read(portfolioHealthCheckProvider.notifier).clear();
      storage.releaseReads();
      for (var i = 0; i < 5; i++) {
        await settle();
      }

      expect(c.read(portfolioHealthCheckProvider), isA<HealthCheckIdle>());
      expect(storage.data.containsKey('health_check_portfolio'), isFalse);
    });

    test('without clear(), the cached result still loads', () async {
      final c = await container();
      c.read(portfolioHealthCheckProvider);
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      expect(c.read(portfolioHealthCheckProvider), isA<HealthCheckDone>());
    });

    // M-14: a clear() cancels only the restores already under way. A later
    // rebuild of the same notifier (an invalidate) restores a result written
    // after the clear.
    test('after a clear(), a rebuild still restores a newer result',
        () async {
      final c = await container();
      c.read(portfolioHealthCheckProvider);
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      await c.read(portfolioHealthCheckProvider.notifier).clear();
      expect(storage.data.containsKey('health_check_portfolio'), isFalse);

      // A later run writes a fresh result; then something rebuilds the
      // provider.
      storage.data['health_check_portfolio'] = mockHealthResult.toJsonString();
      c.invalidate(portfolioHealthCheckProvider);
      c.read(portfolioHealthCheckProvider);
      for (var i = 0; i < 5; i++) {
        await settle();
      }

      expect(c.read(portfolioHealthCheckProvider), isA<HealthCheckDone>());
    });
  });

  // ── In-app entry points into the Wallets branch (R-B2d) ────────────────

  group('entry points', () {
    testWidgets('home health chip → /wallets/health-check', (tester) async {
      await pumpApp(tester, '/', scene: ScreenshotScene.healthCheck, pro: true);

      final score = mockHealthResult.score.score;
      await tester.tap(find.text('$score ${AppColors.scoreLetter(score)}'));
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets/health-check');
      expect(find.byType(UtxoInspectorScreen), findsOneWidget);
    });

    // Ruling R-B4b: the balance row goes to /wallets for everyone. A free
    // user lands on the Wallets pitch, a Pro user on their wallets.
    for (final pro in [true, false]) {
      testWidgets('home balance row (${pro ? 'Pro' : 'free'}) → /wallets', (
        tester,
      ) async {
        await pumpApp(
          tester,
          '/',
          scene: ScreenshotScene.homeWithWallet,
          pro: pro,
        );

        await tester.tap(
          find.text(formatBtcAmount(mockBtcAmount, satsMode: false)),
        );
        await tester.pumpAndSettle();

        expect(locationOf(tester), '/wallets');
        expect(find.byType(WalletsScreen), findsOneWidget);
        expect(
          find.byType(WalletsPitchCard),
          pro ? findsNothing : findsOneWidget,
        );
      });
    }

    testWidgets('Settings amount link → /wallets', (tester) async {
      await pumpApp(
        tester,
        '/settings',
        scene: ScreenshotScene.settingsProLocked,
        pro: false,
      );

      final link = find.text(_amountLink);
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(find.byType(WalletsPitchCard), findsOneWidget);
    });

    testWidgets('Settings Bag Pro row (free) → Pro sheet', (tester) async {
      await pumpApp(
        tester,
        '/settings',
        scene: ScreenshotScene.settingsProLocked,
        pro: false,
      );

      await tester.tap(find.text('Bag Pro'));
      await tester.pumpAndSettle();

      expect(_proSheet, findsOneWidget);
      expect(locationOf(tester), '/settings');
    });

    testWidgets('UTXOs button → /wallets/health-check', (tester) async {
      await pumpApp(tester, '/wallets', pro: true);

      final utxos = find.text('UTXOs');
      await tester.ensureVisible(utxos);
      await tester.pumpAndSettle();
      await tester.tap(utxos);
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets/health-check');
      expect(find.byType(UtxoInspectorScreen), findsOneWidget);
    });

    testWidgets('Sentinel card (Android) → /wallets/sentinel', (tester) async {
      SentinelService.debugIsAndroid = true;
      await pumpApp(tester, '/wallets', pro: true);

      final card = inWallets(_byTypeName('_SentinelCard'));
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets/sentinel');
      expect(find.byType(SentinelScreen), findsOneWidget);
    });
  });

  // ── Small phones and large text (B4 fix round 2, N1) ───────────────────

  group('the free layout fits a small phone at large text (N1)', () {
    const proxy = ProxyConfig(
      type: ProxyType.socks5,
      host: '10.0.0.5',
      port: 1080,
    );
    const manual = WalletEntry(
      id: 'manual-kraken',
      label: 'Kraken',
      kind: WalletKind.manual,
      lastSats: 4240000,
    );

    /// The free Wallets screen alone (no bottom bar), at [size] and
    /// [scale]. The states turn on every switch-off row there is: Tor and
    /// the proxy exclude each other, so they take separate states.
    final states =
        <String, (Map<String, Object>, ProxyConfig?, List<WalletEntry>)>{
          'nothing on': (const {}, null, const []),
          'Tor, own node, watch-only and typed-in': (
            {
              AppConstants.keyUseTor: true,
              AppConstants.keyExplorerPreset: ExplorerPreset.custom.index,
            },
            null,
            [mockWallet, manual],
          ),
          'proxy on': ({AppConstants.keyUseProxy: true}, proxy, const []),
          'proxy unreadable': (
            {AppConstants.keyUseProxy: true},
            null,
            const [],
          ),
        };

    for (final MapEntry(key: state, value: (prefs, saved, wallets))
        in states.entries) {
      for (final size in const [Size(320, 568), Size(360, 640)]) {
        for (final scale in const [1.0, 1.5, 2.0]) {
          testWidgets('$state, ${size.width.toInt()}×${size.height.toInt()}, '
              '${scale}x: no overflow', (tester) async {
            SentinelService.debugIsAndroid = true;
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.reset);
            SharedPreferences.setMockInitialValues(prefs);
            final sp = await SharedPreferences.getInstance();
            final calls = <String>[];
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  ...overridesForScene(
                    ScreenshotScene.walletPrivacy,
                    prefs: sp,
                  ),
                  initialProxyConfigProvider.overrideWithValue(saved),
                  proUnlockedProvider.overrideWith(() => _FixedPro(false)),
                  networkSettingsProvider.overrideWith(
                    () => _RecordingNetworkSettings(calls),
                  ),
                  walletsProvider.overrideWith(
                    () => _RecordingWallets(calls, wallets),
                  ),
                ],
                child: MaterialApp(
                  theme: AppTheme.dark,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: const WalletsScreen(),
                ),
              ),
            );
            await tester.pumpAndSettle();

            expect(tester.takeException(), isNull);
            expect(find.byType(WalletsPitchCard), findsOneWidget);
            expect(find.text('looked up over Tor'), findsOneWidget);
            if (state != 'nothing on') {
              expect(_byTypeName('_SwitchOffRow'), findsWidgets);
            }
          });
        }
      }
    }
  });
}
