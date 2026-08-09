import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/models/subtitle_config.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放器设置持久化服务。
///
/// 集中管理所有播放器设置的读/写逻辑，Widget 层不再直接访问 SharedPreferences。
class PlaybackSettingsService {
  PlaybackSettingsService._();

  static const _defaultDanmakuOffKey = 'player_defaultDanmakuOff';
  static const _defaultPlaybackSpeedKey = 'player_defaultPlaybackSpeed';
  static const _clearCacheOnExitKey = 'app_clearCacheOnExit';
  static const _lowMemoryModeKey = 'app_lowMemoryMode';
  static const _rememberLastPositionKey = 'player_rememberLastPosition';
  static const _autoFullscreenKey = 'player_autoFullscreen';
  static const _enableSkipOpEdKey = 'player_enableSkipOpEd';
  static const _longPressSpeedKey = 'player_longPressSpeed';
  static const _showNextEpisodeButtonKey = 'player_showNextEpisodeButton';
  static const _enableDoubleTapKey = 'player_enableDoubleTap';
  static const _doubleTapActionKey = 'player_doubleTapAction';
  static const _doubleTapSeekDurationKey = 'player_doubleTapSeekDuration';
  static const _showSystemTimeKey = 'player_showSystemTime';
  static const _skipOpWaitTimeKey = 'player_skipOpWaitTime';
  static const _skipOpDurationKey = 'player_skipOpDuration';
  static const _enableAnime4KKey = 'player_enableAnime4K';
  static const _anime4KLevelKey = 'player_anime4KLevel';
  static const _videoEnhancementModeKey = 'player_videoEnhancementMode';
  static const _lastVideoEnhancementModeKey = 'player_lastVideoEnhancementMode';
  static const _showSubtitleKey = 'player_showSubtitle';
  static const _hwdecModeKey = 'player_hwdecMode';
  static const _videoRendererKey = 'player_videoRenderer';

  /// 候选值 → 显示文案。Map 保持插入序，因此 [hwdecModeOptions] 之类的
  /// 下标视图直接由 keys 派生，不再维护第二份平行的字符串字面量。
  static const hwdecModeLabels = <String, String>{
    'auto': '自动',
    'auto-safe': '安全模式',
    'mediacodec-copy': '硬解复制',
    'no': '软件解码',
  };

  static const videoRendererLabels = <String, String>{
    'gpu': 'gpu',
    'gpu-next': 'gpu-next',
    'mediacodec_embed': 'mediacodec_embed',
  };

  static const doubleTapActionLabels = <String, String>{
    'seek': '快进快退',
    'play_pause': '播放暂停',
  };

  static final hwdecModeOptions = hwdecModeLabels.keys.toList(growable: false);
  static final videoRendererOptions = videoRendererLabels.keys.toList(
    growable: false,
  );
  static const _tvHwdecModeOptions = <String>[
    'auto-safe',
    'mediacodec-copy',
    'no',
  ];
  static const _tvHwdecModeLabels = <String, String>{
    'auto-safe': '安全模式',
    'mediacodec-copy': '硬解复制',
    'no': '软件解码',
  };
  static const _androidRendererOptions = <String>['gpu', 'mediacodec_embed'];
  static const _androidRendererLabels = <String, String>{
    'gpu': 'gpu',
    'mediacodec_embed': 'mediacodec_embed',
  };
  static const _desktopRendererOptions = <String>['gpu', 'gpu-next'];
  static const _desktopRendererLabels = <String, String>{
    'gpu': 'gpu',
    'gpu-next': 'gpu-next',
  };

  /// 当前平台可选的硬解模式。
  ///
  /// Android TV 上 `auto`（mpv direct 硬解）会落到不稳定的纹理互操作路径，
  /// [normalizeHwdecMode] 会把它改写成 `mediacodec-copy`；选项列表同步去掉
  /// `auto`，避免 UI 出现不可达档位。
  static List<String> get hwdecModeOptionsForPlatform {
    return Instances.isTV ? _tvHwdecModeOptions : hwdecModeOptions;
  }

  static Map<String, String> get hwdecModeLabelsForPlatform {
    return Instances.isTV ? _tvHwdecModeLabels : hwdecModeLabels;
  }

  /// 当前平台可选的渲染器。
  static List<String> get videoRendererOptionsForPlatform {
    return Platform.isAndroid
        ? _androidRendererOptions
        : _desktopRendererOptions;
  }

  static Map<String, String> get videoRendererLabelsForPlatform {
    return Platform.isAndroid ? _androidRendererLabels : _desktopRendererLabels;
  }

  /// 旧渲染档位迁移到真实 vo 名称：自动/兼容 → gpu，高质量 → gpu-next。
  /// Android 上 gpu-next 不可用，高质量档位直接落到 gpu。
  static const _rendererMigrate = <String, String>{
    'auto': 'gpu',
    'compatibility': 'gpu',
    'quality': 'gpu-next',
  };

