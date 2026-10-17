import 'package:baka/models/playback_state.dart';
import 'package:baka/widgets/settings/dlss_effects_editor.dart';
import '../controller.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/material.dart';

Future<void> showDlssEffectsDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('DLSS 播放增强'),
    content: const SizedBox(
      width: 540,
      child: SingleChildScrollView(child: DlssSettings()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  ),
);

Future<void> showSpeedDialog(
  BuildContext context,
  PlaybackController controller,
) async {
  const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0];
  final current = controller.core.value.playbackRate;
  final result = await showAppSelectionDialog<double>(
    context,
    title: '播放倍速',
    options: speeds,
    label: (speed) => '${speed}x',
    isSelected: (speed) => speed == current,
  );
  if (result != null) {
    controller.setRate(result);
  }
}

Future<void> showVideoFitDialog(
  BuildContext context,
  PlaybackController controller,
) async {
  final currentFit = controller.preferences.value.videoFit;
  final result =
      await showAppSelectionDialog<({BoxFit fit, String description})>(
        context,
        title: '画面比例',
        options: PlaybackController.videoFitTypes,
        label: (type) => type.description,
        isSelected: (type) => type.fit == currentFit,
      );
  if (result != null) {
    controller.setVideoFit(result.fit, result.description);
  }
}

Future<void> showVideoEnhancementModeDialog(
  BuildContext context,
  PlaybackController controller,
) async {
  const options = [
    VideoEnhancementMode.low,
    VideoEnhancementMode.medium,
    VideoEnhancementMode.high,
    VideoEnhancementMode.ultra,
  ];
  final result = await showAppSelectionDialog<VideoEnhancementMode>(
    context,
    title: 'Anime4K 增强档位',
    options: options,
    label: (mode) => mode.label,
    isSelected: (mode) =>
        mode == controller.preferences.value.videoEnhancementMode,
    subtitle: (mode) => switch (mode) {
      VideoEnhancementMode.off => null,
      VideoEnhancementMode.low => '轻度锐化，画面更通透，性能开销小',
      VideoEnhancementMode.medium => '线条更锐利，画面更干净，效果明显',
      VideoEnhancementMode.high => '大幅提升清晰度，改善显著',
      VideoEnhancementMode.ultra => '负载高，线条与细节还原最佳',
    },
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
