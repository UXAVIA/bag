// Tor availability probe.
//
// Android: Orbot exposes a local SOCKS5 proxy on 127.0.0.1:9050 — fast TCP
//   connect confirms the port is open and the proxy is ready.
// iOS: Orbot runs as a system VPN (Network Extension). Other apps cannot
//   reach its localhost port due to sandbox isolation, so we verify Tor by
//   making an HTTP request to check.torproject.org/api — the Tor Project's
//   own endpoint that returns {"IsTor": true} when traffic exits through Tor.
//   Since Orbot's VPN routes all device traffic through Tor at the OS level,
//   a plain HTTP request (no SOCKS5) is sufficient.

import 'dart:convert';
import 'dart:io';

import '../core/constants/app_constants.dart';

enum TorStatus { checking, available, unavailable }

class TorService {
  TorService._();

  /// Returns true when SOCKS5 proxy configuration is needed.
  /// On iOS Orbot routes via VPN — no SOCKS5 setup required.
  static bool get needsSocks5 => Platform.isAndroid;

  /// Platform-aware Orbot/Tor detection.
  static Future<TorStatus> probe() async {
    if (Platform.isIOS) return _probeIOS();
    return _probeAndroid();
  }

  // ── Short-lived probe cache ───────────────────────────────────────────────
  //
  // The price and chart layer fetches from up to five hosts per refresh. A
  // fresh probe per request would mean five TCP connects on Android and — far
  // worse — five round trips to check.torproject.org on iOS. Memoising for a
  // few seconds collapses a refresh burst into one probe while still being
  // short enough that Orbot dropping is noticed on the next cycle.
  static const _probeCacheTtl = Duration(seconds: 30);
  static TorStatus? _cachedStatus;
  static DateTime? _cachedAt;
  static Future<TorStatus>? _inFlight;

  /// Like [probe], but reuses a result younger than 30 seconds and collapses
  /// concurrent callers onto a single probe.
  ///
  /// Use this on hot paths (price/chart refresh). Wallet scans and the health
  /// check deliberately call [probe] directly — they touch address data, so
  /// they always want a result from *right now*.
  static Future<TorStatus> probeCached() {
    final cachedAt = _cachedAt;
    final cached = _cachedStatus;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _probeCacheTtl) {
      return Future.value(cached);
    }
    return _inFlight ??= probe().then((status) {
      _cachedStatus = status;
      _cachedAt = DateTime.now();
      _inFlight = null;
      return status;
    }, onError: (Object e) {
      _inFlight = null;
      throw e;
    });
  }

  /// Drops the memoised probe result. Call when the user toggles Tor or
  /// explicitly re-checks, so the next request cannot use a stale answer.
  static void invalidateCache() {
    _cachedStatus = null;
    _cachedAt = null;
  }

  /// Android: TCP-probe the local Orbot SOCKS5 port (2 s timeout).
  static Future<TorStatus> _probeAndroid() async {
    try {
      final socket = await Socket.connect(
        AppConstants.torHost,
        AppConstants.torPort,
        timeout: const Duration(seconds: 2),
      );
      await socket.close();
      return TorStatus.available;
    } catch (_) {
      return TorStatus.unavailable;
    }
  }

  /// iOS: Verify traffic is actually routing through Tor by querying the Tor
  /// Project's check endpoint. Returns [TorStatus.available] only when the
  /// response confirms `{"IsTor": true}`.
  static Future<TorStatus> _probeIOS() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(
        Uri.parse('https://check.torproject.org/api/ip'),
      );
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join();
      client.close();
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['IsTor'] == true
          ? TorStatus.available
          : TorStatus.unavailable;
    } catch (_) {
      return TorStatus.unavailable;
    }
  }
}
