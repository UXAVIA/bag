import 'package:flutter_test/flutter_test.dart';

import 'package:bag/models/network_route.dart';
import 'package:bag/services/network/explorer_url.dart';
import 'package:bag/services/network/route_gate.dart';

const _socks = ProxyRoute(
  ProxyConfig(type: ProxyType.socks5, host: '10.0.0.5', port: 1080),
);
const _http = ProxyRoute(
  ProxyConfig(type: ProxyType.http, host: '10.0.0.5', port: 3128),
);

void main() {
  group('plainHttpAllowed (R-3)', () {
    test('onion, loopback, private, link-local and .local hosts', () {
      for (final host in [
        'abc.onion',
        'localhost',
        'node.localhost',
        '127.0.0.1',
        '127.8.9.10',
        '::1',
        '10.0.0.1',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.1.20',
        'fe80::1',
        'fd12:3456::1',
        'fc00::5',
        'umbrel.local',
        'Umbrel.Local.',
      ]) {
        expect(plainHttpAllowed(host), isTrue, reason: host);
      }
    });

    test('anything public is refused', () {
      for (final host in [
        'blockstream.info',
        'node.example.com',
        'foo.onion.example.com',
        'local',
        'mylocal',
        '8.8.8.8',
        '172.15.0.1',
        '172.32.0.1',
        '192.169.0.1',
        '11.0.0.1',
        '2001:db8::1',
        'fe00::1',
      ]) {
        expect(plainHttpAllowed(host), isFalse, reason: host);
      }
    });
  });

  group('checkCustomExplorerUrl', () {
    ({String? url, String? error}) check(
      String input, [
      NetworkRoute route = const DirectRoute(),
    ]) =>
        checkCustomExplorerUrl(input, route);

    test('normalises what it accepts', () {
      expect(check('https://node.example/api/').url, 'https://node.example');
      expect(check('https://node.example/api/v1').url, 'https://node.example');
      expect(check('node.example').url, 'https://node.example');
      expect(check('http://192.168.1.20:3002').url, 'http://192.168.1.20:3002');
      expect(check('  ').url, isNull);
      expect(check('  ').error, isNull);
    });

    test('a scheme-less .onion gets http:// (R-2)', () {
      expect(check('abc.onion', const TorRoute()).url, 'http://abc.onion');
      expect(check('abc.onion:3002/api', _socks).url, 'http://abc.onion:3002');
    });

    test('plain http to a public host is refused (R-3)', () {
      for (final route in [const DirectRoute(), const TorRoute(), _socks]) {
        final r = check('http://node.example', route);
        expect(r.url, isNull, reason: '$route');
        expect(r.error, plainHttpRefusedMessage, reason: '$route');
      }
      expect(check('https://node.example').error, isNull);
    });

    test('.onion is refused on a route that cannot reach it (R-2)', () {
      for (final route in [const DirectRoute(), _http]) {
        for (final input in ['http://abc.onion', 'abc.onion', 'http://ABC.ONION.']) {
          final r = check(input, route);
          expect(r.url, isNull, reason: '$route $input');
          expect(r.error, onionNeedsTorMessage, reason: '$route $input');
        }
      }
      expect(check('http://abc.onion', const TorRoute()).error, isNull);
      expect(check('http://abc.onion', _socks).error, isNull);
      // A clearnet host with ".onion" in it is not an onion service.
      expect(check('https://foo.onion.example.com').error, isNull);
    });

    test('other schemes and link-local addresses are refused as before', () {
      expect(check('ftp://node.example').error, isNotNull);
      expect(check('http://169.254.169.254').error, isNotNull);
    });
  });
}
