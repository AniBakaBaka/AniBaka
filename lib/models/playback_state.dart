import 'package:baka/models/subtitle_config.dart';
import 'package:flutter/material.dart';

enum SkipState { idle, waiting, showingCancel }

@immutable
class PlaybackCoreState {
  const PlaybackCoreState({
    this.loading = true,
    this.playing = false,
    this.buffering = true,
    this.failed = false,
    this.errorMessage = '',
    this.hasSubtitleTracks = false,
    this.playbackRate = 1.0,
  });

  final bool loading;
  final bool playing;
  final bool buffering;
  final bool failed;
  final String errorMessage;
  final bool hasSubtitleTracks;
  final double playbackRate;

  PlaybackCoreState copyWith({
    bool? loading,
    bool? playing,
    bool? buffering,
    bool? failed,
    String? errorMessage,
    bool? hasSubtitleTracks,
    double? playbackRate,
  }) {
    return PlaybackCoreState(
      loading: loading ?? this.loading,
      playing: playing ?? this.playing,
      buffering: buffering ?? this.buffering,
      failed: failed ?? this.failed,
      errorMessage: errorMessage ?? this.errorMessage,
      hasSubtitleTracks: hasSubtitleTracks ?? this.hasSubtitleTracks,
      playbackRate: playbackRate ?? this.playbackRate,
    );
  }
}

@immutable
class PlaybackTimelineState {
  const PlaybackTimelineState({
    this.position = Duration.zero,
    this.previewPosition = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.seeking = false,
  });

  final Duration position;
  final Duration previewPosition;
  final Duration duration;
  final Duration buffered;
  final bool seeking;

  PlaybackTimelineState copyWith({
    Duration? position,
    Duration? previewPosition,
    Duration? duration,
    Duration? buffered,
    bool? seeking,
  }) {
    return PlaybackTimelineState(
      position: position ?? this.position,
      previewPosition: previewPosition ?? this.previewPosition,
      duration: duration ?? this.duration,
      buffered: buffered ?? this.buffered,
      seeking: seeking ?? this.seeking,
    );
  }
}

@immutable
class PlayerOverlayState {
  const PlayerOverlayState({
    this.controlsVisible = false,
    this.controlsLocked = false,
    this.doubleSpeed = false,
    this.volume = 1.0,
    this.brightness = 0.0,
    this.showDanmaku = true,
    this.showDanmakuInput = false,
    this.skipState = SkipState.idle,
    this.showJumpPrompt = false,
    this.jumpPosition = Duration.zero,
    this.jumpPromptText = '',
  });

  final bool controlsVisible;
  final bool controlsLocked;
  final bool doubleSpeed;
  final double volume;
  final double brightness;
  final bool showDanmaku;
  final bool showDanmakuInput;
  final SkipState skipState;
  final bool showJumpPrompt;
  final Duration jumpPosition;
  final String jumpPromptText;

  PlayerOverlayState copyWith({
    bool? controlsVisible,
    bool? controlsLocked,
    bool? doubleSpeed,
    double? volume,
    double? brightness,
    bool? showDanmaku,
    bool? showDanmakuInput,
    SkipState? skipState,
    bool? showJumpPrompt,
    Duration? jumpPosition,
    String? jumpPromptText,
  }) {
    return PlayerOverlayState(
      controlsVisible: controlsVisible ?? this.controlsVisible,
      controlsLocked: controlsLocked ?? this.controlsLocked,
      doubleSpeed: doubleSpeed ?? this.doubleSpeed,
      volume: volume ?? this.volume,
      brightness: brightness ?? this.brightness,
      showDanmaku: showDanmaku ?? this.showDanmaku,
      showDanmakuInput: showDanmakuInput ?? this.showDanmakuInput,
      skipState: skipState ?? this.skipState,
      showJumpPrompt: showJumpPrompt ?? this.showJumpPrompt,
      jumpPosition: jumpPosition ?? this.jumpPosition,
      jumpPromptText: jumpPromptText ?? this.jumpPromptText,
    );
  }
}

@immutable
class PlaybackPreferences {
  const PlaybackPreferences({
    this.rememberLastPosition = true,
    this.autoFullscreen = false,
    this.enableSkipOpEd = false,
    this.defaultDanmakuOff = false,
    this.defaultPlaybackSpeed = 1.0,
    this.longPressSpeed = 2.0,
    this.showNextEpisodeButton = true,
    this.enableDoubleTap = true,
    this.doubleTapAction = 'play_pause',
    this.doubleTapSeekDuration = 10,
    this.showSystemTime = false,
    this.skipOpWaitTime = 105,
    this.skipOpDuration = 85,
    this.enableAnime4K = false,
    this.anime4KLevel = 'medium',
    this.showSubtitle = true,
    this.subtitleConfig = const SubtitleConfig(),
    this.videoFit = BoxFit.contain,
    this.videoFitDescription = '\u753b\u9762',
    this.hwdecMode = 'auto',
    this.videoRenderer = 'auto',
  });

