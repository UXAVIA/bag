import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

// Matches Figma ease: [0.34, 1.56, 0.64, 1] — spring/bounce overshoot
const _bounceCurve = Cubic(0.34, 1.56, 0.64, 1.0);

class SplashScreen extends StatefulWidget {
  final bool onboardingComplete;

  const SplashScreen({super.key, required this.onboardingComplete});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // Combined entrance for the whole icon: 800ms
  late final AnimationController _enterController;
  // White block slides in from right: 500ms, starts after entrance
  late final AnimationController _whiteController;
  // Full-screen fade-out: 600ms
  late final AnimationController _exitController;

  // Entrance (B + orange blocks)
  late final Animation<double> _scale;
  late final Animation<double> _opacity;
  late final Animation<double> _translateY;
  late final Animation<double> _rotate;

  // White block
  late final Animation<double> _whiteSlideX;
  late final Animation<double> _whiteOpacity;

  @override
  void initState() {
    super.initState();

    _enterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _whiteController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    // scale: 0.5 → 1.1 → 1.0  (times [0, 0.6, 1])
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.5, end: 1.1)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.1, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 40,
      ),
    ]).animate(_enterController);

    // opacity: 0 → 1 → 1
    _opacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 60,
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 40),
    ]).animate(_enterController);

    // translateY: 50 → -10 → 0 px
    _translateY = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 50.0, end: -10.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween(begin: -10.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 40,
      ),
    ]).animate(_enterController);

    // rotate: -20° → 5° → 0°
    _rotate = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: -20.0 * math.pi / 180.0,
          end: 5.0 * math.pi / 180.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: 5.0 * math.pi / 180.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 40,
      ),
    ]).animate(_enterController);

    // White block: +50px → 0 with bounce, opacity 0 → 1
    _whiteSlideX = Tween(begin: 50.0, end: 0.0)
        .chain(CurveTween(curve: _bounceCurve))
        .animate(_whiteController);
    _whiteOpacity = Tween(begin: 0.0, end: 1.0)
        .chain(CurveTween(curve: Curves.easeOut))
        .animate(_whiteController);

    _enterController.forward().then((_) {
      // Kick off white block slide and 2500ms hold simultaneously
      _whiteController.forward();
      Future.delayed(const Duration(milliseconds: 2500), _exit);
    });
  }

  void _exit() {
    if (!mounted) return;
    _exitController.forward().then((_) {
      if (!mounted) return;
      context.go(widget.onboardingComplete ? '/' : '/onboarding');
    });
  }

  @override
  void dispose() {
    _enterController.dispose();
    _whiteController.dispose();
    _exitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const iconSize = 240.0;

    return AnimatedBuilder(
      animation: _exitController,
      builder: (context, child) => Opacity(
        opacity: 1.0 - _exitController.value,
        child: child,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Center(
              child: AnimatedBuilder(
                animation: _enterController,
                builder: (context, child) {
                  return Transform.translate(
                    offset: Offset(0, _translateY.value),
                    child: Transform.rotate(
                      angle: _rotate.value,
                      child: Transform.scale(
                        scale: _scale.value,
                        child: Opacity(
                          opacity: _opacity.value.clamp(0.0, 1.0),
                          child: child,
                        ),
                      ),
                    ),
                  );
                },
                child: SizedBox(
                  width: iconSize,
                  height: iconSize,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // B + two orange blocks — animated by outer controller
                      SvgPicture.asset(
                        'assets/images/splash_icon_base.svg',
                        width: iconSize,
                        height: iconSize,
                      ),
                      // White block — slides in from right after entrance
                      AnimatedBuilder(
                        animation: _whiteController,
                        builder: (context, child) {
                          return Transform.translate(
                            offset: Offset(_whiteSlideX.value, 0),
                            child: Opacity(
                              opacity: _whiteOpacity.value.clamp(0.0, 1.0),
                              child: child,
                            ),
                          );
                        },
                        child: SvgPicture.asset(
                          'assets/images/splash_icon_white.svg',
                          width: iconSize,
                          height: iconSize,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Positioned(
              bottom: 80,
              left: 0,
              right: 0,
              child: _PulsingDots(),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulsingDots extends StatefulWidget {
  const _PulsingDots();

  @override
  State<_PulsingDots> createState() => _PulsingDotsState();
}

class _PulsingDotsState extends State<_PulsingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _Dot(controller: _controller, delay: 0.0),
        const SizedBox(width: 6),
        _Dot(controller: _controller, delay: 0.2),
        const SizedBox(width: 6),
        _Dot(controller: _controller, delay: 0.4),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  final AnimationController controller;
  final double delay;

  const _Dot({required this.controller, required this.delay});

  @override
  Widget build(BuildContext context) {
    final end = (delay + 0.6).clamp(0.0, 1.0);
    final curve = CurvedAnimation(
      parent: controller,
      curve: Interval(delay, end, curve: Curves.easeInOut),
    );
    final scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.5), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.5, end: 1.0), weight: 50),
    ]).animate(curve);
    final opacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.5, end: 1.0), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.5), weight: 50),
    ]).animate(curve);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Transform.scale(
          scale: scale.value,
          child: Opacity(
            opacity: opacity.value,
            child: Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Color(0xFFF7931A),
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      },
    );
  }
}
