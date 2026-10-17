import 'dart:async';
import 'dart:io';

import 'package:baka/models/skip_segment.dart';
import 'package:baka/models/skip_selection.dart';
import 'package:baka/services/playback/skip_segments.dart';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:baka/models/playback_state.dart';
import 'package:baka/models/subtitle_config.dart';
import 'package:baka/services/playback/anime4k.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/core/app_logger.dart';
import 'package:baka/utils/format_utils.dart';

const String mediacodecEmbedRenderer = 'mediacodec_embed';

class PlaybackController {
  PlaybackController() {
    timeline.addListener(_validateSkipSelection);
  }

  static const videoFitTypes = <({BoxFit fit, String description})>[
    (fit: BoxFit.contain, description: '画面'),
    (fit: BoxFit.cover, description: '覆盖'),
    (fit: BoxFit.fill, description: '填充'),
    (fit: BoxFit.fitHeight, description: '高度适应'),
    (fit: BoxFit.fitWidth, description: '宽度适应'),
  ];

  static const _timelineIntervalMs = 250;
  static const _skipCancelVisibleDuration = Duration(seconds: 5);
  static const _reverseTickInterval = Duration(milliseconds: 100);
  static const _longPressPixelsPerRate = 32.0;
  static const _maxLongPressRate = 5.0;

  Player? _player;
  final skipData = ValueNotifier<SkipData>(const SkipData());
  final skipSelection = ValueNotifier<SkipSelection?>(null);
  bool _playingBeforeSkipSelection = false;
  int? _pendingSelectionSeek;
  bool _selectionSeeking = false;
  int _selectionGeneration = 0;
  final skipService = SkipSegmentsService();
  final _skipSession = SkipSession();
  SkipSegment? _activeSkipSegment;
  Duration? _skipReturnPosition;
  int _skipGeneration = 0;
  int _skipDuration = 0;
  SkipContext? get skipContext => skipData.value.context;
  bool get canControlPlayback => !_roomConnected || _roomCanControl;

  final core = ValueNotifier<PlaybackCoreState>(const PlaybackCoreState());
  final timeline = ValueNotifier<PlaybackTimelineState>(
    const PlaybackTimelineState(),
  );
  final overlay = ValueNotifier<PlayerOverlayState>(const PlayerOverlayState());
  final preferences = ValueNotifier<PlaybackPreferences>(
    const PlaybackPreferences(),
  );
  final mediaInfo = ValueNotifier<PlaybackMediaInfo>(const PlaybackMediaInfo());
  final enhancement = ValueNotifier<VideoEnhancementState>(
    const VideoEnhancementState(),
  );
  final videoController = ValueNotifier<VideoController?>(null);

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<Duration> _seekEvents =
      StreamController<Duration>.broadcast();

  Timer? _hideControlsTimer;
  Timer? _skipCancelHideTimer;
  Timer? _reversePlaybackTimer;

  Future<void>? _initializeFuture;
  Future<void>? _disposeFuture;
  Future<void> _settingsWrites = Future<void>.value();
  PlaybackPreferences _persistedPreferences = const PlaybackPreferences();
  DanmakuController? _danmakuController;

  double _lastPlaybackRate = 1.0;
  double _longPressStartRate = 1.0;
  bool _playingBeforeLongPress = false;
  bool _reverseSeekInFlight = false;
  int _lastTimelineBucket = -1;
  bool _disposed = false;
  bool _roomConnected = false;
  bool _roomCanControl = true;
  bool _eofReached = false;

  String? get currentMediaUri =>
      _player?.state.playlist.medias.firstOrNull?.uri;
  List<SubtitleTrack> get subtitleTracks =>
      _player?.state.tracks.subtitle ?? const <SubtitleTrack>[];
  SubtitleTrack get currentSubtitleTrack =>
      _player?.state.track.subtitle ?? SubtitleTrack.no();
  DanmakuController get danmakuController =>
      _danmakuController ??
      (throw StateError('Danmaku controller is not attached'));
  Stream<void> get completed => _completed.stream;
  Stream<Duration> get seekEvents => _seekEvents.stream;

  Future<void> initialize() => _initializeFuture ??= _initialize();

  Future<void> _initialize() async {
    final stored = PlaybackSettingsService.loadAll();
    var loaded = stored;
    if (Platform.isAndroid &&
        loaded.videoRenderer == mediacodecEmbedRenderer &&
        loaded.videoEnhancementMode != VideoEnhancementMode.off) {
      loaded = loaded.copyWith(videoEnhancementMode: VideoEnhancementMode.off);
      await PlaybackSettingsService.saveChanges(stored, loaded);
    }
    if (_disposed) return;
    _persistedPreferences = loaded;
    if (preferences.value == const PlaybackPreferences()) {
      preferences.value = loaded;
    }
    overlay.value = overlay.value.copyWith(
      showDanmaku: !preferences.value.defaultDanmakuOff,
    );

    _createPlayer(preferences.value.videoRenderer);
  }

