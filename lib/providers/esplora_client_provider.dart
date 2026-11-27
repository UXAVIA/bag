import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/wallet/esplora_client.dart';
import 'network_settings_provider.dart';

/// Provides a configured [EsploraClient] that reflects the current network
/// settings. Rebuilds automatically when they change — wallet scans always
/// use the latest configuration.
///
/// The client always carries the selected route, whatever its last probe
/// said: a private route that is down makes every request fail, never fall
/// back to clearnet. The scan and health-check paths still probe the route
/// first so the user gets a clear error instead of a run of failed requests.
///
/// Rebuilt only when the route or the explorer URL changes, and the old
/// client is closed then (R-1): a scan or health check holding it stops at
/// once instead of carrying on over the route the user just left.
final esploraClientProvider = Provider<EsploraClient>((ref) {
  final (route, baseUrl) = ref.watch(
    networkSettingsProvider.select((s) => (s.route, s.effectiveBaseUrl)),
  );
  final client = EsploraClient(baseUrl: baseUrl, route: route);
  ref.onDispose(client.close);
  return client;
});
