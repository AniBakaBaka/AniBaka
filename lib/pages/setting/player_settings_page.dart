import 'package:flutter/material.dart';

import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/player/settings_panel.dart';
import 'package:baka/widgets/player/skip_segments_panel.dart';

class PlayerSettingsPage extends StatelessWidget {
  const PlayerSettingsPage({required this.controller, super.key});

  final PlaybackController controller;

  static Future<void> show(
    BuildContext context,
    PlaybackController controller,
  ) => showPlayerSettingsPanel(
    context,
    PlayerSettingsPage(controller: controller),
  );

  void _set(PlaybackPreferences next, {bool persist = true}) =>
      controller.updatePreferences(next, persist: persist);

  @override
  Widget build(BuildContext context) {
    final gap = SizedBox(height: isCompactPlayerPanel(context) ? 12 : 24);
    return ValueListenableBuilder<PlaybackPreferences>(
      valueListenable: controller.preferences,
      builder: (context, p, _) => PanelContainer(
        title: '播放器设置',
        child: ListView(
          padding: playerPanelContentPadding(context),
          children: [
            const PanelSectionTitle('播放'),
            PanelSettingsGroup(
              children: [
                PanelSwitchTile(
                  title: '记住播放位置',
                  value: p.rememberLastPosition,
                  onChanged: (v) => _set(p.copyWith(rememberLastPosition: v)),
                ),
                const PanelDivider(),
                PanelSwitchTile(
                  title: '自动全屏',
                  value: p.autoFullscreen,
                  onChanged: (v) => _set(p.copyWith(autoFullscreen: v)),
                ),
                const PanelDivider(),
                PanelSwitchTile(
                  title: '显示系统时间',
                  value: p.showSystemTime,
                  onChanged: (v) => _set(p.copyWith(showSystemTime: v)),
                ),
                const PanelDivider(),
                PanelSwitchTile(
                  title: '显示下一集按钮',
                  value: p.showNextEpisodeButton,
                  onChanged: (v) => _set(p.copyWith(showNextEpisodeButton: v)),
                ),
              ],
            ),
            gap,
            const PanelSectionTitle('片头片尾'),
            PanelSettingsGroup(
              children: [
                PanelSwitchTile(
                  title: '自动跳过',
                  value: p.enableSkipOpEd,
                  onChanged: (v) => _set(p.copyWith(enableSkipOpEd: v)),
                ),
                const PanelDivider(),
                FilledButton.tonal(
                  onPressed: () => SkipSegmentsPanel.show(context, controller),
                  child: const Row(
                    children: [
                      Expanded(child: Text('校正区间')),
                      Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ),
              ],
            ),
            gap,
            const PanelSectionTitle('手势'),
            PanelSettingsGroup(
              children: [
                PanelSliderTile(
                  title: '长按倍速',
                  value: p.longPressSpeed,
                  valueLabel: '${p.longPressSpeed}x',
                  min: 1.5,
                  max: 5,
                  divisions: 7,
                  onChanged: (v) =>
                      _set(p.copyWith(longPressSpeed: v), persist: false),
                  onChangeEnd: (v) => _set(p.copyWith(longPressSpeed: v)),
                ),
                const PanelDivider(),
                PanelSwitchTile(
                  title: '双击',
                  value: p.enableDoubleTap,
                  onChanged: (v) => _set(p.copyWith(enableDoubleTap: v)),
                ),
                if (p.enableDoubleTap) ...[
                  const PanelDivider(),
                  PanelSelectTile(
                    title: '双击动作',
                    value: p.doubleTapAction,
                    options: PlaybackSettingsService.doubleTapActionLabels,
                    onChanged: (v) => _set(p.copyWith(doubleTapAction: v)),
                  ),
                  const PanelDivider(),
                  PanelSliderTile(
                    title: '快进时长',
                    value: p.doubleTapSeekDuration.toDouble(),
                    valueLabel: '${p.doubleTapSeekDuration}秒',
                    min: 5,
                    max: 60,
                    divisions: 11,
                    onChanged: (v) => _set(
                      p.copyWith(doubleTapSeekDuration: v.round()),
                      persist: false,
                    ),
                    onChangeEnd: (v) =>
                        _set(p.copyWith(doubleTapSeekDuration: v.round())),
                  ),
                ],
              ],
            ),
            gap,
            const PanelSectionTitle('解码'),
            PanelSettingsGroup(
              children: [
                PanelSwitchTile(
                  title: 'HLS 视频去广告',
                  value: p.filterHlsAds,
                  onChanged: (v) => _set(p.copyWith(filterHlsAds: v)),
                ),
                const PanelDivider(),
                PanelSelectTile(
                  title: '硬件解码',
                  value: p.hwdecMode,
                  options: PlaybackSettingsService.hwdecModeLabelsForPlatform,
                  onChanged: (v) => _set(p.copyWith(hwdecMode: v)),
                ),
                const PanelDivider(),
                PanelSelectTile(
                  title: '视频渲染器',
                  value: p.videoRenderer,
                  options:
                      PlaybackSettingsService.videoRendererLabelsForPlatform,
                  onChanged: (v) => _set(p.copyWith(videoRenderer: v)),
                ),
              ],
            ),
            gap,
            PanelResetButton(
              onPressed: () async {
                await controller.resetPreferences();
                showSnackBar('已恢复默认设置');
              },
            ),
          ],
        ),
      ),
    );
  }
}
