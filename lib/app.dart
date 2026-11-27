import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/constants/app_constants.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/secret_on_screen.dart';
import 'features/dca/presentation/dca_screen.dart';
import 'features/home/presentation/home_screen.dart';
import 'features/onboarding/presentation/onboarding_screen.dart';
import 'features/splash/presentation/splash_screen.dart';
import 'features/settings/presentation/sentinel_screen.dart';
import 'features/settings/presentation/settings_screen.dart';
import 'features/settings/presentation/utxo_inspector_screen.dart';
import 'features/wallets/presentation/wallets_screen.dart';
import 'providers/biometric_lock_provider.dart';
import 'providers/fee_alerts_provider.dart';
import 'providers/network_settings_provider.dart';
import 'providers/purchase_provider.dart';
import 'providers/sentinel_provider.dart';
import 'providers/shared_preferences_provider.dart';
import 'models/network_route.dart';
import 'services/embedded_tor_service.dart';
import 'services/tor_host.dart';
import 'services/tor_service.dart';
import 'services/network/route_gate.dart';
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

// A detached arrived and no resume since: the engine may be kept after all
// (M8). Top-level, like _splashShown, so it survives the app State being
// re-created before that resume (N-e).
bool _torDetached = false;

/// Whether onboarding is finished, read from prefs on every call (each
/// navigation, each unlock): finishing it and Debug "Reset onboarding"
/// change it within the session. [BagApp.onboardingComplete] is the value
/// at launch, for the splash.
bool _onboardingCompleteNow(WidgetRef ref) =>
    ref
        .read(sharedPreferencesProvider)
        .getBool(AppConstants.keyOnboardingComplete) ??
    false;

/// Where each pre-2.0 location of the screens that moved to the Wallets tab
/// lives now. Wallet & Privacy, the health check and Sentinel used to sit
/// under `/settings`; a deep link (Android's MainActivity is exported, so any
/// installed app or `adb` can open a route) or an old screenshot mock can
/// still name the old path.
const _legacyLocations = <String, String>{
  '/settings/wallet-privacy/health-check': '/wallets/health-check',
  '/settings/wallet-privacy': '/wallets',
  '/settings/sentinel': '/wallets/sentinel',
};

