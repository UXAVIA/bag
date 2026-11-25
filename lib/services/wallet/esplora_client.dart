// Esplora API client for address balance and transaction lookups.
//
// Security design:
// - Only address hashes are sent — the zpub is NEVER transmitted.
// - No authentication headers, no cookies, no identifying info.
// - Addresses are not logged.
// - Every request leaves over the given [NetworkRoute] (the built-in Tor, a
//   user-supplied proxy, or direct). Private routes fail closed: a dead proxy
//   or a Tor client that isn't ready means a refused request, never a
//   clearnet one. Callers still probe the route first so the user gets a
//   clear error.
//
// Reliability over a private route (Tor, or a proxy that may chain to Tor):
// - Timeouts are raised to 60 s (vs 20 s clearnet) — Tor circuit
//   establishment alone can take 10–20 s.
// - Transient failures (timeout, connection reset) are retried up to 4 times
//   with exponential back-off (5 s / 10 s / 20 s / 30 s). Tor circuits rotate
//   every ~10 min; a rotation causes a connection reset and the new circuit
//   typically takes 5–30 s to warm up.
// - A .onion the route refused on the device (OnionNeedsTorException) is
//   final and never retried.

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../network/route_gate.dart' show onionNeedsTorMessage;
import '../network/routed_http.dart';

import '../../models/chain_analysis.dart';
import '../../models/network_route.dart';

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
  final NetworkRoute route;
  final Dio _dio;

  /// Strips a trailing /api or /api/vN suffix so we can fall back to the
  /// root-level Esplora path when a sub-path doesn't serve all endpoints.
  String get _rootBaseUrl =>
      baseUrl.replaceAll(RegExp(r'/api(/v\d+)?$'), '');

  /// Whether requests go over Tor or a proxy. Drives retries here and scan
  /// concurrency in the callers.
  bool get isPrivateRoute => route.isPrivate;

  // Over a private route, retry up to 5 attempts total (4 retries). Clearnet
  // gets 1.
  int get _maxAttempts => isPrivateRoute ? 5 : 1;

  // [route] is required, with no default: a caller that forgot it would
  // otherwise go out in the clear while a private route is selected. The
  // Dio sends no identifying headers, just Accept: JSON. Private routes get
  // the 60 s [privateRouteTimeout] instead of 20 s: Tor circuits take far
  // longer to establish than clearnet TCP.
  EsploraClient({
    required this.baseUrl,
    required this.route,
  }) : _dio = buildRoutedJsonDio(route);

  bool _closed = false;

  /// Whether [close] has run. A closed client makes no request.
  bool get isClosed => _closed;

  /// Abandons every request in flight and refuses every later one with
  /// [RouteChangedException]. `esploraClientProvider` calls it when the
  /// route or the explorer changes, so a scan that started on the old route
  /// can't carry on over it (R-1). Nothing is retried, on either route.
  void close() {
    _closed = true;
    _dio.close(force: true);
  }

  void _throwIfClosed() {
    if (_closed) throw const RouteChangedException();
  }

  // ── Retry wrapper ─────────────────────────────────────────────────────────

  // Exponential back-off before each private-route retry, in seconds: retry
  // n waits entry n - 1. Tor circuit establishment after a rotation
  // typically takes 5–30 s; exponential gives the new circuit time to warm
  // up without hanging indefinitely on later attempts.
  static const _privateRouteBackoffSeconds = [5, 10, 20, 30];

  /// One back-off "second". Tests set it to [Duration.zero] so exhausting the
  /// private-route retries does not take 65 s of real time.
  @visibleForTesting
  static Duration debugRetryDelayUnit = const Duration(seconds: 1);

  /// Calls [fn] up to [_maxAttempts] times, retrying on transient Dio errors.
  /// Uses exponential back-off so a new Tor circuit has time to warm up.
  Future<T> _withRetry<T>(Future<T> Function() fn, String context) async {
    DioException? lastDioError;

    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      if (attempt > 0) {
        final delaySecs = _privateRouteBackoffSeconds[
            (attempt - 1).clamp(0, _privateRouteBackoffSeconds.length - 1)];
        if (kDebugMode) {
          debugPrint(
              '[Esplora] retry $attempt/${_maxAttempts - 1} ($context) — waiting ${delaySecs}s');
        }
        await Future.delayed(debugRetryDelayUnit * delaySecs);
      }
      try {
        return await fn();
      } on DioException catch (e) {
        // Closed: the request was abandoned (or, after the close, refused by
        // the closed Dio without a connection), not a network error to retry.
        _throwIfClosed();
        // A .onion explorer this route can't reach, refused on the device
        // before any lookup (routed_http): final, never retried. Retrying it
        // would only sit out the back-off, about 65 s per request (net R-1).
        if (e.error is OnionNeedsTorException) {
          throw const EsploraException(onionNeedsTorMessage);
        }
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
          _throwIfClosed();
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
