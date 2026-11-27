/// What the iOS Sentinel run needs from the explorer client: the per-address
/// transaction counts (one `GET /address/:addr` says whether anything new
/// happened), the newest confirmed transactions of an address, and a
/// single-attempt mode, because the 5-attempt Tor retry ladder (about 65 s of
/// back-off per request) can't fit iOS's 25 s background budget.
///
/// Answers come from a real loopback server over a Direct route, and the
/// requests of the Tor cases are counted by a recording interceptor while the
/// real routed adapter refuses them (no Tor client runs in a test), so no
/// test replaces the client's adapter.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bag/models/network_route.dart';
import 'package:bag/services/wallet/esplora_client.dart';

/// A loopback explorer: answers each path from [answers] as JSON, 404 for
/// any other, and records every path it was asked for.
class _Explorer {
  _Explorer._(this._server, this.answers) {
    _server.listen((request) {
      paths.add(request.uri.path);
      final answer = answers[request.uri.path];
      request.response
        ..statusCode = answer == null ? HttpStatus.notFound : HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(answer ?? {}));
      request.response.close();
    });
  }

  final HttpServer _server;
  final Map<String, Object?> answers;
  final paths = <String>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}/api';

  static Future<_Explorer> start(Map<String, Object?> answers) async {
    final explorer = _Explorer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      answers,
    );
    addTearDown(() => explorer._server.close(force: true));
    return explorer;
  }
}

/// Counts the requests a client's Dio sends, each attempt of a retry too.
class _Recorder extends Interceptor {
  int requests = 0;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests++;
    handler.next(options);
  }
}

