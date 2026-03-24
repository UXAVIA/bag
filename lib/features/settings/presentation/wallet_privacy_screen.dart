import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:socks5_proxy/socks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../providers/sentinel_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/btc_format.dart';
import '../../../models/chain_analysis.dart';
import '../../../models/network_settings.dart';
import '../../../models/wallet_entry.dart';
import '../../../providers/health_check_provider.dart';
import '../../../providers/network_settings_provider.dart';
import '../../../providers/purchase_provider.dart';
import '../../../providers/sats_mode_provider.dart';
import '../../../providers/tor_status_provider.dart';
import '../../../providers/wallets_provider.dart';
import '../../../services/tor_service.dart';
import '../../../services/wallet/biometric_storage_service.dart';
import '../../../widgets/privacy_score_sheet.dart';
import '../../../widgets/pro_gate.dart';
import '../../../widgets/wallet_section.dart';

class WalletPrivacyScreen extends ConsumerWidget {
  const WalletPrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallets = ref.watch(walletsProvider);
    final proUnlocked = ref.watch(proUnlockedProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Wallet & Privacy')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── SENTINEL ────────────────────────────────────────────────
            _SectionHeader(label: 'SENTINEL'),
            const SizedBox(height: 4),
            Text(
              'Always-on balance monitoring with instant alerts on any movement.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            ProGate(
              featureName: 'Sentinel',
              child: const _SentinelCard(),
            ),
            const SizedBox(height: 32),

            // ── WALLETS ─────────────────────────────────────────────────
            _SectionHeader(label: 'WALLETS'),
            const SizedBox(height: 4),
            Text(
              'Track balance from one or more Bitcoin zpub keys',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            ProGate(
              featureName: 'Watch-only Wallets',
              child: Column(
                children: [
                  ...wallets.map((w) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _WalletCard(wallet: w),
                      )),
                  if (proUnlocked) const AddWalletForm(),
                ],
              ),
            ),

            // ── PORTFOLIO HEALTH ─────────────────────────────────────────
            if (wallets.isNotEmpty) ...[
              const SizedBox(height: 32),
              _SectionHeader(label: 'PORTFOLIO HEALTH'),
              const SizedBox(height: 4),
              Text(
                'Privacy score and UTXO analysis across all connected wallets',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              const _PortfolioHealthCard(),
            ],
            const SizedBox(height: 32),

            // ── NETWORK ──────────────────────────────────────────────────
            _SectionHeader(label: 'NETWORK'),
            const SizedBox(height: 4),
            Text(
              'Route queries privately via Tor, or point to your own node.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            const _TorSection(),
            const SizedBox(height: 16),
            const _ExplorerSelector(),
          ],
        ),
      ),
    );
  }
}

// ── Wallet card ───────────────────────────────────────────────────────────────

class _WalletCard extends ConsumerWidget {
  final WalletEntry wallet;

