import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../models/network_route.dart';
import '../providers/network_settings_provider.dart';
import '../providers/route_status_provider.dart';
import '../services/network/route_gate.dart';

/// A place on the Wallets tab that a tap on [RouteStatusPill] scrolls to.
enum WalletsAnchor {
  /// The Pro layout's Network heading, scrolled into view.
  network,

  /// Anywhere in the free layout: its scroll view goes back to the top when
  /// the tap comes from another tab.
  top,
}

/// Marks [child] as a [WalletsAnchor] on the Wallets tab.
///
/// Not a `GlobalKey`: a push the router redirects to `/wallets` stacks a
/// second Wallets screen on the first, and a key can't be in the tree twice.
/// The pill uses the anchor on the current route.
class WalletsScrollAnchor extends StatefulWidget {
  const WalletsScrollAnchor({
    super.key,
    required this.anchor,
    required this.child,
  });

  final WalletsAnchor anchor;
  final Widget child;

  /// The context of the [anchor] on the current route, if one is built.
  static BuildContext? find(WalletsAnchor anchor) {
    for (final state in _WalletsScrollAnchorState._live.reversed) {
      if (state.mounted &&
          state.widget.anchor == anchor &&
          state._onCurrentRoute) {
        return state.context;
      }
    }
    return null;
  }

  @override
  State<WalletsScrollAnchor> createState() => _WalletsScrollAnchorState();
}

class _WalletsScrollAnchorState extends State<WalletsScrollAnchor> {
  /// Every anchor in the tree, oldest first.
  static final _live = <_WalletsScrollAnchorState>[];

  bool _onCurrentRoute = true;

  @override
  void initState() {
    super.initState();
    _live.add(this);
  }

  @override
  void dispose() {
    _live.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A dependency: rebuilt when its route is covered or uncovered.
    _onCurrentRoute = ModalRoute.isCurrentOf(context) ?? true;
    return widget.child;
  }
}

enum _Tone { up, checking, down, direct }

typedef _Tint = ({Color fill, Color edge, Color dot});

/// The route every request takes, and whether it is up, always in view at
/// the top of Home and the Wallets tab.
///
/// - Tor: `Tor` (green dot), `Tor connecting…` (orange) while checking,
///   `Tor paused` (red) when down.
/// - Proxy: `Proxy` (green), `Proxy connecting…` (orange) while checking,
///   `Proxy paused` (red) when down.
/// - Unreadable proxy: `Proxy paused` (red), whatever the status.
/// - Direct: `Direct`, muted, no dot, whatever the status.
///
/// The status comes from `routeStatusProvider` alone. On Tor that provider
/// already follows the built-in client (ruling R2), so there is no platform
/// switch here (R-B5b). The pill never shows a host, port,
/// credential or Tor error.
///
/// A tap opens the Wallets tab, scrolled to its Network section for a Pro
/// user (R-B5c), at the top for a free user coming from another tab.
///
/// Hosts put it in `AppBar.title`: that slot gets whatever room the leading
/// and the actions leave, and caps text scaling as for a title. When even
/// that is too narrow, the label shrinks rather than lose its last word.
class RouteStatusPill extends ConsumerWidget {
  const RouteStatusPill({super.key});

  static const _scrollDuration = Duration(milliseconds: 300);

  /// Dark: as drawn on the RouteStatus artboard. Light: the same hues as
  /// pale fills, with darker dots so each still reads at 3:1 against its
  /// fill.
  static const _tints = <Brightness, Map<_Tone, _Tint>>{
    Brightness.dark: {
      _Tone.up: (
        fill: Color(0xFF0E1F1A),
        edge: Color(0xFF1F4D40),
        dot: AppColors.positive,
      ),
      _Tone.checking: (
        fill: Color(0xFF1A140A),
        edge: Color(0xFF4A3414),
        dot: AppColors.primary,
      ),
      _Tone.down: (
        fill: Color(0xFF24101A),
        edge: Color(0xFF5A1E2A),
        dot: AppColors.negative,
      ),
    },
    Brightness.light: {
      _Tone.up: (
        fill: Color(0xFFE3F5EF),
        edge: Color(0xFFA6DCCB),
        dot: Color(0xFF008F6B),
      ),
      _Tone.checking: (
        fill: Color(0xFFFBEEDD),
        edge: Color(0xFFEDC48E),
        dot: Color(0xFFB5650A),
      ),
      _Tone.down: (
        fill: Color(0xFFFBE5E8),
        edge: Color(0xFFF0A9B1),
        dot: Color(0xFFB3323D),
      ),
    },
  };

