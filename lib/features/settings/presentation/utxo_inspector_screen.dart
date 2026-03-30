import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/btc_format.dart';
import '../../../models/chain_analysis.dart';
import '../../../providers/health_check_provider.dart';
import '../../../providers/sats_mode_provider.dart';
import '../../../widgets/privacy_score_sheet.dart';

class UtxoInspectorScreen extends ConsumerWidget {
  const UtxoInspectorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final checkState = ref.watch(portfolioHealthCheckProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Portfolio Health Check'),
      ),
      body: switch (checkState) {
        HealthCheckRunning(:final done, :final total) =>
          _RunningView(done: done, total: total),
        HealthCheckDone(:final result) => _ResultView(result: result),
        HealthCheckError(:final message) => _ErrorView(message: message),
        HealthCheckIncomplete() => const _IncompleteView(),
        HealthCheckIdle() => const _IdleView(),
      },
    );
  }
}

// ── State views ───────────────────────────────────────────────────────────────

class _IdleView extends ConsumerWidget {
  const _IdleView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.health_and_safety_outlined,
                size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              'Bitcoin Health Check',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Analyses all your wallets together for address reuse, dust, '
              'mixed address types, and detects coinjoined outputs.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () =>
                  ref.read(portfolioHealthCheckProvider.notifier).run(),
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Run Health Check'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.black,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IncompleteView extends ConsumerWidget {
  const _IncompleteView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_outlined,
                size: 56, color: Colors.amber.shade600),
            const SizedBox(height: 16),
            Text('Check interrupted',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'The previous check was interrupted. Run it again to get your results.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () =>
                  ref.read(portfolioHealthCheckProvider.notifier).run(),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Restart Health Check'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.black,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RunningView extends StatelessWidget {
  final int done;
  final int total;
  const _RunningView({required this.done, required this.total});

  @override
  Widget build(BuildContext context) {
    final pct = total > 0 ? done / total : 0.0;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                  color: AppColors.primary, strokeWidth: 3),
            ),
            const SizedBox(height: 20),
            Text('Running Health Check…',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: pct,
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 8),
            Text(
              total > 0 ? '$done / $total fetched' : 'Starting…',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends ConsumerWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 56, color: AppColors.negative),
            const SizedBox(height: 16),
            Text('Check failed',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(message,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () =>
                  ref.read(portfolioHealthCheckProvider.notifier).run(),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try Again'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.black,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Result view ───────────────────────────────────────────────────────────────

class _ResultView extends ConsumerWidget {
  final ChainAnalysisResult result;
  const _ResultView({required this.result});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final satsMode = ref.watch(satsModeProvider);
    final score = result.score;
    final coinjoined = result.utxos.where((u) => u.isCoinjoined).toList();
    final regular = result.utxos.where((u) => !u.isCoinjoined).toList();
    final reusedAddrs = result.utxos
        .where((u) => u.flags.contains(UtxoRiskFlag.addressReused))
        .map((u) => u.address)
        .toSet();

    return CustomScrollView(
      slivers: [
        // Score summary card
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: _ScoreSummaryCard(
              result: result,
              onViewBreakdown: () => showPrivacyScoreSheet(context, result),
            ),
          ),
        ),

        // Reuse warning banner
        if (reusedAddrs.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: Colors.amber.withValues(alpha: 0.4)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_outlined,
                        size: 16, color: Colors.amber.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${reusedAddrs.length} address${reusedAddrs.length == 1 ? '' : 'es'} '
                        'used more than once. Avoid spending these UTXOs together '
                        'to prevent linking your transactions.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // Coinjoined section
        if (coinjoined.isNotEmpty) ...[
          _SliverSectionHeader(
            label: 'COINJOINED OUTPUTS (${coinjoined.length})',
            trailing: 'Enhanced privacy',
            trailingColor: AppColors.positive,
          ),
          SliverList.builder(
            itemCount: coinjoined.length,
            itemBuilder: (_, i) =>
                _UtxoRow(utxo: coinjoined[i], satsMode: satsMode),
          ),
        ],

        // Regular UTXOs section
        _SliverSectionHeader(
          label: score.totalUtxos == 0
              ? 'NO UTXOS'
              : 'UTXOS (${regular.length})',
        ),

        if (regular.isEmpty && coinjoined.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              child: Text(
                'No UTXOs found. These wallets have no unspent outputs.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: regular.length,
            itemBuilder: (_, i) =>
                _UtxoRow(utxo: regular[i], satsMode: satsMode),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }
}

// ── Score summary card ────────────────────────────────────────────────────────

class _ScoreSummaryCard extends ConsumerWidget {
  final ChainAnalysisResult result;
  final VoidCallback onViewBreakdown;

  const _ScoreSummaryCard({
    required this.result,
    required this.onViewBreakdown,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final score = result.score;
    final scoreColor = AppColors.scoreColor(score.score);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
      ),
      child: Row(
        children: [
          // Score circle
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: scoreColor, width: 3),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${score.score}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: scoreColor,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                ),
                Text(
                  AppColors.scoreLetter(score.score),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scoreColor,
                        fontWeight: FontWeight.w600,
                        height: 1,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),

          // Stats
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Privacy Score',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  _buildStatLine(score, result.walletCount),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        label: 'Breakdown',
                        icon: Icons.info_outline,
                        onTap: onViewBreakdown,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ActionButton(
                        label: 'Re-run',
                        icon: Icons.refresh,
                        onTap: () =>
                            ref.read(portfolioHealthCheckProvider.notifier).run(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _buildStatLine(PrivacyScore score, int walletCount) {
    final parts = <String>[];
    parts.add('${score.totalUtxos} UTXOs');
    parts.add('$walletCount wallet${walletCount == 1 ? '' : 's'}');
    if (score.coinjoinedCount > 0) {
      parts.add('${score.coinjoinedCount} coinjoined');
    }
    if (score.reusedAddressCount > 0) {
      parts.add('${score.reusedAddressCount} reused addr');
    }
    if (score.dustCount > 0) {
      parts.add('${score.dustCount} dust');
    }
    return parts.join(' · ');
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(
              color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 13,
                color: Theme.of(context).colorScheme.secondary),
            const SizedBox(width: 4),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── UTXO row ──────────────────────────────────────────────────────────────────

class _UtxoRow extends StatelessWidget {
  final AnalysedUtxo utxo;
  final bool satsMode;

  const _UtxoRow({required this.utxo, required this.satsMode});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Coinjoin shield
                if (utxo.isCoinjoined)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, top: 1),
                    child: Icon(Icons.shield,
                        size: 16, color: AppColors.positive),
                  ),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Amount
                      Text(
                        formatBtcAmount(
                          utxo.raw.valueSats / 1e8,
                          satsMode: satsMode,
                        ),
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      // Address (truncated)
                      Text(
                        _truncateAddress(utxo.address),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                      ),
                      const SizedBox(height: 2),
                      // Block height / confirmation
                      Text(
                        utxo.raw.blockHeight != null
                            ? 'Block ${utxo.raw.blockHeight}'
                            : 'Unconfirmed',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: utxo.raw.blockHeight == null
                                  ? Colors.amber.shade600
                                  : cs.secondary,
                            ),
                      ),
                      // Risk flag chips
                      if (utxo.flags.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 4,
                          children: [
                            for (final flag in utxo.flags)
                              _FlagChip(flag: flag),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: cs.outline.withValues(alpha: 0.5)),
        ],
      ),
    );
  }

  static String _truncateAddress(String addr) {
    if (addr.length <= 20) return addr;
    return '${addr.substring(0, 10)}…${addr.substring(addr.length - 10)}';
  }
}

class _FlagChip extends StatelessWidget {
  final UtxoRiskFlag flag;
  const _FlagChip({required this.flag});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (flag) {
      UtxoRiskFlag.addressReused => ('Reused', Colors.amber.shade700),
      UtxoRiskFlag.dust => ('Dust', Colors.grey),
      UtxoRiskFlag.mixedType => ('Mixed type', Colors.orange),
      UtxoRiskFlag.roundAmount => ('Round amt', Colors.blue.shade400),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 10,
              color: color,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

// ── Section header ────────────────────────────────────────────────────────────

class _SliverSectionHeader extends StatelessWidget {
  final String label;
  final String? trailing;
  final Color? trailingColor;

  const _SliverSectionHeader({
    required this.label,
    this.trailing,
    this.trailingColor,
  });

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Row(
          children: [
            Flexible(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (trailing != null) ...[
              const Spacer(),
              Text(
                trailing!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: trailingColor,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────
