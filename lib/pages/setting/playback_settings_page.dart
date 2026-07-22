import 'package:baka/instance.dart';
import 'package:baka/services/playback_settings_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';

class PlaybackSettingsPage extends StatefulWidget {
  const PlaybackSettingsPage({super.key});

  @override
  State<PlaybackSettingsPage> createState() => _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends State<PlaybackSettingsPage> {
  bool _defaultDanmakuOff = PlaybackSettingsService.getDefaultDanmakuOff();
  bool _defaultSubtitleOff = PlaybackSettingsService.getDefaultSubtitleOff();
  bool _clearCacheOnExit = PlaybackSettingsService.getClearCacheOnExit();
  bool _enableBtDownload = PlaybackSettingsService.getEnableBtDownload();
  bool _autoMatchSource = PlaybackSettingsService.getAutoMatchSource();
  double _defaultPlaybackSpeed =
      PlaybackSettingsService.getDefaultPlaybackSpeed();
  String _hwdecMode = PlaybackSettingsService.normalizeHwdecMode(
    Instances.sp.getString('player_hwdecMode'),
  );
  String _videoRenderer = PlaybackSettingsService.normalizeVideoRenderer(
    Instances.sp.getString('player_videoRenderer'),
  );

  Future<void> _setDefaultDanmakuOff(bool value) async {
    setState(() => _defaultDanmakuOff = value);
    await PlaybackSettingsService.setDefaultDanmakuOff(value);
  }

  Future<void> _setDefaultSubtitleOff(bool value) async {
    setState(() => _defaultSubtitleOff = value);
    await PlaybackSettingsService.setDefaultSubtitleOff(value);
  }

  Future<void> _setClearCacheOnExit(bool value) async {
    setState(() => _clearCacheOnExit = value);
    await PlaybackSettingsService.setClearCacheOnExit(value);
  }

  Future<void> _setEnableBtDownload(bool value) async {
    setState(() => _enableBtDownload = value);
    await PlaybackSettingsService.setEnableBtDownload(value);
  }

  Future<void> _setAutoMatchSource(bool value) async {
    setState(() => _autoMatchSource = value);
    await PlaybackSettingsService.setAutoMatchSource(value);
  }

  Future<void> _setDefaultPlaybackSpeed(double speed) async {
    final normalized = PlaybackSettingsService.normalizePlaybackSpeed(speed);
    setState(() => _defaultPlaybackSpeed = normalized);
    await PlaybackSettingsService.setDefaultPlaybackSpeed(normalized);
  }

  Future<void> _setHwdecMode(String mode) async {
    final normalized = PlaybackSettingsService.normalizeHwdecMode(mode);
    setState(() => _hwdecMode = normalized);
    await Instances.sp.setString('player_hwdecMode', normalized);
  }

  Future<void> _setVideoRenderer(String renderer) async {
    final normalized = PlaybackSettingsService.normalizeVideoRenderer(renderer);
    setState(() => _videoRenderer = normalized);
    await Instances.sp.setString('player_videoRenderer', normalized);
  }

  Future<void> _showVideoRendererSheet() async {
    HapticFeedback.selectionClick();
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Text(
                '视频渲染器',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Text(
                '渲染器始终使用嵌入式 libmpv 输出，以下选项只调整安全的 GPU 渲染配置',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ),
            RadioGroup<String>(
              groupValue: _videoRenderer,
              onChanged: (value) => Navigator.pop(context, value),
              child: Column(
                children: [
                  for (final renderer
                      in PlaybackSettingsService.videoRendererOptions)
                    RadioListTile<String>(
                      value: renderer,
                      title: Text(
                        PlaybackSettingsService.videoRendererLabels[renderer] ??
                            renderer,
                      ),
                      subtitle: Text(_videoRendererDescription(renderer)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected != null) await _setVideoRenderer(selected);
  }

  String _videoRendererDescription(String renderer) => switch (renderer) {
    'auto' => '使用稳定、低开销的默认渲染参数',
    'compatibility' => '关闭高质量缩放，适合黑屏、花屏或性能不足的设备',
    'quality' => '启用高质量缩放，GPU 占用更高',
    _ => '',
  };

  Future<void> _showHwdecModeSheet() async {
    HapticFeedback.selectionClick();
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 8, 24, 12),
                child: Text(
                  '硬件解码模式',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(
                  '如果遇到视频黑屏、花屏或卡顿，可尝试切换解码模式',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
              RadioGroup<String>(
                groupValue: _hwdecMode,
                onChanged: (value) => Navigator.pop(context, value),
                child: Column(
                  children: [
                    for (final mode in PlaybackSettingsService.hwdecModeOptions)
                      RadioListTile<String>(
                        value: mode,
                        title: Text(
                          PlaybackSettingsService.hwdecModeLabels[mode] ?? mode,
                        ),
                        subtitle: Text(_hwdecModeDescription(mode)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (selected != null) {
      await _setHwdecMode(selected);
    }
  }

  String _hwdecModeDescription(String mode) => switch (mode) {
    'auto' => '自动选择最佳硬件解码器',
    'auto-safe' => '仅使用经验证可靠的解码器',
    'no' => '使用CPU解码，兼容性最好',
    _ => '',
  };

  Future<void> _showDefaultPlaybackSpeedSheet() async {
    HapticFeedback.selectionClick();
    final selected = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final current = _defaultPlaybackSpeed;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 8, 24, 12),
                child: Text(
                  '默认播放速度',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              RadioGroup<double>(
                groupValue: current,
                onChanged: (value) => Navigator.pop(context, value),
                child: Column(
                  children: [
                    for (final speed
                        in PlaybackSettingsService.playbackSpeedOptions)
                      RadioListTile<double>(
                        value: speed,
                        title: Text(
                          PlaybackSettingsService.formatPlaybackSpeed(speed),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (selected != null) {
      await _setDefaultPlaybackSpeed(selected);
    }
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
                        _defaultPlaybackSpeed,
                      ),
                      icon: Icons.speed_rounded,
                      onTap: _showDefaultPlaybackSpeedSheet,
                    ),
                    SettingsSwitchTile(
                      title: '默认关闭弹幕',
                      value: _defaultDanmakuOff,
                      icon: Icons.subtitles_off_rounded,
                      onChanged: _setDefaultDanmakuOff,
                    ),
                    SettingsSwitchTile(
                      title: '默认关闭内嵌字幕',
                      value: _defaultSubtitleOff,
                      icon: Icons.closed_caption_off_rounded,
                      onChanged: _setDefaultSubtitleOff,
                    ),
                    SettingsTile(
                      title: '硬件解码',
                      value:
                          PlaybackSettingsService.hwdecModeLabels[_hwdecMode] ??
                          '自动',
                      icon: Icons.memory_rounded,
                      onTap: _showHwdecModeSheet,
                    ),
                    SettingsTile(
                      title: '视频渲染器',
                      value:
                          PlaybackSettingsService
                              .videoRendererLabels[_videoRenderer] ??
                          '自动',
                      icon: Icons.monitor_rounded,
                      onTap: _showVideoRendererSheet,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('图源搜索'),
                SettingsGroup(
                  children: [
                    SettingsSwitchTile(
                      title: '自动匹配播放源',
                      value: _autoMatchSource,
                      icon: Icons.auto_awesome_rounded,
                      onChanged: _setAutoMatchSource,
                      showDivider: false,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('下载引擎'),
                SettingsGroup(
                  children: [
                    SettingsSwitchTile(
                      title: '启用BT种子下载',
                      value: _enableBtDownload,
                      icon: Icons.download_rounded,
                      onChanged: _setEnableBtDownload,
                      showDivider: false,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('缓存管理'),
                SettingsGroup(
                  children: [
                    SettingsSwitchTile(
                      title: '退出自动清理缓存',
                      value: _clearCacheOnExit,
                      icon: Icons.auto_delete_rounded,
                      onChanged: _setClearCacheOnExit,
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
