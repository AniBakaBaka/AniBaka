import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/baka_player/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class BottomControl extends StatelessWidget {
  const BottomControl({
    required this.controller,
    required this.triggerFullScreen,
    required this.isWideLayout,
    required this.updatesEnabled,
    this.isFullScreen = false,
    this.danmakuBar,
    this.extraButtons,
    this.episodeTitle,
    super.key,
  });

  final PlaybackController controller;
  final VoidCallback triggerFullScreen;
  final bool isWideLayout;
  final bool updatesEnabled;
  final bool isFullScreen;
  final Widget? danmakuBar;
  final Widget? extraButtons;
  final Widget? episodeTitle;

  /// 按钮交互后让控制栏重新计时，避免连续操作到一半被自动隐藏。
  void _keepControlsAwake() => controller.setControlsVisible(true);

  @override
  Widget build(BuildContext context) {
    final colorTheme = Theme.of(context).colorScheme.primary;
    final isWideScreen = isWideLayout;

    return Padding(
      padding: EdgeInsets.only(
        left: isWideScreen ? 32 : 8,
        right: isWideScreen ? 32 : 8,
        bottom: isWideScreen ? 16 : 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (danmakuBar != null ||
              extraButtons != null ||
              episodeTitle != null)
            Padding(
              padding: EdgeInsets.only(
                bottom: isWideScreen ? 12 : 8,
                left: (isWideScreen ? 16 : 10) - (isWideScreen ? 4 : 2),
                right: isWideScreen ? 16 : 10,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ?episodeTitle,
                  const Spacer(),
                  ?danmakuBar,
                  if (danmakuBar != null && extraButtons != null)
                    const SizedBox(width: 8),
                  ?extraButtons,
                ],
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(isWideScreen ? 16 : 12),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(isWideScreen ? 16 : 12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                  width: 0.5,
                ),
              ),
              padding: EdgeInsets.symmetric(
                horizontal: isWideScreen ? 16 : 10,
                vertical: isWideScreen ? 10 : 6,
              ),
              child: Row(
                children: [
                  _buildPlaybackButton(isWideScreen),
                  SizedBox(width: isWideScreen ? 12 : 8),
                  Expanded(child: _buildTimeline(colorTheme, isWideScreen)),
                  SizedBox(width: isWideScreen ? 12 : 8),
                  if (danmakuBar != null) _buildDanmakuButton(isWideScreen),
                  if (!isFullScreen)
                    _buildIconBtn(
                      Icons.fullscreen_rounded,
                      triggerFullScreen,
                      isWide: isWideScreen,
                      size: 26,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaybackButton(bool isWideScreen) {
    if (!updatesEnabled) {
      return _buildPlayPauseBtn(controller.core.value.playing, isWideScreen);
    }
    return ValueListenableBuilder<PlaybackCoreState>(
      valueListenable: controller.core,
      builder: (context, core, _) =>
          _buildPlayPauseBtn(core.playing, isWideScreen),
    );
  }

  Widget _buildTimeline(Color colorTheme, bool isWideScreen) {
    Widget buildTimeline(PlaybackTimelineState timeline) => _TimelineControl(
      controller: controller,
      timeline: timeline,
      colorTheme: colorTheme,
      isWideScreen: isWideScreen,
    );
    if (!updatesEnabled) return buildTimeline(controller.timeline.value);
    return ValueListenableBuilder<PlaybackTimelineState>(
      valueListenable: controller.timeline,
      builder: (context, timeline, _) => buildTimeline(timeline),
    );
  }

  Widget _buildDanmakuButton(bool isWideScreen) {
    if (!updatesEnabled) {
      return _buildDanmakuToggle(
        controller.overlay.value.showDanmaku,
        isWideScreen,
      );
    }
    return ValueListenableBuilder<PlayerOverlayState>(
      valueListenable: controller.overlay,
      builder: (context, overlay, _) =>
          _buildDanmakuToggle(overlay.showDanmaku, isWideScreen),
    );
  }

  Widget _buildPlayPauseBtn(bool isPlaying, bool isWide) {
    return SizedBox(
      width: isWide ? 42 : 36,
      height: isWide ? 42 : 36,
      child: IconButton(
        style: ButtonStyle(padding: WidgetStateProperty.all(EdgeInsets.zero)),
        tooltip: isPlaying ? '暂停' : '播放',
        onPressed: () {
          HapticFeedback.lightImpact();
          controller.togglePlayback();
          _keepControlsAwake();
        },
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          transitionBuilder: (child, animation) =>
              ScaleTransition(scale: animation, child: child),
          child: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            key: ValueKey(isPlaying),
            color: Colors.white,
            size: isWide ? 28 : 24,
          ),
        ),
      ),
    );
  }

  Widget _buildDanmakuToggle(bool show, bool isWide) {
    return SizedBox(
      width: isWide ? 42 : 36,
      height: isWide ? 42 : 36,
      child: IconButton(
        style: ButtonStyle(padding: WidgetStateProperty.all(EdgeInsets.zero)),
        tooltip: show ? '关闭弹幕' : '开启弹幕',
        onPressed: () {
          HapticFeedback.lightImpact();
          controller.setDanmakuVisible(!show);
          _keepControlsAwake();
        },
        icon: Icon(
          show ? Icons.subtitles_rounded : Icons.subtitles_off_rounded,
          color: show ? Colors.white : Colors.white.withValues(alpha: 0.5),
          size: isWide ? 24 : 20,
        ),
      ),
    );
  }

  Widget _buildIconBtn(
    IconData icon,
    VoidCallback onTap, {
    required bool isWide,
    double size = 22,
  }) {
    return SizedBox(
      width: isWide ? 42 : 36,
      height: isWide ? 42 : 36,
      child: IconButton(
        style: ButtonStyle(padding: WidgetStateProperty.all(EdgeInsets.zero)),
        onPressed: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        icon: Icon(
          icon,
          color: Colors.white,
          size: isWide ? size * 1.25 : size,
        ),
      ),
    );
  }
}

class _TimelineControl extends StatelessWidget {
  const _TimelineControl({
    required this.controller,
    required this.timeline,
    required this.colorTheme,
    required this.isWideScreen,
  });

  final PlaybackController controller;
  final PlaybackTimelineState timeline;
  final Color colorTheme;
  final bool isWideScreen;

  @override
  Widget build(BuildContext context) {
    final total = timeline.duration;
    final progress =
        (timeline.seeking ? timeline.previewPosition : timeline.position).clamp(
          Duration.zero,
          total,
        );
    final buffered = timeline.buffered.clamp(Duration.zero, total);
    final fontSize = isWideScreen ? 14.0 : 12.0;

    return Row(
      children: [
        // 拖动进度时直接在标签上预览目标时间，并用主题色提示。
        Text(
          progress.label(reference: total),
          style: TextStyle(
            color: timeline.seeking ? colorTheme : Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        SizedBox(width: isWideScreen ? 12 : 8),
        Expanded(
          child: total > Duration.zero
              ? ProgressBar(
                  progress: progress,
                  buffered: buffered,
                  total: total,
                  progressBarColor: colorTheme,
                  baseBarColor: Colors.white.withValues(alpha: 0.25),
                  bufferedBarColor: colorTheme.withValues(alpha: 0.4),
                  timeLabelLocation: TimeLabelLocation.none,
                  thumbColor: colorTheme,
                  barHeight: isWideScreen ? 8 : 6,
                  thumbRadius: isWideScreen ? 9 : 7,
                  thumbGlowRadius: isWideScreen ? 20 : 16,
                  onDragStart: (_) => controller.beginSeekPreview(),
                  onDragUpdate: (details) =>
                      controller.updateSeekPreview(details.timeStamp),
                  onSeek: (duration) {
                    controller.endSeekPreview();
                    controller.updateSeekPreview(duration);
                    controller.seek(duration, fromSlider: true);
                  },
                )
              : Container(
                  height: isWideScreen ? 8 : 6,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(isWideScreen ? 4 : 3),
                  ),
                ),
        ),
        SizedBox(width: isWideScreen ? 12 : 8),
        Text(
          total.label(),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
