import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/constants/supported_currencies.dart';
import '../core/theme/app_theme.dart';
import '../providers/alerts_provider.dart';
import '../providers/fee_alerts_provider.dart';
import '../providers/portfolio_provider.dart';
import '../providers/purchase_provider.dart';
import '../services/notification_service.dart';

void showAlertsSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _AlertsSheet(),
  );
}

class _AlertsSheet extends ConsumerStatefulWidget {
  const _AlertsSheet();

  @override
  ConsumerState<_AlertsSheet> createState() => _AlertsSheetState();
}

class _AlertsSheetState extends ConsumerState<_AlertsSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int _tabIndex = 0;

  // ── Price alert form state ─────────────────────────────────────────────────
  final _priceController = TextEditingController();
  bool _priceAbove = true;
  late String _currency;

  // ── Fee alert form state ───────────────────────────────────────────────────
  final _feeController = TextEditingController();
  bool _feeAbove = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() => _tabIndex = _tabController.index);
      }
    });
    final currencies = ref.read(portfolioProvider).selectedCurrencies;
    _currency = currencies.isNotEmpty ? currencies.first : 'usd';
  }

  @override
  void dispose() {
    _tabController.dispose();
    _priceController.dispose();
    _feeController.dispose();
    super.dispose();
  }

  // ── Price alert actions ────────────────────────────────────────────────────

  Future<void> _addPrice() async {
    final price = double.tryParse(_priceController.text.trim());
    if (price == null || price <= 0) return;

    final granted = await NotificationService.requestPermission();
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification permission denied')),
      );
      return;
    }

    await ref.read(alertsProvider.notifier).add(
          targetPrice: price,
          currency: _currency,
          above: _priceAbove,
        );
    _priceController.clear();
    if (mounted) FocusScope.of(context).unfocus();
  }

  // ── Fee alert actions ──────────────────────────────────────────────────────

  Future<void> _addFee() async {
    final rate = double.tryParse(_feeController.text.trim());
    if (rate == null || rate <= 0) return;

    final granted = await NotificationService.requestPermission();
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification permission denied')),
      );
      return;
    }

    await ref.read(feeAlertsProvider.notifier).add(
          targetRate: rate,
          above: _feeAbove,
        );
    _feeController.clear();
    if (mounted) FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final proUnlocked = ref.watch(proUnlockedProvider);

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child:
                Text('Alerts', style: Theme.of(context).textTheme.titleLarge),
          ),

          const SizedBox(height: 8),

          TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: 'Price'),
              Tab(text: 'Fees'),
            ],
            labelColor: AppColors.primary,
            unselectedLabelColor: null,
            indicatorColor: AppColors.primary,
            dividerColor: cs.outline,
            labelStyle: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),

          const SizedBox(height: 4),

          // Tab body — IndexedStack keeps each tab's state alive.
          IndexedStack(
            index: _tabIndex,
            children: [
              _PriceAlertsBody(
                priceController: _priceController,
                currency: _currency,
                above: _priceAbove,
                onAboveChanged: (v) => setState(() => _priceAbove = v),
                onCurrencyChanged: (v) => setState(() => _currency = v),
                onAdd: _addPrice,
              ),
              _FeeAlertsBody(
                feeController: _feeController,
                above: _feeAbove,
                onAboveChanged: (v) => setState(() => _feeAbove = v),
                onAdd: _addFee,
                proUnlocked: proUnlocked,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Price alerts tab ──────────────────────────────────────────────────────────

class _PriceAlertsBody extends ConsumerWidget {
  final TextEditingController priceController;
  final String currency;
  final bool above;
  final ValueChanged<bool> onAboveChanged;
  final ValueChanged<String> onCurrencyChanged;
  final VoidCallback onAdd;

  const _PriceAlertsBody({
    required this.priceController,
    required this.currency,
    required this.above,
    required this.onAboveChanged,
    required this.onCurrencyChanged,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsProvider);
    final currencies = ref.read(portfolioProvider).selectedCurrencies;
    final currencyInfo = supportedCurrencies[currency];
    final symbol = currencyInfo?.symbol ?? currency.toUpperCase();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Add form — direction row + input row stacked for narrow screens
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Row 1: currency selector + Above/Below chips
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (currencies.length > 1)
                    DropdownButton<String>(
                      value: currency,
                      underline: const SizedBox.shrink(),
                      style: TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                      items: currencies.map((c) {
                        final info = supportedCurrencies[c];
                        return DropdownMenuItem(
                          value: c,
                          child: Text(info?.code ?? c.toUpperCase()),
                        );
                      }).toList(),
                      onChanged: (v) => onCurrencyChanged(v!),
                    ),
                  ChoiceChip(
                    label: const Text('Above'),
                    selected: above,
                    onSelected: (_) => onAboveChanged(true),
                    selectedColor: AppColors.positive.withValues(alpha: 0.15),
                    labelStyle: TextStyle(
                      color: above ? AppColors.positive : null,
                      fontSize: 13,
                    ),
                  ),
                  ChoiceChip(
                    label: const Text('Below'),
                    selected: !above,
                    onSelected: (_) => onAboveChanged(false),
                    selectedColor: AppColors.negative.withValues(alpha: 0.15),
                    labelStyle: TextStyle(
                      color: !above ? AppColors.negative : null,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Row 2: price input + add button
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: priceController,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'^\d*\.?\d{0,2}')),
                      ],
                      decoration: InputDecoration(
                        hintText: '0.00',
                        prefixText: '$symbol ',
                        isDense: true,
                      ),
                      onSubmitted: (_) => onAdd(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add),
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.black,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Divider(height: 1),
        if (alerts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text('No alerts set',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: alerts.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final alert = alerts[i];
              final cs = Theme.of(context).colorScheme;
              final info = supportedCurrencies[alert.currency];
              final fmt = NumberFormat.simpleCurrency(
                  name: alert.currency.toUpperCase());
              final dirIcon =
                  alert.above ? Icons.arrow_upward : Icons.arrow_downward;
              final dirColor =
                  alert.above ? AppColors.positive : AppColors.negative;

              return Dismissible(
                key: ValueKey(alert.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  color: AppColors.negative,
                  child: const Icon(Icons.delete_outline,
                      color: Colors.white, size: 22),
                ),
                onDismissed: (_) =>
                    ref.read(alertsProvider.notifier).delete(alert.id),
                child: ListTile(
                  dense: true,
                  leading: Icon(dirIcon,
                      color: alert.fired ? cs.outline : dirColor, size: 20),
                  title: Text(
                    '${alert.above ? 'Above' : 'Below'} ${fmt.format(alert.targetPrice)}',
                    style: TextStyle(
                      color: alert.fired ? cs.outline : null,
                      decoration:
                          alert.fired ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  subtitle: Text(
                    alert.fired
                        ? 'Triggered · ${info?.code ?? alert.currency.toUpperCase()}'
                        : info?.code ?? alert.currency.toUpperCase(),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing:
                      Icon(Icons.chevron_left, size: 16, color: cs.outline),
                ),
              );
            },
          ),
        if (alerts.any((a) => a.fired))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextButton(
              onPressed: () => ref.read(alertsProvider.notifier).clearFired(),
              child: const Text('Clear triggered alerts'),
            ),
          )
        else
          const SizedBox(height: 16),
      ],
    );
  }
}

// ── Fee alerts tab ────────────────────────────────────────────────────────────

class _FeeAlertsBody extends ConsumerWidget {
  final TextEditingController feeController;
  final bool above;
  final ValueChanged<bool> onAboveChanged;
  final VoidCallback onAdd;
  final bool proUnlocked;

  const _FeeAlertsBody({
    required this.feeController,
    required this.above,
    required this.onAboveChanged,
    required this.onAdd,
    required this.proUnlocked,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;

    if (!proUnlocked) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
        child: Column(
          children: [
            Icon(Icons.lock_outline, color: cs.outline, size: 32),
            const SizedBox(height: 12),
            Text(
              'Fee alerts are a Pro feature',
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Unlock Pro to set alerts for when fees rise above or drop below your target.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
          ],
        ),
      );
    }

    final alerts = ref.watch(feeAlertsProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Add form — direction chips + input row stacked for narrow screens
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Row 1: Above/Below chips
              Row(
                children: [
                  ChoiceChip(
                    label: const Text('Above'),
                    selected: above,
                    onSelected: (_) => onAboveChanged(true),
                    selectedColor: AppColors.positive.withValues(alpha: 0.15),
                    labelStyle: TextStyle(
                      color: above ? AppColors.positive : null,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(width: 6),
                  ChoiceChip(
                    label: const Text('Below'),
                    selected: !above,
                    onSelected: (_) => onAboveChanged(false),
                    selectedColor: AppColors.negative.withValues(alpha: 0.15),
                    labelStyle: TextStyle(
                      color: !above ? AppColors.negative : null,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Row 2: sat/vB input + add button
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: feeController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: const InputDecoration(
                        hintText: '0',
                        suffixText: 'sat/vB',
                        isDense: true,
                      ),
                      onSubmitted: (_) => onAdd(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add),
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.black,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Divider(height: 1),
        if (alerts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text('No fee alerts set',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: alerts.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final alert = alerts[i];
              final dirIcon =
                  alert.above ? Icons.arrow_upward : Icons.arrow_downward;
              final dirColor =
                  alert.above ? AppColors.positive : AppColors.negative;

              return Dismissible(
                key: ValueKey(alert.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  color: AppColors.negative,
                  child: const Icon(Icons.delete_outline,
                      color: Colors.white, size: 22),
                ),
                onDismissed: (_) =>
                    ref.read(feeAlertsProvider.notifier).delete(alert.id),
                child: ListTile(
                  dense: true,
                  leading: Icon(dirIcon,
                      color: alert.fired ? cs.outline : dirColor, size: 20),
                  title: Text(
                    '${alert.above ? 'Above' : 'Below'} ${alert.targetRate.toStringAsFixed(0)} sat/vB',
                    style: TextStyle(
                      color: alert.fired ? cs.outline : null,
                      decoration:
                          alert.fired ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  subtitle: Text(
                    alert.fired ? 'Triggered' : 'Network fee alert',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing:
                      Icon(Icons.chevron_left, size: 16, color: cs.outline),
                ),
              );
            },
          ),
        if (alerts.any((a) => a.fired))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextButton(
              onPressed: () =>
                  ref.read(feeAlertsProvider.notifier).clearFired(),
              child: const Text('Clear triggered alerts'),
            ),
          )
        else
          const SizedBox(height: 16),
      ],
    );
  }
}
