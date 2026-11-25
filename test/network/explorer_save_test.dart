/// The custom explorer's Save and Test on the Wallets screen: what is
/// refused before any request (R-2, R-3), what a failed test leaves behind
/// (R-4), the notes under a saved URL, and the state's own hygiene (M-4,
/// M-5). Real loopback sockets, as in explorer_route_gate_test.dart.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/app.dart';
import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/mock/mock_providers.dart';
import 'package:bag/mock/scenes.dart';
import 'package:bag/models/network_settings.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/services/network/explorer_url.dart';
import 'package:bag/services/network/route_gate.dart';

/// A loopback HTTP server. Counts requests and connections, and answers
/// with [reply] (null: never answers).
class _Node {
  _Node._(this._server) {
    _server.listen((request) {
      hits++;
      final r = reply;
      if (r == null) {
        held.add(request);
        return;
      }
      r(request);
    });
  }

  final HttpServer _server;
  int hits = 0;
  final held = <HttpRequest>[];
  void Function(HttpRequest request)? reply;

  int get port => _server.port;
  String get url => 'http://127.0.0.1:$port';

  /// Open connections, idle keep-alive ones included.
  int get connections => _server.connectionsInfo().total;

  static Future<_Node> start() async =>
      _Node._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> close() => _server.close(force: true);
}

