/// A native `stop()` that never returns must not hold the route setters:
/// `TorService.followRoute` issues the embedded Tor stop — state `off`,
/// generation bumped — at once and doesn't wait for it, because
/// `EmbeddedTorService` serialises native start and stop itself. A later
/// start still waits for the hung stop before it touches the backend.
///
/// Its own file on purpose: flutter test runs each file in a fresh isolate,
/// and this test runs the setters in `fakeAsync`. A static future another
/// test completed in the real zone (`WidgetService`'s route-flag chain)
/// would schedule its callbacks outside the fake zone, and the fake clock
/// could never drive them.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/models/network_route.dart';
import 'package:bag/models/price_data.dart';
import 'package:bag/mock/mock_data.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/price_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/services/embedded_tor_service.dart';
import 'package:bag/services/tor_service.dart';

/// Starts at once; `stop()` waits on [stopHold] while it is set.
class _HangingStopBackend implements EmbeddedTorBackend {
  int startCalls = 0;
  int stopCalls = 0;
  Completer<void>? stopHold;
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
    startCalls++;
    _bootstrapped = true;
  }

  @override
  Future<void> bootstrap() async {}

  @override
  Future<void> setDormant(bool dormant) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
    _bootstrapped = false;
    final pending = stopHold;
    if (pending != null) await pending.future;
  }
}

/// Keeps the ready transition's forced refresh off the network.
class _QuietPriceNotifier extends PriceNotifier {
  @override
  Future<PriceData> build() async => mockPriceData;

  @override
  Future<void> refresh({bool force = false}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _HangingStopBackend backend;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('home_widget'),
          (call) async => null,
        );
    FlutterSecureStorage.setMockInitialValues({});
    backend = _HangingStopBackend();
    EmbeddedTorService.debugBackend = backend;
    TorService.debugIsIOS = true;
  });

  tearDown(() async {
    final hold = backend.stopHold;
    if (hold != null && !hold.isCompleted) hold.complete();
    backend.stopHold = null;
    await EmbeddedTorService.stop();
    // A start a failed case left held can't stall the next case.
    EmbeddedTorService.debugReset();
    EmbeddedTorService.debugBackend = null;
    TorService.debugIsIOS = null;
  });

  test('a hung native stop holds neither the route setter nor the next '
      'one, and a later start still waits for it', () {
    fakeAsync((async) {
      SharedPreferences.setMockInitialValues({});
      late ProviderContainer c;
      SharedPreferences.getInstance().then((prefs) {
        c = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            priceProvider.overrideWith(_QuietPriceNotifier.new),
          ],
        );
      });
      async.flushMicrotasks();
      final settings = c.read(networkSettingsProvider.notifier);

      var on = false;
      settings.setUseTor(true).then((_) => on = true);
      async.elapse(const Duration(milliseconds: 10));
      expect(on, isTrue);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);

      final hung = backend.stopHold = Completer<void>(); // never completes
      var off = false;
      var next = false;
      settings.setUseTor(false).then((_) => off = true);
      settings.setUseProxy(false).then((_) => next = true);
      // Both setters complete without any time passing: the stop is issued,
      // not waited for.
      async.flushMicrotasks();
      expect(off, isTrue);
      expect(next, isTrue);
      expect(c.read(networkSettingsProvider).route, const DirectRoute());
      // Issued at once, even though the native stop hangs: fail-closed.
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      expect(EmbeddedTorService.port, -1);
      expect(backend.stopCalls, 1);

      // Tor back on while the stop still hangs. The setter isn't held
      // either, but the new start waits for the hung stop before it touches
      // the backend — however long that takes.
      var onAgain = false;
      settings.setUseTor(true).then((_) => onAgain = true);
      async.flushMicrotasks();
      expect(onAgain, isTrue);
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      async.elapse(const Duration(seconds: 30));
      expect(backend.startCalls, 1);
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(EmbeddedTorService.port, -1);

      hung.complete();
      async.flushMicrotasks();
      expect(backend.startCalls, 2);
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);

      c.dispose();
      async.flushMicrotasks();
    });
  });
}
