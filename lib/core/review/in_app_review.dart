/// Stub types for `in_app_review` — used by the `direct` flavor so the Play
/// Core review library is never compiled into the F-Droid / website APK.
///
/// For `store` flavor CI builds, the import in
/// `lib/services/review_prompt_service.dart` is swapped to
/// `package:in_app_review/in_app_review.dart` before compilation, exactly like
/// the `in_app_purchase` stub in `lib/core/iap/iap.dart`.
///
/// F-Droid has no ratings and the direct APK has no store to rate on, so the
/// stub simply reports the review flow as unavailable.
library;

class InAppReview {
  InAppReview._();
  static final InAppReview instance = InAppReview._();

  Future<bool> isAvailable() async => false;

  Future<void> requestReview() async {}

  Future<void> openStoreListing({
    String? appStoreId,
    String? microsoftStoreId,
  }) async {}
}
