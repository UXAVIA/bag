import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../core/utils/serial_chain.dart';
import '../models/network_route.dart';
import '../models/network_settings.dart';
import '../services/network/network_route_store.dart';
import '../services/network/route_gate.dart';
import '../services/tor_service.dart';
import '../services/widget_service.dart';
import '../services/wallet/wallet_store.dart';
import 'shared_preferences_provider.dart';

/// Custom Esplora URL loaded from secure storage before `runApp`.
///
/// Overridden in `main()` — the value is encrypted, so it cannot be read
/// synchronously in `build()`. Defaults to empty for tests and screenshots.
final initialExplorerUrlProvider = Provider<String>((ref) => '');

/// Saved proxy config loaded from secure storage before `runApp`.
///
/// Overridden in `main()`. Null means none saved *or* unreadable; for a
/// `use_proxy` user either way resolves to [MisconfiguredProxyRoute].
final initialProxyConfigProvider = Provider<ProxyConfig?>((ref) => null);

final networkSettingsProvider =
    NotifierProvider<NetworkSettingsNotifier, NetworkSettings>(
  NetworkSettingsNotifier.new,
);

class NetworkSettingsNotifier extends Notifier<NetworkSettings> {
  late SharedPreferences _prefs;

  /// Serialises every route setter ([setUseTor], [setUseProxy], [saveProxy],
  /// [clearProxy]), [reloadProxy], and the explorer setters ([setPreset],
  /// [setCustomUrl]). Each one awaits several prefs writes and
  /// the widget writer; interleaved taps on the Tor and proxy cards could
  /// otherwise leave both flags false while state shows a private route.
  /// A failed setter doesn't wedge the later ones.
  final _routeChain = SerialChain();

  Future<void> _serial(Future<void> Function() body) => _routeChain.run(body);

  /// Replaces [WidgetService.writeWidgetRouteFlags] in tests.
  @visibleForTesting
  static Future<void> Function()? debugWriteRouteFlagsOverride;

  @override
  NetworkSettings build() {
    _prefs = ref.read(sharedPreferencesProvider);

    final presetIndex = _prefs.getInt(AppConstants.keyExplorerPreset) ?? 0;
    // Encrypted at rest — a self-hosted node address identifies the user's
    // own infrastructure. Preloaded in main() via initialExplorerUrlProvider.
    final customUrl = ref.read(initialExplorerUrlProvider);
    final useTor = _prefs.getBool(AppConstants.keyUseTor) ?? false;

    return NetworkSettings(
      preset: ExplorerPreset.values[presetIndex.clamp(
        0,
        ExplorerPreset.values.length - 1,
      )],
      customUrl: customUrl,
      useTor: useTor,
      useProxy: _prefs.getBool(AppConstants.keyUseProxy) ?? false,
      proxy: ref.read(initialProxyConfigProvider),
    );
  }

  // On the serial chain too (M-2): a route setter builds its new state
  // before awaiting prefs and the widget writer, and publishing it would
  // otherwise revert a preset or URL set in that window.
  Future<void> setPreset(ExplorerPreset preset) => _serial(() async {
    await _prefs.setInt(AppConstants.keyExplorerPreset, preset.index);
    state = state.copyWith(preset: preset);
  });

  Future<void> setCustomUrl(String url) => _serial(() async {
    final trimmed = url.trim();
    await saveExplorerCustomUrl(trimmed);
    state = state.copyWith(customUrl: trimmed);
  });

  Future<void> setUseTor(bool value) => _serial(() async {
    // Tor and a custom proxy are mutually exclusive.
    final next = state.copyWith(
      useTor: value,
      useProxy: value ? false : state.useProxy,
    );
    await _prefs.setBool(AppConstants.keyUseTor, value);
    if (value) await _prefs.setBool(AppConstants.keyUseProxy, false);
    await _applyRoute(next);
  });

