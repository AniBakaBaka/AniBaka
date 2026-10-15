import 'dart:async';

import 'package:baka/models/playback_state.dart';
import 'package:baka/widgets/common/value_selector.dart';
import 'package:flutter/material.dart';

import '../controller.dart';

/// Skip actions and episode-two opt-in share one anchored surface.
class PlayerPrompts extends StatelessWidget {
  const PlayerPrompts({
    required this.controller,
    required this.hasNextEpisode,
    required this.onNextEpisode,
    this.isWideLayout = false,
    this.isTvLayout = false,
    super.key,
  });

  final PlaybackController controller;
  final bool hasNextEpisode;
  final VoidCallback? onNextEpisode;
  final bool isWideLayout;
  final bool isTvLayout;

  @override
  Widget build(BuildContext context) {
    // Settings and other modal routes have priority over playback notices.
    if (ModalRoute.isCurrentOf(context) == false) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 8, isWideLayout ? 32 : 16, 4),
          child: Align(
            alignment: Alignment.topRight,
            child:
                ValueSelector<
                  PlayerOverlayState,
                  (SkipState, String, bool, bool, bool)
                >(
                  valueListenable: controller.overlay,
                  select: (state) => (
                    state.skipState,
                    state.skipLabel,
                    state.skipWasAutomatic,
                    state.showSkipSuggestion,
                    state.controlsLocked || state.showDanmakuInput,
                  ),
                  builder: (context, state) {
                    if (state.$5 || !controller.canControlPlayback) {
                      return const SizedBox.shrink();
                    }
                    if (state.$4) {
                      return _PlayerNotice(
                        key: const ValueKey('skip-suggestion'),
                        isWideLayout: isWideLayout,
                        isTvLayout: isTvLayout,
                        icon: Icons.fast_forward_rounded,
                        text: '自动跳过片头片尾？',
                        compact: true,
                        onClose: () =>
                            unawaited(controller.answerSkipSuggestion(false)),
                        actions: [
                          _NoticeAction(
                            '暂不',
                            () => unawaited(
                              controller.answerSkipSuggestion(false),
                            ),
                          ),
                          _NoticeAction(
                            '开启',
                            () => unawaited(
                              controller.answerSkipSuggestion(true),
                            ),
                            filled: true,
                          ),
                        ],
                      );
                    }
                    if (state.$1 == SkipState.idle) {
                      return const SizedBox.shrink();
                    }
                    final waiting = state.$1 == SkipState.waiting;
                    final canUndo = state.$1 == SkipState.showingCancel;
                    return ValueSelector<PlaybackPreferences, bool>(
                      valueListenable: controller.preferences,
                      select: (preferences) =>
                          preferences.showNextEpisodeButton,
                      builder: (context, showNext) {
                        final next =
                            state.$2 == '片尾' &&
                            showNext &&
                            hasNextEpisode &&
                            onNextEpisode != null;
                        if (state.$1 == SkipState.ending && !next) {
                          return const SizedBox.shrink();
                        }
                        return _PlayerNotice(
                          key: const ValueKey('skip-notice'),
                          isWideLayout: isWideLayout,
                          isTvLayout: isTvLayout,
                          icon: Icons.skip_next_rounded,
                          text: waiting
                              ? '${state.$2}播放中'
                              : '${state.$3 ? '已自动跳过' : '已跳过'}${state.$2}',
                          onClose: controller.userActionCancelSkip,
                          actions: [
                            if (waiting)
                              _NoticeAction('跳过', controller.userActionSkip),
                            if (canUndo)
                              _NoticeAction('撤销', controller.cancelSkipOpEd),
                            if (next)
                              _NoticeAction(
                                '下一集',
                                () {
                                  controller.userActionCancelSkip();
                                  onNextEpisode!();
                                },
                                leading: _EndingCountdown(
                                  controller: controller,
                                ),
                              ),
                          ],
                        );
                      },
                    );
                  },
                ),
          ),
        ),
      ),
    );
  }
}

class _NoticeAction {
  const _NoticeAction(
    this.label,
    this.onPressed, {
    this.filled = false,
    this.leading,
  });
  final String label;
  final VoidCallback onPressed;
  final bool filled;
  final Widget? leading;
}

