import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/btc_format.dart';
import '../../../core/utils/secret_on_screen.dart';
import '../../../models/chain_analysis.dart';
import '../../../models/network_route.dart';
import '../../../models/network_settings.dart';
import '../../../models/wallet_entry.dart';
import '../../../providers/health_check_provider.dart';
import '../../../providers/network_settings_provider.dart';
import '../../../providers/purchase_provider.dart';
import '../../../providers/route_status_provider.dart';
import '../../../providers/sats_mode_provider.dart';
import '../../../providers/sentinel_provider.dart';
import '../../../providers/shared_preferences_provider.dart';
import '../../../providers/wallets_provider.dart';
import '../../../services/embedded_tor_service.dart';
import '../../../services/network/explorer_url.dart';
import '../../../services/network/route_gate.dart';
import '../../../services/network/routed_http.dart';
import '../../../services/sentinel_service.dart';
import '../../../services/tor_service.dart';
import '../../../services/wallet/biometric_storage_service.dart';
import '../../../widgets/privacy_score_sheet.dart';
import '../../../widgets/pro_locked_row.dart';
import '../../../widgets/route_status_pill.dart';
import '../../../widgets/section_header.dart';
import '../../../widgets/wallet_section.dart';
import '../../settings/presentation/proxy_section.dart';
import '../../settings/presentation/sentinel_screen.dart';
import 'wallets_pitch_card.dart';

/// The Wallets tab (`/wallets`).
///
/// Everything on it is Pro, so it has two layouts, and only the Pro one
/// contains a Pro control:
/// - free: a switch-off row for each Pro feature still in use (R-B2g), which
///   can only turn it off or remove it; then [WalletsPitchCard] and an "Also
///   in Pro" list of [ProLockedRow]s, each of which opens the Pro sheet. The
///   Tor card, the proxy form, the explorer picker, the wallet list and the
///   Watching cards are not in the tree at all.
/// - Pro: the sections Wallets, Network and Watching.
class WalletsScreen extends ConsumerWidget {
  const WalletsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proUnlocked = ref.watch(proUnlockedProvider);

    return Scaffold(
      appBar: AppBar(
        // The heading and, at the other end, the connection pill, in both
        // layouts. The pill may take up to 60% of the bar; at large text the
        // heading gives way first.
        title: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              const Expanded(child: Text('Wallets')),
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * 0.6,
                ),
                child: const RouteStatusPill(),
              ),
            ],
          ),
        ),
      ),
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        child: proUnlocked ? const _ProLayout() : const _FreeLayout(),
      ),
    );
  }
}

// ── Free layout ───────────────────────────────────────────────────────────────

class _FreeLayout extends ConsumerWidget {
  const _FreeLayout();

  /// The preset a fresh install gets: `NetworkSettingsNotifier.build` and
  /// `resolveExplorerBaseUrl` both fall back to index 0.
  static final _defaultPreset = ExplorerPreset.values.first;

  static const _offBody =
      'Part of Pro. You can switch it off; switching it back on needs Pro.';