void _json(HttpRequest request, String body) {
  request.response
    ..headers.contentType = ContentType.json
    ..write(body);
  request.response.close();
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
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
  });

  late _Node node;

  Future<ProviderContainer> pumpWallets(
    WidgetTester tester, {
    String savedUrl = '',
    bool tor = false,
  }) async {
    node = (await tester.runAsync(_Node.start))!;
    addTearDown(() => tester.runAsync(node.close));
    RouteGate.debugProbeOverride = (_) async => RouteStatus.available;

    tester.view.physicalSize = const Size(1100, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({
      AppConstants.keyUseTor: tor,
      AppConstants.keyExplorerPreset: ExplorerPreset.custom.index,
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overridesForScene(ScreenshotScene.walletPrivacy, prefs: prefs),
          initialExplorerUrlProvider.overrideWithValue(savedUrl),
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

  final urlField = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == 'http://yournode.onion',
  );

  /// Taps [finder] in the real zone, so the handler's sockets are real, then
  /// alternates real time and fake pumps: the settings notifier lives in
  /// the fake zone, and its serial chain needs both to finish a save.
  Future<void> tapForReal(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    for (var i = 0; i < 3; i++) {
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    await tester.pumpAndSettle();
  }

  Future<void> typeAndSave(WidgetTester tester, String url) async {
    await tester.ensureVisible(urlField);
    await tester.enterText(urlField, url);
    await tapForReal(tester, find.text('Save').last);
  }

  group('Save (R-4)', () {
    testWidgets('a server that does not answer as Esplora is not saved: edit '
        'mode stays, with the failure and a "Save anyway"', (tester) async {
      final c = await pumpWallets(tester);
      node.reply = (r) => _json(r, '{"ok":true}');

      await typeAndSave(tester, node.url);

      expect(node.hits, greaterThan(0));
      expect(c.read(networkSettingsProvider).customUrl, '');
      expect(urlField, findsOneWidget, reason: 'still editing');
      expect(
        find.text('Could not reach server — check the address and try again.'),
        findsOneWidget,
      );
      final saveAnyway = find.widgetWithText(TextButton, 'Save anyway');
      expect(saveAnyway, findsOneWidget);

      // The second tap saves it.
      await tapForReal(tester, saveAnyway);
      expect(c.read(networkSettingsProvider).customUrl, node.url);
      expect(urlField, findsNothing, reason: 'edit mode closed');
    });

    testWidgets('editing the URL after a failed test withdraws "Save anyway"',
        (tester) async {
      final c = await pumpWallets(tester);
      node.reply = (r) => _json(r, '{"ok":true}');
      await typeAndSave(tester, node.url);
      expect(find.text('Save anyway'), findsOneWidget);

      await tester.enterText(urlField, '${node.url}/other');
      await tester.pump();
      expect(find.text('Save anyway'), findsNothing);
      expect(c.read(networkSettingsProvider).customUrl, '');
    });

    testWidgets('an Esplora server is saved at once', (tester) async {
      final c = await pumpWallets(tester);
      node.reply = (r) => _json(r, '{"chain_stats":{},"mempool_stats":{}}');

      await typeAndSave(tester, '${node.url}/');

      expect(c.read(networkSettingsProvider).customUrl, node.url);
      expect(find.text('Connected — endpoint detected'), findsOneWidget);
      expect(find.text('Save anyway'), findsNothing);
    });
  });

  group('refused before any request', () {
    testWidgets('plain http to a public host (R-3)', (tester) async {
      final c = await pumpWallets(tester);
      await typeAndSave(tester, 'http://node.example');
      expect(find.text(plainHttpRefusedMessage), findsOneWidget);
      expect(find.text('Save anyway'), findsNothing);
      expect(c.read(networkSettingsProvider).customUrl, '');
    });

    testWidgets('.onion on a direct route (R-2)', (tester) async {
      final c = await pumpWallets(tester);
      await typeAndSave(tester, 'abcdefgh.onion');
      expect(find.text(onionNeedsTorMessage), findsWidgets);
      expect(find.text('Save anyway'), findsNothing);
      expect(c.read(networkSettingsProvider).customUrl, '');
    });
  });

  group('notes under a saved URL', () {
    testWidgets('a plain-http public URL saved earlier warns (R-3)',
        (tester) async {
      await pumpWallets(tester, savedUrl: 'http://node.example');
      expect(find.text(unencryptedExplorerWarning), findsOneWidget);
    });

    testWidgets('a LAN http URL does not', (tester) async {
      await pumpWallets(tester, savedUrl: 'http://192.168.1.20:3002');
      expect(find.text(unencryptedExplorerWarning), findsNothing);
    });

    testWidgets('a saved .onion on a direct route keeps the onion note (R-2)',
        (tester) async {
      await pumpWallets(tester, savedUrl: 'http://abcdefgh.onion');
      expect(find.text(onionNeedsTorMessage), findsOneWidget);
    });

    testWidgets('foo.onion.example.com over Tor is not taken for an onion '
        'service (R-2)', (tester) async {
      await pumpWallets(
        tester,
        savedUrl: 'https://foo.onion.example.com',
        tor: true,
      );
      expect(
        find.text('Tor is enabled — use an .onion address for full privacy.'),
        findsOneWidget,
      );
    });

    testWidgets('Test on a saved .onion on a direct route makes no request',
        (tester) async {
      await pumpWallets(tester, savedUrl: 'http://abcdefgh.onion');
      final test = find.byTooltip('Test connection');
      await tester.ensureVisible(test);
      await tapForReal(tester, test);
      // The note and the test result say the same.
      expect(find.text(onionNeedsTorMessage), findsNWidgets(2));
    });
  });

  group('state hygiene', () {
    testWidgets('Test connection closes its client when done (M-5)',
        (tester) async {
      await pumpWallets(tester, savedUrl: 'http://127.0.0.1:1');
      // Re-point at the node now that its port is known.
      final c = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold).first),
      );
      await tester.runAsync(
        () => c.read(networkSettingsProvider.notifier).setCustomUrl(node.url),
      );
      await tester.pumpAndSettle();
      node.reply = (r) => _json(r, '812345');

      final test = find.byTooltip('Test connection');
      await tester.ensureVisible(test);
      await tapForReal(tester, test);

      expect(find.text('Connected — block height 812345'), findsOneWidget);
      expect(node.hits, 1);
      // A client left open would keep its keep-alive socket for 15 s.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      expect(node.connections, 0);
    });

    testWidgets('Save closes its client when done (M-5)', (tester) async {
      await pumpWallets(tester);
      node.reply = (r) => _json(r, '{"chain_stats":{},"mempool_stats":{}}');
      await typeAndSave(tester, node.url);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      expect(node.hits, 1);
      expect(node.connections, 0);
    });

    testWidgets('a test that fails after the screen is gone does not touch '
        'the disposed state either (M-4)', (tester) async {
      final c = await pumpWallets(tester, savedUrl: 'http://127.0.0.1:1');
      await tester.runAsync(
        () => c.read(networkSettingsProvider.notifier).setCustomUrl(node.url),
      );
      await tester.pumpAndSettle();

      final test = find.byTooltip('Test connection');
      await tester.ensureVisible(test);
      await tester.runAsync(() async {
        await tester.tap(test);
        for (var i = 0; i < 100 && node.held.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(node.held, hasLength(1));

      await tester.pumpWidget(const SizedBox());
      // The node drops the connection: the request fails.
      await tester.runAsync(() async {
        await node.close();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('leaving the screen during a test does not touch the '
        'disposed state (M-4)', (tester) async {
      final c = await pumpWallets(tester, savedUrl: 'http://127.0.0.1:1');
      await tester.runAsync(
        () => c.read(networkSettingsProvider.notifier).setCustomUrl(node.url),
      );
      await tester.pumpAndSettle();
      // Holds the request until released.

      final test = find.byTooltip('Test connection');
      await tester.ensureVisible(test);
      await tester.runAsync(() async {
        await tester.tap(test);
        for (var i = 0; i < 100 && node.held.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(node.held, hasLength(1));

      // The screen goes away, then the node answers.
      await tester.pumpWidget(const SizedBox());
      final errors = <Object>[];
      await tester.runAsync(() async {
        await runZonedGuarded(() async {
          final request = node.held.single;
          request.response.write('812345');
          await request.response.close();
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }, (e, _) => errors.add(e));
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(errors, isEmpty);
    });
  });
}
