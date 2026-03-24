import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../core/constants/app_constants.dart';
import '../core/services/license_key_service.dart';
import 'shared_preferences_provider.dart';

// License token is stored in Keystore-backed secure storage, not SharedPrefs.
const _secureStorage = FlutterSecureStorage();

/// Whether the user has unlocked the Pro tier.
///
/// F-Droid / sideload flavor: license token stored in [FlutterSecureStorage]
/// (Android Keystore AES-256-GCM). Token is re-verified asynchronously on
/// every cold start; state starts from the cached bool and is revoked if the
/// token is missing or invalid.
///
/// Play Store flavor (future): reads plain [keyProUnlocked] bool set by IAP.
final proUnlockedProvider =
    NotifierProvider<ProUnlockedNotifier, bool>(ProUnlockedNotifier.new);

class ProUnlockedNotifier extends Notifier<bool> {
  @override
  bool build() {
    final prefs = ref.read(sharedPreferencesProvider);

    if (AppConstants.kFlavor == 'direct') {
      // Start from the cached bool for immediate synchronous state.
      // Kick off async re-verification; state is revoked if token is invalid.
      _asyncReverify();
      return prefs.getBool(AppConstants.keyProUnlocked) ?? false;
    }

    // Play Store flavor: subscribe to the purchase stream and restore any
    // existing entitlement. The stream fires on purchase, restore, and error.
    final subscription = InAppPurchase.instance.purchaseStream.listen(
      _onPurchaseUpdate,
      onDone: () {},
      onError: (_) {},
    );
    ref.onDispose(subscription.cancel);
    InAppPurchase.instance.restorePurchases();
    return prefs.getBool(AppConstants.keyProUnlocked) ?? false;
  }

  Future<void> _onPurchaseUpdate(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.productID != AppConstants.iapProProductId) continue;

      if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        await ref
            .read(sharedPreferencesProvider)
            .setBool(AppConstants.keyProUnlocked, true);
        state = true;
        if (purchase.pendingCompletePurchase) {
          await InAppPurchase.instance.completePurchase(purchase);
        }
      } else if (purchase.status == PurchaseStatus.error) {
        if (kDebugMode) debugPrint('[IAP] purchase error: ${purchase.error}');
      }
    }
  }

  /// Reads the license token from secure storage and verifies the Ed25519
  /// signature. Revokes the unlock if the token is missing or invalid.
  Future<void> _asyncReverify() async {
    try {
      // Migrate legacy token from SharedPreferences to secure storage (runs once).
      final prefs = ref.read(sharedPreferencesProvider);
      final legacyToken = prefs.getString(AppConstants.keyLicenseToken);
      if (legacyToken != null) {
        await _secureStorage.write(
            key: AppConstants.keyLicenseToken, value: legacyToken);
        await prefs.remove(AppConstants.keyLicenseToken);
        if (kDebugMode) debugPrint('[Pro] migrated license token → secure storage');
      }

      final token =
          await _secureStorage.read(key: AppConstants.keyLicenseToken);
      if (token != null && LicenseKeyService.verify(token)) return;

      // Token missing or invalid — revoke.
      if (kDebugMode) debugPrint('[Pro] token invalid or missing — revoking');
      await prefs.remove(AppConstants.keyProUnlocked);
      state = false;
    } catch (e) {
      if (kDebugMode) debugPrint('[Pro] reverify error: $e');
    }
  }

  /// Verifies [token] and, if valid, persists the unlock state to secure storage.
  ///
  /// Returns `true` on success, `false` if the token fails verification.
  Future<bool> verifyAndUnlock(String token) async {
    if (!LicenseKeyService.verify(token)) return false;
    await _secureStorage.write(
        key: AppConstants.keyLicenseToken, value: token);
    await ref
        .read(sharedPreferencesProvider)
        .setBool(AppConstants.keyProUnlocked, true);
    state = true;
    return true;
  }

  /// Direct toggle — used only by the debug panel (debug builds).
  /// In F-Droid flavor this bypasses token verification intentionally for
  /// testing; the async re-verify in [build] will reset it on next cold start.
  Future<void> setUnlocked(bool value) async {
    state = value;
    await ref
        .read(sharedPreferencesProvider)
        .setBool(AppConstants.keyProUnlocked, value);
  }
}
