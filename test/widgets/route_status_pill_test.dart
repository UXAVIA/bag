/// The connection pill at the top of Home and the Wallets tab (Task B5).
///
/// It names the route every request takes, and whether that route is up, in
/// the mockup's words: `Tor`, `Tor connecting…`, `Tor paused`, `Proxy`,
/// `Proxy paused`, `Direct`. Its only source is `routeStatusProvider`, which
/// on iOS Tor already mirrors the built-in client (ruling R-B5b), so the pill
/// has no platform switch. A tap opens the Wallets tab, scrolled to Network
/// for a Pro user (ruling R-B5c).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/app.dart';
import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/core/theme/app_theme.dart';
import 'package:bag/features/home/presentation/home_screen.dart';
import 'package:bag/features/wallets/presentation/wallets_screen.dart';
import 'package:bag/mock/mock_providers.dart';
import 'package:bag/mock/scenes.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/network_settings.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/route_status_provider.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/widgets/route_status_pill.dart';

/// Settings the test sets directly, so it can change one field at a time.
class _Settings extends NetworkSettingsNotifier {
  _Settings(this._initial);

  final NetworkSettings _initial;

  @override
  NetworkSettings build() => _initial;

  void set(NetworkSettings next) => state = next;
}

/// A fixed status; null is a probe that never answers (still loading).
class _Status extends RouteStatusNotifier {
  _Status(this._initial);

  final RouteStatus? _initial;

  @override
  FutureOr<RouteStatus> build() => _initial ?? Completer<RouteStatus>().future;
}

/// Up on the first probe; every later probe never answers, so a rebuild
/// leaves the provider reloading with the first answer as its value: what a
/// route change does to the real provider.
class _ReprobedStatus extends RouteStatusNotifier {
  var _probes = 0;

  @override
  FutureOr<RouteStatus> build() =>
      _probes++ == 0 ? RouteStatus.available : Completer<RouteStatus>().future;
}

/// A probe that fails outright: an error, never an answer.
class _FailingStatus extends RouteStatusNotifier {
  @override
  FutureOr<RouteStatus> build() => throw StateError('probe failed');
}

/// The real settings, with every setter recorded.
class _RecordingSettings extends NetworkSettingsNotifier {
  _RecordingSettings(this.calls);

  final List<String> calls;

  @override
  Future<void> setPreset(ExplorerPreset preset) async => calls.add('setPreset');
  @override
  Future<void> setCustomUrl(String url) async => calls.add('setCustomUrl');
  @override
  Future<void> setUseTor(bool value) async => calls.add('setUseTor($value)');
  @override
  Future<void> setUseProxy(bool value) async =>
      calls.add('setUseProxy($value)');
  @override
  Future<void> saveProxy(ProxyConfig config) async => calls.add('saveProxy');
  @override
  Future<void> clearProxy() async => calls.add('clearProxy');
  @override
  Future<void> reloadProxy() async => calls.add('reloadProxy');
}

class _Pro extends ProUnlockedNotifier {
  _Pro(this._value);

  final bool _value;

  @override
  bool build() => _value;
}

/// Distinctive on purpose: none of it may ever reach the screen.
const _host = 'vault7.secret-proxy.example';
const _port = 48123;
const _user = 'alice-proxy-user';
const _password = 'hunter2-proxy-pass';
const _proxy = ProxyConfig(
  type: ProxyType.socks5,
  host: _host,
  port: _port,
  username: _user,
  password: _password,
);

const _direct = NetworkSettings();
const _tor = NetworkSettings(useTor: true);
const _proxyOn = NetworkSettings(useProxy: true, proxy: _proxy);
const _misconfigured = NetworkSettings(useProxy: true);

const _green = AppColors.positive;
const _orange = AppColors.primary;
const _red = AppColors.negative;

final _pill = find.byType(RouteStatusPill);

/// The status dot: a circle inside the pill.
final _dot = find.descendant(
  of: _pill,
  matching: find.byWidgetPredicate(
    (w) =>
        w is DecoratedBox &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).shape == BoxShape.circle,
    description: 'status dot',
  ),
);

