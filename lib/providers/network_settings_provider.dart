import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../models/network_settings.dart';
import 'shared_preferences_provider.dart';

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
    final customUrl =
        _prefs.getString(AppConstants.keyExplorerCustomUrl) ?? '';
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
    await _prefs.setString(AppConstants.keyExplorerCustomUrl, trimmed);
    state = state.copyWith(customUrl: trimmed);
  }

  Future<void> setUseTor(bool value) async {
    await _prefs.setBool(AppConstants.keyUseTor, value);
    state = state.copyWith(useTor: value);
  }
}
