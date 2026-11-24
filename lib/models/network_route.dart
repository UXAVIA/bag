import 'dart:convert';
import 'dart:io';

final _dnsName = RegExp(
  r'^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
  r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$',
);
final _ipLiteralChars = RegExp(r'^[0-9A-Fa-f:.]+$');

/// Whether [host] is a bare IP literal (IPv4, or IPv6 without brackets or a
/// zone id) or a plain DNS name, and nothing else.
///
/// Strict on purpose: the host is spliced into Dart's `PROXY host:port`
/// string, which has no escaping, splits on ';' and falls through to the next
/// entry on error, so a stray ';', '@', '[', ']' or space could turn into a
/// direct connection. Used both by [ProxyConfig.validate] and by the routing
/// layer, which re-checks stored configs.
bool isValidProxyHost(String host) {
  if (_ipLiteralChars.hasMatch(host) &&
      InternetAddress.tryParse(host) != null) {
    return true;
  }
  return _dnsName.hasMatch(host);
}

/// Whether Dart's `PROXY user:pass@host:port` string can carry these HTTP
/// proxy credentials: non-empty, no ':' in the username, no ';', and no
/// leading or trailing whitespace.
bool _httpProxyCredentialsCarriable(String username, String password) {
  if (username.isEmpty || password.isEmpty || username.contains(':')) {
    return false;
  }
  for (final s in [username, password]) {
    if (s.contains(';') || s != s.trim()) return false;
  }
  return true;
}

/// Whether RFC 1929 can carry these SOCKS5 proxy credentials: it
/// length-prefixes each field with a single byte.
bool _socks5CredentialsCarriable(String username, String password) =>
    utf8.encode(username).length <= 255 && utf8.encode(password).length <= 255;

bool _isValidPort(int port) => port >= 1 && port <= 65535;

/// Protocol spoken to a user-supplied proxy.
enum ProxyType { socks5, http }

/// A user-supplied SOCKS5 or HTTP proxy.
///
/// Host, port and credentials are encrypted at rest by the storage layer;
/// this class only models them. [toString] and [label] never include
/// credentials.
class ProxyConfig {
  const ProxyConfig({
    required this.type,
    required this.host,
    required this.port,
    this.username,
    this.password,
  });

  final ProxyType type;
  final String host;
  final int port;
  final String? username;
  final String? password;

  bool get hasCredentials => username != null && password != null;

  /// Whether this config can be dialled as stored: a host [isValidProxyHost]
  /// accepts, a port in range, and credentials that are either both null or
  /// both non-empty and that the protocol can carry (Dart's `PROXY` string
  /// for HTTP, RFC 1929's one-byte lengths for SOCKS5).
  ///
  /// The one predicate the storage layer, the route gate and the routing
  /// layer all apply, so a config one of them would refuse can never be
  /// dialled by another.
  bool get isRoutable {
    if (!isValidProxyHost(host) || !_isValidPort(port)) return false;
    final user = username;
    final pass = password;
    if (user == null && pass == null) return true;
    if (user == null || pass == null || user.isEmpty || pass.isEmpty) {
      return false;
    }
    return switch (type) {
      ProxyType.http => _httpProxyCredentialsCarriable(user, pass),
      ProxyType.socks5 => _socks5CredentialsCarriable(user, pass),
    };
  }

