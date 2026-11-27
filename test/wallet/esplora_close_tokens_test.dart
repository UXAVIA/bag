/// `EsploraClient.close()` aborts requests at any stage, without leaking
/// (R21): each request carries its own cancel token, held only while the
/// request runs, so a client that lives for days (Android Sentinel's cached
/// client, the foreground `esploraClientProvider` client) keeps nothing of a
/// finished request; `close()` cancels the tokens still held, which aborts a
/// request even while it sits in the Dio's interceptors.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bag/models/network_route.dart';
import 'package:bag/services/network/routed_http.dart';
import 'package:bag/services/wallet/esplora_client.dart';

Map<String, dynamic> _stats() => {
  'chain_stats': {'tx_count': 1, 'funded_txo_sum': 0, 'spent_txo_sum': 0},
  'mempool_stats': {'tx_count': 0, 'funded_txo_sum': 0, 'spent_txo_sum': 0},
};

void main() {
  /// A path here waits for its completer; one in [failing] fails.
  final holds = <String, Completer<void>>{};
  final failing = <String>{};

  setUp(() {
    holds.clear();
    failing.clear();
    EsploraClient.debugInterceptDio = (interceptors, _) => interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          await holds[options.uri.path]?.future;
          if (failing.contains(options.uri.path)) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: options, statusCode: 500),
              ),
            );
            return;
          }
          final body = options.uri.path.endsWith('/txs/mempool')
              ? <dynamic>[]
              : _stats();
          handler.resolve(
            Response(requestOptions: options, data: body, statusCode: 200),
          );
        },
      ),
    );
  });

  tearDown(() {
    for (final h in holds.values) {
      if (!h.isCompleted) h.complete();
    }
    EsploraClient.debugInterceptDio = null;
  });

  EsploraClient client() => EsploraClient(
    baseUrl: 'https://esplora.test/api',
    route: const DirectRoute(),
  );

  test('finished requests leave no token behind, answered or failed', () async {
    final c = client();
    addTearDown(c.close);
    failing.add('/api/address/bad');

    for (var i = 0; i < 50; i++) {
      await c.fetchAddress('addr$i');
      await c.fetchMempoolTxs('addr$i');
    }
    for (var i = 0; i < 5; i++) {
      await expectLater(
        c.fetchAddress('bad'),
        throwsA(isA<EsploraException>()),
      );
    }

    expect(c.debugLiveCancelTokens, 0);
  });

  test('a request in flight holds one token until it ends', () async {
    final c = client();
    addTearDown(c.close);
    holds['/api/address/slow'] = Completer<void>();

    final pending = c.fetchAddress('slow');
    await pumpEventQueue();
    expect(c.debugLiveCancelTokens, 1);

    holds['/api/address/slow']!.complete();
    await pending;
    expect(c.debugLiveCancelTokens, 0);
  });

  test('close() aborts a request held in an interceptor: it ends as '
      'RouteChangedException, and so does every later call', () async {
    final c = client();
    holds['/api/address/held'] = Completer<void>(); // never released here

    final pending = c.fetchAddress('held');
    await pumpEventQueue();
    c.close();

    await expectLater(
      pending.timeout(const Duration(seconds: 2)),
      throwsA(isA<RouteChangedException>()),
    );
    expect(c.debugLiveCancelTokens, 0);
    await expectLater(
      c.fetchAddress('later'),
      throwsA(isA<RouteChangedException>()),
    );
    expect(c.debugLiveCancelTokens, 0);
  });
}
