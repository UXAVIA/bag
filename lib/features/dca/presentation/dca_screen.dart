import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/supported_currencies.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/btc_format.dart';
import '../../../models/dca_entry.dart';
import '../../../providers/dca_provider.dart';
import '../../../providers/portfolio_provider.dart';
import '../../../providers/price_provider.dart';
import '../../../providers/sats_mode_provider.dart';
import '../../../services/price_service.dart';

/// Which currency to view DCA stats in. Defaults to the first selected
/// currency; survives navigation but resets if that currency is removed.
final dcaViewCurrencyProvider = StateProvider<String>((ref) {
  final currencies = ref.read(portfolioProvider).selectedCurrencies;
  return currencies.isNotEmpty ? currencies.first : 'usd';
});

class DcaScreen extends ConsumerWidget {
  const DcaScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(dcaProvider);
    final priceAsync = ref.watch(priceProvider);
    final portfolio = ref.watch(portfolioProvider);
    final selectedCurrencies = portfolio.selectedCurrencies;
    final viewCurrency = ref.watch(dcaViewCurrencyProvider);

    // If the view currency was removed from selected currencies, reset to first.
    final effectiveView = selectedCurrencies.contains(viewCurrency)
        ? viewCurrency
        : (selectedCurrencies.isNotEmpty ? selectedCurrencies.first : 'usd');
    if (effectiveView != viewCurrency) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(dcaViewCurrencyProvider.notifier).state = effectiveView;
      });
    }

    final satsMode = ref.watch(satsModeProvider);
    final currentPrices = priceAsync.valueOrNull?.prices;
    final stats = DcaStats.fromEntries(
      entries,
      viewCurrency: effectiveView,
      currentPrices: currentPrices,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('DCA Tracker'),
        actions: [
          if (entries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Add purchase',
              onPressed: () => _showAddEntrySheet(context, ref, effectiveView),
            ),
        ],
      ),
      body: entries.isEmpty
          ? _EmptyState(
              onAdd: () => _showAddEntrySheet(context, ref, effectiveView),
            )
          : RefreshIndicator(
              color: AppColors.primary,
              onRefresh: () => ref.read(priceProvider.notifier).refresh(),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  // Currency tab selector (only shown when >1 currency selected)
                  if (selectedCurrencies.length > 1) ...[
                    _CurrencyTabBar(
                      currencies: selectedCurrencies,
                      selected: effectiveView,
                      onChanged: (c) =>
                          ref.read(dcaViewCurrencyProvider.notifier).state = c,
                    ),
                    const SizedBox(height: 12),
                  ],
                  _StatsCard(stats: stats, currency: effectiveView, satsMode: satsMode),
                  const SizedBox(height: 24),
                  _EntriesHeader(
                    onAdd: () => _showAddEntrySheet(context, ref, effectiveView),
                  ),
                  const SizedBox(height: 8),
                  ...entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _EntryTile(
                        entry: e,
                        satsMode: satsMode,
                        onDelete: () =>
                            ref.read(dcaProvider.notifier).removeEntry(e.id),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  void _showAddEntrySheet(
    BuildContext context,
    WidgetRef ref,
    String defaultCurrency,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _AddEntrySheet(defaultCurrency: defaultCurrency),
    );
  }
}

// ─── Currency Tab Bar ─────────────────────────────────────────────────────────

class _CurrencyTabBar extends StatelessWidget {
  final List<String> currencies;
  final String selected;
  final ValueChanged<String> onChanged;

