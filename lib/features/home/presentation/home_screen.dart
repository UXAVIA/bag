import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/btc_format.dart';
import '../../../models/dca_entry.dart';
import '../../../models/fee_estimate.dart';
import '../../../models/price_data.dart';
import '../../../providers/alerts_provider.dart';
import '../../../providers/dca_provider.dart';
import '../../../providers/fee_alerts_provider.dart';
import '../../../providers/fee_provider.dart';
import '../../../providers/fee_settings_provider.dart';
import '../../../providers/health_check_provider.dart';
import '../../../providers/portfolio_provider.dart';
import '../../../providers/price_provider.dart';
import '../../../providers/purchase_provider.dart';
import '../../../providers/sats_mode_provider.dart';
import '../../../providers/wallets_provider.dart';
import '../../../services/price_service.dart';
import '../../../widgets/alerts_sheet.dart';
import '../../../widgets/net_worth_card.dart';
import '../../../widgets/price_chart.dart';

const _timeframes = [
  (label: '1D', days: 1),
  (label: '1W', days: 7),
  (label: '1M', days: 30),
  (label: '1Y', days: 365),
  (label: '5Y', days: 1825),
  (label: 'ALL', days: 0),
];

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final portfolio = ref.watch(portfolioProvider);
    final priceAsync = ref.watch(priceProvider);
    final selectedDays = ref.watch(selectedTimeframeDaysProvider);
    final dcaEntries = ref.watch(dcaProvider);

    // Timeframe-aware % change: for non-1D frames, compute open→close from
    // chart data. BTC % change is currency-independent, so one fetch covers all
    // currency cards. Falls back to null (cards use 24h from priceData).
    final primaryCurrency = portfolio.selectedCurrencies.isNotEmpty
        ? portfolio.selectedCurrencies.first
        : 'usd';
    double? timeframeChange;
    if (selectedDays != 1) {
      final chartData = ref
          .watch(chartDataProvider((primaryCurrency, selectedDays)))
          .valueOrNull;
      if (chartData != null && chartData.length >= 2) {
        final first = chartData.first.$2;
        final last = chartData.last.$2;
        if (first > 0) timeframeChange = (last - first) / first * 100;
      }
    }

    final alerts = ref.watch(alertsProvider);
    final feeAlerts = ref.watch(feeAlertsProvider);
    final activeAlertCount = alerts.where((a) => !a.fired).length +
        feeAlerts.where((a) => !a.fired).length;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leadingWidth: 120,
        leading: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 0, 10),
          child: SvgPicture.asset(
            Theme.of(context).brightness == Brightness.dark
                ? 'assets/images/logo_text.svg'
                : 'assets/images/logo_text_light.svg',
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
          ),
        ),
        actions: [
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: Icon(
                  activeAlertCount > 0
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_none_outlined,
                ),
                tooltip: 'Price alerts',
                onPressed: () => showAlertsSheet(context),
              ),
              if (activeAlertCount > 0)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        backgroundColor: Theme.of(context).colorScheme.surface,
        onRefresh: () async {
          // Only clear the visible chart — invalidating all at once fires
          // simultaneous requests and triggers 429s.
          final currency = portfolio.selectedCurrencies.isNotEmpty
              ? portfolio.selectedCurrencies.first
              : 'usd';
          ref.read(priceServiceProvider).clearChartCache(currency, selectedDays);
          ref.invalidate(chartDataProvider((currency, selectedDays)));
          await Future.wait([
            ref.read(priceProvider.notifier).refresh(),
            ref.read(walletsProvider.notifier).scanAllIfStale(),
          ]);
        },
        child: priceAsync.when(
          loading: () => _buildBody(
            context: context,
            ref: ref,
            portfolio: portfolio,
            selectedDays: selectedDays,
            priceWidget: _LoadingCards(count: portfolio.selectedCurrencies.length),
            chartWidget: _ChartSection(
              portfolio: portfolio,
              selectedDays: selectedDays,
              ref: ref,
            ),
          ),
          error: (error, _) => _buildBody(
            context: context,
            ref: ref,
            portfolio: portfolio,
            selectedDays: selectedDays,
            priceWidget: _ErrorCard(
              onRetry: () => ref.read(priceProvider.notifier).refresh(),
            ),
            chartWidget: const SizedBox.shrink(),
          ),
          data: (priceData) {
            final currencies = portfolio.selectedCurrencies;
            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (portfolio.hasAmount)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(13, 8, 16, 16),
                    sliver: SliverToBoxAdapter(
                      child: _BtcAmountRow(portfolio: portfolio),
                    ),
                  ),
                if (!portfolio.hasAmount)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                    sliver: SliverToBoxAdapter(
                      child: _NoAmountPrompt(
                        priceData: priceData,
                        selectedDays: selectedDays,
                        timeframeChange: timeframeChange,
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverReorderableList(
                      itemCount: currencies.length,
                      onReorder: (oldIndex, newIndex) {
                        final list = [...currencies];
                        if (newIndex > oldIndex) newIndex--;
                        list.insert(newIndex, list.removeAt(oldIndex));
                        ref.read(portfolioProvider.notifier).setCurrencies(list);
                      },
                      itemBuilder: (context, index) {
                        final c = currencies[index];
                        final matchingEntries = dcaEntries
                            .where((e) => e.currency.toLowerCase() == c.toLowerCase())
                            .toList();
                        final dcaStats = matchingEntries.isNotEmpty
                            ? DcaStats.fromEntries(
                                matchingEntries,
                                viewCurrency: c,
                                currentPrices: priceData.prices,
                              )
                            : null;
                        // For 1D use the 24h value from the price API;
                        // for other frames use the chart-computed change.
                        final cardChange = selectedDays == 1
                            ? priceData.changeFor(c)
                            : timeframeChange;
                        return ReorderableDelayedDragStartListener(
                          key: ValueKey(c),
                          index: index,
                          child: Dismissible(
                            key: ValueKey('dismiss_$c'),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 24),
                              decoration: BoxDecoration(
                                color: AppColors.negative,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.delete_outline,
                                  color: Colors.white, size: 24),
                            ),
                            confirmDismiss: (_) async {
                              if (currencies.length <= 1) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                        'Keep at least one display currency'),
                                  ),
                                );
                                return false;
                              }
                              return true;
                            },
                            onDismissed: (_) {
                              final updated = currencies
                                  .where((cur) => cur != c)
                                  .toList();
                              ref
                                  .read(portfolioProvider.notifier)
                                  .setCurrencies(updated);
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: NetWorthCard(
                                currencyCode: c,
                                portfolio: portfolio,
                                priceData: priceData,
                                dcaStats: dcaStats,
                                timeframeChange: cardChange,
                                timeframeDays: selectedDays,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'PRICE CHART',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                reverse: true,
                                child: Row(
                                  children: _timeframes.map((tf) {
                                    return Padding(
                                      padding: const EdgeInsets.only(left: 4),
                                      child: TimeframeButton(
                                        label: tf.label,
                                        isSelected: selectedDays == tf.days,
                                        onTap: () => ref
                                            .read(selectedTimeframeDaysProvider.notifier)
                                            .state = tf.days,
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _ChartSection(
                          portfolio: portfolio,
                          selectedDays: selectedDays,
                          ref: ref,
                        ),
                        const SizedBox(height: 16),
                        _LastUpdatedRow(
                          fetchedAt: priceData.fetchedAt,
                          isStale: priceData.isStale,
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(
                  child: _FeeSectionSliver(),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildBody({
    required BuildContext context,
    required WidgetRef ref,
    required portfolio,
    required int selectedDays,
    required Widget priceWidget,
    required Widget chartWidget,
    DateTime? lastUpdated,
    bool isStale = false,
  }) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // BTC holding row — only shown once a balance is set
        if (portfolio.hasAmount) ...[
          _BtcAmountRow(portfolio: portfolio),
          const SizedBox(height: 20),
        ],

        // Net worth cards
        if (!portfolio.hasAmount) _NoAmountPrompt() else priceWidget,
        const SizedBox(height: 24),

        // Chart section header
        Row(
          children: [
            Text(
              'PRICE CHART',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(width: 8),
            // Timeframe selector — scrollable so 6 buttons don't overflow
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true, // keep rightmost buttons visible by default
                child: Row(
                  children: _timeframes.map((tf) {
                    return Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: TimeframeButton(
                        label: tf.label,
                        isSelected: selectedDays == tf.days,
                        onTap: () => ref
                            .read(selectedTimeframeDaysProvider.notifier)
                            .state = tf.days,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        chartWidget,

        // Last updated
        if (lastUpdated != null) ...[
          const SizedBox(height: 16),
          _LastUpdatedRow(fetchedAt: lastUpdated, isStale: isStale),
        ],
      ],
    );
  }
}

class _BtcAmountRow extends ConsumerWidget {
  final dynamic portfolio;

  const _BtcAmountRow({required this.portfolio});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final satsMode = ref.watch(satsModeProvider);
    final hasWallets = ref.watch(walletsProvider.select((w) => w.isNotEmpty));
    final isScanning =
        ref.watch(walletsProvider.select((w) => w.any((e) => e.isScanning)));
    final btcStr = portfolio.hasAmount
        ? formatBtcAmount(portfolio.btcAmount, satsMode: satsMode)
        : 'Tap ⚙ to set your BTC amount';

    // Only rebuild when health check transitions to Done — not on every progress tick.
    final healthResult = ref.watch(
      portfolioHealthCheckProvider
          .select((s) => s is HealthCheckDone ? s.result : null),
    );

    return Row(
      children: [
        GestureDetector(
          onTap: () => ref.read(satsModeProvider.notifier).toggle(),
          behavior: HitTestBehavior.opaque,
          child: BtcUnitIcon(satsMode: satsMode, color: AppColors.primary, size: 22),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            btcStr,
            style: portfolio.hasAmount
                ? Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    )
                : Theme.of(context).textTheme.bodyMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (hasWallets) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: isScanning
                ? 'Scanning wallet…'
                : 'Balance from watch-only wallet',
            child: isScanning
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                  )
                : const Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 14,
                    color: AppColors.primary,
                  ),
          ),
        ],
        if (healthResult != null) ...[
          const Spacer(),
          _HealthChip(result: healthResult),
        ],
      ],
    );
  }
}

class _NoAmountPrompt extends ConsumerWidget {
  final PriceData? priceData;
  final int selectedDays;
  final double? timeframeChange;

  const _NoAmountPrompt({
    this.priceData,
    this.selectedDays = 1,
    this.timeframeChange,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final portfolio = ref.watch(portfolioProvider);
    final currency = portfolio.selectedCurrencies.isNotEmpty
        ? portfolio.selectedCurrencies.first
        : 'usd';
    final price = priceData?.priceFor(currency);
    final fmt = NumberFormat.simpleCurrency(name: currency.toUpperCase());

    // Mirror how NetWorthCard works: 1D uses the 24h value from the API;
    // any other timeframe uses the chart-computed open→close change.
    final displayChange = selectedDays == 1
        ? priceData?.changeFor(currency)
        : timeframeChange;
    final tfLabel = _timeframes
        .firstWhere((t) => t.days == selectedDays,
            orElse: () => (label: '1D', days: 1))
        .label;

    return GestureDetector(
      onTap: () => context.go('/settings'),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
        ),
        child: Column(
          children: [
            if (price != null) ...[
              Text(
                fmt.format(price),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              if (displayChange != null) ...[
                const SizedBox(height: 4),
                Text(
                  '${displayChange >= 0 ? '+' : ''}${displayChange.toStringAsFixed(2)}% · $tfLabel',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: displayChange >= 0
                            ? AppColors.positive
                            : AppColors.negative,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ],
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 12),
            ],
            const Icon(Icons.currency_bitcoin, color: AppColors.primary, size: 28),
            const SizedBox(height: 8),
            Text(
              'Set up your portfolio',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap to enter your BTC balance',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.primary.withValues(alpha: 0.75),
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartSection extends ConsumerWidget {
  final dynamic portfolio;
  final int selectedDays;
  final WidgetRef ref;

  const _ChartSection({
    required this.portfolio,
    required this.selectedDays,
    required this.ref,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currency = portfolio.selectedCurrencies.isNotEmpty
        ? portfolio.selectedCurrencies.first
        : 'usd';

    final chartAsync = ref.watch(chartDataProvider((currency, selectedDays)));

    return chartAsync.when(
      loading: () => const SizedBox(
        height: 180,
        child: Center(
          child: CircularProgressIndicator(
            color: AppColors.primary,
            strokeWidth: 2,
          ),
        ),
      ),
      error: (_, __) => SizedBox(
        height: 180,
        child: Center(
          child: Text(
            'Chart unavailable',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
      data: (data) => PriceChart(
        data: data,
        currencyCode: currency,
        days: selectedDays,
      ),
    );
  }
}

class _LoadingCards extends StatelessWidget {
  final int count;

  const _LoadingCards({required this.count});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: List.generate(
        count.clamp(1, 3),
        (i) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            height: 110,
            width: double.infinity,
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.outline),
            ),
            child: const Center(
              child: CircularProgressIndicator(
                color: AppColors.primary,
                strokeWidth: 2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorCard({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
      ),
      child: Column(
        children: [
          Icon(Icons.wifi_off_outlined, color: Theme.of(context).textTheme.bodySmall!.color!, size: 28),
          const SizedBox(height: 12),
          Text('Unable to fetch price', style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 4),
          Text(
            'Pull down to retry',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _LastUpdatedRow extends StatelessWidget {
  final DateTime fetchedAt;
  final bool isStale;

  const _LastUpdatedRow({required this.fetchedAt, required this.isStale});

  @override
  Widget build(BuildContext context) {
    final formatted = DateFormat('HH:mm').format(fetchedAt);
    return Row(
      children: [
        Icon(
          isStale ? Icons.warning_amber_outlined : Icons.check_circle_outline,
          size: 12,
          color: isStale ? AppColors.negative : Theme.of(context).textTheme.bodySmall!.color!,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            isStale ? 'Stale data — last updated $formatted' : 'Updated $formatted',
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// ── Portfolio health chip (inline with BTC holdings row) ─────────────────────

class _HealthChip extends StatelessWidget {
  final dynamic result;

  const _HealthChip({required this.result});

  @override
  Widget build(BuildContext context) {
    final score = result.score.score as int;
    final scoreColor = AppColors.scoreColor(score);

    return GestureDetector(
      onTap: () => context.go('/settings/wallet-privacy/health-check'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: scoreColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scoreColor.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.health_and_safety_outlined, size: 13, color: scoreColor),
            const SizedBox(width: 5),
            Text(
              '$score ${AppColors.scoreLetter(score)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scoreColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
            ),
            const SizedBox(width: 4),
            Text(
              'Health',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scoreColor.withValues(alpha: 0.8),
                    fontSize: 11,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Network fee section ───────────────────────────────────────────────────────

// Standard P2WPKH transaction size used for fiat cost estimates (1-in 2-out).
// Same reference size used by mempool.space.
const _standardTxVBytes = 140;

/// Returns the estimated fiat cost of a standard transaction at [rate] sat/vB
/// given a current [btcPrice] in fiat.
double _fiatCostForRate(double rate, double btcPrice) =>
    rate * _standardTxVBytes / 1e8 * btcPrice;

class _FeeSectionSliver extends ConsumerWidget {
  const _FeeSectionSliver();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proUnlocked = ref.watch(proUnlockedProvider);
    final feeSettings = ref.watch(feeSettingsProvider);

    if (!proUnlocked || !feeSettings.showOnHome) return const SizedBox.shrink();

    final feeAsync = ref.watch(feeProvider);

    // Grab BTC price in the primary display currency for cost estimates.
    final portfolio = ref.watch(portfolioProvider);
    final primaryCurrency = portfolio.selectedCurrencies.isNotEmpty
        ? portfolio.selectedCurrencies.first
        : 'usd';
    final btcPrice =
        ref.watch(priceProvider).valueOrNull?.priceFor(primaryCurrency);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('NETWORK FEES',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          feeAsync.when(
            loading: () => const _FeeLoadingRow(),
            error: (_, __) => const _FeeErrorRow(),
            data: (estimate) {
              if (estimate == null) return const _FeeErrorRow();
              return feeSettings.compact
                  ? _FeeCompactRow(
                      estimate: estimate,
                      btcPrice: btcPrice,
                      currency: primaryCurrency,
                    )
                  : _FeeNormalRow(
                      estimate: estimate,
                      btcPrice: btcPrice,
                      currency: primaryCurrency,
                    );
            },
          ),
        ],
      ),
    );
  }
}

class _FeeCompactRow extends StatelessWidget {
  final FeeEstimate estimate;
  final double? btcPrice;
  final String currency;

  const _FeeCompactRow({
    required this.estimate,
    required this.btcPrice,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final allSame = estimate.fast == estimate.standard &&
        estimate.standard == estimate.slow;

    // Fiat cost based on the fast rate (best-case, shown as approximate).
    String? costStr;
    if (btcPrice != null) {
      final cost = _fiatCostForRate(estimate.fast, btcPrice!);
      final fmt = NumberFormat.simpleCurrency(name: currency.toUpperCase());
      costStr = '~${fmt.format(cost)}';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outline),
      ),
      child: Row(
        children: [
          const Icon(Icons.bolt, color: AppColors.primary, size: 16),
          const SizedBox(width: 8),
          if (allSame) ...[
            Text(
              'Low congestion',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(width: 6),
            Text('·',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.outline)),
            const SizedBox(width: 6),
            Text(
              '${estimate.fast.toStringAsFixed(0)} sat/vB',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ] else ...[
            Text(
              estimate.slow.toStringAsFixed(0),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text('·',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.outline)),
            ),
            Text(
              estimate.standard.toStringAsFixed(0),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text('·',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.outline)),
            ),
            Text(
              estimate.fast.toStringAsFixed(0),
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 6),
            Text('sat/vB',
                style: Theme.of(context).textTheme.bodySmall),
          ],
          const Spacer(),
          if (costStr != null)
            Text(costStr, style: Theme.of(context).textTheme.bodySmall)
          else if (!allSame)
            Text('slow · normal · fast',
                style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _FeeNormalRow extends StatelessWidget {
  final FeeEstimate estimate;
  final double? btcPrice;
  final String currency;

  const _FeeNormalRow({
    required this.estimate,
    required this.btcPrice,
    required this.currency,
  });

  String? _cost(double rate) {
    if (btcPrice == null) return null;
    final cost = _fiatCostForRate(rate, btcPrice!);
    final fmt = NumberFormat.simpleCurrency(name: currency.toUpperCase());
    return '~${fmt.format(cost)}';
  }

  @override
  Widget build(BuildContext context) {
    final allSame = estimate.fast == estimate.standard &&
        estimate.standard == estimate.slow;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (allSame)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline,
                    size: 13,
                    color: Theme.of(context).textTheme.bodySmall!.color!),
                const SizedBox(width: 4),
                Text(
                  'Low congestion — all tiers at minimum fee',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: _FeeTile(
                label: 'Slow',
                rate: estimate.slow,
                time: '~1 hour',
                fiatCost: _cost(estimate.slow),
                highlight: false,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _FeeTile(
                label: 'Normal',
                rate: estimate.standard,
                time: '~30 min',
                fiatCost: _cost(estimate.standard),
                highlight: false,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _FeeTile(
                label: 'Fast',
                rate: estimate.fast,
                time: '~10 min',
                fiatCost: _cost(estimate.fast),
                highlight: true,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _FeeTile extends StatelessWidget {
  final String label;
  final double rate;
  final String time;
  final String? fiatCost;
  final bool highlight;

  const _FeeTile({
    required this.label,
    required this.rate,
    required this.time,
    required this.highlight,
    this.fiatCost,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = highlight ? AppColors.primary : cs.onSurface;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: highlight
            ? AppColors.primary.withValues(alpha: 0.06)
            : cs.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: highlight
              ? AppColors.primary.withValues(alpha: 0.3)
              : cs.outline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                rate.toStringAsFixed(0),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(width: 3),
              Text(
                'sat/vB',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant, fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            time,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurfaceVariant, fontSize: 10),
          ),
          if (fiatCost != null) ...[
            const SizedBox(height: 2),
            Text(
              fiatCost!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FeeLoadingRow extends StatelessWidget {
  const _FeeLoadingRow();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outline),
      ),
      child: const Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: AppColors.primary),
        ),
      ),
    );
  }
}

class _FeeErrorRow extends StatelessWidget {
  const _FeeErrorRow();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outline),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off_outlined, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            'Fee data unavailable',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

