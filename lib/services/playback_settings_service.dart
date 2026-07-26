import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/models/subtitle_config.dart';
import 'package:baka/services/low_memory_mode_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放器设置持久化服务。
///
/// 集中管理所有播放器设置的读/写逻辑，Widget 层不再直接访问 SharedPreferences。
class PlaybackSettingsService {
  PlaybackSettingsService._();

  static const _defaultDanmakuOffKey = 'player_defaultDanmakuOff';
  static const _defaultSubtitleOffKey = 'player_defaultSubtitleOff';
  static const _defaultPlaybackSpeedKey = 'player_defaultPlaybackSpeed';
  static const _clearCacheOnExitKey = 'app_clearCacheOnExit';
  static const _lowMemoryModeKey = 'app_lowMemoryMode';
  static const _enableBtDownloadKey = 'player_enableBtDownload';
  static const _autoMatchSourceKey = 'player_autoMatchSource';
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
  static const _showSubtitleKey = 'player_showSubtitle';
  static const _hwdecModeKey = 'player_hwdecMode';
  static const _videoRendererKey = 'player_videoRenderer';

  /// 候选值 → 显示文案。Map 保持插入序，因此 [hwdecModeOptions] 之类的
  /// 下标视图直接由 keys 派生，不再维护第二份平行的字符串字面量。
  static const hwdecModeLabels = <String, String>{
    'auto': '自动',
    'auto-safe': '安全模式',
    'no': '软件解码',
  };

  static const videoRendererLabels = <String, String>{
    'auto': '自动',
    'compatibility': 'GPU 兼容',
    'quality': 'GPU 高质量',
  };

  static const doubleTapActionLabels = <String, String>{
    'seek': '快进快退',
    'play_pause': '播放暂停',
  };

  static final hwdecModeOptions = hwdecModeLabels.keys.toList(growable: false);
  static final videoRendererOptions = videoRendererLabels.keys.toList(
    growable: false,
  );

  /// 旧 vo=gpu / gpu-next 迁移到 libmpv 渲染档位。
  static const _rendererMigrate = <String, String>{
    'gpu': 'compatibility',
    'gpu-next': 'quality',
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
    if (mode != null && hwdecModeLabels.containsKey(mode)) return mode;
    return Instances.isTV ? 'auto-safe' : 'auto';
  }

  static String normalizeVideoRenderer(String? renderer) {
    if (renderer == null) return 'auto';
    return _rendererMigrate[renderer] ??
        (videoRendererLabels.containsKey(renderer) ? renderer : 'auto');
  }

  static double normalizePlaybackSpeed(double? speed) =>
      (speed != null && playbackSpeedOptions.contains(speed))
      ? speed
      : defaultPlaybackSpeed;

  static String formatPlaybackSpeed(double speed) =>
      '${speed.toStringAsFixed(2).replaceFirst(_speedLabelTrim, '')}x';

  static SharedPreferences get _prefs => Instances.sp;

  static bool getDefaultDanmakuOff() =>
      _prefs.getBool(_defaultDanmakuOffKey) ?? false;

  static Future<void> setDefaultDanmakuOff(bool value) =>
      _prefs.setBool(_defaultDanmakuOffKey, value);

  static double getDefaultPlaybackSpeed() =>
      normalizePlaybackSpeed(_prefs.getDouble(_defaultPlaybackSpeedKey));

  static Future<void> setDefaultPlaybackSpeed(double speed) =>
      _prefs.setDouble(_defaultPlaybackSpeedKey, normalizePlaybackSpeed(speed));

  static bool getDefaultSubtitleOff() =>
      _prefs.getBool(_defaultSubtitleOffKey) ?? false;

  static Future<void> setDefaultSubtitleOff(bool value) =>
      _prefs.setBool(_defaultSubtitleOffKey, value);

  static bool getEnableBtDownload() =>
      _prefs.getBool(_enableBtDownloadKey) ?? true;

  static Future<void> setEnableBtDownload(bool value) =>
      _prefs.setBool(_enableBtDownloadKey, value);

  static bool getClearCacheOnExit() =>
      _prefs.getBool(_clearCacheOnExitKey) ?? false;

  static Future<void> setClearCacheOnExit(bool value) =>
      _prefs.setBool(_clearCacheOnExitKey, value);

  static bool getLowMemoryMode() => _prefs.getBool(_lowMemoryModeKey) ?? false;

  static Future<void> setLowMemoryMode(bool value) async {
    await _prefs.setBool(_lowMemoryModeKey, value);
    LowMemoryModeService.apply(value);
  }

  static bool getAutoMatchSource() =>
      _prefs.getBool(_autoMatchSourceKey) ?? true;

  static Future<void> setAutoMatchSource(bool value) =>
      _prefs.setBool(_autoMatchSourceKey, value);

  static String getHwdecMode() =>
      normalizeHwdecMode(_prefs.getString(_hwdecModeKey));

  static Future<void> setHwdecMode(String mode) =>
      _prefs.setString(_hwdecModeKey, normalizeHwdecMode(mode));

  static String getVideoRenderer() =>
      normalizeVideoRenderer(_prefs.getString(_videoRendererKey));

  static Future<void> setVideoRenderer(String renderer) =>
      _prefs.setString(_videoRendererKey, normalizeVideoRenderer(renderer));

  static Future<PlaybackPreferences> loadAll() async {
    final sp = _prefs;
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
      enableAnime4K: sp.getBool(_enableAnime4KKey) ?? false,
      anime4KLevel: sp.getString(_anime4KLevelKey) ?? 'medium',
      showSubtitle: sp.getBool(_showSubtitleKey) ?? true,
      subtitleConfig: await SubtitleConfig.load(),
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
    write(_enableAnime4KKey, previous.enableAnime4K, next.enableAnime4K);
    write(_anime4KLevelKey, previous.anime4KLevel, next.anime4KLevel);
    write(_showSubtitleKey, previous.showSubtitle, next.showSubtitle);
    write(_hwdecModeKey, previous.hwdecMode, next.hwdecMode);
    write(_videoRendererKey, previous.videoRenderer, next.videoRenderer);

    if (previous.subtitleConfig != next.subtitleConfig) {
      writes.add(next.subtitleConfig.save());
    }

    return writes.isEmpty ? Future.value() : Future.wait(writes);
  }
}
