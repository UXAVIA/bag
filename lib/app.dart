import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme/app_theme.dart';
import 'features/dca/presentation/dca_screen.dart';
import 'features/home/presentation/home_screen.dart';
import 'features/onboarding/presentation/onboarding_screen.dart';
import 'features/splash/presentation/splash_screen.dart';
import 'features/settings/presentation/sentinel_screen.dart';
import 'features/settings/presentation/settings_screen.dart';
import 'features/settings/presentation/utxo_inspector_screen.dart';
import 'features/settings/presentation/wallet_privacy_screen.dart';
import 'providers/biometric_lock_provider.dart';
import 'providers/fee_alerts_provider.dart';
import 'providers/purchase_provider.dart';
import 'providers/sentinel_provider.dart';
import 'services/sentinel_service.dart';
import 'services/wallet/biometric_storage_service.dart' as bio;
import 'providers/theme_provider.dart';
import 'providers/wallets_provider.dart';

class BagApp extends ConsumerStatefulWidget {
  final bool onboardingComplete;
  final String initialLocation;
  final GlobalKey<NavigatorState>? navigatorKey;

  const BagApp({
    super.key,
    required this.onboardingComplete,
    this.initialLocation = '/splash',
    this.navigatorKey,
  });

  @override
  ConsumerState<BagApp> createState() => _BagAppState();
}

// True after the first cold-start splash has been shown. Persists for the
// lifetime of the Dart isolate so background→foreground re-inits skip splash.
bool _splashShown = false;

class _BagAppState extends ConsumerState<BagApp>
    with WidgetsBindingObserver {
  late final GoRouter _router;
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  bool _locked = false;
  bool _obscured = false; // visual blank shown during inactive/hidden
  bool _authInProgress = false;
  DateTime? _backgroundedAt; // when the app was last fully backgrounded

  // Auth is required on cold start and after being backgrounded longer than this.
  static const _kGracePeriod = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Require auth on cold start if bio lock is enabled.
    if (ref.read(biometricLockProvider)) {
      _locked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _triggerAuth());
    }
    final String initialLocation;
    if (!_splashShown && widget.initialLocation == '/splash') {
      initialLocation = '/splash';
    } else if (widget.initialLocation != '/splash') {
      initialLocation = widget.initialLocation;
    } else {
      initialLocation = '/';
    }
    _splashShown = true;

    _router = GoRouter(
      navigatorKey: widget.navigatorKey,
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/splash',
          builder: (_, __) =>
              SplashScreen(onboardingComplete: widget.onboardingComplete),
        ),
        GoRoute(
          path: '/onboarding',
          builder: (_, __) => const OnboardingScreen(),
        ),
        // Pro unlock deep link: https://bitbag.app/unlock?token=<base64url>
        // Handled as Android App Links — verified against assetlinks.json at install time.
        GoRoute(
          path: '/unlock',
          builder: (_, state) => _UnlockScreen(
            token: state.uri.queryParameters['token'] ?? '',
            scaffoldMessengerKey: _scaffoldMessengerKey,
          ),
        ),
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => _ScaffoldWithNav(shell: shell),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (_, __) => const HomeScreen(),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/dca',
                  builder: (_, __) => const DcaScreen(),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/settings',
                  builder: (_, __) => const SettingsScreen(),
                  routes: [
                    GoRoute(
                      path: 'wallet-privacy',
                      builder: (_, __) => const WalletPrivacyScreen(),
                      routes: [
                        GoRoute(
                          path: 'health-check',
                          builder: (context, state) =>
                              const UtxoInspectorScreen(),
                        ),
                      ],
                    ),
                    GoRoute(
                      path: 'sentinel',
                      builder: (_, __) => const SentinelScreen(),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final lockEnabled = ref.read(biometricLockProvider);
    switch (state) {
      case AppLifecycleState.inactive:
        // Task switcher snapshot is taken during this transition. Show a visual
        // blank so app content isn't captured. Don't record the time or lock
        // yet — user may just be pulling the notification shade.
        if (lockEnabled && !_locked) {
          setState(() => _obscured = true);
        }
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // App is fully backgrounded. Record when this happened so we can
        // apply the grace period on return. First one wins (??=) in case both
        // fire on older/newer Android.
        if (lockEnabled && !_locked) {
          _backgroundedAt ??= DateTime.now();
        }
      case AppLifecycleState.resumed:
        // Always clear the visual blank first.
        setState(() => _obscured = false);

        if (_locked) {
          // Cold-start path: _locked was set in initState, trigger auth.
          _triggerAuth();
        } else if (lockEnabled && _backgroundedAt != null) {
          final elapsed = DateTime.now().difference(_backgroundedAt!);
          _backgroundedAt = null;
          if (elapsed > _kGracePeriod) {
            // Away long enough — require auth.
            setState(() => _locked = true);
            _triggerAuth();
          }
          // else: within grace period, just clear the overlay — no auth.
        } else {
          _backgroundedAt = null;
        }

        ref.read(walletsProvider.notifier).scanAllIfStale();
        // Sync Sentinel state written by the background isolate.
        ref.read(sentinelProvider.notifier).syncFromPrefs();
        // Reload fee alerts so any fired by background services are reflected.
        ref.read(feeAlertsProvider.notifier).reload();
        // Restart Sentinel foreground service if the OS killed it.
        SentinelService.restoreIfEnabled();
      default:
        break;
    }
  }

  Future<void> _triggerAuth() async {
    if (_authInProgress) return;
    _authInProgress = true;
    final ok = await bio.authenticateForAppLock();
    _authInProgress = false;
    if (ok && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'Bag',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: _router,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      builder: (context, child) => Stack(
        children: [
          child!,
          // Privacy blank: shown on inactive/task-switcher before lock commits.
          if (_obscured && !_locked)
            const _PrivacyOverlay(),
          // Lock overlay: shown after paused/hidden — requires biometric auth.
          if (_locked)
            _LockOverlay(onUnlock: _triggerAuth),
        ],
      ),
    );
  }
}

