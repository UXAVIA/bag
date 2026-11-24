import 'dart:async';
import 'dart:io';

import 'package:bag/models/network_route.dart';
import 'package:bag/services/embedded_tor_service.dart';
import 'package:bag/services/tor_host.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/services/network/routed_http.dart';
import 'package:bag/services/tor_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../network/fake_proxies.dart';

/// An [EmbeddedTorBackend] whose port the test sets directly, so it can point
/// the embedded client at a [FakeSocks5Proxy] and move it between requests.
class _PortBackend implements EmbeddedTorBackend {
  _PortBackend(this.socksPort);

  /// The port reported once bootstrapped.
  int socksPort;

  /// While set, `start()` waits on it, holding the state at `starting`.
  Completer<void>? hold;

  /// When true, `start()` throws, ending in `failed`.
  bool failStart = false;

  bool _bootstrapped = false;
  final _failures = StreamController<Object>.broadcast();
  final _events = StreamController<int>.broadcast();

  void dieOnItsOwn() {
    _bootstrapped = false;
    _failures.add('proxy exited');
  }

  @override
  Stream<Object> get failures => _failures.stream;

  @override
  Stream<int> get events => _events.stream;

  @override
  bool get bootstrapped => _bootstrapped;

  @override
  int get port => _bootstrapped ? socksPort : -1;

  @override
  Future<void> start() async {
    final pending = hold;
    if (pending != null) await pending.future;
    if (failStart) throw StateError('bootstrap failed');
    _bootstrapped = true;
  }

  @override
  Future<void> bootstrap() async {}

  @override
  Future<void> setDormant(bool dormant) async {}

  @override
  Future<void> stop() async {
    _bootstrapped = false;
  }
}

/// GETs `http://bag-test.invalid:<port>/` over [TorRoute]. `.invalid` never
/// resolves (RFC 6761), so a hit on the target proves the proxy resolved it.
Future<int> _get(int port, {HttpClient? client}) async {
  final c = client ?? routeHttpClient(HttpClient(), const TorRoute());
  try {
    final request = await c.getUrl(Uri.parse('http://bag-test.invalid:$port/'));
    // A fresh connection per request, so each one goes through the factory.
    request.persistentConnection = false;
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    if (client == null) c.close(force: true);
  }
}

/// `TorRoute` goes through the embedded client's SOCKS port on both
/// platforms (iOS since Phase B, Android since Task A1): the suite runs with
/// `TorService.debugIsIOS` true and false.
void main() {
  for (final ios in [true, false]) {
    group(ios ? 'iOS' : 'Android', () => _suite(ios: ios));
  }

  test('nothing in lib/ contacts check.torproject.org', () {
    final offenders = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => f.readAsStringSync().contains('check.torproject.org'))
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty);
  });
}

