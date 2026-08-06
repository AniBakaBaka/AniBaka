import 'dart:async';

import 'package:baka/instance.dart';
import 'package:flutter/material.dart';

class AppShimmer extends StatefulWidget {
  final Widget child;
  final Color? baseColor;
  final Color? highlightColor;
  final Duration duration;
  final bool enabled;

  const AppShimmer({
    required this.child,
    this.baseColor,
    this.highlightColor,
    this.duration = const Duration(milliseconds: 1400),
    this.enabled = true,
    super.key,
  });

  static Color defaultBaseColor(ThemeData theme) {
    return theme.brightness == Brightness.dark
        ? const Color(0xFF24262B)
        : const Color(0xFFE7EAF0);
  }

  static Color defaultHighlightColor(ThemeData theme) {
    return theme.brightness == Brightness.dark
        ? const Color(0xFF343741)
        : const Color(0xFFF8FAFC);
  }

  @override
  State<AppShimmer> createState() => _AppShimmerState();
}

class _AppShimmerState extends State<AppShimmer> with WidgetsBindingObserver {
  static const _frameInterval = Duration(milliseconds: 33);

  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  double _progress = 0;
  bool _isAnimating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant AppShimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncAnimation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  void _syncAnimation() {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    final shouldAnimate =
        widget.enabled &&
        !context.reduceMotion &&
        TickerMode.of(context) &&
        (lifecycleState == null || lifecycleState == AppLifecycleState.resumed);

    if (_isAnimating == shouldAnimate) return;
    _isAnimating = shouldAnimate;
    _timer?.cancel();
    _timer = null;

    if (!shouldAnimate) {
      _clock.stop();
      return;
    }

    _clock.start();
    _timer = Timer.periodic(_frameInterval, (_) {
      if (!mounted) return;
      final durationMicros = widget.duration.inMicroseconds;
      final progress = durationMicros <= 0
          ? 1.0
          : (_clock.elapsedMicroseconds % durationMicros) / durationMicros;
      setState(() => _progress = progress);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAnimating) {
      return widget.child;
    }

    final theme = Theme.of(context);
    final baseColor = widget.baseColor ?? AppShimmer.defaultBaseColor(theme);
    final highlightColor =
        widget.highlightColor ?? AppShimmer.defaultHighlightColor(theme);

    return RepaintBoundary(
      child: ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (bounds) {
          return LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [baseColor, highlightColor, baseColor],
            stops: const [0.1, 0.5, 0.9],
            transform: _ShimmerGradientTransform(_progress),
          ).createShader(bounds);
        },
        child: widget.child,
      ),
    );
  }
}

class AppSkeletonizer extends StatelessWidget {
  final Widget child;
  final bool enabled;
  final Color? baseColor;
  final Color? highlightColor;

  const AppSkeletonizer({
    required this.child,
    this.enabled = true,
    this.baseColor,
    this.highlightColor,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;

    final theme = Theme.of(context);
    final base = baseColor ?? AppShimmer.defaultBaseColor(theme);

    return IgnorePointer(
      child: AppShimmer(
        baseColor: base,
        highlightColor: highlightColor,
        child: ColorFiltered(
          colorFilter: ColorFilter.mode(
            base,
            BlendMode.srcIn,
          ),
          child: child,
        ),
      ),
    );
  }
}

typedef Skeletonizer = AppSkeletonizer;

class _ShimmerGradientTransform extends GradientTransform {
  final double percent;

  const _ShimmerGradientTransform(this.percent);

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * (percent * 2 - 1), 0, 0);
  }
}
