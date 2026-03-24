import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../features/settings/presentation/pro_upgrade_sheet.dart';
import '../providers/purchase_provider.dart';

/// Wraps a pro feature widget.
///
/// When unlocked: renders [child] normally.
/// When locked:   renders [child] dimmed with an orange lock badge overlay.
///
/// Tapping the locked overlay calls [onLockTap] if provided — use this to
/// open the paywall/upgrade sheet when that exists.
class ProGate extends ConsumerWidget {
  final Widget child;
  final String featureName;
  final VoidCallback? onLockTap;

  const ProGate({
    super.key,
    required this.child,
    required this.featureName,
    this.onLockTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlocked = ref.watch(proUnlockedProvider);
    if (unlocked) return child;

    // ConstrainedBox ensures the Stack is always tall enough to display the
    // lock badge even when the child is empty (e.g. no wallets added yet).
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 130),
      child: Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        IgnorePointer(
          child: Opacity(opacity: 0.35, child: child),
        ),
        Positioned.fill(
          child: GestureDetector(
            onTap: onLockTap ?? () => showProUpgradeSheet(context),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: const BoxDecoration(
                          color: AppColors.primary,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.lock_outline,
                            color: Colors.black, size: 20),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        featureName,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Pro feature',
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
      ),
    );
  }
}
