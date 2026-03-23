import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/btc_format.dart';
import '../../../providers/network_settings_provider.dart';
import '../../../providers/purchase_provider.dart';
import '../../../providers/sentinel_provider.dart';
import '../../../providers/sats_mode_provider.dart';
import '../../../providers/wallets_provider.dart';
import '../../../widgets/pro_gate.dart';

class SentinelScreen extends ConsumerWidget {
  const SentinelScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sentinelState = ref.watch(sentinelProvider);
    final proUnlocked = ref.watch(proUnlockedProvider);
    final useTor = ref.watch(networkSettingsProvider).useTor;
    final cs = Theme.of(context).colorScheme;
    final isEnabled = sentinelState is SentinelEnabled;

    return Scaffold(
      appBar: AppBar(title: const Text('Sentinel')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ────────────────────────────────────────────────────────
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (isEnabled ? AppColors.positive : cs.secondary)
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.shield_outlined,
                    color: isEnabled ? AppColors.positive : cs.secondary,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sentinel',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        isEnabled ? 'Active' : 'Off',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: isEnabled
                                  ? AppColors.positive
                                  : cs.secondary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // ── What Sentinel does ─────────────────────────────────────────────
            Text(
              'Always-on wallet monitoring. Sentinel runs continuously in the '
              'background and sends you an instant alert if any connected '
              'wallet balance changes — whether funds arrive or leave.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(height: 1.5),
            ),

            const SizedBox(height: 12),

            _BulletList(items: const [
              'Scans every ${AppConstants.sentinelScanIntervalMinutes} minutes, even with the app closed',
              'Alerts on any balance change — incoming or outgoing',
              'Tor-aware: waits for Orbot instead of leaking your IP',
              'Restarts automatically after device reboot',
            ]),

            const SizedBox(height: 20),

            // ── Persistent notification notice ─────────────────────────────────
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.outline),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: cs.secondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Android requires a persistent notification for any '
                      'always-on background service. Sentinel shows a silent '
                      'status bar notification while active — it never makes '
                      'a sound unless your balance changes.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(height: 1.5),
                    ),
                  ),
                ],
              ),
            ),

            // ── Orbot Always-On tip (only when Tor is enabled) ────────────────
            if (useTor) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.25)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.security_outlined,
                        size: 16, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(height: 1.5),
                          children: const [
                            TextSpan(
                              text: 'Tor is enabled — two steps for reliability:\n',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            TextSpan(
                              text: '1. Enable Always-On VPN in Orbot: open Orbot → ⋮ → Always-On VPN.\n'
                                  '2. Allow Orbot to run in the background (see tips below).',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // ── Background reliability tips (always visible) ───────────────────
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.4)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.battery_saver_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(height: 1.5),
                        children: const [
                          TextSpan(
                            text: 'Keep Sentinel running\n',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          TextSpan(
                            text:
                                '• Disable battery optimisation for Bag: Settings → Apps → Bag → Battery → Unrestricted.\n'
                                '• Some Android builds have extra background limits — check Settings → Battery, Apps, or Device Care for options like '
                                '"Autostart", "Background activity", "Manage background apps", or "Apps that won\'t sleep" and allow Bag',
                          ),
                          TextSpan(
                            text: ' (and Orbot if using Tor)',
                            style: TextStyle(fontStyle: FontStyle.italic),
                          ),
                          TextSpan(text: '.'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            // ── Enable / disable toggle ────────────────────────────────────────
            ProGate(
              featureName: 'Sentinel',
              child: _EnableCard(
                isEnabled: isEnabled,
                proUnlocked: proUnlocked,
              ),
            ),

            // ── Status section (when enabled) ──────────────────────────────────
            if (sentinelState is SentinelEnabled) ...[
              const SizedBox(height: 24),
              _StatusSection(state: sentinelState),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Enable card ───────────────────────────────────────────────────────────────

class _EnableCard extends ConsumerWidget {
  final bool isEnabled;
  final bool proUnlocked;

  const _EnableCard({required this.isEnabled, required this.proUnlocked});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final wallets = ref.watch(walletsProvider);

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
      ),
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Enable Sentinel'),
            subtitle: Text(
              wallets.isEmpty
                  ? 'Connect a wallet first'
                  : isEnabled
                      ? 'Tap to stop monitoring'
                      : 'Start background monitoring',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            value: isEnabled,
            activeColor: AppColors.primary,
            onChanged: proUnlocked && wallets.isNotEmpty
                ? (v) async {
                    if (v) {
                      final confirmed =
                          await _showDisclosure(context);
                      if (confirmed == true) {
                        await ref
                            .read(sentinelProvider.notifier)
                            .enable();
                      }
                    } else {
                      await ref
                          .read(sentinelProvider.notifier)
                          .disable();
                    }
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Future<bool?> _showDisclosure(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.shield_outlined,
                      color: AppColors.primary, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    'Enable Sentinel?',
                    style: Theme.of(ctx)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Android requires all always-on background services to show '
                'a persistent notification. This is a security requirement '
                '— it means you always know Bag is watching your wallets.',
                style: Theme.of(ctx)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(height: 1.5),
              ),
              const SizedBox(height: 10),
              Text(
                'The notification is completely silent. You can disable '
                'Sentinel here at any time.',
                style: Theme.of(ctx)
                    .textTheme
                    .bodySmall
                    ?.copyWith(height: 1.5),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.black,
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Enable'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Status section ────────────────────────────────────────────────────────────

class _StatusSection extends ConsumerWidget {
  final SentinelEnabled state;

  const _StatusSection({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final wallets = ref.watch(walletsProvider);
    final satsMode = ref.watch(satsModeProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'STATUS',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Last scan time
              Row(
                children: [
                  Icon(Icons.access_time_outlined,
                      size: 14, color: cs.secondary),
                  const SizedBox(width: 6),
                  Text(
                    state.lastScanAt != null
                        ? 'Last scan: ${DateFormat('d MMM HH:mm').format(state.lastScanAt!)}'
                        : 'Waiting for first scan…',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),

              if (wallets.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Divider(height: 1),
                const SizedBox(height: 14),
                // Per-wallet last known balance
                ...wallets.map((wallet) {
                  final lastSats = state.lastBalances[wallet.id];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 14,
                          color: lastSats != null
                              ? AppColors.positive
                              : cs.secondary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            wallet.label,
                            style:
                                Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        Text(
                          lastSats != null
                              ? formatBtcAmount(lastSats / 1e8,
                                  satsMode: satsMode)
                              : 'Pending scan',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Sentinel scans every ${AppConstants.sentinelScanIntervalMinutes} minutes. '
          'Balance figures above are from the last Sentinel scan and may '
          'differ from a manual scan.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: cs.secondary, height: 1.4),
        ),
      ],
    );
  }
}

// ── Bullet list ───────────────────────────────────────────────────────────────

class _BulletList extends StatelessWidget {
  final List<String> items;

  const _BulletList({required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items
          .map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}
