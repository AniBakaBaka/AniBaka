import 'package:baka/services/playback_settings_service.dart';
import 'package:baka/models/playback_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';

class PlaybackSettingsPage extends StatefulWidget {
  const PlaybackSettingsPage({super.key});

  @override
  State<PlaybackSettingsPage> createState() => _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends State<PlaybackSettingsPage> {
  PlaybackPreferences _preferences = PlaybackSettingsService.loadAll();
  bool _clearCacheOnExit = PlaybackSettingsService.getClearCacheOnExit();
  bool _lowMemoryMode = PlaybackSettingsService.getLowMemoryMode();

  static const _hwdecDescriptions = <String, String>{
    'auto': '自动选择最佳硬件解码器',
    'auto-safe': '仅使用经验证可靠的解码器',
    'mediacodec-copy': 'MediaCodec 硬解后复制帧到 GPU，兼容性最好',
    'no': '使用CPU解码，兼容性最好',
  };

  static const _rendererDescriptions = <String, String>{
    'gpu': 'GPU 渲染器，兼容性最好',
    'gpu-next': '新一代 GPU 渲染器，画质更好但要求更高',
    'mediacodec_embed': 'Android 专用：解码帧直写 Surface，绕过 GPU 合成，适合部分电视黑屏但有声',
  };

  /// 就地改字段 + 落盘，取代每个开关各写一个四行的 `_setXxx` 方法。
  Future<void> _apply(VoidCallback assign, Future<void> Function() persist) {
    setState(assign);
    return persist();
  }

  Future<void> _updatePreferences(PlaybackPreferences next) {
    final previous = _preferences;
    setState(() => _preferences = next);
    return PlaybackSettingsService.saveChanges(previous, next);
  }

  /// 通用单选底部弹窗：三份逐行同构的 `_showXxxSheet` 收敛成一个。
  Future<void> _pickOption<T>({
    required String title,
    required T current,
    required List<T> options,
    required String Function(T option) labelOf,
    required Future<void> Function(T selected) onSelected,
    String? intro,
    String Function(T option)? descriptionOf,
  }) async {
    HapticFeedback.selectionClick();
    final selected = await showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (intro != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(
                  intro,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
            RadioGroup<T>(
              groupValue: current,
              onChanged: (value) => Navigator.pop(context, value),
              child: Column(
                children: [
                  for (final option in options)
                    RadioListTile<T>(
                      value: option,
                      title: Text(labelOf(option)),
                      subtitle: descriptionOf == null
                          ? null
                          : Text(descriptionOf(option)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected != null) await onSelected(selected);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          const SettingsSliverAppBar(title: '播放与下载'),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 20),
                const SettingsSectionHeader('播放控制'),
                SettingsGroup(
                  children: [
                    SettingsTile(
                      title: '默认播放速度',
                      value: PlaybackSettingsService.formatPlaybackSpeed(
                        _preferences.defaultPlaybackSpeed,
                      ),
                      icon: Icons.speed_rounded,
                      onTap: () => _pickOption<double>(
                        title: '默认播放速度',
                        current: _preferences.defaultPlaybackSpeed,
                        options: PlaybackSettingsService.playbackSpeedOptions,
                        labelOf: PlaybackSettingsService.formatPlaybackSpeed,
                        onSelected: (speed) {
                          final value =
                              PlaybackSettingsService.normalizePlaybackSpeed(
                                speed,
                              );
                          return _updatePreferences(
                            _preferences.copyWith(defaultPlaybackSpeed: value),
                          );
                        },
                      ),
                    ),
                    SettingsSwitchTile(
                      title: '默认关闭弹幕',
                      value: _preferences.defaultDanmakuOff,
                      icon: Icons.subtitles_off_rounded,
                      onChanged: (value) => _updatePreferences(
                        _preferences.copyWith(defaultDanmakuOff: value),
                      ),
                    ),
                    SettingsSwitchTile(
                      title: '默认关闭内嵌字幕',
                      value: !_preferences.showSubtitle,
                      icon: Icons.closed_caption_off_rounded,
                      onChanged: (value) => _updatePreferences(
                        _preferences.copyWith(showSubtitle: !value),
                      ),
                    ),
                    SettingsTile(
                      title: '硬件解码',
                      value:
                          PlaybackSettingsService
                              .hwdecModeLabelsForPlatform[_preferences
                              .hwdecMode] ??
                          PlaybackSettingsService.hwdecModeLabels[_preferences
                              .hwdecMode] ??
                          '自动',
                      icon: Icons.memory_rounded,
                      onTap: () => _pickOption<String>(
                        title: '硬件解码模式',
                        intro: '如果遇到视频黑屏、花屏或卡顿，可尝试切换解码模式',
                        current: _preferences.hwdecMode,
                        options:
                            PlaybackSettingsService.hwdecModeOptionsForPlatform,
                        labelOf: (mode) =>
                            PlaybackSettingsService
                                .hwdecModeLabelsForPlatform[mode] ??
                            mode,
                        descriptionOf: (mode) => _hwdecDescriptions[mode] ?? '',
                        onSelected: (mode) {
                          final value =
                              PlaybackSettingsService.normalizeHwdecMode(mode);
                          return _updatePreferences(
                            _preferences.copyWith(hwdecMode: value),
                          );
                        },
                      ),
                    ),
                    SettingsTile(
                      title: '视频渲染器',
                      value:
                          PlaybackSettingsService
                              .videoRendererLabels[_preferences
                              .videoRenderer] ??
                          '自动',
                      icon: Icons.monitor_rounded,
                      onTap: () => _pickOption<String>(
                        title: '视频渲染器',
                        intro:
                            'gpu 为 GPU 渲染器；若电视播放黑屏但有声音，'
                            '可切换到 mediacodec_embed',
                        current: _preferences.videoRenderer,
                        options: PlaybackSettingsService
                            .videoRendererOptionsForPlatform,
                        labelOf: (renderer) =>
                            PlaybackSettingsService
                                .videoRendererLabels[renderer] ??
                            renderer,
                        descriptionOf: (renderer) =>
                            _rendererDescriptions[renderer] ?? '',
                        onSelected: (renderer) {
                          final value =
                              PlaybackSettingsService.normalizeVideoRenderer(
                                renderer,
                              );
                          return _updatePreferences(
                            _preferences.copyWith(videoRenderer: value),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('缓存管理'),
                SettingsGroup(
                  children: [
                    SettingsSwitchTile(
                      title: '低内存模式',
                      subtitle: '减少图片与播放器缓冲占用，网络较慢时可能更频繁地重新加载',
                      value: _lowMemoryMode,
                      icon: Icons.memory_outlined,
                      onChanged: (value) => _apply(
                        () => _lowMemoryMode = value,
                        () => PlaybackSettingsService.setLowMemoryMode(value),
                      ),
                    ),
                    SettingsSwitchTile(
                      title: '退出自动清理缓存',
                      value: _clearCacheOnExit,
                      icon: Icons.auto_delete_rounded,
                      onChanged: (value) => _apply(
                        () => _clearCacheOnExit = value,
                        () =>
                            PlaybackSettingsService.setClearCacheOnExit(value),
                      ),
                      showDivider: false,
                    ),
                  ],
                ),
                const SizedBox(height: 40),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
