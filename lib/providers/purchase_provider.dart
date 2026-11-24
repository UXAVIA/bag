import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/iap/iap.dart';

import '../core/constants/app_constants.dart';
import '../core/services/license_key_service.dart';
import 'shared_preferences_provider.dart';

// License token is stored in Keystore-backed secure storage, not SharedPrefs.
const _secureStorage = FlutterSecureStorage();

/// Whether the user has unlocked the Pro tier.
///
/// F-Droid / sideload flavor: license token stored in [FlutterSecureStorage]
/// (Android Keystore AES-256-GCM). Token is re-verified asynchronously on
/// every cold start; state starts from the cached bool, is restored if the
/// token is valid and revoked if it is missing or invalid.
///
/// Store flavor (Google Play and the App Store): `in_app_purchase`. The
/// bool in [AppConstants.keyProUnlocked] is set on a purchase or restore,
/// and purchases are restored on every cold start.
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

    // Store flavor: subscribe to the purchase stream and restore any
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
          try {
            await InAppPurchase.instance.completePurchase(purchase);
          } catch (e) {
            if (kDebugMode) debugPrint('[IAP] completePurchase error: $e');
          }
        }
      } else if (purchase.status == PurchaseStatus.error) {
        if (kDebugMode) debugPrint('[IAP] purchase error: ${purchase.error}');
      }
    }
  }

  /// Reads the license token from secure storage and verifies the Ed25519
  /// signature. A valid token turns Pro on (and restores the cached bool if
  /// it was lost: the token, not the bool, is what Pro rests on, M-13); a
  /// missing or invalid one revokes it.
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
      if (token != null && LicenseKeyService.verify(token)) {
        if (prefs.getBool(AppConstants.keyProUnlocked) != true) {
          await prefs.setBool(AppConstants.keyProUnlocked, true);
        }
        state = true;
        return;
      }

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

/// The store's price for Pro, formatted for the user's storefront (e.g.
/// "$7.99"), or null when there is none to show. Every `{price}` in the Pro
/// copy reads it; copy without a price drops it ("Unlock Pro").
///
/// Loaded once per process. Null while it loads, and for good in the
/// `direct` flavor (F-Droid, GitHub APK), which sells through bitbag.app.
/// The Pro sheet still loads its own `ProductDetails` for the buy call.
final proPriceProvider = FutureProvider<String?>(
  (ref) => loadProPrice(AppConstants.kFlavor, InAppPurchase.instance),
);

/// The unlock button's label: "Unlock Pro for $7.99" with a [price] from
/// [proPriceProvider], plain "Unlock Pro" without one.
String unlockProLabel(String? price) =>
    price == null ? 'Unlock Pro' : 'Unlock Pro for $price';

/// [proPriceProvider]'s lookup: the `bag_pro` price from [store] in the
/// `store` flavor; null for any other flavor (without asking the store), an
/// unavailable store, a missing product or an empty price, and on any error.
@visibleForTesting
Future<String?> loadProPrice(String flavor, InAppPurchase store) async {
  if (flavor != 'store') return null;
  try {
    if (!await store.isAvailable()) return null;
    final response =
        await store.queryProductDetails({AppConstants.iapProProductId});
    if (response.productDetails.isEmpty) return null;
    final price = response.productDetails.first.price;
    return price.isEmpty ? null : price;
  } catch (e) {
    if (kDebugMode) debugPrint('[IAP] price lookup failed: $e');
    return null;
  }
}
