/// Task A5: the home-screen widget names the route its prices came through
/// (Tor › Proxy › Direct) and when they were fetched, on Android and iOS.
///
/// The keys, in HomeWidgetPreferences (Android) and the App Group (iOS):
/// - `widget_use_tor` / `widget_use_proxy` (bool): the route, written only by
///   `WidgetService.writeWidgetRouteFlags` (R-A5b). The badge derives from
///   them, Tor first. There is no `widget_route` key.
/// - `widget_route_ok` (bool): whether the last fetch attempt reached the
///   network through that route (R-A5c).
/// - `widget_fetched_at` (int, epoch seconds): when the prices the widget
///   shows were fetched — the data's own time, never "now" for data that
///   wasn't fetched now (R-A5a, R-A5d). It replaces `widget_updated_at`, an
///   `"HH:mm"` string a type-strict reader can't share a key with.
///
/// This file covers the foreground writer (`WidgetService.update`, driven by
/// `PriceNotifier`) and the native readers' source shape. The background
/// writers' cases (the Android WorkManager job, the iOS refresh) sit next to
/// their harnesses, in test/tor/android_background_tor_test.dart and
/// test/tor/ios_background_refresh_test.dart, groups "widget route keys
/// (Task A5)": their fake Tor clients and request recorders are private to
/// those files.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/core/constants/supported_currencies.dart';
import 'package:bag/models/dca_entry.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/portfolio.dart';
import 'package:bag/models/price_data.dart';
import 'package:bag/providers/dca_provider.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/price_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/services/network/network_route_store.dart';
import 'package:bag/services/price_service.dart';
import 'package:bag/services/tor_service.dart';
import 'package:bag/services/widget_service.dart';

const _proxy = ProxyConfig(
  type: ProxyType.socks5,
  host: '10.0.0.5',
  port: 1080,
);

/// A fetch from an earlier run, already on the widget.
const _earlierFetch = 1763880000; // 2025-11-23 06:40 UTC

