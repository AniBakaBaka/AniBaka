import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'package:baka/widgets/baka_player/controller.dart';

/// Creates system media controls only on platforms supported by audio_service.
class MediaSessionService {
  MediaSessionService({this._audioHandler});

  PlaybackAudioHandler? _audioHandler;
  Future<void>? _initializing;

  Future<void> init() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      _audioHandler = await AudioService.init(
        builder: PlaybackAudioHandler.new,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'ani.baka.channel.playback',
          androidNotificationChannelName: '视频播放',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          androidNotificationIcon: 'mipmap/ic_launcher',
        ),
      );
    }
  }

  void attach(
    PlaybackController controller, {
    VoidCallback? onNextEpisode,
    VoidCallback? onPreviousEpisode,
  }) => _audioHandler?.attach(
    controller,
    onNextEpisode: onNextEpisode,
    onPreviousEpisode: onPreviousEpisode,
  );

  void detach([PlaybackController? owner]) => _audioHandler?.detach(owner);

  void close() => detach();
}

/// Owns the controller listeners and publishes only platform-visible changes.
class PlaybackAudioHandler extends BaseAudioHandler with SeekHandler {
  PlaybackController? _controller;
  VoidCallback? _onNextEpisode;
  VoidCallback? _onPreviousEpisode;
  StreamSubscription<Duration>? _seekSubscription;

  void attach(
    PlaybackController controller, {
    VoidCallback? onNextEpisode,
    VoidCallback? onPreviousEpisode,
  }) {
    if (!identical(_controller, controller)) {
      detach();
      _controller = controller;
      controller.core.addListener(_syncPlaybackState);
      controller.timeline.addListener(_syncTimeline);
      controller.mediaInfo.addListener(_syncMetadata);
      _seekSubscription = controller.seekEvents.listen(_syncPlaybackState);
      _syncMetadata();
      _syncPlaybackState(controller.timeline.value.position);
    }
    _onNextEpisode = onNextEpisode;
    _onPreviousEpisode = onPreviousEpisode;
  }

  void detach([PlaybackController? owner]) {
    final controller = _controller;
    if (controller == null ||
        (owner != null && !identical(owner, controller))) {
      return;
    }
    controller.core.removeListener(_syncPlaybackState);
    controller.timeline.removeListener(_syncTimeline);
    controller.mediaInfo.removeListener(_syncMetadata);
    unawaited(seekForward(false));
    _seekSubscription?.cancel();
    _seekSubscription = null;
    _controller = null;
    _onNextEpisode = null;
    _onPreviousEpisode = null;
    playbackState.add(PlaybackState());
    mediaItem.add(null);
  }

  void _syncPlaybackState([Duration? seekPosition]) {
    final controller = _controller!;
    final core = controller.core.value;
    final timeline = controller.timeline.value;
    final processing = core.failed
        ? AudioProcessingState.error
        : core.loading
        ? AudioProcessingState.loading
        : core.buffering
        ? AudioProcessingState.buffering
        : AudioProcessingState.ready;
    final error = core.failed ? core.errorMessage : null;
    final current = playbackState.value;
    // audio_service projects normal progress from updatePosition/updateTime.
    // Only publish changes it actually consumes, or an explicit seek.
    if (seekPosition == null &&
        current.playing == core.playing &&
        current.processingState == processing &&
        current.speed == core.playbackRate &&
        current.bufferedPosition == timeline.buffered &&
        current.errorMessage == error) {
      return;
    }
    playbackState.add(
      PlaybackState(
        controls: core.playing
            ? const [
                MediaControl.skipToPrevious,
                MediaControl.pause,
                MediaControl.stop,
                MediaControl.skipToNext,
              ]
            : const [
                MediaControl.skipToPrevious,
                MediaControl.play,
                MediaControl.stop,
                MediaControl.skipToNext,
              ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 3],
        processingState: processing,
        playing: core.playing,
        updatePosition: seekPosition ?? timeline.position,
        bufferedPosition: timeline.buffered,
        speed: core.playbackRate,
        errorMessage: error,
      ),
    );
  }

  void _syncTimeline() {
    if (_controller!.timeline.value.duration != mediaItem.value?.duration) {
      _syncMetadata();
    }
    if (playbackState.value.processingState != AudioProcessingState.idle) {
      _syncPlaybackState();
    }
  }

  void _syncMetadata() {
    final controller = _controller!;
    final info = controller.mediaInfo.value;
    final title = info.episode.isNotEmpty
        ? '${info.title} - ${info.episode}'
        : info.totalEpisodes > 0
        ? '${info.title} - 第${info.episodeIndex + 1}集'
        : info.title;
    final artist = info.totalEpisodes > 1
        ? '第${info.episodeIndex + 1}集 / 共${info.totalEpisodes}集'
        : info.title;
    final duration = controller.timeline.value.duration;
    final current = mediaItem.value;
    if (current?.title == title &&
        current?.artist == artist &&
        current?.duration == duration &&
        (current?.artUri?.toString() ?? '') == info.imageUrl) {
      return;
    }
    mediaItem.add(
      MediaItem(
        id: 'baka_video',
        title: title,
        artist: artist,
        artUri: info.imageUrl.isEmpty ? null : Uri.parse(info.imageUrl),
        duration: duration,
      ),
    );
  }

  @override
  Future<void> play() async => _controller?.play();

  @override
  Future<void> pause() async => _controller?.pause();

  @override
  Future<void> stop() async {
    await pause();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async => _controller?.seek(position);

  @override
  Future<void> skipToNext() async => _onNextEpisode?.call();

  @override
  Future<void> skipToPrevious() async => _onPreviousEpisode?.call();

  @override
  Future<void> setSpeed(double speed) async => _controller?.setRate(speed);
}
