import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/supported_currencies.dart';
import '../../../core/theme/app_theme.dart';
import '../../../providers/portfolio_provider.dart';
import '../../../providers/purchase_provider.dart';
import '../../../providers/shared_preferences_provider.dart';
import '../../../widgets/currency_selector.dart';
import '../../settings/presentation/pro_upgrade_sheet.dart';

/// How the user holds their bitcoin, the answer to onboarding's second page.
/// It decides the rest of the route (ruling R-B4d) and is kept in memory
/// only: nothing reads it later, and in plaintext prefs it would label the
/// user as a self-custodian (M-12).
enum OnboardingHolding {
  exchange(
    'On an exchange',
    'Coinbase, Kraken, Strike and the like. You type your amount.',
  ),
  hardware('On a hardware wallet', 'Bitkey, Coldcard, Trezor, Ledger, Jade'),
  multisig(
    'In a multisig',
    '2-of-3 or more, set up in Bitkey, Sparrow or Nunchuk',
  ),
  price('I just follow the price', 'No amount for now');

  const OnboardingHolding(this.title, this.body);

  final String title;
  final String body;

  /// Bag can read this balance from a public key, which is Pro, so the Pro
  /// sheet comes next.
  bool get readsWallet => this == hardware || this == multisig;

  /// A price follower has no amount: the amount page is left out.
  bool get asksAmount => this != price;
}