/// The drawn pill: the stadium the label sits on.
Material _shape(WidgetTester tester) => tester.widget<Material>(
  find.descendant(of: _pill, matching: find.byType(Material)),
);

Text _label(WidgetTester tester) => tester.widget<Text>(
  find.descendant(of: _pill, matching: find.byType(Text)),
);

Color _dotColor(WidgetTester tester) =>
    ((tester.widget<DecoratedBox>(_dot)).decoration as BoxDecoration).color!;

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// The pill on its own, centred on a screen.
Future<ProviderContainer> _pumpPill(
  WidgetTester tester, {
  required NetworkSettings settings,
  required RouteStatus? status,
  ThemeData? theme,
  double textScale = 1.0,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        networkSettingsProvider.overrideWith(() => _Settings(settings)),
        routeStatusProvider.overrideWith(() => _Status(status)),
      ],
      child: MaterialApp(
        theme: theme ?? AppTheme.dark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Scaffold(body: Center(child: RouteStatusPill())),
      ),
    ),
  );
  await tester.pump();
  return ProviderScope.containerOf(tester.element(_pill));
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

  // ── Every state ─────────────────────────────────────────────────────────

  group('states (the RouteStatus artboard)', () {
    final cases = <(String, NetworkSettings, RouteStatus?, String, Color?)>[
      ('Tor, available', _tor, RouteStatus.available, 'Tor', _green),
      (
        'Tor, checking (starting)',
        _tor,
        RouteStatus.checking,
        'Tor connecting…',
        _orange,
      ),
      ('Tor, still probing', _tor, null, 'Tor connecting…', _orange),
      (
        'Tor, unavailable (failed or off)',
        _tor,
        RouteStatus.unavailable,
        'Tor paused',
        _red,
      ),
      ('Proxy, available', _proxyOn, RouteStatus.available, 'Proxy', _green),
      // Checking says so in words, as for Tor: the dot alone can't carry it.
      (
        'Proxy, checking',
        _proxyOn,
        RouteStatus.checking,
        'Proxy connecting…',
        _orange,
      ),
      ('Proxy, still probing', _proxyOn, null, 'Proxy connecting…', _orange),
      (
        'Proxy, unavailable',
        _proxyOn,
        RouteStatus.unavailable,
        'Proxy paused',
        _red,
      ),
      for (final status in [...RouteStatus.values, null])
        (
          'unreadable proxy, ${status?.name ?? 'probing'}',
          _misconfigured,
          status,
          'Proxy paused',
          _red,
        ),
      for (final status in [...RouteStatus.values, null])
        (
          'Direct, ${status?.name ?? 'probing'}',
          _direct,
          status,
          'Direct',
          null,
        ),
    ];

    for (final (name, settings, status, label, dot) in cases) {
      testWidgets('$name: "$label", ${dot == null ? 'no dot' : 'dot'}', (
        tester,
      ) async {
        await _pumpPill(tester, settings: settings, status: status);

        expect(
          find.descendant(of: _pill, matching: find.text(label)),
          findsOneWidget,
        );
        if (dot == null) {
          expect(_dot, findsNothing);
        } else {
          expect(_dot, findsOneWidget);
          expect(_dotColor(tester), dot);
        }
      });
    }

    testWidgets('a re-probe reads as checking, not as the answer it '
        'replaces', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            networkSettingsProvider.overrideWith(() => _Settings(_tor)),
            routeStatusProvider.overrideWith(_ReprobedStatus.new),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const Scaffold(body: Center(child: RouteStatusPill())),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Tor'), findsOneWidget);

      final container = ProviderScope.containerOf(tester.element(_pill));
      container.invalidate(routeStatusProvider);
      await tester.pump();

      final status = container.read(routeStatusProvider);
      expect(status.isLoading, isTrue);
      expect(status.valueOrNull, RouteStatus.available);
      await tester.pump();
      expect(find.text('Tor connecting…'), findsOneWidget);
      expect(_dotColor(tester), _orange);
    });

    // Fail closed: a probe that errors reads as down, never as up.
    for (final (route, settings, label) in [
      ('Tor', _tor, 'Tor paused'),
      ('proxy', _proxyOn, 'Proxy paused'),
    ]) {
      testWidgets('$route, the probe throws: "$label", red', (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              networkSettingsProvider.overrideWith(() => _Settings(settings)),
              routeStatusProvider.overrideWith(_FailingStatus.new),
            ],
            child: MaterialApp(
              theme: AppTheme.dark,
              home: const Scaffold(body: Center(child: RouteStatusPill())),
            ),
          ),
        );
        await tester.pump();

        final container = ProviderScope.containerOf(tester.element(_pill));
        expect(container.read(routeStatusProvider).hasError, isTrue);
        expect(
          find.descendant(of: _pill, matching: find.text(label)),
          findsOneWidget,
        );
        expect(_dotColor(tester), _red);
      });
    }

    test('… is the ellipsis character', () {
      expect('Tor connecting…'.runes.last, 0x2026);
    });

    // Colours as drawn on the dark artboard.
    for (final (name, settings, status, fill, edge) in [
      ('ok', _tor, RouteStatus.available, 0xFF0E1F1A, 0xFF1F4D40),
      ('connecting', _tor, RouteStatus.checking, 0xFF1A140A, 0xFF4A3414),
      ('paused', _tor, RouteStatus.unavailable, 0xFF24101A, 0xFF5A1E2A),
    ]) {
      testWidgets('dark, $name: fill, edge and white label as drawn', (
        tester,
      ) async {
        await _pumpPill(tester, settings: settings, status: status);

        final shape = _shape(tester);
        expect(shape.color, Color(fill));
        expect((shape.shape as StadiumBorder).side.color, Color(edge));
        expect(_label(tester).style?.color, const Color(0xFFFFFFFF));
      });
    }

    testWidgets('dark, Direct: surface, outline and muted label as drawn', (
      tester,
    ) async {
      await _pumpPill(tester, settings: _direct, status: null);
      final cs = AppTheme.dark.colorScheme;

      final shape = _shape(tester);
      expect(shape.color, cs.surface); // #13131A
      expect((shape.shape as StadiumBorder).side.color, cs.outline); // #252535
      // Drawn #A9A9C4: muted, but lighter than the secondary text.
      final text = _label(tester).style!.color!;
      expect((text.r * 255).round(), closeTo(0xA9, 2));
      expect((text.g * 255).round(), closeTo(0xA9, 2));
      expect((text.b * 255).round(), closeTo(0xC4, 3));
    });

    testWidgets('sizes as drawn: 28 high, 13 px medium, a 7 px dot 6 px '
        'before the label, 10 px in from the edge', (tester) async {
      await _pumpPill(tester, settings: _tor, status: RouteStatus.available);

      final shape = find.descendant(of: _pill, matching: find.byType(Material));
      expect(tester.getSize(shape).height, 28);
      expect(tester.getSize(_dot), const Size(7, 7));
      final style = _label(tester).style!;
      expect(style.fontSize, 13);
      expect(style.fontWeight, FontWeight.w500);
      final label = find.descendant(of: _pill, matching: find.text('Tor'));
      expect(tester.getTopLeft(_dot).dx - tester.getTopLeft(shape).dx, 10);
      expect(tester.getTopLeft(label).dx - tester.getTopRight(_dot).dx, 6);
      expect(tester.getTopRight(shape).dx - tester.getTopRight(label).dx, 10);
      expect((_shape(tester).shape as StadiumBorder).side.width, 1);
    });

    for (final (name, theme) in [
      ('dark', AppTheme.dark),
      ('light', AppTheme.light),
    ]) {
      for (final (state, settings, status) in [
        ('Tor', _tor, RouteStatus.available),
        ('Tor connecting…', _tor, RouteStatus.checking),
        ('Tor paused', _tor, RouteStatus.unavailable),
        ('Direct', _direct, RouteStatus.available),
      ]) {
        testWidgets('$name, $state: the label meets the contrast guideline', (
          tester,
        ) async {
          final handle = tester.ensureSemantics();
          await _pumpPill(
            tester,
            settings: settings,
            status: status,
            theme: theme,
          );
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          handle.dispose();
        });
      }

      // "Proxy" checking and "Proxy" up differ only by the dot (R-B5a), so
      // the dot must read against its fill in both themes.
      for (final (state, status, hue) in [
        ('up', RouteStatus.available, _green),
        ('checking', RouteStatus.checking, _orange),
        ('down', RouteStatus.unavailable, _red),
      ]) {
        testWidgets('$name, proxy $state: the dot is at least 3:1 against '
            'the fill and keeps its hue', (tester) async {
          await _pumpPill(
            tester,
            settings: _proxyOn,
            status: status,
            theme: theme,
          );
          final dot = _dotColor(tester);
          expect(
            _contrast(dot, _shape(tester).color!),
            greaterThanOrEqualTo(3.0),
          );
          final hsl = HSLColor.fromColor(dot);
          expect(
            hsl.hue,
            closeTo(HSLColor.fromColor(hue).hue, 6),
            reason: 'a darker shade of the same colour, not a new one',
          );
        });
      }
    }
  });

  // ── Privacy ─────────────────────────────────────────────────────────────

  group('never shows a host, port or credential', () {
    for (final status in [...RouteStatus.values, null]) {
      testWidgets('proxy, ${status?.name ?? 'probing'}', (tester) async {
        final handle = tester.ensureSemantics();
        await _pumpPill(tester, settings: _proxyOn, status: status);

        final texts = [
          for (final r in tester.widgetList<RichText>(
            find.descendant(of: _pill, matching: find.byType(RichText)),
          ))
            r.text.toPlainText(),
        ];
        final node = tester.getSemantics(_pill);
        final semantics = <String>[];
        void collect(SemanticsNode n) {
          final d = n.getSemanticsData();
          semantics.addAll([d.label, d.value, d.hint, d.tooltip]);
          n.visitChildren((c) {
            collect(c);
            return true;
          });
        }

        collect(node);
        expect(texts, isNotEmpty);
        for (final secret in [_host, '$_port', _user, _password, 'secret']) {
          for (final s in [...texts, ...semantics]) {
            expect(s, isNot(contains(secret)));
          }
          expect(find.textContaining(secret), findsNothing);
        }
        handle.dispose();
      });
    }
  });

  // ── Semantics and tap target ────────────────────────────────────────────

  group('semantics', () {
    for (final (settings, status, label) in [
      (_tor, RouteStatus.available, 'Tor'),
      (_tor, RouteStatus.checking, 'Tor connecting…'),
      (_tor, RouteStatus.unavailable, 'Tor paused'),
      (_proxyOn, RouteStatus.available, 'Proxy'),
      (_proxyOn, RouteStatus.checking, 'Proxy connecting…'),
      (_proxyOn, RouteStatus.unavailable, 'Proxy paused'),
      (_misconfigured, RouteStatus.available, 'Proxy paused'),
      (_direct, RouteStatus.available, 'Direct'),
    ]) {
      testWidgets('"$label" is one button: "Connection: $label. Open network '
          'settings"', (tester) async {
        final handle = tester.ensureSemantics();
        await _pumpPill(tester, settings: settings, status: status);

        expect(
          tester.getSemantics(_pill),
          isSemantics(
            label: 'Connection: $label. Open network settings',
            isButton: true,
            hasTapAction: true,
          ),
        );
        // The label is the whole of it: the text inside isn't read twice.
        expect(
          find.bySemanticsLabel('Connection: $label. Open network settings'),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel(label), findsNothing);
        handle.dispose();
      });
    }

    testWidgets('the tap target is at least 48 × 48 dp although the pill is '
        'drawn 28 high', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpPill(tester, settings: _tor, status: RouteStatus.available);

      final size = tester.getSize(_pill);
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      handle.dispose();
    });
  });

  // ── Rebuilds ────────────────────────────────────────────────────────────

  group('rebuilds only on a route or status change', () {
    late int builds;

    setUp(() {
      builds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is RouteStatusPill) builds++;
      };
    });
    tearDown(() => debugOnRebuildDirtyWidget = null);

    testWidgets('unrelated settings and a repeated status leave it alone', (
      tester,
    ) async {
      final container = await _pumpPill(
        tester,
        settings: _proxyOn,
        status: RouteStatus.available,
      );
      final settings =
          container.read(networkSettingsProvider.notifier) as _Settings;
      final status = container.read(routeStatusProvider.notifier);
      builds = 0;

      settings.set(_proxyOn.copyWith(preset: ExplorerPreset.mempool));
      await tester.pump();
      settings.set(
        _proxyOn.copyWith(
          preset: ExplorerPreset.custom,
          customUrl: 'https://node.example',
        ),
      );
      await tester.pump();
      // An equal config is the same route.
      settings.set(
        _proxyOn.copyWith(
          proxy: () => const ProxyConfig(
            type: ProxyType.socks5,
            host: _host,
            port: _port,
            username: _user,
            password: _password,
          ),
        ),
      );
      await tester.pump();
      status.setValue(RouteStatus.available);
      await tester.pump();
      expect(builds, 0);

      status.setValue(RouteStatus.unavailable);
      await tester.pump();
      expect(builds, 1);
      expect(find.text('Proxy paused'), findsOneWidget);

      settings.set(_tor);
      await tester.pump();
      expect(builds, 2);
      expect(find.text('Tor paused'), findsOneWidget);
    });

    testWidgets('on Direct, neither the status nor a saved proxy matters', (
      tester,
    ) async {
      final container = await _pumpPill(
        tester,
        settings: _direct,
        status: RouteStatus.available,
      );
      final settings =
          container.read(networkSettingsProvider.notifier) as _Settings;
      builds = 0;

      container
          .read(routeStatusProvider.notifier)
          .setValue(RouteStatus.unavailable);
      await tester.pump();
      // Saved but switched off: still Direct.
      settings.set(_direct.copyWith(proxy: () => _proxy));
      await tester.pump();
      expect(builds, 0);
      expect(find.text('Direct'), findsOneWidget);
    });
  });

  // ── In the app ──────────────────────────────────────────────────────────

  group('in the app', () {
    /// The real app (router, shell, bottom bar) on [location], scene mocks.
    Future<void> pumpApp(
      WidgetTester tester,
      String location, {
      required bool pro,
      Size size = const Size(360, 640),
      double textScale = 1.0,
      ThemeMode theme = ThemeMode.dark,
      Map<String, Object> prefs = const {},
      RouteStatus? status = RouteStatus.unavailable,
      List<String>? settingsCalls,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      SharedPreferences.setMockInitialValues({
        AppConstants.keyThemeMode: theme.name,
        ...prefs,
      });
      final sp = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overridesForScene(ScreenshotScene.walletPrivacy, prefs: sp),
            initialProxyConfigProvider.overrideWithValue(_proxy),
            proUnlockedProvider.overrideWith(() => _Pro(pro)),
            routeStatusProvider.overrideWith(() => _Status(status)),
            if (settingsCalls != null)
              networkSettingsProvider.overrideWith(
                () => _RecordingSettings(settingsCalls),
              ),
          ],
          child: BagApp(onboardingComplete: true, initialLocation: location),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));
    }

    String locationOf(WidgetTester tester) => GoRouter.of(
      tester.element(find.byType(NavigationBar)),
    ).routerDelegate.currentConfiguration.last.matchedLocation;

    Finder onHome(Finder f) =>
        find.descendant(of: find.byType(HomeScreen), matching: f);
    Finder onWallets(Finder f) =>
        find.descendant(of: find.byType(WalletsScreen), matching: f);

    /// The Network heading, if this layout has one the pill scrolls to.
    final networkHeading = find.byWidgetPredicate(
      (w) => w is WalletsScrollAnchor && w.anchor == WalletsAnchor.network,
      description: 'Network anchor',
    );

    /// Whether [f] lies wholly between the Wallets app bar and the bottom bar.
    bool onScreen(WidgetTester tester, Finder f) {
      final rect = tester.getRect(f);
      final top = tester.getBottomLeft(onWallets(find.byType(AppBar))).dy;
      final bottom = tester.getTopLeft(find.byType(NavigationBar)).dy;
      return rect.top >= top && rect.bottom <= bottom;
    }

    double walletsScroll(WidgetTester tester) => tester
        .state<ScrollableState>(onWallets(find.byType(Scrollable)).first)
        .position
        .pixels;

    testWidgets('Home: in the top bar, between the logo and the alerts bell', (
      tester,
    ) async {
      await pumpApp(tester, '/', pro: true);

      final pill = onHome(_pill);
      expect(pill, findsOneWidget);
      final bar = tester.getRect(onHome(find.byType(AppBar)));
      final rect = tester.getRect(pill);
      expect(bar.contains(rect.center), isTrue);
      expect(
        rect.right,
        lessThanOrEqualTo(
          tester.getTopLeft(onHome(find.byTooltip('Price alerts'))).dx,
        ),
      );
    });

    for (final pro in [true, false]) {
      testWidgets('Wallets (${pro ? 'Pro' : 'free'}): beside the Wallets '
          'heading', (tester) async {
        await pumpApp(tester, '/wallets', pro: pro);

        final pill = onWallets(_pill);
        expect(pill, findsOneWidget);
        final title = find.descendant(
          of: onWallets(find.byType(AppBar)),
          matching: find.text('Wallets'),
        );
        expect(title, findsOneWidget);
        expect(
          (tester.getCenter(pill).dy - tester.getCenter(title).dy).abs(),
          lessThan(2),
        );
        expect(tester.getTopRight(pill).dx, 360 - 16);
      });
    }

    testWidgets('Pro: the Network section starts below the fold (so the '
        'next test proves a scroll)', (tester) async {
      await pumpApp(tester, '/', pro: true);
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Wallets'),
        ),
      );
      await tester.pumpAndSettle();

      expect(networkHeading, findsOneWidget);
      expect(onScreen(tester, networkHeading), isFalse);
    });

    testWidgets('Pro, from Home: opens /wallets with the Network section on '
        'screen', (tester) async {
      await pumpApp(tester, '/', pro: true);

      await tester.tap(onHome(_pill));
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(onScreen(tester, networkHeading), isTrue);
    });

    testWidgets('Pro, on Wallets: a tap scrolls to the Network section', (
      tester,
    ) async {
      await pumpApp(tester, '/wallets', pro: true);
      expect(onScreen(tester, networkHeading), isFalse);

      await tester.tap(onWallets(_pill));
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(onScreen(tester, networkHeading), isTrue);
    });

    // A push the router redirects to /wallets (here Sentinel, which this
    // platform lacks) stacks a second Wallets screen on the first.
    testWidgets('Pro, two Wallets screens stacked: no crash, and the tap '
        'scrolls the one on screen', (tester) async {
      await pumpApp(tester, '/wallets', pro: true);
      GoRouter.of(
        tester.element(find.byType(NavigationBar)),
      ).push('/wallets/sentinel');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byType(WalletsScreen, skipOffstage: false),
        findsNWidgets(2),
      );

      await tester.tap(onWallets(_pill));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(onScreen(tester, networkHeading), isTrue);
    });

    testWidgets('free, from Home: opens /wallets at the top', (tester) async {
      await pumpApp(tester, '/', pro: false);

      await tester.tap(onHome(_pill));
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(networkHeading, findsNothing);
      expect(walletsScroll(tester), 0);
    });

    Future<void> scrollWallets(WidgetTester tester, double to) async {
      final position = tester
          .state<ScrollableState>(onWallets(find.byType(Scrollable)).first)
          .position;
      expect(position.maxScrollExtent, greaterThanOrEqualTo(to));
      position.jumpTo(to);
      await tester.pumpAndSettle();
    }

    Future<void> tapNav(WidgetTester tester, String label) async {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('free, from Home after scrolling Wallets: lands at the top', (
      tester,
    ) async {
      // A lapsed user with Tor still on: the switch-off rows make the free
      // layout tall enough to scroll.
      await pumpApp(
        tester,
        '/wallets',
        pro: false,
        prefs: {AppConstants.keyUseTor: true},
      );
      await scrollWallets(tester, 300);
      await tapNav(tester, 'Home');

      await tester.tap(onHome(_pill));
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(walletsScroll(tester), 0);
    });

    testWidgets('free with Tor still on, on Wallets: a tap leaves the scroll, '
        'opens nothing and calls nothing', (tester) async {
      final calls = <String>[];
      await pumpApp(
        tester,
        '/wallets',
        pro: false,
        prefs: {AppConstants.keyUseTor: true},
        settingsCalls: calls,
      );
      expect(onWallets(find.text('Tor is on')), findsOneWidget);
      await scrollWallets(tester, 200);

      await tester.tap(onWallets(_pill));
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(walletsScroll(tester), 200);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(calls, isEmpty);
    });

    testWidgets('free, on Wallets: a tap does nothing', (tester) async {
      await pumpApp(tester, '/wallets', pro: false);

      await tester.tap(onWallets(_pill));
      await tester.pumpAndSettle();

      expect(locationOf(tester), '/wallets');
      expect(walletsScroll(tester), 0);
      expect(find.byType(BottomSheet), findsNothing);
    });

    // The longest label, on the smallest phone, at the largest text.
    for (final theme in [ThemeMode.dark, ThemeMode.light]) {
      for (final (route, prefs, status, label) in [
        (
          'Tor connecting',
          {AppConstants.keyUseTor: true},
          RouteStatus.checking,
          'Tor connecting…',
        ),
        (
          'proxy paused',
          {AppConstants.keyUseProxy: true},
          RouteStatus.unavailable,
          'Proxy paused',
        ),
        (
          'proxy connecting',
          {AppConstants.keyUseProxy: true},
          RouteStatus.checking,
          'Proxy connecting…',
        ),
      ]) {
        for (final pro in [true, false]) {
          testWidgets('320×568, 2.0x, ${theme.name}, $route, '
              '${pro ? 'Pro' : 'free'}: Home fits and the pill keeps clear of '
              'the logo and the bell', (tester) async {
            await pumpApp(
              tester,
              '/',
              pro: pro,
              size: const Size(320, 568),
              textScale: 2.0,
              theme: theme,
              prefs: prefs,
              status: status,
            );

            expect(tester.takeException(), isNull);
            final pill = tester.getRect(onHome(_pill));
            expect(
              find.descendant(of: onHome(_pill), matching: find.text(label)),
              findsOneWidget,
            );
            final logo = tester.getRect(
              find.descendant(
                of: onHome(find.byType(AppBar)),
                matching: find.byType(SvgPicture),
              ),
            );
            final bell = tester.getRect(onHome(find.byTooltip('Price alerts')));
            expect(pill.left, greaterThanOrEqualTo(logo.right));
            expect(pill.right, lessThanOrEqualTo(bell.left));
          });
        }

        for (final pro in [true, false]) {
          testWidgets('320×568, 2.0x, ${theme.name}, $route, '
              '${pro ? 'Pro' : 'free'}: Wallets fits and the pill keeps '
              'clear of the heading', (tester) async {
            await pumpApp(
              tester,
              '/wallets',
              pro: pro,
              size: const Size(320, 568),
              textScale: 2.0,
              theme: theme,
              prefs: prefs,
              status: status,
            );

            expect(tester.takeException(), isNull);
            final pill = tester.getRect(onWallets(_pill));
            expect(
              find.descendant(of: onWallets(_pill), matching: find.text(label)),
              findsOneWidget,
            );
            final title = tester.getRect(
              find.descendant(
                of: onWallets(find.byType(AppBar)),
                matching: find.text('Wallets'),
              ),
            );
            expect(pill.left, greaterThanOrEqualTo(title.right));
            expect(pill.right, lessThanOrEqualTo(320));
          });
        }
      }
    }
  });
}