int _seconds(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

/// A [PriceService] whose price fetch is scripted. [answer] null means the
/// fetch throws, as the real one does with no cache to fall back on.
class _Prices extends PriceService {
  _Prices(
    NetworkRoute route,
    this.log, {
    this.answer,
    this.cached,
    this.blocked = false,
  }) : super(route: route);

  final List<String> log;
  final PriceData Function()? answer;
  final PriceData? cached;
  final bool blocked;

  @override
  PriceData? getCachedPrice() => cached;

  @override
  bool get lastRequestBlockedByRoute => blocked;

  @override
  Future<PriceData> fetchCurrentPrice(List<String> currencies) async {
    log.add('fetch:$route');
    final a = answer;
    if (a == null) throw const RouteUnavailableException();
    return a();
  }

  @override
  Future<void> prewarmCharts(String currency) async {}

  @override
  Future<List<(DateTime, double)>> fetchChartData(
    String currency,
    int days, {
    void Function()? onRefreshed,
  }) async => const [];
}

class _EmptyDcaNotifier extends DcaNotifier {
  @override
  List<DcaEntry> build() => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The fake HomeWidgetPreferences / App Group.
  final store = <String, Object?>{};

  /// Every channel call in order: `save:<key>=<value>`, `reload`, and the
  /// price layer's `fetch:<route>`.
  final log = <String>[];

  setUp(() {
    store
      ..clear()
      ..addAll({'widget_fetched_at': _earlierFetch, 'widget_route_ok': true});
    log.clear();
    FlutterSecureStorage.setMockInitialValues({AppConstants.keyBtcAmount: '1'});
    SharedPreferences.setMockInitialValues({});
    TorService.debugIsIOS = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'), (
          call,
        ) async {
          final args = call.arguments is Map ? call.arguments as Map : const {};
          switch (call.method) {
            case 'saveWidgetData':
              final id = args['id'] as String;
              final data = args['data'];
              if (data == null) {
                store.remove(id);
              } else {
                store[id] = data;
              }
              log.add('save:$id=$data');
              return true;
            case 'getWidgetData':
              return store[args['id']] ?? args['defaultValue'];
            case 'updateWidget':
              log.add('reload');
              return true;
          }
          return null;
        });
  });

  tearDown(() {
    TorService.debugIsIOS = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
  });

  Future<void> update(PriceData data, {DateTime? attemptedAt}) =>
      WidgetService.update(
        priceData: data,
        portfolio: const Portfolio(btcAmount: 1, selectedCurrencies: ['usd']),
        attemptedAt: attemptedAt,
      );

  PriceData usd(DateTime fetchedAt, {Set<String> stale = const {}}) =>
      PriceData(
        prices: const {'usd': 100000},
        changes24h: const {'usd': 1.0},
        fetchedAt: fetchedAt,
        staleCurrencies: stale,
      );

  Map<String, bool> flags() => {
    'tor': store['widget_use_tor'] as bool,
    'proxy': store['widget_use_proxy'] as bool,
  };

  // ── 1. The route flags ───────────────────────────────────────────────────

  group('the route flags the badge derives from (R-A5b)', () {
    final routes = <(String, Map<String, Object>, Map<String, bool>)>[
      ('Tor', {AppConstants.keyUseTor: true}, {'tor': true, 'proxy': false}),
      (
        'a proxy',
        {AppConstants.keyUseProxy: true},
        {'tor': false, 'proxy': true},
      ),
      ('Direct', const {}, {'tor': false, 'proxy': false}),
    ];
    for (final ios in [false, true]) {
      for (final (name, prefs, want) in routes) {
        test('${ios ? 'iOS' : 'Android'}, $name: the foreground update '
            'writes them, before the price keys', () async {
          TorService.debugIsIOS = ios;
          SharedPreferences.setMockInitialValues(prefs);
          if (prefs.containsKey(AppConstants.keyUseProxy)) {
            await saveProxyConfig(_proxy);
          }

          await update(usd(DateTime.now()));

          expect(flags(), want);
          final lastFlag = log.lastIndexWhere(
            (e) => e.startsWith('save:widget_use_'),
          );
          expect(
            lastFlag,
            lessThan(log.indexWhere((e) => e.startsWith('save:widget_price='))),
          );
        });
      }
    }

    test('a route change rewrites them before the next fetch', () async {
      SharedPreferences.setMockInitialValues({});
      await saveProxyConfig(_proxy);
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          initialProxyConfigProvider.overrideWithValue(_proxy),
          dcaProvider.overrideWith(_EmptyDcaNotifier.new),
          priceServiceProvider.overrideWith(
            (ref) => _Prices(
              ref.watch(networkSettingsProvider.select((s) => s.route)),
              log,
              answer: () => usd(DateTime.now()),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(priceProvider.future);
      await pumpEventQueue();
      expect(flags(), {'tor': false, 'proxy': false});
      log.clear();

      await c.read(networkSettingsProvider.notifier).setUseProxy(true);
      await c.read(priceProvider.notifier).refresh(force: true);
      await pumpEventQueue();

      final flagged = log.indexOf('save:widget_use_proxy=true');
      final fetched = log.indexOf('fetch:${const ProxyRoute(_proxy)}');
      expect(flagged, isNonNegative);
      expect(fetched, greaterThan(flagged));
      expect(flags(), {'tor': false, 'proxy': true});
      // Paused from the switch until the first fetch on the new route says
      // otherwise (Obs 10).
      final reset = log.indexOf('save:widget_route_ok=false');
      expect(reset, allOf(isNonNegative, lessThan(flagged)));
      expect(store['widget_route_ok'], isTrue);
    });
  });

  group('a route change resets route_ok (Obs 10)', () {
    test(
      'the flags change: route_ok false, written before the flags, so a '
      'redraw in between never shows a green dot for the new route',
      () async {
        store.addAll({'widget_use_tor': false, 'widget_use_proxy': false});
        SharedPreferences.setMockInitialValues({AppConstants.keyUseTor: true});

        await WidgetService.writeWidgetRouteFlags();

        expect(store['widget_route_ok'], isFalse);
        final reset = log.indexOf('save:widget_route_ok=false');
        expect(reset, isNonNegative);
        expect(
          reset,
          lessThan(log.indexWhere((e) => e.startsWith('save:widget_use_'))),
        );
        expect(flags(), {'tor': true, 'proxy': false});
      },
    );

    test(
      'the flags not written yet (an upgrade): that counts as a change',
      () async {
        SharedPreferences.setMockInitialValues({});

        await WidgetService.writeWidgetRouteFlags();

        expect(store['widget_route_ok'], isFalse);
      },
    );

    test('no change (every foreground update rewrites them): route_ok is '
        'left as it is', () async {
      store.addAll({'widget_use_tor': true, 'widget_use_proxy': false});
      SharedPreferences.setMockInitialValues({AppConstants.keyUseTor: true});

      await WidgetService.writeWidgetRouteFlags();

      expect(store['widget_route_ok'], isTrue);
      expect(log, isNot(contains(startsWith('save:widget_route_ok'))));
      expect(flags(), {'tor': true, 'proxy': false});
    });
  });

  // ── 2. and 3. Freshness from the foreground ──────────────────────────────

  group('the foreground update (R-A5c, R-A5d)', () {
    test('a fetch: fetched_at is the data\'s own fetch time, not now, and '
        'route_ok is true', () async {
      final fetchedAt = DateTime(2026, 11, 23, 9, 41, 7);

      await update(
        usd(fetchedAt),
        attemptedAt: fetchedAt.subtract(const Duration(seconds: 2)),
      );

      expect(store['widget_fetched_at'], _seconds(fetchedAt));
      expect(store['widget_route_ok'], isTrue);
      expect(store.containsKey('widget_updated_at'), isFalse);
      expect(log.last, 'reload');
    });

    test('a cached push after a route block: route_ok false, with the cached '
        'data\'s fetched_at', () async {
      final cachedAt = DateTime.now().subtract(const Duration(hours: 3));

      // The price layer served its cache: data fetched before the attempt.
      await update(usd(cachedAt), attemptedAt: DateTime.now());

      expect(store['widget_route_ok'], isFalse);
      expect(store['widget_fetched_at'], _seconds(cachedAt));
    });

    test('a price carried over from an older cache (no source quoted it): '
        'route_ok false, and fetched_at stays, since that price has no fetch '
        'time of its own', () async {
      await update(
        usd(DateTime.now(), stale: const {'usd'}),
        attemptedAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      expect(store['widget_route_ok'], isFalse);
      expect(store['widget_fetched_at'], _earlierFetch);
    });

    test('a push that was no fetch attempt (the cached first frame, a DCA '
        'change) says when its data was fetched and leaves route_ok', () async {
      // The route flags as written: no route change (that resets route_ok,
      // Obs 10).
      store.addAll({
        'widget_route_ok': false,
        'widget_use_tor': false,
        'widget_use_proxy': false,
      });
      final cachedAt = DateTime.now().subtract(const Duration(hours: 1));

      await update(usd(cachedAt));

      expect(store['widget_fetched_at'], _seconds(cachedAt));
      expect(store['widget_route_ok'], isFalse);
      expect(log, isNot(contains(startsWith('save:widget_route_ok'))));
    });

    test(
      'a cached time in the future (the clock set back): route_ok false, '
      'since that data can\'t have been fetched during the attempt (I3)',
      () async {
        await update(
          usd(DateTime.now().add(const Duration(hours: 3))),
          attemptedAt: DateTime.now(),
        );

        expect(store['widget_route_ok'], isFalse);
      },
    );

    test('a carried-over price for the currency the widget shows: its price '
        'keys are left as they are, not replaced by an older cached value '
        '(M4)', () async {
      final shown = <String, Object>{
        'widget_currency': 'usd',
        'widget_price': r'$40,000.00',
        'widget_net_worth': r'$40,000.00',
        'widget_change': '+1.0%',
        'widget_change_positive': true,
        'widget_pnl_amount': r'+$1.00',
        'widget_pnl_pct': '+1.0%',
        'widget_pnl_positive': true,
      };
      store.addAll(shown);

      await update(
        usd(DateTime.now(), stale: const {'usd'}),
        attemptedAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      for (final e in shown.entries) {
        expect(store, containsPair(e.key, e.value));
      }
      for (final key in shown.keys.where((k) => k != 'widget_currency')) {
        expect(log, isNot(contains(startsWith('save:$key='))), reason: key);
      }
      expect(store['widget_route_ok'], isFalse);
      expect(store['widget_fetched_at'], _earlierFetch);
    });

    test('a carried-over price for another currency than the widget shows: '
        'written, so the price and its currency agree (M4)', () async {
      store.addAll({'widget_currency': 'eur', 'widget_price': '€40,000.00'});

      await update(
        usd(DateTime.now(), stale: const {'usd'}),
        attemptedAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      expect(store['widget_currency'], 'usd');
      expect(store['widget_price'], currencyFormatter('usd').format(100000));
      expect(store['widget_route_ok'], isFalse);
    });

    test('no price for the widget\'s currency: fetched_at stays', () async {
      await update(
        PriceData(
          prices: const {'eur': 90000},
          changes24h: const {},
          fetchedAt: DateTime.now(),
        ),
        attemptedAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      expect(store['widget_fetched_at'], _earlierFetch);
      expect(store['widget_route_ok'], isFalse);
    });
  });

  group('PriceNotifier drives it', () {
    Future<ProviderContainer> notifier(
      NetworkRoute route, {
      PriceData Function()? answer,
      PriceData? cached,
      bool blocked = false,
    }) async {
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          initialProxyConfigProvider.overrideWithValue(
            route is ProxyRoute ? route.config : null,
          ),
          dcaProvider.overrideWith(_EmptyDcaNotifier.new),
          priceServiceProvider.overrideWith(
            (ref) => _Prices(
              route,
              log,
              answer: answer,
              cached: cached,
              blocked: blocked,
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test(
      'a fetch that succeeds: fetched_at from the data, route_ok true',
      () async {
        final c = await notifier(
          const DirectRoute(),
          answer: () => usd(DateTime.now()),
        );
        final before = _seconds(DateTime.now());

        await c.read(priceProvider.future);
        await pumpEventQueue();

        final data = c.read(priceProvider).value!;
        expect(store['widget_fetched_at'], _seconds(data.fetchedAt));
        expect(store['widget_fetched_at'], greaterThanOrEqualTo(before));
        expect(store['widget_route_ok'], isTrue);
      },
    );

    test('a failed private-route attempt with nothing cached: route_ok false, '
        'fetched_at unchanged, the widget redrawn', () async {
      SharedPreferences.setMockInitialValues({AppConstants.keyUseProxy: true});
      final c = await notifier(const ProxyRoute(_proxy));

      await expectLater(
        c.read(priceProvider.future),
        throwsA(isA<RouteUnavailableException>()),
      );
      await pumpEventQueue();

      expect(store['widget_route_ok'], isFalse);
      expect(store['widget_fetched_at'], _earlierFetch);
      expect(log, contains('reload'));
    });

    test('a route block served from cache: the first frame and the refresh '
        'both push the cached prices with their own fetch time, and the '
        'refresh says the route is paused', () async {
      SharedPreferences.setMockInitialValues({AppConstants.keyUseProxy: true});
      final cached = usd(DateTime.now().subtract(const Duration(hours: 2)));
      final c = await notifier(
        const ProxyRoute(_proxy),
        // As PriceService does when its route gate trips: the cache.
        answer: () => cached,
        cached: cached,
        blocked: true,
      );

      await c.read(priceProvider.future);
      await pumpEventQueue();

      expect(log, contains('fetch:${const ProxyRoute(_proxy)}'));
      expect(store['widget_fetched_at'], _seconds(cached.fetchedAt));
      expect(store['widget_route_ok'], isFalse);
    });
  });

  // ── 5. The native readers ─────────────────────────────────────────────────
  //
  // Kotlin and Swift can't be compiled here; these pin the source shape. A
  // type-strict read of a key written as another type (`getString` on a
  // Long) throws and kills the Android widget, and `integer(forKey:)` reads
  // a missing key as 1970. They pin whole expressions, whitespace
  // normalised, not just the strings: a swapped colour, branch or call
  // site must fail (review round 1, I2).

  /// [file]'s text with comments removed (a `//` comment starts the line or
  /// follows whitespace, so a URL's `https://` is kept).
  String code(File file) => file
      .readAsStringSync()
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(RegExp(r'(^|\s)//.*$', multiLine: true), '');

  /// [text] with every run of whitespace as one space.
  String flat(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

  int count(String text, String pattern) =>
      RegExp(RegExp.escape(pattern)).allMatches(text).length;

  /// The body of the declaration [signature] (a regex) opens, up to the
  /// first line that closes at its indentation.
  String body(String text, String signature) {
    final m = RegExp(
      '^( *)$signature[^\\n]*\\{\\n(.*?)\\n\\1\\}',
      multiLine: true,
      dotAll: true,
    ).firstMatch(text);
    expect(m, isNotNull, reason: 'no $signature');
    return m!.group(2)!;
  }

  /// [text] contains each of [snippets], whitespace normalised.
  void expectPinned(String text, List<String> snippets, {String where = ''}) {
    final f = flat(text);
    for (final snippet in snippets) {
      expect(f, contains(flat(snippet)), reason: '$where: $snippet');
    }
  }

  /// The XML element whose `android:id` is [id].
  String element(String xml, String id) {
    final at = xml.indexOf('@+id/$id"');
    expect(at, isNonNegative, reason: 'no $id');
    return xml.substring(xml.lastIndexOf('<', at), xml.indexOf('>', at) + 1);
  }

  const androidDir = 'android/app/src/main';
  const ktDir = '$androidDir/kotlin/app/bitbag';
  final widgetKt = File('$ktDir/BagWidget.kt');
  final workerKt = File('$ktDir/NativeChartRefreshWorker.kt');
  final configureKt = File('$ktDir/BagWidgetConfigureActivity.kt');
  final privateRouteKt = File('$ktDir/PrivateRoute.kt');
  File layout(String name) => File('$androidDir/res/layout/$name.xml');
  File drawable(String name) => File('$androidDir/res/drawable/$name.xml');
  final widgetLayouts = ['bag_widget_small', 'bag_widget', 'bag_widget_large'];

  group('Android widget (BagWidget.kt and its layouts)', () {
    test('widget_fetched_at and widget_route_ok are read type-safely, with '
        'route_ok defaulting to ok, and nothing reads widget_updated_at', () {
      final kt = code(widgetKt);
      expectPinned(body(kt, r'private fun freshnessText\('), [
        'val seconds = (all["widget_fetched_at"] as? Number)?.toLong() '
            '?: return null',
        'val millis = seconds * 1000',
      ]);
      expectPinned(body(kt, r'private fun applyRouteAndTime\('), [
        'val all = data.all',
        'val ok = all["widget_route_ok"] as? Boolean ?: true',
      ]);
      expect(count(kt, '"widget_fetched_at"'), 1);
      expect(count(kt, '"widget_route_ok"'), 1);
      for (final typed in ['getString', 'getLong', 'getInt', 'getBoolean']) {
        for (final key in ['widget_fetched_at', 'widget_route_ok']) {
          expect(kt, isNot(contains('$typed("$key"')));
        }
      }
      for (final f in [widgetKt, workerKt, configureKt]) {
        expect(code(f), isNot(contains('widget_updated_at')), reason: f.path);
      }
    });

    test('the badge: Tor before Proxy, none before the app has written the '
        'flags; its drawable, label colour and dot by route and state', () {
      final kt = code(widgetKt);
      expect(
        flat(body(kt, r'private fun widgetRoute\(')),
        flat('''
          val tor = all["widget_use_tor"] as? Boolean
          val proxy = all["widget_use_proxy"] as? Boolean
          return when {
              tor == true -> WidgetRoute.TOR
              proxy == true -> WidgetRoute.PROXY
              tor == null && proxy == null -> null
              else -> WidgetRoute.DIRECT
          }'''),
      );
      expectPinned(kt, ['TOR("Tor"), PROXY("Proxy"), DIRECT("Direct"),']);
      expectPinned(body(kt, r'private fun applyRouteAndTime\('), [
        'val route = widgetRoute(all)',
        'if (route == null) { views.setViewVisibility(R.id.widget_route_badge, '
            'android.view.View.GONE) } else {',
        'val direct = route == WidgetRoute.DIRECT',
        'views.setTextViewText(R.id.widget_route_label, route.label)',
        'views.setTextColor(R.id.widget_route_label, '
            'if (direct) TEXT_MUTED else TEXT_WHITE)',
        '''views.setInt(
            R.id.widget_route_badge, "setBackgroundResource",
            when {
                direct -> R.drawable.widget_route_badge_direct
                ok -> R.drawable.widget_route_badge_ok
                else -> R.drawable.widget_route_badge_failed
            },
        )''',
        '''if (direct) {
            views.setViewVisibility(R.id.widget_route_dot, android.view.View.GONE)
        } else {
            views.setImageViewResource(
                R.id.widget_route_dot,
                if (ok) R.drawable.widget_route_dot_ok else R.drawable.widget_route_dot_failed,
            )
            views.setViewVisibility(R.id.widget_route_dot, android.view.View.VISIBLE)
        }
        views.setViewVisibility(R.id.widget_route_badge, android.view.View.VISIBLE)''',
      ]);
    });

    test('the time: its copy and colour by state, the date instead of the '
        'time when the fetch wasn\'t today, short copy where it is narrow', () {
      final kt = code(widgetKt);
      expectPinned(body(kt, r'private fun freshnessText\('), [
        'val pattern = if (DateUtils.isToday(millis)) "HH:mm" else "d MMM"',
        'val stamp = SimpleDateFormat(pattern, Locale.US).format(Date(millis))',
        r'''return when {
            ok -> "Updated $stamp"
            short -> "Paused $stamp"
            else -> "Paused since $stamp"
        }''',
      ]);
      expectPinned(body(kt, r'private fun applyRouteAndTime\('), [
        'val time = freshnessText(all, ok, short)',
        'views.setTextViewText(R.id.widget_updated, time ?: "")',
        'views.setTextColor(R.id.widget_updated, '
            'if (ok) TEXT_MUTED else TEXT_PAUSED)',
        'views.setViewVisibility( R.id.widget_updated, if (time == null) '
            'android.view.View.GONE else android.view.View.VISIBLE, )',
      ]);
      expectPinned(kt, [
        'private val TEXT_WHITE = 0xFFFFFFFF.toInt()',
        'private val TEXT_MUTED = 0xFFA9A9C4.toInt()',
        'private val TEXT_PAUSED = 0xFFFF6B78.toInt()',
        'private const val LONG_TIME_MIN_WIDTH_DP = 180',
        'val narrowMedium = buildMedium(context, widgetData, appWidgetId, '
            'short = true)',
        'val medium = buildMedium(context, widgetData, appWidgetId, '
            'short = false)',
        'SizeF(80f, 110f) to narrowMedium, '
            'SizeF(LONG_TIME_MIN_WIDTH_DP.toFloat(), 110f) to medium,',
        'if (w >= LONG_TIME_MIN_WIDTH_DP) medium else narrowMedium',
      ]);
      expectPinned(body(kt, r'private fun buildSmall\('), [
        'applyRouteAndTime(views, data, short = true)',
      ]);
      expectPinned(body(kt, r'private fun buildMedium\('), [
        'applyRouteAndTime(views, data, short)',
      ]);
      expectPinned(body(kt, r'private fun buildLarge\('), [
        'applyRouteAndTime(views, data, short = false)',
      ]);
    });

    test('the drawables: the dots and the pill tones as drawn', () {
      final tones = {
        'widget_route_dot_ok': ['#00C896'],
        'widget_route_dot_failed': ['#FF4757'],
        'widget_route_badge_ok': ['#0E1F1A', '#1F4D40'],
        'widget_route_badge_failed': ['#24101A', '#5A1E2A'],
        'widget_route_badge_direct': ['#13131A', '#252535'],
      };
      for (final MapEntry(key: name, value: colours) in tones.entries) {
        final xml = drawable(name).readAsStringSync();
        expect(
          RegExp(
            r'android:color="(#[0-9A-F]{6})"',
          ).allMatches(xml).map((m) => m.group(1)).toList(),
          colours,
          reason: name,
        );
      }
    });

    test('one badge layout, included by every widget layout with its size on '
        'the include; every id the code sets is there; no <View>', () {
      final badge = layout('widget_route_badge').readAsStringSync();
      for (final id in [
        'widget_route_badge',
        'widget_route_dot',
        'widget_route_label',
      ]) {
        expect(badge, contains('@+id/$id"'), reason: id);
      }
      for (final name in [...widgetLayouts, 'widget_route_badge']) {
        final xml = layout(name).readAsStringSync();
        expect(RegExp(r'<View[\s/>]').hasMatch(xml), isFalse, reason: name);
      }
      for (final name in widgetLayouts) {
        final xml = layout(name).readAsStringSync();
        final include = RegExp(
          r'<include\s[^>]*layout="@layout/widget_route_badge"[^>]*/>',
        ).firstMatch(xml);
        expect(include, isNotNull, reason: '$name: no badge include');
        expect(include!.group(0), contains('android:layout_width='));
        expect(include.group(0), contains('android:layout_height='));
        expect(xml, isNot(contains('@+id/widget_route_dot"')), reason: name);
        expect(
          element(xml, 'widget_updated'),
          contains('android:maxLines="1"'),
        );
      }
    });

    test('long values keep to one line (M7)', () {
      for (final (name, id) in [
        ('bag_widget_small', 'widget_net_worth'),
        ('bag_widget', 'widget_price'),
        ('bag_widget_large', 'widget_price'),
      ]) {
        final view = element(layout(name).readAsStringSync(), id);
        expect(view, contains('android:maxLines="1"'), reason: '$name $id');
        expect(view, contains('android:ellipsize="end"'), reason: '$name $id');
      }
    });

    test('the day rule at midnight (I1): after every render, an inexact '
        'non-wakeup alarm at the next local midnight redraws from prefs; one '
        'PendingIntent, cancelled with the last widget', () {
      final kt = code(widgetKt);
      final update = kt.substring(
        kt.indexOf('fun updateWidget('),
        kt.indexOf('private fun buildSmall('),
      );
      final rendered = update.indexOf(
        'appWidgetManager.updateAppWidget(appWidgetId, views)',
      );
      expect(rendered, isNonNegative);
      expect(
        update.indexOf('scheduleMidnightRedraw(context)'),
        greaterThan(rendered),
      );
      expectPinned(body(kt, r'private fun scheduleMidnightRedraw\('), [
        'val alarms = context.getSystemService(Context.ALARM_SERVICE) '
            'as? AlarmManager ?: return',
        // A 15-min window: a plain inexact set() may slip by up to 75 % of
        // the time to its trigger (round 2).
        'alarms.setWindow( AlarmManager.RTC, '
            'nextLocalMidnightMillis(System.currentTimeMillis()), '
            '15 * 60_000L, midnightRedrawIntent(context), )',
        '} catch (e: Exception) {',
      ]);
      expect(
        flat(body(kt, r'private fun midnightRedrawIntent\(')),
        flat('''
          val ids = AppWidgetManager.getInstance(context)
              .getAppWidgetIds(ComponentName(context, BagWidget::class.java))
          val intent = Intent(context, BagWidget::class.java).apply {
              action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
              putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
          }
          return PendingIntent.getBroadcast(
              context, MIDNIGHT_REDRAW_REQUEST, intent,
              PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
          )'''),
      );
      expect(
        flat(body(kt, r'private fun nextLocalMidnightMillis\(')),
        flat('''
          val midnight = Calendar.getInstance()
          midnight.timeInMillis = now
          midnight.add(Calendar.DAY_OF_YEAR, 1)
          midnight.set(Calendar.HOUR_OF_DAY, 0)
          midnight.set(Calendar.MINUTE, 0)
          midnight.set(Calendar.SECOND, 0)
          midnight.set(Calendar.MILLISECOND, 0)
          return midnight.timeInMillis'''),
      );
      expect(
        RegExp(r'private const val MIDNIGHT_REDRAW_REQUEST = \d+').hasMatch(kt),
        isTrue,
      );
      expect(count(kt, 'PendingIntent.getBroadcast('), 1);
      expect(kt, isNot(contains('alarms.set(')));
      expectPinned(body(kt, r'override fun onDisabled\('), [
        '(context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager)'
            '?.cancel(midnightRedrawIntent(context))',
      ]);
      for (final banned in [
        'RTC_WAKEUP',
        'ELAPSED_REALTIME_WAKEUP',
        'setExact',
        'setAndAllowWhileIdle',
        'setAlarmClock',
        'FLAG_MUTABLE',
      ]) {
        expect(kt, isNot(contains(banned)), reason: banned);
      }
      final manifest = File(
        '$androidDir/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, isNot(contains('SCHEDULE_EXACT_ALARM')));
      expect(manifest, isNot(contains('USE_EXACT_ALARM')));
    });

    test('the native chart worker says whether its direct fetch got through, '
        'only while still direct, never stamps the price time (it fetches '
        'only the chart)', () {
      final kt = code(workerKt);
      expect(count(kt, '"widget_route_ok"'), 2);
      expect(kt, isNot(contains('widget_fetched_at')));
      expectPinned(kt, [
        'if (!applicationContext.privateRouteOn()) '
            'editor.putBoolean("widget_route_ok", true) editor.apply()',
        '?: return if (applicationContext.privateRouteOn()) '
            'Result.success() else failed(prefs)',
        '} catch (e: Exception) { Log.e(TAG, "Fetch failed: \$e") '
            'if (applicationContext.privateRouteOn()) Result.success() '
            'else failed(prefs) }',
      ]);
      expect(
        flat(body(kt, r'private fun failed\(')),
        flat('''
          prefs.edit().putBoolean("widget_route_ok", false).apply()
          redrawAll()
          return Result.retry()'''),
      );
      // The two skips stay ahead of every fetch, and write nothing.
      final work = body(kt, r'override fun doWork\(\)');
      final firstFetch = work.indexOf('fetchKrakenPrices(');
      expect(work.indexOf('"flutter.use_proxy"'), lessThan(firstFetch));
      expect(work.indexOf('"flutter.use_tor"'), lessThan(firstFetch));
    });

    test('one privateRouteOn() for the worker and the configure activity '
        '(M8)', () {
      expect(
        flat(
          body(
            code(privateRouteKt),
            r'internal fun Context\.privateRouteOn\(\)',
          ),
        ),
        flat('''
          val flutterPrefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
          return flutterPrefs.getBoolean("flutter.use_tor", false) ||
              flutterPrefs.getBoolean("flutter.use_proxy", false)'''),
      );
      for (final f in [workerKt, configureKt]) {
        expect(code(f), isNot(contains('fun privateRouteOn')), reason: f.path);
      }
    });
  });

  group('Android: a timeframe change with a private route on (R-A5g)', () {
    test('the configure activity asks the workmanager plugin\'s public '
        'native helper for one run of the Dart widget job, under a unique '
        'name of its own', () {
      final kt = code(configureKt);
      final dart = File('lib/services/widget_service.dart').readAsStringSync();
      final taskId = RegExp(
        r"const _taskId = '([^']+)';",
      ).firstMatch(dart)!.group(1)!;
      final ownName = RegExp(
        r'private const val DART_REFRESH_NOW = "([^"]+)"',
      ).firstMatch(kt)?.group(1);

      expect(kt, contains('import dev.fluttercommunity.workmanager.WM'));
      expect(kt, contains('private const val DART_TASK = "$taskId"'));
      expect(ownName, isNotNull);
      expect(ownName, isNot(taskId), reason: 'would replace the periodic job');
      expect(count(kt, 'WM.enqueueOneOffTask('), 1);
      expectPinned(body(kt, r'private fun enqueueDartRefresh\(\)'), [
        '''
          WM.enqueueOneOffTask(
              context = this,
              uniqueName = DART_REFRESH_NOW,
              dartTask = DART_TASK,
              existingWorkPolicy = ExistingWorkPolicy.APPEND_OR_REPLACE,
              constraintsConfig = Constraints.Builder()
                  .setRequiredNetworkType(NetworkType.CONNECTED)
                  .build(),
              backoffPolicyConfig = null,
          )''',
      ]);
      expectPinned(body(kt, r'private fun triggerImmediateRefresh\(\)'), [
        'if (privateRouteOn()) enqueueDartRefresh()',
      ]);
      // None of the plugin's private input keys or worker class.
      for (final private in [
        'BackgroundWorker',
        'be.tramckrijte',
        'DART_TASK_KEY',
        'PAYLOAD_KEY',
      ]) {
        expect(kt, isNot(contains(private)), reason: private);
      }
    });
  });

  // The public source snapshot strips ios/; skip there, as the other Swift
  // checks do.
  final widgetDir = Directory('ios/BagWidget');
  final swiftFile = File('ios/BagWidget/BagWidget.swift');
  group(
    'iOS widget (BagWidget.swift)',
    skip: swiftFile.existsSync()
        ? false
        : 'ios/ is not in this checkout (public snapshot)',
    () {
      String swift() => code(swiftFile);
      String allSwift() {
        final files =
            widgetDir
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => f.path.endsWith('.swift'))
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        return files.map(code).join('\n');
      }

      test('widget_fetched_at and widget_route_ok are read type-safely, with '
          'route_ok defaulting to ok, and nothing reads widget_updated_at', () {
        final s = allSwift();
        expectPinned(body(s, r'static func load\(_ ud: UserDefaults\?\)'), [
          'let seconds = (ud?.object(forKey: "widget_fetched_at") '
              'as? NSNumber)?.int64Value',
          'ok: ud?.object(forKey: "widget_route_ok") as? Bool ?? true,',
          'fetchedAt: seconds.map '
              '{ Date(timeIntervalSince1970: TimeInterval(\$0)) })',
        ]);
        expect(count(s, '"widget_fetched_at"'), 1, reason: 'never written');
        expect(s, isNot(contains('integer(forKey: "widget_fetched_at"')));
        expect(s, isNot(contains('widget_updated_at')));
      });

      test('the badge: Tor before Proxy, none before the app has written the '
          'flags; its dot, label and pill by route and state', () {
        final s = swift();
        expect(
          flat(body(s, r'static func storedRoute\(')),
          flat('''
            let tor = ud?.object(forKey: "widget_use_tor") as? Bool
            let proxy = ud?.object(forKey: "widget_use_proxy") as? Bool
            if tor == true { return .tor }
            if proxy == true { return .proxy }
            if tor == nil && proxy == nil { return nil }
            return .direct'''),
        );
        expectPinned(s, [
          'case .tor: return "Tor" case .proxy: return "Proxy" '
              'case .direct: return "Direct"',
        ]);
        final badge = body(s, 'struct RouteBadge');
        expectPinned(badge, [
          'if let route = status.route {',
          'if route != .direct { Circle() '
              '.fill(status.ok ? routeOkDot : routeFailedDot)',
          '.foregroundColor(route == .direct ? mutedText : .white)',
          '.background(fill(route), in: Capsule())',
          '.overlay(Capsule().strokeBorder(stroke(route), lineWidth: 1))',
        ]);
        expect(
          flat(body(badge, r'private func fill\(')),
          flat(
            'if route == .direct { return badgeDirectFill } '
            'return status.ok ? badgeOkFill : badgeFailedFill',
          ),
        );
        expect(
          flat(body(badge, r'private func stroke\(')),
          flat(
            'if route == .direct { return badgeDirectStroke } '
            'return status.ok ? badgeOkStroke : badgeFailedStroke',
          ),
        );
      });

      test('the colours as drawn', () {
        expectPinned(swift(), [
          'private let routeOkDot = Color(hex: 0x00C896)',
          'private let routeFailedDot = Color(hex: 0xFF4757)',
          'private let pausedText = Color(hex: 0xFF6B78)',
          'private let mutedText = Color(hex: 0xA9A9C4)',
          'private let badgeOkFill = Color(hex: 0x0E1F1A)',
          'private let badgeOkStroke = Color(hex: 0x1F4D40)',
          'private let badgeFailedFill = Color(hex: 0x24101A)',
          'private let badgeFailedStroke = Color(hex: 0x5A1E2A)',
          'private let badgeDirectFill = Color(hex: 0x13131A)',
          'private let badgeDirectStroke = Color(hex: 0x252535)',
        ]);
      });

      test('the time: its copy by state, the date once the fetch is not '
          'from the entry\'s day, short on the small widget and long on the '
          'medium, coloured by state', () {
        final s = swift();
        expectPinned(body(s, r'func text\(short: Bool, now: Date\)'), [
          'formatter.locale = Locale(identifier: "en_US_POSIX")',
          'formatter.dateFormat = Calendar.current.isDate(fetchedAt, '
              'inSameDayAs: now) ? "HH:mm" : "d MMM"',
          r'if ok { return "Updated \(stamp)" }',
          r'return short ? "Paused \(stamp)" : "Paused since \(stamp)"',
        ]);
        final small = body(s, 'struct SmallView');
        final medium = body(s, 'struct MediumView');
        expectPinned(small, [
          'if let time = e.status.text(short: true, now: e.date) { Text(time)',
          '.foregroundColor(e.status.ok ? mutedText : pausedText)',
        ]);
        expect(small, isNot(contains('short: false')));
        expectPinned(medium, [
          'if let time = e.status.text(short: false, now: e.date) { Text(time)',
          '.foregroundColor(e.status.ok ? mutedText : pausedText)',
        ]);
        expect(medium, isNot(contains('short: true')));
      });

      test('the timeline: an entry at the next local midnight, so the day '
          'rule flips without a fetch', () {
        final timeline = body(
          swift(),
          r'func timeline\(for configuration: BagWidgetIntent',
        );
        expectPinned(timeline, [
          '''
          var entries = [entry]
          if let fetchedAt = entry.status.fetchedAt,
             Calendar.current.isDate(fetchedAt, inSameDayAs: entry.date),
             let midnight = Calendar.current.date(
                 byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: entry.date)) {
              var atMidnight = entry
              atMidnight.date = midnight
              entries.append(atMidnight)
          }''',
          'return Timeline(entries: entries, policy: .after(next))',
        ]);
      });

      test('the self-fetch says whether it got through and never stamps the '
          'price time (it fetches only the chart)', () {
        final s = allSwift();
        final timeline = body(
          swift(),
          r'func timeline\(for configuration: BagWidgetIntent',
        );
        expectPinned(timeline, [
          'ud?.set(tfChange >= 0, forKey: "widget_change_positive") '
              'ud?.set(true, forKey: "widget_route_ok") '
              'entry = BagEntry.load(showChange: configuration.showChange) '
              '} else { ud?.set(false, forKey: "widget_route_ok") '
              'entry = BagEntry.load(showChange: configuration.showChange) }',
        ]);
        expect(
          count(s, '"widget_route_ok"'),
          3,
          reason: 'one read, two writes',
        );
      });

      test('no new network code in the extension (R-A5f)', () {
        final s = allSwift();
        // The counts since CI M5 (one bounded session type, one request
        // line behind WidgetSession's route re-check).
        expect(count(s, 'URLSession'), 5);
        expect(count(s, '.data(from:'), 3);
        expect(count(s, 'URLComponents'), 2);
        expect(count(s, 'https://'), 2);
        for (final banned in ['dataTask', 'URLRequest', 'NWConnection']) {
          expect(s, isNot(contains(banned)), reason: banned);
        }
      });
    },
  );

  group('lib/', () {
    test('no longer writes widget_updated_at', () {
      for (final f in Directory(
        'lib',
      ).listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        expect(code(f), isNot(contains("'widget_updated_at'")), reason: f.path);
      }
    });

    test('one redraw helper and one "no price" recorder (M8)', () {
      final ws = code(File('lib/services/widget_service.dart'));
      expect(count(ws, 'HomeWidget.updateWidget('), 1);
      expectPinned(ws, [
        'Future<void> _redraw() => HomeWidget.updateWidget( name: _widgetName, '
            'iOSName: _widgetName, qualifiedAndroidName: _androidWidgetName);',
        'WidgetService.recordNoPrice(appGroupId: AppConstants.iosAppGroupId)',
      ]);
      expect(
        flat(body(ws, r'static Future<void> recordNoPrice\(')),
        flat('''
          if (appGroupId != null) await HomeWidget.setAppGroupId(appGroupId);
          await HomeWidget.saveWidgetData<bool>(_keyRouteOk, false);
          await _redraw();'''),
      );
      expect(ws, isNot(contains('_iosRecordNoPrice')));
      expect(ws, isNot(contains('recordFailedPriceFetch')));
      expectPinned(code(File('lib/providers/price_provider.dart')), [
        'WidgetService.recordNoPrice().ignore();',
      ]);
    });
  });
}
