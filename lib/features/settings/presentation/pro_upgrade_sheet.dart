import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/iap/iap.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/license_key_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../providers/purchase_provider.dart';
import '../../../services/sentinel_service.dart';

/// The Pro sheet's root while it is open, so tests can tell it from any
/// other bottom sheet whatever its layout.
@visibleForTesting
const proUpgradeSheetKey = Key('pro-upgrade-sheet');

/// Test seams: the flavor and the store the sheet runs against, so the store
/// flavor can be driven on the host. Null means [AppConstants.kFlavor] and
/// [InAppPurchase.instance]. Reset both in tearDown.
@visibleForTesting
String? debugProSheetFlavor;
@visibleForTesting
InAppPurchase? debugProSheetStore;

/// Shows the Pro upgrade bottom sheet: what Pro adds (a figure, the headline
/// and the feature list), then a footer with the price and the way to buy.
///
/// `store` flavor (Play, App Store): buys `bag_pro` through the store, with
/// Restore purchase. `direct` flavor (F-Droid, GitHub APK): Buy Pro opens
/// bitbag.app/pro, and a licence key can be pasted as a fallback.
Future<void> showProUpgradeSheet(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: _sheetRadius,
    ),
    builder: (_) => const KeyedSubtree(
      key: proUpgradeSheetKey,
      child: _ProUpgradeSheet(),
    ),
  );
}

const _sheetRadius = BorderRadius.vertical(top: Radius.circular(20));

