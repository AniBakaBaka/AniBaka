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
    this.longPressRate = 1.0,
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
  final double longPressRate;
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
    double? longPressRate,
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
      longPressRate: longPressRate ?? this.longPressRate,
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
    // Migrate the modes used by the previous enhancement implementation.
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

enum VideoEnhancementPipeline {
  off,
  low,
  medium,
  high,
  ultra;

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
    this.appliedPipeline = VideoEnhancementPipeline.off,
    this.fallbackReason,
  });

  final VideoEnhancementMode requestedMode;
  final VideoEnhancementPipeline appliedPipeline;
  final String? fallbackReason;

  bool get enabled => appliedPipeline != VideoEnhancementPipeline.off;

  VideoEnhancementState copyWith({
    VideoEnhancementMode? requestedMode,
    VideoEnhancementPipeline? appliedPipeline,
    String? fallbackReason,
    bool clearFallbackReason = false,
  }) => VideoEnhancementState(
    requestedMode: requestedMode ?? this.requestedMode,
    appliedPipeline: appliedPipeline ?? this.appliedPipeline,
    fallbackReason: clearFallbackReason
        ? null
        : fallbackReason ?? this.fallbackReason,
  );
}

String? _resolution(int? width, int? height) {
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return '$width × $height';
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
    this.videoEnhancementMode = VideoEnhancementMode.off,
    this.lastVideoEnhancementMode = VideoEnhancementMode.medium,
    this.showSubtitle = true,
    this.subtitleConfig = const SubtitleConfig(),
    this.videoFit = BoxFit.contain,
    this.videoFitDescription = '\u753b\u9762',
    this.hwdecMode = 'auto',
    this.videoRenderer = 'gpu',
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
  final VideoEnhancementMode videoEnhancementMode;
  final VideoEnhancementMode lastVideoEnhancementMode;
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
    VideoEnhancementMode? videoEnhancementMode,
    VideoEnhancementMode? lastVideoEnhancementMode,
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
      videoEnhancementMode: videoEnhancementMode ?? this.videoEnhancementMode,
      lastVideoEnhancementMode:
          lastVideoEnhancementMode ?? this.lastVideoEnhancementMode,
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
          videoEnhancementMode == other.videoEnhancementMode &&
          lastVideoEnhancementMode == other.lastVideoEnhancementMode &&
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
    videoEnhancementMode,
    lastVideoEnhancementMode,
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
    this.videoDecoder,
    this.hardwareDecoder,
    this.videoOutput,
    this.graphicsApi,
    this.graphicsContext,
    this.pixelFormat,
    this.colorSpace,
    this.containerFormat,
    this.audioBitrate,
    this.audioSampleRate,
    this.audioChannels,
    this.audioCodec,
    this.audioDecoder,
    this.audioFormat,
    this.audioChannelLayout,
    this.rendererProfile = 'gpu',
    this.hardwareDecodeMode = 'auto',
    this.requestedEnhancementMode = VideoEnhancementMode.off,
    this.appliedEnhancementPipeline = VideoEnhancementPipeline.off,
    this.enhancementFallbackReason,
    this.outputWidth,
    this.outputHeight,
    this.frameDropCount = 0,
    this.delayedFrameCount = 0,
  });

  final int? width;
  final int? height;
  final double? framesPerSecond;
  final int? videoBitrate;
  final String? videoCodec;
  final String? videoDecoder;
  final String? hardwareDecoder;
  final String? videoOutput;
  final String? graphicsApi;
  final String? graphicsContext;
  final String? pixelFormat;
  final String? colorSpace;
  final String? containerFormat;
  final int? audioBitrate;
  final int? audioSampleRate;
  final int? audioChannels;
  final String? audioCodec;
  final String? audioDecoder;
  final String? audioFormat;
  final String? audioChannelLayout;
  final String rendererProfile;
  final String hardwareDecodeMode;
  final VideoEnhancementMode requestedEnhancementMode;
  final VideoEnhancementPipeline appliedEnhancementPipeline;
  final String? enhancementFallbackReason;
  final int? outputWidth;
  final int? outputHeight;
  final int frameDropCount;
  final int delayedFrameCount;

  String? get resolution {
    if (width == null || height == null || width! <= 0 || height! <= 0) {
      return null;
    }
    return '$width × $height';
  }

  String? get outputResolution => _resolution(outputWidth, outputHeight);

  String? get qualityLabel {
    if (width == null || height == null || width! <= 0 || height! <= 0) {
      return null;
    }
    final shortEdge = width! < height! ? width! : height!;
    if (shortEdge >= 2160) return '4K';
    if (shortEdge >= 1440) return '2K';
    if (shortEdge >= 1080) return '1080p';
    if (shortEdge >= 720) return '720p';
    if (shortEdge >= 480) return '480p';
    if (shortEdge >= 360) return '360p';
    return '${shortEdge}p';
  }

  PlaybackTechnicalInfo copyWith({
    String? rendererProfile,
    String? hardwareDecodeMode,
    VideoEnhancementMode? requestedEnhancementMode,
    VideoEnhancementPipeline? appliedEnhancementPipeline,
    String? enhancementFallbackReason,
    int? outputWidth,
    int? outputHeight,
    int? frameDropCount,
    int? delayedFrameCount,
  }) {
    return PlaybackTechnicalInfo(
      width: width,
      height: height,
      framesPerSecond: framesPerSecond,
      videoBitrate: videoBitrate,
      videoCodec: videoCodec,
      videoDecoder: videoDecoder,
      hardwareDecoder: hardwareDecoder,
      videoOutput: videoOutput,
      graphicsApi: graphicsApi,
      graphicsContext: graphicsContext,
      pixelFormat: pixelFormat,
      colorSpace: colorSpace,
      containerFormat: containerFormat,
      audioBitrate: audioBitrate,
      audioSampleRate: audioSampleRate,
      audioChannels: audioChannels,
      audioCodec: audioCodec,
      audioDecoder: audioDecoder,
      audioFormat: audioFormat,
      audioChannelLayout: audioChannelLayout,
      rendererProfile: rendererProfile ?? this.rendererProfile,
      hardwareDecodeMode: hardwareDecodeMode ?? this.hardwareDecodeMode,
      requestedEnhancementMode:
          requestedEnhancementMode ?? this.requestedEnhancementMode,
      appliedEnhancementPipeline:
          appliedEnhancementPipeline ?? this.appliedEnhancementPipeline,
      enhancementFallbackReason:
          enhancementFallbackReason ?? this.enhancementFallbackReason,
      outputWidth: outputWidth ?? this.outputWidth,
      outputHeight: outputHeight ?? this.outputHeight,
      frameDropCount: frameDropCount ?? this.frameDropCount,
      delayedFrameCount: delayedFrameCount ?? this.delayedFrameCount,
    );
  }
}