  final bool rememberLastPosition;
  final bool autoFullscreen;
  final bool enableSkipOpEd;
  final bool defaultDanmakuOff;
  final double defaultPlaybackSpeed;
  final double longPressSpeed;
  final bool showNextEpisodeButton;
  final bool enableDoubleTap;
  final String doubleTapAction;
  final int doubleTapSeekDuration;
  final bool showSystemTime;
  final int skipOpWaitTime;
  final int skipOpDuration;
  final bool enableAnime4K;
  final String anime4KLevel;
  final bool showSubtitle;
  final SubtitleConfig subtitleConfig;
  final BoxFit videoFit;
  final String videoFitDescription;
  final String hwdecMode;
  final String videoRenderer;

  PlaybackPreferences copyWith({
    bool? rememberLastPosition,
    bool? autoFullscreen,
    bool? enableSkipOpEd,
    bool? defaultDanmakuOff,
    double? defaultPlaybackSpeed,
    double? longPressSpeed,
    bool? showNextEpisodeButton,
    bool? enableDoubleTap,
    String? doubleTapAction,
    int? doubleTapSeekDuration,
    bool? showSystemTime,
    int? skipOpWaitTime,
    int? skipOpDuration,
    bool? enableAnime4K,
    String? anime4KLevel,
    bool? showSubtitle,
    SubtitleConfig? subtitleConfig,
    BoxFit? videoFit,
    String? videoFitDescription,
    String? hwdecMode,
    String? videoRenderer,
  }) {
    return PlaybackPreferences(
      rememberLastPosition: rememberLastPosition ?? this.rememberLastPosition,
      autoFullscreen: autoFullscreen ?? this.autoFullscreen,
      enableSkipOpEd: enableSkipOpEd ?? this.enableSkipOpEd,
      defaultDanmakuOff: defaultDanmakuOff ?? this.defaultDanmakuOff,
      defaultPlaybackSpeed: defaultPlaybackSpeed ?? this.defaultPlaybackSpeed,
      longPressSpeed: longPressSpeed ?? this.longPressSpeed,
      showNextEpisodeButton:
          showNextEpisodeButton ?? this.showNextEpisodeButton,
      enableDoubleTap: enableDoubleTap ?? this.enableDoubleTap,
      doubleTapAction: doubleTapAction ?? this.doubleTapAction,
      doubleTapSeekDuration:
          doubleTapSeekDuration ?? this.doubleTapSeekDuration,
      showSystemTime: showSystemTime ?? this.showSystemTime,
      skipOpWaitTime: skipOpWaitTime ?? this.skipOpWaitTime,
      skipOpDuration: skipOpDuration ?? this.skipOpDuration,
      enableAnime4K: enableAnime4K ?? this.enableAnime4K,
      anime4KLevel: anime4KLevel ?? this.anime4KLevel,
      showSubtitle: showSubtitle ?? this.showSubtitle,
      subtitleConfig: subtitleConfig ?? this.subtitleConfig,
      videoFit: videoFit ?? this.videoFit,
      videoFitDescription: videoFitDescription ?? this.videoFitDescription,
      hwdecMode: hwdecMode ?? this.hwdecMode,
      videoRenderer: videoRenderer ?? this.videoRenderer,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackPreferences &&
          rememberLastPosition == other.rememberLastPosition &&
          autoFullscreen == other.autoFullscreen &&
          enableSkipOpEd == other.enableSkipOpEd &&
          defaultDanmakuOff == other.defaultDanmakuOff &&
          defaultPlaybackSpeed == other.defaultPlaybackSpeed &&
          longPressSpeed == other.longPressSpeed &&
          showNextEpisodeButton == other.showNextEpisodeButton &&
          enableDoubleTap == other.enableDoubleTap &&
          doubleTapAction == other.doubleTapAction &&
          doubleTapSeekDuration == other.doubleTapSeekDuration &&
          showSystemTime == other.showSystemTime &&
          skipOpWaitTime == other.skipOpWaitTime &&
          skipOpDuration == other.skipOpDuration &&
          enableAnime4K == other.enableAnime4K &&
          anime4KLevel == other.anime4KLevel &&
          showSubtitle == other.showSubtitle &&
          subtitleConfig == other.subtitleConfig &&
          videoFit == other.videoFit &&
          videoFitDescription == other.videoFitDescription &&
          hwdecMode == other.hwdecMode &&
          videoRenderer == other.videoRenderer;

  @override
  int get hashCode => Object.hashAll([
    rememberLastPosition,
    autoFullscreen,
    enableSkipOpEd,
    defaultDanmakuOff,
    defaultPlaybackSpeed,
    longPressSpeed,
    showNextEpisodeButton,
    enableDoubleTap,
    doubleTapAction,
    doubleTapSeekDuration,
    showSystemTime,
    skipOpWaitTime,
    skipOpDuration,
    enableAnime4K,
    anime4KLevel,
    showSubtitle,
    subtitleConfig,
    videoFit,
    videoFitDescription,
    hwdecMode,
    videoRenderer,
  ]);
}

@immutable
class PlaybackMediaInfo {
  const PlaybackMediaInfo({
    this.title = '',
    this.episode = '',
    this.imageUrl = '',
    this.episodeIndex = 0,
    this.totalEpisodes = 0,
  });

  final String title;
  final String episode;
  final String imageUrl;
  final int episodeIndex;
  final int totalEpisodes;
}