enum _Step { welcome, holding, amount, currencies }

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  final _btcController = TextEditingController();
  int _currentPage = 0;
  List<String> _selectedCurrencies = List<String>.from(AppConstants.defaultCurrencies);

  /// The option picked on the question page; null until one is.
  OnboardingHolding? _holding;

  /// Set while the question's Continue is storing the answer or the Pro
  /// sheet is open, so a second tap can't open the sheet twice.
  bool _leavingQuestion = false;

  /// Whether the route has the amount page. Before an answer it is assumed,
  /// as for most users.
  bool get _asksAmount => _holding?.asksAmount ?? true;

  /// The pages, in order, for the current answer.
  List<_Step> get _steps => [
        _Step.welcome,
        _Step.holding,
        if (_asksAmount) _Step.amount,
        _Step.currencies,
      ];

  @override
  void dispose() {
    _pageController.dispose();
    _btcController.dispose();
    super.dispose();
  }

  Future<void> _goTo(int page) {
    setState(() => _currentPage = page);
    return _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }

  /// Moves on from [step]. A tap that lands on a page that is already
  /// leaving (a double tap during the slide) does nothing.
  Future<void> _nextFrom(_Step step) async {
    final steps = _steps;
    final index = steps.indexOf(step);
    if (index != _currentPage || index + 1 >= steps.length) return;
    await _goTo(index + 1);
  }

  /// Android back: one page back along the current route, so the amount
  /// page and the currency page both lead back to the question rather than
  /// past it. The welcome page leaves back to the system.
  void _back() {
    if (_currentPage > 0) _goTo(_currentPage - 1);
  }

  Future<void> _continueFromQuestion() async {
    final holding = _holding;
    if (holding == null || _leavingQuestion) return;
    _leavingQuestion = true;
    try {
      // A user who is already Pro (restored at start, or bought in the
      // sheet and came back) is never offered it.
      if (holding.readsWallet && !ref.read(proUnlockedProvider)) {
        if (!mounted) return;
        // Closing the sheet continues, and so does buying (it closes
        // itself).
        await showProUpgradeSheet(context);
      }
      if (mounted) await _nextFrom(_Step.holding);
    } finally {
      _leavingQuestion = false;
    }
  }

  /// Saves what was entered and leaves onboarding; Skip calls it too.
  /// [keepAmount] false leaves the amount at 0: the end of the price-only
  /// route, where the amount page isn't part of the flow.
  Future<void> _complete({bool keepAmount = true}) async {
    // Save BTC amount
    final amount = keepAmount
        ? double.tryParse(_btcController.text.trim()) ?? 0.0
        : 0.0;
    await ref.read(portfolioProvider.notifier).setBtcAmount(amount);
    await ref.read(portfolioProvider.notifier).setCurrencies(_selectedCurrencies);

    // Mark onboarding done
    await ref.read(sharedPreferencesProvider).setBool(
          AppConstants.keyOnboardingComplete,
          true,
        );

    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final steps = _steps;
    final proUnlocked = ref.watch(proUnlockedProvider);

    return PopScope(
      canPop: _currentPage == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              // Page dots + skip
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _PageDots(current: _currentPage, total: steps.length),
                    if (_currentPage < steps.length - 1)
                      TextButton(
                        onPressed: () => _complete(),
                        child: Text(
                          'Skip',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.secondary,
                            fontSize: 14,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Pages
              Expanded(
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (i) => setState(() => _currentPage = i),
                  children: [
                    for (final step in steps)
                      switch (step) {
                        _Step.welcome => _WelcomePage(
                            key: const ValueKey(_Step.welcome),
                            onNext: () => _nextFrom(_Step.welcome),
                          ),
                        _Step.holding => _HoldingPage(
                            key: const ValueKey(_Step.holding),
                            selected: _holding,
                            proUnlocked: proUnlocked,
                            onSelected: (h) => setState(() => _holding = h),
                            onContinue:
                                _holding == null ? null : _continueFromQuestion,
                          ),
                        _Step.amount => _BtcAmountPage(
                            key: const ValueKey(_Step.amount),
                            controller: _btcController,
                            onNext: () => _nextFrom(_Step.amount),
                          ),
                        _Step.currencies => _CurrencyPage(
                            key: const ValueKey(_Step.currencies),
                            selected: _selectedCurrencies,
                            onChanged: (c) =>
                                setState(() => _selectedCurrencies = c),
                            onNext: () => _complete(keepAmount: _asksAmount),
                          ),
                      },
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Page 1: Welcome ────────────────────────────────────────────────────────

class _WelcomePage extends StatelessWidget {
  final VoidCallback onNext;

  const _WelcomePage({super.key, required this.onNext});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  SvgPicture.asset(
                    Theme.of(context).brightness == Brightness.dark
                        ? 'assets/images/logo_full.svg'
                        : 'assets/images/logo_full_light.svg',
                    height: 110,
                  ),
                  const SizedBox(height: 40),
                  Text(
                    'Your Bitcoin net worth,\nalways in view.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displayMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Track your BTC holdings in multiple currencies.\nPrivate, local-only. No accounts, no tracking.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                  const Spacer(flex: 3),
                  _PrimaryButton(label: 'Get Started', onTap: onNext),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

// ─── Page 3: BTC Amount (not on the price-only route) ────────────────────────

class _BtcAmountPage extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onNext;

  const _BtcAmountPage({
    super.key,
    required this.controller,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  const Icon(Icons.currency_bitcoin, color: AppColors.primary, size: 56),
                  const SizedBox(height: 24),
                  Text(
                    'How much Bitcoin\ndo you own?',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displayMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Enter your holdings to see your net worth.\nYou can update this anytime in settings.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                  const SizedBox(height: 36),
                  TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,8}')),
                    ],
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displayMedium?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w400,
                        ),
                    decoration: InputDecoration(
                      hintText: '0.00000000',
                      hintStyle: Theme.of(context).textTheme.displayMedium?.copyWith(
                            color: Theme.of(context).colorScheme.outline,
                            fontWeight: FontWeight.w300,
                          ),
                      suffixText: 'BTC',
                      suffixStyle: TextStyle(
                        color: Theme.of(context).colorScheme.secondary,
                        fontSize: 16,
                      ),
                    ),
                    onSubmitted: (_) => onNext(),
                  ),
                  const Spacer(flex: 3),
                  _PrimaryButton(label: 'Continue', onTap: onNext),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: onNext,
                    child: Text(
                      "I'll set this later",
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.secondary,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

// ─── Last page: Currency Selection ───────────────────────────────────────────

class _CurrencyPage extends StatelessWidget {
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  final VoidCallback onNext;

  const _CurrencyPage({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(
            child: Column(
              children: [
                const Spacer(flex: 2),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    children: [
                      Icon(Icons.swap_horiz_rounded,
                          color: AppColors.primary, size: 56),
                      const SizedBox(height: 24),
                      Text(
                        'Choose your\ndisplay currencies',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .displayMedium
                            ?.copyWith(fontWeight: FontWeight.w600, height: 1.2),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Your net worth will be shown in up to 3 currencies.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(height: 1.6),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),

                // Chip row — reduced padding so all 3 chips are always visible
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    height: 48,
                    child: ReorderableListView(
                      scrollDirection: Axis.horizontal,
                      shrinkWrap: true,
                      buildDefaultDragHandles: false,
                      proxyDecorator: (child, index, animation) => child,
                      onReorderItem: (oldIndex, newIndex) {
                        final newList = [...selected];
                        newList.insert(newIndex, newList.removeAt(oldIndex));
                        onChanged(newList);
                      },
                      children: [
                        for (int i = 0; i < selected.length; i++)
                          Padding(
                            key: ValueKey(selected[i]),
                            padding: EdgeInsets.only(
                                right: i < selected.length - 1 ? 10 : 0),
                            child: ReorderableDragStartListener(
                              index: i,
                              child: _CurrencyChip(
                                label: () {
                                  final info = supportedCurrencies[selected[i]];
                                  return '${info?.symbol ?? ''} ${info?.code ?? selected[i].toUpperCase()}';
                                }(),
                                onRemove: selected.length > 1
                                    ? () => onChanged(
                                          selected
                                              .where((c) => c != selected[i])
                                              .toList(),
                                        )
                                    : null,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (selected.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Hold & drag to reorder',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                    ),
                  ),
                const SizedBox(height: 20),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      side: const BorderSide(color: AppColors.primary),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                    ),
                    onPressed: () => showCurrencySelector(
                      context: context,
                      selected: selected,
                      onChanged: onChanged,
                    ),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Change currencies'),
                  ),
                ),

                const Spacer(flex: 3),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: _PrimaryButton(label: 'Continue', onTap: onNext),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _CurrencyChip extends StatelessWidget {
  final String label;
  final VoidCallback? onRemove;

  const _CurrencyChip({required this.label, this.onRemove});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onRemove,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            if (onRemove != null) ...[
              const SizedBox(width: 6),
              const Icon(Icons.close, color: AppColors.primary, size: 14),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Page 2: How do you hold your bitcoin? ──────────────────────────────────

/// The holding question, as drawn on the Onboarding artboard: a left-aligned
/// title and body, four radio tiles, the Pro note for a hardware wallet or a
/// multisig, and Continue, which waits for an answer.
class _HoldingPage extends StatelessWidget {
  final OnboardingHolding? selected;

  /// A Pro user gets no Pro note (and no sheet).
  final bool proUnlocked;
  final ValueChanged<OnboardingHolding> onSelected;

  /// Null until an option is picked.
  final VoidCallback? onContinue;

  const _HoldingPage({
    super.key,
    required this.selected,
    required this.proUnlocked,
    required this.onSelected,
    required this.onContinue,
  });

  static const title = 'How do you hold your bitcoin?';
  static const body =
      'Pick the closest one. It decides how Bag finds your balance, and you '
      'can change it later.';
  static const proNote =
      "Bag can read the balance straight from your wallet's public key, so "
      "you never type it in. That's part of Bag Pro. Next we'll show you "
      'what it includes.';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bodyColor = cs.bodyText;
    return LayoutBuilder(builder: (context, constraints) {
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 40),
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 30,
                        fontWeight: FontWeight.w300,
                        letterSpacing: -0.5,
                        height: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    body,
                    style: TextStyle(color: bodyColor, fontSize: 15, height: 1.5),
                  ),
                  const SizedBox(height: 28),
                  for (final option in OnboardingHolding.values) ...[
                    if (option != OnboardingHolding.values.first)
                      const SizedBox(height: 10),
                    _HoldingOption(
                      option: option,
                      selected: option == selected,
                      onTap: () => onSelected(option),
                    ),
                  ],
                  if ((selected?.readsWallet ?? false) && !proUnlocked) ...[
                    const SizedBox(height: 16),
                    // Announced as it appears, so a screen reader user hears
                    // why the next step is the Pro sheet.
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        proNote,
                        style: TextStyle(
                          color: bodyColor,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  const SizedBox(height: 24),
                  _PrimaryButton(label: 'Continue', onTap: onContinue),
                  const SizedBox(height: 28),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// One answer: a single radio semantics node (in a mutually exclusive group,
/// checked or not) that reads its title and body.
class _HoldingOption extends StatelessWidget {
  final OnboardingHolding option;
  final bool selected;
  final VoidCallback onTap;

  const _HoldingOption({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return MergeSemantics(
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        checked: selected,
        enabled: true,
        child: Material(
          // Selected: a faint orange wash over the page, as drawn.
          color: selected
              ? Color.alphaBlend(
                  cs.primary.withValues(alpha: 0.07),
                  theme.scaffoldBackgroundColor,
                )
              : cs.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: selected
                ? BorderSide(color: cs.primary, width: 1.5)
                : BorderSide(color: cs.outline),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 68),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            option.title,
                            style: TextStyle(
                              color: cs.onSurface,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            option.body,
                            style: TextStyle(
                              color: cs.secondary,
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _RadioDot(selected: selected),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The drawn radio: an orange ring around a dark centre when selected, a thin
/// muted ring otherwise. Decoration only; the tile carries the semantics.
class _RadioDot extends StatelessWidget {
  final bool selected;

  const _RadioDot({required this.selected});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? cs.surface : null,
        border: selected
            ? Border.all(color: cs.primary, width: 6)
            // At least 3:1 against the tile (`surface`), as a control's
            // boundary needs: #747493 on #13131A is 4.1:1 in dark mode,
            // #7E7E9B on white 3.9:1 in light. The drawn #555570 was 2.6:1.
            : Border.all(color: Color.lerp(cs.outline, cs.secondary, 0.8)!, width: 2),
      ),
    );
  }
}

// ─── Shared Widgets ──────────────────────────────────────────────────────────

class _PrimaryButton extends StatelessWidget {
  final String label;

  /// Null disables the button.
  final VoidCallback? onTap;

  const _PrimaryButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _PageDots extends StatelessWidget {
  final int current;
  final int total;

  const _PageDots({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Step ${current + 1} of $total',
      child: ExcludeSemantics(
        child: Row(
          children: List.generate(total, (i) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.only(right: 6),
              width: 18,
              height: 4,
              decoration: BoxDecoration(
                color: i == current
                    ? cs.primary
                    // #39394C on the dark page, the drawn #3A3A50.
                    : Color.lerp(cs.outline, cs.secondary, 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        ),
      ),
    );
  }
}
