import 'package:baka/models/playback_state.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/material.dart';

class PlayerPrompts extends StatelessWidget {
  const PlayerPrompts({
    required this.controller,
    required this.isFullScreen,
    required this.hasNextEpisode,
    required this.onNextEpisode,
    super.key,
  });

  final PlaybackController controller;
  final bool isFullScreen;
  final bool hasNextEpisode;
  final VoidCallback? onNextEpisode;

  @override
  Widget build(BuildContext context) {
    if (!isFullScreen) return const SizedBox.shrink();
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        ValueListenableBuilder<PlayerOverlayState>(
          valueListenable: controller.overlay,
          builder: (context, overlay, _) => Stack(
            fit: StackFit.expand,
            children: [
              if (overlay.skipState == SkipState.showingCancel)
                _skipCancelPrompt(controller),
              if (overlay.skipState == SkipState.waiting)
                _waitingPrompt(controller),
              if (overlay.showJumpPrompt)
                _jumpPrompt(controller, overlay.jumpPromptText),
            ],
          ),
        ),
        if (hasNextEpisode)
          ValueListenableBuilder<PlaybackPreferences>(
            valueListenable: controller.preferences,
            builder: (context, preferences, _) {
              if (!preferences.showNextEpisodeButton) {
                return const SizedBox.shrink();
              }
              return ValueListenableBuilder<PlaybackTimelineState>(
                valueListenable: controller.timeline,
                builder: (context, timeline, _) => _isNearEpisodeEnd(timeline)
                    ? _nextEpisodePrompt(timeline)
                    : const SizedBox.shrink(),
              );
            },
          ),
      ],
    );
  }

  bool _isNearEpisodeEnd(PlaybackTimelineState timeline) {
    const waitSeconds = 95;
    final position = timeline.position.inSeconds;
    final duration = timeline.duration.inSeconds;
    return duration > waitSeconds &&
        duration - position <= waitSeconds &&
        position > 0;
  }

  Widget _waitingPrompt(PlaybackController controller) {
    return Positioned(
      top: 64,
      right: 24,
      child: _PlayerPill(
        children: [
          Icon(
            Icons.auto_awesome,
            color: Colors.white.withValues(alpha: 0.9),
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            '可能是片头',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const _PillDivider(),
          _PillAction(
            icon: Icons.fast_forward_rounded,
            label: '跳过',
            onTap: controller.userActionSkip,
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () {
              controller.userActionCancelSkip();
              showSnackBar('已取消自动跳过');
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close_rounded,
                color: Colors.white.withValues(alpha: 0.7),
                size: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _skipCancelPrompt(PlaybackController controller) {
    return Positioned(
      top: 80,
      right: 24,
      child: _PlayerPill(
        children: [
          Icon(
            Icons.fast_forward_rounded,
            color: Colors.white.withValues(alpha: 0.9),
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            '已自动跳过片头',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const _PillDivider(),
          _PillAction(
            icon: Icons.replay_rounded,
            label: '撤销',
            onTap: () {
              controller.cancelSkipOpEd();
              showSnackBar('已返回跳过前位置');
            },
          ),
        ],
      ),
    );
  }

  Widget _jumpPrompt(PlaybackController controller, String text) {
    return Positioned(
      top: 120,
      right: 24,
      child: _PlayerPill(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.history,
                    color: Colors.blueAccent.shade100,
                    size: 12,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '上次播放位置',
                    style: TextStyle(
                      color: Colors.blueAccent.shade100,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              Text(
                text,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(width: 16),
          _JumpActionButton(
            label: '继续',
            icon: Icons.play_arrow_rounded,
            onTap: controller.performJumpToPosition,
            color: Colors.blueAccent,
          ),
          const SizedBox(width: 8),
          _JumpActionButton(
            icon: Icons.close_rounded,
            onTap: controller.hideJumpPrompt,
            color: Colors.white,
            isClose: true,
          ),
        ],
      ),
    );
  }

  Widget _nextEpisodePrompt(PlaybackTimelineState timeline) {
    const waitSeconds = 95;
    final remaining = timeline.duration.inSeconds - timeline.position.inSeconds;
    return Positioned(
      bottom: 100,
      right: 24,
      child: InkWell(
        onTap: onNextEpisode,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.1),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: (waitSeconds - remaining) / waitSeconds,
                      backgroundColor: Colors.white.withValues(alpha: 0.2),
                      color: Colors.blueAccent,
                      strokeWidth: 2,
                    ),
                    Text(
                      '$remaining',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                '下一集',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.skip_next_rounded,
                color: Colors.white.withValues(alpha: 0.9),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JumpActionButton extends StatelessWidget {
  const _JumpActionButton({
    required this.icon,
    required this.onTap,
    required this.color,
    this.label,
    this.isClose = false,
  });

  final String? label;
  final IconData icon;
  final VoidCallback onTap;
  final Color color;
  final bool isClose;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isClose
              ? Colors.white.withValues(alpha: 0.1)
              : color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isClose
                ? Colors.white.withValues(alpha: 0.2)
                : color.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        child: label != null
            ? Row(
                children: [
                  Icon(icon, color: color, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    label!,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
              )
            : Icon(icon, color: Colors.white70, size: 14),
      ),
    );
  }
}

class _PlayerPill extends StatelessWidget {
  const _PlayerPill({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.1),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _PillDivider extends StatelessWidget {
  const _PillDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 12,
      width: 1,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: Colors.white.withValues(alpha: 0.2),
    );
  }
}

class _PillAction extends StatelessWidget {
  const _PillAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.blueAccent.shade100, size: 14),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: Colors.blueAccent.shade100,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
