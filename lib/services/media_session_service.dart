import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import 'package:baka/widgets/baka_player/controller.dart';

/// 统一媒体会话服务 —— 桥接 PlaybackController 与各平台系统媒体控制
///
/// Android/iOS/macOS: audio_service (MediaSession / MPNowPlayingInfoCenter)
class MediaSessionService extends GetxService {
  MediaSessionService({PlaybackAudioHandler? audioHandler})
    : _audioHandler = audioHandler;

  PlaybackAudioHandler? _audioHandler;
  PlaybackController? _controller;
  StreamSubscription<Duration>? _seekSubscription;
  Duration _lastDuration = Duration.zero;

  static Future<void> init() async {
    if (Get.isRegistered<MediaSessionService>()) return;
    final svc = MediaSessionService();

    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      svc._audioHandler = await AudioService.init<PlaybackAudioHandler>(
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

    Get.put(svc, permanent: true);
  }

  void attach(
    PlaybackController controller, {
    VoidCallback? onNextEpisode,
    VoidCallback? onPreviousEpisode,
  }) {
    if (_controller == controller) return;
    detach();
    _controller = controller;
    _audioHandler?._controller = controller;
    _audioHandler?._onNextEpisode = onNextEpisode;
    _audioHandler?._onPreviousEpisode = onPreviousEpisode;
    _seekSubscription = controller.seekEvents.listen(
      (_) => _syncPlaybackState(),
    );
    _startListening();

    // 立即同步当前元数据，避免 Rx 值在 attach 前已设置导致 listener 不触发
    _syncMetadata();
    _syncPlaybackState();
  }

  void detach() {
    _stopListening();

    _audioHandler?._controller = null;
    _audioHandler?._onNextEpisode = null;
    _audioHandler?._onPreviousEpisode = null;
    _seekSubscription?.cancel();
    _seekSubscription = null;
    _audioHandler?._broadcastStopped();
    _controller = null;
    _lastDuration = Duration.zero;
  }

  void _startListening() {
    final c = _controller;
    if (c == null) return;
    c.core.addListener(_syncPlaybackState);
    c.timeline.addListener(_syncTimeline);
    c.mediaInfo.addListener(_syncMetadata);
  }

  void _stopListening() {
    final c = _controller;
    c?.core.removeListener(_syncPlaybackState);
    c?.timeline.removeListener(_syncTimeline);
    c?.mediaInfo.removeListener(_syncMetadata);
  }

  void _syncPlaybackState() {
    final c = _controller;
    if (c == null) return;

    final core = c.core.value;
    final timeline = c.timeline.value;
    _audioHandler?._broadcastState(
      playing: core.playing,
      position: timeline.position,
      duration: timeline.duration,
      speed: core.playbackRate,
      buffered: timeline.buffered,
    );
  }

  void _syncTimeline() {
    final duration = _controller?.timeline.value.duration ?? Duration.zero;
    if (duration > Duration.zero && duration != _lastDuration) {
      _lastDuration = duration;
      _syncDuration(duration);
    }
  }

  void _syncDuration(Duration dur) {
    _audioHandler?._updateDuration(dur);
  }

  void _syncMetadata() {
    final c = _controller;
    if (c == null) return;
    final info = c.mediaInfo.value;
    final mainTitle = info.title;
    final episode = info.episode;
    final coverUrl = info.imageUrl;
    final epIdx = info.episodeIndex;
    final epTotal = info.totalEpisodes;

    String displayTitle = mainTitle;
    if (episode.isNotEmpty) {
      displayTitle = '$mainTitle - $episode';
    } else if (epTotal > 0) {
      displayTitle = '$mainTitle - 第${epIdx + 1}集';
    }
    if (displayTitle.isEmpty) return;

    final subtitle = epTotal > 1 ? '第${epIdx + 1}集 / 共$epTotal集' : mainTitle;

    _audioHandler?._updateMetadata(
      title: displayTitle,
      artist: subtitle,
      artUrl: coverUrl.isNotEmpty ? coverUrl : null,
    );
  }

  @override
  void onClose() {
    detach();
    super.onClose();
  }
}

class PlaybackAudioHandler extends BaseAudioHandler with SeekHandler {
  PlaybackController? _controller;
  VoidCallback? _onNextEpisode;
  VoidCallback? _onPreviousEpisode;

  PlaybackAudioHandler() {
    mediaItem.add(
      const MediaItem(
        id: 'baka_video',
        title: 'Baka',
        artist: '',
        duration: Duration.zero,
      ),
    );
  }

  @override
  Future<void> play() async {
    await _controller?.play();
  }

  @override
  Future<void> pause() async {
    await _controller?.pause();
  }

  @override
  Future<void> stop() async {
    await _controller?.pause();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await _controller?.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    _onNextEpisode?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    _onPreviousEpisode?.call();
  }

  @override
  Future<void> setSpeed(double speed) async {
    await _controller?.setRate(speed);
  }

  void _broadcastState({
    required bool playing,
    required Duration position,
    required Duration duration,
    required double speed,
    required Duration buffered,
  }) {
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 3],
        processingState: AudioProcessingState.ready,
        playing: playing,
        updatePosition: position,
        bufferedPosition: buffered,
        speed: speed,
      ),
    );
  }

  void _broadcastStopped() {
    playbackState.add(
      PlaybackState(
        controls: [],
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
  }

  void _updateDuration(Duration dur) {
    final current = mediaItem.value;
    if (current != null && current.duration != dur) {
      mediaItem.add(current.copyWith(duration: dur));
    }
  }

  void _updateMetadata({
    required String title,
    required String artist,
    String? artUrl,
  }) {
    final current = mediaItem.value;
    Uri? artUri;
    if (artUrl != null && artUrl.isNotEmpty) {
      artUri = Uri.tryParse(artUrl);
    }
    mediaItem.add(
      MediaItem(
        id: 'baka_video',
        title: title,
        artist: artist,
        artUri: artUri,
        duration: current?.duration ?? Duration.zero,
      ),
    );
  }
}
