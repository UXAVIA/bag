import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/supported_currencies.dart';
import '../../../core/services/license_key_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/btc_format.dart';
import '../../../core/utils/secret_on_screen.dart';
import '../../../providers/biometric_lock_provider.dart';
import '../../../providers/fee_settings_provider.dart';
import '../../../providers/portfolio_provider.dart';
import '../../../providers/purchase_provider.dart';
import '../../../providers/sats_mode_provider.dart';
import '../../../providers/shared_preferences_provider.dart';
import '../../../providers/theme_provider.dart';
import '../../../providers/wallets_provider.dart';
import '../../../services/notification_service.dart';
import '../../../services/wallet/biometric_storage_service.dart' as bio;
import '../../../services/widget_service.dart';
import '../../../widgets/currency_selector.dart';
import '../../../widgets/pro_locked_row.dart';
import '../../../widgets/section_header.dart';
import 'pro_upgrade_sheet.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late TextEditingController _btcController;
  final _btcFocusNode = FocusNode();
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final amount = ref.read(portfolioProvider).btcAmount;
    final satsMode = ref.read(satsModeProvider);
    _btcController = TextEditingController(
      text: amount > 0 ? btcToFieldString(amount, satsMode: satsMode) : '',
    );
  }

  @override
  void dispose() {
    _btcController.dispose();
    _btcFocusNode.dispose();
    super.dispose();
  }

  void _toggleSatsMode() {
    final currentSatsMode = ref.read(satsModeProvider);
    final parsed =
        parseBtcInput(_btcController.text, satsMode: currentSatsMode);
    // iOS doesn't reload the keyboard when keyboardType changes on a focused
    // field — cycle focus to force the correct keyboard to appear.
    final wasFocused = _btcFocusNode.hasFocus;
    if (wasFocused) _btcFocusNode.unfocus();
    ref.read(satsModeProvider.notifier).toggle();
    if (parsed != null && parsed > 0) {
      _btcController.text = btcToFieldString(parsed, satsMode: !currentSatsMode);
    }
    if (wasFocused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _btcFocusNode.requestFocus();
      });
    }
  }

  Future<void> _saveBtcAmount() async {
    final satsMode = ref.read(satsModeProvider);
    final parsed = parseBtcInput(_btcController.text, satsMode: satsMode);
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Please enter a valid ${satsMode ? 'sats' : 'BTC'} amount'),
        ),
      );
      return;
    }
    await ref.read(portfolioProvider.notifier).setBtcAmount(parsed);
    if (!mounted) return;
    setState(() => _dirty = false);
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Amount saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final portfolio = ref.watch(portfolioProvider);
    final satsMode = ref.watch(satsModeProvider);
    final walletConnected = ref.watch(
        walletsProvider.select((wallets) => wallets.isNotEmpty));
    final onlyTypedIn = ref.watch(walletsProvider.select((wallets) =>
        wallets.isNotEmpty && wallets.every((w) => !w.isWatchOnly)));
    final proUnlocked = ref.watch(proUnlockedProvider);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        automaticallyImplyLeading: false,
      ),
      body: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── BAG PRO (free users) ────────────────────────────────
                  // Wallets, Tor and the rest live on the Wallets tab.
                  if (!proUnlocked) ...[
                    const _BagProRow(),
                    const SizedBox(height: 32),
                  ],

                  // ── PORTFOLIO ───────────────────────────────────────────
                  SectionHeader(label: 'Portfolio'),
                  const SizedBox(height: 12),
                  if (walletConnected)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: cs.outline),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                              Icons.account_balance_wallet_outlined,
                              color: AppColors.primary,
                              size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              onlyTypedIn
                                  ? 'Balance managed by your typed-in balances'
                                  : 'Balance managed by watch-only wallet',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    TextField(
                      controller: _btcController,
                      focusNode: _btcFocusNode,
                      keyboardType: satsMode
                          ? TextInputType.number
                          : const TextInputType.numberWithOptions(
                              decimal: true),
                      inputFormatters: [
                        satsMode
                            ? FilteringTextInputFormatter.digitsOnly
                            : FilteringTextInputFormatter.allow(
                                RegExp(r'^\d*\.?\d{0,8}')),
                      ],
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.w400,
                      ),
                      decoration: InputDecoration(
                        hintText: satsMode ? '0' : '0.00000000',
                        prefixIcon: GestureDetector(
                          onTap: _toggleSatsMode,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: BtcUnitIcon(
                              satsMode: satsMode,
                              color: AppColors.primary,
                              size: 20,
                            ),
                          ),
                        ),
                        suffixText: satsMode ? 'sats' : 'BTC',
                        suffixStyle: TextStyle(
                            color: Theme.of(context).colorScheme.secondary),
                      ),
                      onChanged: (_) => setState(() => _dirty = true),
                      onSubmitted: (_) => _saveBtcAmount(),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _dirty ? _saveBtcAmount : null,
                        child: const Text('Save Amount'),
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () => context.go('/wallets'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        minimumSize: const Size(48, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      child: const Text('Or let Bag read it from your wallet'),
                    ),
                  ],
                  const SizedBox(height: 32),

                  // ── DISPLAY ─────────────────────────────────────────────
                  SectionHeader(label: 'Display'),
                  const SizedBox(height: 4),
                  Text(
                    'Up to 3 currencies shown on the dashboard',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // Reorderable currency rows
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverReorderableList(
              itemCount: portfolio.selectedCurrencies.length,
              onReorderItem: (oldIndex, newIndex) {
                final list = [...portfolio.selectedCurrencies];
                list.insert(newIndex, list.removeAt(oldIndex));
                ref.read(portfolioProvider.notifier).setCurrencies(list);
              },
              itemBuilder: (context, index) {
                final code = portfolio.selectedCurrencies[index];
                final info = supportedCurrencies[code];
                if (info == null) {
                  return ReorderableDelayedDragStartListener(
                    key: ValueKey(code),
                    index: index,
                    child: const SizedBox.shrink(),
                  );
                }
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(code),
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: cs.outline),
                      ),
                      child: Row(
                        children: [
                          Text(
                            info.symbol,
                            style: const TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(info.name, style: Theme.of(context).textTheme.bodyLarge),
                          ),
                          Text(
                            info.code,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.drag_handle, color: cs.outline, size: 18),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          // Rest of settings
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: BorderSide(color: cs.outline),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => showCurrencySelector(
                        context: context,
                        selected: portfolio.selectedCurrencies,
                        onChanged: (currencies) =>
                            ref.read(portfolioProvider.notifier).setCurrencies(currencies),
                      ),
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      label: const Text('Change Currencies'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SatsModeToggle(
                    value: satsMode,
                    onChanged: (_) {
                      ref.read(satsModeProvider.notifier).toggle().then((_) {
                        final amount = ref.read(portfolioProvider).btcAmount;
                        final nowSats = ref.read(satsModeProvider);
                        if (amount > 0) {
                          _btcController.text =
                              btcToFieldString(amount, satsMode: nowSats);
                        }
                        setState(() => _dirty = false);
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  Center(child: _ThemeSelector()),
                  const SizedBox(height: 32),

                  // ── SECURITY ────────────────────────────────────────────
                  SectionHeader(label: 'Security'),
                  const SizedBox(height: 12),
                  _BiometricLockTile(),
                  const SizedBox(height: 32),

                  // ── HOME SCREEN ─────────────────────────────────────────
                  SectionHeader(label: 'Home screen'),
                  const SizedBox(height: 12),
                  _WidgetSection(),
                  const SizedBox(height: 32),

                  // ── NETWORK FEES ─────────────────────────────────────────
                  SectionHeader(label: 'Network fees'),
                  const SizedBox(height: 12),
                  _NetworkFeesSection(),
                  const SizedBox(height: 32),

                  // ── ABOUT ───────────────────────────────────────────────
                  SectionHeader(label: 'About'),
                  const SizedBox(height: 12),
                  Text(
                    'Bag is a Bitcoin-only portfolio monitor. Track your net worth in up to 3 fiat currencies, view price charts across multiple timeframes, log DCA purchases, and add a home screen widget.\n\n'
                    // Tor is Pro, built in on both platforms.
                    'Pro unlocks watch-only wallet tracking, '
                    'built-in Tor routing, '
                    'custom Esplora node support, Bitcoin Health Check with privacy scoring, and Sentinel — always-on balance alerts.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.6),
                    textAlign: TextAlign.justify,
                  ),
                  const SizedBox(height: 20),
                  _AboutTile(
                    icon: Icons.language_outlined,
                    label: 'Website',
                    trailing: 'bitbag.app →',
                    onTap: () => launchUrl(
                      Uri.parse('https://bitbag.app'),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                  _AboutTile(
                    icon: Icons.info_outline,
                    label: 'Version',
                    trailing: AppConstants.appVersion,
                  ),
                  // Direct: always (the key is how Pro is held). Store: only
                  // when a key is stored, i.e. Pro came from one.
                  if (proUnlocked &&
                      (ProUnlockedNotifier.flavor == 'direct' ||
                          ref.watch(licenceKeyStoredProvider).valueOrNull ==
                              true))
                    const _LicenseKeyTile(),
                  _AboutTile(
                    icon: Icons.code,
                    label: 'Source Code',
                    trailing: 'GitHub →',
                    onTap: () => launchUrl(
                      Uri.parse('https://github.com/UXAVIA/bag'),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                  _AboutTile(
                    icon: Icons.description_outlined,
                    label: 'Open-source licences',
                    trailing: 'View →',
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: 'Bag',
                      applicationVersion: AppConstants.appVersion,
                      applicationLegalese:
                          'GPL-3.0. Source: github.com/UXAVIA/bag',
                    ),
                  ),
                  _AboutTile(
                    icon: Icons.design_services_outlined,
                    label: 'Bitcoin Design Guide',
                    trailing: 'bitcoin.design →',
                    onTap: () => launchUrl(
                      Uri.parse('https://bitcoin.design'),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                  _AboutTile(
                    icon: Icons.currency_exchange_outlined,
                    label: 'Sat symbol',
                    trailing: 'satsymbol.com →',
                    onTap: () => launchUrl(
                      Uri.parse('https://satsymbol.com'),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Sat symbol design: Bitcoin Design Community',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      'No ads. No tracking. No accounts.\nYour data stays on your device.',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ),

                  // ── Debug panel (debug builds only) ──────────────────────
                  if (kDebugMode) ...[
                    const SizedBox(height: 40),
                    SectionHeader(label: 'Debug'),
                    const SizedBox(height: 12),
                    _NotificationsSection(),
                    const SizedBox(height: 12),
                    _DebugPanel(),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fee estimates and alerts are Pro. A free user gets one row naming the
/// feature with a Pro label, which opens the Pro sheet; the switches below
/// exist only for a Pro user.
class _NetworkFeesSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final proUnlocked = ref.watch(proUnlockedProvider);
    if (!proUnlocked) return const _NetworkFeesLockedRow();
    final feeSettings = ref.watch(feeSettingsProvider);

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
      ),
      child: Column(
        children: [
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: _SwitchRow(
              icon: Icons.speed_outlined,
              title: 'Show on home screen',
              subtitle: 'Display slow / normal / fast sat/vB estimates',
              value: feeSettings.showOnHome,
              onChanged: (v) =>
                  ref.read(feeSettingsProvider.notifier).setShowOnHome(v),
            ),
          ),
          // Display mode selector — only shown when enabled
          if (feeSettings.showOnHome) ...[
            Divider(height: 1, color: cs.outline),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Display mode',
                        style: Theme.of(context).textTheme.bodyMedium),
                  ),
                  SegmentedButton<bool>(
                    style: SegmentedButton.styleFrom(
                      backgroundColor: cs.surface,
                      selectedBackgroundColor:
                          AppColors.primary.withValues(alpha: 0.15),
                      selectedForegroundColor: AppColors.primary,
                      foregroundColor:
                          Theme.of(context).textTheme.bodyMedium?.color,
                      side: BorderSide(color: cs.outline),
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(
                        value: true,
                        label: Text('Compact'),
                      ),
                      ButtonSegment(
                        value: false,
                        label: Text('Normal'),
                      ),
                    ],
                    selected: {feeSettings.compact},
                    onSelectionChanged: (val) => ref
                        .read(feeSettingsProvider.notifier)
                        .setCompact(val.first),
                  ),
                ],
              ),
            ),
          ],
          Divider(height: 1, color: cs.outline),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: _SwitchRow(
              icon: Icons.widgets_outlined,
              title: 'Show in widget',
              subtitle: 'Fast fee rate on the home screen widget',
              value: feeSettings.showInWidget,
              onChanged: (v) =>
                  ref.read(feeSettingsProvider.notifier).setShowInWidget(v),
            ),
          ),
        ],
      ),
    );
  }
}

class _NetworkFeesLockedRow extends StatelessWidget {
  const _NetworkFeesLockedRow();

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
      // One node for a screen reader, read as a button whose lock says what
      // the "Pro" tag means.
      child: MergeSemantics(
        child: Semantics(
          button: true,
          child: InkWell(
            onTap: () => showProUpgradeSheet(context),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.speed_outlined,
                        color: AppColors.primary, size: 18),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Network fees on home',
                          style: Theme.of(context).textTheme.bodyLarge),
                    ),
                    const _ProLabel(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The small "Pro" tag on a setting that is part of Pro. A screen reader
/// hears the same lock label as on a [ProLockedRow].
class _ProLabel extends StatelessWidget {
  const _ProLabel();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: ProLockedRow.lockLabel,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
        ),
        child: const Text(
          'Pro',
          style: TextStyle(
            color: AppColors.primary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _WidgetSection extends StatefulWidget {
  @override
  State<_WidgetSection> createState() => _WidgetSectionState();
}

class _WidgetSectionState extends State<_WidgetSection> {
  int _sdkVersion = 0;
  bool _pinning = false;

  @override
  void initState() {
    super.initState();
    WidgetService.getSdkVersion().then((v) {
      if (mounted) setState(() => _sdkVersion = v);
    });
  }

  Future<void> _requestPin() async {
    setState(() => _pinning = true);
    final sent = await WidgetService.requestPinWidget();
    if (mounted) {
      setState(() => _pinning = false);
      if (!sent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Not supported on this launcher — use the manual steps below'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // requestPinAppWidget requires API 26+ (O), though most launchers only
    // support it from API 31 (Android 12). We show the button from API 26.
    final canPin = Platform.isAndroid && _sdkVersion >= 26;

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
              const Icon(Icons.widgets_outlined, color: AppColors.primary, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Live BTC price and net worth on your home screen',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          if (canPin) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: BorderSide(color: cs.outline),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _pinning ? null : _requestPin,
                icon: _pinning
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.primary,
                        ),
                      )
                    : const Icon(Icons.add_to_home_screen, size: 18),
                label: const Text('Add to Home Screen'),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Or manually: long-press your home screen → Widgets → Bag',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ] else if (Platform.isIOS) ...[
            const SizedBox(height: 14),
            _IOSWidgetSteps(cs: cs),
          ] else ...[
            const SizedBox(height: 12),
            Text(
              'Long-press your home screen → Widgets → Bag',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _IOSWidgetSteps extends StatelessWidget {
  final ColorScheme cs;
  const _IOSWidgetSteps({required this.cs});

  static int _iosMajorVersion() {
    try {
      // Platform.operatingSystemVersion on iOS: e.g. "17.4.1"
      final v = Platform.operatingSystemVersion.split('.').first;
      return int.parse(v);
    } catch (_) {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ios17 = _iosMajorVersion() >= 17;
    final steps = ios17
        ? [
            'Long-press any empty area on your home screen',
            'Tap \u201cEdit\u201d in the bottom-left corner',
            'Tap \u201cAdd Widget\u201d',
            'Search for \u201cBag\u201d, choose Small or Medium, tap \u201cAdd Widget\u201d',
          ]
        : [
            'Long-press any empty area on your home screen',
            'Tap the \u201c+\u201d button in the top-left corner',
            'Search for \u201cBag\u201d, choose Small or Medium, tap \u201cAdd Widget\u201d',
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < steps.length; i++) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${i + 1}.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  steps[i],
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (i < steps.length - 1) const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _ThemeSelector extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(themeModeProvider);
    return SegmentedButton<ThemeMode>(
      style: SegmentedButton.styleFrom(
        backgroundColor: Theme.of(context).colorScheme.surface,
        selectedBackgroundColor: AppColors.primary.withValues(alpha: 0.15),
        selectedForegroundColor: AppColors.primary,
        foregroundColor: Theme.of(context).textTheme.bodyMedium?.color,
        side: BorderSide(color: Theme.of(context).colorScheme.outline),
      ),
      segments: const [
        ButtonSegment(
          value: ThemeMode.system,
          icon: Icon(Icons.brightness_auto_outlined, size: 16),
          label: Text('System'),
        ),
        ButtonSegment(
          value: ThemeMode.light,
          icon: Icon(Icons.light_mode_outlined, size: 16),
          label: Text('Light'),
        ),
        ButtonSegment(
          value: ThemeMode.dark,
          icon: Icon(Icons.dark_mode_outlined, size: 16),
          label: Text('Dark'),
        ),
      ],
      selected: {current},
      onSelectionChanged: (val) =>
          ref.read(themeModeProvider.notifier).setMode(val.first),
    );
  }
}

class _SatsModeToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SatsModeToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outline),
      ),
      child: _SwitchRow(
        icon: Icons.bolt,
        title: 'Display in sats',
        subtitle: 'Show BTC amounts as satoshis (1 BTC = 100,000,000 sats)',
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

class _NotificationsSection extends StatefulWidget {
  @override
  State<_NotificationsSection> createState() => _NotificationsSectionState();
}

class _NotificationsSectionState extends State<_NotificationsSection> {
  bool _sending = false;

  Future<void> _sendTest() async {
    setState(() => _sending = true);
    final granted = await NotificationService.requestPermission();
    if (!granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notification permission denied')),
        );
      }
      if (mounted) setState(() => _sending = false);
      return;
    }
    await NotificationService.showPriceAlert(
      id: 0,
      title: 'Bag test notification',
      body: 'Price alerts are working correctly.',
    );
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
      ),
      child: Row(
        children: [
          const Icon(Icons.notifications_outlined,
              color: AppColors.primary, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Price alerts notify you when BTC hits your target',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: BorderSide(color: cs.outline),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            onPressed: _sending ? null : _sendTest,
            child: _sending
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.primary),
                  )
                : const Text('Test', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

class _DebugPanel extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proUnlocked = ref.watch(proUnlockedProvider);
    final cs = Theme.of(context).colorScheme;
    // A Material, not a coloured Container: the tiles paint on the nearest
    // Material, which a decorated box in between would hide.
    return Material(
      color: cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.primary.withValues(alpha: 0.4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            dense: true,
            leading: Icon(
              proUnlocked ? Icons.lock_open_outlined : Icons.lock_outline,
              color: AppColors.primary,
              size: 18,
            ),
            title: const Text('Pro tier unlocked'),
            subtitle: const Text('Toggle to test gated features'),
            trailing: Switch(
              value: proUnlocked,
              onChanged: (v) =>
                  ref.read(proUnlockedProvider.notifier).setUnlocked(v),
              activeThumbColor: AppColors.primary,
            ),
          ),
          const Divider(height: 1),
          ListTile(
            dense: true,
            leading: const Icon(Icons.restart_alt_outlined,
                color: AppColors.primary, size: 18),
            title: const Text('Reset onboarding'),
            subtitle: const Text('Show onboarding flow on next launch'),
            trailing: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: BorderSide(color: AppColors.primary.withValues(alpha: 0.4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () async {
                await ref
                    .read(sharedPreferencesProvider)
                    .setBool(AppConstants.keyOnboardingComplete, false);
                if (context.mounted) context.go('/onboarding');
              },
              child: const Text('Reset', style: TextStyle(fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings' way to Pro for a free user: what Pro adds and, in the store
/// builds, its price. Opens the Pro sheet.
class _BagProRow extends ConsumerWidget {
  const _BagProRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final price = ref.watch(proPriceProvider).valueOrNull;
    const pitch =
        'Watch-only wallets, Tor built in and a privacy health check.';

    return Material(
      color: AppColors.primary.withValues(alpha: 0.08),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: InkWell(
        onTap: () => showProUpgradeSheet(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.verified_user_outlined,
                    color: AppColors.onPrimary, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Bag Pro',
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      price == null ? pitch : '$pitch $price once.',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontSize: 13, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right,
                  color: AppColors.primary, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// One setting with a switch: an icon, a title over a subtitle, and the
/// switch. The caller adds the padding and any card around it.
class _SwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.primary, size: 18),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.bodyLarge),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: AppColors.primary,
        ),
      ],
    );
  }
}

class _BiometricLockTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_BiometricLockTile> createState() => _BiometricLockTileState();
}

class _BiometricLockTileState extends ConsumerState<_BiometricLockTile> {
  bio.BiometricAvailability _availability = bio.BiometricAvailability.available;

  @override
  void initState() {
    super.initState();
    bio.checkAvailability().then((v) {
      if (mounted) setState(() => _availability = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = ref.watch(biometricLockProvider);
    final available = _availability == bio.BiometricAvailability.available;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: cs.outline),
          ),
          child: _SwitchRow(
            icon: Icons.lock_outline,
            title: 'Require unlock to open',
            subtitle: available
                ? 'Use fingerprint, face, or screen lock PIN'
                : 'Set a screen lock on your device to use this',
            value: enabled && available,
            onChanged: available
                ? (v) => ref.read(biometricLockProvider.notifier).setEnabled(v)
                : null,
          ),
        ),
        if (enabled && available) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 4),
              Icon(Icons.widgets_outlined, size: 13, color: cs.secondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'The home screen widget will still show your portfolio — widgets run outside the app and cannot be locked.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _AboutTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String trailing;
  final VoidCallback? onTap;

  const _AboutTile({
    required this.icon,
    required this.label,
    required this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(icon, color: Theme.of(context).colorScheme.secondary, size: 18),
      title: Text(label, style: Theme.of(context).textTheme.bodyLarge),
      trailing: Text(
        trailing,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: onTap != null ? AppColors.primary : Theme.of(context).textTheme.bodySmall!.color!,
            ),
      ),
      onTap: onTap,
    );
  }
}

// ── License key viewer (Pro, direct flavor only) ──────────────────────────────

class _LicenseKeyTile extends StatefulWidget {
  const _LicenseKeyTile();

  @override
  State<_LicenseKeyTile> createState() => _LicenseKeyTileState();
}

class _LicenseKeyTileState extends State<_LicenseKeyTile> {
  bool _loading = false;

  static const _storage = FlutterSecureStorage();

  Future<void> _viewKey() async {
    setState(() => _loading = true);
    try {
      final availability = await bio.checkAvailability();
      if (!mounted) return;

      if (availability != bio.BiometricAvailability.available) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'No screen lock set up. Add a PIN or fingerprint to protect your license key.'),
        ));
        return;
      }

      final authenticated = await bio.authenticateToView(
        reason: 'Authenticate to view your license key',
      );
      if (!mounted) return;

      if (!authenticated) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Authentication cancelled')),
        );
        return;
      }

      final token = await _storage.read(key: AppConstants.keyLicenseToken);
      if (!mounted) return;

      if (token == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('License key not found')),
        );
        return;
      }

      final formatted = LicenseKeyService.formatForDisplay(token);
      // FLAG_SECURE on Android, the privacy cover on iOS; undone in
      // `finally`.
      await SecretOnScreen.guard(() async {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('License Key'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Store this key safely. You can use it to restore Pro on a new device.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SelectableText(
                  formatted,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: token));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('License key copied to clipboard')),
                  );
                },
                child: const Text('Copy'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: _loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.primary),
            )
          : const Icon(Icons.fingerprint, color: AppColors.primary, size: 18),
      title: Text('License Key', style: Theme.of(context).textTheme.bodyLarge),
      trailing: Text(
        'View →',
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: AppColors.primary),
      ),
      onTap: _loading ? null : _viewKey,
    );
  }
}
