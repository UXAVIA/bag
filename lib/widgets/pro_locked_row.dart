import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../features/settings/presentation/pro_upgrade_sheet.dart';
import '../providers/purchase_provider.dart';

/// A Pro feature as a free user sees it: what it is, at full opacity, with a
/// lock. The row is the only control and it opens the Pro sheet.
///
/// It describes the feature and never wraps the feature's own widget, so
/// nothing behind it can be operated.
class ProLockedRow extends StatelessWidget {
  const ProLockedRow({super.key, required this.title, required this.body});

  final String title;
  final String body;

  /// The lock icon's accessible name.
  static const lockLabel = 'Locked, part of Pro';

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // One node for a screen reader: title, body and the lock, as a button.
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: () => showProUpgradeSheet(context),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: textTheme.bodyLarge?.copyWith(fontSize: 15),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          body,
                          style: textTheme.bodySmall?.copyWith(
                            color: textTheme.bodyMedium?.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Icon(
                    Icons.lock_outline,
                    size: 16,
                    color: AppColors.primary,
                    semanticLabel: lockLabel,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The guard for an action only Pro may perform: true for a Pro user. For
/// anyone else the action is refused (the caller does nothing) and the Pro
/// sheet opens instead.
///
/// The screens that call it sit behind the router's Pro gate, so a free user
/// should never get there; this is the second line.
bool requirePro(BuildContext context, WidgetRef ref) {
  if (ref.read(proUnlockedProvider)) return true;
  showProUpgradeSheet(context);
  return false;
}