void main() {
  late Duration previousUnit;
  late _Recorder recorder;

  setUp(() {
    // The test binding answers every HTTP request with a canned 400; these
    // talk to a real loopback server or are refused by the route itself.
    HttpOverrides.global = null;
    previousUnit = EsploraClient.debugRetryDelayUnit;
    EsploraClient.debugRetryDelayUnit = Duration.zero;
    recorder = _Recorder();
    EsploraClient.debugInterceptDio = (interceptors, _) =>
        interceptors.add(recorder);
  });

  tearDown(() {
    EsploraClient.debugRetryDelayUnit = previousUnit;
    EsploraClient.debugInterceptDio = null;
  });

  EsploraClient client(
    String baseUrl, {
    NetworkRoute route = const DirectRoute(),
    bool singleAttempt = false,
  }) {
    final c = EsploraClient(
      baseUrl: baseUrl,
      route: route,
      singleAttempt: singleAttempt,
    );
    addTearDown(c.close);
    return c;
  }

  group('address stats', () {
    test('address stats carry both tx counts', () async {
      final explorer = await _Explorer.start({
        '/api/address/bc1qwatched': {
          'chain_stats': {
            'tx_count': 7,
            'funded_txo_sum': 5000,
            'spent_txo_sum': 1000,
          },
          'mempool_stats': {
            'tx_count': 1,
            'funded_txo_sum': 200,
            'spent_txo_sum': 0,
          },
        },
      });

      final stats = await client(explorer.baseUrl).fetchAddress('bc1qwatched');

      expect(stats.chainTxCount, 7);
      expect(stats.mempoolTxCount, 1);
      // The existing fields are unchanged.
      expect(stats.hasTransactions, isTrue);
      expect(stats.balanceSats, 4200);
    });

    test('stats without a tx_count read as 0 and 0', () async {
      final explorer = await _Explorer.start({
        '/api/address/bc1qfresh': {'chain_stats': {}, 'mempool_stats': {}},
      });

      final stats = await client(explorer.baseUrl).fetchAddress('bc1qfresh');

      expect(stats.chainTxCount, 0);
      expect(stats.mempoolTxCount, 0);
      expect(stats.hasTransactions, isFalse);
      expect(stats.balanceSats, 0);
    });

    test('a body with no stats at all is still refused, not read as an '
        'unused address', () async {
      // A silently-empty answer would end a gap-limit scan early and report
      // a wrong balance, so the existing strictness stays.
      final explorer = await _Explorer.start({'/api/address/bc1qodd': {}});

      await expectLater(
        client(explorer.baseUrl).fetchAddress('bc1qodd'),
        throwsA(
          isA<EsploraException>().having(
            (e) => e.message,
            'message',
            'Unexpected response format',
          ),
        ),
      );
    });
  });

  group('recent chain txs', () {
    const tx = {
      'txid': 'aa11',
      'vin': [
        {
          'prevout': {'scriptpubkey_address': 'bc1qsender', 'value': 70000},
        },
      ],
      'vout': [
        {'scriptpubkey_address': 'bc1qmine', 'value': 50000},
        {'scriptpubkey_address': 'bc1qchange', 'value': 19000},
      ],
    };

    test('recent chain txs parse like mempool txs', () async {
      final explorer = await _Explorer.start({
        '/api/address/bc1qmine/txs/chain': [tx],
        '/api/address/bc1qmine/txs/mempool': [tx],
      });
      final c = client(explorer.baseUrl);

      final chain = await c.fetchRecentChainTxs('bc1qmine');
      final mempool = await c.fetchMempoolTxs('bc1qmine');

      expect(explorer.paths, [
        '/api/address/bc1qmine/txs/chain',
        '/api/address/bc1qmine/txs/mempool',
      ]);
      expect(chain, hasLength(1));
      expect(chain.single.txid, 'aa11');
      expect(chain.single.inputs, [(address: 'bc1qsender', sats: 70000)]);
      expect(chain.single.outputs, [
        (address: 'bc1qmine', sats: 50000),
        (address: 'bc1qchange', sats: 19000),
      ]);
      expect(chain.single.inputs, mempool.single.inputs);
      expect(chain.single.outputs, mempool.single.outputs);
    });

    test('an empty answer is an empty list', () async {
      final explorer = await _Explorer.start({
        '/api/address/bc1qquiet/txs/chain': <Object?>[],
      });

      expect(
        await client(explorer.baseUrl).fetchRecentChainTxs('bc1qquiet'),
        isEmpty,
      );
    });

    test('a malformed answer is an EsploraException', () async {
      final explorer = await _Explorer.start({
        '/api/address/bc1qodd/txs/chain': [42],
      });

      await expectLater(
        client(explorer.baseUrl).fetchRecentChainTxs('bc1qodd'),
        throwsA(isA<EsploraException>()),
      );
    });
  });

  group('single attempt', () {
    // No Tor client runs in a test, so every connection over TorRoute is
    // refused by the real routed adapter ("Tor is not connected"), a
    // transient error the retry ladder would retry.
    const explorer = 'http://explorer.example/api';

    test('single attempt never retries over Tor', () async {
      final c = client(explorer, route: const TorRoute(), singleAttempt: true);

      await expectLater(
        c.fetchAddress('bc1qwatched'),
        throwsA(isA<EsploraException>()),
      );
      expect(recorder.requests, 1);
    });

    test('single attempt holds for every call', () async {
      final c = client(explorer, route: const TorRoute(), singleAttempt: true);

      await expectLater(
        c.fetchMempoolTxs('bc1q'),
        throwsA(isA<EsploraException>()),
      );
      await expectLater(
        c.fetchRecentChainTxs('bc1q'),
        throwsA(isA<EsploraException>()),
      );
      expect(recorder.requests, 2);
    });

    test('without the flag Tor still retries, 5 requests in all', () async {
      final c = client(explorer, route: const TorRoute());

      await expectLater(
        c.fetchAddress('bc1qwatched'),
        throwsA(isA<EsploraException>()),
      );
      expect(recorder.requests, 5);
    });

    test('a clearnet client makes one attempt either way', () async {
      // A loopback port nothing listens on: the connection is refused.
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${closed.port}/api';
      await closed.close(force: true);

      for (final single in [false, true]) {
        recorder.requests = 0;
        await expectLater(
          client(base, singleAttempt: single).fetchAddress('bc1qwatched'),
          throwsA(isA<EsploraException>()),
        );
        expect(recorder.requests, 1, reason: 'singleAttempt: $single');
      }
    });
  });
}
