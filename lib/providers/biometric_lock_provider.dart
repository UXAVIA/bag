import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_constants.dart';
import 'shared_preferences_provider.dart';

final biometricLockProvider =
    NotifierProvider<BiometricLockNotifier, bool>(BiometricLockNotifier.new);

class BiometricLockNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.read(sharedPreferencesProvider).getBool(AppConstants.keyBiometricLock) ?? false;

  Future<void> setEnabled(bool value) async {
    await ref
        .read(sharedPreferencesProvider)
        .setBool(AppConstants.keyBiometricLock, value);
    state = value;
  }
}
