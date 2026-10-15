import 'dart:io';
import 'dart:convert';

import 'package:flutter/painting.dart';

import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/models/subtitle_config.dart';

/// 播放器设置持久化服务
class PlaybackSettingsService {
  PlaybackSettingsService._();

  static const _subtitleSettingsKey = 'subtitle_settings';

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
  static const _videoEnhancementModeKey = 'player_videoEnhancementMode';
  static const _lastVideoEnhancementModeKey = 'player_lastVideoEnhancementMode';
  static const _showSubtitleKey = 'player_showSubtitle';
  static const _hwdecModeKey = 'player_hwdecMode';
  static const _videoRendererKey = 'player_videoRenderer';
  static const _filterHlsAdsKey = 'player_filterHlsAds';

  static const _tvHwdecModeLabels = <String, String>{
    'auto-safe': '安全模式',
    'mediacodec-copy': '硬解复制',
    'no': '软件解码',
  };

  static const hwdecModeLabels = {'auto': '自动', ..._tvHwdecModeLabels};

  static const videoRendererLabels = {
    'gpu': 'gpu',
    'gpu-next': 'gpu-next',
    'mediacodec_embed': 'mediacodec_embed',
  };

  static const doubleTapActionLabels = <String, String>{
    'seek': '快进快退',
    'play_pause': '播放暂停',
  };

  static final _hwdecModes = hwdecModeLabels.keys.toList(growable: false);
  static final _tvHwdecModes = _tvHwdecModeLabels.keys.toList(growable: false);

  static List<String> get hwdecModeOptionsForPlatform =>
      Instances.isTV ? _tvHwdecModes : _hwdecModes;

  static Map<String, String> get hwdecModeLabelsForPlatform =>
      Instances.isTV ? _tvHwdecModeLabels : hwdecModeLabels;

  static final videoRendererLabelsForPlatform = {
    for (final entry in videoRendererLabels.entries)
      if (entry.key != (Platform.isAndroid ? 'gpu-next' : 'mediacodec_embed'))
        entry.key: entry.value,
  };

  static final videoRendererOptionsForPlatform = videoRendererLabelsForPlatform
      .keys
      .toList(growable: false);