/// "Couldn't start the purchase" — shown in the error line when the store
/// throws on the buy call (StoreKit does when a transaction is pending).
const _buyFailed = "Couldn't start the purchase. Try again.";

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

  final String _flavor = debugProSheetFlavor ?? AppConstants.kFlavor;
  final InAppPurchase _store = debugProSheetStore ?? InAppPurchase.instance;

  // Store flavor: product details (price string) loaded from the store.
  ProductDetails? _productDetails;
  bool _buyPending = false;
  bool _storeUnavailable = false;
  String? _iapError;

  bool get _isStore => _flavor == 'store';

  @override
  void initState() {
    super.initState();
    if (_isStore) _loadProductDetails();
  }

  Future<void> _loadProductDetails() async {
    setState(() {
      _storeUnavailable = false;
      _iapError = null;
    });
    final available = await _store.isAvailable();
    if (!mounted) return;
    if (!available) {
      setState(() => _storeUnavailable = true);
      return;
    }
    final response =
        await _store.queryProductDetails({AppConstants.iapProProductId});
    if (!mounted) return;
    if (response.productDetails.isNotEmpty) {
      setState(() => _productDetails = response.productDetails.first);
    } else {
      setState(() => _iapError = _productLoadError(response));
    }
  }

  /// Why no product came back: the store's own message, else the ids it
  /// couldn't find.
  static String _productLoadError(ProductDetailsResponse response) {
    final storeMessage = response.error?.message;
    if (storeMessage != null) return storeMessage;
    if (response.notFoundIDs.isNotEmpty) {
      return 'Product not found (${response.notFoundIDs.join(', ')})';
    }
    return 'Could not load product';
  }

  Future<void> _buyPro() async {
    if (_productDetails == null) return;
    setState(() => _buyPending = true);
    final param = PurchaseParam(productDetails: _productDetails!);
    try {
      await _store.buyNonConsumable(purchaseParam: param);
    } catch (e) {
      // e.g. a PlatformException from StoreKit while a transaction is
      // already pending. The error line and Retry take over the button.
      if (kDebugMode) debugPrint('[IAP] buyNonConsumable failed: $e');
      if (mounted) setState(() => _iapError = _buyFailed);
    } finally {
      if (mounted) setState(() => _buyPending = false);
    }
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
      _closeUnlocked();
    } else {
      setState(() {
        _verifying = false;
        _errorText = 'Invalid key. Check for typos or contact support.';
      });
    }
  }

  /// Pro is unlocked (a verified key, or the store's purchase stream): close
  /// the sheet and thank the user.
  void _closeUnlocked() {
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Pro unlocked — thank you!'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _pasteKey() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    if (data?.text != null) {
      _tokenController.text =
          LicenseKeyService.formatForDisplay(data!.text!.trim());
      setState(() => _errorText = null);
    }
  }

  /// The price to show: the product this sheet loaded (what the buy call
  /// charges), else [proPriceProvider] whenever the sheet has no loaded
  /// price (still loading, a failed load, an empty price). Null when neither
  /// has one, and always in the direct flavor.
  String? _price() {
    final fallback = ref.watch(proPriceProvider).valueOrNull;
    final loaded = _productDetails?.price;
    return (loaded != null && loaded.isNotEmpty) ? loaded : fallback;
  }

  @override
  Widget build(BuildContext context) {
    if (_isStore) {
      ref.listen<bool>(proUnlockedProvider, (previous, next) {
        if (next && mounted) _closeUnlocked();
      });
    }

    final cs = Theme.of(context).colorScheme;
    final price = _price();
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;

    // The artboard's top border, following the rounded corners (the sheet's
    // shape has no side, which would also run down both screen edges).
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outline)),
        borderRadius: _sheetRadius,
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: _SheetTop.height, child: _SheetTop()),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: const _WhatYouGet(),
                ),
              ),
              // The footer always stays on screen, capped at 60% of the sheet
              // so the body keeps room; beyond that it scrolls on its own
              // rather than overflow. With the keyboard up (the key entry) it
              // may take everything below the top, so Verify key stays in
              // view.
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: cs.outline)),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: keyboard > 0
                        ? math.max(
                            0.0,
                            constraints.maxHeight - _SheetTop.height,
                          )
                        : constraints.maxHeight * 0.6,
                  ),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      24,
                      14,
                      24,
                      22 + MediaQuery.paddingOf(context).bottom,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _PriceLine(price: price),
                        const SizedBox(height: 10),
                        if (_isStore)
                          ..._storeActions(price)
                        else
                          ..._directActions(),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Store flavor: buy, or the load error with Retry; then restore ─────────

  List<Widget> _storeActions(String? price) {
    final cs = Theme.of(context).colorScheme;
    return [
      if (_storeUnavailable || _iapError != null) ...[
        _ErrorLine(
          _storeUnavailable
              ? 'App Store unavailable. Check your device settings.'
              : _iapError!,
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: _loadProductDetails,
            style: _linkButtonStyle(context),
            child: const Text('Retry'),
          ),
        ),
      ] else
        _PrimaryButton(
          label: _buyLabel(price),
          pending: _buyPending,
          onPressed: _productDetails == null ? null : _buyPro,
        ),
      const SizedBox(height: 6),
      // The note sits beside the button (wrapping if it must); at large text
      // sizes the button's label wraps too, rather than push the row off
      // screen.
      LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(
              child: Text(
                defaultTargetPlatform == TargetPlatform.iOS
                    ? 'Restores on any device with your Apple ID'
                    : 'Restores on any phone with your Google account',
                style: TextStyle(fontSize: 12, color: cs.secondary),
              ),
            ),
            // No gap, as drawn: the button's own 4 px padding separates them.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.6),
              child: TextButton(
                onPressed: () => _store.restorePurchases(),
                // Tight padding, as drawn, leaves the note the most room;
                // the target stays 48 tall (and padded to 48 wide if ever
                // narrower).
                style: _linkButtonStyle(
                  context,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(0, 48),
                ),
                child: const Text(
                  'Restore purchase',
                  textAlign: TextAlign.end,
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  String _buyLabel(String? price) {
    if (_productDetails == null) return 'Loading…';
    return unlockProLabel(price);
  }

  // ── Direct flavor: Buy Pro on bitbag.app, or paste a key ─────────────────

  List<Widget> _directActions() {
    final cs = Theme.of(context).colorScheme;
    return [
      _PrimaryButton(
        label: 'Buy Pro',
        icon: Icons.open_in_new,
        onPressed: () => launchUrl(
          Uri.parse('https://bitbag.app/pro'),
          mode: LaunchMode.externalApplication,
        ),
      ),
      const SizedBox(height: 6),
      Semantics(
        container: true,
        button: true,
        expanded: _keyExpanded,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _keyExpanded = !_keyExpanded),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Already have a key?',
                    style: _linkStyle(context),
                  ),
                ),
                Icon(
                  _keyExpanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  color: cs.secondary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
      if (_keyExpanded) ...[
        const SizedBox(height: 8),
        TextField(
          controller: _tokenController,
          maxLines: 2,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Paste your license key…',
            errorText: _errorText,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            suffixIcon: IconButton(
              icon: const Icon(Icons.content_paste_outlined, size: 18),
              tooltip: 'Paste from clipboard',
              onPressed: _pasteKey,
            ),
          ),
          onChanged: (_) => setState(() => _errorText = null),
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: _verifying ? null : _verifyKey,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            foregroundColor: _accentText(context),
          ),
          child: _verifying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Verify key'),
        ),
      ],
    ];
  }
}

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

/// Accent text (links, Retry, Verify key): Bitcoin orange as drawn on the
/// dark sheet. On the light sheet orange text is 2.3:1 on white, so it reads
/// in the text colour instead.
Color _accentText(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return _isDark(context) ? cs.primary : cs.onSurface;
}

/// Text links on the sheet (Restore purchase, Retry, Already have a key?):
/// the accent colour, a weight up on the light sheet so they still read as
/// actions.
TextStyle _linkStyle(BuildContext context) => TextStyle(
      fontSize: 14,
      color: _accentText(context),
      fontWeight: _isDark(context) ? FontWeight.w400 : FontWeight.w500,
    );

