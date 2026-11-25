// Fees come from the selected explorer, and the mempool.space preset uses
// mempool's onion over Tor: mempool.space refuses Tor exits, so over Tor
// both its fee endpoint and its Esplora API were unreachable (rc3 device
// test, 2026-11-24).

import 'dart:convert';
import 'dart:typed_data';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/network_settings.dart';
import 'package:bag/services/fee_service.dart';
import 'package:bag/services/wallet/wallet_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  final requested = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requested.add(options.uri.toString());
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

(Dio, _FakeAdapter) _dio(ResponseBody Function(RequestOptions) respond) {
  final adapter = _FakeAdapter(respond);
  final dio = Dio()..httpClientAdapter = adapter;
  return (dio, adapter);
}

void main() {
  group('explorerBaseUrl', () {
    test('mempool.space preset uses the onion over Tor only', () {
      expect(
        explorerBaseUrl(ExplorerPreset.mempool, '', const TorRoute()),
        AppConstants.explorerMempoolOnion,
      );
      expect(
        explorerBaseUrl(ExplorerPreset.mempool, '', const DirectRoute()),
        AppConstants.explorerMempool,
      );
    });

    test('other presets and custom URLs are unchanged over Tor', () {
      expect(
        explorerBaseUrl(ExplorerPreset.blockstream, '', const TorRoute()),
        AppConstants.explorerBlockstream,
      );
      expect(
        explorerBaseUrl(
            ExplorerPreset.custom, 'https://node.local/api', const TorRoute()),
        'https://node.local/api',
      );
      expect(
        explorerBaseUrl(ExplorerPreset.custom, '', const TorRoute()),
        AppConstants.explorerBlockstream,
      );
    });

    test('NetworkSettings.effectiveBaseUrl follows its own route', () {
      const s = NetworkSettings(preset: ExplorerPreset.mempool, useTor: true);
      expect(s.effectiveBaseUrl, AppConstants.explorerMempoolOnion);
      expect(s.copyWith(useTor: false).effectiveBaseUrl,
          AppConstants.explorerMempool);
    });

    test('background isolates resolve the same URL for their route', () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues(
          {AppConstants.keyExplorerPreset: ExplorerPreset.mempool.index});
      expect(await resolveExplorerBaseUrl(const TorRoute()),
          AppConstants.explorerMempoolOnion);
      expect(await resolveExplorerBaseUrl(const DirectRoute()),
          AppConstants.explorerMempool);
    });

    test('the onion is a well-formed .onion URL', () {
      final uri = Uri.parse(AppConstants.explorerMempoolOnion);
      expect(uri.scheme, 'http');
      expect(uri.host, endsWith('.onion'));
      expect(uri.host.length, 56 + '.onion'.length);
      expect(uri.path, '/api');
    });
  });

  group('fetchFeeEstimate', () {
    test('a mempool backend answers /v1/fees/recommended', () async {
      final (dio, adapter) = _dio((o) => _json(
          {'fastestFee': 12, 'halfHourFee': 8, 'hourFee': 5}));
      final fee =
          await fetchFeeEstimate(dio, explorerBase: 'https://node.local/api');
      expect((fee!.fast, fee.standard, fee.slow), (12.0, 8.0, 5.0));
      expect(adapter.requested,
          ['https://node.local/api/v1/fees/recommended']);
    });

    test('a plain Esplora falls back to /fee-estimates', () async {
      final (dio, adapter) = _dio((o) => o.path.endsWith('/fee-estimates')
          ? _json({'1': 1.194, '3': 1.11, '6': 0.13, '144': 0.12})
          : ResponseBody.fromString('Not found', 404));
      final fee =
          await fetchFeeEstimate(dio, explorerBase: 'https://node.local/api/');
      expect((fee!.fast, fee.standard, fee.slow), (1.194, 1.11, 0.13));
      expect(adapter.requested, [
        'https://node.local/api/v1/fees/recommended',
        'https://node.local/api/fee-estimates',
      ]);
    });

    test('blockstream.info goes straight to /fee-estimates', () async {
      final (dio, adapter) =
          _dio((o) => _json({'1': 3.0, '3': 2.0, '6': 1.0}));
      final fee = await fetchFeeEstimate(dio,
          explorerBase: AppConstants.explorerBlockstream);
      expect((fee!.fast, fee.standard, fee.slow), (3.0, 2.0, 1.0));
      expect(adapter.requested,
          ['${AppConstants.explorerBlockstream}/fee-estimates']);
    });

    test('a missing target uses the next larger one', () async {
      final (dio, _) = _dio((o) => o.path.endsWith('/fee-estimates')
          ? _json({'2': 4.0, '4': 3.0, '10': 1.5})
          : ResponseBody.fromString('Not found', 404));
      final fee =
          await fetchFeeEstimate(dio, explorerBase: 'https://node.local/api');
      expect((fee!.fast, fee.standard, fee.slow), (4.0, 3.0, 1.5));
    });

    test('a connection failure is not retried on the other endpoint',
        () async {
      final adapter = _FakeAdapter((o) => throw DioException.connectionError(
            requestOptions: o,
            reason: 'refused',
          ));
      final dio = Dio()..httpClientAdapter = adapter;
      final fee =
          await fetchFeeEstimate(dio, explorerBase: 'https://node.local/api');
      expect(fee, isNull);
      expect(adapter.requested, hasLength(1));
    });

    test('nothing usable from either endpoint gives null', () async {
      final (dio, adapter) = _dio((o) => _json({'unexpected': true}));
      final fee =
          await fetchFeeEstimate(dio, explorerBase: 'https://node.local/api');
      expect(fee, isNull);
      expect(adapter.requested, hasLength(2));
    });
  });

  group('fetchFeeEstimate (audit fixes)', () {
    test('a custom base saved without /api is also tried under /api',
        () async {
      final (dio, adapter) = _dio((o) => o.uri.path == '/api/v1/fees/recommended'
          ? _json({'fastestFee': 9, 'halfHourFee': 6, 'hourFee': 3})
          : ResponseBody.fromString('<html>app</html>', 200));
      final fee =
          await fetchFeeEstimate(dio, explorerBase: 'http://umbrel.local');
      expect(fee!.fast, 9.0);
      expect(adapter.requested, [
        'http://umbrel.local/v1/fees/recommended',
        'http://umbrel.local/fee-estimates',
        'http://umbrel.local/api/v1/fees/recommended',
      ]);
    });

    for (final (name, body) in [
      ('negative', '{"fastestFee":-1,"halfHourFee":1,"hourFee":1}'),
      ('infinite', '{"fastestFee":1e999,"halfHourFee":1,"hourFee":1}'),
      ('absurd', '{"fastestFee":5000000,"halfHourFee":1,"hourFee":1}'),
      ('negative Esplora', '{"1":-5,"3":-1,"6":-1}'),
    ]) {
      test('a $name rate is not an estimate', () async {
        final (dio, _) = _dio((o) => ResponseBody.fromString(body, 200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            }));
        expect(
            await fetchFeeEstimate(dio,
                explorerBase: AppConstants.explorerMempoolOnion),
            isNull);
      });
    }
  });

  group('formatFeeRate', () {
    test('whole numbers above 10, one decimal below, no trailing .0', () {
      expect(formatFeeRate(25), '25');
      expect(formatFeeRate(12.6), '13');
      expect(formatFeeRate(1.194), '1.2');
      expect(formatFeeRate(1.0), '1');
      expect(formatFeeRate(0.13), '0.1');
    });
  });
}