  void _createPlayer(String renderer) {
    MediaKit.ensureInitialized();
    final player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 8 * 1024 * 1024,
        title: 'BAKA Player',
      ),
    );
    _player = player;

    final embedded = Platform.isAndroid && renderer == mediacodecEmbedRenderer;
    videoController.value = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        vo: embedded ? mediacodecEmbedRenderer : null,
        hwdec: embedded ? 'mediacodec' : null,
      ),
    );
    _subscriptions.addAll([
      player.stream.playing.listen(_onPlayingChanged),
      player.stream.position.listen(_onPositionChanged),
      player.stream.duration.listen(_onDurationChanged),
      player.stream.buffer.listen(_onBufferedChanged),
      player.stream.buffering.listen(_onBufferingChanged),
      player.stream.error.listen(_onError),
      player.stream.completed.listen((completed) {
        _eofReached = completed;
        if (!_disposed && completed) _completed.add(null);
      }),
      player.stream.tracks.listen(_onTracksChanged),
    ]);
  }

  Future<void> open(
    String uri, {
    bool autoplay = true,
    Map<String, String>? httpHeaders,
    Duration? start,
  }) async {
    if (_disposed) return;
    try {
      _resetPlaybackState();
      await initialize();
      final player = _player;
      if (_disposed || player == null) return;
      if (currentMediaUri != null) await player.stop();
      await _configurePlayer(uri, preferences.value.defaultPlaybackSpeed);
      await player.open(
        Media(uri, httpHeaders: httpHeaders, start: start),
        play: autoplay,
      );
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

  Future<void> _setNativeProperty(String name, String value) async {
    final platform = _player?.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty(name, value);
      } catch (e) {
        debugPrint('setNativeProperty $name failed: $e');
      }
    }
  }

  Future<void> _reapplyHwdec() async {
    await _setNativeProperty(
      'hwdec',
      effectiveHwdec(
        preferences.value.hwdecMode,
        preferences.value.videoRenderer,
      ),
    );
  }

  void attachDanmaku(DanmakuController controller) {
    _danmakuController = controller;
    controller.playbackRate = core.value.playbackRate;
    controller.syncTime(timeline.value.position);
    _syncDanmakuActivity();
  }

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

  void _onPlayingChanged(bool playing) {
    if (_disposed) return;
    final current = core.value;
    final loading = playing ? false : current.loading;
    final buffering = playing ? false : current.buffering;
    final failed = playing ? false : current.failed;
    final errorMessage = playing ? '' : current.errorMessage;
    if (current.playing == playing &&
        current.loading == loading &&
        current.buffering == buffering &&
        current.failed == failed &&
        current.errorMessage == errorMessage) {
      return;
    }
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

    _danmakuController?.syncTime(position);
    final current = timeline.value;
    timeline.value = current.copyWith(
      position: position,
      previewPosition: current.seeking ? current.previewPosition : position,
    );
    _updateSkipState(position);
  }

  void _onDurationChanged(Duration duration) {
    if (_disposed ||
        duration == Duration.zero ||
        duration == timeline.value.duration) {
      return;
    }
    timeline.value = timeline.value.copyWith(duration: duration);
    unawaited(refreshSkipSegments());
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
    if (_disposed || core.value.buffering == buffering) return;
    core.value = core.value.copyWith(buffering: buffering);
    _syncDanmakuActivity();
  }

  void _onError(String error) {
    if (_disposed) return;
    final safeError = sanitizePlaybackError(error);
    AppLogger.instance.warning('Playback error: $safeError', tag: 'Playback');
    if ((_player?.state.playing ?? false) && !isFatalPlaybackError(safeError)) {
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
    unawaited(_player?.pause());
    _syncDanmakuActivity();
  }

  Future<void> play({bool remote = false}) async {
    if (_disposed || (!_roomCanControl && _roomConnected && !remote)) return;
    await _player?.play();
  }

  Future<void> pause({bool remote = false}) async {
    if (_disposed || (!_roomCanControl && _roomConnected && !remote)) return;
    await _player?.pause();
    _danmakuController?.pause();
  }

  Future<void> stop() async {
    if (_disposed) return;
    await _player?.stop();
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

  Future<void> seek(Duration target, {bool remote = false}) =>
      _seek(target, remote: remote);

  Future<void> _seek(
    Duration target, {
    bool remote = false,
    bool fromSkip = false,
  }) async {
    if (_disposed || (!_roomCanControl && _roomConnected && !remote)) return;
    // Calibration seeks move the video for inspection, not watch progress.
    // Capture this before awaiting the native seek: editing can end meanwhile.
    final previewingSelection = skipSelection.value != null;
    if (!fromSkip) {
      _skipSession.seek(target.inMilliseconds);
      _skipReturnPosition = null;
      _skipCancelHideTimer?.cancel();
      _setSkipState(SkipState.idle);
    }
    if (overlay.value.skipState == SkipState.waiting) {
      _setSkipState(SkipState.idle);
    }
    final resumeAfterSeek = _eofReached;
    final position = await _performSeek(target);
    if (resumeAfterSeek && !previewingSelection) {
      _eofReached = false;
      await play();
    }
    if (!previewingSelection && !_seekEvents.isClosed) {
      _seekEvents.add(position);
    }
  }

  Future<Duration> _performSeek(Duration target) async {
    final clamped = target.clamp(Duration.zero, timeline.value.duration);
    final current = timeline.value;
    timeline.value = current.copyWith(
      position: clamped,
      previewPosition: current.seeking ? current.previewPosition : clamped,
    );
    _lastTimelineBucket = clamped.inMilliseconds ~/ _timelineIntervalMs;
    await _player?.seek(clamped);
    _danmakuController?.syncTime(clamped);
    return clamped;
  }

  Future<void> setRate(double rate, {bool roomCorrection = false}) async {
    if (_disposed || (_roomConnected && !roomCorrection)) return;
    final normalized = rate > 0 ? rate : 1.0;
    if (core.value.playbackRate == normalized &&
        (_player == null || _player!.state.rate == normalized)) {
      return;
    }
    core.value = core.value.copyWith(playbackRate: normalized);
    _danmakuController?.playbackRate = normalized;
    await _player?.setRate(normalized);
  }

  void setDoubleSpeed(bool enabled) {
    if (_disposed ||
        _roomConnected ||
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
      _applyLongPressRate(_longPressStartRate);
      return;
    }

    _stopReversePlayback();
    overlay.value = overlay.value.copyWith(doubleSpeed: false);
    _restorePlaybackAfterLongPress();
  }

  void updateDoubleSpeedOffset(double horizontalOffset) {
    if (_disposed || _roomConnected || !overlay.value.doubleSpeed) return;
    final rate =
        (_longPressStartRate + horizontalOffset / _longPressPixelsPerRate)
            .clamp(-_maxLongPressRate, _maxLongPressRate)
            .toDouble();
    final steppedRate = (rate * 10).round() / 10;
    if (overlay.value.longPressRate == steppedRate) return;
    overlay.value = overlay.value.copyWith(longPressRate: steppedRate);
    _applyLongPressRate(steppedRate);
  }

  Future<void> configureWatchParty({
    required bool connected,
    required bool canControl,
  }) async {
    _roomConnected = connected;
    _roomCanControl = canControl;
    _updateSkipSuggestion();
    if (!canControlPlayback) {
      cancelSkipSelection(restorePlayback: false);
      userActionCancelSkip();
    }
    if (connected && core.value.playbackRate != 1.0) {
      await setRate(1.0, roomCorrection: true);
    }
  }

  Future<void> _applyLongPressRate(double rate) async {
    if (_disposed || !overlay.value.doubleSpeed) return;
    if (rate > 0) {
      _stopReversePlayback();
      await setRate(rate);
      if (_playingBeforeLongPress &&
          overlay.value.doubleSpeed &&
          overlay.value.longPressRate == rate &&
          !core.value.playing) {
        await play();
      }
      return;
    }

    if (rate == 0) _stopReversePlayback();
    if (core.value.playing) await pause();
    if (rate < 0 &&
        !_disposed &&
        overlay.value.doubleSpeed &&
        overlay.value.longPressRate == rate) {
      _reversePlaybackTimer ??= Timer.periodic(
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
            (_reverseTickInterval.inMilliseconds *
                    overlay.value.longPressRate.abs())
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
    timeline.value = timeline.value.copyWith(
      seeking: true,
      previewPosition: timeline.value.position,
    );
  }

  void updateSeekPreview(Duration value) {
    if (timeline.value.previewPosition == value) return;
    timeline.value = timeline.value.copyWith(previewPosition: value);
  }

  void endSeekPreview() {
    if (!timeline.value.seeking) return;
    timeline.value = timeline.value.copyWith(seeking: false);
    setControlsVisible(true);
  }

  void setControlsVisible(bool visible) {
    if (_disposed) return;
    if (skipSelection.value != null) visible = true;
    if (overlay.value.controlsLocked && visible) return;
    if (overlay.value.controlsVisible != visible) {
      overlay.value = overlay.value.copyWith(controlsVisible: visible);
    }
    _hideControlsTimer?.cancel();
    if (visible && skipSelection.value == null) {
      _hideControlsTimer = Timer(const Duration(seconds: 3), () {
        if (_disposed || timeline.value.seeking) return;
        overlay.value = overlay.value.copyWith(controlsVisible: false);
      });
    }
  }

  void toggleControls() => setControlsVisible(!overlay.value.controlsVisible);

  void setControlsLocked(bool locked) {
    if (_disposed || overlay.value.controlsLocked == locked) return;
    if (locked && skipSelection.value != null) return;
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

  void setSkipContext(SkipContext? context) {
    cancelSkipSelection(restorePlayback: false);
    _skipGeneration++;
    _skipDuration = 0;
    _skipSession.reset();
    _activeSkipSegment = null;
    _skipReturnPosition = null;
    _skipCancelHideTimer?.cancel();
    _setSkipState(SkipState.idle);
    skipData.value = SkipData(
      context: context == null ? null : skipService.restoreBinding(context),
    );
    _updateSkipSuggestion();
    if (context != null) unawaited(refreshSkipSegments());
  }

  void _updateSkipSuggestion() {
    final context = skipContext;
    final key = context?.suggestionKey;
    final visible =
        context?.episodeNumber == 2 &&
        key != null &&
        !preferences.value.enableSkipOpEd &&
        canControlPlayback &&
        !skipService.hasAnsweredSuggestion(key);
    if (overlay.value.showSkipSuggestion != visible) {
      overlay.value = overlay.value.copyWith(showSkipSuggestion: visible);
    }
  }

  Future<void> answerSkipSuggestion(bool enable) async {
    final key = skipContext?.suggestionKey;
    if (_disposed || !canControlPlayback || key == null) return;
    overlay.value = overlay.value.copyWith(showSkipSuggestion: false);
    await skipService.rememberSuggestion(key);
    if (_disposed) return;
    if (enable) {
      await updatePreferences(preferences.value.copyWith(enableSkipOpEd: true));
    }
  }

  Future<void> refreshSkipSegments({bool force = false}) async {
    final context = skipContext;
    final duration = timeline.value.duration.inMilliseconds;
    if (_disposed || context == null || duration <= 0) return;
    if (!force && _skipDuration == duration) return;
    _skipDuration = duration;
    final generation = ++_skipGeneration;
    // Apply personal edits immediately, even while the server is unavailable.
    final local = skipService.mergeLocal(
      context,
      duration,
      skipData.value.editableSegments.where((s) => s.origin != 'local'),
      message: skipData.value.message,
    );
    skipData.value = local;
    _skipSession.install(
      local.segments,
      timeline.value.position.inMilliseconds,
    );
    // Markers and manual ending actions also need data with auto-skip off.
    final data = await skipService.load(context, duration);
    if (_disposed || generation != _skipGeneration) return;
    skipData.value = data;
    _skipSession.install(data.segments, timeline.value.position.inMilliseconds);
  }

  void _updateSkipState(Duration position) {
    if (skipSelection.value != null) return;
    final context = skipContext;
    if (context == null || context.isFirstEpisode) {
      if (overlay.value.skipState == SkipState.waiting) {
        _setSkipState(SkipState.idle);
      }
      return;
    }
    final result = _skipSession.observe(
      position.inMilliseconds,
      duration: timeline.value.duration.inMilliseconds,
      episodeNumber: context.episodeNumber,
      canAuto:
          preferences.value.enableSkipOpEd &&
          core.value.playing &&
          !core.value.loading &&
          !core.value.buffering &&
          !timeline.value.seeking &&
          !overlay.value.showSkipSuggestion &&
          canControlPlayback,
    );
    if (overlay.value.skipState == SkipState.showingCancel ||
        overlay.value.skipState == SkipState.ending) {
      return;
    }
    if (result == null ||
        overlay.value.showSkipSuggestion ||
        !canControlPlayback) {
      _setSkipState(SkipState.idle);
      return;
    }
    _activeSkipSegment = result.segment;
    if (result.automatic) {
      _skipCurrentSegment(automatic: true);
    } else {
      _setSkipState(SkipState.waiting, label: result.segment.label);
    }
  }

  void _setSkipState(SkipState state, {String? label, bool automatic = false}) {
    final current = overlay.value;
    if (current.skipState == state &&
        (label == null || label == current.skipLabel) &&
        current.skipWasAutomatic == automatic) {
      return;
    }
    overlay.value = current.copyWith(
      skipState: state,
      skipLabel: label,
      skipWasAutomatic: automatic,
    );
  }

  void userActionSkip() => _skipCurrentSegment(automatic: false);

  bool beginSkipSelection(String type) {
    final context = skipContext;
    final duration = timeline.value.duration.inMilliseconds;
    if (_disposed ||
        !canControlPlayback ||
        context == null ||
        duration <= 0 ||
        (type != 'op' && type != 'ed') ||
        skipSelection.value?.saving == true) {
      return false;
    }
    final previous = skipSelection.value;
    var range = type == 'op' ? previous?.ranges.op : previous?.ranges.ed;
    if (range == null) {
      final segment = skipData.value.editableSegments
          .where((s) => s.type == type && s.canPreview(duration))
          .firstOrNull;
      if (segment != null) {
        range = (startMs: segment.startMs, endMs: segment.endMs);
      } else {
        // A new ending starts near the tail, independent of the current playhead.
        // Switching back to a new opening must not reuse that ending position.
        final position = type == 'ed'
            ? duration - 90000
            : previous?.type == 'ed'
            ? 0
            : timeline.value.position.inMilliseconds;
        final start = position.clamp(0, duration - 1);
        range = (
          startMs: start,
          endMs: (start + 90000).clamp(start + 1, duration),
        );
      }
    }
    if (previous == null) {
      _selectionGeneration++;
      _playingBeforeSkipSelection = core.value.playing;
      _skipCancelHideTimer?.cancel();
      _setSkipState(SkipState.idle);
      overlay.value = overlay.value.copyWith(
        controlsLocked: false,
        showDanmakuInput: false,
        showSkipSuggestion: false,
      );
    }
    skipSelection.value = SkipSelection(
      context: context,
      durationMs: duration,
      type: type,
      ranges: (
        op: type == 'op' ? range : previous?.ranges.op,
        ed: type == 'ed' ? range : previous?.ranges.ed,
      ),
      changed: previous?.changed ?? (op: false, ed: false),
    );
    if (previous?.type != type) {
      _pendingSelectionSeek = range.startMs;
      if (!_selectionSeeking) unawaited(_seekSelectionBoundary());
    }
    setControlsVisible(true);
    return true;
  }

  void _validateSkipSelection() {
    final selection = skipSelection.value;
    if (selection != null &&
        selection.durationMs != timeline.value.duration.inMilliseconds) {
      cancelSkipSelection(restorePlayback: false);
    }
  }

  void updateSkipSelection(int startMs, int endMs) {
    final selection = skipSelection.value;
    if (_disposed ||
        selection == null ||
        selection.saving ||
        !canControlPlayback) {
      return;
    }
    final start = startMs.clamp(0, selection.durationMs - 1);
    final end = endMs.clamp(start + 1, selection.durationMs);
    final old = selection.range;
    if (old.startMs == start && old.endMs == end) return;
    skipSelection.value = selection.copyWith(
      ranges: (
        op: selection.type == 'op'
            ? (startMs: start, endMs: end)
            : selection.ranges.op,
        ed: selection.type == 'ed'
            ? (startMs: start, endMs: end)
            : selection.ranges.ed,
      ),
      changed: (
        op: selection.changed.op || selection.type == 'op',
        ed: selection.changed.ed || selection.type == 'ed',
      ),
    );
    _pendingSelectionSeek = old.startMs != start ? start : end;
    if (!_selectionSeeking) unawaited(_seekSelectionBoundary());
  }

  Future<void> _seekSelectionBoundary() async {
    _selectionSeeking = true;
    final context = skipSelection.value?.context;
    final generation = _selectionGeneration;
    try {
      // Keep the latest drag position while the native player is seeking.
      await pause();
      while (!_disposed &&
          generation == _selectionGeneration &&
          identical(skipContext, context) &&
          skipSelection.value != null &&
          _pendingSelectionSeek != null) {
        final target = _pendingSelectionSeek!;
        _pendingSelectionSeek = null;
        await seek(Duration(milliseconds: target));
      }
    } finally {
      _selectionSeeking = false;
      if (!_disposed &&
          skipSelection.value != null &&
          _pendingSelectionSeek != null) {
        unawaited(_seekSelectionBoundary());
      }
    }
  }

  Future<bool> finishSkipSelection({bool allEpisodes = false}) async {
    final selection = skipSelection.value;
    if (_disposed ||
        selection == null ||
        selection.saving ||
        !canControlPlayback) {
      return false;
    }
    final saving = selection.copyWith(saving: true);
    skipSelection.value = saving;
    try {
      for (final type in const ['op', 'ed']) {
        if (type != selection.type &&
            !(type == 'op' ? selection.changed.op : selection.changed.ed)) {
          continue;
        }
        if (_disposed ||
            !identical(skipSelection.value, saving) ||
            !identical(skipContext, selection.context)) {
          return false;
        }
        await skipService.saveLocal(
          selection.context,
          selection.segment(type),
          allEpisodes: allEpisodes && type == selection.type,
        );
      }
      if (_disposed || !identical(skipSelection.value, saving)) return false;
      // Refresh installs local markers synchronously before the network lookup.
      unawaited(refreshSkipSegments(force: true));
      cancelSkipSelection();
      return true;
    } catch (_) {
      if (!_disposed && identical(skipSelection.value, saving)) {
        skipSelection.value = selection;
      }
      rethrow;
    }
  }

  void cancelSkipSelection({bool restorePlayback = true}) {
    if (_disposed || skipSelection.value == null) return;
    _selectionGeneration++;
    _pendingSelectionSeek = null;
    skipSelection.value = null;
    setControlsVisible(true);
    if (restorePlayback && _playingBeforeSkipSelection) unawaited(play());
    _playingBeforeSkipSelection = false;
  }

  void previewSkipSegment(SkipSegment segment) {
    if (!canControlPlayback ||
        !segment.canPreview(timeline.value.duration.inMilliseconds)) {
      return;
    }
    _activeSkipSegment = segment;
    _skipCurrentSegment(automatic: false);
  }

  void _skipCurrentSegment({required bool automatic}) {
    final segment = _activeSkipSegment;
    if (segment == null ||
        skipContext?.isFirstEpisode == true ||
        !canControlPlayback ||
        !(automatic
            ? segment.fits(timeline.value.duration.inMilliseconds)
            : segment.canPreview(timeline.value.duration.inMilliseconds))) {
      return;
    }
    _skipSession.suppress(segment);
    _skipReturnPosition = timeline.value.position;
    _setSkipState(
      SkipState.showingCancel,
      label: segment.label,
      automatic: automatic,
    );
    unawaited(_seek(Duration(milliseconds: segment.endMs), fromSkip: true));
    _skipCancelHideTimer?.cancel();
    _skipCancelHideTimer = Timer(_skipCancelVisibleDuration, () {
      if (_disposed) return;
      _skipReturnPosition = null;
      if (overlay.value.skipState == SkipState.showingCancel) {
        _setSkipState(
          segment.type == 'ed' ? SkipState.ending : SkipState.idle,
          label: segment.label,
          automatic: automatic,
        );
      }
    });
  }

  void userActionCancelSkip() {
    final segment = _activeSkipSegment;
    if (segment != null) _skipSession.dismiss(segment);
    _skipCancelHideTimer?.cancel();
    _skipReturnPosition = null;
    _setSkipState(SkipState.idle);
  }

  void cancelSkipOpEd() {
    final target = _skipReturnPosition;
    if (target == null || !canControlPlayback) return;
    userActionCancelSkip();
    unawaited(_seek(target, fromSkip: true));
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
    final hwdec = PlaybackSettingsService.normalizeHwdecMode(next.hwdecMode);
    if (hwdec != next.hwdecMode) next = next.copyWith(hwdecMode: hwdec);
    if (Platform.isAndroid) {
      final rendererChanged = previous.videoRenderer != next.videoRenderer;
      final enhancementChanged =
          previous.videoEnhancementMode != next.videoEnhancementMode;
      if (rendererChanged &&
          next.videoRenderer == mediacodecEmbedRenderer &&
          next.videoEnhancementMode != VideoEnhancementMode.off) {
        next = next.copyWith(videoEnhancementMode: VideoEnhancementMode.off);
      } else if (enhancementChanged &&
          next.videoEnhancementMode != VideoEnhancementMode.off &&
          next.videoRenderer == mediacodecEmbedRenderer) {
        next = next.copyWith(videoRenderer: 'gpu');
      }
    }
    if (previous == next) {
      if (persist) await _persistPreferences(next);
      return;
    }
    preferences.value = next;
    _updateSkipSuggestion();
    if (next.enableSkipOpEd != previous.enableSkipOpEd) {
      if (next.enableSkipOpEd) {
        unawaited(refreshSkipSegments(force: true));
      } else {
        userActionCancelSkip();
      }
    }

    if (previous.videoEnhancementMode != next.videoEnhancementMode) {
      await _syncVideoEnhancement();
    }
    if (previous.subtitleConfig != next.subtitleConfig) {
      await _syncSubtitleConfig();
    }
    if (previous.showSubtitle != next.showSubtitle) {
      await _setNativeProperty(
        'sub-visibility',
        next.showSubtitle ? 'yes' : 'no',
      );
    }
    if (previous.hwdecMode != next.hwdecMode) {
      await _setNativeProperty(
        'hwdec',
        effectiveHwdec(next.hwdecMode, next.videoRenderer),
      );
    }
    if (previous.videoRenderer != next.videoRenderer) {
      if (Platform.isAndroid) {
        await _rebuildForRenderer(next.videoRenderer);
      } else {
        await _syncProperties(buildVideoRendererProperties(next.videoRenderer));
      }
    }
    if (persist) await _persistPreferences(next);
    if (previous.filterHlsAds != next.filterHlsAds) {
      await onHlsAdFilterChanged?.call(next.filterHlsAds);
    }
  }

  Future<void> _persistPreferences(PlaybackPreferences next) =>
      _settingsWrites = _settingsWrites.then((_) async {
        await PlaybackSettingsService.saveChanges(_persistedPreferences, next);
        _persistedPreferences = next;
      });

  /// 清单处理属于播放页面；切换去广告时由页面重新准备当前媒体。
  Future<void> Function(bool enabled)? onHlsAdFilterChanged;

  Future<void> setVideoFit(BoxFit fit, String description) => updatePreferences(
    preferences.value.copyWith(videoFit: fit, videoFitDescription: description),
    persist: false,
  );

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
  }) => updatePreferences(
    preferences.value.copyWith(subtitleConfig: config),
    persist: persist,
  );

  Future<void> toggleSubtitle() => updatePreferences(
    preferences.value.copyWith(showSubtitle: !preferences.value.showSubtitle),
  );

  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    await _player?.setSubtitleTrack(track);
  }

  Future<PlaybackTechnicalInfo> loadTechnicalInfo() async {
    final player = _player;
    if (player == null || _disposed) return const PlaybackTechnicalInfo();
    final properties = await _readNativeProperties(player);
    if (_disposed || !identical(player, _player)) {
      return const PlaybackTechnicalInfo();
    }
    final state = player.state;
    return PlaybackTechnicalInfo(
      width: state.videoParams.w,
      height: state.videoParams.h,
      framesPerSecond: double.tryParse(properties['estimated-vf-fps'] ?? ''),
      videoBitrate: double.tryParse(properties['video-bitrate'] ?? '')?.round(),
      videoCodec: properties['video-codec-name'],
      hardwareDecoder: properties['hwdec-current'],
      videoOutput: properties['current-vo'],
      audioBitrate: double.tryParse(properties['audio-bitrate'] ?? '')?.round(),
      audioChannels: state.audioParams.channelCount,
      audioCodec: properties['audio-codec-name'],
      frameDropCount: int.tryParse(properties['frame-drop-count'] ?? ''),
      delayedFrameCount: int.tryParse(
        properties['vo-delayed-frame-count'] ?? '',
      ),
      rendererProfile: preferences.value.videoRenderer,
      appliedEnhancementPipeline: enhancement.value.appliedPipeline,
    );
  }

  Future<void> resetPreferences() {
    const defaults = PlaybackPreferences();
    overlay.value = overlay.value.copyWith(showDanmaku: true);
    return updatePreferences(defaults);
  }

  Future<void> _configurePlayer(String? mediaUri, double rate) async {
    await _syncProperties(
      buildPlayerProperties(
        hwdecMode: preferences.value.hwdecMode,
        videoRenderer: preferences.value.videoRenderer,
        videoEnhancementEnabled:
            preferences.value.videoEnhancementMode != VideoEnhancementMode.off,
        lowMemoryMode: PlaybackSettingsService.getLowMemoryMode(),
        mediaUri: mediaUri,
      ),
    );
    await _syncVideoEnhancement();
    await _syncSubtitleConfig();
    await _setNativeProperty(
      'sub-visibility',
      preferences.value.showSubtitle ? 'yes' : 'no',
    );
    await setRate(rate);
  }

  Future<void> _syncProperties(Map<String, String> properties) async {
    for (final entry in properties.entries) {
      await _setNativeProperty(entry.key, entry.value);
    }
  }

  Future<void> _rebuildForRenderer(String renderer) async {
    final player = _player;
    if (player == null) return;
    final wasPlaying = player.state.playing;
    final position = player.state.position;
    final media = player.state.playlist.medias.firstOrNull;
    final subtitleTrack = currentSubtitleTrack;
    final rate = core.value.playbackRate;
    final context = skipContext;

    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

    videoController.value = null;
    await player.dispose();
    _player = null;
    if (_disposed) return;
    _createPlayer(renderer);
    final newPlayer = _player!;
    _resetPlaybackState();
    await _configurePlayer(media?.uri, rate);

    if (media != null) {
      await newPlayer.open(
        Media(media.uri, httpHeaders: media.httpHeaders, start: position),
        play: wasPlaying,
      );
      if (_disposed) return;
      await _reapplyHwdec();
      setSkipContext(context);
      if (subtitleTrack.id != 'auto' && subtitleTrack.id != 'no') {
        try {
          await newPlayer.setSubtitleTrack(subtitleTrack);
        } catch (_) {}
      }
    }
  }

  Future<void> _syncVideoEnhancement() async {
    final mode = preferences.value.videoEnhancementMode;
    if (Platform.isAndroid &&
        preferences.value.videoRenderer == mediacodecEmbedRenderer &&
        mode != VideoEnhancementMode.off) {
      await _setNativeProperty('glsl-shaders', '');
      if (_disposed) return;
      enhancement.value = VideoEnhancementState(
        requestedMode: mode,
        appliedPipeline: VideoEnhancementMode.off,
        fallbackReason: 'mediacodec_embed 直接输出不经过 GPU 着色器',
      );
      return;
    }

    final framebuffer = buildVideoEnhancementFramebufferProperties(
      enabled: mode != VideoEnhancementMode.off,
    );
    if (mode == VideoEnhancementMode.off) {
      await _setNativeProperty('glsl-shaders', '');
    }
    await _syncProperties(framebuffer);
    if (mode != VideoEnhancementMode.off) {
      await _setNativeProperty('glsl-shaders', await Anime4K.shaderPath(mode));
    }
    if (_disposed) return;
    enhancement.value = VideoEnhancementState(
      requestedMode: mode,
      appliedPipeline: mode,
    );
  }

  Future<void> _syncSubtitleConfig() => _syncProperties(
    buildSubtitleProperties(preferences.value.subtitleConfig),
  );

  void _resetPlaybackState() {
    setSkipContext(null);
    _stopReversePlayback();
    _skipCancelHideTimer?.cancel();
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
    );
    _lastTimelineBucket = -1;
    _eofReached = false;
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    _hideControlsTimer?.cancel();
    _skipCancelHideTimer?.cancel();
    _reversePlaybackTimer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _danmakuController?.pause();
    _danmakuController = null;
    await _settingsWrites;
    final player = _player;
    _player = null;
    videoController.value = null;
    if (player != null) {
      try {
        await player.pause();
      } catch (_) {}
      await player.dispose();
    }
    await _completed.close();
    await _seekEvents.close();
    core.dispose();
    timeline.dispose();
    overlay.dispose();
    skipData.dispose();
    skipSelection.dispose();
    preferences.dispose();
    mediaInfo.dispose();
    enhancement.dispose();
    videoController.dispose();
  }
}

