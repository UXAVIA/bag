import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/tor_service.dart';
import '../services/wallet/esplora_client.dart';
import 'network_settings_provider.dart';
import 'tor_status_provider.dart';

/// Provides a configured [EsploraClient] that reflects the current
/// network settings and Tor availability. Rebuilds automatically when
/// either changes — wallet scans always use the latest configuration.
///
/// Note: the scan/health-check paths do their own fresh Tor probe before
/// calling this provider, so the cached torStatusProvider value here is
/// only used to decide the client shape — it will already be up-to-date
/// when the fresh probe triggers a recheck().
final esploraClientProvider = Provider<EsploraClient>((ref) {
  final settings = ref.watch(networkSettingsProvider);
  final torAsync = ref.watch(torStatusProvider);

  // While the initial probe is still running, treat Tor as unavailable
  // so we never build a clearnet client that bypasses the user's intent.
  // The scan gate always does a fresh probe before reading this provider,
  // so the client will be rebuilt correctly before any scan starts.
  final torStatus = torAsync.valueOrNull;
  final useTor = settings.useTor && torStatus == TorStatus.available;

  return EsploraClient(
    baseUrl: settings.effectiveBaseUrl,
    useTor: useTor,
  );
});
