import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/btc_format.dart';
import '../models/wallet_entry.dart';
import '../providers/sats_mode_provider.dart';
import '../providers/wallets_provider.dart';
import '../services/wallet/wallet_engine.dart';

/// Collapsible form for adding a portfolio entry.
///
/// Renders as an "Add holding" button when collapsed; expands inline on tap
/// into a three-way picker:
///   • zpub       — watch-only single-sig wallet
///   • descriptor — watch-only multisig (e.g. Bitkey's 2-of-3)
///   • amount     — a balance held elsewhere, e.g. on an exchange
///
/// Used inside [WalletPrivacyScreen] below the entry list.
class AddWalletForm extends ConsumerStatefulWidget {
  const AddWalletForm({super.key});

  @override
  ConsumerState<AddWalletForm> createState() => _AddWalletFormState();
}

class _AddWalletFormState extends ConsumerState<AddWalletForm> {
  final _secretController = TextEditingController();
  final _labelController = TextEditingController();
  final _amountController = TextEditingController();
  final _amountFocusNode = FocusNode();

  WalletKind _kind = WalletKind.zpub;
  bool _expanded = false;
  bool _connecting = false;
  String? _inputError;

  @override
  void dispose() {
    _secretController.dispose();
    _labelController.dispose();
    _amountController.dispose();
    _amountFocusNode.dispose();
    super.dispose();
  }

