import 'package:baka/models/subtitle_config.dart';
import 'package:flutter/material.dart';

enum SkipState { idle, waiting, showingCancel, ending }

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
  }) => PlaybackCoreState(
    loading: loading ?? this.loading,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    failed: failed ?? this.failed,
    errorMessage: errorMessage ?? this.errorMessage,
    hasSubtitleTracks: hasSubtitleTracks ?? this.hasSubtitleTracks,
    playbackRate: playbackRate ?? this.playbackRate,
  );
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
  }) => PlaybackTimelineState(
    position: position ?? this.position,
    previewPosition: previewPosition ?? this.previewPosition,
    duration: duration ?? this.duration,
    buffered: buffered ?? this.buffered,
    seeking: seeking ?? this.seeking,
  );
}

@immutable
class PlayerOverlayState {
  const PlayerOverlayState({
    this.controlsVisible = false,
    this.controlsLocked = false,
    this.doubleSpeed = false,
    this.longPressRate = 1.0,
    this.volume = 1.0,
    this.brightness = 0.0,
    this.showDanmaku = true,
    this.showDanmakuInput = false,
    this.skipState = SkipState.idle,
    this.skipLabel = '片头',
    this.skipWasAutomatic = false,
    this.showSkipSuggestion = false,
  });

  final bool controlsVisible;
  final bool controlsLocked;
  final bool doubleSpeed;
  final double longPressRate;
  final double volume;
  final double brightness;
  final bool showDanmaku;
  final bool showDanmakuInput;
  final SkipState skipState;
  final String skipLabel;
  final bool skipWasAutomatic;
  final bool showSkipSuggestion;

  PlayerOverlayState copyWith({
    bool? controlsVisible,
    bool? controlsLocked,
    bool? doubleSpeed,
    double? longPressRate,
    double? volume,
    double? brightness,
    bool? showDanmaku,
    bool? showDanmakuInput,
    SkipState? skipState,
    String? skipLabel,
    bool? skipWasAutomatic,
    bool? showSkipSuggestion,
  }) => PlayerOverlayState(
    controlsVisible: controlsVisible ?? this.controlsVisible,
    controlsLocked: controlsLocked ?? this.controlsLocked,
    doubleSpeed: doubleSpeed ?? this.doubleSpeed,
    longPressRate: longPressRate ?? this.longPressRate,
    volume: volume ?? this.volume,
    brightness: brightness ?? this.brightness,
    showDanmaku: showDanmaku ?? this.showDanmaku,
    showDanmakuInput: showDanmakuInput ?? this.showDanmakuInput,
    skipState: skipState ?? this.skipState,
    skipLabel: skipLabel ?? this.skipLabel,
    skipWasAutomatic: skipWasAutomatic ?? this.skipWasAutomatic,
    showSkipSuggestion: showSkipSuggestion ?? this.showSkipSuggestion,
  );
}

enum VideoEnhancementMode {
  off,
  low,
  medium,
  high,
  ultra;

  static VideoEnhancementMode fromStorage(String? value) => switch (value) {
    'low' => low,
    'medium' => medium,
    'high' => high,
    'ultra' => ultra,
    'auto' || 'anime4kSoft' => medium,
    'anibakaClear' => low,
    'anime4kStrong' => high,
    _ => off,
  };

  String get storageValue => name;

  String get label => switch (this) {
    off => '关闭',
    low => '低',
    medium => '中',
    high => '高',
    ultra => '超高',
  };
}

@immutable
class VideoEnhancementState {
  const VideoEnhancementState({
    this.requestedMode = VideoEnhancementMode.off,
    this.appliedPipeline = VideoEnhancementMode.off,
    this.fallbackReason,
  });

  final VideoEnhancementMode requestedMode;
  final VideoEnhancementMode appliedPipeline;
  final String? fallbackReason;

