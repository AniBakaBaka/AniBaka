import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/utils/platform_page_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:fullscreen_window/fullscreen_window.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:baka/widgets/danmaku/view.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/baka_player/utils.dart';
import 'package:ios_orientation/ios_orientation.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'widgets/bottom_control.dart';
import 'package:baka/services/navigation_service.dart';
import 'widgets/danmaku_input_overlay.dart';
import 'widgets/player_dialogs.dart';
import 'widgets/player_indicators.dart';
import 'widgets/player_prompts.dart';

const _longPressDelay = Duration(milliseconds: 400);
const _seekStep = Duration(seconds: 10);
const _indicatorDuration = Duration(milliseconds: 800);
const _volumeStep = 0.05;
const _verticalGestureSensitivity = 2.0;

enum _VerticalControl { none, brightness, volume }

class BakaPlayer extends StatefulWidget {
  const BakaPlayer({
    required this.controller,
    this.full = false,
    this.canSearchSource = false,
    this.headerControl,
    this.onPickEpisode,
    this.danmakuEnabled = false,
    this.hasNextEpisode = false,
    this.onNextEpisode,
    this.onFullScreenChanged,
    this.focusNode,
    super.key,
  });

  final PlaybackController controller;
  final Widget? headerControl;
  final VoidCallback? onPickEpisode;
  final bool danmakuEnabled;
  final bool full;
  final bool canSearchSource;
  final bool hasNextEpisode;
  final VoidCallback? onNextEpisode;
  final ValueChanged<bool>? onFullScreenChanged;
  final FocusNode? focusNode;

  BakaPlayer fullscreenView() => BakaPlayer(
    controller: controller,
    full: true,
    headerControl: headerControl,
    danmakuEnabled: danmakuEnabled,
    onPickEpisode: onPickEpisode,
    canSearchSource: canSearchSource,
    hasNextEpisode: hasNextEpisode,
    onNextEpisode: onNextEpisode,
    onFullScreenChanged: onFullScreenChanged,
  );

  @override
  State<BakaPlayer> createState() => _BakaPlayerState();
}

class _BakaPlayerState extends State<BakaPlayer> {
  late final FocusNode _playerFocusNode;
  late final bool _ownsPlayerFocusNode;

  final ValueNotifier<int> _indicatorRevision = ValueNotifier(0);
  _VerticalControl _visibleVerticalIndicator = _VerticalControl.none;
  Timer? _indicatorTimer;
  Timer? _doubleSpeedTimer;
  Timer? _seekTimer;
  bool _fullscreenRouteActive = false;
  int _pendingSeekSeconds = 0;
  double _horizontalSeekScale = 0;
  double _pendingVerticalDelta = 0;
  double _verticalExtent = 1;
  _VerticalControl _verticalControl = _VerticalControl.none;
  bool _verticalFrameScheduled = false;
  bool _autoFullscreenTriggered = false;

  // 设备类型判断 - 在 dispose 时需要用到但无法访问 context
  bool _isTablet = false;
  bool get _canAdjustScreenBrightness => !Platform.isWindows;

