/// The iOS WidgetKit extension fetches charts itself and can only learn the
/// Tor setting from the App Group, so every toggle must be mirrored there —
/// otherwise the widget keeps reaching bitbag.app over clearnet.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/portfolio.dart';
import 'package:bag/models/price_data.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/services/network/network_route_store.dart';
import 'package:bag/services/widget_service.dart';

const _config = ProxyConfig(
  type: ProxyType.socks5,
  host: '10.0.0.5',
  port: 1080,
);

const _routeFlags = {'widget_use_tor', 'widget_use_proxy'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final saved = <String, Object?>{};

  /// Route-flag writes in the order the platform channel received them.
  final flagWrites = <MapEntry<String, bool>>[];

  /// How long the fake widget host takes to answer each write. Non-zero
  /// forces overlapping writers to actually interleave.
  var writeDelay = Duration.zero;

  setUp(() {
    saved.clear();
    flagWrites.clear();
    writeDelay = Duration.zero;
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'), (
          call,
        ) async {
          if (call.method == 'saveWidgetData') {
            final args = call.arguments as Map;
            final id = args['id'] as String;
            saved[id] = args['data'];
            if (_routeFlags.contains(id)) {
              flagWrites.add(MapEntry(id, args['data'] as bool));
            }
            if (writeDelay > Duration.zero) {
              await Future<void>.delayed(writeDelay);
            }
            return true;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
  });

  Future<ProviderContainer> containerWithPrefs() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('setUseTor(true) mirrors the flag to the widget', () async {
    final container = await containerWithPrefs();
    await container.read(networkSettingsProvider.notifier).setUseTor(true);
    expect(saved['widget_use_tor'], true);
  });

  test('setUseTor(false) clears the flag on the widget', () async {
    final container = await containerWithPrefs();
    final notifier = container.read(networkSettingsProvider.notifier);
    await notifier.setUseTor(true);
    await notifier.setUseTor(false);
    expect(saved['widget_use_tor'], false);
  });

  // backgroundWidgetCallback never writes the flags, so this foreground path
  // is the only way an existing Tor user's widget learns the flag after
  // upgrading.
  Future<void> pushUpdate() => WidgetService.update(
    priceData: PriceData(
      prices: const {'usd': 100000},
      changes24h: const {'usd': 1.0},
      fetchedAt: DateTime.now(),
    ),
    portfolio: const Portfolio(btcAmount: 1, selectedCurrencies: ['usd']),
  );

  test(
    'WidgetService.update writes widget_use_tor true when Tor is on',
    () async {
      SharedPreferences.setMockInitialValues({AppConstants.keyUseTor: true});
      await pushUpdate();
      expect(saved['widget_use_tor'], true);
    },
  );

  test('WidgetService.update writes widget_use_tor false when unset', () async {
    SharedPreferences.setMockInitialValues({});
    await pushUpdate();
    expect(saved['widget_use_tor'], false);
  });

  group('writeWidgetRouteFlags', () {
    // The iOS widget reads the App Group on its own schedule; use_tor=false
    // with use_proxy=false means "direct", so a switch between private routes
    // must never pass through that state.
    void expectNeverBothFalse({required bool tor, required bool proxy}) {
      final flags = {'widget_use_tor': tor, 'widget_use_proxy': proxy};
      expect(flagWrites, isNotEmpty);
      for (final w in flagWrites) {
        flags[w.key] = w.value;
        expect(
          flags.values.any((v) => v),
          isTrue,
          reason: 'after writing ${w.key}=${w.value} both flags were false',
        );
      }
    }

    Map<String, bool> finalFlags() => {
      for (final w in flagWrites) w.key: w.value,
    };

    test('Tor -> proxy writes the proxy flag first', () async {
      SharedPreferences.setMockInitialValues({AppConstants.keyUseProxy: true});
      await saveProxyConfig(_config);

      await WidgetService.writeWidgetRouteFlags();

      expectNeverBothFalse(tor: true, proxy: false);
      expect(flagWrites.map((e) => '${e.key}=${e.value}'), [
        'widget_use_proxy=true',
        'widget_use_tor=false',
      ]);
    });

    test('proxy -> Tor writes the Tor flag first', () async {
      SharedPreferences.setMockInitialValues({AppConstants.keyUseTor: true});

      await WidgetService.writeWidgetRouteFlags();

      expectNeverBothFalse(tor: false, proxy: true);
      expect(flagWrites.map((e) => '${e.key}=${e.value}'), [
        'widget_use_tor=true',
        'widget_use_proxy=false',
      ]);
    });

    test('an unreadable proxy still sets the proxy flag', () async {
      SharedPreferences.setMockInitialValues({AppConstants.keyUseProxy: true});

      await WidgetService.writeWidgetRouteFlags();

      expect(finalFlags(), {'widget_use_tor': false, 'widget_use_proxy': true});
    });

    test('overlapping writers across a route change end on the final route and '
        'never pass through both false', () async {
      SharedPreferences.setMockInitialValues({AppConstants.keyUseTor: true});
      final prefs = await SharedPreferences.getInstance();
      await saveProxyConfig(_config);
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          initialProxyConfigProvider.overrideWithValue(_config),
        ],
      );
      addTearDown(container.dispose);
      writeDelay = const Duration(milliseconds: 20);

      // A widget update that began while Tor was selected...
      final before = WidgetService.writeWidgetRouteFlags();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // ...is still writing when the user switches to the proxy.
      final after = container
          .read(networkSettingsProvider.notifier)
          .setUseProxy(true);
      await Future.wait([before, after]);

      expectNeverBothFalse(tor: true, proxy: false);
      expect(finalFlags(), {'widget_use_tor': false, 'widget_use_proxy': true});
      expect(
        container.read(networkSettingsProvider).route,
        const ProxyRoute(_config),
      );
    });
  });
}
