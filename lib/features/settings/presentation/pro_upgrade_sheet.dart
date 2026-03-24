import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/license_key_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../providers/purchase_provider.dart';

/// Shows the Pro upgrade bottom sheet.
///
/// F-Droid flavor: Buy button opens bitbag.app/pro; manual key paste as fallback.
/// Play Store flavor (stub): shows placeholder text.
Future<void> showProUpgradeSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _ProUpgradeSheet(),
  );
}

// ── Sheet widget ─────────────────────────────────────────────────────────────

class _ProUpgradeSheet extends ConsumerStatefulWidget {
  const _ProUpgradeSheet();

  @override
  ConsumerState<_ProUpgradeSheet> createState() => _ProUpgradeSheetState();
}

class _ProUpgradeSheetState extends ConsumerState<_ProUpgradeSheet> {
  final _tokenController = TextEditingController();
  bool _keyExpanded = false;
  bool _verifying = false;
  String? _errorText;

  // Play Store: product details (price string) loaded from the store.
  ProductDetails? _productDetails;
  bool _buyPending = false;

  @override
  void initState() {
    super.initState();
    if (AppConstants.kFlavor == 'playstore') _loadProductDetails();
  }

  Future<void> _loadProductDetails() async {
    final response = await InAppPurchase.instance
        .queryProductDetails({AppConstants.iapProProductId});
    if (!mounted) return;
    if (response.productDetails.isNotEmpty) {
      setState(() => _productDetails = response.productDetails.first);
    }
  }

  Future<void> _buyPro() async {
    if (_productDetails == null) return;
    setState(() => _buyPending = true);
    final param = PurchaseParam(productDetails: _productDetails!);
    await InAppPurchase.instance.buyNonConsumable(purchaseParam: param);
    if (mounted) setState(() => _buyPending = false);
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _verifyKey() async {
    final raw = _tokenController.text.trim();
    if (raw.isEmpty) return;

    setState(() {
      _verifying = true;
      _errorText = null;
    });

    final ok =
        await ref.read(proUnlockedProvider.notifier).verifyAndUnlock(raw);

    if (!mounted) return;

    if (ok) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pro unlocked — thank you!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      setState(() {
        _verifying = false;
        _errorText = 'Invalid key. Check for typos or contact support.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isPlayStore = AppConstants.kFlavor == 'playstore';

    if (isPlayStore) {
      ref.listen<bool>(proUnlockedProvider, (previous, next) {
        if (next && mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Pro unlocked — thank you!'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      });
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 32,
      ),
      child: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Handle ────────────────────────────────────────────────────────
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── Title ─────────────────────────────────────────────────────────
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.shield_outlined,
                    color: AppColors.primary, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Bag Pro',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      'One-time purchase · no subscription',
                      style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.6),
                          fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          if (isPlayStore) ...[
            // ── Play Store buy flow ───────────────────────────────────────
            ..._features.map((f) => _FeatureRow(icon: f.$1, label: f.$2)),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (_productDetails == null || _buyPending)
                    ? null
                    : _buyPro,
                icon: _buyPending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black),
                      )
                    : const Icon(Icons.lock_open_outlined, size: 18),
                label: Text(_productDetails == null
                    ? 'Loading…'
                    : 'Buy Pro · ${_productDetails!.price}'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: TextButton(
                onPressed: () =>
                    InAppPurchase.instance.restorePurchases(),
                child: Text(
                  'Restore purchase',
                  style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 13),
                ),
              ),
            ),
          ] else ...[
            // ── Feature list ──────────────────────────────────────────────
            ..._features.map((f) => _FeatureRow(icon: f.$1, label: f.$2)),
            const SizedBox(height: 20),

            // ── Buy button ────────────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://bitbag.app/pro'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Buy Pro'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Divider ───────────────────────────────────────────────────
            Divider(color: cs.onSurface.withValues(alpha: 0.12)),
            const SizedBox(height: 4),

            // ── "Already have a key?" section ─────────────────────────────
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _keyExpanded = !_keyExpanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Already have a key?',
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.7),
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      _keyExpanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      color: cs.onSurface.withValues(alpha: 0.5),
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),

            if (_keyExpanded) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _tokenController,
                maxLines: 2,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Paste your license key…',
                  errorText: _errorText,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.content_paste_outlined, size: 18),
                    tooltip: 'Paste from clipboard',
                    onPressed: () async {
                      final data =
                          await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text != null) {
                        _tokenController.text =
                            LicenseKeyService.formatForDisplay(
                                data!.text!.trim());
                        setState(() => _errorText = null);
                      }
                    },
                  ),
                ),
                onChanged: (_) => setState(() => _errorText = null),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _verifying ? null : _verifyKey,
                  child: _verifying
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Verify key'),
                ),
              ),
            ],
          ],
        ],
        ),
      ),
    );
  }
}

// ── Feature list data ─────────────────────────────────────────────────────────

const _features = [
  (Icons.account_balance_wallet_outlined, 'Watch-only wallet tracking (zpub)'),
  (Icons.router_outlined, 'Tor routing via Orbot'),
  (Icons.dns_outlined, 'Custom Esplora node support'),
  (Icons.security_outlined, 'Bitcoin Health Check'),
  (Icons.shield_outlined, 'Sentinel — always-on balance alerts'),
  (Icons.bar_chart_outlined, 'Network fee estimates & alerts'),
];

class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _FeatureRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }
}
