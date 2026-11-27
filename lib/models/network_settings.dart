import '../core/constants/app_constants.dart';
import 'network_route.dart';

enum ExplorerPreset { blockstream, mempool, custom }

/// The explorer's base URL on [route]. The mempool.space preset uses
/// mempool's onion over Tor, since mempool.space refuses Tor exits; nothing
/// else depends on the route. Shared with the background isolates
/// (`resolveExplorerBaseUrl`).
String explorerBaseUrl(
  ExplorerPreset preset,
  String customUrl,
  NetworkRoute route,
) =>
    switch (preset) {
      ExplorerPreset.blockstream => AppConstants.explorerBlockstream,
      ExplorerPreset.mempool => route is TorRoute
          ? AppConstants.explorerMempoolOnion
          : AppConstants.explorerMempool,
      ExplorerPreset.custom =>
        customUrl.isNotEmpty ? customUrl : AppConstants.explorerBlockstream,
    };

class NetworkSettings {
  final ExplorerPreset preset;
  final String customUrl;
  final bool useTor;
  final bool useProxy;

  /// The saved proxy config. Kept when [useProxy] is off so the user can
  /// switch back without re-entering it.
  final ProxyConfig? proxy;

  const NetworkSettings({
    this.preset = ExplorerPreset.blockstream,
    this.customUrl = '',
    this.useTor = false,
    this.useProxy = false,
    this.proxy,
  });

  /// The route: Tor, then a proxy, then direct (`readNetworkRoute` uses it
  /// too). A proxy that is switched on but has no config fails closed.
  NetworkRoute get route {
    if (useTor) return const TorRoute();
    if (useProxy) {
      final p = proxy;
      return p == null ? const MisconfiguredProxyRoute() : ProxyRoute(p);
    }
    return const DirectRoute();
  }

  /// The base URL that the Esplora client (and the fee estimate) should use
  /// on this settings' route.
  String get effectiveBaseUrl => explorerBaseUrl(preset, customUrl, route);

  NetworkSettings copyWith({
    ExplorerPreset? preset,
    String? customUrl,
    bool? useTor,
    bool? useProxy,
    ProxyConfig? Function()? proxy,
  }) =>
      NetworkSettings(
        preset: preset ?? this.preset,
        customUrl: customUrl ?? this.customUrl,
        useTor: useTor ?? this.useTor,
        useProxy: useProxy ?? this.useProxy,
        proxy: proxy != null ? proxy() : this.proxy,
      );
}