class _PlayerNotice extends StatelessWidget {
  const _PlayerNotice({
    required this.icon,
    required this.text,
    required this.actions,
    required this.onClose,
    required this.isWideLayout,
    required this.isTvLayout,
    this.compact = false,
    super.key,
  });

  final IconData icon;
  final String text;
  final bool compact;
  final List<_NoticeAction> actions;
  final VoidCallback onClose;
  final bool isWideLayout;
  final bool isTvLayout;

  double get _fontSize => isTvLayout ? 15 : (isWideLayout ? 13 : 12);
  double get _buttonSize => isTvLayout ? 48 : (isWideLayout ? 32 : 40);

  TextStyle _textStyle(BuildContext context) =>
      Theme.of(context).textTheme.labelLarge!.copyWith(
        color: Colors.white,
        fontSize: _fontSize,
        fontWeight: FontWeight.w500,
      );

  double _textWidth(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: _textStyle(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxWidth: isTvLayout ? 420 : (compact ? 310 : 340),
    ),
    child: Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(isWideLayout ? 16 : 12),
        side: BorderSide(
          color: Colors.white.withValues(alpha: 0.08),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        liveRegion: true,
        container: true,
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              10,
              isWideLayout ? 4 : 2,
              2,
              isWideLayout ? 4 : 2,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final actionWidth = actions.fold<double>(0, (width, action) {
                  final content =
                      _textWidth(context, action.label) +
                      12 +
                      (action.leading == null ? 0 : 30);
                  return width +
                      (content < _buttonSize ? _buttonSize : content);
                });
                final wrap =
                    _textWidth(context, text) + 24 + _buttonSize + actionWidth >
                    constraints.maxWidth;
                final buttons = [
                  for (final action in actions) _button(context, action),
                ];
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, color: Colors.white, size: 18),
                        const SizedBox(width: 6),
                        Flexible(child: Text(text, style: _textStyle(context))),
                        if (!wrap) ...buttons,
                        IconButton(
                          constraints: BoxConstraints.tightFor(
                            width: _buttonSize,
                            height: _buttonSize,
                          ),
                          onPressed: onClose,
                          icon: const Icon(
                            Icons.close_rounded,
                            semanticLabel: '关闭提示',
                            size: 16,
                            color: Color(0xFFD4DCE5),
                          ),
                          style: IconButton.styleFrom(
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.standard,
                          ),
                        ),
                      ],
                    ),
                    if (wrap)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Wrap(spacing: 4, children: buttons),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );

  Widget _button(BuildContext context, _NoticeAction action) => TextButton(
    onPressed: action.onPressed,
    style: TextButton.styleFrom(
      foregroundColor: const Color(0xFFACD5F2),
      backgroundColor: action.filled ? const Color(0xFF30465F) : null,
      minimumSize: Size(_buttonSize, _buttonSize),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      textStyle: _textStyle(context),
      shape: const StadiumBorder(),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (action.leading != null) ...[
          action.leading!,
          const SizedBox(width: 4),
        ],
        Text(action.label),
      ],
    ),
  );
}

/// Uses playback time, so pausing, buffering and seeking also update the ring.
class _EndingCountdown extends StatelessWidget {
  const _EndingCountdown({required this.controller});
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) =>
      ValueSelector<PlaybackTimelineState, (int, int)>(
        valueListenable: controller.timeline,
        select: (state) => (
          (state.duration - state.position).inMilliseconds.clamp(0, 1 << 53),
          state.duration.inMilliseconds,
        ),
        builder: (context, time) {
          final seconds = (time.$1 / 1000).ceil();
          final ending = controller.skipData.value.segments
              .where((segment) => segment.type == 'ed' && segment.fits(time.$2))
              .firstOrNull;
          final total = time.$2 - (ending?.startMs ?? 0);
          return Semantics(
            label: '距离下一集还有 $seconds 秒',
            child: ExcludeSemantics(
              child: SizedBox.square(
                dimension: 26,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned.fill(
                      child: CircularProgressIndicator(
                        value: total > 0
                            ? (time.$1 / total).clamp(0.0, 1.0)
                            : 0,
                        strokeWidth: 2,
                        backgroundColor: Colors.white.withValues(alpha: 0.16),
                        color: const Color(0xFFACD5F2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(3),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '$seconds',
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
}
