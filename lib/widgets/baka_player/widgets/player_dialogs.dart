import 'package:baka/models/playback_state.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/material.dart';

void showSpeedDialog(BuildContext context, PlaybackController controller) {
  const speeds = [0.5, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0];
  _showSelectionDialog<double>(
    context: context,
    title: '倍速',
    items: speeds
        .map(
          (speed) => (
            value: speed,
            label: speed.toString(),
            selected: speed == controller.core.value.playbackRate,
          ),
        )
        .toList(),
    onSelect: controller.setRate,
    actions: [
      TextButton(
        onPressed: () {
          controller.setRate(1.0);
          Navigator.pop(context);
        },
        child: const Text('默认速度'),
      ),
    ],
  );
}

void showVideoFitDialog(BuildContext context, PlaybackController controller) {
  _showSelectionDialog<({BoxFit fit, String description})>(
    context: context,
    title: '画面比例',
    items: PlaybackController.videoFitTypes
        .map(
          (type) => (
            value: type,
            label: type.description,
            selected: type.fit == controller.preferences.value.videoFit,
          ),
        )
        .toList(),
    onSelect: (type) {
      controller.setVideoFit(type.fit, type.description);
    },
  );
}

Future<void> showVideoEnhancementModeDialog(
  BuildContext context,
  PlaybackController controller,
) async {
  final options = <SelectionOption<VideoEnhancementMode>>[
    const SelectionOption(
      value: VideoEnhancementMode.low,
      label: '低',
      subtitle: '轻度锐化，画面更通透，性能开销小',
    ),
    const SelectionOption(
      value: VideoEnhancementMode.medium,
      label: '中',
      subtitle: '线条更锐利，画面更干净，效果明显',
    ),
    const SelectionOption(
      value: VideoEnhancementMode.high,
      label: '高',
      subtitle: '大幅提升清晰度，改善显著',
    ),
    const SelectionOption(
      value: VideoEnhancementMode.ultra,
      label: '超高',
      subtitle: '负载高，线条与细节还原最佳',
    ),
  ];
  final result = await showAppSelectionDialog<VideoEnhancementMode>(
    context,
    title: 'Anime4K 增强档位',
    options: options,
    currentValue: controller.preferences.value.videoEnhancementMode,
  );
  if (result != null) {
    try {
      await controller.setVideoEnhancementMode(result);
      showSnackBar('视频增强：${result.label}');
    } catch (error) {
      showSnackBar('视频增强切换失败：$error');
    }
  }
}

void _showSelectionDialog<T>({
  required BuildContext context,
  required String title,
  required List<({T value, String label, bool selected})> items,
  required void Function(T) onSelect,
  List<Widget>? actions,
}) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Wrap(
        spacing: 8,
        children: items
            .map(
              (item) => InkWell(
                onTap: () {
                  onSelect(item.value);
                  Navigator.pop(ctx);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: Theme.of(ctx).colorScheme.primary.withValues(
                      alpha: item.selected ? 0.3 : 0.1,
                    ),
                  ),
                  child: Text(item.label),
                ),
              ),
            )
            .toList(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(
            '取消',
            style: TextStyle(color: Theme.of(ctx).colorScheme.outline),
          ),
        ),
        ...?actions,
      ],
    ),
  );
}
