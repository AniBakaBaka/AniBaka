import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/baka_player/utils.dart';
import 'package:flutter/material.dart';

class BottomControl extends StatelessWidget {
  const BottomControl({
    required this.controller,
    required this.triggerFullScreen,
    required this.isWideLayout,
    this.isFullScreen = false,
    this.danmakuBar,
    this.extraButtons,
    this.episodeTitle,
    super.key,
  });

  final PlaybackController controller;
  final VoidCallback triggerFullScreen;
  final bool isWideLayout;
  final bool isFullScreen;
  final Widget? danmakuBar;
  final Widget? extraButtons;
  final Widget? episodeTitle;

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
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: double.infinity),
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
                  left: 4,
                  right: 4,
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
            ClipRRect(
              borderRadius: BorderRadius.circular(isWideScreen ? 14 : 8),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(isWideScreen ? 14 : 8),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.05),
                    width: 0.5,
                  ),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: isWideScreen ? 16 : 8,
                  vertical: isWideScreen ? 12 : 8,
                ),
                child: Row(
                  children: [
                    ValueListenableBuilder<PlaybackCoreState>(
                      valueListenable: controller.core,
                      builder: (context, core, _) =>
                          _buildPlayPauseBtn(core.playing, isWideScreen),
                    ),
                    SizedBox(width: isWideScreen ? 12 : 8),
                    Expanded(
                      child: ValueListenableBuilder<PlaybackTimelineState>(
                        valueListenable: controller.timeline,
                        builder: (context, timeline, _) => _TimelineControl(
                          controller: controller,
                          timeline: timeline,
                          colorTheme: colorTheme,
                          isWideScreen: isWideScreen,
                        ),
                      ),
                    ),
                    SizedBox(width: isWideScreen ? 12 : 8),
                    if (danmakuBar != null)
                      ValueListenableBuilder<PlayerOverlayState>(
                        valueListenable: controller.overlay,
                        builder: (context, overlay, _) => _buildDanmakuToggle(
                          overlay.showDanmaku,
                          isWideScreen,
                        ),
                      ),
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
      ),
    );
  }

  Widget _buildPlayPauseBtn(bool isPlaying, bool isWide) {
    return SizedBox(
      width: isWide ? 40 : 32,
      height: isWide ? 40 : 32,
      child: IconButton(
        style: ButtonStyle(padding: WidgetStateProperty.all(EdgeInsets.zero)),
        onPressed: controller.togglePlayback,
        icon: Icon(
          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: Colors.white,
          size: isWide ? 28 : 22,
        ),
      ),
    );
  }

  Widget _buildDanmakuToggle(bool show, bool isWide) {
    return SizedBox(
      width: isWide ? 40 : 32,
      height: isWide ? 40 : 32,
      child: IconButton(
        style: ButtonStyle(padding: WidgetStateProperty.all(EdgeInsets.zero)),
        onPressed: () => controller.setDanmakuVisible(!show),
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
      width: isWide ? 40 : 32,
      height: isWide ? 40 : 32,
      child: IconButton(
        style: ButtonStyle(padding: WidgetStateProperty.all(EdgeInsets.zero)),
        onPressed: onTap,
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
    final progress = (timeline.seeking
            ? timeline.previewPosition
            : timeline.position)
        .clamp(Duration.zero, total);
    final buffered = timeline.buffered.clamp(Duration.zero, total);

    return Row(
      children: [
        Text(
          timeline.position.label(reference: timeline.duration),
          style: TextStyle(
            color: Colors.white,
            fontSize: isWideScreen ? 15 : 12,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: isWideScreen ? 6 : 4),
          child: Text(
            '·',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: isWideScreen ? 15 : 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Text(
          timeline.duration.label(),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: isWideScreen ? 15 : 12,
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
                  baseBarColor: Colors.white.withValues(alpha: 0.2),
                  bufferedBarColor: colorTheme.withValues(alpha: 0.4),
                  timeLabelLocation: TimeLabelLocation.none,
                  thumbColor: colorTheme,
                  barHeight: isWideScreen ? 8 : 6,
                  thumbRadius: isWideScreen ? 9 : 7,
                  thumbGlowRadius: isWideScreen ? 24 : 18,
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
      ],
    );
  }
}
