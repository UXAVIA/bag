// Esplora API client for address balance and transaction lookups.
//
// Security design:
// - Only address hashes are sent — the zpub is NEVER transmitted.
// - No authentication headers, no cookies, no identifying info.
// - Addresses are not logged.
// - When useTor is true, all requests are routed through the local Orbot
//   SOCKS5 proxy (127.0.0.1:9050). The caller must verify Tor is available
//   before constructing a Tor-enabled client.
//
// Reliability over Tor:
// - Timeouts are raised to 60 s (vs 20 s clearnet) — Tor circuit
//   establishment alone can take 10–20 s.
// - Transient failures (timeout, connection reset) are retried up to 4 times
//   with exponential back-off (5 s / 10 s / 20 s / 30 s). Tor circuits rotate
//   every ~10 min; a rotation causes a connection reset and the new circuit
//   typically takes 5–30 s to warm up — flat 3 s was often too short.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:socks5_proxy/socks.dart';

import '../tor_service.dart';

import '../../core/constants/app_constants.dart';
import '../../models/chain_analysis.dart';

/// Thrown when the Esplora API returns an unexpected response or times out
/// after all retries are exhausted.
final class EsploraException implements Exception {
  final String message;

  /// Raw response body from the server, if available. Used to detect
  /// HTML routing errors (e.g. Express "Cannot GET /path") vs real 404s.
  final Object? responseBody;

  const EsploraException(this.message, {this.responseBody});

  @override
  String toString() => 'EsploraException: $message';
}

/// Summary stats for a single address.
final class AddressStats {
  /// True if this address has ever received any transactions.
  final bool hasTransactions;

  /// Confirmed + unconfirmed received minus spent, in satoshis.
  final int balanceSats;

  const AddressStats({required this.hasTransactions, required this.balanceSats});
}

/// An unconfirmed transaction touching a watched address in the mempool.
final class MempoolTx {
  final String txid;

  /// Inputs being spent: address + value in sats (vin[].prevout).
  /// An address from our wallet here means one of our UTXOs is being spent.
  final List<({String? address, int sats})> inputs;

  /// Outputs: address + value in sats (vout[]).
  final List<({String? address, int sats})> outputs;

  const MempoolTx({
    required this.txid,
    required this.inputs,
    required this.outputs,
  });
}

/// DioException types that are transient and safe to retry.
/// These cover timeout and connection-reset scenarios — notably Tor circuit
/// rotation, which drops the in-flight connection and requires a new circuit.
bool _isRetryable(DioException e) => switch (e.type) {
      DioExceptionType.connectionTimeout => true,
      DioExceptionType.sendTimeout => true,
      DioExceptionType.receiveTimeout => true,
      DioExceptionType.connectionError => true,
      // unknown often means a socket reset on Tor circuit rotation
      DioExceptionType.unknown => true,
      _ => false,
    };

class EsploraClient {
  final String baseUrl;
  final bool useTor;
  final Dio _dio;

  /// Strips a trailing /api or /api/vN suffix so we can fall back to the
  /// root-level Esplora path when a sub-path doesn't serve all endpoints.
  String get _rootBaseUrl =>
      baseUrl.replaceAll(RegExp(r'/api(/v\d+)?$'), '');

  // Over Tor, retry up to 5 attempts total (4 retries). Clearnet gets 1.
  int get _maxAttempts => useTor ? 5 : 1;

  EsploraClient({
    required this.baseUrl,
    this.useTor = false,
  }) : _dio = _buildDio(useTor);

  static Dio _buildDio(bool useTor) {
    // Tor circuits take significantly longer to establish than clearnet TCP.
    // 60 s gives Tor enough headroom for slow guard nodes and circuit builds.
    final timeout = useTor
        ? const Duration(seconds: 60)
        : const Duration(seconds: 20);

    final dio = Dio(BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
      // No identifying headers — just accept JSON.
      headers: {'Accept': 'application/json'},
    ));

