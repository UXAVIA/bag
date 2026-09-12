import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/review/in_app_review.dart';

/// Asks for a store rating exactly once, at a moment the user is pleased.
///
/// Two triggers, whichever comes first:
///   • the first successful watch-only wallet scan (a Pro user has just seen
///     their cold-storage balance appear) — but never on the very first day
///     the app is used;
///   • the third distinct day the home screen shows a net worth (free users
///     who keep coming back).
///
/// The "asked" flag is written *before* the OS sheet is requested, so a
/// throttled or silently-dropped sheet (both stores rate-limit the prompt)
/// never leads to a second ask. No rating ever happens on first launch.
///
/// In the `direct` flavor the review client is a stub that reports itself
/// unavailable, so the flag is still set but nothing is shown.
class ReviewPromptService {
  ReviewPromptService._();

  static const keyAsked = 'review_prompt_asked';
  static const keyHomeDays = 'review_prompt_home_days';

  /// Distinct days with holdings on the home screen before the free-tier ask.
  static const homeDaysBeforeAsk = 3;

  /// Delay after the home screen appears, so the sheet never lands on top of
  /// the splash → home transition. Overridable for tests.
  @visibleForTesting
  static Duration homeAskDelay = const Duration(seconds: 4);

  /// Overridable for tests.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// Record that the home screen is showing (with or without a net worth) and
  /// ask if this is the [homeDaysBeforeAsk]-th distinct day with holdings.
  static Future<void> onHomeShown({required bool hasHoldings}) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(keyAsked) ?? false) return;
    if (!hasHoldings) return;

    final days = _recordToday(prefs);
    await prefs.setStringList(keyHomeDays, days);
    if (days.length < homeDaysBeforeAsk) return;

    await Future<void>.delayed(homeAskDelay);
    await _ask(prefs);
  }

  /// A watch-only wallet scan just completed with a non-zero balance.
  static Future<void> afterSuccessfulWalletScan() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(keyAsked) ?? false) return;

    // Never on the first day: the day list only gains today's entry when the
    // home screen is shown with holdings, so a wallet added on day one finds
    // either nothing or only today here.
    final days = prefs.getStringList(keyHomeDays) ?? const [];
    final today = _dayKey(clock());
    if (days.where((d) => d != today).isEmpty) return;

    await _ask(prefs);
  }

  static Future<void> _ask(SharedPreferences prefs) async {
    // Mark first — the OS may throttle the sheet and we must not ask twice.
    await prefs.setBool(keyAsked, true);
    try {
      final review = InAppReview.instance;
      if (!await review.isAvailable()) return;
      await review.requestReview();
    } catch (e) {
      if (kDebugMode) debugPrint('[Review] request failed: $e');
    }
  }

  static List<String> _recordToday(SharedPreferences prefs) {
    final days = List<String>.from(prefs.getStringList(keyHomeDays) ?? const []);
    final today = _dayKey(clock());
    if (!days.contains(today)) days.add(today);
    return days;
  }

  static String _dayKey(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}
