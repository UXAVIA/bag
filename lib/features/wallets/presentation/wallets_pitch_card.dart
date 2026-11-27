import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../providers/purchase_provider.dart';
import '../../settings/presentation/pro_upgrade_sheet.dart';

/// The Wallets tab's lead for a free user: what watch-only wallets do, shown
/// on a made-up portfolio, and the way to Pro. Both actions open the Pro
/// sheet; nothing on the card touches a wallet.
class WalletsPitchCard extends ConsumerWidget {
  const WalletsPitchCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final price = ref.watch(proPriceProvider).valueOrNull;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _ExampleFigure(),
          const SizedBox(height: 14),
          Text(
            'Let Bag read your wallets',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Add a public key or multisig descriptor once. Bag keeps every '
            'balance current, and Bag can never spend.',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: () => showProUpgradeSheet(context),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                unlockProLabel(price),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: TextButton(
              onPressed: () => showProUpgradeSheet(context),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                minimumSize: const Size(48, 44),
              ),
              child: const Text('See everything Pro includes'),
            ),
          ),
        ],
      ),
    );
  }
}

/// A static illustration: three holdings adding up to a net worth. The
/// numbers are not the user's; a screen reader hears what it is instead.
class _ExampleFigure extends StatelessWidget {
  const _ExampleFigure();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final secondary = theme.textTheme.bodyMedium?.color;

    return Semantics(
      label: 'Example: three wallets adding up to your net worth',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ExampleRow(name: 'Bitkey', detail: '2-of-3', amount: '0.5000'),
              const SizedBox(height: 7),
              _ExampleRow(name: 'Coldcard', amount: '0.2100'),
              const SizedBox(height: 7),
              _ExampleRow(
                name: 'Kraken',
                detail: 'typed in',
                amount: '0.0424',
                typedIn: true,
              ),
              const SizedBox(height: 8),
              Divider(height: 1, color: cs.outline),
              const SizedBox(height: 8),
              // At large text on a narrow phone the total shrinks to fit and
              // the caption wraps, right-aligned; at 1.0× both sit as drawn.
              LayoutBuilder(
                builder: (context, constraints) => Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * 0.6,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '\$71,482',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'looked up over Tor',
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: secondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExampleRow extends StatelessWidget {
  const _ExampleRow({
    required this.name,
    required this.amount,
    this.detail,
    this.typedIn = false,
  });

  final String name;
  final String? detail;
  final String amount;

  /// A balance typed in by hand rather than read from a wallet: hollow dot.
  final bool typedIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = theme.textTheme.bodyMedium?.color;
    final style = theme.textTheme.bodyLarge?.copyWith(fontSize: 14);

    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: typedIn ? null : AppColors.primary,
            border: typedIn
                ? Border.all(color: secondary ?? Colors.grey, width: 1.5)
                : null,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(
              text: name,
              children: [
                if (detail != null)
                  TextSpan(
                    text: ' $detail',
                    style: TextStyle(color: secondary),
                  ),
              ],
            ),
            style: style,
          ),
        ),
        Text(
          amount,
          style: style?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
