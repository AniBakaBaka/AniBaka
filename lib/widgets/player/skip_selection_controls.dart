import 'dart:async';

import 'package:baka/models/skip_selection.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/common/value_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'skip_segment_track.dart';

/// The normal player seekbar becomes a range selector while editing.
class SkipSelectionControls extends StatelessWidget {
  const SkipSelectionControls({
    required this.controller,
    this.onFullscreen,
    this.isFullScreen = false,
    super.key,
  });
  final PlaybackController controller;
  final VoidCallback? onFullscreen;
  final bool isFullScreen;

  Future<void> _save({bool allEpisodes = false}) async {
    try {
      if (await controller.finishSkipSelection(allEpisodes: allEpisodes)) {
        showSnackBar(allEpisodes ? '区间已应用到同片源线路的全集' : '区间已保存到本机');
      }
    } catch (error) {
      showSnackBar('保存失败：$error', isError: true);
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueSelector<SkipSelection?, ({String type, bool saving, int durationMs})?>(
    valueListenable: controller.skipSelection,
    select: (selection) => selection == null
        ? null
        : (
            type: selection.type,
            saving: selection.saving,
            durationMs: selection.durationMs,
          ),
    builder: (context, selection) {
      if (selection == null) return const SizedBox.shrink();
      final color = SkipSegmentColors.forType(selection.type);
      final colors = Theme.of(context).colorScheme;
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !selection.saving) controller.cancelSkipSelection();
        },
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (!selection.saving) controller.cancelSkipSelection();
            },
          },
          child: Material(
            color: Colors.black.withValues(alpha: 0.58),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final narrow =
                      constraints.maxWidth < 520 ||
                      MediaQuery.textScalerOf(context).scale(1) > 1.3;
                  final Widget selector =
                      constraints.maxWidth < 360 && constraints.maxHeight < 190
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: ShapeDecoration(
                            color: color.withValues(alpha: 0.2),
                            shape: const StadiumBorder(),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: selection.type,
                              dropdownColor: const Color(0xFF202833),
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: color, fontSize: 14),
                              items: const [
                                DropdownMenuItem(
                                  value: 'op',
                                  child: Text('片头'),
                                ),
                                DropdownMenuItem(
                                  value: 'ed',
                                  child: Text('片尾'),
                                ),
                              ],
                              onChanged: selection.saving
                                  ? null
                                  : (type) {
                                      if (type != null) {
                                        controller.beginSkipSelection(type);
                                      }
                                    },
                            ),
                          ),
                        )
                      : SegmentedButton<String>(
                          showSelectedIcon: false,
                          style: SegmentedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            selectedForegroundColor: Colors.black,
                            selectedBackgroundColor: color,
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          segments: const [
                            ButtonSegment(value: 'op', label: Text('片头')),
                            ButtonSegment(value: 'ed', label: Text('片尾')),
                          ],
                          selected: {selection.type},
                          onSelectionChanged: selection.saving
                              ? null
                              : (value) =>
                                    controller.beginSkipSelection(value.single),
                        );
                  final actions = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        key: const ValueKey('cancel-skip-selection'),
                        onPressed: selection.saving
                            ? null
                            : controller.cancelSkipSelection,
                        child: const Text(
                          '取消',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      FilledButton(
                        key: const ValueKey('save-skip-selection'),
                        style: FilledButton.styleFrom(
                          backgroundColor: colors.primary,
                          foregroundColor: colors.onPrimary,
                        ),
                        onPressed: selection.saving ? null : () => _save(),
                        child: Text(selection.saving ? '保存中' : '完成'),
                      ),
                      PopupMenuButton<bool>(
                        key: const ValueKey('save-skip-selection-scope'),
                        tooltip: '保存范围',
                        enabled:
                            !selection.saving &&
                            controller.skipContext?.seriesLocalKey != null,
                        iconColor: Colors.white,
                        onSelected: (allEpisodes) =>
                            _save(allEpisodes: allEpisodes),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: true,
                            child: Text(
                              '${selection.type == 'op' ? '片头' : '片尾'}应用到全集',
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (narrow)
                        SizedBox(
                          width: double.infinity,
                          child: Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            children: [selector, actions],
                          ),
                        )
                      else
                        Row(
                          children: [
                            selector,
                            const SizedBox(width: 16),
                            Expanded(
                              child: Text(
                                '拖动两端选择${selection.type == 'op' ? '片头' : '片尾'}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            actions,
                          ],
                        ),
                      Row(
                        children: [
                          ValueSelector<PlaybackCoreState, bool>(
                            valueListenable: controller.core,
                            select: (state) => state.playing,
                            builder: (context, playing) => IconButton(
                              tooltip: playing ? '暂停' : '播放',
                              onPressed: selection.saving
                                  ? null
                                  : controller.togglePlayback,
                              color: Colors.white,
                              icon: Icon(
                                playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                            ),
                          ),
                          if (!narrow)
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: ValueSelector<PlaybackTimelineState, int>(
                                valueListenable: controller.timeline,
                                select: (state) => state.position.inSeconds,
                                builder: (context, seconds) => Text(
                                  '${Duration(seconds: seconds).toTimeString()} / ${Duration(milliseconds: selection.durationMs).toTimeString()}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          Expanded(child: _rangeSlider(color)),
                          if (onFullscreen != null)
                            IconButton(
                              tooltip: isFullScreen ? '退出全屏' : '全屏',
                              onPressed: selection.saving ? null : onFullscreen,
                              color: Colors.white,
                              icon: Icon(
                                isFullScreen
                                    ? Icons.fullscreen_exit_rounded
                                    : Icons.fullscreen_rounded,
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _rangeSlider(Color color) => ValueListenableBuilder<SkipSelection?>(
    valueListenable: controller.skipSelection,
    builder: (context, selection, _) {
      if (selection == null) return const SizedBox.shrink();
      final range = selection.range;
      final start = Duration(milliseconds: range.startMs).toTimeString();
      final end = Duration(milliseconds: range.endMs).toTimeString();
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              activeTrackColor: color,
              inactiveTrackColor: Colors.white24,
              thumbColor: color,
              overlayColor: color.withValues(alpha: 0.16),
              minThumbSeparation: 0,
              showValueIndicator: ShowValueIndicator.onDrag,
              rangeThumbShape: const _RangeHandle(),
            ),
            child: RangeSlider(
              key: ValueKey('skip-range-${selection.type}'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              min: 0,
              max: selection.durationMs.toDouble(),
              divisions: (selection.durationMs / 1000).ceil(),
              values: RangeValues(
                range.startMs.toDouble(),
                range.endMs.toDouble(),
              ),
              labels: RangeLabels('起点 $start', '终点 $end'),
              semanticFormatterCallback: (value) =>
                  Duration(milliseconds: value.round()).toTimeString(),
              onChanged: selection.saving
                  ? null
                  : (values) => controller.updateSkipSelection(
                      values.start.round(),
                      values.end.round(),
                    ),
              onChangeStart: (_) => unawaited(controller.pause()),
            ),
          ),
          // A single readout stays legible even when two endpoints are close together.
          Text(
            '$start – $end',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      );
    },
  );
}

class _RangeHandle extends RoundRangeSliderThumbShape {
  const _RangeHandle();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(8, 24);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required SliderThemeData sliderTheme,
    bool isDiscrete = false,
    bool isEnabled = false,
    bool? isOnTop,
    TextDirection? textDirection,
    Thumb? thumb,
    bool? isPressed,
  }) {
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: 8, height: 24),
        const Radius.circular(4),
      ),
      Paint()
        ..color = thumb == Thumb.end ? Colors.white : sliderTheme.thumbColor!,
    );
  }
}
