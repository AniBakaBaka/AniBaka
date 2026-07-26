import 'dart:async';

import 'package:baka/models/playback_state.dart';
import 'package:baka/models/subtitle_config.dart';
import 'package:baka/services/playback_settings_service.dart';
import 'package:baka/utils/date_util.dart';
import 'package:baka/widgets/baka_player/anime4k.dart';
import 'package:baka/widgets/baka_player/mpv_config.dart';
import 'package:baka/widgets/baka_player/playback_backend.dart';
import 'package:baka/widgets/baka_player/utils.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlaybackController {
  PlaybackController({PlaybackBackend? backend})
    : _backend = backend ?? MediaKitPlaybackBackend();

  static const videoFitTypes = <({BoxFit fit, String description})>[
    (fit: BoxFit.contain, description: '\u753b\u9762'),
    (fit: BoxFit.cover, description: '\u8986\u76d6'),
    (fit: BoxFit.fill, description: '\u586b\u5145'),
    (fit: BoxFit.fitHeight, description: '\u9ad8\u5ea6\u9002\u5e94'),
    (fit: BoxFit.fitWidth, description: '\u5bbd\u5ea6\u9002\u5e94'),
  ];

  static const _timelineIntervalMs = 250;
  static const _skipCancelVisibleDuration = Duration(seconds: 5);
  static const _reverseTickInterval = Duration(milliseconds: 100);
  static const _longPressPixelsPerRate = 32.0;
  static const _maxLongPressRate = 5.0;

  final PlaybackBackend _backend;
  final core = ValueNotifier<PlaybackCoreState>(const PlaybackCoreState());
  final timeline = ValueNotifier<PlaybackTimelineState>(
    const PlaybackTimelineState(),
  );
  final overlay = ValueNotifier<PlayerOverlayState>(const PlayerOverlayState());
  final toastRevision = ValueNotifier<int>(0);
  final preferences = ValueNotifier<PlaybackPreferences>(
    const PlaybackPreferences(),
  );
  final mediaInfo = ValueNotifier<PlaybackMediaInfo>(const PlaybackMediaInfo());

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<Duration> _seekEvents =
      StreamController<Duration>.broadcast();

  Timer? _hideControlsTimer;
  Timer? _skipCancelHideTimer;
  Timer? _jumpPromptTimer;
  Timer? _errorDebounceTimer;
  Timer? _bufferingDebounceTimer;
  Timer? _reversePlaybackTimer;

  Future<void>? _initializeFuture;
  Future<void> _settingsWrites = Future<void>.value();
  PlaybackPreferences _persistedPreferences = const PlaybackPreferences();
  DanmakuController? _danmakuController;
  double _lastPlaybackRate = 1.0;
  double _longPressStartRate = 1.0;
  double _reversePlaybackRate = 0.0;
  bool _playingBeforeLongPress = false;
  bool _reverseSeekInFlight = false;
  Future<void>? _longPressTask;
  int _longPressRevision = 0;
  int _lastTimelineBucket = -1;
  bool _listenersBound = false;
  bool _disposed = false;
  bool _hasPlaybackProgress = false;
  int _openRetryCount = 0;
  int _openGeneration = 0;
  String? _lastOpenUri;
  Map<String, String>? _lastOpenHeaders;
  bool _lastOpenAutoplay = true;

  VideoController? get videoController => _backend.videoController;
  String? get currentMediaUri => _backend.currentMediaUri;
  List<SubtitleTrack> get subtitleTracks => _backend.subtitleTracks;
  SubtitleTrack get currentSubtitleTrack => _backend.currentSubtitleTrack;
  DanmakuController get danmakuController =>
      _danmakuController ??
      (throw StateError('Danmaku controller is not attached'));
  Stream<void> get completed => _completed.stream;
  Stream<Duration> get seekEvents => _seekEvents.stream;

  Future<void> initialize() {
    return _initializeFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    final loaded = await PlaybackSettingsService.loadAll();
    if (_disposed) return;
    _persistedPreferences = loaded;
    preferences.value = loaded;
    overlay.value = overlay.value.copyWith(
      showDanmaku: !loaded.defaultDanmakuOff,
    );
    await _backend.initialize();
    if (_disposed) return;
    _bindBackend();
  }

  Future<void> open(
    String uri, {
    bool autoplay = true,
    Map<String, String>? httpHeaders,
  }) async {
    _openGeneration++;
    _lastOpenUri = uri;
    _lastOpenHeaders = httpHeaders == null
        ? null
        : Map<String, String>.from(httpHeaders);
    _lastOpenAutoplay = autoplay;
    _hasPlaybackProgress = false;
    _openRetryCount = 0;
    try {
      await _openCurrent();
    } catch (error) {
      final safeError = sanitizePlaybackError(error);
      if (!_disposed) {
        core.value = core.value.copyWith(
          loading: false,
          buffering: false,
          failed: true,
          errorMessage: safeError,
        );
      }
      throw Exception(safeError);
    }
  }

  /// open 与错误自动重试共用的打开序列（initialize 已记忆化，重复调用无害）。
  Future<void> _openCurrent() async {
    _resetPlaybackState();
    await initialize();
    if (_backend.currentMediaUri != null) await _backend.stop();
    await _configurePlayer(preferences.value.defaultPlaybackSpeed);
    await _backend.open(
      _lastOpenUri!,
      autoplay: _lastOpenAutoplay,
      httpHeaders: _lastOpenHeaders,
    );
    if (_disposed) return;
    core.value = core.value.copyWith(loading: false);
  }

  Future<void> applyPlaybackConfiguration() async {
    await initialize();
    await _configurePlayer(preferences.value.defaultPlaybackSpeed);
  }

  void attachDanmaku(DanmakuController controller) {
    _danmakuController = controller;
    controller.playbackRate = core.value.playbackRate;
    controller.syncTime(timeline.value.position);
    _syncDanmakuActivity();
  }

  /// 弹幕滚动与播放状态的唯一同步点：仅「播放中、未缓冲、未失败」时滚动。
  /// 各状态回调更新 core.value 后统一调用，替代散落各处、条件各写各的
  /// pause/resume。
  void _syncDanmakuActivity() {
    final controller = _danmakuController;
    if (controller == null) return;
    final state = core.value;
    if (state.playing && !state.buffering && !state.failed) {
      controller.resume();
    } else {
      controller.pause();
    }
  }

  void detachDanmaku() {
    _danmakuController?.pause();
    _danmakuController = null;
  }

  void _bindBackend() {
    if (_listenersBound || _disposed) return;
    _listenersBound = true;
    _subscriptions.addAll([
      _backend.playing.listen(_onPlayingChanged),
      _backend.position.listen(_onPositionChanged),
      _backend.duration.listen(_onDurationChanged),
      _backend.buffered.listen(_onBufferedChanged),
      _backend.buffering.listen(_onBufferingChanged),
      _backend.errors.listen(_onError),
      _backend.completed.listen((completed) {
        if (!_disposed && completed) _completed.add(null);
      }),
      _backend.tracks.listen(_onTracksChanged),
    ]);
  }

  void _onPlayingChanged(bool playing) {
    if (_disposed) return;
    final current = core.value;
    final loading = playing ? false : current.loading;
    final buffering = playing ? false : current.buffering;
    final failed = playing ? false : current.failed;
    final errorMessage = playing ? '' : current.errorMessage;
    final changed =
        current.playing != playing ||
        current.loading != loading ||
        current.buffering != buffering ||
        current.failed != failed ||
        current.errorMessage != errorMessage;
    if (!changed) return;
    core.value = current.copyWith(
      playing: playing,
      loading: loading,
      buffering: buffering,
      failed: failed,
      errorMessage: errorMessage,
    );
    _syncDanmakuActivity();
  }

  void _onPositionChanged(Duration position) {
    if (_disposed) return;
    if (!_hasPlaybackProgress && position > Duration.zero) {
      _hasPlaybackProgress = true;
      final coreState = core.value;
      if (coreState.loading ||
          coreState.buffering ||
          coreState.failed ||
          coreState.errorMessage.isNotEmpty) {
        core.value = coreState.copyWith(
          loading: false,
          buffering: false,
          failed: false,
          errorMessage: '',
        );
        _syncDanmakuActivity();
      }
    }
    final milliseconds = position.inMilliseconds;
    final bucket = milliseconds ~/ _timelineIntervalMs;
    if (_lastTimelineBucket == bucket &&
        milliseconds >= timeline.value.position.inMilliseconds) {
      return;
    }
    _lastTimelineBucket = bucket;

    // Danmaku owns a frame clock and only needs a bounded media-time anchor.
    // Keeping this behind the same 250 ms bucket avoids rescheduling its wake
    // timer for every raw backend position sample.
    _danmakuController?.syncTime(position);
    _updateSkipState(position);
    final current = timeline.value;
    timeline.value = current.copyWith(
      position: position,
      previewPosition: current.seeking ? current.previewPosition : position,
    );
  }

  void _onDurationChanged(Duration duration) {
    if (_disposed ||
        duration == Duration.zero ||
        duration == timeline.value.duration) {
      return;
    }
    timeline.value = timeline.value.copyWith(duration: duration);
  }

  void _onBufferedChanged(Duration buffered) {
    if (_disposed || buffered == timeline.value.buffered) return;
    timeline.value = timeline.value.copyWith(buffered: buffered);
  }

  void _onTracksChanged(Tracks tracks) {
    if (_disposed) return;
    final hasTracks = tracks.subtitle.any(
      (track) => track.id != 'auto' && track.id != 'no',
    );
    if (hasTracks == core.value.hasSubtitleTracks) return;
    core.value = core.value.copyWith(hasSubtitleTracks: hasTracks);
  }

  void _onBufferingChanged(bool buffering) {
    if (_disposed) return;
    _bufferingDebounceTimer?.cancel();
    _bufferingDebounceTimer = null;

    if (!buffering) {
      if (core.value.buffering) {
        core.value = core.value.copyWith(buffering: false);
      }
      _syncDanmakuActivity();
      return;
    }
    if (!core.value.playing) {
      if (!core.value.buffering) {
        core.value = core.value.copyWith(buffering: true);
      }
      _syncDanmakuActivity();
      return;
    }

    // 疑似卡顿：core.buffering 尚未置位，先停弹幕，600ms 确认后再同步。
    _danmakuController?.pause();
    final position = _backend.currentPosition;
    _bufferingDebounceTimer = Timer(const Duration(milliseconds: 600), () {
      if (_disposed) return;
      final stalled = _backend.currentPosition <= position;
      if (core.value.buffering != stalled) {
        core.value = core.value.copyWith(buffering: stalled);
      }
      _syncDanmakuActivity();
    });
  }

  void _onError(String error) {
    if (_disposed) return;
    final safeError = sanitizePlaybackError(error);
    final openGeneration = _openGeneration;
    _errorDebounceTimer?.cancel();
    _errorDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (_disposed || openGeneration != _openGeneration) return;
      final hasPlaybackProgress =
          _hasPlaybackProgress ||
          _backend.currentPosition > Duration.zero ||
          timeline.value.position > Duration.zero;
      if (hasPlaybackProgress && _backend.isPlaying) {
        debugPrint('播放中忽略非致命错误: $safeError');
        return;
      }
      if (!hasPlaybackProgress &&
          _backend.isPlaying &&
          _openRetryCount == 0 &&
          _lastOpenUri != null) {
        _openRetryCount = 1;
        debugPrint('媒体尚未开始播放，自动重试打开: $safeError');
        unawaited(_retryLastOpen(openGeneration));
        return;
      }
      _setPlaybackFailed(safeError);
    });
  }

  Future<void> _retryLastOpen(int openGeneration) async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (_disposed ||
          _hasPlaybackProgress ||
          openGeneration != _openGeneration) {
        return;
      }
      if (_lastOpenUri == null) return;
      await _openCurrent();
    } catch (error) {
      if (!_disposed && openGeneration == _openGeneration) {
        _setPlaybackFailed(sanitizePlaybackError(error));
      }
    }
  }

  void _setPlaybackFailed(String error) {
    if (_disposed) return;
    core.value = core.value.copyWith(
      loading: false,
      buffering: false,
      failed: true,
      errorMessage: error,
    );
    unawaited(_backend.pause());
    _syncDanmakuActivity();
  }

  Future<void> play() async {
    if (_disposed) return;
    await _backend.play();
  }

  Future<void> pause() async {
    if (_disposed) return;
    await _backend.pause();
    _danmakuController?.pause();
  }

  Future<void> stop() async {
    if (_disposed) return;
    await _backend.stop();
    _danmakuController?.pause();
  }

  void togglePlayback() {
    if (core.value.playing) {
      unawaited(pause());
    } else {
      unawaited(play());
    }
  }

  Future<void> seek(Duration target, {bool fromSlider = false}) async {
    if (_disposed) return;
    if (overlay.value.skipState == SkipState.waiting) {
      _setSkipState(SkipState.idle);
    }
    await _performSeek(target, updatePreview: !fromSlider);
    if (!_seekEvents.isClosed) _seekEvents.add(target);
  }

  Future<void> _performSeek(
    Duration target, {
    bool updatePreview = true,
  }) async {
    final clamped = target.clamp(Duration.zero, timeline.value.duration);
    final current = timeline.value;
    timeline.value = current.copyWith(
      position: clamped,
      previewPosition: updatePreview ? clamped : current.previewPosition,
    );
    _lastTimelineBucket = clamped.inMilliseconds ~/ _timelineIntervalMs;
    try {
      await _backend.seek(clamped);
      _danmakuController?.syncTime(clamped);
    } catch (error) {
      debugPrint('播放跳转失败: $error');
    }
  }

  Future<void> setRate(double rate) async {
    if (_disposed) return;
    final normalized = rate > 0 ? rate : 1.0;
    core.value = core.value.copyWith(playbackRate: normalized);
    _danmakuController?.playbackRate = normalized;
    await _backend.setRate(normalized);
  }

  void setDoubleSpeed(bool enabled) {
    if (_disposed ||
        overlay.value.controlsLocked ||
        overlay.value.doubleSpeed == enabled) {
      return;
    }
    if (enabled) {
      _lastPlaybackRate = core.value.playbackRate;
      _longPressStartRate = preferences.value.longPressSpeed.clamp(
        0.0,
        _maxLongPressRate,
      );
      _playingBeforeLongPress = core.value.playing;
      overlay.value = overlay.value.copyWith(
        doubleSpeed: true,
        longPressRate: _longPressStartRate,
      );
      _notifyToastChanged();
      _scheduleLongPressState();
      return;
    }

    _stopReversePlayback();
    overlay.value = overlay.value.copyWith(doubleSpeed: false);
    _notifyToastChanged();
    _scheduleLongPressState();
  }

  void updateDoubleSpeedOffset(double horizontalOffset) {
    if (_disposed || !overlay.value.doubleSpeed) return;
    final rate =
        (_longPressStartRate + horizontalOffset / _longPressPixelsPerRate)
            .clamp(-_maxLongPressRate, _maxLongPressRate)
            .toDouble();
    final steppedRate = (rate * 10).round() / 10;
    if (overlay.value.longPressRate == steppedRate) return;
    overlay.value = overlay.value.copyWith(longPressRate: steppedRate);
    _notifyToastChanged();
    _scheduleLongPressState();
  }

  void _scheduleLongPressState() {
    _longPressRevision++;
    _longPressTask ??= _drainLongPressState();
  }

  Future<void> _drainLongPressState() async {
    while (!_disposed) {
      final revision = _longPressRevision;
      final state = overlay.value;
      try {
        if (state.doubleSpeed) {
          await _applyLongPressRate(state.longPressRate);
        } else {
          await _restorePlaybackAfterLongPress();
        }
      } catch (error) {
        debugPrint('长按变速失败: $error');
      }
      if (revision == _longPressRevision) break;
    }
    _longPressTask = null;
  }

  Future<void> _applyLongPressRate(double rate) async {
    if (_disposed || !overlay.value.doubleSpeed) return;
    if (rate > 0) {
      _stopReversePlayback();
      await setRate(rate);
      if (_playingBeforeLongPress &&
          overlay.value.doubleSpeed &&
          overlay.value.longPressRate > 0 &&
          !core.value.playing) {
        await play();
      }
      return;
    }

    _stopReversePlayback();
    if (core.value.playing) await pause();
    if (rate < 0 &&
        !_disposed &&
        overlay.value.doubleSpeed &&
        overlay.value.longPressRate == rate) {
      _reversePlaybackRate = rate.abs();
      _reversePlaybackTimer = Timer.periodic(
        _reverseTickInterval,
        (_) => unawaited(_reversePlaybackTick()),
      );
    }
  }

  Future<void> _reversePlaybackTick() async {
    if (_reverseSeekInFlight ||
        _disposed ||
        !overlay.value.doubleSpeed ||
        overlay.value.longPressRate >= 0) {
      return;
    }
    _reverseSeekInFlight = true;
    try {
      final rewind = Duration(
        milliseconds:
            (_reverseTickInterval.inMilliseconds * _reversePlaybackRate)
                .round(),
      );
      await _performSeek(timeline.value.position - rewind);
    } finally {
      _reverseSeekInFlight = false;
    }
  }

  void _stopReversePlayback() {
    _reversePlaybackTimer?.cancel();
    _reversePlaybackTimer = null;
    _reversePlaybackRate = 0.0;
  }

  Future<void> _restorePlaybackAfterLongPress() async {
    await setRate(_lastPlaybackRate);
    if (_playingBeforeLongPress) {
      if (!core.value.playing) await play();
    } else if (core.value.playing) {
      await pause();
    }
  }

  void beginSeekPreview() {
    if (timeline.value.seeking) return;
    timeline.value = timeline.value.copyWith(seeking: true);
    _notifyToastChanged();
  }

  void updateSeekPreview(Duration value) {
    if (timeline.value.previewPosition == value) return;
    timeline.value = timeline.value.copyWith(previewPosition: value);
    _notifyToastChanged();
  }

  void endSeekPreview() {
    if (!timeline.value.seeking) return;
    timeline.value = timeline.value.copyWith(seeking: false);
    _notifyToastChanged();
    setControlsVisible(true);
  }

  void _notifyToastChanged() {
    toastRevision.value = toastRevision.value + 1;
  }

  void setControlsVisible(bool visible) {
    if (_disposed) return;
    if (overlay.value.controlsVisible != visible) {
      overlay.value = overlay.value.copyWith(controlsVisible: visible);
    }
    _hideControlsTimer?.cancel();
    if (visible) {
      _hideControlsTimer = Timer(const Duration(seconds: 3), () {
        if (_disposed || timeline.value.seeking) return;
        overlay.value = overlay.value.copyWith(controlsVisible: false);
      });
    }
  }

  void toggleControls() => setControlsVisible(!overlay.value.controlsVisible);

  void setControlsLocked(bool locked) {
    if (_disposed || overlay.value.controlsLocked == locked) return;
    overlay.value = overlay.value.copyWith(
      controlsLocked: locked,
      controlsVisible: locked ? false : true,
    );
    if (locked) {
      _hideControlsTimer?.cancel();
    } else {
      setControlsVisible(true);
    }
  }

  void setVolume(double value) {
    final next = value.clamp(0.0, 1.0);
    if (overlay.value.volume == next) return;
    overlay.value = overlay.value.copyWith(volume: next);
  }

  void setBrightness(double value) {
    final next = value.clamp(0.0, 1.0);
    if (overlay.value.brightness == next) return;
    overlay.value = overlay.value.copyWith(brightness: next);
  }

  void setDanmakuVisible(bool visible) {
    if (overlay.value.showDanmaku == visible) return;
    overlay.value = overlay.value.copyWith(showDanmaku: visible);
  }

  void setDanmakuInputVisible(bool visible) {
    if (overlay.value.showDanmakuInput == visible) return;
    overlay.value = overlay.value.copyWith(showDanmakuInput: visible);
    if (visible) setControlsVisible(false);
  }

  void showJumpToPositionPrompt(Duration position) {
    if (!preferences.value.rememberLastPosition || position.inSeconds <= 0) {
      return;
    }
    overlay.value = overlay.value.copyWith(
      showJumpPrompt: true,
      jumpPosition: position,
      jumpPromptText: '继续播放${position.toTimeString()}？',
    );
    _jumpPromptTimer?.cancel();
    _jumpPromptTimer = Timer(const Duration(seconds: 15), hideJumpPrompt);
  }

  void hideJumpPrompt() {
    if (!overlay.value.showJumpPrompt) return;
    overlay.value = overlay.value.copyWith(
      showJumpPrompt: false,
      jumpPosition: Duration.zero,
      jumpPromptText: '',
    );
    _jumpPromptTimer?.cancel();
  }

  void performJumpToPosition() {
    final target = overlay.value.jumpPosition;
    if (target > Duration.zero) unawaited(seek(target));
    hideJumpPrompt();
  }

  void _updateSkipState(Duration position) {
    final settings = preferences.value;
    final current = overlay.value;
    if (!settings.enableSkipOpEd) {
      if (current.skipState == SkipState.waiting) {
        _setSkipState(SkipState.idle);
      }
      return;
    }
    final seconds = position.inSeconds;
    final canSkip =
        seconds > 0 &&
        timeline.value.duration.inSeconds >
            settings.skipOpWaitTime + settings.skipOpDuration;
    if (!canSkip || current.showJumpPrompt) return;

    if (current.skipState == SkipState.idle &&
        seconds < settings.skipOpWaitTime) {
      _setSkipState(SkipState.waiting);
      return;
    }
    if (current.skipState != SkipState.waiting) return;
    if (seconds < settings.skipOpWaitTime) return;

    _showSkipCancelPrompt();
    unawaited(
      _performSeek(position + Duration(seconds: settings.skipOpDuration)),
    );
  }

  void _setSkipState(SkipState state) {
    if (overlay.value.skipState == state) return;
    overlay.value = overlay.value.copyWith(skipState: state);
  }

  void userActionSkip() {
    _showSkipCancelPrompt();
    unawaited(
      _performSeek(
        timeline.value.position +
            Duration(seconds: preferences.value.skipOpDuration),
      ),
    );
  }

  void userActionCancelSkip() {
    _skipCancelHideTimer?.cancel();
    _setSkipState(SkipState.idle);
  }

  void cancelSkipOpEd() {
    final wasShowing = overlay.value.skipState == SkipState.showingCancel;
    _skipCancelHideTimer?.cancel();
    _setSkipState(SkipState.idle);
    if (!wasShowing) return;
    final position = timeline.value.position;
    final target =
        (position - Duration(seconds: preferences.value.skipOpDuration)).clamp(
          Duration.zero,
          position,
        );
    unawaited(_performSeek(target));
  }

  void _showSkipCancelPrompt() {
    _setSkipState(SkipState.showingCancel);
    _skipCancelHideTimer?.cancel();
    _skipCancelHideTimer = Timer(_skipCancelVisibleDuration, () {
      if (_disposed || overlay.value.skipState != SkipState.showingCancel) {
        return;
      }
      _setSkipState(SkipState.idle);
    });
  }

  void setMediaInfo(PlaybackMediaInfo info) {
    mediaInfo.value = info;
  }

  Future<void> updatePreferences(
    PlaybackPreferences next, {
    bool persist = true,
  }) async {
    if (_disposed) return;
    final previous = preferences.value;
    if (previous == next) return;
    preferences.value = next;
    if (previous.longPressSpeed != next.longPressSpeed) {
      _notifyToastChanged();
    }

    if (previous.enableAnime4K != next.enableAnime4K ||
        previous.anime4KLevel != next.anime4KLevel) {
      await _syncAnime4KShaders();
    }
    if (previous.subtitleConfig != next.subtitleConfig) {
      await _syncSubtitleConfig();
    }
    if (previous.showSubtitle != next.showSubtitle) {
      await _backend.setNativeProperty(
        'sub-visibility',
        next.showSubtitle ? 'yes' : 'no',
      );
    }
    if (previous.hwdecMode != next.hwdecMode) {
      await _backend.setNativeProperty('hwdec', next.hwdecMode);
    }
    if (previous.videoRenderer != next.videoRenderer) {
      await syncMpvProperties(
        _backend.setNativeProperty,
        buildVideoRendererProperties(next.videoRenderer),
        debugLabel: 'video renderer',
      );
    }
    if (persist) {
      _settingsWrites = _settingsWrites.then((_) async {
        final persisted = _persistedPreferences;
        await PlaybackSettingsService.saveChanges(persisted, next);
        _persistedPreferences = next;
      });
      await _settingsWrites;
    }
  }

  Future<void> setVideoFit(BoxFit fit, String description) {
    return updatePreferences(
      preferences.value.copyWith(
        videoFit: fit,
        videoFitDescription: description,
      ),
      persist: false,
    );
  }

  Future<bool> toggleAnime4K() async {
    final enabled = !preferences.value.enableAnime4K;
    await updatePreferences(preferences.value.copyWith(enableAnime4K: enabled));
    return enabled;
  }

  Future<void> switchAnime4KLevel(String level) async {
    if (preferences.value.anime4KLevel == level) return;
    await updatePreferences(preferences.value.copyWith(anime4KLevel: level));
  }

  Future<void> updateSubtitleConfig(
    SubtitleConfig config, {
    bool persist = true,
  }) {
    return updatePreferences(
      preferences.value.copyWith(subtitleConfig: config),
      persist: persist,
    );
  }

  Future<void> toggleSubtitle() {
    return updatePreferences(
      preferences.value.copyWith(showSubtitle: !preferences.value.showSubtitle),
    );
  }

  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      _backend.setSubtitleTrack(track);

  Future<void> resetPreferences() {
    const defaults = PlaybackPreferences();
    overlay.value = overlay.value.copyWith(showDanmaku: true);
    return updatePreferences(defaults);
  }

  Future<void> _configurePlayer(double rate) async {
    await syncMpvProperties(
      _backend.setNativeProperty,
      buildPlayerProperties(
        hwdecMode: preferences.value.hwdecMode,
        videoRenderer: preferences.value.videoRenderer,
      ),
      debugLabel: 'player',
    );
    await _syncAnime4KShaders();
    await _syncSubtitleConfig();
    await _backend.setNativeProperty(
      'sub-visibility',
      preferences.value.showSubtitle ? 'yes' : 'no',
    );
    await setRate(rate);
  }

  Future<void> _syncAnime4KShaders() async {
    final settings = preferences.value;
    final path = settings.enableAnime4K
        ? await Anime4K.shaderPath(settings.anime4KLevel)
        : '';
    await _backend.setNativeProperty('glsl-shaders', path);
  }

  Future<void> _syncSubtitleConfig() {
    return syncMpvProperties(
      _backend.setNativeProperty,
      buildSubtitleProperties(preferences.value.subtitleConfig),
      debugLabel: 'subtitle',
    );
  }

  void _resetPlaybackState() {
    _stopReversePlayback();
    _skipCancelHideTimer?.cancel();
    _jumpPromptTimer?.cancel();
    _errorDebounceTimer?.cancel();
    _bufferingDebounceTimer?.cancel();
    core.value = core.value.copyWith(
      loading: true,
      buffering: true,
      failed: false,
      errorMessage: '',
    );
    timeline.value = const PlaybackTimelineState();
    overlay.value = overlay.value.copyWith(
      doubleSpeed: false,
      skipState: SkipState.idle,
      showJumpPrompt: false,
      jumpPosition: Duration.zero,
      jumpPromptText: '',
    );
    _notifyToastChanged();
    _lastTimelineBucket = -1;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _hideControlsTimer?.cancel();
    _skipCancelHideTimer?.cancel();
    _jumpPromptTimer?.cancel();
    _errorDebounceTimer?.cancel();
    _bufferingDebounceTimer?.cancel();
    _reversePlaybackTimer?.cancel();
    _longPressRevision++;
    await _longPressTask;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _danmakuController?.pause();
    _danmakuController = null;
    await _settingsWrites;
    try {
      await _backend.pause();
    } catch (_) {}
    await _backend.dispose();
    await _completed.close();
    await _seekEvents.close();
    core.dispose();
    timeline.dispose();
    overlay.dispose();
    toastRevision.dispose();
    preferences.dispose();
    mediaInfo.dispose();
  }
}