  /// Persists [config] (encrypted) without switching to it. The caller
  /// (the settings UI) trims the host and turns blank credentials into null;
  /// anything `ProxyConfig.validate` would reject is refused here so it can
  /// never reach storage.
  Future<void> saveProxy(ProxyConfig config) => _serial(() async {
    final error = ProxyConfig.validate(
      type: config.type,
      host: config.host,
      port: config.port.toString(),
      username: config.username,
      password: config.password,
    );
    // Host must be stored exactly as validated, not just valid once trimmed.
    if (error != null || config.host != config.host.trim()) {
      throw ArgumentError('Invalid proxy settings: ${error ?? 'host has '
          'surrounding whitespace'}');
    }
    // validate() reads an empty string as "no credential"; storage needs
    // null for that, or the entry would be refused on every read.
    if (!config.isRoutable) {
      throw ArgumentError('Invalid proxy settings: enter both a username and '
          'a password, or neither.');
    }
    await saveProxyConfig(config);
    state = state.copyWith(proxy: () => config);
    // An active proxy now points somewhere else — drop the memoised probe.
    if (state.route is ProxyRoute) RouteGate.invalidateCache();
  });

  Future<void> clearProxy() => _serial(() async {
    await saveProxyConfig(null);
    await _prefs.setBool(AppConstants.keyUseProxy, false);
    await _applyRoute(state.copyWith(useProxy: false, proxy: () => null));
  });

  /// The selected route, for callers that hold the notifier and must not go
  /// through `ref` (one whose dependency on this provider just changed).
  NetworkRoute get route => state.route;

  /// Re-reads the saved proxy from secure storage. `main()` reads it once
  /// before `runApp`; if that failed (keychain still locked, a transient
  /// read error), this is how the app recovers without a restart. A config
  /// that is readable now becomes the route; one that is still unreadable
  /// (or missing) leaves a `use_proxy` user on [MisconfiguredProxyRoute].
  Future<void> reloadProxy() => _serial(() async {
    final config = await loadProxyConfigOrNull();
    if (config == state.proxy) return;
    await _applyRoute(state.copyWith(proxy: () => config));
  });

  /// Switches the saved proxy on or off. The saved config is kept when off;
  /// only [clearProxy] deletes it.
  Future<void> setUseProxy(bool value) => _serial(() async {
    if (value && state.proxy == null) {
      throw StateError('No proxy saved');
    }
    await _prefs.setBool(AppConstants.keyUseProxy, value);
    if (value) await _prefs.setBool(AppConstants.keyUseTor, false);
    await _applyRoute(
      state.copyWith(useProxy: value, useTor: value ? false : state.useTor),
    );
  });

  /// Mirrors the route flags to the widget, drops the memoised probe, points
  /// the embedded Tor client at the new route and only then publishes
  /// [next], so neither the widget nor the next request lags the toggle.
  /// Callers write prefs first: the shared writer reads the route from them.
  ///
  /// Only a route *change* moves the client. Its start or stop is issued
  /// here, before [next] is published, so `routeStatusProvider` sees
  /// `starting` (or `off`) when it rebuilds. Neither is awaited: the client
  /// serialises its own native start and stop, so the next setter on the
  /// chain can't start a second client next to a stopping one.
  ///
  /// The widget flags are best-effort (M-3): a write that fails is retried
  /// once, and if it fails again [next] is published anyway, because the
  /// app's own traffic must follow the user's choice. The background
  /// isolates read the route from prefs, which the caller already wrote, and
  /// the next foreground widget update (`WidgetService.update`) rewrites the
  /// flags.
  Future<void> _applyRoute(NetworkSettings next) async {
    await _writeWidgetRouteFlags();
    RouteGate.invalidateCache();
    if (next.route != state.route) {
      TorService.followRoute(next.route);
      // Not awaited, like the Tor start and stop: a platform call never
      // holds the serial chain. It never throws.
      unawaited(WidgetService.backgroundRefreshFollows(next.route));
    }
    state = next;
  }

  Future<void> _writeWidgetRouteFlags() async {
    final write =
        debugWriteRouteFlagsOverride ?? WidgetService.writeWidgetRouteFlags;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await write();
        return;
      } catch (e) {
        // The type only: nothing about the route or the user.
        debugPrint('[NetworkSettings] widget route flags not written '
            '(${e.runtimeType}, attempt $attempt of 2)');
      }
    }
  }
}