  void _collapse() {
    _secretController.clear();
    _labelController.clear();
    _amountController.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _expanded = false;
      _inputError = null;
    });
  }

  void _selectKind(WalletKind kind) {
    if (kind == _kind) return;
    // iOS doesn't reload the keyboard when the field type changes underneath a
    // focused field — drop focus so the right keyboard appears next tap.
    FocusScope.of(context).unfocus();
    setState(() {
      _kind = kind;
      _inputError = null;
    });
  }

  Future<void> _submit() async {
    setState(() {
      _connecting = true;
      _inputError = null;
    });

    final label = _labelController.text.trim();
    final notifier = ref.read(walletsProvider.notifier);

    try {
      switch (_kind) {
        case WalletKind.zpub:
          final zpub = _secretController.text.trim();
          if (zpub.isEmpty) {
            setState(() => _inputError = 'Enter a zpub');
            return;
          }
          if (looksLikePrivateKey(zpub)) {
            setState(() => _inputError = _kPrivateKeyWarning);
            return;
          }
          await notifier.addWallet(zpub, label: label.isEmpty ? null : label);

        case WalletKind.descriptor:
          final descriptor = _secretController.text.trim();
          if (descriptor.isEmpty) {
            setState(() => _inputError = 'Enter a wallet descriptor');
            return;
          }
          if (looksLikePrivateKey(descriptor)) {
            setState(() => _inputError = _kPrivateKeyWarning);
            return;
          }
          await notifier.addDescriptorWallet(descriptor,
              label: label.isEmpty ? null : label);

        case WalletKind.manual:
          final satsMode = ref.read(satsModeProvider);
          final btc =
              parseBtcInput(_amountController.text, satsMode: satsMode);
          if (btc == null || btc <= 0) {
            setState(() => _inputError =
                'Enter a valid ${satsMode ? 'sats' : 'BTC'} amount');
            return;
          }
          await notifier.addManualEntry(
            sats: (btc * satsPerBtc).round(),
            label: label.isEmpty ? null : label,
          );
      }

      // Collapse back to the button after a successful add.
      if (mounted) _collapse();
    } on ZpubException catch (e) {
      setState(() => _inputError = e.message);
    } on DescriptorException catch (e) {
      setState(() => _inputError = e.message);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: _expanded ? _buildForm(cs) : _buildButton(cs),
    );
  }

  Widget _buildButton(ColorScheme cs) {
    return InkWell(
      onTap: () => setState(() => _expanded = true),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.add_circle_outline,
                size: 18, color: AppColors.primary),
            const SizedBox(width: 8),
            Text(
              'Add holding',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm(ColorScheme cs) {
    final satsMode = ref.watch(satsModeProvider);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with cancel
          Row(
            children: [
              const Icon(Icons.add_circle_outline,
                  color: AppColors.primary, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Add holding',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              IconButton(
                onPressed: _connecting ? null : _collapse,
                icon: Icon(Icons.close, size: 18, color: cs.secondary),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Cancel',
              ),
            ],
          ),
          const SizedBox(height: 12),

          if (!_connecting) ...[
            _KindPicker(selected: _kind, onChanged: _selectKind),
            const SizedBox(height: 10),
            Text(
              switch (_kind) {
                WalletKind.zpub =>
                  'Extended public key from a single-signature wallet. '
                      'Balance is read from the blockchain — the key never leaves your device.',
                WalletKind.descriptor =>
                  'Output descriptor from a multisig wallet such as Bitkey. '
                      'Paste the whole export — Bitkey\'s External and '
                      'Internal lines together — so change addresses are '
                      'watched too. Watch-only: no private keys, no spending.',
                WalletKind.manual =>
                  'A balance you hold somewhere Bag can\'t see — an exchange, '
                      'for example. Nothing is queried on-chain.',
              },
              style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _labelController,
              autocorrect: false,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                hintText: switch (_kind) {
                  WalletKind.zpub => 'Label (e.g. Cold Storage)',
                  WalletKind.descriptor => 'Label (e.g. Bitkey)',
                  WalletKind.manual => 'Label (e.g. Exchange)',
                },
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            if (_kind == WalletKind.manual)
              _buildAmountField(cs, satsMode)
            else
              _buildSecretField(cs),
            const SizedBox(height: 12),
          ] else
            const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _connecting ? null : _submit,
              icon: _connecting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : Icon(
                      _kind == WalletKind.manual ? Icons.add : Icons.link,
                      size: 16,
                    ),
              label: Text(
                _connecting
                    ? 'Connecting…'
                    : switch (_kind) {
                        WalletKind.zpub => 'Connect Wallet',
                        WalletKind.descriptor => 'Connect Wallet',
                        WalletKind.manual => 'Add Amount',
                      },
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSecretField(ColorScheme cs) {
    final isDescriptor = _kind == WalletKind.descriptor;
    return TextField(
      controller: _secretController,
      autocorrect: false,
      enableSuggestions: false,
      autofocus: true,
      maxLines: isDescriptor ? 4 : 1,
      minLines: isDescriptor ? 3 : 1,
      decoration: InputDecoration(
        hintText: isDescriptor
            ? 'External: wsh(sortedmulti(2,[…]xpub…/0/*,…))\n'
                'Internal: wsh(sortedmulti(2,[…]xpub…/1/*,…))'
            : 'zpub6rFR7y4Q2…',
        hintStyle: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: cs.outline,
        ),
        hintMaxLines: 2,
        errorText: _inputError,
        errorMaxLines: 6,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      onChanged: (v) {
        if (looksLikePrivateKey(v)) {
          setState(() => _inputError = _kPrivateKeyWarning);
        } else if (_inputError != null) {
          setState(() => _inputError = null);
        }
      },
      onSubmitted: isDescriptor ? null : (_) => _submit(),
    );
  }

  Widget _buildAmountField(ColorScheme cs, bool satsMode) {
    return TextField(
      controller: _amountController,
      focusNode: _amountFocusNode,
      autofocus: true,
      keyboardType: satsMode
          ? TextInputType.number
          : const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        satsMode
            ? FilteringTextInputFormatter.digitsOnly
            : FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,8}')),
      ],
      decoration: InputDecoration(
        hintText: satsMode ? '0' : '0.00000000',
        suffixText: btcUnit(satsMode),
        suffixStyle: TextStyle(color: cs.secondary),
        errorText: _inputError,
        errorMaxLines: 3,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
      style: const TextStyle(fontSize: 14),
      onChanged: (_) {
        if (_inputError != null) setState(() => _inputError = null);
      },
      onSubmitted: (_) => _submit(),
    );
  }
}

// ── Kind picker ───────────────────────────────────────────────────────────────

class _KindPicker extends StatelessWidget {
  final WalletKind selected;
  final ValueChanged<WalletKind> onChanged;

  const _KindPicker({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SegmentedButton<WalletKind>(
      style: SegmentedButton.styleFrom(
        backgroundColor: cs.surface,
        selectedBackgroundColor: AppColors.primary.withValues(alpha: 0.15),
        selectedForegroundColor: AppColors.primary,
        foregroundColor: Theme.of(context).textTheme.bodyMedium?.color,
        side: BorderSide(color: cs.outline),
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 12),
      ),
      segments: const [
        ButtonSegment(value: WalletKind.zpub, label: Text('zpub')),
        ButtonSegment(value: WalletKind.descriptor, label: Text('Multisig')),
        ButtonSegment(value: WalletKind.manual, label: Text('Amount')),
      ],
      selected: {selected},
      showSelectedIcon: false,
      onSelectionChanged: (v) => onChanged(v.first),
    );
  }
}

// ── Shared input guards ───────────────────────────────────────────────────────

const _kPrivateKeyWarning =
    'This looks like a private key. Never enter a private key here — '
    'Bag only ever needs public keys.';

/// Cheap client-side guard so a pasted private key is caught before it is
/// written anywhere. The parsers reject private prefixes too; this exists to
/// warn the user while they are still typing.
bool looksLikePrivateKey(String input) {
  final t = input.trim().toLowerCase();
  return t.startsWith('zpriv') ||
      t.startsWith('xpriv') ||
      t.startsWith('ypriv') ||
      t.startsWith('tpriv') ||
      t.startsWith('upriv') ||
      t.startsWith('vpriv') ||
      // BIP32 serialisation actually uses the "prv" spelling.
      t.contains('xprv') ||
      t.contains('yprv') ||
      t.contains('zprv') ||
      t.contains('tprv') ||
      t.contains('uprv') ||
      t.contains('vprv');
}

// ── Amount editor for existing manual entries ─────────────────────────────────

/// Prompts for a new amount on a manual entry and saves it.
Future<void> showEditManualAmountDialog(
  BuildContext context,
  WidgetRef ref,
  WalletEntry entry,
) async {
  final satsMode = ref.read(satsModeProvider);
  final controller = TextEditingController(
    text: entry.lastSats != null && entry.lastSats! > 0
        ? btcToFieldString(entry.btcAmount, satsMode: satsMode)
        : '',
  );

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(entry.label),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: satsMode
            ? TextInputType.number
            : const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          satsMode
              ? FilteringTextInputFormatter.digitsOnly
              : FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,8}')),
        ],
        decoration: InputDecoration(
          hintText: satsMode ? '0' : '0.00000000',
          suffixText: btcUnit(satsMode),
        ),
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

  final btc = parseBtcInput(controller.text, satsMode: satsMode);
  controller.dispose();

  if (saved != true) return;
  if (btc == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('Enter a valid ${satsMode ? 'sats' : 'BTC'} amount')),
      );
    }
    return;
  }

  await ref
      .read(walletsProvider.notifier)
      .updateManualEntry(entry.id, (btc * satsPerBtc).round());
}
