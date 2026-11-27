/// iOS with Tor on: the widget extension never goes online (it can't run Tor
/// in its ~30 MB), so `WidgetService.update` fetches the widget's chart
/// through the app's own Tor and pushes it as three App Group keys —
/// `widget_chart_prices`, `widget_chart_days`, `widget_chart_change` — which
/// the Swift timeline renders only when `widget_chart_days` matches the
/// configured timeframe.
///
/// - ready + TorRoute: pushes the widget's currency and timeframe.
/// - starting, a non-Tor route, Android, or a fetch that throws: no chart key
///   is written at all (the last push stays). Android runs Tor itself too
///   (Task A1), but its widget never needed the push: `PriceNotifier` saves
///   the chart for it, fetched through the same Tor-routed service.
/// - The three keys go out together or not at all, with `widget_chart_days`
///   cleared first and written last.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/models/dca_entry.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/portfolio.dart';
import 'package:bag/models/price_data.dart';
import 'package:bag/providers/dca_provider.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/price_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/services/embedded_tor_service.dart';
import 'package:bag/services/tor_host.dart';
import 'package:bag/services/price_service.dart';
import 'package:bag/services/tor_service.dart';
import 'package:bag/services/widget_service.dart';

const _chartKeys = {
  'widget_chart_prices',
  'widget_chart_days',
  'widget_chart_change',
};

/// Bootstraps at once on port 47123; `hold` keeps it at `starting`.
class _ReadyBackend implements EmbeddedTorBackend {
  Completer<void>? hold;
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
  Future<void> start() async {
    final pending = hold;
    if (pending != null) await pending.future;
    _bootstrapped = true;
  }

  @override
  Future<void> bootstrap() async {}

  @override
  Future<void> setDormant(bool dormant) async {}

  @override
  Future<void> stop() async => _bootstrapped = false;
}

/// A [PriceService] whose chart is scripted and whose calls are recorded.
class _FakeChartService extends PriceService {
  _FakeChartService(NetworkRoute route, {this.chart, this.error})
    : super(route: route);

  final List<(DateTime, double)>? chart;
  final Object? error;
  final calls = <(String, int)>[];

  @override
  Future<List<(DateTime, double)>> fetchChartData(
    String currency,
    int days, {
    void Function()? onRefreshed,
  }) async {
    calls.add((currency, days));
    if (error != null) throw error!;
    return chart!;
  }
}

/// [_FakeChartService] whose chart fetch waits on [gate], as one over Tor
/// takes seconds: calls made meanwhile overlap it.
class _HeldChartService extends _FakeChartService {
  _HeldChartService(super.route) : super(chart: _chart);

  final gate = Completer<void>();

  @override
  Future<List<(DateTime, double)>> fetchChartData(
    String currency,
    int days, {
    void Function()? onRefreshed,
  }) async {
    calls.add((currency, days));
    await gate.future;
    return chart!;
  }
}

/// [_FakeChartService] that also answers the price fetch, for driving the
/// real [PriceNotifier]. With [cached], `build()` takes the cached path: a
/// widget update at once, then a background refresh that updates it again.
/// With [holdChart], the chart fetch waits on [gate].
class _FakePriceLayer extends _FakeChartService {
  _FakePriceLayer(super.route, {this.cached, this.holdChart = false})
    : super(chart: _chart);

  final PriceData? cached;
  final bool holdChart;
  final gate = Completer<void>();

  @override
  PriceData? getCachedPrice() => cached;

  @override
  Future<List<(DateTime, double)>> fetchChartData(
    String currency,
    int days, {
    void Function()? onRefreshed,
  }) async {
    if (!holdChart) return super.fetchChartData(currency, days);
    calls.add((currency, days));
    await gate.future;
    return chart!;
  }

  @override
  Future<PriceData> fetchCurrentPrice(List<String> currencies) async =>
      PriceData(
        prices: const {'usd': 100000},
        changes24h: const {'usd': 1.0},
        fetchedAt: DateTime.now(),
      );

