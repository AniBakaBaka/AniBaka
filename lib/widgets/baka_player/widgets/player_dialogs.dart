import 'dart:io';

import 'package:flutter/material.dart';

import 'package:baka/models/playback_state.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/player/settings_panel.dart';
import '../controller.dart';

/// 倍速：侧边面板，点选即时生效。
Future<void> showSpeedDialog(
  BuildContext context,
  PlaybackController controller,
) => showPlayerSettingsPanel(context, _SpeedPanel(controller: controller));

/// 画面：比例 + 视频增强档位，和弹幕/播放器设置共用同一块浮层。
Future<void> showVideoFitDialog(
  BuildContext context,
  PlaybackController controller,
) => showPlayerSettingsPanel(context, _VideoPanel(controller: controller));

/// 长按 Anime4K 按钮时只调档位。
Future<void> showVideoEnhancementModeDialog(
  BuildContext context,
  PlaybackController controller,
) => showPlayerSettingsPanel(
  context,
  _EnhancementPanel(controller: controller),
);

class _SpeedPanel extends StatelessWidget {
  const _SpeedPanel({required this.controller});

  final PlaybackController controller;

  static const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0];

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PlaybackCoreState>(
    valueListenable: controller.core,
    builder: (context, core, _) => PanelContainer(
      title: '播放倍速',
      child: ListView(
        padding: playerPanelContentPadding(context),
        children: [
          const PanelSectionTitle('倍速'),
          PanelSettingsGroup(
            children: [
              for (final (index, speed) in _SpeedPanel.speeds.indexed) ...[
                if (index > 0) const PanelDivider(),
                PanelOptionTile(
                  title: '${speed}x',
                  subtitle: speed == 1.0 ? '正常速度' : null,
                  selected: core.playbackRate == speed,
                  onTap: () => _applyRate(speed),
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );

  void _applyRate(double speed) {
    controller.setRate(speed);
    controller.setControlsVisible(true);
  }
}

class _VideoPanel extends StatelessWidget {
  const _VideoPanel({required this.controller});

  final PlaybackController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PlaybackPreferences>(
    valueListenable: controller.preferences,
    builder: (context, preferences, _) {
      final gap = SizedBox(height: isCompactPlayerPanel(context) ? 12 : 24);
      return PanelContainer(
        title: '画面',
        child: ListView(
          padding: playerPanelContentPadding(context),
          children: [
            const PanelSectionTitle('画面比例'),
            PanelSettingsGroup(
              children: [
                for (final (index, type)
                    in PlaybackController.videoFitTypes.indexed) ...[
                  if (index > 0) const PanelDivider(),
                  PanelOptionTile(
                    title: type.description,
                    selected: preferences.videoFit == type.fit,
                    onTap: () => controller.setVideoFit(
                      type.fit,
                      type.description,
                    ),
                  ),
                ],
              ],
            ),
            if (Platform.isWindows) ...[
              gap,
              const PanelSectionTitle('Anime4K 增强'),
              PanelSettingsGroup(
                children: _enhancementTiles(
                  controller,
                  preferences.videoEnhancementMode,
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}

class _EnhancementPanel extends StatelessWidget {
  const _EnhancementPanel({required this.controller});

  final PlaybackController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PlaybackPreferences>(
    valueListenable: controller.preferences,
    builder: (context, preferences, _) => PanelContainer(
      title: 'Anime4K 增强',
      child: ListView(
        padding: playerPanelContentPadding(context),
        children: [
          PanelSettingsGroup(
            children: _enhancementTiles(
              controller,
              preferences.videoEnhancementMode,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 档位行：画面面板与长按入口共用。
List<Widget> _enhancementTiles(
  PlaybackController controller,
  VideoEnhancementMode current,
) => [
  for (final (index, mode) in _enhancementModes.indexed) ...[
    if (index > 0) const PanelDivider(),
    PanelOptionTile(
      title: mode.label,
      subtitle: _enhancementDescription(mode),
      selected: current == mode,
      onTap: () => _applyEnhancement(controller, mode),
    ),
  ],
];

const _enhancementModes = [
  VideoEnhancementMode.off,
  VideoEnhancementMode.low,
  VideoEnhancementMode.medium,
  VideoEnhancementMode.high,
  VideoEnhancementMode.ultra,
];

String? _enhancementDescription(VideoEnhancementMode mode) => switch (mode) {
  VideoEnhancementMode.off => '关闭视频增强',
  VideoEnhancementMode.low => '轻度锐化，画面更通透，性能开销小',
  VideoEnhancementMode.medium => '线条更锐利，画面更干净，效果明显',
  VideoEnhancementMode.high => '大幅提升清晰度，改善显著',
  VideoEnhancementMode.ultra => '负载高，线条与细节还原最佳',
};

Future<void> _applyEnhancement(
  PlaybackController controller,
  VideoEnhancementMode mode,
) async {
  try {
    await controller.setVideoEnhancementMode(mode);
    showSnackBar('视频增强：${mode.label}');
  } catch (error) {
    showSnackBar('视频增强切换失败：$error');
  }
}
