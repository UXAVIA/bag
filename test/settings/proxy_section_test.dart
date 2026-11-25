import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpOverrides;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/core/theme/app_theme.dart';
import 'package:bag/features/settings/presentation/proxy_section.dart';
import 'package:bag/features/wallets/presentation/wallets_screen.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/route_status_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/services/embedded_tor_service.dart';
import 'package:bag/services/tor_host.dart';
import 'package:bag/services/network/network_route_store.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/services/network/routed_http.dart';

import '../network/fake_proxies.dart';

/// What a failed test request throws when it goes through [route] to [url].
Future<Object> failureThrough(
  NetworkRoute route,
  String url, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final dio = buildRoutedDio(route: route, clearnetTimeout: timeout);
  dio.options
    ..connectTimeout = timeout
    ..receiveTimeout = timeout;
  try {
    await dio.get<Object?>(url);
  } catch (e) {
    return e;
  } finally {
    dio.close(force: true);
  }
  fail('request through the proxy unexpectedly succeeded');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The test binding swaps in an HttpClient that answers every request with
  // 400, which would hide the proxy entirely. These tests need real sockets.
  setUp(() => HttpOverrides.global = null);

  group('classifyProxyTestError, against real errors from the fakes', () {
    late TargetServer target;

    setUp(() async => target = await TargetServer.start());
    tearDown(() => target.close());

    String url() => 'http://bag-test.invalid:${target.port}/';

    ProxyRoute socks({String? user, String? pass, required int port}) =>
        ProxyRoute(
          ProxyConfig(
            type: ProxyType.socks5,
            host: '127.0.0.1',
            port: port,
            username: user,
            password: pass,
          ),
        );

    ProxyRoute http({String? user, String? pass, required int port}) =>
        ProxyRoute(
          ProxyConfig(
            type: ProxyType.http,
            host: '127.0.0.1',
            port: port,
            username: user,
            password: pass,
          ),
        );

    test('SOCKS5 wrong password is authRejected', () async {
      final proxy = await FakeSocks5Proxy.start(
        username: 'alice',
        password: 'right',
        targetPort: target.port,
      );
      addTearDown(proxy.close);
      final error = await failureThrough(
        socks(user: 'alice', pass: 'wrong', port: proxy.port),
        url(),
      );
      expect(
        classifyProxyTestError(error, hadCredentials: true),
        ProxyTestResult.authRejected,
      );
    });

    test('SOCKS5 login required but none given is authRequired', () async {
      final proxy = await FakeSocks5Proxy.start(
        username: 'alice',
        password: 'right',
        targetPort: target.port,
      );
      addTearDown(proxy.close);
      final error = await failureThrough(socks(port: proxy.port), url());
      expect(
        classifyProxyTestError(error, hadCredentials: false),
        ProxyTestResult.authRequired,
      );
    });

    test('SOCKS5 CONNECT refusal is requestFailed', () async {
      final proxy = await FakeSocks5Proxy.start(
        targetPort: target.port,
        connectReplyCode: 0x05,
      );
      addTearDown(proxy.close);
      final error = await failureThrough(socks(port: proxy.port), url());
      expect(
        classifyProxyTestError(error, hadCredentials: false),
        ProxyTestResult.requestFailed,
      );
    });

    test('a proxy that answers with garbage is requestFailed', () async {
      final proxy = await FakeSocks5Proxy.start(
        targetPort: target.port,
        payload: utf8.encode('not http at all\r\n\r\n'),
      );
      addTearDown(proxy.close);
      final error = await failureThrough(socks(port: proxy.port), url());
      expect(
        classifyProxyTestError(error, hadCredentials: false),
        ProxyTestResult.requestFailed,
      );
    });

    test('HTTP proxy 407 on CONNECT (https): wrong password', () async {
      final proxy = await FakeHttpProxy.start(
        username: 'alice',
        password: 'right',
        targetPort: target.port,
      );
      addTearDown(proxy.close);
      final error = await failureThrough(
        http(user: 'alice', pass: 'wrong', port: proxy.port),
        'https://bag-test.invalid/',
      );
      expect(
        classifyProxyTestError(error, hadCredentials: true),
        ProxyTestResult.authRejected,
      );
    });

    test('HTTP proxy 407 on CONNECT (https): no credentials', () async {
      final proxy = await FakeHttpProxy.start(
        username: 'alice',
        password: 'right',
        targetPort: target.port,
      );
      addTearDown(proxy.close);
      final error = await failureThrough(
        http(port: proxy.port),
        'https://bag-test.invalid/',
      );
      expect(
        classifyProxyTestError(error, hadCredentials: false),
        ProxyTestResult.authRequired,
      );
    });

    test('HTTP proxy 407 on an absolute-form request (http)', () async {
      final proxy = await FakeHttpProxy.start(
        username: 'alice',
        password: 'right',
        targetPort: target.port,
      );
      addTearDown(proxy.close);
      final wrong = await failureThrough(
        http(user: 'alice', pass: 'wrong', port: proxy.port),
        url(),
      );
      expect(
        classifyProxyTestError(wrong, hadCredentials: true),
        ProxyTestResult.authRejected,
      );
      final none = await failureThrough(http(port: proxy.port), url());
      expect(
        classifyProxyTestError(none, hadCredentials: false),
        ProxyTestResult.authRequired,
      );
    });

    test('a dead port is unreachable, for both proxy types', () async {
      final dead = await FakeSocks5Proxy.start(targetPort: target.port);
      final port = dead.port;
      await dead.close();

      final viaSocks = await failureThrough(socks(port: port), url());
      expect(
        classifyProxyTestError(viaSocks, hadCredentials: false),
        ProxyTestResult.unreachable,
      );
      final viaHttp = await failureThrough(http(port: port), url());
      expect(
        classifyProxyTestError(viaHttp, hadCredentials: false),
        ProxyTestResult.unreachable,
      );
    });
  });

  group('ProxySection', () {
    final widgetFlagWrites = <MapEntry<String, Object?>>[];

    setUp(() {
      widgetFlagWrites.clear();
      FlutterSecureStorage.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('home_widget'), (
            call,
          ) async {
            if (call.method == 'saveWidgetData') {
              final args = call.arguments as Map;
              widgetFlagWrites.add(
                MapEntry(args['id'] as String, args['data']),
              );
              return true;
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
      RouteGate.debugProbeOverride = null;
    });

    late ProviderContainer container;

    Future<void> pumpSection(
      WidgetTester tester, {
      Map<String, Object> prefs = const {},
      ProxyConfig? saved,
      String? testUrl,
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      final sp = await tester.runAsync(SharedPreferences.getInstance);
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sp!),
          initialProxyConfigProvider.overrideWithValue(saved),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: ProxySection(testUrl: testUrl),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> enter(WidgetTester tester, String key, String text) async {
      await tester.enterText(find.byKey(Key(key)), text);
    }

    Future<void> tapButton(WidgetTester tester, String key) async {
      final finder = find.byKey(Key(key));
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pump();
    }

    /// Taps with the real clock running, so the socket work the tap starts
    /// is not stuck behind the test's fake-async zone.
    Future<void> tapRealIo(WidgetTester tester, String key) async {
      final finder = find.byKey(Key(key));
      await tester.ensureVisible(finder);
      await tester.runAsync(() => tester.tap(finder));
      await tester.pump();
    }

    /// Lets real socket I/O run, then rebuilds, until [done] or ~10 s.
    Future<void> settleIo(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
    }

    /// Like `find.textContaining`, but only for [Text] widgets: a text field's
    /// own (obscured) content is not on-screen text.
    Finder plainTextContaining(String needle) => find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').contains(needle),
    );

    bool switchEnabled(WidgetTester tester) =>
        tester
            .widget<Switch>(find.byKey(const Key('proxy-switch')))
            .onChanged !=
        null;

    testWidgets('port 70000 shows the error and saves nothing', (tester) async {
      await pumpSection(tester);
      await enter(tester, 'proxy-host', '10.0.0.5');
      await enter(tester, 'proxy-port', '70000');
      await tapButton(tester, 'proxy-save');

      expect(find.textContaining('Port must be 1–65535'), findsOneWidget);
      expect(container.read(networkSettingsProvider).proxy, isNull);
      expect(switchEnabled(tester), isFalse);
      expect(await tester.runAsync(loadProxyConfig), isNull);
    });

    testWidgets('a username without a password never reaches the notifier', (
      tester,
    ) async {
      await pumpSection(tester);
      await enter(tester, 'proxy-host', '10.0.0.5');
      await enter(tester, 'proxy-port', '1080');
      await enter(tester, 'proxy-username', 'alice');
      await tapButton(tester, 'proxy-save');

      expect(
        find.text('Enter both a username and a password, or neither.'),
        findsOneWidget,
      );
      expect(container.read(networkSettingsProvider).proxy, isNull);
    });

    testWidgets('a valid save trims, stores and enables the switch; the '
        'switch selects a ProxyRoute and turns Tor off', (tester) async {
      await pumpSection(tester, prefs: {AppConstants.keyUseTor: true});
      expect(switchEnabled(tester), isFalse);

      await enter(tester, 'proxy-host', '  10.0.0.5 ');
      await enter(tester, 'proxy-port', ' 1080');
      await tapButton(tester, 'proxy-save');
      await tester.pump();

      const expected = ProxyConfig(
        type: ProxyType.socks5,
        host: '10.0.0.5',
        port: 1080,
      );
      expect(container.read(networkSettingsProvider).proxy, expected);
      expect(await tester.runAsync(loadProxyConfig), expected);
      expect(switchEnabled(tester), isTrue);
      // Saving alone does not switch it on.
      expect(container.read(networkSettingsProvider).route, const TorRoute());

      await tapRealIo(tester, 'proxy-switch');
      await settleIo(
        tester,
        () => container.read(networkSettingsProvider).useProxy,
      );

      final settings = container.read(networkSettingsProvider);
      expect(settings.route, const ProxyRoute(expected));
      expect(settings.useTor, isFalse);
      expect(
        tester.widget<Switch>(find.byKey(const Key('proxy-switch'))).value,
        isTrue,
      );
    });

    testWidgets('blank credentials are saved as null', (tester) async {
      await pumpSection(tester);
      await enter(tester, 'proxy-host', 'proxy.lan');
      await enter(tester, 'proxy-port', '3128');
      await enter(tester, 'proxy-username', '  ');
      await tester.tap(find.text('HTTP'));
      await tester.pump();
      await tapButton(tester, 'proxy-save');
      await tester.pump();

      final proxy = container.read(networkSettingsProvider).proxy!;
      expect(proxy.type, ProxyType.http);
      expect(proxy.username, isNull);
      expect(proxy.password, isNull);
    });

    testWidgets('prefills from the saved config and Remove clears it', (
      tester,
    ) async {
      const saved = ProxyConfig(
        type: ProxyType.http,
        host: 'proxy.lan',
        port: 3128,
        username: 'alice',
        password: 'hunter2',
      );
      await pumpSection(tester, saved: saved);

      expect(find.text('proxy.lan'), findsOneWidget);
      expect(find.text('3128'), findsOneWidget);
      expect(find.text('Saved: proxy.lan:3128'), findsOneWidget);
      // The password sits obscured in its field and in no label.
      expect(plainTextContaining('hunter2'), findsNothing);
      expect(switchEnabled(tester), isTrue);

      await tapRealIo(tester, 'proxy-remove');
      await settleIo(
        tester,
        () => container.read(networkSettingsProvider).proxy == null,
      );
      await tester.pump();

      expect(container.read(networkSettingsProvider).proxy, isNull);
      expect(find.text('proxy.lan'), findsNothing);
      expect(switchEnabled(tester), isFalse);
    });

    testWidgets('Remove on the active proxy asks first; Cancel keeps it '
        '(M-16)', (tester) async {
      const saved = ProxyConfig(
        type: ProxyType.socks5,
        host: 'proxy.lan',
        port: 1080,
      );
      await pumpSection(
        tester,
        saved: saved,
        prefs: {AppConstants.keyUseProxy: true},
      );
      expect(container.read(networkSettingsProvider).route,
          const ProxyRoute(saved));

      // Real zone throughout: the route setters reach a static serial chain
      // in WidgetService, which must not be left on this test's fake zone.
      await tapRealIo(tester, 'proxy-remove');
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Remove proxy?'), findsOneWidget);
      expect(
        find.text('Bag will connect directly until you set up Tor or a proxy.'),
        findsOneWidget,
      );

      await tester.runAsync(
        () => tester.tap(find.widgetWithText(TextButton, 'Cancel')),
      );
      // Long enough for a removal to land, had Cancel started one.
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
      }
      expect(find.byType(AlertDialog), findsNothing);
      expect(container.read(networkSettingsProvider).route,
          const ProxyRoute(saved));
      expect(container.read(networkSettingsProvider).proxy, saved);

      // Asked again, and confirmed this time.
      await tapRealIo(tester, 'proxy-remove');
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(TextButton, 'Remove'),
          ),
        ),
      );
      await settleIo(
        tester,
        () => container.read(networkSettingsProvider).proxy == null,
      );
      expect(container.read(networkSettingsProvider).proxy, isNull);
      expect(container.read(networkSettingsProvider).route, const DirectRoute());
    });

    testWidgets('a proxy that is on but unreadable can still be switched '
        'off, and says so', (tester) async {
      // main() passes null when the saved entry is unreadable.
      await pumpSection(tester, prefs: {AppConstants.keyUseProxy: true});
      expect(
        container.read(networkSettingsProvider).route,
        const MisconfiguredProxyRoute(),
      );

      expect(
        find.text(
          'Saved proxy could not be read — re-enter it or switch the proxy '
          'off.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Save one below to switch it on'),
        findsNothing,
      );
      expect(
        tester.widget<Switch>(find.byKey(const Key('proxy-switch'))).value,
        isTrue,
      );
      expect(switchEnabled(tester), isTrue);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('proxy-remove')))
            .onPressed,
        isNotNull,
      );

      await tapRealIo(tester, 'proxy-switch');
      await settleIo(
        tester,
        () => !container.read(networkSettingsProvider).useProxy,
      );

      expect(container.read(networkSettingsProvider).route, const DirectRoute());
      expect(
        container.read(sharedPreferencesProvider).getBool(
          AppConstants.keyUseProxy,
        ),
        isFalse,
      );
      expect(find.textContaining('could not be read'), findsNothing);
      // Off with nothing saved: back to the normal locked state.
      expect(switchEnabled(tester), isFalse);
    });

    testWidgets('Test connection through a SOCKS5 proxy reports success, '
        'without saving, and locks the controls meanwhile', (tester) async {
      final target = (await tester.runAsync(TargetServer.start))!;
      final proxy = (await tester.runAsync(
        () => FakeSocks5Proxy.start(targetPort: target.port),
      ))!;
      addTearDown(() async {
        await target.close();
        await proxy.close();
      });

      await pumpSection(
        tester,
        testUrl: 'http://bag-test.invalid:${target.port}/',
      );
      await enter(tester, 'proxy-host', '127.0.0.1');
      await enter(tester, 'proxy-port', '${proxy.port}');
      await tapRealIo(tester, 'proxy-test');

      // In flight: every action is disabled so taps can't interleave.
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('proxy-save')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('proxy-test')))
            .onPressed,
        isNull,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(switchEnabled(tester), isFalse);

      await settleIo(
        tester,
        () => find.text('Connected through proxy').evaluate().isNotEmpty,
      );

      expect(find.text('Connected through proxy'), findsOneWidget);
      expect(proxy.connectHosts, ['bag-test.invalid']);
      // Testing never saves.
      expect(container.read(networkSettingsProvider).proxy, isNull);
    });

    testWidgets('a wrong password reports the rejection and never shows it', (
      tester,
    ) async {
      final target = (await tester.runAsync(TargetServer.start))!;
      final proxy = (await tester.runAsync(
        () => FakeSocks5Proxy.start(
          username: 'alice',
          password: 'right',
          targetPort: target.port,
        ),
      ))!;
      addTearDown(() async {
        await target.close();
        await proxy.close();
      });

      await pumpSection(
        tester,
        testUrl: 'http://bag-test.invalid:${target.port}/',
      );
      await enter(tester, 'proxy-host', '127.0.0.1');
      await enter(tester, 'proxy-port', '${proxy.port}');
      await enter(tester, 'proxy-username', 'alice');
      await enter(tester, 'proxy-password', 'wrongpass');
      await tapRealIo(tester, 'proxy-test');
      await settleIo(
        tester,
        () => find
            .text('Proxy rejected the username or password')
            .evaluate()
            .isNotEmpty,
      );

      expect(
        find.text('Proxy rejected the username or password'),
        findsOneWidget,
      );
      expect(plainTextContaining('wrongpass'), findsNothing);
    });

    testWidgets('a dead proxy reports unreachable', (tester) async {
      final dead = (await tester.runAsync(
        () => FakeSocks5Proxy.start(targetPort: 9),
      ))!;
      final port = dead.port;
      await tester.runAsync(dead.close);

      await pumpSection(tester, testUrl: 'http://bag-test.invalid:9/');
      await enter(tester, 'proxy-host', '127.0.0.1');
      await enter(tester, 'proxy-port', '$port');
      await tapRealIo(tester, 'proxy-test');
      await settleIo(
        tester,
        () => find.text('Could not reach the proxy').evaluate().isNotEmpty,
      );

      expect(find.text('Could not reach the proxy'), findsOneWidget);
    });

    testWidgets('the note about what the proxy sees is shown verbatim', (
      tester,
    ) async {
      await pumpSection(tester);
      expect(
        find.text(
          'The proxy sees which servers Bag connects to, but not what is '
          'sent — that stays encrypted. Proxy usernames and passwords travel '
          "unencrypted to the proxy, so only use credentials you don't use "
          'elsewhere.',
        ),
        findsOneWidget,
      );
    });
  });

  group('Network card on WalletsScreen', () {
    const proxy = ProxyConfig(
      type: ProxyType.socks5,
      host: '10.0.0.5',
      port: 1080,
    );

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      EmbeddedTorService.debugBackend = _ReadyTorBackend();
      // The UI isolate with Tor selected: TorHost starts nothing with neither
      // a route nor a route check (N-f).
      TorHost.routeChanged(tor: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('home_widget'),
            (_) async => true,
          );
    });

    tearDown(() async {
      await EmbeddedTorService.stop();
      EmbeddedTorService.debugReset();
      EmbeddedTorService.debugBackend = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
    });

    Future<ProviderContainer> pumpScreen(
      WidgetTester tester,
      Map<String, Object> prefs, {
      Size size = const Size(800, 3200),
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      final sp = (await tester.runAsync(SharedPreferences.getInstance))!;
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sp),
          initialProxyConfigProvider.overrideWithValue(proxy),
          // A successful probe of whatever route is selected: a reachable
          // proxy, or the always-available direct route.
          routeStatusProvider.overrideWith(_AvailableStatus.new),
          // The Network card is in the Wallets tab's Pro layout only; the
          // free layout is pinned by test/pro/action_locks_test.dart.
          proUnlockedProvider.overrideWith(_ProUser.new),
        ],
      );
      addTearDown(container.dispose);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const WalletsScreen(),
          ),
        ),
      );
      await tester.pump();
      return container;
    }

    Switch torSwitch(WidgetTester tester) => tester.widget<Switch>(
      find
          .descendant(
            of: find.ancestor(
              of: find.text('Route through Tor'),
              matching: find.byType(Row),
            ),
            matching: find.byType(Switch),
          )
          .first,
    );

    testWidgets('on a 320×568 phone the Save / Test connection / Remove row '
        'fits, with no overflow', (tester) async {
      await pumpScreen(tester, {
        AppConstants.keyUseProxy: true,
      }, size: const Size(320, 568));

      expect(tester.takeException(), isNull);
      for (final key in ['proxy-save', 'proxy-test', 'proxy-remove']) {
        final button = find.byKey(Key(key));
        expect(button, findsOneWidget, reason: key);
        expect(tester.getTopLeft(button).dx, greaterThanOrEqualTo(0));
        expect(
          tester.getTopRight(button).dx,
          lessThanOrEqualTo(320),
          reason: key,
        );
      }
    });

    testWidgets('a reachable proxy, with a ready Tor client, does not read '
        'as "Connected through Tor"', (tester) async {
      await tester.runAsync(EmbeddedTorService.ensureStarted);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      await pumpScreen(tester, {AppConstants.keyUseProxy: true});

      expect(find.text('Connected through Tor'), findsNothing);
      expect(find.text('Tor is off'), findsOneWidget);
      expect(torSwitch(tester).value, isFalse);
    });

    testWidgets('Tor is reported connected only while Tor is the route', (
      tester,
    ) async {
      await tester.runAsync(EmbeddedTorService.ensureStarted);
      await pumpScreen(tester, {AppConstants.keyUseTor: true});

      expect(find.text('Connected through Tor'), findsOneWidget);
      expect(find.text('Tor is off'), findsNothing);
      expect(torSwitch(tester).value, isTrue);
    });

    testWidgets('turning the proxy on turns the Tor switch off', (
      tester,
    ) async {
      await tester.runAsync(EmbeddedTorService.ensureStarted);
      final container = await pumpScreen(tester, {
        AppConstants.keyUseTor: true,
      });
      expect(torSwitch(tester).value, isTrue);
      expect(find.text('Connected through Tor'), findsOneWidget);

      final proxySwitch = find.byKey(const Key('proxy-switch'));
      await tester.ensureVisible(proxySwitch);
      await tester.runAsync(() => tester.tap(proxySwitch));
      await tester.pump();
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (container.read(networkSettingsProvider).useProxy) break;
      }

      expect(
        container.read(networkSettingsProvider).route,
        const ProxyRoute(proxy),
      );
      expect(torSwitch(tester).value, isFalse);
      // Switching away stopped the client: nothing reads as connected.
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(find.text('Connected through Tor'), findsNothing);
      expect(find.text('Tor is off'), findsOneWidget);
    });
  });
}

class _ProUser extends ProUnlockedNotifier {
  @override
  bool build() => true;
}

class _AvailableStatus extends RouteStatusNotifier {
  @override
  Future<RouteStatus> build() async => RouteStatus.available;
}

/// A built-in Tor client that bootstraps at once.
class _ReadyTorBackend implements EmbeddedTorBackend {
  bool _bootstrapped = false;
  final _failures = StreamController<Object>.broadcast();
  final _events = StreamController<int>.broadcast();

  @override
  Stream<Object> get failures => _failures.stream;

  @override
  Stream<int> get events => _events.stream;

  @override
  bool get bootstrapped => _bootstrapped;

  @override
  int get port => _bootstrapped ? 47123 : -1;

  @override
  Future<void> start() async => _bootstrapped = true;

  @override
  Future<void> bootstrap() async {}

  @override
  Future<void> setDormant(bool dormant) async {}

  @override
  Future<void> stop() async => _bootstrapped = false;
}