ButtonStyle _linkButtonStyle(
  BuildContext context, {
  EdgeInsetsGeometry? padding,
  Size? minimumSize,
}) =>
    TextButton.styleFrom(
      foregroundColor: _accentText(context),
      textStyle: Theme.of(context).textTheme.labelLarge?.merge(
            _linkStyle(context),
          ),
      padding: padding,
      minimumSize: minimumSize,
    );

/// The store's error line. Dark: the error red. Light: red text
/// is 3.3:1 on white, so the text takes the text colour and a leading error
/// icon carries the red.
class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_isDark(context)) {
      return Text(
        message,
        style: TextStyle(color: cs.error, fontSize: 13),
        textAlign: TextAlign.center,
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.error_outline, size: 16, color: cs.error),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            message,
            style: TextStyle(color: cs.onSurface, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

// ── Top: drag handle and Close ───────────────────────────────────────────────

class _SheetTop extends StatelessWidget {
  const _SheetTop();

  /// 8 + the 4 px handle + the 48 px Close target; text size doesn't change
  /// it.
  static const height = 60.0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: IconButton(
              icon: const Icon(Icons.close, size: 20),
              color: cs.secondary,
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      ],
    );
  }
}

// ── What you get: figure, headline, features ─────────────────────────────────

class _WhatYouGet extends StatelessWidget {
  const _WhatYouGet();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _HeroFigure(),
        const SizedBox(height: 22),
        Semantics(
          header: true,
          child: Text(
            'Your real balance, looked up privately',
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 26,
              fontWeight: FontWeight.w400,
              letterSpacing: -0.3,
              height: 1.2,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          "Add your wallet's public key once. Bag keeps the balance current on "
          'its own, and every lookup goes through Tor built into Bag.',
          style: TextStyle(color: cs.bodyText, fontSize: 15, height: 1.5),
        ),
        const SizedBox(height: 22),
        for (final (i, (title, body)) in _features.indexed) ...[
          if (i > 0) const SizedBox(height: 14),
          _FeatureRow(title: title, body: body),
        ],
      ],
    );
  }
}

// A getter, not a final: the platform check is read when the sheet builds.
List<(String, String)> get _features => [
      (
        'Watch-only wallets',
        'Single-sig, multisig and Bitkey, from a public key or descriptor. '
            'Read-only: Bag can never spend.',
      ),
      (
        'Tor built in',
        'Wallet and price lookups go through Tor inside Bag. No other app to '
            'install.',
      ),
      (
        'Bitcoin Health Check',
        'A privacy score for your coins, with what to fix first.',
      ),
      if (SentinelService.isSupported)
        (
          'Sentinel',
          'A notification the moment a payment touches one of your wallets.',
        ),
      (
        'Your own node or proxy',
        'Point Bag at your own Esplora server, or route through your SOCKS5 '
            'or HTTP proxy.',
      ),
      (
        'Fee estimates and alerts',
        'Mempool fees on the home screen, and a ping when they reach your '
            'target.',
      ),
    ];

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.check_rounded, size: 16, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(
                    color: cs.secondary,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Hero figure: three wallets add up; the lookup goes over Tor ──────────────

/// A static illustration, drawn with widgets (no image, no network): three
/// example holdings summing to a total, and the route a lookup takes.
class _HeroFigure extends StatelessWidget {
  const _HeroFigure();

  // The total and its BTC figure share one line box, so they sit on one
  // baseline side by side and still wrap at large text sizes.
  static const _totalStrut = StrutStyle(
    fontSize: 30,
    height: 1.2,
    forceStrutHeight: true,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'What Bag Pro adds up for you',
            style: TextStyle(fontSize: 12, color: cs.secondary),
          ),
          const SizedBox(height: 12),
          const _WalletLine(name: 'Bitkey', detail: '2-of-3', btc: '0.5000'),
          const SizedBox(height: 9),
          const _WalletLine(name: 'Coldcard', btc: '0.2100'),
          const SizedBox(height: 9),
          const _WalletLine(
            name: 'Kraken',
            detail: 'typed in',
            btc: '0.0424',
            typedIn: true,
          ),
          const SizedBox(height: 12),
          Divider(height: 1, thickness: 1, color: cs.outline),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 12,
            children: [
              Text(
                '\$71,482',
                strutStyle: _totalStrut,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 30,
                  fontWeight: FontWeight.w300,
                  letterSpacing: -0.5,
                ),
              ),
              Text(
                '0.7524 BTC',
                strutStyle: _totalStrut,
                style: TextStyle(
                  color: cs.bodyText,
                  fontSize: 14,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const _RouteLine(),
        ],
      ),
    );
  }
}

