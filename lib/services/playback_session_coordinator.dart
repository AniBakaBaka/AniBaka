import 'dart:async';

import 'package:baka/services/danmaku_service.dart';
import 'package:baka/services/media_session_service.dart';
import 'package:baka/services/player_service.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

class PlaybackSessionCoordinator {
  PlaybackSessionCoordinator({
    required this.controller,
    required this.danmakuController,
    required this.content,
    required this.onNextEpisode,
    required this.onPreviousEpisode,
    MediaSessionService? mediaSession,
    DateTime Function()? now,
  }) : _mediaSession = mediaSession,
       _now = now ?? DateTime.now;

  final PlaybackController controller;
  final DanmakuController danmakuController;
  final PlayerService content;
  final VoidCallback onNextEpisode;
  final VoidCallback onPreviousEpisode;
  final MediaSessionService? _mediaSession;
  final DateTime Function() _now;

  StreamSubscription<void>? _completedSubscription;
  StreamSubscription<Duration>? _seekSubscription;
  DateTime _lastProgressSave = DateTime.fromMillisecondsSinceEpoch(0);
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;
  MediaSessionService? _attachedMediaSession;

  int get generation => _generation;
  int nextGeneration() => ++_generation;
  bool isCurrent(int generation) => !_disposed && generation == _generation;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    controller.attachDanmaku(danmakuController);
    await Future.wait([
      controller.initialize(),
      DanmakuService.loadSettings(danmakuController),
    ]);
    if (_disposed) return;
    _lastProgressSave = _now();
    controller.timeline.addListener(_onTimelineChanged);
    _completedSubscription = controller.completed.listen(
      (_) => onNextEpisode(),
    );
    _seekSubscription = controller.seekEvents.listen((_) => saveProgress());
    final mediaSession = _mediaSession ?? Get.find<MediaSessionService>();
    mediaSession.attach(
      controller,
      onNextEpisode: onNextEpisode,
      onPreviousEpisode: onPreviousEpisode,
    );
    _attachedMediaSession = mediaSession;
  }

  void setDanmakuItems(List<DanmakuItem> items) {
    DanmakuService.startPlay(controller: danmakuController, items: items);
  }

  Future<void> parseAndSetDanmakuItems(List<dynamic> rawItems) async {
    setDanmakuItems(await DanmakuService.parseItems(rawItems));
  }

  void _onTimelineChanged() {
    final now = _now();
    if (now.difference(_lastProgressSave) < const Duration(seconds: 30)) {
      return;
    }
    _lastProgressSave = now;
    unawaited(saveProgress());
  }

  Future<void> saveProgress() {
    return content.saveProgress(
      controller.timeline.value.position,
      controller.preferences.value.rememberLastPosition,
    );
  }

  Future<void> saveAndResetForSwitch() async {
    await saveProgress();
    content.saveHistory(
      positionMs: controller.timeline.value.position.inMilliseconds,
      durationMs: controller.timeline.value.duration.inMilliseconds,
    );
    danmakuController.reset();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    controller.timeline.removeListener(_onTimelineChanged);
    await _completedSubscription?.cancel();
    await _seekSubscription?.cancel();
    await saveProgress();
    content.saveHistory(
      positionMs: controller.timeline.value.position.inMilliseconds,
      durationMs: controller.timeline.value.duration.inMilliseconds,
    );
    _attachedMediaSession?.detach();
    _attachedMediaSession = null;
    controller.detachDanmaku();
  }
}
