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