    if (useTor && TorService.needsSocks5) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          SocksTCPClient.assignToHttpClient(client, [
            ProxySettings(
              InternetAddress(AppConstants.torHost),
              AppConstants.torPort,
            ),
          ]);
          return client;
        },
      );
    }

    return dio;
  }

  // ── Retry wrapper ─────────────────────────────────────────────────────────

  // Exponential back-off delays for Tor retries (attempt index → seconds).
  // Tor circuit establishment after a rotation typically takes 5–30 s.
  // Flat 3 s was often too short; exponential gives the new circuit
  // time to warm up without hanging indefinitely on later attempts.
  static const _torBackoffSeconds = [5, 10, 20, 30];

  /// Calls [fn] up to [_maxAttempts] times, retrying on transient Dio errors.
  /// Uses exponential back-off so a new Tor circuit has time to warm up.
  Future<T> _withRetry<T>(Future<T> Function() fn, String context) async {
    DioException? lastDioError;

    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      if (attempt > 0) {
        final delaySecs = _torBackoffSeconds[
            (attempt - 1).clamp(0, _torBackoffSeconds.length - 1)];
        if (kDebugMode) {
          debugPrint(
              '[Esplora] Tor retry $attempt/${_maxAttempts - 1} ($context) — waiting ${delaySecs}s');
        }
        await Future.delayed(Duration(seconds: delaySecs));
      }
      try {
        return await fn();
      } on DioException catch (e) {
        if (!_isRetryable(e) || attempt == _maxAttempts - 1) {
          final detail = e.type == DioExceptionType.badResponse
              ? 'HTTP ${e.response?.statusCode ?? '?'}'
              : e.type.name;
          throw EsploraException(
            'Network error: $detail',
            responseBody: e.response?.data,
          );
        }
        lastDioError = e;
      }
    }

    // Unreachable, but satisfies the type system.
    throw EsploraException('Network error: ${lastDioError?.type.name ?? 'unknown'}');
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// Returns [AddressStats] for a single bech32 address.
  /// Throws [EsploraException] on network error or unexpected response.
  Future<AddressStats> fetchAddress(String address) async {
    try {
      final response = await _withRetry(
        () => _dio.get<Map<String, dynamic>>('$baseUrl/address/$address'),
        'address',
      );

      final data = response.data!;
      final chainStats = data['chain_stats'] as Map<String, dynamic>;
      final mempoolStats = data['mempool_stats'] as Map<String, dynamic>;

      final txCount = (chainStats['tx_count'] as int? ?? 0) +
          (mempoolStats['tx_count'] as int? ?? 0);
      final funded = (chainStats['funded_txo_sum'] as int? ?? 0) +
          (mempoolStats['funded_txo_sum'] as int? ?? 0);
      final spent = (chainStats['spent_txo_sum'] as int? ?? 0) +
          (mempoolStats['spent_txo_sum'] as int? ?? 0);

      return AddressStats(
        hasTransactions: txCount > 0,
        balanceSats: funded - spent,
      );
    } on EsploraException {
      rethrow;
    } on TypeError catch (_) {
      throw const EsploraException('Unexpected response format');
    }
  }

  /// Returns all unspent outputs for [address].
  /// Returns an empty list if the address has no UTXOs.
  /// Throws [EsploraException] on network error or unexpected response.
  Future<List<RawUtxo>> fetchUtxos(String address) async {
    try {
      final url = '$baseUrl/address/$address/utxo';
      if (kDebugMode) debugPrint('[Esplora] fetchUtxos GET (address redacted)');
      final response = await _withRetry(
        () => _dio.get<List<dynamic>>(url),
        'utxo',
      );
      if (kDebugMode) {
        debugPrint('[Esplora] fetchUtxos ${response.statusCode} '
            'data=${response.data.runtimeType} len=${response.data?.length}');
      }
      return _parseUtxoList(response.data);
    } on EsploraException catch (e) {
      if (e.message.contains('HTTP 404')) {
        // Inspect the response body: Express/Node servers that don't have
        // the route configured return an HTML page like
        // "Cannot GET /api/v1/address/.../utxo" with a 404 status.
        // This is a misconfigured local mempool — tell the user rather than
        // silently returning an empty UTXO set.
        final body = e.responseBody?.toString() ?? '';
        if (body.contains('Cannot GET') ||
            body.trimLeft().startsWith('<!') ||
            body.trimLeft().startsWith('<html')) {
          throw const EsploraException(
            'Custom explorer doesn\'t support UTXO lookups '
            '(server returned an HTML error page). '
            'Switch to Blockstream or mempool.space for health checks.',
          );
        }

        // Plain 404 — either the address has no UTXOs, or the /api prefix
        // doesn't serve this endpoint. Try root as a one-shot fallback.
        final root = _rootBaseUrl;
        if (root != baseUrl) {
          final rootUrl = '$root/address/$address/utxo';
          if (kDebugMode) debugPrint('[Esplora] fetchUtxos 404 on primary, trying root fallback');
          try {
            final fallback = await _dio.get<dynamic>(rootUrl);
            if (kDebugMode) {
              debugPrint('[Esplora] fetchUtxos root ${fallback.statusCode} '
                  'data=${fallback.data.runtimeType}');
            }
            if (fallback.data is List) {
              return _parseUtxoList(fallback.data);
            }
          } catch (fe) {
            if (kDebugMode) debugPrint('[Esplora] fetchUtxos root fallback failed: $fe');
          }
        }
        return [];
      }
      rethrow;
    } on TypeError catch (_) {
      throw const EsploraException('Unexpected UTXO response format');
    }
  }

  List<RawUtxo> _parseUtxoList(List<dynamic>? data) {
    return (data ?? []).map((e) {
      final m = e as Map<String, dynamic>;
      final status = m['status'] as Map<String, dynamic>?;
      final confirmed = status?['confirmed'] as bool? ?? false;
      return RawUtxo(
        txid: m['txid'] as String,
        vout: m['vout'] as int,
        valueSats: m['value'] as int,
        blockHeight: confirmed ? (status?['block_height'] as int?) : null,
      );
    }).toList();
  }

  /// Returns the transaction identified by [txid], with input count and outputs.
  /// Throws [EsploraException] on network error or unexpected response.
  Future<RawTransaction> fetchTransaction(String txid) async {
    try {
      final response = await _withRetry(
        () => _dio.get<Map<String, dynamic>>('$baseUrl/tx/$txid'),
        'tx',
      );
      final data = response.data!;
      final vin = data['vin'] as List<dynamic>;
      final vout = data['vout'] as List<dynamic>;
      final status = data['status'] as Map<String, dynamic>?;
      final confirmed = status?['confirmed'] as bool? ?? false;

      return RawTransaction(
        txid: txid,
        inputCount: vin.length,
        outputs: vout.map((e) {
          final o = e as Map<String, dynamic>;
          return RawTxOutput(
            address: o['scriptpubkey_address'] as String?,
            valueSats: o['value'] as int,
            scriptpubkeyType: o['scriptpubkey_type'] as String? ?? '',
          );
        }).toList(),
        blockHeight: confirmed ? (status?['block_height'] as int?) : null,
      );
    } on EsploraException {
      rethrow;
    } on TypeError catch (_) {
      throw const EsploraException('Unexpected transaction response format');
    }
  }

  /// Returns all unconfirmed transactions touching [address] in the mempool.
  /// Returns an empty list when no mempool transactions exist for this address.
  Future<List<MempoolTx>> fetchMempoolTxs(String address) async {
    try {
      final response = await _withRetry(
        () => _dio.get<List<dynamic>>(
            '$baseUrl/address/$address/txs/mempool'),
        'mempool-txs',
      );
      return _parseMempoolTxList(response.data);
    } on EsploraException {
      rethrow;
    } on TypeError catch (_) {
      throw const EsploraException('Unexpected mempool response format');
    }
  }

  List<MempoolTx> _parseMempoolTxList(List<dynamic>? data) {
    if (data == null) return [];
    return data.map((e) {
      final tx = e as Map<String, dynamic>;
      final vin = tx['vin'] as List<dynamic>? ?? [];
      final vout = tx['vout'] as List<dynamic>? ?? [];
      return MempoolTx(
        txid: tx['txid'] as String,
        inputs: vin.map((i) {
          final prevout =
              ((i as Map<String, dynamic>)['prevout'] as Map<String, dynamic>?) ??
                  {};
          return (
            address: prevout['scriptpubkey_address'] as String?,
            sats: prevout['value'] as int? ?? 0,
          );
        }).toList(),
        outputs: vout.map((o) {
          final out = o as Map<String, dynamic>;
          return (
            address: out['scriptpubkey_address'] as String?,
            sats: out['value'] as int? ?? 0,
          );
        }).toList(),
      );
    }).toList();
  }
}
