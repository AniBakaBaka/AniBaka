import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback_settings_service.dart';
import 'package:flutter/material.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/player/settings_panel.dart';

class PlayerSettingsPage extends StatefulWidget {
  final PlaybackController controller;

  const PlayerSettingsPage({required this.controller, super.key});

  static Future<void> show(
    BuildContext context,
    PlaybackController controller,
  ) async {
    await controller.initialize();

    if (!context.mounted) return;
    return showPlayerSettingsPanel(
      context,
      PlayerSettingsPage(controller: controller),
    );
  }

  @override
  State<PlayerSettingsPage> createState() => _PlayerSettingsPageState();
}

class _PlayerSettingsPageState extends State<PlayerSettingsPage> {
  Future<void> _resetToDefaults() async {
    await widget.controller.resetPreferences();
    showSnackBar('已重置为默认设置');
  }

  Future<void> _update(
    PlaybackPreferences Function(PlaybackPreferences current) change, {
    bool persist = true,
  }) {
    return widget.controller.updatePreferences(
      change(widget.controller.preferences.value),
      persist: persist,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cardColor = Colors.white.withValues(alpha: 0.05);

    return ValueListenableBuilder<PlaybackPreferences>(
      valueListenable: widget.controller.preferences,
      builder: (context, preferences, _) => PanelContainer(
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  const PanelSectionTitle('播放体验'),
                  PanelSettingsGroup(
                    backgroundColor: cardColor,
                    children: [
                      PanelSwitchTile(
                        title: '记住播放位置',
                        subtitle: '下次打开时继续从上次位置播放',
                        value: preferences.rememberLastPosition,
                        onChanged: (value) => _update(
                          (current) =>
                              current.copyWith(rememberLastPosition: value),
                        ),
                      ),
                      const PanelDivider(),
                      PanelSwitchTile(
                        title: '自动全屏',
                        subtitle: '播放开始时自动进入全屏',
                        value: preferences.autoFullscreen,
                        onChanged: (value) => _update(
                          (current) => current.copyWith(autoFullscreen: value),
                        ),
                      ),
                      const PanelDivider(),
                      PanelSwitchTile(
                        title: '显示系统时间',
                        subtitle: '在播放器顶部显示时间',
                        value: preferences.showSystemTime,
                        onChanged: (value) => _update(
                          (current) => current.copyWith(showSystemTime: value),
                        ),
                      ),
                      const PanelDivider(),
                      PanelSwitchTile(
                        title: '显示下一集按钮',
                        value: preferences.showNextEpisodeButton,
                        onChanged: (value) => _update(
                          (current) =>
                              current.copyWith(showNextEpisodeButton: value),
                        ),
                      ),
                      PanelSelectTile(
                        title: '硬件解码',
                        value: preferences.hwdecMode,
                        options:
                            PlaybackSettingsService.hwdecModeLabelsForPlatform,
                        onChanged: (value) => _update(
                          (current) => current.copyWith(hwdecMode: value),
                        ),
                      ),
                      const PanelDivider(),
                      PanelSelectTile(
                        title: '视频渲染器',
                        value: preferences.videoRenderer,
                        options:
                            PlaybackSettingsService
                                .videoRendererLabelsForPlatform,
                        onChanged: (value) => _update(
                          (current) => current.copyWith(videoRenderer: value),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  const PanelSectionTitle('智能跳过'),
                  PanelSettingsGroup(
                    backgroundColor: cardColor,
                    children: [
                      PanelSwitchTile(
                        title: '启用智能跳过',
                        subtitle: '自动跳过片头片尾',
                        value: preferences.enableSkipOpEd,
                        onChanged: (value) => _update(
                          (current) => current.copyWith(enableSkipOpEd: value),
                        ),
                      ),
                      if (preferences.enableSkipOpEd)
                        Column(
                          children: [
                            const PanelDivider(),
                            PanelSliderTile(
                              title: '等待操作',
                              value: preferences.skipOpWaitTime.toDouble(),
                              valueLabel: '${preferences.skipOpWaitTime}秒',
                              min: 30,
                              max: 300,
                              divisions: 27,
                              onChanged: (value) => _update(
                                (current) => current.copyWith(
                                  skipOpWaitTime: value.round(),
                                ),
                                persist: false,
                              ),
                              onChangeEnd: (value) => _update(
                                (current) => current.copyWith(
                                  skipOpWaitTime: value.round(),
                                ),
                              ),
                            ),
                            const PanelDivider(),
                            PanelSliderTile(
                              title: '跳过时长',
                              value: preferences.skipOpDuration.toDouble(),
                              valueLabel: '${preferences.skipOpDuration}秒',
                              min: 30,
                              max: 300,
                              divisions: 27,
                              onChanged: (value) => _update(
                                (current) => current.copyWith(
                                  skipOpDuration: value.round(),
                                ),
                                persist: false,
                              ),
                              onChangeEnd: (value) => _update(
                                (current) => current.copyWith(
                                  skipOpDuration: value.round(),
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  const PanelSectionTitle('手势交互'),
                  PanelSettingsGroup(
                    backgroundColor: cardColor,
                    children: [
                      PanelSliderTile(
                        title: '长按倍速',
                        value: preferences.longPressSpeed,
                        valueLabel: '${preferences.longPressSpeed}x',
                        min: 1.5,
                        max: 5.0,
                        divisions: 7,
                        onChanged: (value) => _update(
                          (current) => current.copyWith(
                            longPressSpeed: (value * 10).round() / 10,
                          ),
                          persist: false,
                        ),
                        onChangeEnd: (value) => _update(
                          (current) => current.copyWith(
                            longPressSpeed: (value * 10).round() / 10,
                          ),
                        ),
                      ),
                      const PanelDivider(),
                      PanelSwitchTile(
                        title: '双击功能',
                        value: preferences.enableDoubleTap,
                        onChanged: (value) => _update(
                          (current) => current.copyWith(enableDoubleTap: value),
                        ),
                      ),
                      if (preferences.enableDoubleTap)
                        Column(
                          children: [
                            const PanelDivider(),
                            PanelSelectTile(
                              title: '双击动作',
                              value: preferences.doubleTapAction,
                              options:
                                  PlaybackSettingsService.doubleTapActionLabels,
                              onChanged: (value) => _update(
                                (current) =>
                                    current.copyWith(doubleTapAction: value),
                              ),
                            ),
                            const PanelDivider(),
                            PanelSliderTile(
                              title: '快进时长',
                              value: preferences.doubleTapSeekDuration
                                  .toDouble(),
                              valueLabel:
                                  '${preferences.doubleTapSeekDuration}秒',
                              min: 5,
                              max: 60,
                              divisions: 11,
                              onChanged: (value) => _update(
                                (current) => current.copyWith(
                                  doubleTapSeekDuration: value.round(),
                                ),
                                persist: false,
                              ),
                              onChangeEnd: (value) => _update(
                                (current) => current.copyWith(
                                  doubleTapSeekDuration: value.round(),
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),

                  const SizedBox(height: 32),

                  PanelResetButton(onPressed: _resetToDefaults),
                  const SizedBox(height: 32),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
