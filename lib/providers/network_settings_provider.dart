import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../models/network_settings.dart';
import '../services/tor_service.dart';
import '../services/wallet/wallet_store.dart';
import 'shared_preferences_provider.dart';

/// Custom Esplora URL loaded from secure storage before `runApp`.
///
/// Overridden in `main()` — the value is encrypted, so it cannot be read
/// synchronously in `build()`. Defaults to empty for tests and screenshots.
final initialExplorerUrlProvider = Provider<String>((ref) => '');

final networkSettingsProvider =
    NotifierProvider<NetworkSettingsNotifier, NetworkSettings>(
  NetworkSettingsNotifier.new,
);

class NetworkSettingsNotifier extends Notifier<NetworkSettings> {
  late SharedPreferences _prefs;

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
    );
  }

  Future<void> setPreset(ExplorerPreset preset) async {
    await _prefs.setInt(AppConstants.keyExplorerPreset, preset.index);
    state = state.copyWith(preset: preset);
  }

  Future<void> setCustomUrl(String url) async {
    final trimmed = url.trim();
    await saveExplorerCustomUrl(trimmed);
    state = state.copyWith(customUrl: trimmed);
  }

  Future<void> setUseTor(bool value) async {
    await _prefs.setBool(AppConstants.keyUseTor, value);
    // Drop the memoised probe result so the very next request re-checks
    // rather than trusting an answer from before the toggle.
    TorService.invalidateCache();
    state = state.copyWith(useTor: value);
  }
}
