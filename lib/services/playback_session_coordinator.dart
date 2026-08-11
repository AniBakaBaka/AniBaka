import 'dart:async';

import 'package:baka/services/danmaku_service.dart';
import 'package:baka/services/media_session_service.dart';
import 'package:baka/services/player_service.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// Wires player controller, danmaku, media session, and progress persistence.
class PlaybackSessionCoordinator {
  PlaybackSessionCoordinator({
    required this.controller,
    required this.danmakuController,
    required this.content,
    required this.onNextEpisode,
    required this.onPreviousEpisode,
    this._mediaSession,
  });

  static const _progressThrottle = Duration(seconds: 30);

  final PlaybackController controller;
  final DanmakuController danmakuController;
  final PlayerService content;
  final VoidCallback onNextEpisode;
  final VoidCallback onPreviousEpisode;
  final MediaSessionService? _mediaSession;

  StreamSubscription<void>? _completedSubscription;
  StreamSubscription<Duration>? _seekSubscription;
  int _lastCheckpointPositionMs = 0;
  int _lastPersistedPositionMs = -1;
  bool _started = false;
  bool _disposed = false;
  MediaSessionService? _attachedMediaSession;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    controller.attachDanmaku(danmakuController);
    await Future.wait([
      controller.initialize(),
      DanmakuService.loadSettings(danmakuController),
    ]);
    if (_disposed) return;

    _lastCheckpointPositionMs =
        controller.timeline.value.position.inMilliseconds;
    controller.timeline.addListener(_onTimelineChanged);
    _completedSubscription = controller.completed.listen(
      (_) => onNextEpisode(),
    );
    _seekSubscription = controller.seekEvents.listen((position) {
      _lastCheckpointPositionMs = position.inMilliseconds;
      unawaited(saveProgress());
    });

    final mediaSession = _mediaSession ?? Get.find<MediaSessionService>();
    mediaSession.attach(
      controller,
      onNextEpisode: onNextEpisode,
      onPreviousEpisode: onPreviousEpisode,
    );
    _attachedMediaSession = mediaSession;
  }

  void _onTimelineChanged() {
    final positionMs = controller.timeline.value.position.inMilliseconds;
    if (positionMs >= _lastCheckpointPositionMs &&
        positionMs - _lastCheckpointPositionMs <
            _progressThrottle.inMilliseconds) {
      return;
    }
    _lastCheckpointPositionMs = positionMs;
    unawaited(saveProgress());
  }

  Future<void> saveProgress() {
    final position = controller.timeline.value.position;
    final positionMs = position.inMilliseconds;
    if (!controller.preferences.value.rememberLastPosition ||
        positionMs == _lastPersistedPositionMs) {
      return Future.value();
    }
    _lastPersistedPositionMs = positionMs;
    return content.saveProgress(position, true);
  }

  void _saveHistory() {
    final timeline = controller.timeline.value;
    content.saveHistory(
      positionMs: timeline.position.inMilliseconds,
      durationMs: timeline.duration.inMilliseconds,
    );
  }

  Future<void> saveAndResetForSwitch() async {
    await saveProgress();
    _saveHistory();
    danmakuController.reset();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    controller.timeline.removeListener(_onTimelineChanged);
    await _completedSubscription?.cancel();
    await _seekSubscription?.cancel();
    await saveProgress();
    _saveHistory();
    _attachedMediaSession?.detach();
    _attachedMediaSession = null;
    controller.detachDanmaku();
  }
}