// ---------------- MPV 配置与诊断辅助工具 ---------------- //

const playerProperties = <String, String>{
  'volume-max': '100',
  'hwdec': 'auto',
  'hwdec-codecs': 'all',
  'cache': 'auto',
  'cache-secs': '12',
  'demuxer-max-bytes': '16777216',
  'demuxer-max-back-bytes': '4194304',
  'demuxer-hysteresis-secs': '3',
  'network-timeout': '30',
  'tls-verify': 'no',
  'user-agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
};

const localDemuxerLavfOptions =
    'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
    'protocol_whitelist=[file,http,https,tcp,udp,tls,data,crypto,ftp,rtp,rtsp,rtmp,srt]';

const networkDemuxerLavfOptions =
    'reconnect=1,multiple_requests=1,retry_open=3,hls_wrap=0,hls_allow_cache=1,'
    'fflags=+igndts+ignidx,tls_verify=0';

const lowMemoryPlayerProperties = <String, String>{
  'cache-secs': '5',
  'demuxer-max-bytes': '8388608',
  'demuxer-max-back-bytes': '2097152',
  'demuxer-hysteresis-secs': '2',
};

Map<String, String> buildPlayerProperties({
  String hwdecMode = 'auto',
  String videoRenderer = 'gpu',
  bool videoEnhancementEnabled = false,
  bool lowMemoryMode = false,
  bool? android,
  String? mediaUri,
}) {
  final isNetwork =
      mediaUri != null &&
      (mediaUri.startsWith('http://') || mediaUri.startsWith('https://'));
  return <String, String>{
    ...playerProperties,
    if (lowMemoryMode) ...lowMemoryPlayerProperties,
    'hwdec': effectiveHwdec(hwdecMode, videoRenderer, android: android),
    ...buildVideoRendererProperties(
      videoRenderer,
      android: android,
      videoEnhancementEnabled: videoEnhancementEnabled,
    ),
    'demuxer-lavf-o': isNetwork
        ? networkDemuxerLavfOptions
        : localDemuxerLavfOptions,
  };
}

