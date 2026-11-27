import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bag/models/network_route.dart';
import 'package:bag/services/network/routed_http.dart';
import 'package:bag/services/network/socks5_connect.dart';

import 'fake_proxies.dart';
import 'test_certs.dart';

const _user = 'user';
const _pass = 'p@ss:wörd';

void main() {
  late TargetServer target;
  final cleanup = <Future<void> Function()>[];

  setUp(() async {
    target = await TargetServer.start();
    cleanup.add(target.close);
  });

  tearDown(() async {
    for (final close in cleanup.reversed) {
      await close();
    }
    cleanup.clear();
  });

  HttpClient newClient(NetworkRoute route, {SecurityContext? tls}) {
    final client = routeHttpClient(HttpClient(), route, securityContext: tls);
    cleanup.add(() async => client.close(force: true));
    return client;
  }

  Future<String> get(HttpClient client, String url) async {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    return response.transform(utf8.decoder).join();
  }

  Future<int> deadPort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  ProxyConfig config(
    ProxyType type,
    int port, {
    String? username,
    String? password,
  }) => ProxyConfig(
    type: type,
    host: '127.0.0.1',
    port: port,
    username: username,
    password: password,
  );

  String basic(String user, String pass) =>
      'Basic ${base64Encode(utf8.encode('$user:$pass'))}';

  test('direct: reaches the target without any proxy', () async {
    final body = await get(
      newClient(const DirectRoute()),
      'http://127.0.0.1:${target.port}/',
    );
    expect(body, '{"ok":true}');
    expect(target.hits, 1);
  });

  group('socks5', () {
    test(
      'request reaches target through proxy and sends the hostname, not an IP',
      () async {
        final proxy = await FakeSocks5Proxy.start(targetPort: target.port);
        cleanup.add(proxy.close);

        final body = await get(
          newClient(ProxyRoute(config(ProxyType.socks5, proxy.port))),
          'http://bag-test.invalid:${target.port}/',
        );

        expect(body, '{"ok":true}');
        expect(proxy.connectHosts, ['bag-test.invalid']);
        expect(target.hits, 1);
      },
    );

    test('sends credentials exactly as typed', () async {
      final proxy = await FakeSocks5Proxy.start(
        username: _user,
        password: _pass,
        targetPort: target.port,
      );
      cleanup.add(proxy.close);

      final body = await get(
        newClient(
          ProxyRoute(
            config(
              ProxyType.socks5,
              proxy.port,
              username: _user,
              password: _pass,
            ),
          ),
        ),
        'http://bag-test.invalid:${target.port}/',
      );

      expect(body, '{"ok":true}');
      expect(proxy.authAttempts.single, (_user, _pass));
    });
  });

  group('socks5 https', () {
    SecurityContext trusting(String caPem) =>
        SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(utf8.encode(caPem));

    Future<TargetServer> tlsTarget(String certPem, String keyPem) async {
      final server = await TargetServer.startSecure(
        certPem: certPem,
        keyPem: keyPem,
      );
      cleanup.add(server.close);
      return server;
    }

    test('https through the tunnel verifies and decrypts', () async {
      final secure = await tlsTarget(bagTestLeafPem, bagTestLeafKey);
      final proxy = await FakeSocks5Proxy.start(targetPort: secure.port);
      cleanup.add(proxy.close);

      final body = await get(
        newClient(
          ProxyRoute(config(ProxyType.socks5, proxy.port)),
          tls: trusting(testCaPem),
        ),
        'https://bag-test.invalid:${secure.port}/',
      );

      expect(body, '{"ok":true}');
      expect(proxy.connectHosts, ['bag-test.invalid']);
      expect(secure.hits, 1);
    });

    test(
      'https works when the SOCKS reply arrives one byte at a time',
      () async {
        final secure = await tlsTarget(bagTestLeafPem, bagTestLeafKey);
        final proxy = await FakeSocks5Proxy.start(
          targetPort: secure.port,
          byteByByte: true,
        );
        cleanup.add(proxy.close);

        final body = await get(
          newClient(
            ProxyRoute(config(ProxyType.socks5, proxy.port)),
            tls: trusting(testCaPem),
          ),
          'https://bag-test.invalid:${secure.port}/',
        );

        expect(body, '{"ok":true}');
      },
    );

    test('wrong hostname on the certificate is rejected', () async {
      final secure = await tlsTarget(otherLeafPem, otherLeafKey);
      final proxy = await FakeSocks5Proxy.start(targetPort: secure.port);
      cleanup.add(proxy.close);

      await expectLater(
        get(
          newClient(
            ProxyRoute(config(ProxyType.socks5, proxy.port)),
            tls: trusting(testCaPem),
          ),
          'https://bag-test.invalid:${secure.port}/',
        ),
        throwsA(isA<HandshakeException>()),
      );

      expect(secure.hits, 0);
    });

    test('untrusted CA is rejected', () async {
      final secure = await tlsTarget(bagTestLeafPem, bagTestLeafKey);
      final proxy = await FakeSocks5Proxy.start(targetPort: secure.port);
      cleanup.add(proxy.close);

      await expectLater(
        get(
          newClient(
            ProxyRoute(config(ProxyType.socks5, proxy.port)),
            tls: trusting(otherCaPem),
          ),
          'https://bag-test.invalid:${secure.port}/',
        ),
        throwsA(isA<HandshakeException>()),
      );

      expect(secure.hits, 0);
    });

    test('a proxy that goes silent after CONNECT: TLS gives up at the '
        'handshake deadline', () async {
      final proxy = await FakeSocks5Proxy.start(
        targetPort: target.port,
        silentAfterConnect: true,
      );
      cleanup.add(proxy.close);
      // No connectionTimeout on the HttpClient: only the handshake deadline
      // can end this.
      final client = routeHttpClient(
        HttpClient(),
        ProxyRoute(config(ProxyType.socks5, proxy.port)),
        securityContext: trusting(testCaPem),
        handshakeTimeout: const Duration(seconds: 1),
      );
      cleanup.add(() async => client.close(force: true));

      final watch = Stopwatch()..start();
      await expectLater(
        get(client, 'https://bag-test.invalid/').timeout(
          const Duration(seconds: 10),
        ),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            'TLS handshake timed out',
          ),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('data from the proxy before the TLS handshake is refused', () async {
      // A TLS server cannot speak before the ClientHello, so a ServerHello can
      // never share a chunk with the SOCKS reply. Bytes there are a
      // misbehaving proxy, and must not be fed to (or silently dropped
      // before) the TLS layer.
      final proxy = await FakeSocks5Proxy.start(
        targetPort: target.port,
        payload: utf8.encode('early bytes'),
      );
      cleanup.add(proxy.close);

      await expectLater(
        get(
          newClient(
            ProxyRoute(config(ProxyType.socks5, proxy.port)),
            tls: trusting(testCaPem),
          ),
          'https://bag-test.invalid/',
        ),
        throwsA(isA<Socks5ProtocolError>()),
      );
    });
  });

  test('cancelling a connection stalled in the SOCKS handshake closes the '
      'proxy socket at once', () async {
    final proxy = await SilentServer.start();
    cleanup.add(proxy.close);
    // HttpClient cancels the connection task when this fires.
    final client = newClient(
      ProxyRoute(config(ProxyType.socks5, proxy.port)),
    )..connectionTimeout = const Duration(seconds: 1);

    final watch = Stopwatch()..start();
    await expectLater(
      get(client, 'http://bag-test.invalid:${target.port}/'),
      throwsA(isA<SocketException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    // Before, cancel waited on the stalled handshake future, and the socket
    // to the proxy stayed open for the full 60 s handshake budget.
    await proxy.clientClosed.timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('the socket to the proxy was left open'),
    );
  });

  group('socks5 failures and framing', () {
    Future<Socks5Tunnel> connect(
      FakeSocks5Proxy proxy, {
      String? username,
      String? password,
    }) => socks5Connect(
      proxy: InternetAddress.loopbackIPv4,
      proxyPort: proxy.port,
      targetHost: 'bag-test.invalid',
      targetPort: 80,
      username: username,
      password: password,
      timeout: const Duration(seconds: 5),
    );

    test('a wrong password throws ProxyAuthRejected', () async {
      final proxy = await FakeSocks5Proxy.start(
        username: _user,
        password: 'something else',
        targetPort: target.port,
      );
      cleanup.add(proxy.close);

      await expectLater(
        connect(proxy, username: _user, password: _pass),
        throwsA(isA<ProxyAuthRejected>()),
      );
    });

    test(
      'credentials required but none configured throws ProxyAuthRequired',
      () async {
        final proxy = await FakeSocks5Proxy.start(
          username: _user,
          password: _pass,
          targetPort: target.port,
        );
        cleanup.add(proxy.close);

        await expectLater(connect(proxy), throwsA(isA<ProxyAuthRequired>()));
        expect(proxy.authAttempts, isEmpty);
      },
    );

    test('a CONNECT reply of 0x05 throws ProxyConnectFailed(5)', () async {
      final proxy = await FakeSocks5Proxy.start(
        targetPort: target.port,
        connectReplyCode: 0x05,
      );
      cleanup.add(proxy.close);

      await expectLater(
        connect(proxy),
        throwsA(
          isA<ProxyConnectFailed>().having((e) => e.replyCode, 'code', 5),
        ),
      );
    });

    test(
      'failures are SocketExceptions and never mention the credentials',
      () async {
        final proxy = await FakeSocks5Proxy.start(
          username: 'zq-user-7',
          password: 'zq-pass-9',
          targetPort: target.port,
        );
        cleanup.add(proxy.close);

        await expectLater(
          connect(proxy, username: 'zq-user-7', password: _pass),
          throwsA(
            isA<SocketException>().having(
              (e) => e.toString(),
              'text',
              allOf(isNot(contains('zq-user-7')), isNot(contains(_pass))),
            ),
          ),
        );
      },
    );

    test('a proxy that does not speak SOCKS5 is a protocol error', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      cleanup.add(() => server.close());
      server.listen((s) {
        s.add([0x04, 0x5A]);
        s.close();
      });

      await expectLater(
        socks5Connect(
          proxy: InternetAddress.loopbackIPv4,
          proxyPort: server.port,
          targetHost: 'bag-test.invalid',
          targetPort: 80,
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<Socks5ProtocolError>()),
      );
    });

    for (final byteByByte in [false, true]) {
      test('data sent with the reply is delivered intact '
          '(${byteByByte ? 'byte by byte' : 'one write'})', () async {
        final payload = utf8.encode('hello from the target');
        final proxy = await FakeSocks5Proxy.start(
          targetPort: target.port,
          payload: payload,
          byteByByte: byteByByte,
        );
        cleanup.add(proxy.close);

        final tunnel = await connect(proxy);
        final received = await tunnel.expand((c) => c).toList();

        expect(utf8.decode(received), 'hello from the target');
      });
    }

    test(
      'a reply split across TCP segments still carries the response',
      () async {
        final proxy = await FakeSocks5Proxy.start(
          targetPort: target.port,
          byteByByte: true,
        );
        cleanup.add(proxy.close);

        final body = await get(
          newClient(ProxyRoute(config(ProxyType.socks5, proxy.port))),
          'http://bag-test.invalid:${target.port}/',
        );

        expect(body, '{"ok":true}');
        expect(proxy.connectHosts, ['bag-test.invalid']);
      },
    );
  });

  group('http proxy', () {
    test('absolute-form request goes through proxy with Basic auth', () async {
      final proxy = await FakeHttpProxy.start(
        username: _user,
        password: _pass,
        targetPort: target.port,
      );
      cleanup.add(proxy.close);

      final body = await get(
        newClient(
          ProxyRoute(
            config(
              ProxyType.http,
              proxy.port,
              username: _user,
              password: _pass,
            ),
          ),
        ),
        'http://bag-test.invalid:${target.port}/',
      );

      expect(body, '{"ok":true}');
      expect(
        proxy.requestLines.single,
        startsWith('GET http://bag-test.invalid'),
      );
      // Sent up front: no 407 round trip.
      expect(proxy.proxyAuthHeaders.single, basic(_user, _pass));
    });

    test(
      'https target is tunnelled with CONNECT host:443 and carries credentials',
      () async {
        final proxy = await FakeHttpProxy.start(
          username: _user,
          password: _pass,
          targetPort: target.port,
        );
        cleanup.add(proxy.close);

        // The fake answers 200 and hangs up, so the TLS handshake fails.
        await expectLater(
          get(
            newClient(
              ProxyRoute(
                config(
                  ProxyType.http,
                  proxy.port,
                  username: _user,
                  password: _pass,
                ),
              ),
            ),
            'https://bag-test.invalid/',
          ),
          throwsA(anything),
        );

        expect(
          proxy.requestLines.single,
          'CONNECT bag-test.invalid:443 HTTP/1.1',
        );
        expect(proxy.proxyAuthHeaders.single, basic(_user, _pass));
      },
    );

    test('wrong password surfaces as a 407 tunnel failure', () async {
      final proxy = await FakeHttpProxy.start(
        username: _user,
        password: 'something else',
        targetPort: target.port,
      );
      cleanup.add(proxy.close);

      await expectLater(
        get(
          newClient(
            ProxyRoute(
              config(
                ProxyType.http,
                proxy.port,
                username: _user,
                password: _pass,
              ),
            ),
          ),
          'https://bag-test.invalid/',
        ),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('(407'),
          ),
        ),
      );
    });
  });

  group('proxy host and credentials are checked before routing', () {
    // Dart's PROXY string has no escaping and falls through to the next
    // ';'-separated entry on error, which can be DIRECT.
    const hosts = [
      '::1]:1;DIRECT;PROXY [::2',
      'proxy.lan;',
      'user@proxy.lan',
      '[::1]',
      'proxy lan',
      '',
    ];

    for (final type in ProxyType.values) {
      for (final host in hosts) {
        test(
          '${type.name} refuses host "$host" and never reaches the target',
          () async {
            final route = ProxyRoute(
              ProxyConfig(
                type: type,
                host: host,
                port: 8080,
                username: 'zq-user',
                password: 'zq-secret',
              ),
            );

            Object? error;
            try {
              await get(newClient(route), 'http://127.0.0.1:${target.port}/');
            } catch (e) {
              error = e;
            }

            expect(error, isA<SocketException>());
            expect(target.hits, 0);
            expect(error.toString(), isNot(contains('zq-secret')));
            expect(error.toString(), isNot(contains('zq-user')));
            expect(
              error.toString(),
              isNot(contains(host.isEmpty ? '\u0000' : host)),
            );
          },
        );
      }
    }

    for (final (user, pass) in [
      ('zq-user', 'a;b'),
      ('a;b', 'zq-secret'),
      ('zq:user', 'zq-secret'),
      ('zq-user', ' zq-secret'),
      ('', 'zq-secret'),
    ]) {
      test('http refuses credentials the PROXY string cannot carry '
          '("$user", "$pass")', () async {
        Object? error;
        try {
          await get(
            newClient(
              ProxyRoute(
                ProxyConfig(
                  type: ProxyType.http,
                  host: 'proxy.lan',
                  port: 8080,
                  username: user,
                  password: pass,
                ),
              ),
            ),
            'http://127.0.0.1:${target.port}/',
          );
        } catch (e) {
          error = e;
        }

        expect(error, isA<SocketException>());
        expect(target.hits, 0);
        expect(error.toString(), isNot(contains('zq-secret')));
      });
    }

    for (final type in ProxyType.values) {
      for (final (user, pass) in [
        ('zq-user', null),
        (null, 'zq-secret'),
        ('', ''),
      ]) {
        test('${type.name} refuses a half or empty credential pair '
            '("$user", "$pass") without dialling the proxy', () async {
          final proxy = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          cleanup.add(proxy.close);
          var dialled = 0;
          proxy.listen((s) {
            dialled++;
            s.destroy();
          });
          Object? error;
          try {
            await get(
              newClient(
                ProxyRoute(
                  config(type, proxy.port, username: user, password: pass),
                ),
              ),
              'http://bag-test.invalid:${target.port}/',
            );
          } catch (e) {
            error = e;
          }

          expect(error, isA<SocketException>());
          expect(target.hits, 0);
          expect(dialled, 0);
        });
      }
    }

    test('an IPv6-literal HTTP proxy is reached', () async {
      final InternetAddress loopback6 = InternetAddress.loopbackIPv6;
      final FakeHttpProxy proxy;
      try {
        proxy = await FakeHttpProxy.start(
          targetPort: target.port,
          bindAddress: loopback6,
        );
      } on SocketException {
        markTestSkipped('IPv6 loopback is not available here');
        return;
      }
      cleanup.add(proxy.close);

      final body = await get(
        newClient(
          ProxyRoute(
            ProxyConfig(type: ProxyType.http, host: '::1', port: proxy.port),
          ),
        ),
        'http://bag-test.invalid:${target.port}/',
      );

      expect(body, '{"ok":true}');
      expect(proxy.requestLines.single, startsWith('GET http://bag-test'));
    });
  });

  test(
    'socks5: destroying the tunnel mid-body ends the response stream',
    () async {
      // A server that sends part of a body and never finishes.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      cleanup.add(() => server.close(force: true));
      server.listen((request) {
        request.response.bufferOutput = false;
        request.response.write('first chunk');
        request.response.flush();
      });
      final proxy = await FakeSocks5Proxy.start(targetPort: server.port);
      cleanup.add(proxy.close);
      final client = routeHttpClient(
        HttpClient(),
        ProxyRoute(config(ProxyType.socks5, proxy.port)),
      );

      final response = await (await client.getUrl(
        Uri.parse('http://bag-test.invalid:${server.port}/'),
      )).close();
      final outcome = Completer<Object?>();
      response.listen(
        (_) => client.close(force: true),
        onError: (Object e) {
          if (!outcome.isCompleted) outcome.complete(e);
        },
        onDone: () {
          if (!outcome.isCompleted) outcome.complete('done');
        },
      );

      // Same as a direct connection: the force-close surfaces as an error.
      expect(
        await outcome.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => 'HUNG: no done or error',
        ),
        isA<HttpException>(),
      );
    },
  );

  group('fail closed', () {
    for (final type in ProxyType.values) {
      test(
        'proxy down (${type.name}): request throws and target sees zero hits',
        () async {
          final dead = await deadPort();

          await expectLater(
            get(
              newClient(ProxyRoute(config(type, dead))),
              'http://127.0.0.1:${target.port}/',
            ),
            throwsA(anything),
          );

          expect(target.hits, 0);
        },
      );
    }

    test('Tor, a SOCKS5 proxy and a misconfigured route all resolve every '
        'URL to DIRECT, so an HTTP_PROXY in the environment is never used '
        '(the connection factory alone decides)', () {
      for (final route in [
        const TorRoute(),
        ProxyRoute(config(ProxyType.socks5, 1080)),
        const MisconfiguredProxyRoute(),
      ]) {
        final spy = _ProxySpy();
        routeHttpClient(spy, route);
        expect(spy.proxyFor, isNotNull, reason: '$route');
        for (final url in [
          'https://bitbag.app/api/price',
          'http://bag-test.invalid:8080/',
        ]) {
          expect(spy.proxyFor!(Uri.parse(url)), 'DIRECT', reason: '$route');
        }
        expect(spy.connectionFactorySet, isTrue, reason: '$route');
      }
    });

    test('misconfigured route refuses every connection', () async {
      await expectLater(
        get(
          newClient(const MisconfiguredProxyRoute()),
          'http://127.0.0.1:${target.port}/',
        ),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            'Proxy settings unreadable',
          ),
        ),
      );

      expect(target.hits, 0);
    });
  });

  group('.onion only over Tor or SOCKS5 (R-2)', () {
    test('direct refuses x.onion before any lookup or socket', () async {
      for (final url in ['http://abc.onion/', 'https://ABC.onion./api']) {
        await expectLater(
          get(newClient(const DirectRoute()), url),
          throwsA(isA<OnionNeedsTorException>()),
          reason: url,
        );
      }
    });

    test('direct https still verifies and decrypts through the dialler',
        () async {
      final secure = await TargetServer.startSecure(
        certPem: loopbackLeafPem,
        keyPem: loopbackLeafKey,
      );
      cleanup.add(secure.close);
      final tls = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(loopbackLeafPem));

      final body = await get(
        newClient(const DirectRoute(), tls: tls),
        'https://127.0.0.1:${secure.port}/',
      );
      expect(body, '{"ok":true}');
      expect(secure.hits, 1);

      // And an untrusted certificate is still refused.
      await expectLater(
        get(newClient(const DirectRoute()), 'https://127.0.0.1:${secure.port}/'),
        throwsA(isA<HandshakeException>()),
      );
      expect(secure.hits, 1);
    });

    test('an HTTP proxy refuses x.onion and the proxy sees nothing',
        () async {
      final proxy = await FakeHttpProxy.start(targetPort: target.port);
      cleanup.add(proxy.close);
      final client = newClient(ProxyRoute(config(ProxyType.http, proxy.port)));
      for (final url in ['http://abc.onion/', 'https://abc.onion/']) {
        await expectLater(
          get(client, url),
          throwsA(isA<OnionNeedsTorException>()),
          reason: url,
        );
      }
      expect(proxy.requestLines, isEmpty);
    });

    test('an HTTP proxy still carries other hosts, foo.onion.example.com '
        'included', () async {
      final proxy = await FakeHttpProxy.start(targetPort: target.port);
      cleanup.add(proxy.close);
      final client = newClient(ProxyRoute(config(ProxyType.http, proxy.port)));
      expect(
        await get(client, 'http://foo.onion.example.com:${target.port}/'),
        '{"ok":true}',
      );
      await expectLater(
        get(client, 'https://bitbag.example/'),
        throwsA(anything), // the fake answers CONNECT and hangs up
      );
      expect(proxy.requestLines, [
        'GET http://foo.onion.example.com:${target.port}/ HTTP/1.1',
        'CONNECT bitbag.example:443 HTTP/1.1',
      ]);
    });

    test('a SOCKS5 proxy carries x.onion as a hostname', () async {
      final proxy = await FakeSocks5Proxy.start(targetPort: target.port);
      cleanup.add(proxy.close);
      final body = await get(
        newClient(ProxyRoute(config(ProxyType.socks5, proxy.port))),
        'http://abc.onion:${target.port}/',
      );
      expect(body, '{"ok":true}');
      expect(proxy.connectHosts, ['abc.onion']);
    });

    test('Tor is not refused for x.onion (it fails only while Tor is not '
        'connected)', () async {
      await expectLater(
        get(newClient(const TorRoute()), 'http://abc.onion/'),
        throwsA(
          isA<SocketException>()
              .having((e) => e, 'type', isNot(isA<OnionNeedsTorException>()))
              .having((e) => e.message, 'message', 'Tor is not connected'),
        ),
      );
    });

    test('buildRoutedDio surfaces the refusal as a connection error', () async {
      final dio = buildRoutedJsonDio(const DirectRoute());
      cleanup.add(() async => dio.close(force: true));
      await expectLater(
        dio.get<Object?>('http://abc.onion/address/x'),
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.connectionError)
            .having((e) => e.error, 'error', isA<OnionNeedsTorException>())),
      );
    });
  });

  group('buildRoutedDio', () {
    test(
      'uses 60 s for private routes and clearnetTimeout for DirectRoute',
      () {
        const clearnet = Duration(seconds: 15);
        final proxy = ProxyRoute(config(ProxyType.socks5, 1080));

        for (final route in <NetworkRoute>[
          const TorRoute(),
          proxy,
          const MisconfiguredProxyRoute(),
        ]) {
          final dio = buildRoutedDio(route: route, clearnetTimeout: clearnet);
          expect(
            dio.options.connectTimeout,
            privateRouteTimeout,
            reason: '$route',
          );
          expect(
            dio.options.receiveTimeout,
            privateRouteTimeout,
            reason: '$route',
          );
        }

        final direct = buildRoutedDio(
          route: const DirectRoute(),
          clearnetTimeout: clearnet,
          baseUrl: 'https://example.test',
          headers: {'Accept': 'application/json'},
        );
        expect(direct.options.connectTimeout, clearnet);
        expect(direct.options.receiveTimeout, clearnet);
        expect(direct.options.baseUrl, 'https://example.test');
        expect(direct.options.headers['Accept'], 'application/json');
        expect(direct.httpClientAdapter, isA<IOHttpClientAdapter>());
      },
    );

    test(
      'a proxied Dio request reaches the target through the proxy',
      () async {
        final proxy = await FakeSocks5Proxy.start(targetPort: target.port);
        cleanup.add(proxy.close);
        final dio = buildRoutedDio(
          route: ProxyRoute(config(ProxyType.socks5, proxy.port)),
          clearnetTimeout: const Duration(seconds: 5),
          baseUrl: 'http://bag-test.invalid:${target.port}',
        );
        cleanup.add(() async => dio.close(force: true));

        final response = await dio.get<Map<String, dynamic>>('/');

        expect(response.data, {'ok': true});
        expect(proxy.connectHosts, ['bag-test.invalid']);
      },
    );

    group('redirects are never followed (R-5)', () {
      // Answers every request with a redirect to [location].
      Future<HttpServer> redirector(String location) async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        cleanup.add(() => server.close(force: true));
        server.listen((request) {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, location);
          request.response.close();
        });
        return server;
      }

      test('on every route, by option', () {
        for (final route in <NetworkRoute>[
          const DirectRoute(),
          const TorRoute(),
          ProxyRoute(config(ProxyType.socks5, 1080)),
          ProxyRoute(config(ProxyType.http, 3128)),
          const MisconfiguredProxyRoute(),
        ]) {
          final dio = buildRoutedDio(
            route: route,
            clearnetTimeout: const Duration(seconds: 5),
          );
          expect(dio.options.followRedirects, isFalse, reason: '$route');
          expect(buildRoutedJsonDio(route).options.followRedirects, isFalse,
              reason: '$route');
        }
      });

      test('a 302 to another origin fails and the target sees nothing',
          () async {
        final server = await redirector(
            'http://127.0.0.1:${target.port}/admin/reboot?x=1');
        final dio = buildRoutedJsonDio(const DirectRoute());
        cleanup.add(() async => dio.close(force: true));

        await expectLater(
          dio.get<Object?>('http://127.0.0.1:${server.port}/price'),
          throwsA(isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            HttpStatus.found,
          )),
        );
        expect(target.hits, 0);
      });

      test('a 302 through a SOCKS5 proxy is not followed either', () async {
        final server = await redirector(
            'http://127.0.0.1:${target.port}/admin');
        final proxy = await FakeSocks5Proxy.start(targetPort: server.port);
        cleanup.add(proxy.close);
        final dio = buildRoutedJsonDio(
          ProxyRoute(config(ProxyType.socks5, proxy.port)),
        );
        cleanup.add(() async => dio.close(force: true));

        await expectLater(
          dio.get<Object?>('http://bag-test.invalid:${server.port}/'),
          throwsA(isA<DioException>()),
        );
        expect(target.hits, 0);
        expect(proxy.connectHosts, ['bag-test.invalid']);
      });
    });
  });
}

/// Records what [routeHttpClient] sets on a client.
class _ProxySpy extends Fake implements HttpClient {
  String Function(Uri url)? proxyFor;
  bool connectionFactorySet = false;

  @override
  set findProxy(String Function(Uri url)? f) => proxyFor = f;

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )?
    f,
  ) => connectionFactorySet = f != null;
}