  static const defaultPlaybackSpeed = 1.0;
  static const playbackSpeedOptions = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    2.5,
    3.0,
    4.0,
  ];

  static final _speedLabelTrim = RegExp(r'\.?0+$');

  static String normalizeHwdecMode(String? mode) {
    // Android TV 的 Mali-G52 等 GPU 对 direct 硬解纹理互操作不稳定，
    final effective = Instances.isTV && mode == 'auto' ? null : mode;
    if (effective != null && hwdecModeLabels.containsKey(effective)) {
      return effective;
    }
    return Instances.isTV ? 'mediacodec-copy' : 'auto';
  }

  /// [renderer] 归一化到当前平台可用的值；Android 上 gpu-next 不可用，
  /// 存量配置（含旧档位 'quality'）一律迁移到 gpu。
  static String normalizeVideoRenderer(String? renderer, {bool? android}) {
    final isAndroid = android ?? Platform.isAndroid;
    if (renderer == null) return 'gpu';
    final migrated = _rendererMigrate[renderer] ?? renderer;
    if (isAndroid && migrated == 'gpu-next') return 'gpu';
    return videoRendererLabels.containsKey(migrated) ? migrated : 'gpu';
  }

  static double normalizePlaybackSpeed(double? speed) =>
      (speed != null && playbackSpeedOptions.contains(speed))
      ? speed
      : defaultPlaybackSpeed;

  static String formatPlaybackSpeed(double speed) =>
      '${speed.toStringAsFixed(2).replaceFirst(_speedLabelTrim, '')}x';

  static SharedPreferences get _prefs => Instances.sp;

  static bool getClearCacheOnExit() =>
      _prefs.getBool(_clearCacheOnExitKey) ?? false;

  static Future<void> setClearCacheOnExit(bool value) =>
      _prefs.setBool(_clearCacheOnExitKey, value);

  static bool getLowMemoryMode() => _prefs.getBool(_lowMemoryModeKey) ?? false;

  /// 低内存模式的解码图片内存预算。
  ///
  /// 正常值在首次调用时从 Flutter 捕获而不是硬编码，这样关闭低内存模式
  /// 可以精确恢复当前引擎版本提供的预算。
  static const lowMemoryImageCount = 80;
  static const lowMemoryImageBytes = 32 * 1024 * 1024;
  static int? _normalImageCount;
  static int? _normalImageBytes;

  static void applyLowMemoryMode(bool enabled) {
    final cache = PaintingBinding.instance.imageCache;
    _normalImageCount ??= cache.maximumSize;
    _normalImageBytes ??= cache.maximumSizeBytes;

    cache.maximumSize = enabled ? lowMemoryImageCount : _normalImageCount!;
    cache.maximumSizeBytes = enabled ? lowMemoryImageBytes : _normalImageBytes!;

    if (enabled) {
      // 丢弃只被 Flutter live-image 追踪保留的条目；仍在显示的图片
      // 会通过 widget 监听器保持存活。
      cache.clearLiveImages();
    }
  }

  static Future<void> setLowMemoryMode(bool value) async {
    await _prefs.setBool(_lowMemoryModeKey, value);
    applyLowMemoryMode(value);
  }

  static PlaybackPreferences loadAll() {
    final sp = _prefs;
    final enhancementMode = _loadEnhancementMode(sp);
    final storedLastMode = VideoEnhancementMode.fromStorage(
      sp.getString(_lastVideoEnhancementModeKey),
    );
    final lastEnhancementMode = storedLastMode == VideoEnhancementMode.off
        ? (enhancementMode == VideoEnhancementMode.off
              ? _migrateLegacyEnhancementMode(
                  sp.getString(_anime4KLevelKey),
                  enabled: true,
                )
              : enhancementMode)
        : storedLastMode;
    return PlaybackPreferences(
      rememberLastPosition: sp.getBool(_rememberLastPositionKey) ?? true,
      autoFullscreen: sp.getBool(_autoFullscreenKey) ?? false,
      enableSkipOpEd: sp.getBool(_enableSkipOpEdKey) ?? false,
      defaultDanmakuOff: sp.getBool(_defaultDanmakuOffKey) ?? false,
      defaultPlaybackSpeed: normalizePlaybackSpeed(
        sp.getDouble(_defaultPlaybackSpeedKey),
      ),
      longPressSpeed: sp.getDouble(_longPressSpeedKey) ?? 2.0,
      showNextEpisodeButton: sp.getBool(_showNextEpisodeButtonKey) ?? true,
      enableDoubleTap: sp.getBool(_enableDoubleTapKey) ?? true,
      doubleTapAction: sp.getString(_doubleTapActionKey) ?? 'play_pause',
      doubleTapSeekDuration: sp.getInt(_doubleTapSeekDurationKey) ?? 10,
      showSystemTime: sp.getBool(_showSystemTimeKey) ?? false,
      skipOpWaitTime: (sp.getInt(_skipOpWaitTimeKey) ?? 105).clamp(30, 300),
      skipOpDuration: (sp.getInt(_skipOpDurationKey) ?? 85).clamp(30, 300),
      videoEnhancementMode: enhancementMode,
      lastVideoEnhancementMode: lastEnhancementMode,
      showSubtitle: sp.getBool(_showSubtitleKey) ?? true,
      subtitleConfig: SubtitleConfig.load(),
      hwdecMode: normalizeHwdecMode(sp.getString(_hwdecModeKey)),
      videoRenderer: normalizeVideoRenderer(sp.getString(_videoRendererKey)),
    );
  }

  /// 仅持久化 [previous] 与 [next] 之间有差异的字段。
  static Future<void> saveChanges(
    PlaybackPreferences previous,
    PlaybackPreferences next,
  ) {
    if (identical(previous, next) || previous == next) {
      return Future.value();
    }

    final sp = _prefs;
    final writes = <Future<void>>[];

    /// 一个写入器覆盖全部标量类型：SharedPreferences 的四个 setter 由运行时
    /// 类型分派，取代按类型各写一遍的四个同构闭包。
    void write(String key, Object before, Object after) {
      if (before == after) return;
      writes.add(switch (after) {
        final bool value => sp.setBool(key, value),
        final int value => sp.setInt(key, value),
        final double value => sp.setDouble(key, value),
        _ => sp.setString(key, after as String),
      });
    }

    write(
      _rememberLastPositionKey,
      previous.rememberLastPosition,
      next.rememberLastPosition,
    );
    write(_autoFullscreenKey, previous.autoFullscreen, next.autoFullscreen);
    write(_enableSkipOpEdKey, previous.enableSkipOpEd, next.enableSkipOpEd);
    write(
      _defaultDanmakuOffKey,
      previous.defaultDanmakuOff,
      next.defaultDanmakuOff,
    );
    write(
      _defaultPlaybackSpeedKey,
      previous.defaultPlaybackSpeed,
      next.defaultPlaybackSpeed,
    );
    write(_longPressSpeedKey, previous.longPressSpeed, next.longPressSpeed);
    write(
      _showNextEpisodeButtonKey,
      previous.showNextEpisodeButton,
      next.showNextEpisodeButton,
    );
    write(_enableDoubleTapKey, previous.enableDoubleTap, next.enableDoubleTap);
    write(_doubleTapActionKey, previous.doubleTapAction, next.doubleTapAction);
    write(
      _doubleTapSeekDurationKey,
      previous.doubleTapSeekDuration,
      next.doubleTapSeekDuration,
    );
    write(_showSystemTimeKey, previous.showSystemTime, next.showSystemTime);
    write(_skipOpWaitTimeKey, previous.skipOpWaitTime, next.skipOpWaitTime);
    write(_skipOpDurationKey, previous.skipOpDuration, next.skipOpDuration);
    write(
      _videoEnhancementModeKey,
      previous.videoEnhancementMode.storageValue,
      next.videoEnhancementMode.storageValue,
    );
    write(
      _lastVideoEnhancementModeKey,
      previous.lastVideoEnhancementMode.storageValue,
      next.lastVideoEnhancementMode.storageValue,
    );
    write(_showSubtitleKey, previous.showSubtitle, next.showSubtitle);
    write(_hwdecModeKey, previous.hwdecMode, next.hwdecMode);
    write(_videoRendererKey, previous.videoRenderer, next.videoRenderer);

    if (previous.subtitleConfig != next.subtitleConfig) {
      writes.add(next.subtitleConfig.save());
    }

    return writes.isEmpty ? Future.value() : Future.wait(writes);
  }

  static VideoEnhancementMode _loadEnhancementMode(SharedPreferences sp) {
    if (sp.containsKey(_videoEnhancementModeKey)) {
      return VideoEnhancementMode.fromStorage(
        sp.getString(_videoEnhancementModeKey),
      );
    }
    return _migrateLegacyEnhancementMode(
      sp.getString(_anime4KLevelKey),
      enabled: sp.getBool(_enableAnime4KKey) ?? false,
    );
  }

  static VideoEnhancementMode _migrateLegacyEnhancementMode(
    String? level, {
    required bool enabled,
  }) {
    if (!enabled) return VideoEnhancementMode.off;
    return switch (level) {
      'low' => VideoEnhancementMode.low,
      'medium' => VideoEnhancementMode.medium,
      'high' => VideoEnhancementMode.high,
      'ultra' => VideoEnhancementMode.ultra,
      _ => VideoEnhancementMode.medium,
    };
  }
}
