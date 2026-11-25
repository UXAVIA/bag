import 'dart:io';

import '../../models/network_route.dart';
import 'route_gate.dart';

/// Why a plain `http://` custom explorer was refused (R-3).
const plainHttpRefusedMessage =
    'Use https:// for this server. Plain http:// is only for .onion, '
    'local-network and loopback addresses.';

/// The note under a custom explorer saved before R-3 that is reached over
/// plain `http://` on a public host.
const unencryptedExplorerWarning = 'This server is reached without encryption.';

/// Whether plain `http://` is acceptable for an explorer at [host] (R-3):
/// an onion service (Tor encrypts it end to end), loopback, an RFC 1918 /
/// ULA / link-local literal, or a `.local` name. Anywhere else the
/// addresses Bag looks up would cross the internet, or a Tor exit, readable
/// by anyone on the path.
bool plainHttpAllowed(String host) {
  var h = host.toLowerCase();
  while (h.endsWith('.')) {
    h = h.substring(0, h.length - 1);
  }
  if (isOnionHost(h) || h.endsWith('.local')) return true;
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  final ip = InternetAddress.tryParse(h);
  if (ip == null) return false;
  if (ip.isLoopback || ip.isLinkLocal) return true;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }
  return (b[0] & 0xfe) == 0xfc; // fc00::/7, unique local
}

final _hasScheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://');

/// What the custom explorer's Save makes of [input] before any request:
/// the normalised base URL, or the reason it is refused. Both null for an
/// empty field.
///
/// A scheme-less entry gets `https://`, or `http://` for a `.onion` host,
/// which onion services almost always serve. Refused: anything but http(s),
/// link-local IPv4, a `.onion` host on a [route] that cannot reach one
/// (R-2), and plain `http://` to a host [plainHttpAllowed] rejects (R-3).
({String? url, String? error}) checkCustomExplorerUrl(
  String input,
  NetworkRoute route,
) {
  var raw = input.trim();
  if (raw.isEmpty) return (url: null, error: null);

  if (!_hasScheme.hasMatch(raw)) {
    final host = Uri.tryParse('http://$raw')?.host ?? '';
    raw = isOnionHost(host) ? 'http://$raw' : 'https://$raw';
  }

  // Reject non-HTTP schemes (file://, javascript:, ftp://, etc.).
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return (
      url: null,
      error: 'Invalid URL — must start with https:// or http://',
    );
  }

  // Reject cloud metadata IP (169.254.169.254) — not a valid node address.
  // LAN addresses (192.168.x.x, 10.x.x.x, 127.x.x.x) are intentionally
  // allowed: self-hosted Esplora nodes on a home network are a core use case.
  final host = uri.host.toLowerCase();
  if (host == '169.254.169.254' || host.startsWith('169.254.')) {
    return (
      url: null,
      error: 'Invalid URL — link-local addresses are not allowed.',
    );
  }

  if (isOnionHost(host) && !route.canReachOnion) {
    return (url: null, error: onionNeedsTorMessage);
  }
  if (uri.scheme == 'http' && !plainHttpAllowed(host)) {
    return (url: null, error: plainHttpRefusedMessage);
  }

  // Strip trailing slashes and any API path suffix the user may have typed.
  raw = raw.replaceAll(RegExp(r'/+$'), '');
  raw = raw.replaceAll(RegExp(r'/api/v\d+$'), '');
  raw = raw.replaceAll(RegExp(r'/api$'), '');
  return (url: raw, error: null);
}

/// Whether a saved custom explorer [url] is reached over plain `http://` on a
/// public host: saved before R-3, it keeps working, under a warning.
bool isUnencryptedExplorer(String url) {
  final uri = Uri.tryParse(url);
  return uri != null && uri.scheme == 'http' && !plainHttpAllowed(uri.host);
}