void _suite({required bool ios}) {
  late TargetServer target;
  late FakeSocks5Proxy proxy;
  late _PortBackend backend;

  setUp(() async {
    target = await TargetServer.start();
    proxy = await FakeSocks5Proxy.start(targetPort: target.port);
    backend = _PortBackend(proxy.port);
    EmbeddedTorService.debugBackend = backend;
    TorService.debugIsIOS = ios;
    // The UI isolate with Tor selected: TorHost starts nothing with neither
    // a route nor a route check (N-f).
    TorHost.routeChanged(tor: true);
    RouteGate.invalidateCache();
  });

  tearDown(() async {
    await EmbeddedTorService.stop();
    // A start a failed case left held can't stall the next case.
    EmbeddedTorService.debugReset();
    EmbeddedTorService.debugBackend = null;
    TorService.debugIsIOS = null;
    RouteGate.debugProbeOverride = null;
    RouteGate.invalidateCache();
    await proxy.close();
    await target.close();
  });

  group('TorRoute over the embedded client', () {
    test(
      'ready: the request goes through the SOCKS port, DNS remote',
      () async {
        await EmbeddedTorService.ensureStarted();
        expect(EmbeddedTorService.state, EmbeddedTorState.ready);
        expect(await TorHost.port(), proxy.port);

        expect(await _get(target.port), 200);
        expect(target.hits, 1);
        // Exact bytes: the hostname was sent as ATYP 0x03 with no trailing NUL,
        // so the device never resolved it.
        expect(proxy.connectHosts, ['bag-test.invalid']);
      },
    );

    test('starting: refused, nothing reaches the proxy or target', () async {
      backend.hold = Completer<void>();
      final start = EmbeddedTorService.ensureStarted();
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(await TorHost.port(), -1);

      await expectLater(
        _get(target.port),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            'Tor is not connected',
          ),
        ),
      );
      expect(target.hits, 0);
      expect(proxy.connectHosts, isEmpty);

      backend.hold!.complete();
      await start;
    });

    test('failed: refused, nothing reaches the proxy or target', () async {
      backend.failStart = true;
      await EmbeddedTorService.ensureStarted();
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);

      await expectLater(_get(target.port), throwsA(isA<SocketException>()));
      expect(target.hits, 0);
      expect(proxy.connectHosts, isEmpty);
    });

    test('off: refused', () async {
      expect(EmbeddedTorService.state, EmbeddedTorState.off);
      await expectLater(_get(target.port), throwsA(isA<SocketException>()));
      expect(target.hits, 0);
    });

    test('the refusal names neither host nor port', () async {
      try {
        await _get(target.port);
        fail('request should have been refused');
      } on SocketException catch (e) {
        expect(e.message, 'Tor is not connected');
        expect(e.address, isNull);
        expect(e.port, isNull);
        expect(e.toString(), isNot(contains('127.0.0.1')));
        expect(e.toString(), isNot(contains('${target.port}')));
      }
    });

    test('a client built before bootstrap works once Tor is ready', () async {
      final client = routeHttpClient(HttpClient(), const TorRoute());
      addTearDown(() => client.close(force: true));

      await expectLater(
        _get(target.port, client: client),
        throwsA(isA<SocketException>()),
      );
      await EmbeddedTorService.ensureStarted();
      expect(await _get(target.port, client: client), 200);
      expect(target.hits, 1);
    });

    test('a long-lived client follows a restart onto a new port', () async {
      await EmbeddedTorService.ensureStarted();
      final client = routeHttpClient(HttpClient(), const TorRoute());
      addTearDown(() => client.close(force: true));

      expect(await _get(target.port, client: client), 200);
      expect(proxy.connectHosts, hasLength(1));

      // Tor restarts and comes back on another port; the old one is gone.
      final moved = await FakeSocks5Proxy.start(targetPort: target.port);
      addTearDown(moved.close);
      await proxy.close();
      backend.socksPort = moved.port;
      expect(await TorHost.port(), moved.port);

      expect(await _get(target.port, client: client), 200);
      expect(moved.connectHosts, ['bag-test.invalid']);
      expect(proxy.connectHosts, hasLength(1));
      expect(target.hits, 2);
    });

    test('a client that dies is refused at once', () async {
      await EmbeddedTorService.ensureStarted();
      final client = routeHttpClient(HttpClient(), const TorRoute());
      addTearDown(() => client.close(force: true));
      expect(await _get(target.port, client: client), 200);

      // The automatic retry (M2) fails, so failed is what stays.
      backend.failStart = true;
      backend.dieOnItsOwn();
      await Future<void>.delayed(Duration.zero);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);

      await expectLater(
        _get(target.port, client: client),
        throwsA(isA<SocketException>()),
      );
      expect(target.hits, 1);
    });
  });

  group('TorRoute probe', () {
    test('RouteGate.probe is available only when ready', () async {
      expect(await RouteGate.probe(const TorRoute()), RouteStatus.unavailable);

      backend.hold = Completer<void>();
      final start = EmbeddedTorService.ensureStarted();
      expect(EmbeddedTorService.state, EmbeddedTorState.starting);
      expect(await RouteGate.probe(const TorRoute()), RouteStatus.unavailable);

      backend.hold!.complete();
      await start;
      expect(EmbeddedTorService.state, EmbeddedTorState.ready);
      expect(await RouteGate.probe(const TorRoute()), RouteStatus.available);

      // The automatic retry (M2) fails, so failed is what stays.
      backend.failStart = true;
      backend.dieOnItsOwn();
      await Future<void>.delayed(Duration.zero);
      expect(EmbeddedTorService.state, EmbeddedTorState.failed);
      expect(await RouteGate.probe(const TorRoute()), RouteStatus.unavailable);
    });

    test('probeCached is not cached: a state change shows at once', () async {
      expect(
        await RouteGate.probeCached(const TorRoute()),
        RouteStatus.unavailable,
      );

      await EmbeddedTorService.ensureStarted();
      expect(
        await RouteGate.probeCached(const TorRoute()),
        RouteStatus.available,
        reason: 'bootstrap must not wait out a cached "unavailable"',
      );

      // The automatic retry (M2) fails, so failed is what stays.
      backend.failStart = true;
      backend.dieOnItsOwn();
      await Future<void>.delayed(Duration.zero);
      expect(
        await RouteGate.probeCached(const TorRoute()),
        RouteStatus.unavailable,
        reason: 'a crash must not keep a cached "available"',
      );
    });
  });
}