  /// 触发全屏 - UI 状态切换由 view 负责
  Future<void> _triggerFullScreen() async {
    if (!widget.full) {
      if (Platform.isWindows) await FullScreenWindow.setFullScreen(true);
      if (!mounted) return;
      widget.onFullScreenChanged?.call(true);
      setState(() => _fullscreenRouteActive = true);
      Navigator.of(context)
          .push(
            platformPageRoute<void>(
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
              allowSnapshotting: false,
              builder: (_) => Scaffold(
                backgroundColor: Colors.black,
                body: widget.fullscreenView(),
              ),
            ),
          )
          .then((_) {
            if (mounted) setState(() => _fullscreenRouteActive = false);
            widget.onFullScreenChanged?.call(false);
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _requestKeyboardFocus(),
            );
          });
    } else {
      Navigator.pop(context);
    }
  }

  @override
  void initState() {
    super.initState();
    _ownsPlayerFocusNode = widget.focusNode == null;
    _playerFocusNode = widget.focusNode ?? FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playerFocusNode.requestFocus();
    });
    if (widget.full) _applyFullScreenMode();
    _initializeControls();
    widget.controller.core.addListener(_maybeAutoEnterFullscreen);
    _maybeAutoEnterFullscreen();
  }

  void _maybeAutoEnterFullscreen() {
    if (widget.full ||
        _autoFullscreenTriggered ||
        !widget.controller.core.value.playing ||
        !widget.controller.preferences.value.autoFullscreen) {
      return;
    }
    _autoFullscreenTriggered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _triggerFullScreen();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 在 didChangeDependencies 中判断设备类型，
    // 因为 dispose 时无法安全使用 MediaQuery，所以缓存到变量中
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    _isTablet = shortestSide >= 600;
  }

  void _requestKeyboardFocus() {
    if (mounted && !_playerFocusNode.hasFocus) {
      _playerFocusNode.requestFocus();
    }
  }

  /// 应用全屏模式
  void _applyFullScreenMode() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
    if (Platform.isIOS) {
      IosOrientation().setOrientation(OrientationIOS.landscapeLeft);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
    }
  }

  void _initializeControls() {
    if (widget.full) return;
    final controller = widget.controller;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        FlutterVolumeController.updateShowSystemUI(true);
        controller.setVolume(
          (await FlutterVolumeController.getVolume()) ?? 0.0,
        );
        FlutterVolumeController.addListener((double value) {
          if (mounted && _visibleVerticalIndicator != _VerticalControl.volume) {
            controller.setVolume(value);
          }
        });
      } catch (_) {}

      if (_canAdjustScreenBrightness) {
        try {
          controller.setBrightness(await ScreenBrightness().application);
        } catch (_) {}
      }
    });
  }

  Future<void> _setVerticalLevel(_VerticalControl control, double value) async {
    if (control == _VerticalControl.brightness && !_canAdjustScreenBrightness) {
      return;
    }
    final normalized = (value.clamp(0.0, 1.0).toDouble() * 100).round() / 100;
    final current = control == _VerticalControl.volume
        ? widget.controller.overlay.value.volume
        : widget.controller.overlay.value.brightness;
    if (_visibleVerticalIndicator != control) {
      _visibleVerticalIndicator = control;
      _indicatorRevision.value++;
    }
    _indicatorTimer?.cancel();
    _indicatorTimer = Timer(_indicatorDuration, () {
      if (!mounted) return;
      _visibleVerticalIndicator = _VerticalControl.none;
      _indicatorRevision.value++;
    });
    if (current == normalized) return;

    if (control == _VerticalControl.volume) {
      widget.controller.setVolume(normalized);
    } else {
      widget.controller.setBrightness(normalized);
    }

    try {
      if (control == _VerticalControl.volume) {
        FlutterVolumeController.updateShowSystemUI(false);
        await FlutterVolumeController.setVolume(normalized);
      } else {
        await ScreenBrightness().setApplicationScreenBrightness(normalized);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    widget.controller.core.removeListener(_maybeAutoEnterFullscreen);
    if (_ownsPlayerFocusNode) _playerFocusNode.dispose();
    if (!widget.full) FlutterVolumeController.removeListener();
    _indicatorTimer?.cancel();
    _doubleSpeedTimer?.cancel();
    _seekTimer?.cancel();
    _indicatorRevision.dispose();

    if (widget.full) {
      if (Platform.isWindows) {
        unawaited(FullScreenWindow.setFullScreen(false));
      }

      if (Instances.isTV) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
      }

      // 缓存 didChangeDependencies 中计算的 _isTablet 值，
      // 因为 MediaQuery 在 dispose 时 context 已失效无法使用
      if (Platform.isIOS) {
        if (_isTablet || Instances.isTV) {
          IosOrientation().setOrientation(OrientationIOS.landscapeLeft);
        } else {
          IosOrientation().setOrientation(OrientationIOS.portraitUp);
        }
      } else {
        if (_isTablet || Instances.isTV) {
          SystemChrome.setPreferredOrientations([
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
        } else {
          SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
        }
      }
    } else if (_canAdjustScreenBrightness) {
      unawaited(ScreenBrightness().resetApplicationScreenBrightness());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        fit: StackFit.passthrough,
        children: <Widget>[
          RepaintBoundary(child: _buildVideoPlayer()),
          PlayerLoadingIndicator(controller: widget.controller),
          PlayerToastIndicators(controller: widget.controller),
          Positioned.fill(
            child: ListenableBuilder(
              listenable: _indicatorRevision,
              builder: (context, _) => Stack(
                fit: StackFit.expand,
                children: [
                  PlayerVolumeBrightnessIndicators(
                    controller: widget.controller,
                    volumeVisible:
                        _visibleVerticalIndicator == _VerticalControl.volume,
                    brightnessVisible:
                        _visibleVerticalIndicator ==
                        _VerticalControl.brightness,
                  ),
                  PlayerSeekIndicator(seconds: _pendingSeekSeconds),
                ],
              ),
            ),
          ),
          _buildDanmaku(),
          _buildGestureDetector(),
          _buildControlsOverlay(
            Instances.isDesktopPlatform ||
                Instances.isTV ||
                (_isTablet && constraints.maxWidth >= 720),
          ),
          _buildLockButton(),
          PlayerErrorIndicator(
            controller: widget.controller,
            canSearchSource: widget.canSearchSource,
            onSearch: _navigateToSearch,
          ),
          PlayerPrompts(
            controller: widget.controller,
            isFullScreen: widget.full,
            hasNextEpisode: widget.hasNextEpisode,
            onNextEpisode: widget.onNextEpisode,
          ),
          _buildDanmakuInputOverlay(),
        ],
      ),
    );
  }

  Widget _buildDanmakuInputOverlay() {
    return ValueListenableBuilder<PlayerOverlayState>(
      valueListenable: widget.controller.overlay,
      builder: (context, overlay, _) {
        if (!overlay.showDanmakuInput) {
          return const SizedBox.shrink();
        }

        return DanmakuInputOverlay(
          controller: widget.controller,
          onSend: (text, color, type) {
            showSnackBar('\u53d1\u5c04\u6210\u529f');
            widget.controller.danmakuController.addItem(
              DanmakuItem(
                text,
                time: widget.controller.timeline.value.position.inMilliseconds,
                type: type,
                color: color,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildVideoPlayer() {
    return ValueListenableBuilder<VideoController?>(
      valueListenable: widget.controller.videoController,
      builder: (context, videoController, _) {
        if (videoController == null) {
          return const Center(
            child: SizedBox(
              height: 32,
              width: 32,
              child: CircularProgressIndicator(color: Colors.white),
            ),
          );
        }
        return ValueListenableBuilder<PlaybackPreferences>(
          valueListenable: widget.controller.preferences,
          builder: (context, preferences, _) {
            if (!widget.full && _fullscreenRouteActive) {
              return const ColoredBox(
                color: Colors.black,
                child: SizedBox.expand(),
              );
            }
            final cfg = preferences.subtitleConfig;
            final height = MediaQuery.sizeOf(context).height * 0.5;
            return ValueListenableBuilder<VideoEnhancementState>(
              valueListenable: widget.controller.enhancement,
              builder: (context, enhancement, _) => Video(
                controller: videoController,
                controls: NoVideoControls,
                pauseUponEnteringBackgroundMode: false,
                resumeUponEnteringForegroundMode: true,
                filterQuality: Platform.isAndroid && enhancement.enabled
                    ? FilterQuality.medium
                    : FilterQuality.low,
                subtitleViewConfiguration: SubtitleViewConfiguration(
                  visible: preferences.showSubtitle,
                  style: TextStyle(
                    height: 1.5,
                    fontSize: cfg.fontSize,
                    fontFamily: cfg.fontFamily.isEmpty ? null : cfg.fontFamily,
                    letterSpacing: 0.5,
                    color: cfg.fontColor.withValues(alpha: cfg.opacity),
                    fontWeight: cfg.bold ? FontWeight.w700 : FontWeight.w500,
                    backgroundColor: cfg.backgroundColor,
                    shadows: [
                      Shadow(
                        blurRadius: cfg.borderWidth * 2,
                        color: cfg.borderColor,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  padding: EdgeInsets.fromLTRB(
                    24,
                    cfg.position < 50 ? cfg.position / 100 * height : 0,
                    24,
                    cfg.position >= 50
                        ? (100 - cfg.position) / 100 * height + 24
                        : 24,
                  ),
                ),
                fit: preferences.videoFit,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDanmaku() {
    if (!widget.danmakuEnabled || !widget.full) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<PlayerOverlayState>(
      valueListenable: widget.controller.overlay,
      builder: (context, overlay, _) => overlay.showDanmaku
          ? Positioned.fill(
              top: 10,
              child: RepaintBoundary(
                child: DanmakuView(
                  controller: widget.controller.danmakuController,
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildGestureDetector() {
    final controller = widget.controller;
    return Positioned.fill(
      left: 16,
      top: 25,
      right: 15,
      bottom: 15,
      child: Focus(
        focusNode: _playerFocusNode,
        autofocus: true,
        onKeyEvent: (node, event) => _handleKeyEvent(event),
        child: GestureDetector(
          onTap: controller.toggleControls,
          onDoubleTapDown: (details) {
            _handleDoubleTap(
              details.localPosition.dx,
              MediaQuery.sizeOf(context).width,
            );
          },
          onLongPressStart: (_) => controller.setDoubleSpeed(true),
          onLongPressMoveUpdate: (details) =>
              controller.updateDoubleSpeedOffset(details.offsetFromOrigin.dx),
          onLongPressEnd: (_) => controller.setDoubleSpeed(false),
          onLongPressCancel: () => controller.setDoubleSpeed(false),
          onHorizontalDragStart: _handleHorizontalDragStart,
          onHorizontalDragUpdate: _handleHorizontalDragUpdate,
          onHorizontalDragEnd: (_) {
            final target = controller.timeline.value.previewPosition;
            controller.endSeekPreview();
            controller.seek(target, fromSlider: true);
          },
          onHorizontalDragCancel: controller.endSeekPreview,
          onVerticalDragStart: _handleVerticalDragStart,
          onVerticalDragUpdate: _handleVerticalDragUpdate,
          onVerticalDragEnd: (_) => _endVerticalDrag(),
          onVerticalDragCancel: _endVerticalDrag,
        ),
      ),
    );
  }

  void _handleDoubleTap(double x, double width) {
    final preferences = widget.controller.preferences.value;
    if (!preferences.enableDoubleTap) return;

    final section = width / 3;
    if (preferences.doubleTapAction == 'play_pause' ||
        (x >= section && x < section * 2)) {
      widget.controller.togglePlayback();
      return;
    }

    final direction = x < section ? -1 : 1;
    final step = preferences.doubleTapSeekDuration;
    final current = _pendingSeekSeconds;
    final next = current.sign == direction
        ? current + direction * step
        : direction * step;
    _pendingSeekSeconds = next;
    _indicatorRevision.value++;
    _seekTimer?.cancel();
    _seekTimer = Timer(_longPressDelay, () => unawaited(_commitPendingSeek()));
  }

  Future<void> _commitPendingSeek() async {
    final seconds = _pendingSeekSeconds;
    if (seconds == 0) return;
    if (mounted) {
      _pendingSeekSeconds = 0;
      _indicatorRevision.value++;
    }
    final timeline = widget.controller.timeline.value;
    final target = (timeline.position + Duration(seconds: seconds)).clamp(
      Duration.zero,
      timeline.duration,
    );
    await widget.controller.seek(target);
    await widget.controller.play();
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    final controller = widget.controller;

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (widget.full) {
          _triggerFullScreen();
          return KeyEventResult.handled;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        final timeline = controller.timeline.value;
        final newPosition = timeline.position - _seekStep;
        controller.seek(newPosition.clamp(Duration.zero, timeline.duration));
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _doubleSpeedTimer ??= Timer(_longPressDelay, () {
          if (!controller.overlay.value.doubleSpeed) {
            controller.setDoubleSpeed(true);
          }
        });
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (Instances.isTV) {
          return KeyEventResult.ignored;
        }
        final newVolume = (controller.overlay.value.volume + _volumeStep).clamp(
          0.0,
          1.0,
        );
        _setVerticalLevel(_VerticalControl.volume, newVolume);
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        if (Instances.isTV) {
          return KeyEventResult.ignored;
        }
        final newVolume = (controller.overlay.value.volume - _volumeStep).clamp(
          0.0,
          1.0,
        );
        _setVerticalLevel(_VerticalControl.volume, newVolume);
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.space) {
        widget.controller.togglePlayback();
        return KeyEventResult.handled;
      }
    } else if (event is KeyUpEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _doubleSpeedTimer?.cancel();
      _doubleSpeedTimer = null;

      final wasDoubleSpeed = controller.overlay.value.doubleSpeed;
      controller.setDoubleSpeed(false);
      if (!wasDoubleSpeed) {
        final timeline = controller.timeline.value;
        final newPosition = timeline.position + _seekStep;
        controller.seek(newPosition.clamp(Duration.zero, timeline.duration));
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _handleHorizontalDragStart(DragStartDetails details) {
    final controller = widget.controller;
    final durationMs = controller.timeline.value.duration.inMilliseconds;
    final seekWindowMs = (durationMs * 0.1).clamp(60000.0, 300000.0);
    _horizontalSeekScale =
        seekWindowMs /
        MediaQuery.sizeOf(context).width.clamp(1.0, double.infinity);
    controller.beginSeekPreview();
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    final controller = widget.controller;
    final next = Duration(
      milliseconds:
          controller.timeline.value.previewPosition.inMilliseconds +
          (details.delta.dx * _horizontalSeekScale).round(),
    );
    controller.updateSeekPreview(
      next.clamp(Duration.zero, controller.timeline.value.duration),
    );
  }

  void _handleVerticalDragStart(DragStartDetails details) {
    if (widget.controller.overlay.value.controlsLocked) return;
    final size = MediaQuery.sizeOf(context);
    final section = size.width / 3;
    if (details.localPosition.dx < section && _canAdjustScreenBrightness) {
      _verticalControl = _VerticalControl.brightness;
    } else if (details.localPosition.dx >= section * 2) {
      _verticalControl = _VerticalControl.volume;
    } else {
      _verticalControl = _VerticalControl.none;
    }
    _pendingVerticalDelta = 0;
    _verticalExtent = widget.full ? size.height : size.width * 9 / 16;
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (_verticalControl == _VerticalControl.none) return;
    _pendingVerticalDelta += details.delta.dy;
    if (_verticalFrameScheduled) return;
    _verticalFrameScheduled = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _verticalFrameScheduled = false;
      _applyVerticalDrag();
    });
  }

  void _applyVerticalDrag() {
    if (!mounted || _pendingVerticalDelta == 0) return;
    final delta =
        _pendingVerticalDelta * _verticalGestureSensitivity / _verticalExtent;
    _pendingVerticalDelta = 0;
    final overlay = widget.controller.overlay.value;
    if (_verticalControl == _VerticalControl.brightness) {
      unawaited(
        _setVerticalLevel(
          _VerticalControl.brightness,
          (overlay.brightness - delta).clamp(0.0, 1.0),
        ),
      );
    } else if (_verticalControl == _VerticalControl.volume) {
      unawaited(
        _setVerticalLevel(
          _VerticalControl.volume,
          (overlay.volume - delta).clamp(0.0, 1.0),
        ),
      );
    }
  }

  void _endVerticalDrag() {
    _applyVerticalDrag();
    _verticalControl = _VerticalControl.none;
  }

  Widget _buildControlsOverlay(bool isWide) {
    final controller = widget.controller;
    final headerContent = _buildHeaderContent(isWide);
    final danmakuBar = _buildDanmakuBar(isWide);
    final episodeTitle = _buildEpisodeTitle(isWide);
    final extraButtons = _buildExtraBottomButtons(isWide);

    return ValueListenableBuilder<PlayerOverlayState>(
      valueListenable: controller.overlay,
      builder: (context, overlay, _) {
        final showControls = overlay.controlsVisible;
        final isLocked = overlay.controlsLocked;

        return Column(
          children: [
            ClipRect(
              child: AnimatedSlide(
                offset: !isLocked && showControls
                    ? Offset.zero
                    : const Offset(0, -1),
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child: Padding(
                  padding: EdgeInsets.only(
                    top: isWide ? 20 : 8,
                    left: isWide ? 32 : 16,
                    right: isWide ? 32 : 16,
                  ),
                  child: headerContent,
                ),
              ),
            ),
            const Spacer(),
            ClipRect(
              child: AnimatedSlide(
                offset: !isLocked && showControls
                    ? Offset.zero
                    : const Offset(0, 1),
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child: BottomControl(
                  controller: controller,
                  triggerFullScreen: _triggerFullScreen,
                  isFullScreen: widget.full,
                  isWideLayout: isWide,
                  updatesEnabled: !isLocked && showControls,
                  danmakuBar: danmakuBar,
                  extraButtons: extraButtons,
                  episodeTitle: episodeTitle,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCapsule({required Widget child, double radius = 22}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.05),
          width: 0.5,
        ),
      ),
      child: child,
    );
  }

  Widget _buildHeaderContent(bool isWide) {
    final controller = widget.controller;
    return Row(
      children: [
        _buildCapsule(
          child: SizedBox(
            width: isWide ? 48 : 40,
            height: isWide ? 48 : 40,
            child: IconButton(
              icon: Icon(
                Icons.arrow_back_ios_new_rounded,
                color: Colors.white,
                size: isWide ? 22 : 18,
              ),
              onPressed: () => Navigator.pop(context),
              padding: EdgeInsets.zero,
            ),
          ),
        ),
        SizedBox(width: isWide ? 16 : 12),
        Expanded(
          child: widget.full
              ? ValueListenableBuilder<PlaybackMediaInfo>(
                  valueListenable: controller.mediaInfo,
                  builder: (context, mediaInfo, _) => Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildPlayerTitleOrLogo(
                        mediaInfo.title.isNotEmpty ? mediaInfo.title : '',
                        mediaInfo.logoUrl.isNotEmpty ? mediaInfo.logoUrl : '',
                        isWide,
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([
            controller.core,
            controller.preferences,
          ]),
          builder: (context, _) {
            final core = controller.core.value;
            final preferences = controller.preferences.value;
            final actions = <Widget>[];

            if (core.hasSubtitleTracks) {
              actions.add(
                _buildHeaderButton(
                  icon: preferences.showSubtitle
                      ? Icons.closed_caption_rounded
                      : Icons.closed_caption_disabled_rounded,
                  isWide: isWide,
                  onTap: () => controller.toggleSubtitle(),
                  onLongPress: () => NavigationService.showSubtitleSettings(
                    context,
                    controller,
                  ),
                  isActive: preferences.showSubtitle,
                ),
              );
            }

            if (widget.full && preferences.showSystemTime) {
              actions.add(
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: isWide ? 10 : 8),
                  child: Text(
                    _getCurrentTime(),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: isWide ? 16 : 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              );
            }

            if (widget.full) {
              actions.add(
                _buildHeaderButton(
                  text: preferences.videoFitDescription,
                  isWide: isWide,
                  onTap: () => showVideoFitDialog(context, controller),
                ),
              );
              actions.add(
                _buildHeaderButton(
                  text: '${core.playbackRate}x',
                  isWide: isWide,
                  onTap: () => showSpeedDialog(context, controller),
                ),
              );
            }

            if (widget.headerControl != null) {
              actions.add(widget.headerControl!);
            }

            actions.add(
              Tooltip(
                message: '播放器详情',
                child: _buildHeaderButton(
                  icon: Icons.info_outline_rounded,
                  isWide: isWide,
                  isActive: true,
                  onTap: () => showPlaybackDetailsSheet(context, controller),
                ),
              ),
            );

            if (actions.isEmpty) return const SizedBox.shrink();

            return _buildCapsule(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: actions),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildHeaderButton({
    required bool isWide,
    required VoidCallback onTap,
    String? text,
    IconData? icon,
    VoidCallback? onLongPress,
    bool isActive = false,
  }) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: text == null ? (isWide ? 10 : 8) : (isWide ? 12 : 10),
          vertical: isWide ? 8 : 6,
        ),
        child: icon != null
            ? Icon(
                icon,
                size: isWide ? 24 : 20,
                color: isActive
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.6),
              )
            : Text(
                text!,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: isWide ? 16 : 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }

  Widget _buildPlayerTitleOrLogo(String title, String logoUrl, bool isWide) {
    if (logoUrl.isNotEmpty) {
      return Container(
        constraints: BoxConstraints(maxHeight: isWide ? 58 : 46, maxWidth: 280),
        alignment: Alignment.centerLeft,
        child: CachedNetworkImage(
          key: ValueKey(logoUrl),
          imageUrl: logoUrl,
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          errorWidget: (context, url, error) => Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: isWide ? 20 : 16,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),
        ),
      );
    }

    return Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: Colors.white,
        fontSize: isWide ? 20 : 16,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.3,
      ),
    );
  }

  Widget? _buildEpisodeTitle(bool isWide) {
    if (!widget.full && !isWide) return null;
    if (widget.full && widget.onPickEpisode == null) return null;
    final controller = widget.controller;

    return ValueListenableBuilder<PlaybackMediaInfo>(
      valueListenable: controller.mediaInfo,
      builder: (context, mediaInfo, _) {
        final title = mediaInfo.episode;
        if (title.isEmpty) return const SizedBox.shrink();
        final epIndex = mediaInfo.episodeIndex;
        final display = 'E${epIndex + 1}: $title';

        return Tooltip(
          message: '选择剧集',
          child: InkWell(
            onTap: widget.onPickEpisode,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isWide ? 10 : 6,
                vertical: isWide ? 8 : 5,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: isWide ? 320 : 220),
                    child: Text(
                      display,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: isWide ? 16 : 13,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.onPickEpisode != null) ...[
                    SizedBox(width: isWide ? 6 : 4),
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Colors.white.withValues(alpha: 0.75),
                      size: isWide ? 20 : 16,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 构建弹幕栏（输入框入口和设置按钮）
  Widget? _buildDanmakuBar(bool isWide) {
    if (!widget.danmakuEnabled || !widget.full) return null;
    final controller = widget.controller;

    return ValueListenableBuilder<PlayerOverlayState>(
      valueListenable: controller.overlay,
      builder: (context, overlay, _) {
        if (!overlay.showDanmaku) return const SizedBox.shrink();

        return _buildCapsule(
          radius: isWide ? 22 : 18,
          child: SizedBox(
            height: isWide ? 42 : 34,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () {
                    controller.setDanmakuInputVisible(true);
                  },
                  child: Container(
                    width: isWide ? 92 : 76,
                    padding: EdgeInsets.symmetric(horizontal: isWide ? 14 : 12),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '发弹幕…',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: isWide ? 14 : 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (overlay.showDanmaku) ...[
                  Container(
                    width: 1,
                    height: 14,
                    color: Colors.white.withValues(alpha: 0.15),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.horizontal(
                      right: Radius.circular(isWide ? 22 : 18),
                    ),
                    onTap: () {
                      final mediaInfo = widget.controller.mediaInfo.value;
                      final epIndex = mediaInfo.episodeIndex >= 0
                          ? mediaInfo.episodeIndex + 1
                          : 1;
                      NavigationService.showDanmakuSettings(
                        context,
                        widget.controller.danmakuController,
                        defaultTitle: mediaInfo.title,
                        defaultEpisode: epIndex,
                      );
                    },

                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: isWide ? 12 : 10,
                      ),
                      child: Icon(
                        Icons.tune_rounded,
                        size: isWide ? 18 : 15,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// 构建底部视频增强按钮。
  Widget? _buildExtraBottomButtons(bool isWide) {
    final controller = widget.controller;
    if (!widget.full) return null;

    return ValueListenableBuilder<VideoEnhancementState>(
      valueListenable: controller.enhancement,
      builder: (context, enhancement, _) {
        final isActive = enhancement.enabled;
        final label = isActive ? enhancement.appliedPipeline.label : '增强';
        return GestureDetector(
          onTap: _toggleVideoEnhancement,
          onLongPress: () =>
              showVideoEnhancementModeDialog(context, widget.controller),
          child: _buildCapsule(
            radius: isWide ? 22 : 18,
            child: SizedBox(
              height: isWide ? 42 : 34,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: isWide ? 14 : 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: isWide ? 18 : 15,
                      color: isActive
                          ? Theme.of(context).colorScheme.primary
                          : Colors.white.withValues(alpha: 0.7),
                    ),
                    SizedBox(width: isWide ? 6 : 4),
                    Text(
                      label,
                      style: TextStyle(
                        color: isActive
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white.withValues(alpha: 0.7),
                        fontSize: isWide ? 14 : 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggleVideoEnhancement() async {
    try {
      final enabled = await widget.controller.toggleVideoEnhancement();
      showSnackBar(
        enabled
            ? '视频增强：${widget.controller.enhancement.value.appliedPipeline.label}'
            : '视频增强已关闭',
      );
    } catch (error) {
      showSnackBar('视频增强切换失败：$error');
    }
  }

  Widget _buildLockButton() {
    return ValueListenableBuilder<PlayerOverlayState>(
      valueListenable: widget.controller.overlay,
      builder: (context, overlay, _) {
        final showControls = overlay.controlsVisible;
        final isLocked = overlay.controlsLocked;

        return Visibility(
          visible: showControls,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionalTranslation(
              translation: const Offset(1, 0.0),
              child: SizedBox(
                width: 34,
                height: 34,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  onPressed: () =>
                      widget.controller.setControlsLocked(!isLocked),
                  icon: Icon(
                    isLocked ? Icons.lock : Icons.lock_open,
                    size: 24,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _navigateToSearch() {
    final title = widget.controller.mediaInfo.value.title;
    if (title.isEmpty) return;

    NavigationService.toSearch(context, keyword: title, initialSource: 2);
  }

  String _getCurrentTime() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }
}
