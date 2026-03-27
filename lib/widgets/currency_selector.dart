import 'package:flutter/material.dart';

import '../core/constants/app_constants.dart';
import '../core/constants/supported_currencies.dart';
import '../core/theme/app_theme.dart';

/// Bottom sheet for selecting up to [AppConstants.maxSelectedCurrencies] currencies.
/// Returns the updated selection via [onChanged].
void showCurrencySelector({
  required BuildContext context,
  required List<String> selected,
  required ValueChanged<List<String>> onChanged,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _CurrencySelectorSheet(
      selected: selected,
      onChanged: onChanged,
    ),
  );
}

class _CurrencySelectorSheet extends StatefulWidget {
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  const _CurrencySelectorSheet({
    required this.selected,
    required this.onChanged,
  });

  @override
  State<_CurrencySelectorSheet> createState() => _CurrencySelectorSheetState();
}

class _CurrencySelectorSheetState extends State<_CurrencySelectorSheet> {
  late List<String> _selected;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _selected = List<String>.from(widget.selected);
  }

  List<MapEntry<String, CurrencyInfo>> get _filtered {
    final q = _search.toLowerCase();
    return supportedCurrencies.entries
        .where((e) =>
            q.isEmpty ||
            e.key.contains(q) ||
            e.value.name.toLowerCase().contains(q) ||
            e.value.code.toLowerCase().contains(q))
        .toList();
  }

  void _toggle(String code) {
    setState(() {
      if (_selected.contains(code)) {
        _selected.remove(code);
      } else if (_selected.length < AppConstants.maxSelectedCurrencies) {
        _selected.add(code);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.75;
    final cs = Theme.of(context).colorScheme;
    final textMutedColor = Theme.of(context).textTheme.bodySmall!.color!;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'SELECT CURRENCIES',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '${_selected.length}/${AppConstants.maxSelectedCurrencies}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Search
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                autofocus: false,
                style: TextStyle(color: cs.onSurface),
                decoration: InputDecoration(
                  hintText: 'Search…',
                  prefixIcon: Icon(Icons.search, size: 18, color: textMutedColor),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
            const SizedBox(height: 8),

            // List
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _filtered.length,
                itemBuilder: (_, i) {
                  final entry = _filtered[i];
                  final isSelected = _selected.contains(entry.key);
                  final isDisabled =
                      !isSelected && _selected.length >= AppConstants.maxSelectedCurrencies;

                  return ListTile(
                    dense: true,
                    enabled: !isDisabled,
                    onTap: isDisabled ? null : () => _toggle(entry.key),
                    leading: Text(
                      entry.value.symbol,
                      style: TextStyle(
                        color: isSelected ? AppColors.primary : cs.secondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    title: Text(
                      entry.value.name,
                      style: TextStyle(
                        color: isDisabled ? textMutedColor : cs.onSurface,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      entry.value.code,
                      style: TextStyle(color: textMutedColor, fontSize: 12),
                    ),
                    trailing: isSelected
                        ? const Icon(Icons.check_circle, color: AppColors.primary, size: 20)
                        : null,
                  );
                },
              ),
            ),

            // Confirm
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () {
                          widget.onChanged(_selected);
                          Navigator.of(context).pop();
                        },
                  child: const Text('Confirm'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
