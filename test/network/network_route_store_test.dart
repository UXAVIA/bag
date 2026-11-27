import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/network_settings.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/route_status_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/services/network/network_route_store.dart';
import 'package:bag/services/network/route_gate.dart';

const _config = ProxyConfig(
  type: ProxyType.socks5,
  host: '10.0.0.5',
  port: 1080,
  username: 'alice',
  password: 'hunter2',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final widgetWrites = <MapEntry<String, Object?>>[];

  setUp(() {
    widgetWrites.clear();
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'), (
          call,
        ) async {
          if (call.method == 'saveWidgetData') {
            final args = call.arguments as Map;
            widgetWrites.add(MapEntry(args['id'] as String, args['data']));
            return true;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
  });

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  group('proxy config storage', () {
    test('load returns null when nothing is stored', () async {
      expect(await loadProxyConfig(), isNull);
    });

    test('save then load round-trips, including credentials', () async {
      await saveProxyConfig(_config);
      expect(await loadProxyConfig(), _config);
    });

    test('saving null deletes the entry', () async {
      await saveProxyConfig(_config);
      await saveProxyConfig(null);
      expect(await loadProxyConfig(), isNull);
    });

    test(
      'garbage JSON throws ProxyConfigUnreadable without the payload',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          AppConstants.keyNetworkProxy: 'not-json-SECRETVALUE',
        });
        await expectLater(
          loadProxyConfig(),
          throwsA(
            isA<ProxyConfigUnreadable>().having(
              (e) => e.toString(),
              'message',
              isNot(contains('SECRETVALUE')),
            ),
          ),
        );
      },
    );

    test('valid JSON with a bad shape is unreadable', () async {
      FlutterSecureStorage.setMockInitialValues({
        AppConstants.keyNetworkProxy: '{"type":"socks5","host":"h","port":0}',
      });
      await expectLater(
        loadProxyConfig(),
        throwsA(isA<ProxyConfigUnreadable>()),
      );
    });

    test('a stored host that fails isValidProxyHost is unreadable', () async {
      FlutterSecureStorage.setMockInitialValues({
        AppConstants.keyNetworkProxy:
            '{"type":"http","host":"a;DIRECT","port":8080}',
      });
      await expectLater(
        loadProxyConfig(),
        throwsA(isA<ProxyConfigUnreadable>()),
      );
    });
  });

  group('stored entries that are not routable are unreadable', () {
    for (final (name, json) in [
      ('half pair', '{"type":"socks5","host":"h","port":1,"username":"u"}'),
      (
        'empty credentials',
        '{"type":"socks5","host":"h","port":1,"username":"","password":""}',
      ),
      (
        'an HTTP username with ":"',
        '{"type":"http","host":"h","port":1,"username":"a:b","password":"p"}',
      ),
    ]) {
      test(name, () async {
        FlutterSecureStorage.setMockInitialValues({
          AppConstants.keyNetworkProxy: json,
        });
        await expectLater(
          loadProxyConfig(),
          throwsA(isA<ProxyConfigUnreadable>()),
        );
        final prefs = await prefsWith({AppConstants.keyUseProxy: true});
        expect(
          await readNetworkRoute(prefs),
          const MisconfiguredProxyRoute(),
        );
      });
    }
  });

  group('readNetworkRoute', () {
    test('no flags -> DirectRoute', () async {
      expect(await readNetworkRoute(await prefsWith({})), const DirectRoute());
    });

    test('use_tor -> TorRoute', () async {
      final prefs = await prefsWith({AppConstants.keyUseTor: true});
      expect(await readNetworkRoute(prefs), const TorRoute());
    });

    test('use_tor wins over use_proxy', () async {
      await saveProxyConfig(_config);
      final prefs = await prefsWith({
        AppConstants.keyUseTor: true,
        AppConstants.keyUseProxy: true,
      });
      expect(await readNetworkRoute(prefs), const TorRoute());
    });

    test('use_proxy with a saved config -> ProxyRoute', () async {
      await saveProxyConfig(_config);
      final prefs = await prefsWith({AppConstants.keyUseProxy: true});
      expect(await readNetworkRoute(prefs), const ProxyRoute(_config));
    });

    test('use_proxy with no entry -> MisconfiguredProxyRoute', () async {
      final prefs = await prefsWith({AppConstants.keyUseProxy: true});
      expect(await readNetworkRoute(prefs), const MisconfiguredProxyRoute());
    });

    test('use_proxy with garbage JSON -> MisconfiguredProxyRoute', () async {
      FlutterSecureStorage.setMockInitialValues({
        AppConstants.keyNetworkProxy: '{{{',
      });
      final prefs = await prefsWith({AppConstants.keyUseProxy: true});
      expect(await readNetworkRoute(prefs), const MisconfiguredProxyRoute());
    });

    test('a saved config alone does not enable the proxy', () async {
      await saveProxyConfig(_config);
      expect(await readNetworkRoute(await prefsWith({})), const DirectRoute());
    });
  });

  group('NetworkSettingsNotifier', () {
    Future<ProviderContainer> container({
      Map<String, Object> prefs = const {},
      ProxyConfig? initialProxy,
    }) async {
      final p = await prefsWith(prefs);
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(p),
          initialProxyConfigProvider.overrideWithValue(initialProxy),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('setUseProxy(true) is rejected before saveProxy', () async {
      final c = await container();
      final n = c.read(networkSettingsProvider.notifier);
      await expectLater(n.setUseProxy(true), throwsStateError);
      expect(c.read(networkSettingsProvider).route, const DirectRoute());
      expect(c.read(sharedPreferencesProvider).getBool('use_proxy'), isNull);
    });

    test(
      'saveProxy + setUseProxy(true) selects the proxy and turns Tor off',
      () async {
        final c = await container(prefs: {AppConstants.keyUseTor: true});
        final n = c.read(networkSettingsProvider.notifier);
        expect(c.read(networkSettingsProvider).route, const TorRoute());

        await n.saveProxy(_config);
        // Saving alone changes nothing about the route.
        expect(c.read(networkSettingsProvider).route, const TorRoute());
        expect(await loadProxyConfig(), _config);

        await n.setUseProxy(true);
        expect(
          c.read(networkSettingsProvider).route,
          const ProxyRoute(_config),
        );
        final prefs = c.read(sharedPreferencesProvider);
        expect(prefs.getBool(AppConstants.keyUseTor), false);
        expect(prefs.getBool(AppConstants.keyUseProxy), true);
        expect(
          widgetWrites
              .map((e) => '${e.key}=${e.value}')
              .toList()
              .reversed
              .take(2),
          containsAll(['widget_use_tor=false', 'widget_use_proxy=true']),
        );
      },
    );

    test(
      'setUseTor(true) turns the proxy off and flips both widget flags',
      () async {
        final c = await container();
        final n = c.read(networkSettingsProvider.notifier);
        await n.saveProxy(_config);
        await n.setUseProxy(true);
        widgetWrites.clear();

        await n.setUseTor(true);

        expect(c.read(sharedPreferencesProvider).getBool('use_proxy'), false);
        expect(c.read(networkSettingsProvider).route, const TorRoute());
        final last = <String, Object?>{};
        for (final w in widgetWrites) {
          last[w.key] = w.value;
        }
        expect(last['widget_use_tor'], true);
        expect(last['widget_use_proxy'], false);
        // The saved config survives a switch to Tor.
        expect(await loadProxyConfig(), _config);
      },
    );

    test('interleaved route setters run one at a time: prefs never pass '
        'through both-false and end up agreeing with state', () async {
      await saveProxyConfig(_config);
      final c = await container(
        prefs: {AppConstants.keyUseTor: true},
        initialProxy: _config,
      );
      final n = c.read(networkSettingsProvider.notifier);
      final prefs = c.read(sharedPreferencesProvider);

      // A slow widget host makes each setter yield mid-flight, and samples
      // the prefs at every one of those points.
      final snapshots = <(bool?, bool?)>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('home_widget'), (
            call,
          ) async {
            snapshots.add((
              prefs.getBool(AppConstants.keyUseTor),
              prefs.getBool(AppConstants.keyUseProxy),
            ));
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return true;
          });

      // Taps on the Tor card and the proxy card, without waiting.
      await Future.wait([
        n.setUseProxy(true),
        n.setUseTor(true),
        n.setUseProxy(true),
        n.setUseTor(true),
        n.setUseProxy(true),
      ]);

      expect(snapshots, isNotEmpty);
      expect(
        snapshots.where((s) => s.$1 != true && s.$2 != true),
        isEmpty,
        reason: 'every call selects a private route',
      );
      expect(prefs.getBool(AppConstants.keyUseProxy), isTrue);
      expect(prefs.getBool(AppConstants.keyUseTor), isFalse);
      expect(c.read(networkSettingsProvider).route, const ProxyRoute(_config));
    });

    test('a preset or custom URL set during a route setter is not reverted '
        'by it (M-2)', () async {
      final c = await container();
      final n = c.read(networkSettingsProvider.notifier);
      // A slow widget host keeps the route setter mid-flight.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('home_widget'), (
            call,
          ) async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return true;
          });

      // The Tor switch, then the custom explorer tile and its URL, without
      // waiting.
      await Future.wait([
        n.setUseTor(true),
        n.setPreset(ExplorerPreset.custom),
        n.setCustomUrl('https://node.example'),
        n.setUseTor(false),
      ]);

      final s = c.read(networkSettingsProvider);
      expect(s.preset, ExplorerPreset.custom);
      expect(s.customUrl, 'https://node.example');
      expect(s.route, const DirectRoute());
      // Memory agrees with what the background isolates read.
      expect(
        c.read(sharedPreferencesProvider).getInt(AppConstants.keyExplorerPreset),
        ExplorerPreset.custom.index,
      );
    });

    group('widget route flags that cannot be written (M-3)', () {
      tearDown(
        () => NetworkSettingsNotifier.debugWriteRouteFlagsOverride = null,
      );

      test('a write that fails once is retried, and the route applies',
          () async {
        var calls = 0;
        NetworkSettingsNotifier.debugWriteRouteFlagsOverride = () async {
          calls++;
          if (calls == 1) throw const FileSystemException('prefs');
        };
        final c = await container();
        await c.read(networkSettingsProvider.notifier).setUseTor(true);
        expect(calls, 2);
        expect(c.read(networkSettingsProvider).route, const TorRoute());
      });

      test('a write that keeps failing still publishes the new route: the '
          "app's own traffic follows the user's choice", () async {
        var calls = 0;
        NetworkSettingsNotifier.debugWriteRouteFlagsOverride = () async {
          calls++;
          throw const FileSystemException('prefs');
        };
        final c = await container();
        final n = c.read(networkSettingsProvider.notifier);
        await n.setUseTor(true);
        expect(calls, 2);
        expect(c.read(networkSettingsProvider).route, const TorRoute());
        expect(
          c.read(sharedPreferencesProvider).getBool(AppConstants.keyUseTor),
          isTrue,
        );
        // And the chain is not wedged.
        await n.setUseTor(false);
        expect(c.read(networkSettingsProvider).route, const DirectRoute());
      });

      test('recheck() on a proxy that becomes readable settles even when '
          'the flags cannot be written', () async {
        NetworkSettingsNotifier.debugWriteRouteFlagsOverride =
            () async => throw const FileSystemException('prefs');
        await saveProxyConfig(_config);
        RouteGate.debugProbeOverride = (_) async => RouteStatus.available;
        addTearDown(() => RouteGate.debugProbeOverride = null);
        final c = await container(prefs: {AppConstants.keyUseProxy: true});

        await c.read(routeStatusProvider.notifier).recheck();

        expect(c.read(networkSettingsProvider).route, const ProxyRoute(_config));
        expect(await c.read(routeStatusProvider.future), RouteStatus.available);
      });
    });

    test('recheck() never stays loading when re-reading the proxy throws '
        '(M-3)', () async {
      final p = await prefsWith({AppConstants.keyUseProxy: true});
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(p),
          networkSettingsProvider.overrideWith(_ReloadThrows.new),
        ],
      );
      addTearDown(c.dispose);
      // Built first, so recheck() is what changes it.
      expect(await c.read(routeStatusProvider.future), RouteStatus.unavailable);

      await c.read(routeStatusProvider.notifier).recheck();

      expect(c.read(routeStatusProvider).isLoading, isFalse);
      expect(c.read(routeStatusProvider).value, RouteStatus.unavailable);
    });

    test('a failed setter does not wedge later ones', () async {
      final c = await container();
      final n = c.read(networkSettingsProvider.notifier);
      await expectLater(n.setUseProxy(true), throwsStateError);
      await n.setUseTor(true);
      expect(c.read(networkSettingsProvider).route, const TorRoute());
    });

    // The write-order guarantees (never both flags false, true first,
    // overlapping writers) are pinned on the shared writer in
    // test/widget_service_tor_flag_test.dart.

    test('setUseProxy(false) keeps the saved config', () async {
      final c = await container();
      final n = c.read(networkSettingsProvider.notifier);
      await n.saveProxy(_config);
      await n.setUseProxy(true);
      await n.setUseProxy(false);
      expect(c.read(networkSettingsProvider).route, const DirectRoute());
      expect(c.read(networkSettingsProvider).proxy, _config);
      expect(await loadProxyConfig(), _config);
    });

    test('clearProxy deletes the entry and falls back to direct', () async {
      final c = await container();
      final n = c.read(networkSettingsProvider.notifier);
      await n.saveProxy(_config);
      await n.setUseProxy(true);
      widgetWrites.clear();

      await n.clearProxy();

      expect(await loadProxyConfig(), isNull);
      expect(c.read(networkSettingsProvider).route, const DirectRoute());
      expect(c.read(networkSettingsProvider).proxy, isNull);
      expect(c.read(sharedPreferencesProvider).getBool('use_proxy'), false);
      final last = <String, Object?>{};
      for (final w in widgetWrites) {
        last[w.key] = w.value;
      }
      expect(last['widget_use_proxy'], false);
      expect(last['widget_use_tor'], false);
    });

    test(
      'saveProxy refuses a config validate() rejects, without secrets',
      () async {
        final c = await container();
        final n = c.read(networkSettingsProvider.notifier);
        const bad = ProxyConfig(
          type: ProxyType.http,
          host: ' 10.0.0.5 ',
          port: 8080,
          username: 'SECRETUSER',
          password: 'SECRETPASS',
        );
        await expectLater(
          n.saveProxy(bad),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'message',
              allOf(
                isNot(contains('SECRETUSER')),
                isNot(contains('SECRETPASS')),
              ),
            ),
          ),
        );
        expect(await loadProxyConfig(), isNull);
        expect(c.read(networkSettingsProvider).proxy, isNull);
      },
    );

    test(
      'saveProxy refuses empty-string credentials, without secrets',
      () async {
        final c = await container();
        final n = c.read(networkSettingsProvider.notifier);
        for (final (user, pass) in [
          ('', ''),
          ('SECRETUSER', ''),
          ('', 'SECRETPASS'),
        ]) {
          await expectLater(
            n.saveProxy(
              ProxyConfig(
                type: ProxyType.socks5,
                host: '10.0.0.5',
                port: 1080,
                username: user,
                password: pass,
              ),
            ),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.toString(),
                'message',
                allOf(
                  isNot(contains('SECRETUSER')),
                  isNot(contains('SECRETPASS')),
                ),
              ),
            ),
          );
        }
        expect(await loadProxyConfig(), isNull);
        expect(c.read(networkSettingsProvider).proxy, isNull);
      },
    );

    group('reloadProxy', () {
      test('picks up an entry that is readable now', () async {
        // main() could not read it; by now the keychain is unlocked.
        await saveProxyConfig(_config);
        final c = await container(prefs: {AppConstants.keyUseProxy: true});
        expect(
          c.read(networkSettingsProvider).route,
          const MisconfiguredProxyRoute(),
        );

        await c.read(networkSettingsProvider.notifier).reloadProxy();

        expect(
          c.read(networkSettingsProvider).route,
          const ProxyRoute(_config),
        );
      });

      test('stays misconfigured while the entry is still unreadable', () async {
        FlutterSecureStorage.setMockInitialValues({
          AppConstants.keyNetworkProxy: '{{{',
        });
        final c = await container(prefs: {AppConstants.keyUseProxy: true});

        await c.read(networkSettingsProvider.notifier).reloadProxy();

        expect(
          c.read(networkSettingsProvider).route,
          const MisconfiguredProxyRoute(),
        );
      });
    });

    test(
      'recheck() on a still-unreadable proxy settles on unavailable',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          AppConstants.keyNetworkProxy: '{{{',
        });
        final c = await container(prefs: {AppConstants.keyUseProxy: true});

        await c.read(routeStatusProvider.notifier).recheck();

        expect(c.read(routeStatusProvider).value, RouteStatus.unavailable);
      },
    );

    test('recheck() re-reads a misconfigured proxy before probing', () async {
      await saveProxyConfig(_config);
      final probed = <NetworkRoute>[];
      RouteGate.debugProbeOverride = (route) async {
        probed.add(route);
        return RouteStatus.available;
      };
      addTearDown(() => RouteGate.debugProbeOverride = null);
      final c = await container(prefs: {AppConstants.keyUseProxy: true});

      await c.read(routeStatusProvider.notifier).recheck();

      expect(c.read(networkSettingsProvider).route, const ProxyRoute(_config));
      expect(await c.read(routeStatusProvider.future), RouteStatus.available);
      expect(probed.last, const ProxyRoute(_config));
    });

    test(
      'a use_proxy user with an unreadable entry gets a misconfigured route',
      () async {
        // main() passes null for an unreadable entry.
        final c = await container(prefs: {AppConstants.keyUseProxy: true});
        expect(
          c.read(networkSettingsProvider).route,
          const MisconfiguredProxyRoute(),
        );
      },
    );
  });
}

/// Settings whose proxy re-read fails, however it might.
class _ReloadThrows extends NetworkSettingsNotifier {
  @override
  Future<void> reloadProxy() async => throw StateError('reload failed');
}
