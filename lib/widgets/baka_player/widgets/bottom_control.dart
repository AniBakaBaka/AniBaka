import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/widgets/player/skip_segment_track.dart';
import 'package:baka/widgets/common/value_selector.dart';
import '../controller.dart';
import 'package:baka/utils/format_utils.dart';
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

  @override
  Widget build(BuildContext context) {
    final colorTheme = Theme.of(context).colorScheme.primary;
    final isWide = isWideLayout;
    final paddingH = isWide ? 32.0 : 8.0;

    return Padding(
      padding: EdgeInsets.only(
        left: paddingH,
        right: paddingH,
        bottom: isWide ? 16 : 8,
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
                bottom: isWide ? 12 : 8,
                left: isWide ? 12 : 8,
                right: isWide ? 16 : 10,
              ),
              child: Row(
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
          Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(isWide ? 16 : 12),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
                width: 0.5,
              ),
            ),
            padding: EdgeInsets.symmetric(
              horizontal: isWide ? 16 : 10,
              vertical: isWide ? 10 : 6,
            ),
            child: Row(
              children: [
                _buildPlaybackButton(isWide),
                SizedBox(width: isWide ? 12 : 8),
                Expanded(child: _buildTimeline(colorTheme, isWide)),
                SizedBox(width: isWide ? 12 : 8),
                if (danmakuBar != null) _buildDanmakuButton(isWide),
                if (!isFullScreen)
                  _PlayerIconButton(
                    icon: Icons.fullscreen_rounded,
                    tooltip: '全屏',
                    isWide: isWide,
                    size: 26,
                    onTap: triggerFullScreen,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaybackButton(bool isWide) {
    Widget buildBtn(bool playing) => _PlayerIconButton(
      icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
      tooltip: playing ? '暂停' : '播放',
      isWide: isWide,
      size: isWide ? 28 : 24,
      onTap: () {
        controller.togglePlayback();
        controller.setControlsVisible(true);
      },
    );

    if (!updatesEnabled) {
      return buildBtn(controller.core.value.playing);
    }
    return ValueSelector<PlaybackCoreState, bool>(
      valueListenable: controller.core,
      select: (state) => state.playing,
      builder: (context, playing) => buildBtn(playing),
    );
  }

  Widget _buildTimeline(Color colorTheme, bool isWide) {
    Widget buildTimeline(PlaybackTimelineState state) =>
        _buildTimelineRow(state, colorTheme, isWide);

    if (!updatesEnabled) return buildTimeline(controller.timeline.value);
    return ValueListenableBuilder<PlaybackTimelineState>(
      valueListenable: controller.timeline,
      builder: (context, timeline, _) => buildTimeline(timeline),
    );
  }

  Widget _buildDanmakuButton(bool isWide) {
    Widget buildBtn(bool show) => _PlayerIconButton(
      icon: show ? Icons.subtitles_rounded : Icons.subtitles_off_rounded,
      tooltip: show ? '关闭弹幕' : '开启弹幕',
      isWide: isWide,
      color: show ? Colors.white : Colors.white.withValues(alpha: 0.5),
      size: isWide ? 24 : 20,
      onTap: () {
        controller.setDanmakuVisible(!show);
        controller.setControlsVisible(true);
      },
    );

    if (!updatesEnabled) {
      return buildBtn(controller.overlay.value.showDanmaku);
    }
    return ValueSelector<PlayerOverlayState, bool>(
      valueListenable: controller.overlay,
      select: (state) => state.showDanmaku,
      builder: (context, show) => buildBtn(show),
    );
  }

  Widget _buildTimelineRow(
    PlaybackTimelineState timeline,
    Color colorTheme,
    bool isWideScreen,
  ) {
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
        Text(
          progress.toTimeString(reference: total, includeDays: true),
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
              ? SkipSegmentTrack(
                  data: controller.skipData,
                  duration: total,
                  position: progress,
                  barHeight: isWideScreen ? 8 : 6,
                  thumbRadius: isWideScreen ? 9 : 7,
                  trackInset: isWideScreen ? 4 : 3,
                  child: ProgressBar(
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
                      controller.seek(duration);
                    },
                  ),
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
          total.toTimeString(includeDays: true),
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

class _PlayerIconButton extends StatelessWidget {
  const _PlayerIconButton({
    required this.icon,
    required this.onTap,
    required this.isWide,
    this.tooltip,
    this.color = Colors.white,
    this.size = 22,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool isWide;
  final String? tooltip;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final buttonSize = isWide ? 42.0 : 36.0;
    return SizedBox(
      width: buttonSize,
      height: buttonSize,
      child: Material(
        type: MaterialType.transparency,
        child: InkResponse(
          radius: buttonSize / 2,
          onTap: () {
            HapticFeedback.lightImpact();
            onTap();
          },
          child: Center(
            child: Icon(icon, color: color, size: isWide ? size * 1.15 : size),
          ),
        ),
      ),
    );
  }
}