String effectiveHwdec(String hwdecMode, String videoRenderer, {bool? android}) {
  final isAndroid = android ?? Platform.isAndroid;
  if (!isAndroid) return hwdecMode;
  if (videoRenderer == mediacodecEmbedRenderer) return 'mediacodec';
  return hwdecMode == 'auto' ? 'auto-safe' : hwdecMode;
}

bool isFatalPlaybackError(String error) {
  final message = error.toLowerCase();
  return message.contains('could not open codec') ||
      message.contains('failed to open codec');
}

Map<String, String> buildVideoRendererProperties(
  String renderer, {
  bool? android,
  bool videoEnhancementEnabled = false,
}) {
  final isAndroid = android ?? Platform.isAndroid;
  if (isAndroid) {
    return <String, String>{
      'gpu-context': 'android',
      'profile': 'fast',
      'fbo-format': videoEnhancementEnabled ? 'rgba16f' : 'rgba8',
      'deband': 'no',
      'interpolation': 'no',
      'scale': 'bilinear',
      'cscale': 'bilinear',
      'dscale': 'bilinear',
      'correct-downscaling': 'no',
      'linear-downscaling': 'no',
      'sigmoid-upscaling': 'no',
    };
  }

  if (renderer == 'gpu-next') {
    return const <String, String>{
      'scale': 'ewa_lanczossharp',
      'cscale': 'ewa_lanczossharp',
      'dscale': 'mitchell',
      'correct-downscaling': 'yes',
      'linear-downscaling': 'yes',
      'sigmoid-upscaling': 'yes',
    };
  }
  return const <String, String>{
    'scale': 'bilinear',
    'cscale': 'bilinear',
    'dscale': 'bilinear',
    'correct-downscaling': 'no',
    'linear-downscaling': 'no',
    'sigmoid-upscaling': 'no',
  };
}

