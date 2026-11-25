import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_constants.dart';
import '../../models/network_route.dart';
import '../../models/network_settings.dart';

/// The stored proxy entry could not be read or parsed.
///
/// The message never carries the stored JSON: it holds credentials.
class ProxyConfigUnreadable implements Exception {
  const ProxyConfigUnreadable();

  @override
  String toString() => 'ProxyConfigUnreadable: the saved proxy is unreadable';
}

// Dedicated instance: the entry lives in the shared keychain group so the iOS
// WidgetKit extension can read it. Everything else keeps the app's own group.
const _storage = FlutterSecureStorage(
  aOptions: AndroidOptions(),
  iOptions: IOSOptions(
    groupId: AppConstants.iosAppGroupId,
    accountName: 'bag_network',
    accessibility: KeychainAccessibility.first_unlock,
  ),
);

/// Reads the saved proxy. Null when none is stored; throws
/// [ProxyConfigUnreadable] when the entry exists but cannot be used, so
/// callers can fail closed rather than treat it as "no proxy".
Future<ProxyConfig?> loadProxyConfig() async {
  final String? raw;
  try {
    raw = await _storage.read(key: AppConstants.keyNetworkProxy);
  } catch (_) {
    throw const ProxyConfigUnreadable();
  }
  if (raw == null || raw.isEmpty) return null;
  try {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) throw const FormatException();
    final config = ProxyConfig.fromJson(json);
    // The host and credentials are spliced into strings with no escaping —
    // re-check what is on disk instead of trusting that it was validated on
    // the way in.
    if (!config.isRoutable) throw const FormatException();
    return config;
  } catch (_) {
    // Deliberately drops the original error: FormatException messages can
    // quote the source text, which holds credentials.
    throw const ProxyConfigUnreadable();
  }
}

/// [loadProxyConfig], with an unreadable entry read as none. Only for callers
/// that fail closed on null: with `use_proxy` on, no config is
/// [MisconfiguredProxyRoute], never direct.
Future<ProxyConfig?> loadProxyConfigOrNull() async {
  try {
    return await loadProxyConfig();
  } on ProxyConfigUnreadable {
    return null;
  }
}

/// Persists [config], or deletes the entry when null.
Future<void> saveProxyConfig(ProxyConfig? config) async {
  if (config == null) {
    await _storage.delete(key: AppConstants.keyNetworkProxy);
    return;
  }
  await _storage.write(
    key: AppConstants.keyNetworkProxy,
    value: jsonEncode(config.toJson()),
  );
}

/// The selected route, for isolates that have no Riverpod (Sentinel,
/// WorkManager), by `NetworkSettings.route`'s precedence; a proxy that is on
/// but unusable is [MisconfiguredProxyRoute], never direct. `use_proxy` and
/// the saved config are read only when they decide the route: not with Tor
/// on, and the config only with the proxy on.
Future<NetworkRoute> readNetworkRoute(SharedPreferences prefs) async {
  final useTor = prefs.getBool(AppConstants.keyUseTor) ?? false;
  final useProxy =
      !useTor && (prefs.getBool(AppConstants.keyUseProxy) ?? false);
  return NetworkSettings(
    useTor: useTor,
    useProxy: useProxy,
    proxy: useProxy ? await loadProxyConfigOrNull() : null,
  ).route;
}

/// How long [torRouteStillSelected] may take, prefs reload included.
const _torRouteCheckTimeout = Duration(seconds: 5);

/// The route re-check a background isolate (Sentinel, the WorkManager task)
/// passes to `TorHost.acquire` as `stillTor`, and asks before it takes a
/// lease at all: prefs reloaded, then the route read afresh. True only for
/// [TorRoute]; false for any other route, for a read that takes longer than
/// [_torRouteCheckTimeout], and for one that throws, so a doubtful answer
/// starts no Tor client.
Future<bool> torRouteStillSelected({
  @visibleForTesting Future<SharedPreferences> Function() loadPrefs =
      reloadedPrefs,
}) async {
  try {
    final route = await loadPrefs()
        .then(readNetworkRoute)
        .timeout(_torRouteCheckTimeout);
    return route is TorRoute;
  } catch (_) {
    return false;
  }
}

/// Prefs as another isolate last wrote them, not as this one cached them.
/// SharedPreferences caches what it read at start-up, so an isolate that
/// outlives a settings change (Sentinel, the WorkManager task) and reads the
/// route without this could see a stale `use_proxy = false` after the user
/// switched the proxy on, and go direct.
Future<SharedPreferences> reloadedPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return prefs;
}