  const _WalletCard({required this.wallet});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final satsMode = ref.watch(satsModeProvider);
    final notifier = ref.read(walletsProvider.notifier);

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
          // Header row: icon + label + menu
          Row(
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                color: wallet.lastSats != null
                    ? AppColors.positive
                    : AppColors.primary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  wallet.label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
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
              '${NumberFormat.decimalPattern().format(wallet.lastSats)} sats'
              '  ·  ${wallet.usedAddresses} addresses',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (wallet.lastScanAt != null) ...[
              const SizedBox(height: 2),
              Text(
                'Last scanned ${DateFormat('d MMM HH:mm').format(wallet.lastScanAt!)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ] else
            Text(
              'Not yet scanned',
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
                : () => notifier.scan(wallet.id),
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(wallet.isScanning ? 'Scanning…' : 'Scan Now'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.black,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              textStyle: const TextStyle(fontSize: 13),
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
                  textStyle: const TextStyle(fontSize: 12),
                  side: BorderSide(
                      color: scoreColor.withValues(alpha: 0.6)),
                  foregroundColor: scoreColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => context
                    .push('/settings/wallet-privacy/health-check'),
                icon: const Icon(Icons.list_alt_outlined, size: 15),
                label: const Text('UTXOs'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  textStyle: const TextStyle(fontSize: 12),
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

enum _WalletMenuAction { rename, viewZpub, remove }

class _WalletMenu extends ConsumerWidget {
  final WalletEntry wallet;

  const _WalletMenu({required this.wallet});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_WalletMenuAction>(
      icon: Icon(Icons.more_vert,
          size: 20, color: Theme.of(context).colorScheme.secondary),
      onSelected: (action) async {
        switch (action) {
          case _WalletMenuAction.rename:
            await _showRenameDialog(context, ref);
          case _WalletMenuAction.viewZpub:
            await _showZpub(context, ref);
          case _WalletMenuAction.remove:
            await _confirmRemove(context, ref);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: _WalletMenuAction.rename,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined, size: 18),
            title: Text('Rename'),
          ),
        ),
        PopupMenuItem(
          value: _WalletMenuAction.viewZpub,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.fingerprint, size: 18),
            title: Text('View zpub'),
          ),
        ),
        PopupMenuItem(
          value: _WalletMenuAction.remove,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.link_off, size: 18,
                color: AppColors.negative),
            title: Text('Remove',
                style: TextStyle(color: AppColors.negative)),
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

  Future<void> _showZpub(BuildContext context, WidgetRef ref) async {
    final availability = await checkAvailability();
    if (!context.mounted) return;

    if (availability != BiometricAvailability.available) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'No screen lock set up. Add a PIN or fingerprint to protect your zpub.'),
      ));
      return;
    }

    final zpub =
        await ref.read(walletsProvider.notifier).revealZpub(wallet.id);
    if (!context.mounted) return;
    if (zpub == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Authentication cancelled')));
      return;
    }

    const channel = MethodChannel('app.bitbag/widget');
    await channel.invokeMethod('setSecureMode', {'secure': true});
    if (!context.mounted) {
      await channel.invokeMethod('setSecureMode', {'secure': false});
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(wallet.label),
        content: SelectableText(
          zpub,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard')));
            },
            child: const Text('Copy'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close')),
        ],
      ),
    );
    await channel.invokeMethod('setSecureMode', {'secure': false});
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${wallet.label}"?'),
        content: const Text(
          'This will disconnect the wallet and clear its cached balance. '
          'The zpub will be deleted from secure storage.',
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
                        _buildTorWarning(context, settings),
                        _buildTestResult(context),
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
                  textStyle: const TextStyle(fontSize: 13),
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
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Tor / clearnet mismatch warning.
  Widget _buildTorWarning(BuildContext context, NetworkSettings settings) {
    if (settings.customUrl.isEmpty) return const SizedBox.shrink();

    final isOnion = settings.customUrl.contains('.onion');
    final useTor = settings.useTor;

    if (useTor && !isOnion) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 14, color: Colors.amber.shade600),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Tor is enabled — use an .onion address for full privacy.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.amber.shade700,
                      height: 1.4,
                    ),
              ),
            ),
          ],
        ),
      );
    }

    if (!useTor && isOnion) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline,
                size: 14, color: AppColors.negative),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '.onion addresses only work with Tor enabled.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.negative,
                      height: 1.4,
                    ),
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  /// Connection test result row.
  Widget _buildTestResult(BuildContext context) {
    if (_testStatus == _TestStatus.none ||
        _testStatus == _TestStatus.testing) {
      return const SizedBox.shrink();
    }
    final ok = _testStatus == _TestStatus.ok;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 14,
            color: ok ? AppColors.positive : AppColors.negative,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _testMessage ?? '',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: ok ? AppColors.positive : AppColors.negative,
                    height: 1.4,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds a Tor-aware Dio instance for connectivity tests.
  Dio _buildTestDio(bool useTor) {
    final timeout = Duration(seconds: useTor ? 60 : 10);
    final dio = Dio(BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
      headers: {'Accept': 'application/json'},
    ));
    if (useTor) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          SocksTCPClient.assignToHttpClient(client, [
            ProxySettings(
              InternetAddress(AppConstants.torHost),
              AppConstants.torPort,
            ),
          ]);
          return client;
        },
      );
    }
    return dio;
  }

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
  Future<String?> _resolveApiBase(String base, bool useTor) async {
    final candidates = [base, '$base/api'];
    final dio = _buildTestDio(useTor);

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

  Future<void> _saveCustomUrl() async {
    var raw = _customUrlController.text.trim();
    if (raw.isEmpty) return;

    // Prepend https:// if user omitted the scheme.
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'https://$raw';
    }

    // Reject non-HTTP schemes (file://, javascript:, ftp://, etc.).
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      setState(() {
        _testStatus = _TestStatus.error;
        _testMessage = 'Invalid URL — must start with https:// or http://';
      });
      return;
    }

    // Reject cloud metadata IP (169.254.169.254) — not a valid node address.
    // LAN addresses (192.168.x.x, 10.x.x.x, 127.x.x.x) are intentionally
    // allowed: self-hosted Esplora nodes on a home network are a core use case.
    final host = uri.host.toLowerCase();
    if (host == '169.254.169.254' || host.startsWith('169.254.')) {
      setState(() {
        _testStatus = _TestStatus.error;
        _testMessage = 'Invalid URL — link-local addresses are not allowed.';
      });
      return;
    }

    // Strip trailing slashes and any API path suffix the user may have typed.
    raw = raw.replaceAll(RegExp(r'/+$'), '');
    raw = raw.replaceAll(RegExp(r'/api/v\d+$'), '');
    raw = raw.replaceAll(RegExp(r'/api$'), '');

    setState(() {
      _testStatus = _TestStatus.testing;
      _testMessage = 'Detecting API endpoint…';
    });
    FocusScope.of(context).unfocus();

    final useTor = ref.read(networkSettingsProvider).useTor;
    final resolved = await _resolveApiBase(raw, useTor);

    if (!mounted) return;

    if (resolved != null) {
      ref.read(networkSettingsProvider.notifier).setCustomUrl(resolved);
      setState(() {
        _editing = false;
        _testStatus = _TestStatus.ok;
        _testMessage = 'Connected — endpoint detected';
      });
    } else {
      // Save the stripped URL so user can correct it; keep in edit mode.
      ref.read(networkSettingsProvider.notifier).setCustomUrl(raw);
      setState(() {
        _editing = false;
        _testStatus = _TestStatus.error;
        _testMessage =
            'Could not reach server — check the address and try again.';
      });
    }
  }

  Future<void> _testConnection() async {
    final url = ref.read(networkSettingsProvider).effectiveBaseUrl;
    if (url.isEmpty) return;

    setState(() {
      _testStatus = _TestStatus.testing;
      _testMessage = null;
    });

    final useTor = ref.read(networkSettingsProvider).useTor;

    try {
      final dio = _buildTestDio(useTor);
      // /blocks/tip/height is a lightweight Esplora endpoint that returns a
      // plain integer — no auth required and very fast to respond.
      final response =
          await dio.get<dynamic>('$url/blocks/tip/height');
      if (response.statusCode == 200) {
        final raw = response.data;
        final height =
            raw is int ? raw : int.tryParse(raw.toString().trim());
        if (height != null) {
          setState(() {
            _testStatus = _TestStatus.ok;
            _testMessage = 'Connected — block height $height';
          });
        } else {
          setState(() {
            _testStatus = _TestStatus.error;
            _testMessage = 'Unexpected response — check the URL is correct.';
          });
        }
      } else {
        setState(() {
          _testStatus = _TestStatus.error;
          _testMessage = 'Unexpected status ${response.statusCode}';
        });
      }
    } on DioException catch (e) {
      setState(() {
        _testStatus = _TestStatus.error;
        _testMessage = switch (e.type) {
          DioExceptionType.connectionTimeout ||
          DioExceptionType.receiveTimeout =>
            'Timed out — check the URL and that the server is reachable.',
          DioExceptionType.connectionError =>
            'Connection failed — check the URL and network.',
          _ => 'Error: ${e.type.name}',
        };
      });
    } catch (e) {
      setState(() {
        _testStatus = _TestStatus.error;
        _testMessage = 'Unexpected error — check the URL format.';
      });
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

// ── Tor section ───────────────────────────────────────────────────────────────

class _TorSection extends ConsumerWidget {
  const _TorSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(networkSettingsProvider);
    final torAsync = ref.watch(torStatusProvider);

    final torStatus = torAsync.valueOrNull;
    final isChecking = torAsync.isLoading;
    final isAvailable = torStatus == TorStatus.available;

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
                activeColor: AppColors.primary,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _TorStatusDot(isChecking: isChecking, isAvailable: isAvailable),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _statusLabel(
                      isChecking: isChecking, isAvailable: isAvailable),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isChecking
                            ? cs.secondary
                            : isAvailable
                                ? AppColors.positive
                                : cs.secondary,
                      ),
                ),
              ),
              IconButton(
                onPressed: isChecking
                    ? null
                    : () =>
                        ref.read(torStatusProvider.notifier).recheck(),
                icon: const Icon(Icons.refresh, size: 18),
                color: cs.secondary,
                tooltip: 'Re-check Orbot',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          if (settings.useTor && !isChecking && !isAvailable) ...[
            const SizedBox(height: 8),
            Text(
              'Orbot not detected — wallet scans will fail until Orbot is running. '
              'Install Orbot from F-Droid or Google Play, then tap ↺ above.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.negative,
                    height: 1.5,
                  ),
            ),
          ],
          if (!settings.useTor) ...[
            const SizedBox(height: 4),
            Text(
              'Hides your IP from the block explorer. Requires Orbot.',
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

  String _statusLabel(
      {required bool isChecking, required bool isAvailable}) {
    if (isChecking) return 'Checking for Orbot…';
    if (isAvailable) return 'Orbot detected on port ${AppConstants.torPort}';
    return 'Orbot not detected';
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

    final statusText = switch (sentinelState) {
      SentinelEnabled(:final lastScanAt) => lastScanAt != null
          ? 'Active · Last scan ${DateFormat('HH:mm').format(lastScanAt)}'
          : 'Active · Waiting for first scan…',
      SentinelDisabled() => 'Off — tap to configure',
    };

    return InkWell(
      onTap: () => context.push('/settings/sentinel'),
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
                    'Sentinel',
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

// ── Shared ────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) =>
      Text(label, style: Theme.of(context).textTheme.titleMedium);
}