  @override
  Future<void> prewarmCharts(String currency) async {}
}

/// A keychain that refuses every read and write, as iOS does for an item
/// that isn't accessible yet (`errSecInteractionNotAllowed`).
class _LockedKeychain extends MapBase<String, String> {
  Never _locked() => throw PlatformException(
    code: '-25308',
    message: 'errSecInteractionNotAllowed',
  );

  @override
  String? operator [](Object? key) => _locked();

  @override
  void operator []=(String key, String value) => _locked();

  @override
  void clear() => _locked();

  @override
  Iterable<String> get keys => _locked();

  @override
  String? remove(Object? key) => _locked();
}

class _EmptyDcaNotifier extends DcaNotifier {
  @override
  List<DcaEntry> build() => [];
}

final _chart = [
  (DateTime(2026, 11, 1), 100000.0),
  (DateTime(2026, 11, 2), 105000.0),
  (DateTime(2026, 11, 3), 110000.0),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The fake App Group.
  final store = <String, Object?>{};

  /// Every channel call in order: `save:<key>=<value>` and `reload`.
  final log = <String>[];

  late _ReadyBackend backend;

  setUp(() {
    store.clear();
    log.clear();
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({AppConstants.keyUseTor: true});
    backend = _ReadyBackend();
    EmbeddedTorService.debugBackend = backend;
    TorService.debugIsIOS = true;
    // The UI isolate with Tor selected: TorHost starts nothing with neither
    // a route nor a route check (N-f).
    TorHost.routeChanged(tor: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'), (
          call,
        ) async {
          final args = call.arguments as Map?;
          switch (call.method) {
            case 'saveWidgetData':
              final id = args!['id'] as String;
              final data = args['data'];
              if (data == null) {
                store.remove(id);
              } else {
                store[id] = data;
              }
              log.add('save:$id=$data');
              return true;
            case 'getWidgetData':
              return store[args!['id'] as String] ?? args['defaultValue'];
            case 'updateWidget':
              log.add('reload');
              return true;
          }
          return null;
        });
  });

  tearDown(() async {
    await EmbeddedTorService.stop();
    // A start a failed case left held can't stall the next case.
    EmbeddedTorService.debugReset();
    EmbeddedTorService.debugBackend = null;
    TorService.debugIsIOS = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
  });

  Future<void> update(PriceService service, {String currency = 'usd'}) =>
      WidgetService.update(
        priceData: PriceData(
          prices: {currency: 100000},
          changes24h: {currency: 1.0},
          fetchedAt: DateTime.now(),
        ),
        portfolio: Portfolio(btcAmount: 1, selectedCurrencies: [currency]),
        priceService: service,
      );

  Iterable<String> chartWrites() =>
      log.where((e) => _chartKeys.any((k) => e.startsWith('save:$k=')));

  group('iOS, TorRoute, embedded client ready', () {
    setUp(() async {
      await EmbeddedTorService.ensureStarted();
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
    });

    test(
      "pushes prices, days and change for the widget's currency and timeframe",
      () async {
        store['widget_timeframe_days'] = 30;
        final service = _FakeChartService(const TorRoute(), chart: _chart);

        await update(service, currency: 'eur');

        expect(service.calls, [('eur', 30)]);
        expect(jsonDecode(store['widget_chart_prices'] as String), [
          100000.0,
          105000.0,
          110000.0,
        ]);
        expect(store['widget_chart_days'], 30);
        // The exact string the Swift self-fetch writes for widget_change.
        expect(store['widget_chart_change'], '+10.0%');
      },
    );

    test('a falling chart is formatted without a plus sign', () async {
      store['widget_timeframe_days'] = 7;
      final service = _FakeChartService(
        const TorRoute(),
        chart: [
          (DateTime(2026, 11, 1), 100000.0),
          (DateTime(2026, 11, 8), 97550.0),
        ],
      );

      await update(service);

      expect(store['widget_chart_change'], '-2.5%');
    });

    test('days cleared first, written last, then the widget reloads', () async {
      store['widget_timeframe_days'] = 7;
      store['widget_chart_days'] = 30; // an earlier push
      final service = _FakeChartService(const TorRoute(), chart: _chart);

      await update(service);

      final writes = chartWrites().toList();
      expect(writes.first, 'save:widget_chart_days=null');
      expect(writes.last, 'save:widget_chart_days=7');
      expect(writes, hasLength(4));
      expect(log.last, 'reload');
      expect(
        log.lastIndexOf('reload'),
        greaterThan(log.lastIndexOf('save:widget_chart_days=7')),
      );
    });

    test('no configured timeframe: the widget default (1 week)', () async {
      final service = _FakeChartService(const TorRoute(), chart: _chart);
      await update(service);
      expect(service.calls, [('usd', 7)]);
      expect(store['widget_chart_days'], 7);
    });

    test('an unparseable timeframe falls back to the widget default', () async {
      store['widget_timeframe_days'] = 'week';
      final service = _FakeChartService(const TorRoute(), chart: _chart);
      await update(service);
      expect(service.calls, [('usd', 7)]);
    });

    test('a timeframe the widget does not offer falls back too', () async {
      store['widget_timeframe_days'] = 14;
      final service = _FakeChartService(const TorRoute(), chart: _chart);
      await update(service);
      expect(service.calls, [('usd', 7)]);
    });

    test('every timeframe the widget offers maps to itself', () async {
      // ChartTimeframe.days in ios/BagWidget/BagWidget.swift: 1D 1W 1M 1Y 5Y ALL.
      for (final days in [
        1,
        7,
        30,
        365,
        AppConstants.timeframe5YDays,
        AppConstants.timeframeAllDays,
      ]) {
        store['widget_timeframe_days'] = days;
        final service = _FakeChartService(const TorRoute(), chart: _chart);
        await update(service, currency: 'xau');
        expect(service.calls, [('xau', days)], reason: '$days days');
        expect(store['widget_chart_days'], days, reason: '$days days');
      }
    });

    test('a fetch that throws writes no chart key at all', () async {
      store['widget_timeframe_days'] = 7;
      final service = _FakeChartService(
        const TorRoute(),
        error: const RouteUnavailableException(),
      );

      await update(service);

      expect(service.calls, hasLength(1));
      expect(chartWrites(), isEmpty);
    });

    test('overlapping updates share one chart fetch and one write '
        '(T5-M1)', () async {
      store['widget_timeframe_days'] = 30;
      final service = _HeldChartService(const TorRoute());

      final first = update(service);
      final second = update(service);
      await pumpEventQueue();
      expect(service.calls, [('usd', 30)]);

      service.gate.complete();
      await Future.wait([first, second]);
      expect(service.calls, [('usd', 30)]);
      expect(chartWrites(), hasLength(4)); // one push: cleared, 3 written
      expect(store['widget_chart_days'], 30);

      // Once it has landed, the next update fetches again.
      await update(service);
      expect(service.calls, hasLength(2));
    });

    test('an overlapping update for another currency is not folded into the '
        'push in flight', () async {
      final service = _HeldChartService(const TorRoute());

      final usd = update(service);
      final eur = update(service, currency: 'eur');
      await pumpEventQueue();
      expect(service.calls, [('usd', 7), ('eur', 7)]);
      service.gate.complete();
      await Future.wait([usd, eur]);
    });

    test('a chart too short for a change writes no chart key', () async {
      final service = _FakeChartService(
        const TorRoute(),
        chart: [(DateTime(2026, 11, 1), 100000.0)],
      );
      await update(service);
      expect(chartWrites(), isEmpty);
    });

    test(
      'a non-Tor route pushes nothing (the widget fetches itself)',
      () async {
        for (final route in <NetworkRoute>[
          const DirectRoute(),
          const ProxyRoute(
            ProxyConfig(type: ProxyType.socks5, host: '10.0.0.5', port: 1080),
          ),
          const MisconfiguredProxyRoute(),
        ]) {
          final service = _FakeChartService(route, chart: _chart);
          await update(service);
          expect(service.calls, isEmpty, reason: '$route');
        }
        expect(chartWrites(), isEmpty);
      },
    );

    test('Android, built-in Tor ready: the iOS push never runs', () async {
      // The group's client is ready: it is the platform that keeps it out.
      TorService.debugIsIOS = false;
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      final service = _FakeChartService(const TorRoute(), chart: _chart);

      await update(service);

      expect(service.calls, isEmpty);
      expect(chartWrites(), isEmpty);
    });
  });

  test('starting: no fetch, no chart key', () async {
    backend.hold = Completer<void>();
    final start = EmbeddedTorService.ensureStarted();
    expect(EmbeddedTorService.state, EmbeddedTorState.starting);
    final service = _FakeChartService(const TorRoute(), chart: _chart);

    await update(service);

    expect(service.calls, isEmpty);
    expect(chartWrites(), isEmpty);
    backend.hold!.complete();
    await start;
  });

  test('off: no fetch, no chart key', () async {
    expect(EmbeddedTorService.state, EmbeddedTorState.off);
    final service = _FakeChartService(const TorRoute(), chart: _chart);
    await update(service);
    expect(service.calls, isEmpty);
    expect(chartWrites(), isEmpty);
  });

  test('without a PriceService the push is skipped', () async {
    await EmbeddedTorService.ensureStarted();
    await WidgetService.update(
      priceData: PriceData(
        prices: const {'usd': 100000},
        changes24h: const {'usd': 1.0},
        fetchedAt: DateTime.now(),
      ),
      portfolio: const Portfolio(btcAmount: 1, selectedCurrencies: ['usd']),
    );
    expect(chartWrites(), isEmpty);
  });

  for (final ios in [true, false]) {
    test('TB-9 (${ios ? 'iOS' : 'Android'}): a portfolio amount of 0 with a '
        'keychain that can\'t be read: the price still goes out, and the '
        'last net worth stays rather than being blanked', () async {
      TorService.debugIsIOS = ios;
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues(_LockedKeychain());
      store['widget_net_worth'] = r'$20,000.00';

      await WidgetService.update(
        priceData: PriceData(
          prices: const {'usd': 100000},
          changes24h: const {'usd': 1.0},
          fetchedAt: DateTime.now(),
        ),
        portfolio: const Portfolio(btcAmount: 0, selectedCurrencies: ['usd']),
      );

      expect(store['widget_price'], isNotNull);
      expect(store['widget_currency'], 'usd');
      expect(store['widget_net_worth'], r'$20,000.00');
      expect(log, isNot(contains('save:widget_net_worth=null')));
      expect(log.last, 'reload');
    });
  }

  group('PriceNotifier', () {
    Future<_FakePriceLayer> fetchOnce(
      NetworkRoute route, {
      _FakePriceLayer? layer,
    }) async {
      final prefs = await SharedPreferences.getInstance();
      final service = layer ?? _FakePriceLayer(route);
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          initialProxyConfigProvider.overrideWithValue(null),
          dcaProvider.overrideWith(_EmptyDcaNotifier.new),
          priceServiceProvider.overrideWith((ref) => service),
        ],
      );
      addTearDown(c.dispose);
      await c.read(priceProvider.future);
      // Both widget writers are fire-and-forget.
      await pumpEventQueue();
      return service;
    }

    test('iOS Tor: one chart fetch for the widget, by the push', () async {
      await EmbeddedTorService.ensureStarted();
      store['widget_timeframe_days'] = 30;

      final service = await fetchOnce(const TorRoute());

      // _saveWidgetChartData stands down; only update() fetched.
      expect(service.calls.where((c) => c.$2 == 30), hasLength(1));
      expect(store['widget_chart_days'], 30);
    });

    test("iOS Tor, cached price: build's update and the background "
        "refresh's update share one chart fetch (T5-M1)", () async {
      await EmbeddedTorService.ensureStarted();
      store['widget_timeframe_days'] = 30;
      final layer = _FakePriceLayer(
        const TorRoute(),
        cached: PriceData(
          prices: const {'usd': 99000},
          changes24h: const {'usd': 0.5},
          fetchedAt: DateTime.now(),
        ),
        holdChart: true,
      );

      final service = await fetchOnce(const TorRoute(), layer: layer);
      // Both updates have reached the push by now (the background fetch is
      // instant here); over Tor the first fetch is still running.
      await pumpEventQueue();
      expect(service.calls.where((c) => c.$2 == 30), hasLength(1));

      layer.gate.complete();
      await pumpEventQueue();
      expect(service.calls.where((c) => c.$2 == 30), hasLength(1));
      expect(store['widget_chart_days'], 30);
    });

    test('Android Tor: one chart fetch for the widget, by PriceNotifier, '
        'saved the Android way', () async {
      TorService.debugIsIOS = false;
      await EmbeddedTorService.ensureStarted();
      store['widget_timeframe_days'] = 30;

      final service = await fetchOnce(const TorRoute());

      // The fetch went through the Tor-routed service, once; update() didn't
      // fetch (the push is iOS only).
      expect(service.route, const TorRoute());
      expect(service.calls.where((c) => c.$2 == 30), hasLength(1));
      expect(store.containsKey('widget_chart_prices'), isTrue);
      expect(store.containsKey('widget_chart_days'), isFalse);
    });

    test('TB-7, Android: the timeframe changed while the chart was fetched: '
        'the old timeframe\'s chart is not saved under the new one',
        () async {
      TorService.debugIsIOS = false;
      SharedPreferences.setMockInitialValues({});
      store['widget_timeframe_days'] = 7;
      final layer = _FakePriceLayer(const DirectRoute(), holdChart: true);
      final fetching = fetchOnce(const DirectRoute(), layer: layer);
      await pumpEventQueue();
      expect(layer.calls, contains(('usd', 7)));

      // The configure activity: the user picked 1 month meanwhile.
      store['widget_timeframe_days'] = 30;
      layer.gate.complete();
      await fetching;
      await pumpEventQueue();

      expect(store.containsKey('widget_chart_prices'), isFalse);
      expect(log.where((e) => e.startsWith('save:widget_change=+10')), isEmpty);
    });

    test('TB-7: a timeframe the widget does not offer is read as the default '
        '(1 week), as the Tor push reads it', () async {
      TorService.debugIsIOS = false;
      SharedPreferences.setMockInitialValues({});
      store['widget_timeframe_days'] = 14;
      expect(await WidgetService.getTimeframeDays(), 7);
      store['widget_timeframe_days'] = 'week';
      expect(await WidgetService.getTimeframeDays(), 7);
      store['widget_timeframe_days'] = 365;
      expect(await WidgetService.getTimeframeDays(), 365);

      final service = await fetchOnce(const DirectRoute());
      expect(service.calls.where((c) => c.$2 == 365), hasLength(1));
      expect(store.containsKey('widget_chart_prices'), isTrue);
    });

    test('iOS direct: the existing widget chart save still runs', () async {
      SharedPreferences.setMockInitialValues({});
      store['widget_timeframe_days'] = 30;

      final service = await fetchOnce(const DirectRoute());

      expect(service.calls.where((c) => c.$2 == 30), hasLength(1));
      expect(store['widget_chart_days'], 30);
    });
  });

  // The Swift can't be compiled here; these pin the source shape the "no
  // request with Tor on" guarantee rests on, so a later edit can't quietly
  // undo it. Behaviour is verified on the rc.
  //
  // The public source snapshot strips ios/, so the group is skipped when
  // the widget sources are absent; the file must still load there.
  final widgetDir = Directory('ios/BagWidget');
  final widgetFile = File('ios/BagWidget/BagWidget.swift');
  final haveSwift = widgetFile.existsSync();
  group(
    'BagWidget.swift',
    skip: haveSwift ? false : 'ios/ is not in this checkout (public snapshot)',
    () {
      // Read lazily: group bodies run even when the group is skipped.
      String swift() => widgetFile.readAsStringSync();

      /// Every *.swift file of the widget extension, comments removed (a
      /// `//` comment starts the line or follows whitespace, so a URL's
      /// `https://` is kept), joined.
      String allSwiftCode() {
        final files =
            widgetDir
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => f.path.endsWith('.swift'))
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        expect(files, isNotEmpty);
        return files
            .map(
              (f) => f
                  .readAsStringSync()
                  .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
                  .replaceAll(RegExp(r'(^|\s)//.*$', multiLine: true), ''),
            )
            .join('\n');
      }

      int count(String code, String pattern) =>
          RegExp(RegExp.escape(pattern)).allMatches(code).length;

      test('no Tor probe and no check.torproject.org request', () {
        final code = allSwiftCode();
        expect(code, isNot(contains('torproject')));
        expect(code, isNot(contains('networkAllowed')));
      });

      test('widgetSession: proxy first, then Tor → nil, then direct', () {
        final body = RegExp(
          r'private func widgetSession\(\) -> WidgetSession\? \{(.*?)\n\}',
          dotAll: true,
        ).firstMatch(swift())!.group(1)!;
        final proxy = body.indexOf('"widget_use_proxy"');
        final tor = body.indexOf('"widget_use_tor"');
        final direct = body.indexOf(
          'return WidgetSession(urlSession: boundedSession(proxy: nil), '
          'route: .direct)',
        );
        expect(proxy, isNonNegative);
        expect(tor, greaterThan(proxy));
        expect(direct, greaterThan(tor));
        expect(
          body.substring(tor),
          matches(RegExp(r'^"widget_use_tor"\) \{\s*return nil\s*\}')),
        );
        expect(
          body,
          contains(
            'return proxySession().map '
            '{ WidgetSession(urlSession: \$0, route: .proxy) }',
          ),
        );
      });

      String fnBody(String code, String signature) {
        final start = code.indexOf(signature);
        expect(start, isNonNegative, reason: signature);
        var depth = 0;
        for (var i = code.indexOf('{', start); i < code.length; i++) {
          if (code[i] == '{') depth++;
          if (code[i] == '}' && --depth == 0) {
            return code.substring(code.indexOf('{', start) + 1, i);
          }
        }
        fail('unbalanced: $signature');
      }

      String flat(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

      test('R-6 / CI M5: the route flags are read again immediately before '
          'every request, and none goes out once they changed: Tor on now '
          'means none at all', () {
        final code = allSwiftCode();
        final session = fnBody(code, 'private struct WidgetSession {');
        expect(
          flat(fnBody(session, 'func data(from url: URL) async throws -> Data')),
          flat('''
            guard stillCurrent() else { throw URLError(.cancelled) }
            let (data, _) = try await urlSession.data(from: url)
            return data'''),
        );
        expect(
          flat(fnBody(session, 'func stillCurrent() -> Bool')),
          flat('''
            guard let ud = UserDefaults(suiteName: appGroup) else { return false }
            if ud.bool(forKey: "widget_use_tor") { return false }
            let proxy = ud.bool(forKey: "widget_use_proxy")
            switch route {
            case .proxy:  return proxy
            case .direct: return !proxy
            }'''),
        );
        // After the fetch: a route that changed meanwhile writes nothing of
        // it, and the widget renders the app's push.
        final timeline = fnBody(
          code,
          'func timeline(for configuration: BagWidgetIntent',
        );
        final check = timeline.indexOf('if !session.stillCurrent() {');
        expect(check, isNonNegative);
        expect(
          timeline.indexOf('session.invalidate()'),
          inExclusiveRange(0, check),
        );
        expect(
          flat(timeline.substring(check)),
          startsWith(
            'if !session.stillCurrent() { entry = BagEntry.loadPushed('
            'showChange: configuration.showChange, days: days) } '
            'else if let (prices, tfChange) = fetched {',
          ),
        );
        expect(timeline.indexOf('ud?.set(json'), greaterThan(check));
      });

      test('StandBy: the net worth is marked privacySensitive in both '
          'sizes, so iOS can redact it on a locked device', () {
        final code = allSwiftCode();
        for (final view in ['struct SmallView', 'struct MediumView']) {
          final body = fnBody(code, view);
          final netWorth = RegExp(
            r'if let nw = e\.netWorth \{\s*Text\(nw\)([^}]*)\}',
          ).firstMatch(body);
          expect(netWorth, isNotNull, reason: view);
          expect(
            netWorth!.group(1),
            contains('.privacySensitive()'),
            reason: '$view: net worth not privacy-sensitive',
          );
        }
        // The only money a widget shows that is the user's own (it draws no
        // DCA P&L): nothing else needs the mark.
        expect(code, isNot(contains('widget_pnl')));
        expect(count(code, '.privacySensitive()'), 2);
      });

      test('every request goes through the session widgetSession() hands '
          'out, and both sessions have the widget\'s short limits', () {
        final code = allSwiftCode();

        // No shared session any more: the direct one is bounded too.
        expect(count(code, 'URLSession.shared'), 0);
        expect(count(code, 'URLSession(configuration:'), 1);
        expect(
          flat(fnBody(code, 'private func boundedSession(')),
          flat('''
            let config = URLSessionConfiguration.ephemeral
            if let proxy { config.proxyConfigurations = [proxy] }
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 45
            return URLSession(configuration: config)'''),
        );
        expect(count(code, 'boundedSession(proxy: proxy)'), 1);
        expect(count(code, 'boundedSession(proxy: nil)'), 1);

        // One caller obtains a session, fetches through it once and
        // invalidates it.
        expect(count(code, '= widgetSession()'), 1);
        expect(code, contains('if let session = widgetSession() {'));
        expect(count(code, 'fetchChartData(session: session'), 1);
        expect(count(code, 'session.invalidate()'), 1);
        expect(count(code, 'finishTasksAndInvalidate()'), 1);

        // One line sends anything, inside WidgetSession.data(from:); the
        // two fetch helpers call that, never a URLSession.
        expect(count(code, 'urlSession.data(from: url)'), 1);
        expect(count(code, '.data(from:'), 3);
        expect(count(code, 'let data = try await session.data(from: url)'), 2);
        expect(count(code, 'session: URLSession'), 0);
        expect(count(code, 'session: WidgetSession'), 4);

        // No other way onto the network.
        for (final banned in [
          'Data(contentsOf:',
          '.bytes(from:',
          '.download(',
          '.upload(',
          'webSocketTask',
          'streamTask',
          'NWConnection',
          'URLRequest',
          'dataTask',
        ]) {
          expect(code, isNot(contains(banned)), reason: banned);
        }
      });
    },
  );

  group('saveChartPricesForWidget', () {
    test('iOS: writes the chart with the timeframe it covers', () async {
      await WidgetService.saveChartPricesForWidget(chartData: _chart, days: 30);

      expect(store['widget_chart_days'], 30);
      expect(store['widget_chart_change'], '+10.0%');
      expect(jsonDecode(store['widget_chart_prices'] as String), hasLength(3));
      final writes = chartWrites().toList();
      expect(writes.first, 'save:widget_chart_days=null');
      expect(writes.last, 'save:widget_chart_days=30');
    });

    test('Android: unchanged — prices only, no days or chart change', () async {
      TorService.debugIsIOS = false;

      await WidgetService.saveChartPricesForWidget(chartData: _chart, days: 30);

      expect(store.containsKey('widget_chart_prices'), isTrue);
      expect(store.containsKey('widget_chart_days'), isFalse);
      expect(store.containsKey('widget_chart_change'), isFalse);
      expect(store['widget_change'], '+10.0%');
    });
  });
}
