import 'dart:async';
import 'dart:io';

import 'package:baka/models/playback_state.dart';
import 'package:baka/models/subtitle_config.dart';
import 'package:baka/services/playback_settings_service.dart';
import 'package:baka/utils/app_logger.dart';
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
  final enhancement = ValueNotifier<VideoEnhancementState>(
    const VideoEnhancementState(),
  );

  /// 当前后端持有的 [VideoController]。渲染器切换（Android 全量重建）时
  /// 实例会整体替换，UI 通过监听此 notifier 挂载/卸载 [Video] 组件，
  /// 确保视频 Surface 在媒体打开前就已创建。
  final videoController = ValueNotifier<VideoController?>(null);

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<Duration> _seekEvents =
      StreamController<Duration>.broadcast();

  Timer? _hideControlsTimer;
  Timer? _skipCancelHideTimer;
  Timer? _jumpPromptTimer;
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
  bool _roomConnected = false;
  bool _roomCanControl = true;
  bool _roomRateLocked = false;
  bool _eofReached = false;
  String? _lastOpenUri;
  Map<String, String>? _lastOpenHeaders;

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
    final loaded = PlaybackSettingsService.loadAll();
    if (_disposed) return;
    _persistedPreferences = loaded;
    preferences.value = loaded;
    overlay.value = overlay.value.copyWith(
      showDanmaku: !loaded.defaultDanmakuOff,
    );
    await _backend.initialize(videoRenderer: loaded.videoRenderer);
    if (_disposed) return;
    videoController.value = _backend.videoController;
    _bindBackend();
  }

  Future<void> open(
    String uri, {
    bool autoplay = true,
    Map<String, String>? httpHeaders,
  }) async {
    _lastOpenUri = uri;
    _lastOpenHeaders = httpHeaders;
    try {
      _resetPlaybackState();
      await initialize();
      if (_backend.currentMediaUri != null) await _backend.stop();
      await _configurePlayer(preferences.value.defaultPlaybackSpeed);
      await _backend.open(uri, autoplay: autoplay, httpHeaders: httpHeaders);
      await _reapplyHwdec();
      if (!_disposed) core.value = core.value.copyWith(loading: false);
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

  /// 重新固定 hwdec：AndroidVideoController 初始化会覆盖它，必须在媒体
  /// 打开（其初始化已完成）之后再设一次。硬解直通强制 mediacodec。
  Future<void> _reapplyHwdec() async {
    try {
      await _backend.setNativeProperty(
        'hwdec',
        effectiveHwdec(
          preferences.value.hwdecMode,
          preferences.value.videoRenderer,
        ),
      );
    } catch (error) {
      debugPrint('重新应用 hwdec 失败: $error');
    }
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
        _eofReached = completed;
        if (!_disposed && completed) _completed.add(null);
      }),
      _backend.tracks.listen(_onTracksChanged),
    ]);
  }

  /// 取消全部后端订阅，供 Android 渲染器切换时重建 Player 前后使用。
  Future<void> _unbindBackend() async {
    if (!_listenersBound) return;
    _listenersBound = false;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
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
    if (position > Duration.zero) {
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
    if (_disposed || core.value.buffering == buffering) {
      return;
    }
    core.value = core.value.copyWith(buffering: buffering);
    _syncDanmakuActivity();
  }

  void _onError(String error) {
    if (_disposed) return;
    final safeError = sanitizePlaybackError(error);
    AppLogger.instance.warning('Playback error: $safeError', tag: 'Playback');
    if (_backend.isPlaying) {
      debugPrint('播放中忽略非致命错误: $safeError');
      return;
    }
    _setPlaybackFailed(safeError);
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

  Future<void> play({bool remote = false}) async {
    if (_disposed || (!_roomCanControl && _roomConnected && !remote)) return;
    await _backend.play();
  }

  Future<void> pause({bool remote = false}) async {
    if (_disposed || (!_roomCanControl && _roomConnected && !remote)) return;
    await _backend.pause();
    _danmakuController?.pause();
  }

  Future<void> stop() async {
    if (_disposed) return;
    await _backend.stop();
    _danmakuController?.pause();
  }

  void togglePlayback() {
    if (_roomConnected && !_roomCanControl) return;
    if (core.value.playing) {
      unawaited(pause());
    } else {
      unawaited(play());
    }
  }

  Future<void> seek(
    Duration target, {
    bool fromSlider = false,
    bool remote = false,
  }) async {
    if (_disposed || (!_roomCanControl && _roomConnected && !remote)) return;
    if (overlay.value.skipState == SkipState.waiting) {
      _setSkipState(SkipState.idle);
    }
    // 播放完成后（mpv keep-open 会暂停在结尾）再拖动进度条：seek 之后
    // 后端仍处于暂停，必须显式恢复播放，否则再次拖拽没有效果。
    final resumeAfterSeek = _eofReached;
    await _performSeek(target, updatePreview: !fromSlider);
    if (resumeAfterSeek) {
      _eofReached = false;
      await play();
    }
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

  Future<void> setRate(double rate, {bool roomCorrection = false}) async {
    if (_disposed || (_roomRateLocked && !roomCorrection)) return;
    final normalized = rate > 0 ? rate : 1.0;
    core.value = core.value.copyWith(playbackRate: normalized);
    _danmakuController?.playbackRate = normalized;
    await _backend.setRate(normalized);
  }

  void setDoubleSpeed(bool enabled) {
    if (_disposed ||
        _roomRateLocked ||
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
    if (_disposed || _roomRateLocked || !overlay.value.doubleSpeed) return;
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

  /// Applies room permissions at the player boundary so every platform layout
  /// observes the same control and playback-rate policy.
  Future<void> configureWatchParty({
    required bool connected,
    required bool canControl,
  }) async {
    _roomConnected = connected;
    _roomCanControl = canControl;
    _roomRateLocked = connected;
    if (connected && core.value.playbackRate != 1.0) {
      await setRate(1.0, roomCorrection: true);
    }
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
    // TV 上不允许 auto：选择「自动」立即归一化为 mediacodec-copy，
    // 保证会话内应用值与持久化值一致（resetPreferences 同样受益）。
    final hwdec = PlaybackSettingsService.normalizeHwdecMode(next.hwdecMode);
    if (hwdec != next.hwdecMode) next = next.copyWith(hwdecMode: hwdec);
    if (previous == next) return;
    preferences.value = next;
    if (previous.longPressSpeed != next.longPressSpeed) {
      _notifyToastChanged();
    }

    if (previous.videoEnhancementMode != next.videoEnhancementMode) {
      await _syncVideoEnhancement();
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
      await _backend.setNativeProperty(
        'hwdec',
        effectiveHwdec(next.hwdecMode, next.videoRenderer),
      );
    }
    if (previous.videoRenderer != next.videoRenderer) {
      if (Platform.isAndroid) {
        // Android 的 vo 切换不能对运行中的实例热设置：gpu-next 不在当前
        // mpv 构建中，且反复 set vo 会残留损坏的 GPU 上下文与 MediaCodec
        // Surface（日志中的 vo=null、textureId=0、MediaCodec start failed）。
        // 完整重建 Player + VideoController，在全新 Surface 上按新渲染器
        // 重新打开当前媒体。
        await _rebuildBackendForRenderer(next.videoRenderer);
      } else {
        await syncMpvProperties(
          _backend.setNativeProperty,
          buildRendererSwitchProperties(
            renderer: next.videoRenderer,
            hwdecMode: next.hwdecMode,
          ),
          debugLabel: 'video renderer',
        );
      }
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

  Future<bool> toggleVideoEnhancement() async {
    final current = preferences.value;
    final enabling = current.videoEnhancementMode == VideoEnhancementMode.off;
    final mode = enabling
        ? current.lastVideoEnhancementMode
        : VideoEnhancementMode.off;
    await updatePreferences(
      current.copyWith(
        videoEnhancementMode: mode,
        lastVideoEnhancementMode: enabling
            ? mode
            : current.videoEnhancementMode,
      ),
    );
    return enabling;
  }

  Future<void> setVideoEnhancementMode(VideoEnhancementMode mode) async {
    final current = preferences.value;
    if (current.videoEnhancementMode == mode) return;
    await updatePreferences(
      current.copyWith(
        videoEnhancementMode: mode,
        lastVideoEnhancementMode: mode == VideoEnhancementMode.off
            ? current.lastVideoEnhancementMode
            : mode,
      ),
    );
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

  Future<PlaybackTechnicalInfo> loadTechnicalInfo() async {
    await initialize();
    final info = await _backend.getTechnicalInfo();
    final settings = preferences.value;
    final actual = enhancement.value;
    return info.copyWith(
      rendererProfile: settings.videoRenderer,
      hardwareDecodeMode: settings.hwdecMode,
      requestedEnhancementMode: actual.requestedMode,
      appliedEnhancementPipeline: actual.appliedPipeline,
      enhancementFallbackReason: actual.fallbackReason,
    );
  }

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
        lowMemoryMode: PlaybackSettingsService.getLowMemoryMode(),
        mediaUri: _lastOpenUri,
      ),
      debugLabel: 'player',
    );
    await _syncVideoEnhancement();
    await _syncSubtitleConfig();
    await _backend.setNativeProperty(
      'sub-visibility',
      preferences.value.showSubtitle ? 'yes' : 'no',
    );
    await setRate(rate);
  }

  /// Android 渲染器切换：整体重建 Player 与 VideoController。
  ///
  /// 旧实例连同其 GPU 上下文 / MediaCodec Surface 一起释放，再按新渲染器
  /// 创建全新实例，最后在当前位置恢复播放，避免热切换 vo 后残留损坏的
  /// 视频输出链路。
  Future<void> _rebuildBackendForRenderer(String renderer) async {
    final wasPlaying = _backend.isPlaying;
    final position = _backend.currentPosition;
    final mediaUri = _backend.currentMediaUri;
    final subtitleTrack = _backend.currentSubtitleTrack;
    final rate = core.value.playbackRate;

    await _unbindBackend();
    videoController.value = null;
    await _backend.dispose();
    if (_disposed) return;
    await _backend.initialize(videoRenderer: renderer);
    if (_disposed) return;
    videoController.value = _backend.videoController;
    _bindBackend();
    _resetPlaybackState();
    await _configurePlayer(rate);
    if (mediaUri == null) return;
    await _backend.open(
      mediaUri,
      autoplay: wasPlaying,
      httpHeaders: _lastOpenHeaders,
    );
    if (_disposed) return;
    // 新 VideoController 创建后会重置 hwdec，因此重新应用。
    await _reapplyHwdec();
    if (position > Duration.zero) {
      await _backend.seek(position);
    }
    if (subtitleTrack.id != 'auto' && subtitleTrack.id != 'no') {
      try {
        await _backend.setSubtitleTrack(subtitleTrack);
      } catch (error) {
        debugPrint('重建后恢复字幕轨道失败: $error');
      }
    }
  }

  Future<void> _syncVideoEnhancement() async {
    final mode = preferences.value.videoEnhancementMode;
    final pipeline = selectEnhancementPipeline(mode);
    final shaderPath = await Anime4K.shaderPath(pipeline);
    await _backend.setNativeProperty('glsl-shaders', shaderPath);
    if (_disposed) return;
    enhancement.value = enhancement.value.copyWith(
      requestedMode: mode,
      appliedPipeline: pipeline,
      clearFallbackReason: true,
    );
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
    enhancement.value = VideoEnhancementState(
      requestedMode: preferences.value.videoEnhancementMode,
    );
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
    _eofReached = false;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _hideControlsTimer?.cancel();
    _skipCancelHideTimer?.cancel();
    _jumpPromptTimer?.cancel();
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
    enhancement.dispose();
    videoController.dispose();
  }
}
