import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_constants.dart';
import 'shared_preferences_provider.dart';

final satsModeProvider = NotifierProvider<SatsModeNotifier, bool>(
  SatsModeNotifier.new,
);

class SatsModeNotifier extends Notifier<bool> {
  @override
  bool build() {
    final prefs = ref.read(sharedPreferencesProvider);
    return prefs.getBool(AppConstants.keySatsMode) ?? false;
  }

  Future<void> toggle() async {
    state = !state;
    await ref
        .read(sharedPreferencesProvider)
        .setBool(AppConstants.keySatsMode, state);
  }
}
