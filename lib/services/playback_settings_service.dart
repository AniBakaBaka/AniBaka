import 'package:baka/instance.dart';
import 'package:baka/models/subtitle_config.dart';
import 'package:baka/models/playback_state.dart';

/// 播放器设置持久化服务。
///
/// 集中管理所有播放器设置的读/写逻辑，Widget 层不再直接访问 SharedPreferences。
class PlaybackSettingsService {
  PlaybackSettingsService._();

  static const String _defaultDanmakuOffKey = 'player_defaultDanmakuOff';
  static const String _defaultSubtitleOffKey = 'player_defaultSubtitleOff';
  static const String _defaultPlaybackSpeedKey = 'player_defaultPlaybackSpeed';
  static const String _clearCacheOnExitKey = 'app_clearCacheOnExit';
  static const String _enableBtDownloadKey = 'player_enableBtDownload';
  static const String _autoMatchSourceKey = 'player_autoMatchSource';
  static const String _rememberLastPositionKey = 'player_rememberLastPosition';
  static const String _autoFullscreenKey = 'player_autoFullscreen';
  static const String _enableSkipOpEdKey = 'player_enableSkipOpEd';
  static const String _longPressSpeedKey = 'player_longPressSpeed';
  static const String _showNextEpisodeButtonKey =
      'player_showNextEpisodeButton';
  static const String _enableDoubleTapKey = 'player_enableDoubleTap';
  static const String _doubleTapActionKey = 'player_doubleTapAction';
  static const String _doubleTapSeekDurationKey =
      'player_doubleTapSeekDuration';
  static const String _showSystemTimeKey = 'player_showSystemTime';
  static const String _skipOpWaitTimeKey = 'player_skipOpWaitTime';
  static const String _skipOpDurationKey = 'player_skipOpDuration';
  static const String _enableAnime4KKey = 'player_enableAnime4K';
  static const String _anime4KLevelKey = 'player_anime4KLevel';
  static const String _showSubtitleKey = 'player_showSubtitle';

  static const double defaultPlaybackSpeed = 1.0;
  static const List<double> playbackSpeedOptions = <double>[
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

  static double normalizePlaybackSpeed(double? speed) {
    if (speed == null) return defaultPlaybackSpeed;
    if (playbackSpeedOptions.contains(speed)) return speed;
    return defaultPlaybackSpeed;
  }

  static String formatPlaybackSpeed(double speed) {
    final label = speed.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
    return '${label}x';
  }

  static bool getDefaultDanmakuOff() =>
      Instances.sp.getBool(_defaultDanmakuOffKey) ?? false;

  static Future<void> setDefaultDanmakuOff(bool value) =>
      Instances.sp.setBool(_defaultDanmakuOffKey, value);

  static double getDefaultPlaybackSpeed() =>
      normalizePlaybackSpeed(Instances.sp.getDouble(_defaultPlaybackSpeedKey));

  static Future<void> setDefaultPlaybackSpeed(double speed) => Instances.sp
      .setDouble(_defaultPlaybackSpeedKey, normalizePlaybackSpeed(speed));

  static bool getDefaultSubtitleOff() =>
      Instances.sp.getBool(_defaultSubtitleOffKey) ?? false;

  static Future<void> setDefaultSubtitleOff(bool value) =>
      Instances.sp.setBool(_defaultSubtitleOffKey, value);

  static bool getEnableBtDownload() =>
      Instances.sp.getBool(_enableBtDownloadKey) ?? true;

  static Future<void> setEnableBtDownload(bool value) =>
      Instances.sp.setBool(_enableBtDownloadKey, value);

  static bool getClearCacheOnExit() =>
      Instances.sp.getBool(_clearCacheOnExitKey) ?? false;

  static Future<void> setClearCacheOnExit(bool value) =>
      Instances.sp.setBool(_clearCacheOnExitKey, value);

  static bool getAutoMatchSource() =>
      Instances.sp.getBool(_autoMatchSourceKey) ?? true;

  static Future<void> setAutoMatchSource(bool value) =>
      Instances.sp.setBool(_autoMatchSourceKey, value);

  static Future<PlaybackPreferences> loadAll() async {
    final sp = Instances.sp;
    final subtitleConfig = await SubtitleConfig.load();

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
      subtitleConfig: subtitleConfig,
    );
  }

  static Future<void> saveChanges(
    PlaybackPreferences previous,
    PlaybackPreferences next,
  ) {
    final sp = Instances.sp;
    final writes = <Future<dynamic>>[];
    if (previous.rememberLastPosition != next.rememberLastPosition) {
      writes.add(
        sp.setBool(_rememberLastPositionKey, next.rememberLastPosition),
      );
    }
    if (previous.autoFullscreen != next.autoFullscreen) {
      writes.add(sp.setBool(_autoFullscreenKey, next.autoFullscreen));
    }
    if (previous.enableSkipOpEd != next.enableSkipOpEd) {
      writes.add(sp.setBool(_enableSkipOpEdKey, next.enableSkipOpEd));
    }
    if (previous.defaultDanmakuOff != next.defaultDanmakuOff) {
      writes.add(sp.setBool(_defaultDanmakuOffKey, next.defaultDanmakuOff));
    }
    if (previous.defaultPlaybackSpeed != next.defaultPlaybackSpeed) {
      writes.add(
        sp.setDouble(_defaultPlaybackSpeedKey, next.defaultPlaybackSpeed),
      );
    }
    if (previous.longPressSpeed != next.longPressSpeed) {
      writes.add(sp.setDouble(_longPressSpeedKey, next.longPressSpeed));
    }
    if (previous.showNextEpisodeButton != next.showNextEpisodeButton) {
      writes.add(
        sp.setBool(_showNextEpisodeButtonKey, next.showNextEpisodeButton),
      );
    }
    if (previous.enableDoubleTap != next.enableDoubleTap) {
      writes.add(sp.setBool(_enableDoubleTapKey, next.enableDoubleTap));
    }
    if (previous.doubleTapAction != next.doubleTapAction) {
      writes.add(sp.setString(_doubleTapActionKey, next.doubleTapAction));
    }
    if (previous.doubleTapSeekDuration != next.doubleTapSeekDuration) {
      writes.add(
        sp.setInt(_doubleTapSeekDurationKey, next.doubleTapSeekDuration),
      );
    }
    if (previous.showSystemTime != next.showSystemTime) {
      writes.add(sp.setBool(_showSystemTimeKey, next.showSystemTime));
    }
    if (previous.skipOpWaitTime != next.skipOpWaitTime) {
      writes.add(sp.setInt(_skipOpWaitTimeKey, next.skipOpWaitTime));
    }
    if (previous.skipOpDuration != next.skipOpDuration) {
      writes.add(sp.setInt(_skipOpDurationKey, next.skipOpDuration));
    }
    if (previous.enableAnime4K != next.enableAnime4K) {
      writes.add(sp.setBool(_enableAnime4KKey, next.enableAnime4K));
    }
    if (previous.anime4KLevel != next.anime4KLevel) {
      writes.add(sp.setString(_anime4KLevelKey, next.anime4KLevel));
    }
    if (previous.showSubtitle != next.showSubtitle) {
      writes.add(sp.setBool(_showSubtitleKey, next.showSubtitle));
    }
    if (previous.subtitleConfig != next.subtitleConfig) {
      writes.add(next.subtitleConfig.save());
    }
    return Future.wait(writes);
  }

  static Future<void> setShowSubtitle(bool value) =>
      Instances.sp.setBool(_showSubtitleKey, value);
}
