import 'dart:async';

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
    final mediaQuery = MediaQuery.maybeOf(context);
    final animationsDisabled = mediaQuery?.disableAnimations ?? false;
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    final shouldAnimate =
        widget.enabled &&
        !animationsDisabled &&
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

    // RepaintBoundary 将 ShaderMask 的逐帧重绘隔离在内部，
    // 避免连带父级（如列表项、骨架网格）一起重绘。
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

class ShimmerBox extends StatelessWidget {
  final double? width;
  final double? height;
  final BorderRadiusGeometry borderRadius;
  final EdgeInsetsGeometry? margin;
  final Color? baseColor;
  final Color? highlightColor;

  const ShimmerBox({
    this.width,
    this.height,
    this.borderRadius = BorderRadius.zero,
    this.margin,
    this.baseColor,
    this.highlightColor,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedBaseColor =
        baseColor ?? AppShimmer.defaultBaseColor(Theme.of(context));
    final fillColor = highlightColor == null
        ? resolvedBaseColor
        : Color.lerp(resolvedBaseColor, highlightColor, 0.2)!;
    final child = SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(color: fillColor, borderRadius: borderRadius),
      ),
    );

    if (margin == null) return child;
    return Padding(padding: margin!, child: child);
  }
}

class ShimmerCircle extends StatelessWidget {
  final double size;
  final EdgeInsetsGeometry? margin;
  final Color? baseColor;
  final Color? highlightColor;

  const ShimmerCircle({
    this.size = 40,
    this.margin,
    this.baseColor,
    this.highlightColor,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ShimmerBox(
      width: size,
      height: size,
      borderRadius: BorderRadius.circular(size / 2),
      margin: margin,
      baseColor: baseColor,
      highlightColor: highlightColor,
    );
  }
}

class ShimmerTextLine extends StatelessWidget {
  final double? width;
  final double height;
  final double widthFactor;
  final EdgeInsetsGeometry? margin;
  final Color? baseColor;
  final Color? highlightColor;

  const ShimmerTextLine({
    this.width,
    this.height = 12,
    this.widthFactor = 1,
    this.margin,
    this.baseColor,
    this.highlightColor,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final line = ShimmerBox(
      width: width,
      height: height,
      borderRadius: BorderRadius.circular(height / 2),
      baseColor: baseColor,
      highlightColor: highlightColor,
    );

    final Widget child = width == null && widthFactor < 1
        ? FractionallySizedBox(widthFactor: widthFactor, child: line)
        : line;

    if (margin == null) return child;
    return Padding(padding: margin!, child: child);
  }
}

class ShimmerListTile extends StatelessWidget {
  final bool leading;
  final bool subtitle;
  final EdgeInsetsGeometry padding;

  const ShimmerListTile({
    this.leading = true,
    this.subtitle = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leading) ...[
            const ShimmerCircle(size: 36),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ShimmerTextLine(height: 14),
                if (subtitle) ...[
                  const SizedBox(height: 8),
                  const ShimmerTextLine(height: 12, widthFactor: 0.68),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ShimmerCoverCard extends StatelessWidget {
  final double? width;
  final double aspectRatio;
  final BorderRadiusGeometry borderRadius;
  final bool showSubtitle;

  const ShimmerCoverCard({
    this.width,
    this.aspectRatio = 2 / 3,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.showSubtitle = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final titleWidth = width == null ? double.infinity : width! * 0.82;
    final subtitleWidth = width == null ? double.infinity : width! * 0.58;

    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: aspectRatio,
            child: ShimmerBox(borderRadius: borderRadius),
          ),
          const SizedBox(height: 10),
          ShimmerBox(
            width: titleWidth,
            height: 14,
            borderRadius: BorderRadius.circular(7),
          ),
          if (showSubtitle) ...[
            const SizedBox(height: 8),
            ShimmerBox(
              width: subtitleWidth,
              height: 12,
              borderRadius: BorderRadius.circular(6),
            ),
          ],
        ],
      ),
    );
  }
}

class _ShimmerGradientTransform extends GradientTransform {
  final double percent;

  const _ShimmerGradientTransform(this.percent);

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * (percent * 2 - 1), 0, 0);
  }
}