  bool get enabled => appliedPipeline != VideoEnhancementMode.off;
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
    this.videoEnhancementMode = VideoEnhancementMode.off,
    this.lastVideoEnhancementMode = VideoEnhancementMode.medium,
    this.showSubtitle = true,
    this.subtitleConfig = const SubtitleConfig(),
    this.videoFit = BoxFit.contain,
    this.videoFitDescription = '画面',
    this.hwdecMode = 'auto',
    this.videoRenderer = 'gpu',
    this.filterHlsAds = false,
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
  final VideoEnhancementMode videoEnhancementMode;
  final VideoEnhancementMode lastVideoEnhancementMode;
  final bool showSubtitle;
  final SubtitleConfig subtitleConfig;
  final BoxFit videoFit;
  final String videoFitDescription;
  final String hwdecMode;
  final String videoRenderer;
  final bool filterHlsAds;

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
    VideoEnhancementMode? videoEnhancementMode,
    VideoEnhancementMode? lastVideoEnhancementMode,
    bool? showSubtitle,
    SubtitleConfig? subtitleConfig,
    BoxFit? videoFit,
    String? videoFitDescription,
    String? hwdecMode,
    String? videoRenderer,
    bool? filterHlsAds,
  }) => PlaybackPreferences(
    rememberLastPosition: rememberLastPosition ?? this.rememberLastPosition,
    autoFullscreen: autoFullscreen ?? this.autoFullscreen,
    enableSkipOpEd: enableSkipOpEd ?? this.enableSkipOpEd,
    defaultDanmakuOff: defaultDanmakuOff ?? this.defaultDanmakuOff,
    defaultPlaybackSpeed: defaultPlaybackSpeed ?? this.defaultPlaybackSpeed,
    longPressSpeed: longPressSpeed ?? this.longPressSpeed,
    showNextEpisodeButton: showNextEpisodeButton ?? this.showNextEpisodeButton,
    enableDoubleTap: enableDoubleTap ?? this.enableDoubleTap,
    doubleTapAction: doubleTapAction ?? this.doubleTapAction,
    doubleTapSeekDuration: doubleTapSeekDuration ?? this.doubleTapSeekDuration,
    showSystemTime: showSystemTime ?? this.showSystemTime,
    videoEnhancementMode: videoEnhancementMode ?? this.videoEnhancementMode,
    lastVideoEnhancementMode:
        lastVideoEnhancementMode ?? this.lastVideoEnhancementMode,
    showSubtitle: showSubtitle ?? this.showSubtitle,
    subtitleConfig: subtitleConfig ?? this.subtitleConfig,
    videoFit: videoFit ?? this.videoFit,
    videoFitDescription: videoFitDescription ?? this.videoFitDescription,
    hwdecMode: hwdecMode ?? this.hwdecMode,
    videoRenderer: videoRenderer ?? this.videoRenderer,
    filterHlsAds: filterHlsAds ?? this.filterHlsAds,
  );

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
          videoEnhancementMode == other.videoEnhancementMode &&
          lastVideoEnhancementMode == other.lastVideoEnhancementMode &&
          showSubtitle == other.showSubtitle &&
          subtitleConfig == other.subtitleConfig &&
          videoFit == other.videoFit &&
          videoFitDescription == other.videoFitDescription &&
          hwdecMode == other.hwdecMode &&
          videoRenderer == other.videoRenderer &&
          filterHlsAds == other.filterHlsAds;

  @override
  int get hashCode => Object.hash(
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
    videoEnhancementMode,
    lastVideoEnhancementMode,
    showSubtitle,
    subtitleConfig,
    videoFit,
    videoFitDescription,
    Object.hash(hwdecMode, videoRenderer, filterHlsAds),
  );
}

@immutable
class PlaybackMediaInfo {
  const PlaybackMediaInfo({
    this.title = '',
    this.episode = '',
    this.imageUrl = '',
    this.logoUrl = '',
    this.episodeIndex = 0,
    this.totalEpisodes = 0,
  });

  final String title;
  final String episode;
  final String imageUrl;
  final String logoUrl;
  final int episodeIndex;
  final int totalEpisodes;
}

@immutable
class PlaybackTechnicalInfo {
  const PlaybackTechnicalInfo({
    this.width,
    this.height,
    this.framesPerSecond,
    this.videoBitrate,
    this.videoCodec,
    this.hardwareDecoder,
    this.videoOutput,
    this.audioBitrate,
    this.audioChannels,
    this.audioCodec,
    this.rendererProfile = 'gpu',
    this.appliedEnhancementPipeline = VideoEnhancementMode.off,
    this.frameDropCount,
    this.delayedFrameCount,
  });

  final int? width;
  final int? height;
  final double? framesPerSecond;
  final int? videoBitrate;
  final String? videoCodec;
  final String? hardwareDecoder;
  final String? videoOutput;
  final int? audioBitrate;
  final int? audioChannels;
  final String? audioCodec;
  final String rendererProfile;
  final VideoEnhancementMode appliedEnhancementPipeline;
  final int? frameDropCount;
  final int? delayedFrameCount;

  String? get resolution =>
      (width != null && height != null && width! > 0 && height! > 0)
      ? '$width × $height'
      : null;
}