  /// Removes [entries] one by one through the usual path
  /// (`WalletsNotifier.removeWallet`), which deletes each one's secret and
  /// metadata and updates net worth.
  static Future<void> _remove(WidgetRef ref, List<WalletEntry> entries) async {
    final notifier = ref.read(walletsProvider.notifier);
    for (final w in entries) {
      await notifier.removeWallet(w.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(networkSettingsProvider);
    final wallets = ref.watch(walletsProvider);
    final watchOnly = wallets.where((w) => w.isWatchOnly).toList();
    final typedIn = wallets.where((w) => !w.isWatchOnly).toList();
    final route = settings.route;

    // R-B2g: a Pro feature left on after Pro went away (an unreadable
    // licence, say) is never downgraded silently and never a dead end. A
    // free user can switch it off here; only Pro switches it back on.
    final walletRows = [
      if (watchOnly.isNotEmpty)
        _SwitchOffRow(
          title: 'Your watch-only wallets are kept',
          body: 'Their balances stopped updating. Live balances are part of '
              'Pro.',
          action: 'Remove wallets',
          dialogTitle: 'Remove watch-only wallets?',
          dialogBody: 'Bag deletes their public keys and descriptors from '
              'this device. Your coins are not affected.',
          confirm: 'Remove',
          // Manual entries stay.
          onConfirm: () => _remove(ref, watchOnly),
        ),
      // They keep counting toward net worth and hide Settings' amount field,
      // so without this a free user could never type a total again.
      if (typedIn.isNotEmpty)
        _SwitchOffRow(
          title: 'Your typed-in balances are kept',
          body: 'They still count toward your net worth. Adding or editing '
              'them is part of Pro.',
          action: 'Remove',
          dialogTitle: 'Remove typed-in balances?',
          // Settings takes a typed total only once no wallet is left.
          dialogBody: watchOnly.isEmpty
              ? 'Bag deletes them from this device. You can then type your '
                  'total in Settings.'
              : 'Bag deletes them from this device.',
          confirm: 'Remove',
          onConfirm: () => _remove(ref, typedIn),
        ),
    ];
    final networkRows = [
      if (route is TorRoute)
        _SwitchOffRow(
          title: 'Tor is on',
          body: _offBody,
          action: 'Switch off',
          dialogTitle: 'Switch Tor off?',
          dialogBody: 'Prices will then be fetched directly, without Tor.',
          confirm: 'Switch off',
          onConfirm: () =>
              ref.read(networkSettingsProvider.notifier).setUseTor(false),
        ),
      if (route is ProxyRoute || route is MisconfiguredProxyRoute)
        _SwitchOffRow(
          title: route is MisconfiguredProxyRoute
              ? 'Custom proxy is on, but its settings could not be read'
              : 'Custom proxy is on',
          body: _offBody,
          action: 'Switch off',
          dialogTitle: 'Switch the proxy off?',
          dialogBody:
              'Prices will then be fetched directly, without your proxy.',
          confirm: 'Switch off',
          // Off, not cleared: the saved proxy is kept in case Pro returns.
          onConfirm: () =>
              ref.read(networkSettingsProvider.notifier).setUseProxy(false),
        ),
      // Only wallet scans use the explorer.
      if (settings.preset == ExplorerPreset.custom && watchOnly.isNotEmpty)
        _SwitchOffRow(
          title: 'Your own node is selected',
          body: 'Part of Pro. You can switch back to the default explorer.',
          action: 'Use default',
          dialogTitle: 'Use the default explorer?',
          dialogBody: 'If you get Pro back, wallet scans will use the default '
              'explorer instead of your node.',
          confirm: 'Use default',
          onConfirm: () => ref
              .read(networkSettingsProvider.notifier)
              .setPreset(_defaultPreset),
        ),
    ];
    final proRows = [
      const ProLockedRow(
        title: 'Route through Tor',
        body: 'Built in, no other app needed',
      ),
      const ProLockedRow(title: 'Custom proxy', body: 'SOCKS5 or HTTP'),
      const ProLockedRow(
        title: 'Your own node',
        body: 'Any Esplora server, including .onion',
      ),
      const ProLockedRow(
        title: 'Bitcoin Health Check',
        body: 'A privacy score for your coins',
      ),
      if (SentinelService.isSupported)
        SentinelService.isAlwaysOn
            ? const ProLockedRow(
                title: 'Sentinel',
                body: 'Notifies you when a payment touches a wallet',
              )
            // iOS: Sentinel Lite (spec D9).
            : const ProLockedRow(
                title: 'Sentinel Lite',
                body: 'Alerts for your wallets, when iOS allows',
              ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A tap on the connection pill from another tab scrolls back to the
        // top.
        const WalletsScrollAnchor(
          anchor: WalletsAnchor.top,
          child: SizedBox.shrink(),
        ),
        if (walletRows.isNotEmpty) ...[
          const SectionHeader(label: 'Wallets'),
          const SizedBox(height: 8),
          _RowCard(rows: walletRows),
          const SizedBox(height: 24),
        ],
        if (networkRows.isNotEmpty) ...[
          const SectionHeader(label: 'Network'),
          const SizedBox(height: 8),
          _RowCard(rows: networkRows),
          const SizedBox(height: 24),
        ],
        const WalletsPitchCard(),
        const SizedBox(height: 24),
        const SectionHeader(label: 'Also in Pro'),
        const SizedBox(height: 8),
        _RowCard(rows: proRows),
      ],
    );
  }
}

/// Rows in one bordered card, divided by hairlines.
class _RowCard extends StatelessWidget {
  const _RowCard({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outline),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: cs.outline),
            rows[i],
          ],
        ],
      ),
    );
  }
}

/// A Pro feature still on for a free user, with the one thing they may do:
/// switch it off (or remove it), after a confirmation. A button and a
/// dialog, never a switch, so nothing here can turn a Pro feature on.
class _SwitchOffRow extends StatelessWidget {
  const _SwitchOffRow({
    required this.title,
    required this.body,
    required this.action,
    required this.dialogTitle,
    required this.dialogBody,
    required this.confirm,
    required this.onConfirm,
  });

  final String title;
  final String body;
  final String action;
  final String dialogTitle;
  final String dialogBody;
  final String confirm;
  final Future<void> Function() onConfirm;

  Future<void> _confirmAndRun(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(dialogTitle),
        content: Text(dialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirm),
          ),
        ],
      ),
    );
    if (confirmed == true) await onConfirm();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      // The action may take up to 45% of the row: at large text on a narrow
      // phone its label wraps instead of pushing the row past the edge.
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: textTheme.bodyLarge?.copyWith(fontSize: 15)),
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
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * 0.45,
              ),
              child: TextButton(
                onPressed: () => _confirmAndRun(context),
                style: TextButton.styleFrom(foregroundColor: AppColors.primary),
                child: Text(action, textAlign: TextAlign.center),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Pro layout ────────────────────────────────────────────────────────────────

class _ProLayout extends ConsumerWidget {
  const _ProLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallets = ref.watch(walletsProvider);
    // The health check is only meaningful when there is something on-chain
    // to analyse.
    final showHealthCheck = wallets.any((w) => w.isWatchOnly);
    final showSentinel = SentinelService.isSupported;
    final bodyStyle = Theme.of(context).textTheme.bodyMedium;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── WALLETS ─────────────────────────────────────────────────────────
        const SectionHeader(label: 'Wallets'),
        const SizedBox(height: 4),
        Text(
          'Mix watch-only wallets — single-sig zpubs and multisig '
          'descriptors — with amounts you hold elsewhere, such as on an '
          'exchange. Everything adds up into one net worth.',
          style: bodyStyle,
        ),
        const SizedBox(height: 12),
        ...wallets.map((w) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _WalletCard(wallet: w),
            )),
        const AddWalletForm(),
        if (wallets.length > 1) ...[
          const SizedBox(height: 10),
          _PortfolioTotalRow(wallets: wallets),
        ],
        const SizedBox(height: 16),

        // ── NETWORK ─────────────────────────────────────────────────────────
        // Where the connection pill scrolls to. The anchor takes 16 px of
        // the gap above the heading, so the heading doesn't land flush
        // against the app bar.
        const WalletsScrollAnchor(
          anchor: WalletsAnchor.network,
          child: Padding(
            padding: EdgeInsets.only(top: 16),
            child: SectionHeader(label: 'Network'),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Route queries privately via Tor or your own proxy, or point to your own node.',
          style: bodyStyle,
        ),
        const SizedBox(height: 12),
        const _TorSection(),
        const SizedBox(height: 16),
        const ProxySection(),
        const SizedBox(height: 16),
        const _ExplorerSelector(),

        // ── WATCHING ────────────────────────────────────────────────────────
        if (showHealthCheck || showSentinel) ...[
          const SizedBox(height: 32),
          const SectionHeader(label: 'Watching'),
          if (showHealthCheck) ...[
            const SizedBox(height: 4),
            Text(
              'Privacy score and UTXO analysis across all connected wallets',
              style: bodyStyle,
            ),
            const SizedBox(height: 12),
            const _PortfolioHealthCard(),
          ],
          // Sentinel on Android, Sentinel Lite on iOS.
          if (showSentinel) ...[
            SizedBox(height: showHealthCheck ? 20 : 4),
            Text(
              SentinelService.isAlwaysOn
                  ? 'Always-on balance monitoring with instant alerts on any movement.'
                  : 'Background checks with alerts on any movement, when iOS '
                      'allows.',
              style: bodyStyle,
            ),
            const SizedBox(height: 12),
            const _SentinelCard(),
          ],
        ],
      ],
    );
  }
}

