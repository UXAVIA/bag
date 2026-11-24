import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../providers/purchase_provider.dart';
import '../../../providers/shared_preferences_provider.dart';
import '../../../providers/wallets_provider.dart';

/// Whether the user tapped "Not now" on [HomeWalletCard]. Once true it stays
/// true: the card never comes back.
final homeWalletCardDismissedProvider =
    NotifierProvider<HomeWalletCardDismissedNotifier, bool>(
      HomeWalletCardDismissedNotifier.new,
    );

class HomeWalletCardDismissedNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref
          .read(sharedPreferencesProvider)
          .getBool(AppConstants.keyHomeWalletCardDismissed) ??
      false;

  /// Writes the pref first and hides the card only once it is written, so a
  /// card that has gone can't come back on the next launch. If the write
  /// fails (answers false or throws), the card stays and "Not now" can be
  /// tapped again.
  Future<void> dismiss() async {
    bool saved;
    try {
      saved = await ref
          .read(sharedPreferencesProvider)
          .setBool(AppConstants.keyHomeWalletCardDismissed, true);
    } catch (e) {
      if (kDebugMode) debugPrint('[HomeWalletCard] dismiss not saved: $e');
      return;
    }
    if (!saved) {
      if (kDebugMode) debugPrint('[HomeWalletCard] dismiss not saved');
      return;
    }
    state = true;
  }
}

/// Whether Home shows [HomeWalletCard]: only to a free user with no wallets
/// of any kind (watch-only or typed in) who hasn't dismissed it (ruling
/// R-B4c).
final showHomeWalletCardProvider = Provider<bool>(
  (ref) =>
      !ref.watch(proUnlockedProvider) &&
      ref.watch(walletsProvider.select((wallets) => wallets.isEmpty)) &&
      !ref.watch(homeWalletCardDismissedProvider),
);

/// "Let Bag read your wallet": the watch-only offer for a free user who
/// types their amount in. It sits directly below the net-worth card.
/// "Add a wallet" opens the Wallets tab (the pitch, for a free user); "Not
/// now" dismisses it for good.
class HomeWalletCard extends ConsumerWidget {
  const HomeWalletCard({super.key});

  static const title = 'Let Bag read your wallet';
  static const body =
      'Paste your Bitkey, hardware wallet or multisig public key. Your '
      'balance updates by itself instead of you typing it in.';
  static const addLabel = 'Add a wallet';
  static const notNowLabel = 'Not now';
  static const footnote = 'Part of Bag Pro · read-only, Bag can never spend';

  /// Where the buttons and the footnote start: past the 40 px icon tile and
  /// its 14 px gap, under the title.
  static const _textIndent = 54.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // The theme's button text (its font family), at the drawn size; the
    // buttons' foreground colours set the colour.
    final buttonText = theme.textTheme.labelLarge?.copyWith(fontSize: 14);
    final bodyColor = cs.bodyText;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        // A warm edge that sets the offer apart from the plain cards.
        border: Border.all(
          color: Color.alphaBlend(
            cs.primary.withValues(alpha: 0.2),
            cs.surface,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.account_balance_wallet_outlined,
                    color: cs.primary,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      body,
                      style: TextStyle(
                        color: bodyColor,
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // The buttons are 40 px tall, drawn as such, inside 48 px tap
          // targets: 8 + 4 px of target padding make the drawn 12 px gap.
          const SizedBox(height: 8),
          Container(
            // Full width, so "Not now" sits at the right edge as drawn; a
            // Wrap on its own shrinks to its children. At large text it
            // drops below the button instead of overflowing.
            width: double.infinity,
            padding: const EdgeInsets.only(left: _textIndent),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () => context.go('/wallets'),
                  style: FilledButton.styleFrom(
                    backgroundColor: cs.primary,
                    foregroundColor: cs.onPrimary,
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    textStyle: buttonText?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(addLabel),
                ),
                TextButton(
                  onPressed: () => ref
                      .read(homeWalletCardDismissedProvider.notifier)
                      .dismiss(),
                  style: TextButton.styleFrom(
                    foregroundColor: cs.secondary,
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: buttonText?.copyWith(
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  child: const Text(notNowLabel),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: _textIndent),
            child: Text(
              footnote,
              style: TextStyle(color: cs.secondary, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
