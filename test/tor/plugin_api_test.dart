// The subset of the `tor` plugin's API that EmbeddedTorService's default
// backend (`_PluginTorBackend` in lib/services/embedded_tor_service.dart)
// calls, checked against the real package at the commit pubspec.yaml pins.
// A fork bump that renames, retypes or drops one of these fails here, by
// name, rather than somewhere inside the service.
//
// The typed tear-offs are the check: this file only compiles while every
// member still has the type the backend relies on. The runtime expectations
// pin the plugin's "no circuit" values, which the service's liveness check
// (`bootstrapped && port > 0`) depends on.
//
// No native code is loaded. Only `Tor.init()` and `Tor.stopAllInProcess()`
// initialise the Rust library (flutter_rust_bridge's `RustLib.init`), and
// both are torn off, never called.
// `Tor.instance` is a plain Dart singleton, and nothing else here starts,
// stops or bootstraps anything.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tor/tor.dart';

void main() {
  group('package:tor API used by EmbeddedTorService', () {
    test('Tor.init is a static initialiser that returns a Tor', () {
      final Future<Tor> Function() init = Tor.init;
      expect(init, isA<Future<Tor> Function()>());
    });

    test('Tor.instance is the singleton', () {
      final Tor tor = Tor.instance;
      expect(identical(tor, Tor.instance), isTrue);
    });

    test('start, bootstrap, setClientDormant and stop return futures', () {
      final tor = Tor.instance;
      final Future<void> Function() start = tor.start;
      final Future<void> Function() bootstrap = tor.bootstrap;
      final Future<void> Function(bool dormant) setClientDormant =
          tor.setClientDormant;
      final Future<void> Function() stop = tor.stop;
      expect([start, bootstrap, setClientDormant, stop], hasLength(4));
    });

    test('before a start, the client is not bootstrapped and has no port', () {
      final tor = Tor.instance;
      final bool bootstrapped = tor.bootstrapped;
      final int port = tor.port;
      expect(bootstrapped, isFalse);
      expect(port, -1);
    });

    test('events broadcasts the port as an int', () {
      final StreamController<int> events = Tor.instance.events;
      final Stream<int> stream = events.stream;
      expect(stream.isBroadcast, isTrue);
    });

    test('failures broadcasts TorProxyFailure', () {
      final StreamController<TorProxyFailure> failures = Tor.instance.failures;
      final Stream<Object> stream = failures.stream;
      expect(stream.isBroadcast, isTrue);
      expect(TorProxyFailure('x').message, 'x');
    });

    // TorHost's sweep (EmbeddedTorService.stopAllInProcess). Torn off only:
    // calling it would load the Rust library.
    test('Tor.stopAllInProcess is static and returns how many it stopped', () {
      final Future<int> Function() stopAll = Tor.stopAllInProcess;
      expect(stopAll, isA<Future<int> Function()>());
    });

    test('TorProxyFailure says whether a process-wide stop caused it, false '
        'unless named', () {
      final TorProxyFailure Function(String message, {bool processWideStop})
      failure = TorProxyFailure.new;
      final bool byItself = failure('x').processWideStop;
      expect(byItself, isFalse);
      expect(failure('x', processWideStop: true).processWideStop, isTrue);
      expect(failure('y').toString(), 'TorProxyFailure: y');
    });
  });
}
