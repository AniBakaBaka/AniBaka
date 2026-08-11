import 'package:baka/instance.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

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

class _AppShimmerState extends State<AppShimmer> {
  bool _usesClock = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant AppShimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncClock();
  }

  @override
  void dispose() {
    if (_usesClock) _ShimmerClock.instance.detach();
    super.dispose();
  }

  void _syncClock() {
    final shouldUseClock =
        widget.enabled &&
        !context.reduceMotion &&
        TickerMode.valuesOf(context).enabled;
    if (_usesClock == shouldUseClock) return;
    _usesClock = shouldUseClock;
    if (shouldUseClock) {
      _ShimmerClock.instance.attach();
    } else {
      _ShimmerClock.instance.detach();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_usesClock) return widget.child;

    final theme = Theme.of(context);
    final baseColor = widget.baseColor ?? AppShimmer.defaultBaseColor(theme);
    final highlightColor =
        widget.highlightColor ?? AppShimmer.defaultHighlightColor(theme);

    return ValueListenableBuilder<Duration>(
      valueListenable: _ShimmerClock.instance.elapsed,
      child: widget.child,
      builder: (context, elapsed, child) {
        final durationMicros = widget.duration.inMicroseconds;
        final progress = durationMicros <= 0
            ? 1.0
            : (elapsed.inMicroseconds % durationMicros) / durationMicros;
        return RepaintBoundary(
          child: ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (bounds) => LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [baseColor, highlightColor, baseColor],
              stops: const [0.1, 0.5, 0.9],
              transform: _ShimmerGradientTransform(progress),
            ).createShader(bounds),
            child: child,
          ),
        );
      },
    );
  }
}

/// 所有骨架屏共享一个帧回调，避免列表中每个占位项各自持有 Timer 和 Stopwatch。
class _ShimmerClock {
  _ShimmerClock._();

  static final instance = _ShimmerClock._();

  final ValueNotifier<Duration> elapsed = ValueNotifier(Duration.zero);
  int _users = 0;
  int? _frameCallbackId;
  Duration? _startedAt;

  void attach() {
    _users++;
    if (_users == 1) _scheduleFrame();
  }

  void detach() {
    if (_users == 0) return;
    _users--;
    if (_users != 0) return;

    final callbackId = _frameCallbackId;
    if (callbackId != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callbackId);
    }
    _frameCallbackId = null;
    _startedAt = null;
    elapsed.value = Duration.zero;
  }

  void _scheduleFrame() {
    _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(_tick);
  }

  void _tick(Duration timestamp) {
    _frameCallbackId = null;
    if (_users == 0) return;
    final startedAt = _startedAt ??= timestamp;
    elapsed.value = timestamp - startedAt;
    _scheduleFrame();
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
          colorFilter: ColorFilter.mode(base, BlendMode.srcIn),
          child: child,
        ),
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
