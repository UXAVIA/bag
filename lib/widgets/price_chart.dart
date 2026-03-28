import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/constants/supported_currencies.dart';
import '../core/theme/app_theme.dart';

class PriceChart extends StatelessWidget {
  final List<(DateTime, double)> data;
  final String currencyCode;
  final int days;
  final bool showChangeLabel;

  const PriceChart({
    super.key,
    required this.data,
    required this.currencyCode,
    required this.days,
    this.showChangeLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    final chartHeight = showChangeLabel ? 180.0 : 120.0;
    if (data.isEmpty) return SizedBox(height: showChangeLabel ? 204 : 120);

    final cs = Theme.of(context).colorScheme;
    final textMutedColor = Theme.of(context).textTheme.bodySmall!.color!;

    final spots = data
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value.$2))
        .toList();

    final prices = data.map((e) => e.$2).toList();
    final minY = prices.reduce((a, b) => a < b ? a : b);
    final maxY = prices.reduce((a, b) => a > b ? a : b);
    final padding = (maxY - minY) * 0.08;

    final info = supportedCurrencies[currencyCode];
    final symbol = info?.symbol ?? currencyCode.toUpperCase();

    final changePercent =
        prices.first > 0 ? (prices.last - prices.first) / prices.first * 100 : 0.0;
    final isPositive = changePercent >= 0;
    final pctText =
        '${isPositive ? '+' : ''}${changePercent.toStringAsFixed(1)}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (showChangeLabel) ...[
          Text(
            pctText,
            style: TextStyle(
              color: isPositive ? AppColors.positive : AppColors.negative,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
        ],
        SizedBox(
          height: chartHeight,
          child: LineChart(
            LineChartData(
              minY: minY - padding,
              maxY: maxY + padding,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: (maxY - minY + padding * 2) / 3,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: cs.onSurface.withValues(alpha: 0.06),
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    interval: _labelInterval(data.length),
                    getTitlesWidget: (value, meta) {
                      final idx = value.toInt();
                      if (idx < 0 || idx >= data.length) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _formatLabel(data[idx].$1, days),
                          style: TextStyle(
                            color: textMutedColor,
                            fontSize: 10,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => cs.surface,
                  getTooltipItems: (spots) => spots.map((s) {
                    final idx = s.spotIndex;
                    final dt = data[idx].$1;
                    final price = s.y;
                    final formatter = NumberFormat.currency(
                      symbol: symbol,
                      decimalDigits: 0,
                    );
                    return LineTooltipItem(
                      '${formatter.format(price)}\n',
                      TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                      children: [
                        TextSpan(
                          text: DateFormat('d MMM, HH:mm').format(dt),
                          style: TextStyle(
                            color: cs.secondary,
                            fontWeight: FontWeight.w400,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true,
                  curveSmoothness: 0.3,
                  color: AppColors.primary,
                  barWidth: 2,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.primary.withValues(alpha: 0.15),
                        AppColors.primary.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            duration: const Duration(milliseconds: 250),
          ),
        ),
      ],
    );
  }

  double _labelInterval(int dataLength) {
    if (dataLength <= 8) return 1;
    return (dataLength / 4).floorToDouble();
  }

  String _formatLabel(DateTime dt, int days) {
    if (days <= 1) return DateFormat('HH:mm').format(dt);
    if (days <= 7) return DateFormat('EEE').format(dt);
    if (days <= 30) return DateFormat('d MMM').format(dt);
    if (days <= 365) return DateFormat('MMM').format(dt);
    return DateFormat("MMM ''yy").format(dt);
  }
}

class TimeframeButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const TimeframeButton({
    super.key,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? AppColors.primary.withValues(alpha: 0.5) : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? AppColors.primary : Theme.of(context).textTheme.bodySmall!.color!,
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