  /// A probe still running reads as checking, never as the answer it is
  /// replacing: after a route change that answer described the old route.
  /// An error fails closed.
  static RouteStatus _statusOf(AsyncValue<RouteStatus> status) {
    if (status.isLoading) return RouteStatus.checking;
    if (status.hasError) return RouteStatus.unavailable;
    return status.valueOrNull ?? RouteStatus.checking;
  }

  static (String, _Tone) _describe(NetworkRoute route, RouteStatus? status) =>
      switch (route) {
        DirectRoute() => ('Direct', _Tone.direct),
        MisconfiguredProxyRoute() => ('Proxy paused', _Tone.down),
        TorRoute() => switch (status) {
          RouteStatus.available => ('Tor', _Tone.up),
          RouteStatus.unavailable => ('Tor paused', _Tone.down),
          RouteStatus.checking || null => ('Tor connecting…', _Tone.checking),
        },
        ProxyRoute() => switch (status) {
          RouteStatus.available => ('Proxy', _Tone.up),
          RouteStatus.unavailable => ('Proxy paused', _Tone.down),
          // Said in words, as for Tor: the dot's colour alone can't carry
          // it, and a screen reader hears only the label.
          RouteStatus.checking || null => ('Proxy connecting…', _Tone.checking),
        },
      };

  static void _open(BuildContext context) {
    final fromElsewhere =
        GoRouter.of(context).routerDelegate.currentConfiguration.uri.path !=
        '/wallets';
    context.go('/wallets');
    _reveal(fromElsewhere: fromElsewhere);
  }

  /// Once the Wallets tab is laid out: Pro scrolls to its Network heading.
  /// Free has none; coming from another tab, it opens at the top rather than
  /// wherever it was left, and already on the tab nothing moves. A few
  /// frames' grace covers a tab built for the first time; already on the
  /// tab, `go` changes nothing, so a frame is asked for here.
  static void _reveal({required bool fromElsewhere, int framesLeft = 3}) {
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      final heading = WalletsScrollAnchor.find(WalletsAnchor.network);
      if (heading != null) {
        Scrollable.ensureVisible(
          heading,
          duration: _animates(heading) ? _scrollDuration : Duration.zero,
          curve: Curves.easeOutCubic,
        );
        return;
      }
      final top = fromElsewhere
          ? WalletsScrollAnchor.find(WalletsAnchor.top)
          : null;
      final position = top == null ? null : Scrollable.maybeOf(top)?.position;
      if (top != null && position != null) {
        // The scroll view's own start, above its padding.
        if (_animates(top)) {
          position.animateTo(
            position.minScrollExtent,
            duration: _scrollDuration,
            curve: Curves.easeOutCubic,
          );
        } else {
          position.jumpTo(position.minScrollExtent);
        }
        return;
      }
      if (framesLeft > 1) {
        _reveal(fromElsewhere: fromElsewhere, framesLeft: framesLeft - 1);
      }
    });
    binding.ensureVisualUpdate();
  }

  static bool _animates(BuildContext context) =>
      !MediaQuery.disableAnimationsOf(context);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ref.watch(networkSettingsProvider.select((s) => s.route));
    // Only Tor and a proxy can be up or down. Not watching the status
    // otherwise also spares Direct a probe.
    final status = route is TorRoute || route is ProxyRoute
        ? ref.watch(routeStatusProvider.select(_statusOf))
        : null;
    final (label, tone) = _describe(route, status);

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tint = _tints[theme.brightness]![tone];
    // Direct is the quiet one: the plain card colours, and the body text
    // colour for its label.
    final textColor = tint == null ? cs.bodyText : cs.onSurface;
    void open() => _open(context);

    return Semantics(
      container: true,
      button: true,
      label: 'Connection: $label. Open network settings',
      excludeSemantics: true,
      onTap: open,
      // Drawn 28 high; the margin around it takes taps too, up to 48 dp.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: open,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Material(
              color: tint?.fill ?? cs.surface,
              shape: StadiumBorder(
                side: BorderSide(color: tint?.edge ?? cs.outline),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: open,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 28),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (tint != null) ...[
                          SizedBox(
                            width: 7,
                            height: 7,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: tint.dot,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              label,
                              maxLines: 1,
                              softWrap: false,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0,
                                color: textColor,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
