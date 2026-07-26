import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../providers/wallets_provider.dart';
import '../services/wallet/wallet_engine.dart';

/// Collapsible form for connecting a new watch-only wallet.
/// Renders as an "Add wallet" button when collapsed; expands inline on tap.
/// Used inside [WalletPrivacyScreen] below the wallet list.
class AddWalletForm extends ConsumerStatefulWidget {
  const AddWalletForm({super.key});

  @override
  ConsumerState<AddWalletForm> createState() => _AddWalletFormState();
}

class _AddWalletFormState extends ConsumerState<AddWalletForm> {
  final _zpubController = TextEditingController();
  final _labelController = TextEditingController();
  bool _expanded = false;
  bool _connecting = false;
  String? _inputError;

  @override
  void dispose() {
    _zpubController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  bool _looksLikePrivateKey(String input) {
    final t = input.trim().toLowerCase();
    return t.startsWith('zpriv') ||
        t.startsWith('xpriv') ||
        t.startsWith('ypriv') ||
        t.startsWith('tpriv') ||
        t.startsWith('upriv') ||
        t.startsWith('vpriv');
  }

  void _collapse() {
    _zpubController.clear();
    _labelController.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _expanded = false;
      _inputError = null;
    });
  }

  Future<void> _connect() async {
    final zpub = _zpubController.text.trim();
    if (zpub.isEmpty) return;

    if (_looksLikePrivateKey(zpub)) {
      setState(() => _inputError =
          'This looks like a private key. Never enter a private key here — '
          'only zpub extended public keys are supported.');
      return;
    }

    setState(() {
      _connecting = true;
      _inputError = null;
    });

    try {
      await ref.read(walletsProvider.notifier).addWallet(
            zpub,
            label: _labelController.text.trim().isNotEmpty
                ? _labelController.text.trim()
                : null,
          );
      // Collapse back to button after a successful connect.
      if (mounted) _collapse();
    } on ZpubException catch (e) {
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
          border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.4),
            // Dashed border effect via a solid thin border tinted orange —
            // visually distinct from wallet cards without custom painters.
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_circle_outline,
                size: 18, color: AppColors.primary),
            const SizedBox(width: 8),
            Text(
              'Add wallet',
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
                  'Add wallet',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              IconButton(
                onPressed: _connecting ? null : _collapse,
                icon: Icon(Icons.close,
                    size: 18, color: cs.secondary),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Cancel',
              ),
            ],
          ),
          const SizedBox(height: 12),

          if (!_connecting) ...[
            TextField(
              controller: _labelController,
              autocorrect: false,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                hintText: 'Label (e.g. Cold Storage)',
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
            TextField(
              controller: _zpubController,
              autocorrect: false,
              enableSuggestions: false,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'zpub6rFR7y4Q2…',
                hintStyle: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: cs.outline,
                ),
                errorText: _inputError,
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              onChanged: (v) {
                if (_looksLikePrivateKey(v)) {
                  setState(() => _inputError =
                      'This looks like a private key. Never enter a private key here — '
                      'only zpub extended public keys are supported.');
                } else if (_inputError != null) {
                  setState(() => _inputError = null);
                }
              },
              onSubmitted: (_) => _connect(),
            ),
            const SizedBox(height: 12),
          ] else
            const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _connecting ? null : _connect,
              icon: _connecting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Icon(Icons.link, size: 16),
              label: Text(_connecting ? 'Connecting…' : 'Connect Wallet'),
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
}
