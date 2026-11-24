import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps a secret that is on screen (an xpub, a descriptor, the licence key)
/// out of screenshots and the app-switcher snapshot.
///
/// - Android: FLAG_SECURE through `setSecureMode` on the
///   `app.bitbag/widget` channel, for the dialog's lifetime.
/// - iOS answers `setSecureMode` with a no-op. Instead [isShown] is true
///   while the dialog is open, and `BagApp` covers the whole app with its
///   opaque privacy overlay on `AppLifecycleState.inactive`, which is when
///   iOS takes the snapshot (M-15).
///
/// Every secret dialog goes through [guard]; nothing else calls
/// `setSecureMode`.
class SecretOnScreen {
  SecretOnScreen._();

  static const _channel = MethodChannel('app.bitbag/widget');

  static int _depth = 0;
  static final ValueNotifier<bool> _shown = ValueNotifier(false);

  /// Whether a secret dialog is open.
  static ValueListenable<bool> get isShown => _shown;

  /// Forgets any guard a failed test left open.
  @visibleForTesting
  static void debugReset() {
    _depth = 0;
    _shown.value = false;
  }

  /// Runs [show] (which shows the secret and completes when it is gone)
  /// with secure mode on and [isShown] true. Both are undone in `finally`,
  /// so a dialog that throws leaves neither behind.
  static Future<T> guard<T>(Future<T> Function() show) async {
    _depth++;
    _shown.value = true;
    try {
      await _channel.invokeMethod('setSecureMode', {'secure': true});
      return await show();
    } finally {
      _depth--;
      if (_depth == 0) {
        _shown.value = false;
        try {
          await _channel.invokeMethod('setSecureMode', {'secure': false});
        } catch (_) {
          // Left on, FLAG_SECURE only blocks screenshots: the safe side.
        }
      }
    }
  }
}
