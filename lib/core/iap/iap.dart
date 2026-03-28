/// Stub types for `in_app_purchase` — used by the `direct` flavor so the
/// billing client and Google Play Services are never compiled into the APK.
///
/// For `store` flavor CI builds, this import is swapped to
/// `package:in_app_purchase/in_app_purchase.dart` before compilation.
library;

import 'dart:async';

// ---------------------------------------------------------------------------
// InAppPurchase
// ---------------------------------------------------------------------------

class InAppPurchase {
  InAppPurchase._();
  static final InAppPurchase instance = InAppPurchase._();

  Stream<List<PurchaseDetails>> get purchaseStream =>
      const Stream.empty();

  Future<void> restorePurchases() async {}

  Future<void> completePurchase(PurchaseDetails purchase) async {}

  Future<void> buyNonConsumable({required PurchaseParam purchaseParam}) async {}

  Future<ProductDetailsResponse> queryProductDetails(
      Set<String> identifiers) async {
    return ProductDetailsResponse(productDetails: []);
  }
}

// ---------------------------------------------------------------------------
// PurchaseDetails
// ---------------------------------------------------------------------------

class PurchaseDetails {
  final String productID;
  final PurchaseStatus status;
  final bool pendingCompletePurchase;
  final IAPError? error;

  PurchaseDetails({
    this.productID = '',
    this.status = PurchaseStatus.error,
    this.pendingCompletePurchase = false,
    this.error,
  });
}

// ---------------------------------------------------------------------------
// PurchaseStatus
// ---------------------------------------------------------------------------

enum PurchaseStatus { purchased, restored, error, pending, canceled }

// ---------------------------------------------------------------------------
// ProductDetails / ProductDetailsResponse
// ---------------------------------------------------------------------------

class ProductDetails {
  final String price;
  ProductDetails({this.price = ''});
}

class ProductDetailsResponse {
  final List<ProductDetails> productDetails;
  ProductDetailsResponse({required this.productDetails});
}

// ---------------------------------------------------------------------------
// PurchaseParam
// ---------------------------------------------------------------------------

class PurchaseParam {
  final ProductDetails productDetails;
  PurchaseParam({required this.productDetails});
}

// ---------------------------------------------------------------------------
// IAPError
// ---------------------------------------------------------------------------

class IAPError {
  final String message;
  IAPError({this.message = ''});

  @override
  String toString() => message;
}