/// [uri]'s path as go_router matches it: case-insensitively, so lower-cased,
/// and with trailing slashes dropped.
String _matchedPath(Uri uri) {
  var path = uri.path.toLowerCase();
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

/// The current location for a moved screen's old [uri], or null when [uri] is
/// not one of them. Case and trailing slashes are ignored, as go_router
/// ignores them when it matches a route (`/Settings/Wallet-Privacy` used to
/// open the screen). Query kept, `extra` dropped: a redirect is a location
/// string, and nothing passes `extra` to these screens.
@visibleForTesting
String? redirectLegacyLocation(Uri uri) {
  final target = _legacyLocations[_matchedPath(uri)];
  return target == null ? null : uri.replace(path: target).toString();
}

/// The router's Pro gate: without Pro, every location below `/wallets` (the
/// health check and Sentinel, both Pro screens) becomes `/wallets`, which
/// shows a free user what Pro includes. A screen added under `/wallets` is
/// gated too. Sentinel also becomes `/wallets` where it doesn't exist
/// (`!SentinelService.isSupported`; since Sentinel Lite, iOS has it too),
/// Pro or not. Null for every other location.
@visibleForTesting
String? redirectProLocation(Uri uri, {required bool proUnlocked}) {
  final path = _matchedPath(uri);
  if (!path.startsWith('/wallets/')) return null;
  if (!proUnlocked) return '/wallets';
  final sentinel =
      path == '/wallets/sentinel' || path.startsWith('/wallets/sentinel/');
  return sentinel && !SentinelService.isSupported ? '/wallets' : null;
}

/// `/onboarding` once onboarding is done becomes `/`: a deep link (or an old
/// saved location) must not reopen it, because finishing or skipping it again
/// would overwrite the saved amount and currencies. Debug "Reset onboarding"
/// clears the flag before it navigates, so it still opens. Null otherwise.
@visibleForTesting
String? redirectOnboardingLocation(
  Uri uri, {
  required bool onboardingComplete,
}) =>
    onboardingComplete && _matchedPath(uri) == '/onboarding' ? '/' : null;

/// GoRouter's top-level `redirect`: a finished onboarding goes Home; then the
/// legacy map, then the Pro gate on its result, so a free user's
/// `/settings/sentinel` ends at `/wallets` in one hop. GoRouter also runs it
/// for the initial location, so a cold start on any of these paths lands
/// right.
@visibleForTesting
String? redirectLocation(
  Uri uri, {
  required bool proUnlocked,
  bool onboardingComplete = false,
}) {
  final onboarding = redirectOnboardingLocation(
    uri,
    onboardingComplete: onboardingComplete,
  );
  if (onboarding != null) return onboarding;
  final legacy = redirectLegacyLocation(uri);
  final gated = redirectProLocation(
    legacy == null ? uri : Uri.parse(legacy),
    proUnlocked: proUnlocked,
  );
  return gated ?? legacy;
}

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
      // Pro is read on every navigation. At cold start it is the cached bool
      // until the licence re-check or the store confirms it, so a Pro user
      // whose cache is briefly false (e.g. a reinstall before
      // restorePurchases answers) is sent to /wallets: failing closed, by
      // design (R-B2b).
      redirect: (_, state) => redirectLocation(
        state.uri,
        proUnlocked: ref.read(proUnlockedProvider),
        onboardingComplete: _onboardingCompleteNow(ref),
      ),
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
                  path: '/wallets',
                  builder: (_, __) => const WalletsScreen(),
                  routes: [
                    GoRoute(
                      path: 'health-check',
                      builder: (context, state) => const UtxoInspectorScreen(),
                    ),
                    GoRoute(
                      path: 'sentinel',
                      builder: (_, __) => const SentinelScreen(),
                    ),
                  ],
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
                ),
              ],
            ),
          ],
        ),
      ],
    );
    // Pro revoked (the cold-start re-check found no valid licence) while on a
    // Pro screen: leave it. The leaf match is checked, not the location: a
    // screen opened with `push` (the UTXOs button, the Sentinel card) is not
    // part of the location, so re-running the redirect would not reach it.
    ref.listenManual(proUnlockedProvider, (_, unlocked) {
      if (unlocked) return;
      final leaf =
          _router.routerDelegate.currentConfiguration.lastOrNull?.matchedLocation;
      if (leaf != null &&
          redirectProLocation(Uri.parse(leaf), proUnlocked: false) != null) {
        _router.go('/wallets');
      }
    });
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
        if ((lockEnabled && !_locked) || _secretNeedsCover) {
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
        if (state == AppLifecycleState.paused && _onEmbeddedTor) {
          // Let the in-app Tor client sleep while suspended.
          unawaited(EmbeddedTorService.onPause());
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

        if (_torDetached) {
          // The engine was kept after a detached after all (M8): the client
          // was stopped then, so apply the route again.
          _torDetached = false;
          TorService.followRoute(ref.read(networkSettingsProvider).route);
        }
        if (_onEmbeddedTor) {
          // Wake the in-app Tor client, or restart it if the OS took its
          // circuit while suspended (requests stay refused until it is back).
          unawaited(
            EmbeddedTorService.onResume().whenComplete(
              RouteGate.invalidateCache,
            ),
          );
        }
        ref.read(walletsProvider.notifier).scanAllIfStale();
        // Sync Sentinel state written by the background isolate.
        ref.read(sentinelProvider.notifier).syncFromPrefs();
        // Reload fee alerts so any fired by background services are reflected.
        ref.read(feeAlertsProvider.notifier).reload();
        // Restart Sentinel foreground service if the OS killed it.
        SentinelService.restoreIfEnabled();
      case AppLifecycleState.detached:
        // The engine is about to be destroyed (Android 7–11 Back at the
        // root): a Tor client this isolate runs is stopped now, even if
        // Sentinel leases it, because nothing could stop it once this
        // isolate is gone. Sentinel then starts its own (R-A2a).
        _torDetached = true;
        TorHost.onDetached();
    }
  }

  /// A secret dialog is open on iOS, where `setSecureMode` does nothing:
  /// the app-switcher snapshot must show the blank, not the xpub (M-15).
  /// Android's FLAG_SECURE already keeps it out, so the notification shade
  /// doesn't blank the app there.
  bool get _secretNeedsCover =>
      defaultTargetPlatform == TargetPlatform.iOS &&
      SecretOnScreen.isShown.value;

  /// Tor selected: the embedded client follows the lifecycle. The route is
  /// read per event — the user may have switched since launch.
  bool get _onEmbeddedTor =>
      ref.read(networkSettingsProvider).route is TorRoute;

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
          // Privacy blank: shown on inactive/task-switcher before lock commits,
          // and on iOS while a secret is on screen. It sits above the
          // Navigator, so it covers dialogs too.
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

/// Finds the privacy cover in tests.
@visibleForTesting
const privacyOverlayKey = ValueKey('privacy-overlay');

class _PrivacyOverlay extends StatelessWidget {
  const _PrivacyOverlay() : super(key: privacyOverlayKey);

  @override
  Widget build(BuildContext context) {
    // Opaque whatever the theme: nothing under it may show through.
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface.withAlpha(0xFF),
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
/// Verifies the Ed25519 token, shows a result snackbar, then navigates home,
/// or back to onboarding if it isn't finished: a website purchase can land
/// mid-onboarding (from the hardware / multisig Pro sheet), and going home
/// would leave onboarding unfinished with nothing saved. Onboarding then
/// restarts from its first page, and a Pro user gets no Pro sheet in it.
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
    final onboarded = _onboardingCompleteNow(ref);
    widget.scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Pro unlocked — thank you!'
            : 'Unlock failed: invalid or missing license key.'),
        behavior: SnackBarBehavior.floating,
        // Onboarding's pages end in a full-width button at the bottom: keep
        // the message above it, so it neither hides the button nor takes its
        // tap.
        margin: onboarded ? null : const EdgeInsets.fromLTRB(16, 0, 16, 100),
      ),
    );
    context.go(onboarded ? '/' : '/onboarding');
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

  /// Branch index -> root location, for the tabs that never restore a
  /// sub-route: 1 Wallets, 3 Settings.
  static const _resetToRoot = {1: '/wallets', 3: '/settings'};

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
            // Wallets (1) and Settings (3) always open at their root, never
            // at a sub-route such as /wallets/health-check.
            final root = _resetToRoot[i];
            if (root != null) {
              context.go(root);
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
              icon: Icon(Icons.account_balance_wallet_outlined),
              selectedIcon: Icon(
                Icons.account_balance_wallet,
                color: AppColors.primary,
              ),
              label: 'Wallets',
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