// ── Portfolio total ───────────────────────────────────────────────────────────

class _PortfolioTotalRow extends ConsumerWidget {
  final List<WalletEntry> wallets;

  const _PortfolioTotalRow({required this.wallets});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final satsMode = ref.watch(satsModeProvider);
    final totalSats = wallets.fold<int>(0, (s, w) => s + (w.lastSats ?? 0));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Text(
            'Total across ${wallets.length} holdings',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Spacer(),
          Text(
            formatBtcAmount(totalSats / 1e8, satsMode: satsMode),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

// ── Wallet card ───────────────────────────────────────────────────────────────

class _WalletCard extends ConsumerWidget {
  final WalletEntry wallet;

  const _WalletCard({required this.wallet});

  IconData get _icon => switch (wallet.kind) {
        WalletKind.zpub => Icons.account_balance_wallet_outlined,
        WalletKind.descriptor => Icons.workspaces_outline,
        WalletKind.manual => Icons.savings_outlined,
      };

  /// Second line under the label: what this entry actually is.
  String get _kindLabel => switch (wallet.kind) {
        WalletKind.zpub => 'Watch-only · single-sig',
        WalletKind.descriptor =>
          'Watch-only · ${wallet.descriptorSummary ?? 'multisig'}',
        WalletKind.manual => 'Manually tracked · not on-chain',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final satsMode = ref.watch(satsModeProvider);
    final notifier = ref.read(walletsProvider.notifier);
    final isManual = wallet.kind == WalletKind.manual;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: wallet.scanError != null
              ? AppColors.negative.withValues(alpha: 0.4)
              : cs.outline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: icon + label + kind + menu
          Row(
            children: [
              Icon(
                _icon,
                color: wallet.lastSats != null
                    ? AppColors.positive
                    : AppColors.primary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      wallet.label,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    Text(
                      _kindLabel,
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              _WalletMenu(wallet: wallet),
            ],
          ),
          const SizedBox(height: 10),

          // Balance
          if (wallet.lastSats != null) ...[
            Text(
              formatBtcAmount(wallet.btcAmount, satsMode: satsMode),
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              isManual
                  ? '${NumberFormat.decimalPattern().format(wallet.lastSats)} sats'
                  : '${NumberFormat.decimalPattern().format(wallet.lastSats)} sats'
                      '  ·  ${wallet.usedAddresses} addresses',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (wallet.lastScanAt != null) ...[
              const SizedBox(height: 2),
              Text(
                isManual
                    ? 'Updated ${DateFormat('d MMM HH:mm').format(wallet.lastScanAt!)}'
                    : 'Last scanned ${DateFormat('d MMM HH:mm').format(wallet.lastScanAt!)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ] else
            Text(
              isManual ? 'No amount set' : 'Not yet scanned',
              style: Theme.of(context).textTheme.bodySmall,
            ),

          // Scan progress
          if (wallet.isScanning) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.primary),
                ),
                const SizedBox(width: 8),
                Text(
                  'Scanning address ${wallet.scanProgress}…',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],

          // Error
          if (wallet.scanError != null && !wallet.isScanning) ...[
            const SizedBox(height: 6),
            Text(
              wallet.scanError!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.negative),
            ),
          ],

          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: wallet.isScanning
                ? null
                : isManual
                    ? () => showEditManualAmountDialog(context, ref, wallet)
                    : () => notifier.scan(wallet.id),
            icon: Icon(isManual ? Icons.edit_outlined : Icons.refresh, size: 16),
            label: Text(isManual
                ? 'Edit Amount'
                : wallet.isScanning
                    ? 'Scanning…'
                    : 'Scan Now'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.black,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Portfolio health check card ───────────────────────────────────────────────

class _PortfolioHealthCard extends ConsumerWidget {
  const _PortfolioHealthCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final checkState = ref.watch(portfolioHealthCheckProvider);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
      ),
      child: switch (checkState) {
        HealthCheckIdle() => _buildTrigger(context, ref, isIncomplete: false),
        HealthCheckIncomplete() =>
          _buildTrigger(context, ref, isIncomplete: true),
        HealthCheckRunning(:final done, :final total) =>
          _buildProgress(context, done: done, total: total),
        HealthCheckDone(:final result) => _buildResult(context, ref, result),
        HealthCheckError(:final message) =>
          _buildError(context, ref, message),
      },
    );
  }

  Widget _buildTrigger(BuildContext context, WidgetRef ref,
      {required bool isIncomplete}) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.health_and_safety_outlined, size: 16, color: cs.secondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            isIncomplete
                ? 'Portfolio check was interrupted'
                : 'Portfolio Health Check',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        TextButton(
          onPressed: () =>
              ref.read(portfolioHealthCheckProvider.notifier).run(),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            isIncomplete ? 'Restart' : 'Run Check',
            style: const TextStyle(fontSize: 12, color: AppColors.primary),
          ),
        ),
      ],
    );
  }

  Widget _buildProgress(BuildContext context,
      {required int done, required int total}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.primary),
            ),
            const SizedBox(width: 8),
            Text(
              total > 0
                  ? 'Portfolio Health Check — $done / $total'
                  : 'Portfolio Health Check — starting…',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        if (total > 0) ...[
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: done / total,
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(2),
            minHeight: 3,
          ),
        ],
      ],
    );
  }

  Widget _buildResult(
      BuildContext context, WidgetRef ref, ChainAnalysisResult result) {
    final score = result.score;
    final scoreColor = AppColors.scoreColor(score.score);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Top row: icon + score chip + stats + re-run
        Row(
          children: [
            Icon(Icons.health_and_safety_outlined,
                size: 16, color: scoreColor),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: scoreColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border:
                    Border.all(color: scoreColor.withValues(alpha: 0.4)),
              ),
              child: Text(
                '${score.score} ${AppColors.scoreLetter(score.score)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scoreColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${score.totalUtxos} UTXOs · ${result.walletCount} wallet${result.walletCount == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              onPressed: () =>
                  ref.read(portfolioHealthCheckProvider.notifier).run(),
              icon: const Icon(Icons.refresh, size: 14),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              color: Theme.of(context).colorScheme.secondary,
              tooltip: 'Re-run portfolio health check',
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: () =>
                  ref.read(portfolioHealthCheckProvider.notifier).clear(),
              icon: const Icon(Icons.close, size: 14),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              color: Theme.of(context).colorScheme.secondary,
              tooltip: 'Clear result',
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Breakdown + Inspector buttons
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => showPrivacyScoreSheet(context, result),
                icon: const Icon(Icons.bar_chart, size: 15),
                label: const Text('Breakdown'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12),
                  side: BorderSide(
                      color: scoreColor.withValues(alpha: 0.6)),
                  foregroundColor: scoreColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => context.push('/wallets/health-check'),
                icon: const Icon(Icons.list_alt_outlined, size: 15),
                label: const Text('UTXOs'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildError(
      BuildContext context, WidgetRef ref, String message) {
    return Row(
      children: [
        Icon(Icons.error_outline, size: 16, color: AppColors.negative),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.negative),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(
          onPressed: () =>
              ref.read(portfolioHealthCheckProvider.notifier).run(),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Retry',
              style: TextStyle(fontSize: 12, color: AppColors.primary)),
        ),
        IconButton(
          onPressed: () =>
              ref.read(portfolioHealthCheckProvider.notifier).clear(),
          icon: const Icon(Icons.close, size: 14),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          color: Theme.of(context).colorScheme.secondary,
          tooltip: 'Dismiss',
        ),
      ],
    );
  }
}

// ── Per-wallet popup menu ─────────────────────────────────────────────────────

enum _WalletMenuAction { rename, editAmount, viewSecret, remove }

class _WalletMenu extends ConsumerWidget {
  final WalletEntry wallet;

  const _WalletMenu({required this.wallet});

  String get _secretLabel =>
      wallet.kind == WalletKind.descriptor ? 'View descriptor' : 'View zpub';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isManual = wallet.kind == WalletKind.manual;

    return PopupMenuButton<_WalletMenuAction>(
      icon: Icon(Icons.more_vert,
          size: 20, color: Theme.of(context).colorScheme.secondary),
      onSelected: (action) async {
        switch (action) {
          case _WalletMenuAction.rename:
            await _showRenameDialog(context, ref);
          case _WalletMenuAction.editAmount:
            await showEditManualAmountDialog(context, ref, wallet);
          case _WalletMenuAction.viewSecret:
            await _showSecret(context, ref);
          case _WalletMenuAction.remove:
            await _confirmRemove(context, ref);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: _WalletMenuAction.rename,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined, size: 18),
            title: Text('Rename'),
          ),
        ),
        if (isManual)
          const PopupMenuItem(
            value: _WalletMenuAction.editAmount,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.tune, size: 18),
              title: Text('Edit amount'),
            ),
          )
        else
          PopupMenuItem(
            value: _WalletMenuAction.viewSecret,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.fingerprint, size: 18),
              title: Text(_secretLabel),
            ),
          ),
        const PopupMenuItem(
          value: _WalletMenuAction.remove,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.link_off, size: 18, color: AppColors.negative),
            title:
                Text('Remove', style: TextStyle(color: AppColors.negative)),
          ),
        ),
      ],
    );
  }

  Future<void> _showRenameDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: wallet.label);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename wallet'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Wallet name'),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (confirmed == true && controller.text.trim().isNotEmpty) {
      await ref
          .read(walletsProvider.notifier)
          .renameWallet(wallet.id, controller.text);
    }
    controller.dispose();
  }

  Future<void> _showSecret(BuildContext context, WidgetRef ref) async {
    final noun =
        wallet.kind == WalletKind.descriptor ? 'descriptor' : 'zpub';

    final availability = await checkAvailability();
    if (!context.mounted) return;

    if (availability != BiometricAvailability.available) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'No screen lock set up. Add a PIN or fingerprint to protect your $noun.'),
      ));
      return;
    }

    final secret =
        await ref.read(walletsProvider.notifier).revealSecret(wallet.id);
    if (!context.mounted) return;
    if (secret == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Authentication cancelled')));
      return;
    }

    // Keeps the value out of screenshots and the app-switcher snapshot
    // while it is on screen: FLAG_SECURE on Android, the privacy cover on
    // iOS. Undone in `finally`.
    await SecretOnScreen.guard(() async {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(wallet.label),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  secret,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 12),
                Text(
                  'Anyone holding this $noun can see your entire balance and '
                  'transaction history. Copying puts it on the system clipboard, '
                  'where other apps may be able to read it.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: secret));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$noun copied to clipboard')));
              },
              child: const Text('Copy'),
            ),
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close')),
          ],
        ),
      );
    });
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${wallet.label}"?'),
        content: Text(
          wallet.kind == WalletKind.manual
              ? 'This will remove the entry and its amount from your portfolio.'
              : 'This will disconnect the wallet and clear its cached balance. '
                  'The ${wallet.kind == WalletKind.descriptor ? 'descriptor' : 'zpub'} '
                  'will be deleted from secure storage.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.negative),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(walletsProvider.notifier).removeWallet(wallet.id);
    }
  }
}