Map<String, String> buildVideoEnhancementFramebufferProperties({
  required bool enabled,
  bool? android,
}) {
  final isAndroid = android ?? Platform.isAndroid;
  if (!isAndroid) return const <String, String>{};
  return <String, String>{'fbo-format': enabled ? 'rgba16f' : 'rgba8'};
}

String sanitizePlaybackError(Object error) {
  var message = error.toString();
  message = message.replaceAllMapped(
    RegExp(r'(https?:\/\/)([^\/\s?#@]+@)', caseSensitive: false),
    (match) => match.group(1)!,
  );
  message = message.replaceAll(
    RegExp(r'Authorization:\s*Basic\s+[A-Za-z0-9+/=]+', caseSensitive: false),
    'Authorization: Basic ***',
  );
  message = message.replaceAllMapped(
    RegExp(
      r'([?&](?:password|passwd|token|access_token|auth|authorization)=)[^&\s]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}***',
  );
  message = message.replaceAll(
    RegExp(r'[A-Za-z]:\\Users\\[^\\]+', caseSensitive: false),
    r'C:\Users\***',
  );
  message = message.replaceAll(
    RegExp(r'/(?:Users|home)/[^/]+', caseSensitive: false),
    '/Users/***',
  );
  return message;
}

Map<String, String> buildSubtitleProperties(SubtitleConfig config) {
  final subPos = config.position.round().clamp(0, 150);
  final subFontSize = config.fontSize.round().clamp(10, 100);

  return {
    'sub-pos': '$subPos',
    'sub-font-size': '$subFontSize',
    'sub-color': colorToMpv(
      config.fontColor.withValues(alpha: config.opacity * config.fontColor.a),
    ),
    'sub-border-size': config.borderWidth.toStringAsFixed(1),
    'sub-border-color': colorToMpv(config.borderColor),
    'sub-back-color': colorToMpv(config.backgroundColor),
    'sub-bold': config.bold ? 'yes' : 'no',
    'sub-visibility': 'no',
    if (config.fontFamily.isNotEmpty) 'sub-font': config.fontFamily,
    'sub-ass-override': 'force',
  };
}

String colorToMpv(Color color) {
  String byte(double value) {
    return (value * 255.0)
        .round()
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0');
  }

  return '#${byte(color.a)}${byte(color.r)}${byte(color.g)}${byte(color.b)}';
}

const _technicalPropertyNames = <String>[
  'current-vo',
  'hwdec-current',
  'video-codec-name',
  'estimated-vf-fps',
  'video-bitrate',
  'audio-codec-name',
  'audio-bitrate',
  'frame-drop-count',
  'vo-delayed-frame-count',
];

Future<Map<String, String>> _readNativeProperties(Player player) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return const <String, String>{};

  final result = <String, String>{};
  for (final name in _technicalPropertyNames) {
    final value = await platform.getProperty(name);
    if (value.isNotEmpty) result[name] = value;
  }
  return result;
}
