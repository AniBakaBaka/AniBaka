import 'package:flutter/material.dart';

import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';

class PlaybackSettingsPage extends StatefulWidget {
  const PlaybackSettingsPage({super.key});

  @override
  State<PlaybackSettingsPage> createState() => _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends State<PlaybackSettingsPage> {
  static final _speeds = {
    for (final speed in PlaybackSettingsService.playbackSpeedOptions)
      speed: PlaybackSettingsService.formatPlaybackSpeed(speed),
  };

  var _preferences = PlaybackSettingsService.loadAll();

  void _set(PlaybackPreferences next) {
    PlaybackSettingsService.saveChanges(_preferences, next);
    setState(() => _preferences = next);
  }

  @override
  Widget build(BuildContext context) {
    final p = _preferences;
    return SettingsPage(
      title: '播放设置',
      children: [
        SettingsSection(
          title: '默认',
          children: [
            SettingsSelectTile<double>(
              icon: Icons.speed_rounded,
              title: '播放速度',
              value: p.defaultPlaybackSpeed,
              options: _speeds,
              onChanged: (v) => _set(p.copyWith(defaultPlaybackSpeed: v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.subtitles_off_outlined),
              title: const Text('默认关闭弹幕'),
              value: p.defaultDanmakuOff,
              onChanged: (v) => _set(p.copyWith(defaultDanmakuOff: v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.closed_caption_off_outlined),
              title: const Text('默认关闭内嵌字幕'),
              value: !p.showSubtitle,
              onChanged: (v) => _set(p.copyWith(showSubtitle: !v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.filter_alt_outlined),
              title: const Text('HLS 视频去广告'),
              value: p.filterHlsAds,
              onChanged: (v) => _set(p.copyWith(filterHlsAds: v)),
            ),
          ],
        ),
        SettingsSection(
          title: '解码',
          children: [
            SettingsSelectTile<String>(
              icon: Icons.memory_rounded,
              title: '硬件解码',
              value: p.hwdecMode,
              options: PlaybackSettingsService.hwdecModeLabelsForPlatform,
              onChanged: (v) => _set(p.copyWith(hwdecMode: v)),
            ),
            SettingsSelectTile<String>(
              icon: Icons.monitor_rounded,
              title: '视频渲染器',
              value: p.videoRenderer,
              options: PlaybackSettingsService.videoRendererLabelsForPlatform,
              onChanged: (v) => _set(p.copyWith(videoRenderer: v)),
            ),
          ],
        ),
        SettingsSection(
          title: '缓存',
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.memory_outlined),
              title: const Text('低内存模式'),
              value: PlaybackSettingsService.getLowMemoryMode(),
              onChanged: (v) {
                PlaybackSettingsService.setLowMemoryMode(v);
                setState(() {});
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.auto_delete_outlined),
              title: const Text('退出时清理缓存'),
              value: PlaybackSettingsService.getClearCacheOnExit(),
              onChanged: (v) {
                PlaybackSettingsService.setClearCacheOnExit(v);
                setState(() {});
              },
            ),
          ],
        ),
      ],
    );
  }
}