  /// `host:port`, safe to show in the UI.
  String get label => '$host:$port';

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'host': host,
    'port': port,
    if (username != null) 'username': username,
    if (password != null) 'password': password,
  };

  /// Throws [FormatException] on missing or invalid fields.
  factory ProxyConfig.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'];
    final type = ProxyType.values.where((t) => t.name == typeName).firstOrNull;
    if (type == null) {
      throw const FormatException('ProxyConfig: unknown or missing type');
    }
    final host = json['host'];
    if (host is! String || host.isEmpty) {
      throw const FormatException('ProxyConfig: missing host');
    }
    final port = json['port'];
    if (port is! int || !_isValidPort(port)) {
      throw const FormatException('ProxyConfig: invalid port');
    }
    final username = json['username'];
    final password = json['password'];
    if (username != null && username is! String) {
      throw const FormatException('ProxyConfig: invalid username');
    }
    if (password != null && password is! String) {
      throw const FormatException('ProxyConfig: invalid password');
    }
    if ((username == null) != (password == null)) {
      throw const FormatException('ProxyConfig: half a credential pair');
    }
    return ProxyConfig(
      type: type,
      host: host,
      port: port,
      username: username as String?,
      password: password as String?,
    );
  }

  /// Validates raw form input. Returns the first error as a user-facing
  /// message, or null when the input is a usable proxy.
  static String? validate({
    required ProxyType type,
    required String host,
    required String port,
    String? username,
    String? password,
  }) {
    final h = host.trim();
    final p = port.trim();

    if (h.isEmpty) return 'Enter the proxy host.';
    if (h.contains('://')) {
      return 'Enter the host without socks5:// or http://.';
    }
    // Two or more colons may be an IPv6 literal; isValidProxyHost decides.
    if (':'.allMatches(h).length == 1) {
      return 'Put the port in the port field, not in the host.';
    }
    if (!isValidProxyHost(h)) {
      return 'Enter a hostname or IP address, without brackets, spaces or '
          'symbols.';
    }

    final portNumber = int.tryParse(p);
    if (portNumber == null || !_isValidPort(portNumber)) {
      return 'Port must be 1–65535.';
    }

    final hasUser = username != null && username.isNotEmpty;
    final hasPass = password != null && password.isNotEmpty;
    if (hasUser != hasPass) {
      return 'Enter both a username and a password, or neither.';
    }
    if (!hasUser) return null;

    switch (type) {
      case ProxyType.http:
        // Dart's `PROXY user:pass@host:port` string has no escaping: it
        // splits on ';', trims both parts, takes the last '@' as the
        // separator and the first ':' in the credentials. So '@' and ':' are
        // fine in a password, but ':' in a username, ';' anywhere and
        // leading/trailing whitespace cannot be carried.
        if (!_httpProxyCredentialsCarriable(username, password!)) {
          return username.contains(':')
              ? 'The username cannot contain ":".'
              : 'The username and password cannot contain ";" or start '
                    'or end with a space.';
        }
      case ProxyType.socks5:
        if (!_socks5CredentialsCarriable(username, password!)) {
          return 'The username and password must each be at most 255 bytes.';
        }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProxyConfig &&
          other.type == type &&
          other.host == host &&
          other.port == port &&
          other.username == username &&
          other.password == password;

  @override
  int get hashCode => Object.hash(type, host, port, username, password);

  @override
  String toString() =>
      'ProxyConfig(${type.name}, $label, auth: ${hasCredentials ? 'yes' : 'no'})';
}

/// Whether [host] names a Tor onion service: it ends in `.onion`, ignoring
/// case and trailing dots. A suffix test, not a substring one:
/// `foo.onion.example.com` is a clearnet name.
bool isOnionHost(String host) {
  var h = host.toLowerCase();
  while (h.endsWith('.')) {
    h = h.substring(0, h.length - 1);
  }
  return h.endsWith('.onion');
}

/// How a network request leaves the device.
sealed class NetworkRoute {
  const NetworkRoute();

  /// True for every route that must never fall back to clearnet.
  bool get isPrivate;

  /// Whether a `.onion` host can be reached this way: over Tor, or through a
  /// SOCKS5 proxy, which receives the name and may front Tor. Anywhere else
  /// the name would go to the local resolver, or to an HTTP proxy in its
  /// CONNECT line, so the routing layer refuses it (R-2).
  bool get canReachOnion => switch (this) {
        TorRoute() => true,
        ProxyRoute(:final config) => config.type == ProxyType.socks5,
        DirectRoute() || MisconfiguredProxyRoute() => false,
      };
}

final class DirectRoute extends NetworkRoute {
  const DirectRoute();

  @override
  bool get isPrivate => false;

  @override
  bool operator ==(Object other) => other is DirectRoute;

  @override
  int get hashCode => (DirectRoute).hashCode;

  @override
  String toString() => 'DirectRoute()';
}

final class TorRoute extends NetworkRoute {
  const TorRoute();

  @override
  bool get isPrivate => true;

  @override
  bool operator ==(Object other) => other is TorRoute;

  @override
  int get hashCode => (TorRoute).hashCode;

  @override
  String toString() => 'TorRoute()';
}

final class ProxyRoute extends NetworkRoute {
  const ProxyRoute(this.config);

  final ProxyConfig config;

  @override
  bool get isPrivate => true;

  @override
  bool operator ==(Object other) =>
      other is ProxyRoute && other.config == config;

  @override
  int get hashCode => Object.hash(ProxyRoute, config);

  @override
  String toString() => 'ProxyRoute($config)';
}

/// A proxy is enabled but its config is missing or unreadable. Private, so
/// every path fails closed instead of falling back to clearnet.
final class MisconfiguredProxyRoute extends NetworkRoute {
  const MisconfiguredProxyRoute();

  @override
  bool get isPrivate => true;

  @override
  bool operator ==(Object other) => other is MisconfiguredProxyRoute;

  @override
  int get hashCode => (MisconfiguredProxyRoute).hashCode;

  @override
  String toString() => 'MisconfiguredProxyRoute()';
}
