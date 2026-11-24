import 'package:flutter_test/flutter_test.dart';

import 'package:bag/models/network_route.dart';

void main() {
  group('ProxyConfig json', () {
    test('json round-trips with and without credentials', () {
      const withAuth = ProxyConfig(
        type: ProxyType.http,
        host: 'proxy.lan',
        port: 3128,
        username: 'u',
        password: 'p@ss:word',
      );
      const withoutAuth = ProxyConfig(
        type: ProxyType.socks5,
        host: '10.0.0.2',
        port: 1080,
      );

      expect(ProxyConfig.fromJson(withAuth.toJson()), withAuth);
      expect(ProxyConfig.fromJson(withoutAuth.toJson()), withoutAuth);
      expect(withAuth.hasCredentials, isTrue);
      expect(withoutAuth.hasCredentials, isFalse);
      expect(withoutAuth.toJson().containsKey('username'), isFalse);
      expect(withoutAuth.toJson().containsKey('password'), isFalse);
      expect(withAuth.toJson()['type'], 'http');
    });

    test('fromJson throws FormatException on missing or invalid fields', () {
      expect(() => ProxyConfig.fromJson({}), throwsFormatException);
      expect(
        () => ProxyConfig.fromJson({'type': 'ftp', 'host': 'h', 'port': 1}),
        throwsFormatException,
      );
      expect(
        () => ProxyConfig.fromJson({
          'type': 'socks5',
          'host': 'h',
          'port': '1080',
        }),
        throwsFormatException,
      );
      expect(
        () => ProxyConfig.fromJson({'type': 'socks5', 'port': 1080}),
        throwsFormatException,
      );
    });

    test('fromJson rejects half a credential pair', () {
      for (final half in [
        {'username': 'u'},
        {'password': 'p'},
      ]) {
        expect(
          () => ProxyConfig.fromJson({
            'type': 'http',
            'host': 'h',
            'port': 1,
            ...half,
          }),
          throwsFormatException,
        );
      }
    });

    test('label is host:port', () {
      const cfg = ProxyConfig(type: ProxyType.socks5, host: 'h', port: 9);
      expect(cfg.label, 'h:9');
    });

    test('toString never contains the password', () {
      const cfg = ProxyConfig(
        type: ProxyType.socks5,
        host: 'h',
        port: 1080,
        username: 'user',
        password: 's3cr3t',
      );
      expect(cfg.toString(), isNot(contains('s3cr3t')));
      expect(cfg.toString(), isNot(contains('user')));
      expect(cfg.toString(), 'ProxyConfig(socks5, h:1080, auth: yes)');
    });
  });

  group('ProxyConfig.validate', () {
    String? v(
      ProxyType type,
      String host,
      String port, [
      String? username,
      String? password,
    ]) => ProxyConfig.validate(
      type: type,
      host: host,
      port: port,
      username: username,
      password: password,
    );

    test('accepts valid configs', () {
      expect(v(ProxyType.socks5, '10.0.0.2', '1080'), isNull);
      expect(v(ProxyType.http, 'proxy.lan', '3128', 'u', 'p@ss:word'), isNull);
      expect(v(ProxyType.socks5, '::1', '1080'), isNull);
    });

    test('rejects an empty host', () {
      expect(
        v(ProxyType.socks5, '  ', '1080'),
        contains('Enter the proxy host'),
      );
    });

    test('rejects a scheme in the host', () {
      expect(
        v(ProxyType.socks5, 'socks5://h', '1080'),
        contains('without socks5:// or http://'),
      );
      expect(
        v(ProxyType.http, 'http://h', '3128'),
        contains('without socks5:// or http://'),
      );
    });

    test('rejects a port inside the host but allows IPv6', () {
      expect(
        v(ProxyType.socks5, 'h:1080', '1080'),
        contains('Put the port in the port field'),
      );
      expect(v(ProxyType.socks5, 'fe80::1', '1080'), isNull);
    });

    test('rejects hosts that are neither a hostname nor an IP address', () {
      const msg = 'Enter a hostname or IP address';
      for (final host in [
        '[::1]:1080',
        'a:b:c',
        '::1]:1;DIRECT;PROXY [::2',
        'proxy.lan;',
        'user@proxy.lan',
        '[::1]',
        'proxy.lan/path',
        'proxy lan',
        'fe80::1%eth0',
        '-proxy.lan',
        'proxy..lan',
        'a' * 64 + '.lan',
      ]) {
        for (final type in ProxyType.values) {
          expect(v(type, host, '1080'), contains(msg), reason: host);
        }
      }
    });

    test('accepts IPv4, bare IPv6 and DNS names', () {
      for (final host in [
        '127.0.0.1',
        '::1',
        '2001:db8::2',
        'proxy',
        'proxy.lan',
        'my-proxy.example.com',
        'a' * 63 + '.lan',
      ]) {
        expect(v(ProxyType.http, host, '1080'), isNull, reason: host);
      }
    });

    test('rejects an out-of-range or non-numeric port', () {
      for (final p in ['0', '65536', 'abc', '']) {
        expect(
          v(ProxyType.socks5, 'h', p),
          contains('Port must be 1–65535'),
          reason: p,
        );
      }
      expect(v(ProxyType.socks5, 'h', '65535'), isNull);
      expect(v(ProxyType.socks5, 'h', ' 1 '), isNull);
    });

    test('requires username and password together', () {
      const msg = 'Enter both a username and a password, or neither';
      expect(v(ProxyType.socks5, 'h', '1', 'u'), contains(msg));
      expect(v(ProxyType.socks5, 'h', '1', null, 'p'), contains(msg));
      expect(v(ProxyType.http, 'h', '1', 'u', ''), contains(msg));
    });

    test('rejects a colon in an HTTP username', () {
      expect(
        v(ProxyType.http, 'h', '1', 'a:b', 'p'),
        contains('cannot contain ":"'),
      );
      expect(v(ProxyType.socks5, 'h', '1', 'a:b', 'p'), isNull);
    });

    test('rejects characters the PROXY string cannot carry (HTTP)', () {
      const msg = 'cannot contain ";" or start or end with a space';
      expect(v(ProxyType.http, 'h', '1', 'a;b', 'p'), contains(msg));
      expect(v(ProxyType.http, 'h', '1', 'u', 'a;b'), contains(msg));
      expect(v(ProxyType.http, 'h', '1', ' u', 'p'), contains(msg));
      expect(v(ProxyType.http, 'h', '1', 'u', 'p '), contains(msg));
      expect(v(ProxyType.http, 'h', '1', 'u', 'a b'), isNull);
      expect(v(ProxyType.socks5, 'h', '1', 'a;b', ' p'), isNull);
    });

    test('rejects SOCKS5 credentials over 255 UTF-8 bytes', () {
      expect(
        v(ProxyType.socks5, 'h', '1', 'u' * 256, 'p'),
        contains('255 bytes'),
      );
      expect(
        v(ProxyType.socks5, 'h', '1', 'u', 'p' * 256),
        contains('255 bytes'),
      );
      expect(v(ProxyType.socks5, 'h', '1', 'u' * 255, 'p' * 255), isNull);
      // 128 two-byte characters = 256 bytes, though only 128 code units.
      expect(
        v(ProxyType.socks5, 'h', '1', 'u', 'é' * 128),
        contains('255 bytes'),
      );
      expect(v(ProxyType.http, 'h', '1', 'u' * 256, 'p'), isNull);
    });
  });

  group('ProxyConfig.isRoutable', () {
    ProxyConfig c(
      ProxyType type, {
      String host = 'proxy.lan',
      int port = 1080,
      String? username,
      String? password,
    }) => ProxyConfig(
      type: type,
      host: host,
      port: port,
      username: username,
      password: password,
    );

    test('accepts a valid host with no credentials or a full pair', () {
      for (final type in ProxyType.values) {
        expect(c(type).isRoutable, isTrue);
        expect(c(type, host: '::1').isRoutable, isTrue);
        expect(c(type, username: 'u', password: 'p@ss:w').isRoutable, isTrue);
      }
    });

    test('rejects an invalid host or port', () {
      for (final type in ProxyType.values) {
        expect(c(type, host: 'a;DIRECT').isRoutable, isFalse);
        expect(c(type, host: '').isRoutable, isFalse);
        expect(c(type, host: '_proxy').isRoutable, isFalse);
        expect(c(type, port: 0).isRoutable, isFalse);
        expect(c(type, port: 65536).isRoutable, isFalse);
      }
    });

    test('rejects half pairs and empty credentials, for both types', () {
      for (final type in ProxyType.values) {
        expect(c(type, username: 'u').isRoutable, isFalse);
        expect(c(type, password: 'p').isRoutable, isFalse);
        expect(c(type, username: '', password: '').isRoutable, isFalse);
        expect(c(type, username: '', password: 'p').isRoutable, isFalse);
        expect(c(type, username: 'u', password: '').isRoutable, isFalse);
      }
    });

    test('HTTP credentials must be carriable in the PROXY string', () {
      expect(
        c(ProxyType.http, username: 'a:b', password: 'p').isRoutable,
        isFalse,
      );
      expect(
        c(ProxyType.http, username: 'u', password: 'a;b').isRoutable,
        isFalse,
      );
      expect(
        c(ProxyType.http, username: 'u', password: ' p').isRoutable,
        isFalse,
      );
      expect(
        c(ProxyType.socks5, username: 'a:b', password: ' p;').isRoutable,
        isTrue,
      );
    });

    test('SOCKS5 credentials must fit RFC 1929 length bytes', () {
      expect(
        c(ProxyType.socks5, username: 'u' * 256, password: 'p').isRoutable,
        isFalse,
      );
      expect(
        c(ProxyType.socks5, username: 'u', password: 'é' * 128).isRoutable,
        isFalse,
      );
    });
  });

  group('NetworkRoute', () {
    test('routes compare by value', () {
      const a = ProxyConfig(type: ProxyType.socks5, host: 'h', port: 1080);
      const copy = ProxyConfig(type: ProxyType.socks5, host: 'h', port: 1080);
      const other = ProxyConfig(type: ProxyType.http, host: 'h', port: 1080);

      expect(const ProxyRoute(a), ProxyRoute(copy));
      expect(const ProxyRoute(a).hashCode, ProxyRoute(copy).hashCode);
      expect(const ProxyRoute(a), isNot(ProxyRoute(other)));
      expect(const TorRoute() == const DirectRoute(), isFalse);
      expect(const TorRoute(), const TorRoute());
      expect(const DirectRoute(), const DirectRoute());
      expect(const MisconfiguredProxyRoute(), const MisconfiguredProxyRoute());
      expect(const TorRoute() == const MisconfiguredProxyRoute(), isFalse);
    });

    test('only DirectRoute is not private', () {
      const cfg = ProxyConfig(type: ProxyType.socks5, host: 'h', port: 1);
      expect(const DirectRoute().isPrivate, isFalse);
      expect(const TorRoute().isPrivate, isTrue);
      expect(const ProxyRoute(cfg).isPrivate, isTrue);
      expect(const MisconfiguredProxyRoute().isPrivate, isTrue);
    });
  });

  group('.onion (R-2)', () {
    test('isOnionHost matches the .onion TLD only, case and trailing dots '
        'aside', () {
      for (final host in [
        'abc.onion',
        'ABC.ONION',
        'x.y.onion',
        'abc.onion.',
        'abc.onion..',
      ]) {
        expect(isOnionHost(host), isTrue, reason: host);
      }
      for (final host in [
        'foo.onion.example.com',
        'onion.example',
        'example.com',
        'notonion',
        'abconion',
        '',
      ]) {
        expect(isOnionHost(host), isFalse, reason: host);
      }
    });

    test('only Tor and a SOCKS5 proxy can reach an onion service', () {
      const socks = ProxyConfig(
        type: ProxyType.socks5,
        host: '10.0.0.5',
        port: 1080,
      );
      const http = ProxyConfig(type: ProxyType.http, host: 'p', port: 3128);
      expect(const TorRoute().canReachOnion, isTrue);
      expect(const ProxyRoute(socks).canReachOnion, isTrue);
      expect(const DirectRoute().canReachOnion, isFalse);
      expect(const ProxyRoute(http).canReachOnion, isFalse);
      expect(const MisconfiguredProxyRoute().canReachOnion, isFalse);
    });
  });
}