// ── Block explorer selector ───────────────────────────────────────────────────

enum _TestStatus { none, testing, ok, error }

class _ExplorerSelector extends ConsumerStatefulWidget {
  const _ExplorerSelector();

  @override
  ConsumerState<_ExplorerSelector> createState() => _ExplorerSelectorState();
}

class _ExplorerSelectorState extends ConsumerState<_ExplorerSelector> {
  final _customUrlController = TextEditingController();
  bool _editing = false;
  _TestStatus _testStatus = _TestStatus.none;
  String? _testMessage;

  /// The URL whose test just failed, offered under "Save anyway" (R-4).
  /// Cleared as soon as the field changes, so the second tap saves exactly
  /// what was tested.
  String? _unverifiedUrl;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(networkSettingsProvider).customUrl;
    _customUrlController.text = saved;
    // If no URL saved yet, open edit mode immediately when Custom is selected.
    _editing = saved.isEmpty;
  }

  @override
  void dispose() {
    _customUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(networkSettingsProvider);

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
      ),
      child: Column(
        children: [
          _ExplorerTile(
            label: 'blockstream',
            subtitle: 'blockstream.info',
            selected: settings.preset == ExplorerPreset.blockstream,
            onTap: () => ref
                .read(networkSettingsProvider.notifier)
                .setPreset(ExplorerPreset.blockstream),
          ),
          Divider(height: 1, color: cs.outline),
          _ExplorerTile(
            label: 'mempool.space',
            subtitle: 'mempool.space',
            selected: settings.preset == ExplorerPreset.mempool,
            onTap: () => ref
                .read(networkSettingsProvider.notifier)
                .setPreset(ExplorerPreset.mempool),
          ),
          Divider(height: 1, color: cs.outline),
          _ExplorerTile(
            label: 'custom',
            subtitle: 'Your own Esplora-compatible server',
            selected: settings.preset == ExplorerPreset.custom,
            onTap: () {
              ref
                  .read(networkSettingsProvider.notifier)
                  .setPreset(ExplorerPreset.custom);
              // Enter edit mode if no URL is saved yet.
              if (settings.customUrl.isEmpty) {
                setState(() => _editing = true);
              }
            },
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: settings.preset == ExplorerPreset.custom
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Divider(height: 1, color: cs.outline),
                        const SizedBox(height: 12),
                        if (_editing)
                          _buildEditRow(cs)
                        else
                          _buildDisplayRow(context, cs, settings),
                        _buildTorWarning(settings),
                        _buildTestResult(),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  /// Read-only row: truncated URL + Test + Edit buttons.
  Widget _buildDisplayRow(
      BuildContext context, ColorScheme cs, NetworkSettings settings) {
    return Row(
      children: [
        Expanded(
          child: Text(
            settings.customUrl.isEmpty ? 'No URL set' : settings.customUrl,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: settings.customUrl.isEmpty ? cs.outline : null,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Test connection
        IconButton(
          onPressed:
              settings.customUrl.isEmpty ? null : _testConnection,
          icon: _testStatus == _TestStatus.testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.primary),
                )
              : Icon(
                  Icons.wifi_tethering,
                  size: 18,
                  color: switch (_testStatus) {
                    _TestStatus.ok => AppColors.positive,
                    _TestStatus.error => AppColors.negative,
                    _ => cs.secondary,
                  },
                ),
          tooltip: 'Test connection',
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(),
        ),
        const SizedBox(width: 4),
        // Edit
        IconButton(
          onPressed: () => setState(() {
            _editing = true;
            _testStatus = _TestStatus.none;
            _testMessage = null;
          }),
          icon: Icon(Icons.edit_outlined, size: 18, color: cs.secondary),
          tooltip: 'Edit URL',
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(),
        ),
      ],
    );
  }

  /// Editable row: TextField + Save + Cancel buttons.
  Widget _buildEditRow(ColorScheme cs) {
    final hasSaved = ref.read(networkSettingsProvider).customUrl.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _customUrlController,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            hintText: 'http://yournode.onion',
            hintStyle: TextStyle(fontSize: 13, color: cs.outline),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          style: const TextStyle(fontSize: 13),
          onChanged: (_) {
            if (_unverifiedUrl != null) setState(() => _unverifiedUrl = null);
          },
          onSubmitted: (_) => _saveCustomUrl(),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed:
                    _testStatus == _TestStatus.testing ? null : _saveCustomUrl,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13),
                ),
                child: _testStatus == _TestStatus.testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text('Save'),
              ),
            ),
            if (hasSaved) ...[
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _testStatus == _TestStatus.testing
                      ? null
                      : () {
                          _customUrlController.text =
                              ref.read(networkSettingsProvider).customUrl;
                          setState(() => _editing = false);
                          FocusScope.of(context).unfocus();
                        },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ],
        ),
        if (_unverifiedUrl != null &&
            _testStatus == _TestStatus.error) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _saveUnverified,
              child: const Text('Save anyway'),
            ),
          ),
        ],
      ],
    );
  }

  /// Route and encryption notes under a saved URL: a `.onion` the route
  /// can't reach (R-2), plain http to a public host saved before that was
  /// refused (R-3), or a clearnet explorer over Tor.
  Widget _buildTorWarning(NetworkSettings settings) {
    if (settings.customUrl.isEmpty) return const SizedBox.shrink();

    final isOnion =
        isOnionHost(Uri.tryParse(settings.customUrl)?.host ?? '');
    final route = settings.route;

    // A SOCKS5 proxy may front a Tor daemon, which resolves .onion itself;
    // anywhere else the routing layer refuses it (R-2).
    if (isOnion && !route.canReachOnion) {
      return const _ExplorerNote(
        icon: Icons.error_outline,
        iconColor: AppColors.negative,
        textColor: AppColors.negative,
        message: onionNeedsTorMessage,
      );
    }

    if (isUnencryptedExplorer(settings.customUrl)) {
      return _ExplorerNote(
        icon: Icons.warning_amber_rounded,
        iconColor: Colors.amber.shade600,
        textColor: Colors.amber.shade700,
        message: unencryptedExplorerWarning,
      );
    }

    if (route is TorRoute && !isOnion) {
      return _ExplorerNote(
        icon: Icons.warning_amber_rounded,
        iconColor: Colors.amber.shade600,
        textColor: Colors.amber.shade700,
        message: 'Tor is enabled — use an .onion address for full privacy.',
      );
    }

    return const SizedBox.shrink();
  }

  /// Connection test result row.
  Widget _buildTestResult() {
    if (_testStatus == _TestStatus.none ||
        _testStatus == _TestStatus.testing) {
      return const SizedBox.shrink();
    }
    final ok = _testStatus == _TestStatus.ok;
    final color = ok ? AppColors.positive : AppColors.negative;
    return _ExplorerNote(
      icon: ok ? Icons.check_circle_outline : Icons.error_outline,
      iconColor: color,
      textColor: color,
      message: _testMessage ?? '',
    );
  }

  /// Fresh probe of a private route before any explorer request. Returns the
  /// message to show when the route is down, or null when it may be used.
  ///
  /// Routing already fails closed; probing first turns a refused connection
  /// into a message that names the route.
  Future<String?> _routeBlockedMessage(NetworkRoute route) async {
    if (route.isPrivate &&
        await RouteGate.probe(route) != RouteStatus.available) {
      return routeUnavailableMessage(route);
    }
    return null;
  }

  /// Builds a Dio for connectivity tests that leaves over the selected route.
  /// Callers must clear [_routeBlockedMessage] first.
  Dio _buildTestDio(NetworkRoute route) => buildRoutedDio(
        route: route,
        clearnetTimeout: const Duration(seconds: 10),
        headers: {'Accept': 'application/json'},
      );

  /// A well-known BIP84 test-vector address. Any live Esplora server must
  /// return a valid `chain_stats` JSON object for this address (even if it
  /// has zero on-chain history — the structure is what matters).
  static const _kProbeAddress = 'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu';

  /// Probes [base] then [base]/api using the Esplora address endpoint.
  /// Returns the first candidate whose `/address/:addr` response contains
  /// a `chain_stats` field — confirming the full Esplora API (including
  /// UTXO lookups) is available at that path.
  ///
  /// Falls back to `blocks/tip/height` if neither candidate serves a valid
  /// address response (e.g. a lightweight node that omits old-address history).
  Future<String?> _resolveApiBase(String base, NetworkRoute route) async {
    final candidates = [base, '$base/api'];
    final dio = _buildTestDio(route);
    try {
      return await _probeApiBase(dio, candidates);
    } finally {
      // Its keep-alive sockets (a tunnel through Tor or the proxy) would
      // otherwise stay open until the idle timeout (M-5).
      dio.close(force: true);
    }
  }

  Future<String?> _probeApiBase(Dio dio, List<String> candidates) async {
    // Primary: validate via the address endpoint — this is what wallet scan
    // and health check both need, so it's a more reliable signal than
    // blocks/tip/height (which may be available at /api even when the full
    // Esplora API lives at root).
    for (final candidate in candidates) {
      try {
        final resp = await dio
            .get<dynamic>('$candidate/address/$_kProbeAddress');
        if (resp.statusCode == 200) {
          final data = resp.data;
          if (data is Map && data.containsKey('chain_stats')) {
            return candidate;
          }
        }
      } catch (_) {
        // Try next candidate.
      }
    }

    // Secondary fallback: blocks/tip/height for servers that don't index
    // all addresses but still expose a tip endpoint.
    for (final candidate in candidates) {
      try {
        final resp =
            await dio.get<dynamic>('$candidate/blocks/tip/height');
        if (resp.statusCode == 200) {
          final raw = resp.data;
          final height =
              raw is int ? raw : int.tryParse(raw.toString().trim());
          if (height != null) return candidate;
        }
      } catch (_) {
        // Try next candidate.
      }
    }

    return null;
  }

  /// Shows [message] as a failed result under the URL.
  void _showError(String message) {
    setState(() {
      _testStatus = _TestStatus.error;
      _testMessage = message;
    });
  }

  Future<void> _saveCustomUrl() async {
    final route = ref.read(networkSettingsProvider).route;
    // Refused before any request: other schemes, link-local, a .onion the
    // route can't reach (R-2), plain http to a public host (R-3).
    final check = checkCustomExplorerUrl(_customUrlController.text, route);
    final raw = check.url;
    if (raw == null) {
      final error = check.error;
      if (error != null) {
        setState(() => _unverifiedUrl = null);
        _showError(error);
      }
      return;
    }

    setState(() {
      _unverifiedUrl = null;
      _testStatus = _TestStatus.testing;
      _testMessage = 'Detecting API endpoint…';
    });
    FocusScope.of(context).unfocus();

    final blocked = await _routeBlockedMessage(route);
    if (!mounted) return;
    if (blocked != null) {
      // Nothing is saved: the user stays in edit mode with the URL intact.
      _showError(blocked);
      return;
    }

    final resolved = await _resolveApiBase(raw, route);

    if (!mounted) return;

    if (resolved != null) {
      ref.read(networkSettingsProvider.notifier).setCustomUrl(resolved);
      setState(() {
        _editing = false;
        _testStatus = _TestStatus.ok;
        _testMessage = 'Connected — endpoint detected';
      });
    } else {
      // Not saved (R-4): a typo that happens to resolve would otherwise get
      // every derived address. Edit mode stays with the error, and "Save
      // anyway" saves this URL on a second tap.
      setState(() {
        _unverifiedUrl = raw;
        _testStatus = _TestStatus.error;
        _testMessage =
            'Could not reach server — check the address and try again.';
      });
    }
  }

  /// "Save anyway" after a failed test (R-4): the user insists.
  void _saveUnverified() {
    final url = _unverifiedUrl;
    if (url == null) return;
    ref.read(networkSettingsProvider.notifier).setCustomUrl(url);
    setState(() {
      _unverifiedUrl = null;
      _editing = false;
      _testStatus = _TestStatus.none;
      _testMessage = null;
    });
  }

  Future<void> _testConnection() async {
    final settings = ref.read(networkSettingsProvider);
    final url = settings.effectiveBaseUrl;
    if (url.isEmpty) return;

    setState(() {
      _testStatus = _TestStatus.testing;
      _testMessage = null;
    });

    final route = settings.route;
    // The routing layer would refuse it; say why without trying (R-2).
    if (!route.canReachOnion && isOnionHost(Uri.tryParse(url)?.host ?? '')) {
      _showError(onionNeedsTorMessage);
      return;
    }
    final blocked = await _routeBlockedMessage(route);
    if (!mounted) return;
    if (blocked != null) {
      _showError(blocked);
      return;
    }

    final dio = _buildTestDio(route);
    String? connected;
    String? error;
    try {
      // /blocks/tip/height is a lightweight Esplora endpoint that returns a
      // plain integer — no auth required and very fast to respond.
      final response =
          await dio.get<dynamic>('$url/blocks/tip/height');
      if (response.statusCode == 200) {
        final raw = response.data;
        final height =
            raw is int ? raw : int.tryParse(raw.toString().trim());
        if (height != null) {
          connected = 'Connected — block height $height';
        } else {
          error = 'Unexpected response — check the URL is correct.';
        }
      } else {
        error = 'Unexpected status ${response.statusCode}';
      }
    } on DioException catch (e) {
      error = switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout =>
          'Timed out — check the URL and that the server is reachable.',
        DioExceptionType.connectionError =>
          'Connection failed — check the URL and network.',
        _ => 'Error: ${e.type.name}',
      };
    } catch (_) {
      error = 'Unexpected error — check the URL format.';
    } finally {
      dio.close(force: true); // M-5
    }

    // The tab may have been left, or Pro lapsed, while it ran (M-4).
    if (!mounted) return;
    if (connected != null) {
      setState(() {
        _testStatus = _TestStatus.ok;
        _testMessage = connected;
      });
    } else {
      _showError(error!);
    }
  }
}

