import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/constants/supported_currencies.dart';
import '../core/theme/app_theme.dart';
import '../models/dca_entry.dart';
import '../models/price_data.dart';
import '../models/portfolio.dart';

class NetWorthCard extends StatelessWidget {
  final String currencyCode;
  final Portfolio portfolio;
  final PriceData priceData;
  final DcaStats? dcaStats;

  /// Override the change % shown in the chip (e.g. computed from chart data).
  /// When null, falls back to the 24h change from [priceData].
  final double? timeframeChange;

  /// The selected timeframe in days — used to label the change chip.
  final int timeframeDays;

  const NetWorthCard({
    super.key,
    required this.currencyCode,
    required this.portfolio,
    required this.priceData,
    this.dcaStats,
    this.timeframeChange,
    this.timeframeDays = 1,
  });

  static String _periodLabel(int days) => switch (days) {
        1 => '24h',
        7 => '1W',
        30 => '1M',
        365 => '1Y',
        1825 => '5Y',
        _ => 'ALL',
      };

  @override
  Widget build(BuildContext context) {
    final info = supportedCurrencies[currencyCode];
    final btcPrice = priceData.priceFor(currencyCode);
    final change = timeframeChange ?? priceData.changeFor(currencyCode);

    if (info == null || btcPrice == null) return const SizedBox.shrink();

    final netWorth = portfolio.netWorthIn(currencyCode, btcPrice);
    final isPositive = (change ?? 0) >= 0;

    final worthFormatter = NumberFormat.currency(
      symbol: info.symbol,
      decimalDigits: info.decimalDigits,
      locale: 'en_US',
    );
    final priceFormatter = NumberFormat.currency(
      symbol: info.symbol,
      decimalDigits: 2,
      locale: 'en_US',
    );

    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                info.code,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (change != null)
                _ChangeChip(
                  change: change,
                  isPositive: isPositive,
                  periodLabel: _periodLabel(timeframeDays),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // Net worth — large
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              portfolio.hasAmount
                  ? worthFormatter.format(netWorth)
                  : '—',
              style: Theme.of(context).textTheme.displayLarge,
            ),
          ),
          const SizedBox(height: 6),
          // BTC spot price
          Text(
            'BTC ${priceFormatter.format(btcPrice)}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (dcaStats != null && dcaStats!.hasPriceData && dcaStats!.pnl != null) ...[
            const SizedBox(height: 10),
            _DcaPnlRow(
              pnl: dcaStats!.pnl!,
              pnlPercent: dcaStats!.pnlPercent!,
              isProfit: dcaStats!.isProfit,
              formatter: worthFormatter,
            ),
          ],
        ],
      ),
    );
  }
}

class _DcaPnlRow extends StatelessWidget {
  final double pnl;
  final double pnlPercent;
  final bool isProfit;
  final NumberFormat formatter;

  const _DcaPnlRow({
    required this.pnl,
    required this.pnlPercent,
    required this.isProfit,
    required this.formatter,
  });

  @override
  Widget build(BuildContext context) {
    final color = isProfit ? AppColors.positive : AppColors.negative;
    final sign = pnl >= 0 ? '+' : '';

    return Row(
      children: [
        Text(
          'DCA P/L',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(width: 8),
        Text(
          '$sign${formatter.format(pnl)}',
          style: TextStyle(
            color: color,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            '$sign${pnlPercent.toStringAsFixed(1)}%',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _ChangeChip extends StatelessWidget {
  final double change;
  final bool isPositive;
  final String periodLabel;

  const _ChangeChip({
    required this.change,
    required this.isPositive,
    required this.periodLabel,
  });

  @override
  Widget build(BuildContext context) {
    final color = isPositive ? AppColors.positive : AppColors.negative;
    final sign = isPositive ? '+' : '';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$sign${change.toStringAsFixed(2)}% · $periodLabel',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