class _PrivacyOverlay extends StatelessWidget {
  const _PrivacyOverlay();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: const SizedBox.expand(),
    );
  }
}

class _LockOverlay extends StatelessWidget {
  final VoidCallback onUnlock;

  const _LockOverlay({required this.onUnlock});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 56, color: AppColors.primary),
              const SizedBox(height: 24),
              Text(
                'Bag is locked',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: onUnlock,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Unlock'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Handles the Pro unlock App Link: `https://bitbag.app/unlock?token=<base64url>`
///
/// Verifies the Ed25519 token, shows a result snackbar, then navigates home.
/// Shown only transiently — the user sees a brief loading spinner.
class _UnlockScreen extends ConsumerStatefulWidget {
  final String token;
  final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey;

  const _UnlockScreen({
    required this.token,
    required this.scaffoldMessengerKey,
  });

  @override
  ConsumerState<_UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<_UnlockScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _processUnlock());
  }

  Future<void> _processUnlock() async {
    final ok = widget.token.isNotEmpty &&
        await ref
            .read(proUnlockedProvider.notifier)
            .verifyAndUnlock(widget.token);

    if (!mounted) return;
    widget.scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Pro unlocked — thank you!'
            : 'Unlock failed: invalid or missing license key.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

class _ScaffoldWithNav extends StatelessWidget {
  final StatefulNavigationShell shell;

  const _ScaffoldWithNav({required this.shell});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return PopScope(
      // Allow the system to pop only when already on the Home tab.
      // On any other tab, intercept and go back to Home instead of exiting.
      canPop: shell.currentIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) shell.goBranch(0);
      },
      child: Scaffold(
        body: shell,
        bottomNavigationBar: NavigationBar(
          backgroundColor: cs.surface,
          indicatorColor: AppColors.primary.withValues(alpha: 0.15),
          selectedIndex: shell.currentIndex,
          onDestinationSelected: (i) {
            // Settings branch (index 2) always resets to /settings root —
            // avoids returning to a sub-route like /settings/wallet-privacy.
            if (i == 2) {
              context.go('/settings');
            } else {
              shell.goBranch(i, initialLocation: i == shell.currentIndex);
            }
          },
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home, color: AppColors.primary),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.trending_up_outlined),
              selectedIcon: Icon(Icons.trending_up, color: AppColors.primary),
              label: 'DCA',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings, color: AppColors.primary),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