class _ExplorerTile extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _ExplorerTile({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              color: selected
                  ? AppColors.primary
                  : Theme.of(context).colorScheme.outline,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: Theme.of(context).textTheme.bodyLarge),
                  Text(subtitle,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A note under the custom explorer's URL: a route warning or the last test
/// result.
class _ExplorerNote extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color textColor;
  final String message;

  const _ExplorerNote({
    required this.icon,
    required this.iconColor,
    required this.textColor,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: iconColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: textColor,
                    height: 1.4,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Tor section ───────────────────────────────────────────────────────────────

class _TorSection extends ConsumerWidget {
  const _TorSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(networkSettingsProvider);

    // Tor is built in, and the card reads the embedded client's state, only
    // while Tor is the route: under a proxy or direct, a client left over
    // must not read as connected. On TorRoute the status is derived from
    // that state, so watching it is what rebuilds the card when it changes.
    ref.watch(routeStatusProvider);
    final torSelected = settings.route is TorRoute;
    final torState = EmbeddedTorService.state;
    final isChecking = torSelected && torState == EmbeddedTorState.starting;
    final isAvailable = torSelected && EmbeddedTorService.carriesTraffic;
    final failed = torSelected && !isChecking && !isAvailable;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.security_outlined,
                  color: AppColors.primary, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Route through Tor',
                    style: Theme.of(context).textTheme.bodyLarge),
              ),
              Switch(
                value: settings.useTor,
                onChanged: (v) =>
                    ref.read(networkSettingsProvider.notifier).setUseTor(v),
                activeThumbColor: AppColors.primary,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "Built-in Tor — only Bag's traffic goes through Tor. No other app needed.",
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(height: 1.5),
          ),
          const _OrbotMigrationHint(),
          const SizedBox(height: 8),
          Row(
            children: [
              _TorStatusDot(isChecking: isChecking, isAvailable: isAvailable),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _statusLabel(
                      torSelected: torSelected,
                      isChecking: isChecking,
                      isAvailable: isAvailable),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isAvailable ? AppColors.positive : cs.secondary,
                      ),
                ),
              ),
              if (failed)
                TextButton(
                  // Restarts a failed client (or one that lost its circuit).
                  // Its transition to ready refreshes prices once, from
                  // routeStatusProvider.
                  onPressed: () =>
                      unawaited(EmbeddedTorService.ensureStarted()),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Retry'),
                ),
            ],
          ),
          // Why the built-in client failed, so a tester can tell us. An Arti
          // error can name the app's own directories; describeError has
          // already replaced every absolute path with <dir> (TB-6).
          if (failed && EmbeddedTorService.lastError != null) ...[
            const SizedBox(height: 4),
            Text(
              'Details: ${EmbeddedTorService.lastError}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  /// The built-in client's state, as the card's status line.
  String _statusLabel(
      {required bool torSelected,
      required bool isChecking,
      required bool isAvailable}) {
    if (!torSelected) return 'Tor is off';
    if (isChecking) return 'Connecting to Tor…';
    if (isAvailable) return 'Connected through Tor';
    return "Couldn't connect to Tor";
  }
}

/// Once: tells a user who had Tor on before the upgrade (so ran it through
/// another app) that the app is no longer needed. Shown while
/// `TorService.showOrbotMigrationHint` (this platform's migration pref is
/// 'show', written once at startup by `TorService.recordOrbotMigration`);
/// dismissing it sets 'dismissed' for good.
class _OrbotMigrationHint extends ConsumerStatefulWidget {
  const _OrbotMigrationHint();

  @override
  ConsumerState<_OrbotMigrationHint> createState() =>
      _OrbotMigrationHintState();
}

class _OrbotMigrationHintState extends ConsumerState<_OrbotMigrationHint> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(sharedPreferencesProvider);
    if (_dismissed || !TorService.showOrbotMigrationHint(prefs)) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 14, color: cs.secondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              "Bag now runs Tor itself. You can turn off Orbot's VPN.",
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(height: 1.5),
            ),
          ),
          IconButton(
            key: const Key('orbot-hint-dismiss'),
            onPressed: () {
              setState(() => _dismissed = true);
              unawaited(TorService.dismissOrbotMigrationHint(prefs));
            },
            icon: const Icon(Icons.close, size: 16),
            color: cs.secondary,
            tooltip: 'Dismiss',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

class _TorStatusDot extends StatelessWidget {
  final bool isChecking;
  final bool isAvailable;

  const _TorStatusDot(
      {required this.isChecking, required this.isAvailable});

  @override
  Widget build(BuildContext context) {
    if (isChecking) {
      return const SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(
            strokeWidth: 1.5, color: AppColors.primary),
      );
    }
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isAvailable ? AppColors.positive : Colors.grey,
      ),
    );
  }
}

