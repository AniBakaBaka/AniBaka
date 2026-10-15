import 'package:baka/models/playback_state.dart';
import 'package:baka/widgets/common/value_selector.dart';
import '../controller.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:flutter/material.dart';

const _indicatorAnimationDuration = Duration(milliseconds: 200);
const _toastIndicatorWidth = 112.0;
const _toastIndicatorGap = 8.0;

const _whiteTextStyle = TextStyle(
  color: Colors.white,
  fontSize: 13,
  fontWeight: FontWeight.w500,
  letterSpacing: 0.5,
);

class PlayerLoadingIndicator extends StatelessWidget {
  final PlaybackController controller;

  const PlayerLoadingIndicator({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    return ValueSelector<PlaybackCoreState, bool>(
      valueListenable: controller.core,
      select: (state) => (state.loading || state.buffering) && !state.failed,
      builder: (context, loading) {
        if (loading) {
          return const Center(
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(color: Colors.white),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}

class PlayerToastIndicators extends StatelessWidget {
  final PlaybackController controller;

  const PlayerToastIndicators({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    return ValueSelector<PlayerOverlayState, double?>(
      valueListenable: controller.overlay,
      select: (state) => state.doubleSpeed ? state.longPressRate : null,
      builder: (context, rate) =>
          ValueSelector<PlaybackTimelineState, (Duration, Duration)?>(
            valueListenable: controller.timeline,
            select: (state) =>
                state.seeking ? (state.previewPosition, state.duration) : null,
            builder: (context, preview) {
              final longPressRate = rate ?? 0;
              final showSpeed = rate != null;
              final showProgress = preview != null;
              final showBoth = showSpeed && showProgress;

              return IgnorePointer(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: FractionalTranslation(
                    translation: const Offset(0, 0.3),
                    child: SizedBox(
                      width: _toastIndicatorWidth * 2 + _toastIndicatorGap,
                      height: 36,
                      child: Stack(
                        children: [
                          _AnimatedIndicator(
                            condition: showSpeed,
                            alignment: Alignment(showBoth ? -1 : 0, 0),
                            child: _PlayerToastIndicator(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    longPressRate < 0
                                        ? Icons.fast_rewind_rounded
                                        : longPressRate == 0
                                        ? Icons.pause_rounded
                                        : Icons.fast_forward_rounded,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _formatLongPressRate(longPressRate),
                                    style: _whiteTextStyle.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          _AnimatedIndicator(
                            condition: showProgress,
                            alignment: Alignment(showBoth ? 1 : 0, 0),
                            child: _PlayerToastIndicator(
                              child: preview == null
                                  ? const SizedBox.shrink()
                                  : _TimeProgressLabel(
                                      position: preview.$1,
                                      total: preview.$2,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
    );
  }
}

String _formatLongPressRate(double rate) {
  final abs = rate.abs();
  final value = abs % 1 == 0 ? abs.toInt().toString() : abs.toStringAsFixed(1);
  if (rate < 0) return '快退 ${value}x';
  if (rate == 0) return '暂停 0x';
  return '快进 ${value}x';
}

class PlayerVolumeBrightnessIndicators extends StatelessWidget {
  final PlaybackController controller;
  final bool volumeVisible;
  final bool brightnessVisible;

  const PlayerVolumeBrightnessIndicators({
    required this.controller,
    required this.volumeVisible,
    required this.brightnessVisible,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ValueSelector<PlayerOverlayState, (double?, double?)>(
      valueListenable: controller.overlay,
      select: (state) => (
        volumeVisible ? state.volume : null,
        brightnessVisible ? state.brightness : null,
      ),
      builder: (context, _) => Stack(
        children: [
          _VerticalIndicator(
            alignment: Alignment.centerRight,
            margin: const EdgeInsets.only(right: 24),
            value: controller.overlay.value.volume,
            visible: volumeVisible,
            icon: Icons.volume_up_rounded,
          ),
          _VerticalIndicator(
            alignment: Alignment.centerLeft,
            margin: const EdgeInsets.only(left: 24),
            value: controller.overlay.value.brightness,
            visible: brightnessVisible,
            icon: Icons.brightness_6_rounded,
          ),
        ],
      ),
    );
  }
}

class PlayerErrorIndicator extends StatelessWidget {
  final PlaybackController controller;
  final bool canSearchSource;
  final VoidCallback onSearch;
  final bool show;
  final VoidCallback? onAiRepair;

  const PlayerErrorIndicator({
    required this.controller,
    required this.canSearchSource,
    required this.onSearch,
    this.show = true,
    this.onAiRepair,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlaybackCoreState>(
      valueListenable: controller.core,
      builder: (context, core, _) {
        if (!core.failed || !show) {
          return const SizedBox.shrink();
        }

        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                onAiRepair == null ? '播放失败，请换源或到 BAKA 报错' : '播放失败，请换源或使用 AI 修复',
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  if (canSearchSource &&
                      controller.mediaInfo.value.title.isNotEmpty)
                    _errorAction(
                      icon: Icons.search_rounded,
                      label: '搜索番剧源',
                      onTap: onSearch,
                    ),
                  if (onAiRepair != null)
                    _errorAction(
                      icon: Icons.auto_awesome_rounded,
                      label: 'AI 修复当前源',
                      onTap: onAiRepair!,
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _errorAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlayerSeekIndicator extends StatelessWidget {
  const PlayerSeekIndicator({required this.seconds, super.key});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    if (seconds == 0) return const SizedBox.shrink();
    final isBackward = seconds < 0;
    return Positioned.fill(
      child: IgnorePointer(
        child: Row(
          children: [
            if (isBackward)
              Expanded(
                child: Center(
                  child: _SeekFeedback(
                    seconds: seconds.abs(),
                    isBackward: true,
                  ),
                ),
              ),
            const Spacer(),
            if (!isBackward)
              Expanded(
                child: Center(
                  child: _SeekFeedback(
                    seconds: seconds.abs(),
                    isBackward: false,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SeekFeedback extends StatelessWidget {
  const _SeekFeedback({required this.seconds, required this.isBackward});

  final int seconds;
  final bool isBackward;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: _indicatorDecoration,
      height: 36.0,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isBackward ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
            color: Colors.white,
            size: 16,
          ),
          const SizedBox(width: 4),
          Text(
            '${isBackward ? '快退' : '快进'} $seconds 秒',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimatedIndicator extends StatelessWidget {
  final bool condition;
  final Alignment alignment;
  final Widget child;

  const _AnimatedIndicator({
    required this.condition,
    required this.alignment,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedAlign(
      alignment: alignment,
      curve: Curves.easeOutCubic,
      duration: _indicatorAnimationDuration,
      child: AnimatedOpacity(
        curve: Curves.easeInOut,
        opacity: condition ? 1.0 : 0.0,
        duration: _indicatorAnimationDuration,
        child: child,
      ),
    );
  }
}

class _PlayerToastIndicator extends StatelessWidget {
  final Widget child;

  const _PlayerToastIndicator({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: _indicatorDecoration,
      height: 36,
      width: _toastIndicatorWidth,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      child: FittedBox(fit: BoxFit.scaleDown, child: child),
    );
  }
}

class _TimeProgressLabel extends StatelessWidget {
  final Duration position;
  final Duration total;

  const _TimeProgressLabel({required this.position, required this.total});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          position.toTimeString(reference: total, includeDays: true),
          style: _whiteTextStyle.copyWith(fontWeight: FontWeight.bold),
        ),
        Text(' / ', style: _whiteTextStyle.copyWith(color: Colors.white54)),
        Text(
          total.toTimeString(includeDays: true),
          style: _whiteTextStyle.copyWith(color: Colors.white70),
        ),
      ],
    );
  }
}

class _VerticalIndicator extends StatelessWidget {
  final Alignment alignment;
  final EdgeInsets margin;
  final double value;
  final bool visible;
  final IconData icon;

  const _VerticalIndicator({
    required this.alignment,
    required this.margin,
    required this.value,
    required this.visible,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: AnimatedOpacity(
        curve: Curves.easeOutCubic,
        opacity: visible ? 1.0 : 0.0,
        duration: _indicatorAnimationDuration,
        child: Container(
          margin: margin,
          width: 28,
          height: 170,
          child: Column(
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(height: 10),
              Expanded(
                child: Container(
                  width: 6,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      widthFactor: 1,
                      heightFactor: value.clamp(0.0, 1.0).toDouble(),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
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
}

final _indicatorDecoration = BoxDecoration(
  color: Colors.black.withValues(alpha: 0.7),
  borderRadius: BorderRadius.circular(32),
  border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 0.5),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.15),
      blurRadius: 4,
      offset: const Offset(0, 2),
    ),
  ],
);