  static const _defaults = PlaybackPreferences();
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
    final effective = Instances.isTV && mode == 'auto' ? null : mode;
    if (effective != null && hwdecModeLabels.containsKey(effective)) {
      return effective;
    }
    return Instances.isTV ? 'mediacodec-copy' : 'auto';
  }

  static String normalizeVideoRenderer(String? renderer, {bool? android}) {
    final isAndroid = android ?? Platform.isAndroid;
    return switch (renderer) {
      'quality' || 'gpu-next' => isAndroid ? 'gpu' : 'gpu-next',
      'mediacodec_embed' => 'mediacodec_embed',
      _ => 'gpu',
    };
  }

  static double normalizePlaybackSpeed(double? speed) =>
      (speed != null && playbackSpeedOptions.contains(speed))
      ? speed
      : _defaults.defaultPlaybackSpeed;

  static String formatPlaybackSpeed(double speed) =>
      '${speed.toStringAsFixed(2).replaceFirst(_speedLabelTrim, '')}x';

  static bool getClearCacheOnExit() =>
      Instances.sp.getBool(_clearCacheOnExitKey) ?? false;

  static Future<void> setClearCacheOnExit(bool value) =>
      Instances.sp.setBool(_clearCacheOnExitKey, value);

  static bool getLowMemoryMode() =>
      Instances.sp.getBool(_lowMemoryModeKey) ?? false;

  /// 未设置时遵循视频源默认值；用户明确关闭时覆盖规则的自动开启。
  static bool? getFilterHlsAdsOverride() =>
      Instances.sp.getBool(_filterHlsAdsKey);

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
    if (enabled) cache.clearLiveImages();
  }

  static Future<void> setLowMemoryMode(bool value) async {
    await Instances.sp.setBool(_lowMemoryModeKey, value);
    applyLowMemoryMode(value);
  }

  static PlaybackPreferences loadAll() {
    final sp = Instances.sp;
    final subtitles = sp.getString(_subtitleSettingsKey);
    final storedMode = sp.getString(_videoEnhancementModeKey);
    var enhancementMode = VideoEnhancementMode.fromStorage(storedMode);
    var lastEnhancementMode = VideoEnhancementMode.fromStorage(
      sp.getString(
        storedMode == null
            ? 'player_anime4KLevel'
            : _lastVideoEnhancementModeKey,
      ),
    );
    if (lastEnhancementMode == VideoEnhancementMode.off) {
      lastEnhancementMode = enhancementMode == VideoEnhancementMode.off
          ? _defaults.lastVideoEnhancementMode
          : enhancementMode;
    }
    if (storedMode == null && sp.getBool('player_enableAnime4K') == true) {
      enhancementMode = lastEnhancementMode;
    }

    return PlaybackPreferences(
      rememberLastPosition:
          sp.getBool(_rememberLastPositionKey) ??
          _defaults.rememberLastPosition,
      autoFullscreen:
          sp.getBool(_autoFullscreenKey) ?? _defaults.autoFullscreen,
      enableSkipOpEd:
          sp.getBool(_enableSkipOpEdKey) ?? _defaults.enableSkipOpEd,
      defaultDanmakuOff:
          sp.getBool(_defaultDanmakuOffKey) ?? _defaults.defaultDanmakuOff,
      defaultPlaybackSpeed: normalizePlaybackSpeed(
        sp.getDouble(_defaultPlaybackSpeedKey),
      ),
      longPressSpeed:
          sp.getDouble(_longPressSpeedKey) ?? _defaults.longPressSpeed,
      showNextEpisodeButton:
          sp.getBool(_showNextEpisodeButtonKey) ??
          _defaults.showNextEpisodeButton,
      enableDoubleTap:
          sp.getBool(_enableDoubleTapKey) ?? _defaults.enableDoubleTap,
      doubleTapAction:
          sp.getString(_doubleTapActionKey) ?? _defaults.doubleTapAction,
      doubleTapSeekDuration:
          sp.getInt(_doubleTapSeekDurationKey) ??
          _defaults.doubleTapSeekDuration,
      showSystemTime:
          sp.getBool(_showSystemTimeKey) ?? _defaults.showSystemTime,
      videoEnhancementMode: enhancementMode,
      lastVideoEnhancementMode: lastEnhancementMode,
      showSubtitle: sp.getBool(_showSubtitleKey) ?? _defaults.showSubtitle,
      subtitleConfig: subtitles == null
          ? _defaults.subtitleConfig
          : SubtitleConfig.fromJson(
              jsonDecode(subtitles) as Map<String, dynamic>,
            ),
      hwdecMode: normalizeHwdecMode(sp.getString(_hwdecModeKey)),
      videoRenderer: normalizeVideoRenderer(sp.getString(_videoRendererKey)),
      filterHlsAds: sp.getBool(_filterHlsAdsKey) ?? _defaults.filterHlsAds,
    );
  }

  static Future<void> saveChanges(
    PlaybackPreferences previous,
    PlaybackPreferences next,
  ) {
    if (identical(previous, next)) {
      return Future.value();
    }

    final sp = Instances.sp;
    List<Future<bool>>? writes;

    void write(String key, Object before, Object after) {
      if (before == after) return;
      final pending = writes ??= [];
      if (after is bool) {
        pending.add(sp.setBool(key, after));
      } else if (after is int) {
        pending.add(sp.setInt(key, after));
      } else if (after is double) {
        pending.add(sp.setDouble(key, after));
      } else if (after is String) {
        pending.add(sp.setString(key, after));
      }
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
    write(_filterHlsAdsKey, previous.filterHlsAds, next.filterHlsAds);

    if (previous.subtitleConfig != next.subtitleConfig) {
      (writes ??= []).add(
        sp.setString(
          _subtitleSettingsKey,
          jsonEncode(next.subtitleConfig.toJson()),
        ),
      );
    }

    return writes == null ? Future.value() : Future.wait(writes!);
  }
}
