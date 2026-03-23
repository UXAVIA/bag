// Tor availability probe.
//
// Performs a fast TCP connect to the local Orbot SOCKS5 port.
// This is a non-blocking check — the 2-second timeout ensures the app
// never hangs waiting for Tor (unlike clients that silently route through
// an unavailable proxy and spin forever).

import 'dart:io';
import '../core/constants/app_constants.dart';

enum TorStatus { checking, available, unavailable }

class TorService {
  TorService._();

  /// Probes the local Orbot SOCKS5 port with a 2-second timeout.
  /// Returns [TorStatus.available] if a TCP connection succeeds,
  /// [TorStatus.unavailable] otherwise.
  static Future<TorStatus> probe() async {
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
}
