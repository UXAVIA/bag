import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';

/// Prefs keys Bag no longer writes. Each one said something about the user
/// in plaintext, so an upgrade deletes it rather than leave it behind.
const retiredPrefsKeys = [
  // How the user holds their coins (onboarding's question). Nothing read it.
  AppConstants.keyOnboardingHolding,
];

/// Deletes [retiredPrefsKeys]. Runs in `main()` on every launch; once the
/// keys are gone it only checks for them.
Future<void> removeRetiredPrefs(SharedPreferences prefs) async {
  for (final key in retiredPrefsKeys) {
    if (prefs.containsKey(key)) await prefs.remove(key);
  }
}
