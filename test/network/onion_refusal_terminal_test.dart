/// net R-1: a `.onion` explorer on a route that can't reach one is refused
/// locally by the routing layer ([OnionNeedsTorException]). That refusal is
/// final: [EsploraClient] never retries it, so a request on a private route
/// fails at once instead of sitting out the 5/10/20/30 s back-off (about
/// 65 s per request). The foreground pre-checks the explorer, but Sentinel
/// and the background widget job reach the client directly, so the client
/// itself must stop.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bag/models/network_route.dart';
import 'package:bag/models/wallet_entry.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/services/wallet/esplora_client.dart';
import 'package:bag/services/wallet/wallet_scanner.dart';
import 'package:bag/services/wallet/wallet_store.dart';

import 'fake_proxies.dart';

const _zpub =
    'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The binding answers every HTTP request with a canned 400; the refusal
  // under test happens in the real HttpClient's connection factory.
  HttpOverrides.global = null;

  late FakeHttpProxy proxy;
  late EsploraClient client;
  late Duration previousUnit;

  setUp(() async {
    // One retry would wait 5 minutes: a refusal that is retried at all
    // times out below instead of passing.
    previousUnit = EsploraClient.debugRetryDelayUnit;
    EsploraClient.debugRetryDelayUnit = const Duration(minutes: 1);
    proxy = await FakeHttpProxy.start(targetPort: 1);
    client = EsploraClient(
      baseUrl: 'http://abcdefghijklmnop.onion/api',
      route: ProxyRoute(
        ProxyConfig(type: ProxyType.http, host: '127.0.0.1', port: proxy.port),
      ),
    );
  });

  tearDown(() async {
    client.close();
    await proxy.close();
    EsploraClient.debugRetryDelayUnit = previousUnit;
  });

  final refused = throwsA(
    isA<EsploraException>().having(
      (e) => e.message,
      'message',
      onionNeedsTorMessage,
    ),
  );

  test('the client is on a private route, so it would retry a transient '
      'error', () {
    expect(client.isPrivateRoute, isTrue);
  });

  for (final (name, call)
      in <(String, Future<Object?> Function(EsploraClient))>[
        ('fetchAddress', (c) => c.fetchAddress('bc1qexample')),
        ('fetchUtxos', (c) => c.fetchUtxos('bc1qexample')),
        ('fetchTransaction', (c) => c.fetchTransaction('aa' * 32)),
        ('fetchMempoolTxs', (c) => c.fetchMempoolTxs('bc1qexample')),
      ]) {
    test(
      '$name fails at once, with no retry, and the proxy sees nothing',
      () async {
        await expectLater(
          call(client).timeout(const Duration(seconds: 5)),
          refused,
        );
        expect(proxy.requestLines, isEmpty);
      },
    );
  }

  test('a background-style wallet scan (Sentinel, the widget job) fails at '
      'once too', () async {
    await expectLater(
      scanWallet(
        buildAddressSource(WalletKind.zpub, _zpub),
        client,
      ).timeout(const Duration(seconds: 5)),
      refused,
    );
    expect(proxy.requestLines, isEmpty);
  });
}