  const _CurrencyTabBar({
    required this.currencies,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: currencies.map((c) {
        final info = supportedCurrencies[c];
        final isSelected = c == selected;
        return Expanded(
          child: GestureDetector(
            onTap: () => onChanged(c),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primary.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected
                      ? AppColors.primary
                      : Theme.of(context).colorScheme.outline,
                ),
              ),
              child: Column(
                children: [
                  Text(
                    info?.symbol ?? c.toUpperCase(),
                    style: TextStyle(
                      color: isSelected
                          ? AppColors.primary
                          : Theme.of(context).colorScheme.secondary,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  Text(
                    info?.code ?? c.toUpperCase(),
                    style: TextStyle(
                      color: isSelected
                          ? AppColors.primary
                          : Theme.of(context).colorScheme.secondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ─── Stats Card ──────────────────────────────────────────────────────────────

class _StatsCard extends StatelessWidget {
  final DcaStats stats;
  final String currency;
  final bool satsMode;

  const _StatsCard({required this.stats, required this.currency, required this.satsMode});

  @override
  Widget build(BuildContext context) {
    final info = supportedCurrencies[currency];
    final symbol = info?.symbol ?? currency.toUpperCase();
    final decimals = info?.decimalDigits ?? 2;

    final priceFormatter =
        NumberFormat.currency(symbol: symbol, decimalDigits: decimals);
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SUMMARY', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),

          // Avg buy vs current price
          Row(
            children: [
              Expanded(
                child: _StatItem(
                  label: 'Avg buy price',
                  value: stats.avgBuyPrice > 0
                      ? priceFormatter.format(stats.avgBuyPrice)
                      : '—',
                ),
              ),
              Expanded(
                child: _StatItem(
                  label: 'Current price',
                  value: stats.currentPrice != null
                      ? priceFormatter.format(stats.currentPrice)
                      : '—',
                  valueColor: stats.hasPriceData
                      ? (stats.isProfit ? AppColors.positive : AppColors.negative)
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: _StatItem(
                  label: satsMode ? 'Total sats' : 'Total BTC',
                  value: formatBtcAmount(stats.totalBtc, satsMode: satsMode),
                ),
              ),
              Expanded(
                child: _StatItem(
                  label: 'Cost basis',
                  value: priceFormatter.format(stats.totalCostBasis),
                ),
              ),
            ],
          ),

          if (stats.hasPriceData) ...[
            const SizedBox(height: 16),
            Divider(color: cs.outline, height: 1),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _StatItem(
                    label: 'Current value',
                    value: priceFormatter.format(stats.currentValue),
                  ),
                ),
                Expanded(
                  child: _PnlItem(
                    pnl: stats.pnl!,
                    pnlPercent: stats.pnlPercent!,
                    isProfit: stats.isProfit,
                    formatter: priceFormatter,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

}

class _StatItem extends StatelessWidget {
  final String label;
  final String? value;
  final Color? valueColor;

  const _StatItem({required this.label, this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(
          value ?? '—',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: valueColor,
              ),
        ),
      ],
    );
  }
}

class _PnlItem extends StatelessWidget {
  final double pnl;
  final double pnlPercent;
  final bool isProfit;
  final NumberFormat formatter;

  const _PnlItem({
    required this.pnl,
    required this.pnlPercent,
    required this.isProfit,
    required this.formatter,
  });

  @override
  Widget build(BuildContext context) {
    final color = isProfit ? AppColors.positive : AppColors.negative;
    final sign = isProfit ? '+' : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('P&L', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(
          '$sign${formatter.format(pnl)}',
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(fontWeight: FontWeight.w600, color: color),
        ),
        Text(
          '$sign${pnlPercent.toStringAsFixed(2)}%',
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ─── Entries List ─────────────────────────────────────────────────────────────

class _EntriesHeader extends StatelessWidget {
  final VoidCallback onAdd;

  const _EntriesHeader({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('PURCHASES', style: Theme.of(context).textTheme.titleMedium),
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: AppColors.primary),
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  final DcaEntry entry;
  final bool satsMode;
  final VoidCallback onDelete;

  const _EntryTile({required this.entry, required this.satsMode, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final info = supportedCurrencies[entry.currency];
    final symbol = info?.symbol ?? entry.currency.toUpperCase();
    final decimals = info?.decimalDigits ?? 2;
    final formatter =
        NumberFormat.currency(symbol: symbol, decimalDigits: decimals);
    final cs = Theme.of(context).colorScheme;

    final btcStr = formatBtcAmount(entry.btcAmount, satsMode: satsMode);
    final dateStr = DateFormat('d MMM yyyy').format(entry.date);

    return Dismissible(
      key: Key(entry.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: AppColors.negative.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete_outline, color: AppColors.negative),
      ),
      confirmDismiss: (_) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete entry?'),
          content: const Text(
              'This purchase will be removed from your DCA history.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete',
                  style: TextStyle(color: AppColors.negative)),
            ),
          ],
        ),
      ),
      onDismissed: (_) => onDelete(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outline),
        ),
        child: Row(
          children: [
            // Date + currency badge
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dateStr,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
                Text(
                  info?.code ?? entry.currency.toUpperCase(),
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const Spacer(),
            // BTC amount + price paid
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  btcStr,
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  '@ ${formatter.format(entry.pricePerBtc)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

}

// ─── Empty State ─────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;

  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.show_chart,
              size: 56,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No purchases yet',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Add your Bitcoin purchases to\ntrack your average buy price and P&L.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 28),
            ElevatedButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add first purchase'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Add Entry Sheet ──────────────────────────────────────────────────────────

class _AddEntrySheet extends ConsumerStatefulWidget {
  final String defaultCurrency;

  const _AddEntrySheet({required this.defaultCurrency});

  @override
  ConsumerState<_AddEntrySheet> createState() => _AddEntrySheetState();
}

class _AddEntrySheetState extends ConsumerState<_AddEntrySheet> {
  final _btcController = TextEditingController();
  final _priceController = TextEditingController();
  final _noteController = TextEditingController();
  late DateTime _selectedDate;
  late String _currency;
  bool _saving = false;
  bool _fetchingPrice = false;
  int _fetchGen = 0; // incremented on every new fetch; stale results are dropped

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now();
    _currency = widget.defaultCurrency;
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchHistoricalPrice());
  }

  @override
  void dispose() {
    _btcController.dispose();
    _priceController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2009, 1, 3),
      lastDate: DateTime.now(),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme:
              Theme.of(context).colorScheme.copyWith(primary: AppColors.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
      _fetchHistoricalPrice();
    }
  }

  Future<void> _fetchHistoricalPrice() async {
    // Capture current values and generation at call time so the async
    // completion can't read stale state or overwrite a newer request's result.
    final gen = ++_fetchGen;
    final currency = _currency;
    final date = _selectedDate;

    setState(() => _fetchingPrice = true);
    try {
      final price = await ref
          .read(priceServiceProvider)
          .fetchHistoricalPrice(currency, date);
      if (mounted && gen == _fetchGen && price != null) {
        _priceController.text = price.toStringAsFixed(0);
      }
    } catch (_) {
    } finally {
      // Only clear the spinner if no newer fetch has started since.
      if (mounted && gen == _fetchGen) {
        setState(() => _fetchingPrice = false);
      }
    }
  }

  Future<void> _save() async {
    final satsMode = ref.read(satsModeProvider);
    final btc = parseBtcInput(_btcController.text, satsMode: satsMode);
    final price = double.tryParse(_priceController.text.trim());

    if (btc == null || btc <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Enter a valid ${satsMode ? 'sats' : 'BTC'} amount')));
      return;
    }
    if (price == null || price <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a valid price')));
      return;
    }

    setState(() => _saving = true);
    await ref.read(dcaProvider.notifier).addEntry(
          btcAmount: btc,
          pricePerBtc: price,
          currency: _currency,
          date: _selectedDate,
          note: _noteController.text,
        );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final portfolio = ref.watch(portfolioProvider);
    final satsMode = ref.watch(satsModeProvider);
    final selectedCurrencies = portfolio.selectedCurrencies;
    final info = supportedCurrencies[_currency];
    final symbol = info?.symbol ?? _currency.toUpperCase();
    final dateStr = DateFormat('d MMM yyyy').format(_selectedDate);
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.outline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text('Add Purchase',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 20),

              // Currency selector
              if (selectedCurrencies.length > 1) ...[
                Text('Currency',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Row(
                  children: selectedCurrencies.map((c) {
                    final cInfo = supportedCurrencies[c];
                    final isSelected = c == _currency;
                    return Expanded(
                      child: GestureDetector(
                        onTap: () {
                          if (!isSelected) {
                            setState(() => _currency = c);
                            _fetchHistoricalPrice();
                          }
                        },
                        child: Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppColors.primary.withValues(alpha: 0.15)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.primary
                                  : cs.outline,
                            ),
                          ),
                          child: Column(
                            children: [
                              Text(
                                cInfo?.symbol ?? c.toUpperCase(),
                                style: TextStyle(
                                  color: isSelected
                                      ? AppColors.primary
                                      : cs.secondary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                              Text(
                                cInfo?.code ?? c.toUpperCase(),
                                style: TextStyle(
                                  color: isSelected
                                      ? AppColors.primary
                                      : cs.secondary,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),
              ],

              // BTC / sats amount
              TextField(
                controller: _btcController,
                keyboardType: satsMode
                    ? TextInputType.number
                    : const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  satsMode
                      ? FilteringTextInputFormatter.digitsOnly
                      : FilteringTextInputFormatter.allow(
                          RegExp(r'^\d*\.?\d{0,8}')),
                ],
                decoration: InputDecoration(
                  labelText: 'Amount purchased',
                  prefixIcon: GestureDetector(
                    onTap: () => ref.read(satsModeProvider.notifier).toggle(),
                    behavior: HitTestBehavior.opaque,
                    child: BtcUnitIcon(
                        satsMode: satsMode, color: AppColors.primary),
                  ),
                  suffixText: satsMode ? 'sats' : 'BTC',
                ),
              ),
              const SizedBox(height: 14),

              // Price per BTC (pre-filled from historical data)
              TextField(
                controller: _priceController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                      RegExp(r'^\d*\.?\d{0,2}')),
                ],
                decoration: InputDecoration(
                  labelText: 'Price per BTC',
                  prefixText: '$symbol ',
                  prefixStyle: const TextStyle(color: AppColors.primary),
                  suffixText: info?.code ?? _currency.toUpperCase(),
                  suffixIcon: _fetchingPrice
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primary,
                            ),
                          ),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 14),

              // Date picker
              GestureDetector(
                onTap: _pickDate,
                child: Container(
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
                      const Icon(Icons.calendar_today_outlined,
                          color: AppColors.primary, size: 18),
                      const SizedBox(width: 12),
                      Text(dateStr,
                          style: Theme.of(context).textTheme.bodyLarge),
                      const Spacer(),
                      Icon(Icons.chevron_right, color: cs.secondary, size: 18),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Note (optional)
              TextField(
                controller: _noteController,
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  prefixIcon: Icon(Icons.notes_outlined),
                ),
                maxLines: 1,
              ),
              const SizedBox(height: 24),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black),
                        )
                      : const Text('Save Purchase',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