class _WalletLine extends StatelessWidget {
  const _WalletLine({
    required this.name,
    required this.btc,
    this.detail,
    this.typedIn = false,
  });

  final String name;
  final String? detail;
  final String btc;

  /// A balance typed in by hand rather than read from a wallet: hollow dot.
  final bool typedIn;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(color: cs.onSurface, fontSize: 14);
    return Row(
      children: [
        SizedBox(
          width: 14,
          child: Center(
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: typedIn ? null : cs.primary,
                border: typedIn
                    ? Border.all(color: cs.secondary, width: 1.5)
                    : null,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(
              text: name,
              children: [
                if (detail != null)
                  TextSpan(
                    text: ' $detail',
                    style: TextStyle(color: cs.secondary),
                  ),
              ],
            ),
            style: style,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          btc,
          style: style.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// Your phone → three Tor relays → the explorer. A screen reader hears it as
/// one sentence.
class _RouteLine extends StatelessWidget {
  const _RouteLine();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final label = TextStyle(fontSize: 11, color: cs.secondary);
    return Semantics(
      label: 'Your phone connects to the block explorer through three Tor '
          'relays',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 22,
              child: CustomPaint(
                painter: _RoutePainter(
                  background: theme.scaffoldBackgroundColor,
                  accent: cs.primary,
                  phone: cs.onSurface,
                  explorer: cs.secondary,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The middle label is the longest; 2:3:2 keeps it on one
                // line on a small phone.
                Expanded(flex: 2, child: Text('Your phone', style: label)),
                Expanded(
                  flex: 3,
                  child: Text(
                    'Three Tor relays',
                    style: label,
                    textAlign: TextAlign.center,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    'Explorer',
                    style: label,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RoutePainter extends CustomPainter {
  const _RoutePainter({
    required this.background,
    required this.accent,
    required this.phone,
    required this.explorer,
  });

  final Color background;
  final Color accent;
  final Color phone;
  final Color explorer;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    const left = 8.0;
    final right = size.width - 8;

    // The path, then the hops travelling along it.
    canvas.drawLine(
      Offset(left, y),
      Offset(right, y),
      Paint()
        ..color = accent.withValues(alpha: 0.22)
        ..strokeWidth = 2,
    );
    final dash = Paint()
      ..color = accent
      ..strokeWidth = 2;
    for (var x = left; x < right; x += 10) {
      canvas.drawLine(
        Offset(x, y),
        Offset((x + 3).clamp(left, right), y),
        dash,
      );
    }

    final fill = Paint()..color = background;
    Paint stroke(Color color, double width) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;

    // Your phone.
    final phoneBox = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, y - 8, 16, 16),
      const Radius.circular(4),
    );
    canvas
      ..drawRRect(phoneBox, fill)
      ..drawRRect(phoneBox, stroke(phone, 1.5));

    // Three relays, centred under their label.
    for (final f in const [0.3, 0.5, 0.7]) {
      final c = Offset(size.width * f, y);
      canvas
        ..drawCircle(c, 5, fill)
        ..drawCircle(c, 5, stroke(accent, 2));
    }

    // The explorer.
    final explorerBox = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width - 18, y - 8, 18, 16),
      const Radius.circular(3),
    );
    canvas
      ..drawRRect(explorerBox, fill)
      ..drawRRect(explorerBox, stroke(explorer, 1.5));
  }

  @override
  bool shouldRepaint(_RoutePainter old) =>
      old.background != background ||
      old.accent != accent ||
      old.phone != phone ||
      old.explorer != explorer;
}

// ── Footer ───────────────────────────────────────────────────────────────────

/// "{price} once" and "No subscription"; "One-time purchase" when the price
/// isn't known (still loading, no store, or the direct flavor).
class _PriceLine extends StatelessWidget {
  const _PriceLine({required this.price});

  final String? price;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = TextStyle(color: cs.onSurface, fontSize: 15);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      spacing: 12,
      children: [
        Flexible(
          child: price == null
              ? Text('One-time purchase', style: base)
              : Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: price,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const TextSpan(text: ' once'),
                    ],
                  ),
                  style: base,
                ),
        ),
        Flexible(
          child: Text(
            'No subscription',
            textAlign: TextAlign.end,
            style: TextStyle(color: cs.secondary, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// The 52 px Bitcoin-orange button: Unlock Pro (store) or Buy Pro (direct).
/// While [pending], a spinner sits before the label and it can't be pressed.
class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.pending = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return FilledButton(
      onPressed: pending ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        minimumSize: const Size.fromHeight(52),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: theme.textTheme.labelLarge
            ?.copyWith(fontSize: 16, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pending) ...[
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
          if (icon != null) ...[
            const SizedBox(width: 8),
            Icon(icon, size: 18),
          ],
        ],
      ),
    );
  }
}
