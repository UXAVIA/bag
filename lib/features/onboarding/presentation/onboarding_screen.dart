import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/supported_currencies.dart';
import '../../../core/theme/app_theme.dart';
import '../../../providers/portfolio_provider.dart';
import '../../../providers/shared_preferences_provider.dart';
import '../../../widgets/currency_selector.dart';
import '../../settings/presentation/pro_upgrade_sheet.dart';

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

  static const int _totalPages = 4;

  @override
  void dispose() {
    _pageController.dispose();
    _btcController.dispose();
    super.dispose();
  }

  void _next() {
    if (_currentPage < _totalPages - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    }
  }

  void _back() {
    _pageController.previousPage(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _openProSheet() async {
    await showProUpgradeSheet(context);
    await _complete();
  }

  Future<void> _complete() async {
    // Save BTC amount
    final amount = double.tryParse(_btcController.text.trim()) ?? 0.0;
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
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Page dots + skip
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _PageDots(current: _currentPage, total: _totalPages),
                  if (_currentPage < _totalPages - 1)
                    TextButton(
                      onPressed: _complete,
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
                  _WelcomePage(onNext: _next),
                  _BtcAmountPage(
                    controller: _btcController,
                    onNext: _next,
                    onBack: _back,
                  ),
                  _CurrencyPage(
                    selected: _selectedCurrencies,
                    onChanged: (c) => setState(() => _selectedCurrencies = c),
                    onNext: _next,
                    onBack: _back,
                  ),
                  _ProTeaserPage(
                    onComplete: _complete,
                    onBack: _back,
                    onGoProTap: _openProSheet,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Page 1: Welcome ────────────────────────────────────────────────────────

class _WelcomePage extends StatelessWidget {
  final VoidCallback onNext;

  const _WelcomePage({required this.onNext});

  @override
  Widget build(BuildContext context) {
    return Padding(
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
    );
  }
}

// ─── Page 2: BTC Amount ──────────────────────────────────────────────────────

class _BtcAmountPage extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onNext;
  final VoidCallback onBack;

  const _BtcAmountPage({
    required this.controller,
    required this.onNext,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
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
          const SizedBox(height: 28),
          const _OnboardingProTeaser(),
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
    );
  }
}

// ─── Onboarding Pro teaser card ──────────────────────────────────────────────

class _OnboardingProTeaser extends StatelessWidget {
  const _OnboardingProTeaser();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => showProUpgradeSheet(context),
      child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.lock_outline, color: AppColors.primary, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Go Pro for full privacy',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Watch-only wallet · Tor routing · Custom node · Privacy health check',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.7),
                        height: 1.5,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}

// ─── Page 3: Currency Selection ──────────────────────────────────────────────

class _CurrencyPage extends StatelessWidget {
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  final VoidCallback onNext;
  final VoidCallback onBack;

  const _CurrencyPage({
    required this.selected,
    required this.onChanged,
    required this.onNext,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Spacer(flex: 2),
          Icon(
            Icons.swap_horiz_rounded,
            color: AppColors.primary,
            size: 56,
          ),
          const SizedBox(height: 24),
          Text(
            'Choose your\ndisplay currencies',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
          ),
          const SizedBox(height: 12),
          Text(
            'Your net worth will be shown in up to 3 currencies.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
          const SizedBox(height: 32),

          // Current selection chips — hold & drag to reorder, tap × to deselect
          SizedBox(
            height: 48,
            child: ReorderableListView(
              scrollDirection: Axis.horizontal,
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              onReorder: (oldIndex, newIndex) {
                if (newIndex > oldIndex) newIndex--;
                final newList = [...selected];
                newList.insert(newIndex, newList.removeAt(oldIndex));
                onChanged(newList);
              },
              children: [
                for (int i = 0; i < selected.length; i++)
                  Padding(
                    key: ValueKey(selected[i]),
                    padding: EdgeInsets.only(right: i < selected.length - 1 ? 10 : 0),
                    child: ReorderableDragStartListener(
                      index: i,
                      child: _CurrencyChip(
                        label: () {
                          final info = supportedCurrencies[selected[i]];
                          return '${info?.symbol ?? ''} ${info?.code ?? selected[i].toUpperCase()}';
                        }(),
                        onRemove: selected.length > 1
                            ? () => onChanged(
                                  selected.where((c) => c != selected[i]).toList(),
                                )
                            : null,
                      ),
                    ),
                  ),
              ],
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

          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: const BorderSide(color: AppColors.primary),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            onPressed: () => showCurrencySelector(
              context: context,
              selected: selected,
              onChanged: onChanged,
            ),
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Change currencies'),
          ),

          const Spacer(flex: 3),
          _PrimaryButton(label: 'Continue', onTap: onNext),
          const SizedBox(height: 32),
        ],
      ),
    );
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

// ─── Page 4: Pro Teaser ──────────────────────────────────────────────────────

class _ProTeaserPage extends StatelessWidget {
  final VoidCallback onComplete;
  final VoidCallback onBack;
  final VoidCallback onGoProTap;

  const _ProTeaserPage({
    required this.onComplete,
    required this.onBack,
    required this.onGoProTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Spacer(flex: 2),
          Stack(
            alignment: Alignment.topRight,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.shield_outlined, color: AppColors.primary, size: 52),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'PRO',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Take control of your\nBitcoin privacy.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'One-time purchase. No subscription.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w500,
                ),
          ),
          const SizedBox(height: 24),
          ..._proFeatures.map(
            (f) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline, color: AppColors.primary, size: 18),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      f,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(flex: 3),
          _PrimaryButton(label: 'Go Pro →', onTap: onGoProTap),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onComplete,
            child: Text(
              'Maybe later',
              style: TextStyle(color: cs.secondary, fontSize: 14),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static const _proFeatures = [
    'Watch-only wallet — track by zpub, no keys needed',
    'Bitcoin Health Check — privacy score & UTXO analysis',
    'Tor routing for maximum privacy',
    'Connect to your own node or Esplora server',
  ];
}

// ─── Shared Widgets ──────────────────────────────────────────────────────────

class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PrimaryButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
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
    return Row(
      children: List.generate(total, (i) {
        final isActive = i == current;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.only(right: 6),
          width: isActive ? 20 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: isActive
                ? AppColors.primary
                : Theme.of(context).colorScheme.outline,
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}