// ── Sentinel entry card ───────────────────────────────────────────────────────

class _SentinelCard extends ConsumerWidget {
  const _SentinelCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final sentinelState = ref.watch(sentinelProvider);
    final isEnabled = sentinelState is SentinelEnabled;

    final alwaysOn = SentinelService.isAlwaysOn;
    final statusText = switch (sentinelState) {
      SentinelEnabled(:final lastScanAt) when !alwaysOn => lastScanAt != null
          ? 'Active · ${sentinelLiteLastChecked(lastScanAt)}'
          : 'Active · Not checked yet',
      SentinelEnabled(:final lastScanAt) => lastScanAt != null
          ? 'Active · Last scan ${DateFormat('HH:mm').format(lastScanAt)}'
          : 'Active · Waiting for first scan…',
      SentinelDisabled() => 'Off — tap to configure',
    };

    return InkWell(
      onTap: () => context.push('/wallets/sentinel'),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isEnabled
                ? AppColors.positive.withValues(alpha: 0.4)
                : cs.outline,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.shield_outlined,
              color: isEnabled ? AppColors.positive : cs.secondary,
              size: 18,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alwaysOn ? 'Sentinel' : 'Sentinel Lite',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  Text(
                    statusText,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: isEnabled ? AppColors.positive : null,
                        ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: cs.secondary, size: 20),
          ],
        ),
      ),
    );
  }
}
