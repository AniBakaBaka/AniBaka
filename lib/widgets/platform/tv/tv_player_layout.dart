import 'package:baka/utils/json_values.dart';
import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback/playback_content.dart';
import 'package:baka/instance.dart';
import 'package:baka/core/app_logger.dart';
import 'package:baka/widgets/baka_player/index.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/widgets/platform/tv/tv_episode_selector.dart';
import 'package:baka/widgets/platform/tv/tv_settings_panel.dart';
import 'package:baka/widgets/common/value_selector.dart';
import 'package:baka/widgets/player/skip_segment_track.dart';

enum _Panel { none, episodes, settings }

class TvPlayerLayout extends StatefulWidget {
  final PlaybackContent content;
  final bool inited;
  final PlaybackController controller;
  final DanmakuController danmakuController;
  final void Function(int) onEpisodeChanged;
  final void Function(int) onUrlChanged;
  final VoidCallback onWatchPartyPressed;
  final bool isSearching;
  final Widget? initialFailure;

  const TvPlayerLayout({
    required this.content,
    required this.inited,
    required this.controller,
    required this.danmakuController,
    required this.onEpisodeChanged,
    required this.onUrlChanged,
    required this.onWatchPartyPressed,
    this.isSearching = false,
    this.initialFailure,
    super.key,
  });

  @override
  State<TvPlayerLayout> createState() => _TvPlayerLayoutState();
}

class _TvPlayerLayoutState extends State<TvPlayerLayout> {
  bool _showOverlay = false;
  bool _editingSkip = false;
  _Panel _panel = _Panel.none;
  Timer? _overlayTimer;
  Timer? _clockTimer;
  final FocusNode _playerFocusNode = FocusNode();
  String? _lastDisplaySignature;
  late final ValueNotifier<String> _clock = ValueNotifier<String>(
    _fmtClock(DateTime.now()),
  );

  PlaybackController get ctr => widget.controller;

  @override
  void initState() {
    super.initState();
    ctr.skipSelection.addListener(_onSkipSelectionChanged);
    _log('TV player layout created');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playerFocusNode.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mediaQuery = MediaQuery.of(context);
    final signature =
        '${mediaQuery.size.width.toStringAsFixed(1)}x'
        '${mediaQuery.size.height.toStringAsFixed(1)}@'
        '${mediaQuery.devicePixelRatio.toStringAsFixed(2)} '
        'animationsDisabled=${mediaQuery.disableAnimations}';
    if (_lastDisplaySignature != signature) {
      _lastDisplaySignature = signature;
      _log('Flutter viewport changed: $signature');
    }
  }

  @override
  void dispose() {
    ctr.skipSelection.removeListener(_onSkipSelectionChanged);
    _log(
      'TV player layout disposed: overlay=$_showOverlay panel=${_panel.name}',
    );
    _overlayTimer?.cancel();
    _clockTimer?.cancel();
    _clock.dispose();
    _playerFocusNode.dispose();
    if (Instances.isTV) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    super.dispose();
  }

  void _showControls() {
    if (_editingSkip) return;
    if (!_showOverlay) {
      _log('Control overlay shown');
      setState(() => _showOverlay = true);
      _clock.value = _fmtClock(DateTime.now());
      _scheduleClockTick();
    }
    _resetOverlayTimer();
  }

  void _hideControls() {
    if (_editingSkip) return;
    if (!_showOverlay && _panel == _Panel.none) return;
    _log('Control overlay hidden: previousPanel=${_panel.name}');
    _overlayTimer?.cancel();
    _clockTimer?.cancel();
    setState(() {
      _showOverlay = false;
      _panel = _Panel.none;
    });
  }

  void _onSkipSelectionChanged() {
    final editing = ctr.skipSelection.value != null;
    if (editing == _editingSkip || !mounted) return;
    _overlayTimer?.cancel();
    _clockTimer?.cancel();
    setState(() {
      _editingSkip = editing;
      _showOverlay = false;
      _panel = _Panel.none;
    });
  }

  void _resetOverlayTimer() {
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _panel == _Panel.none) {
        _clockTimer?.cancel();
        setState(() => _showOverlay = false);
      }
    });
  }

  void _scheduleClockTick() {
    _clockTimer?.cancel();
    final now = DateTime.now();
    _clockTimer = Timer(
      Duration(
        seconds: 60 - now.second,
        milliseconds: -now.millisecond,
        microseconds: -now.microsecond,
      ),
      () {
        if (!mounted || !_showOverlay) return;
        _clock.value = _fmtClock(DateTime.now());
        _scheduleClockTick();
      },
    );
  }

  static String _fmtClock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _log(String message) {
    AppLogger.instance.info(message, tag: 'TvPlayer');
  }

  void _togglePlayPause() {
    ctr.togglePlayback();
    _showControls();
  }

  void _seek(Duration delta) {
    final target = ctr.timeline.value.position + delta;
    ctr.seek(
      delta.isNegative ? (target.isNegative ? Duration.zero : target) : target,
    );
    _showControls();
  }

  void _openPanel(_Panel p) {
    if (_panel == p) return;
    _log(
      'Panel opened: ${p.name}, playing=${ctr.core.value.playing}, '
      'buffering=${ctr.core.value.buffering}',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _showOverlay = true;
      _panel = p;
    });
    _overlayTimer?.cancel();
    _clock.value = _fmtClock(DateTime.now());
    _scheduleClockTick();
  }

  void _closePanel() {
    if (_panel == _Panel.none) return;
    _log('Panel closed: ${_panel.name}');
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _panel = _Panel.none);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playerFocusNode.requestFocus();
    });
    _resetOverlayTimer();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (_editingSkip) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (_panel != _Panel.none) {
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack) {
        _closePanel();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      if (_showOverlay) {
        _hideControls();
        return KeyEventResult.handled;
      }
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlayPause();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      _seek(-const Duration(seconds: 10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seek(const Duration(seconds: 10));
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      _showOverlay ? _openPanel(_Panel.episodes) : _showControls();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      _showOverlay ? _openPanel(_Panel.settings) : _showControls();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.contextMenu || key == LogicalKeyboardKey.f1) {
      _openPanel(_Panel.episodes);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.audioVolumeUp ||
        key == LogicalKeyboardKey.audioVolumeDown ||
        key == LogicalKeyboardKey.audioVolumeMute) {
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final canPop = !_editingSkip && !_showOverlay && _panel == _Panel.none;
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_editingSkip) {
          if (ctr.skipSelection.value?.saving != true) {
            ctr.cancelSkipSelection();
          }
          return;
        }
        if (_panel != _Panel.none) {
          _closePanel();
        } else if (_showOverlay) {
          _hideControls();
        }
      },
      child: Scaffold(
        backgroundColor: context.tvShadowColor(1.0),
        body: Focus(
          canRequestFocus: false,
          onKeyEvent: _handleKeyEvent,
          child: GestureDetector(
            onTap: () => _showOverlay ? _hideControls() : _showControls(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildPlayer(),
                if (_showOverlay)
                  RepaintBoundary(child: _buildControlOverlay()),
                RepaintBoundary(child: _buildPanel()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPanel() {
    final content = widget.content;
    final panel = _panel;
    final Widget child = switch (panel) {
      _Panel.settings => TvSettingsPanel(
        controller: ctr,
        danmakuController: widget.danmakuController,
        onClose: _closePanel,
      ),
      _Panel.episodes => TvEpisodeSelector(
        videoList: content.videoList,
        currentIndex: content.currPlayIndex,
        currUrl: content.currUrl,
        sourceNames: content.sourceNames,
        bgmId: content.bgmInfo.subjectId,
        tmdbId: toInt(content.data['tmdbId']),
        tvdbId: content.data['tvdbId']?.toString(),
        onEpisodeSelected: (index) {
          widget.onEpisodeChanged(index);
          _closePanel();
        },
        onUrlChanged: (index) {
          widget.onUrlChanged(index);
          _closePanel();
        },
        onClose: _closePanel,
      ),
      _Panel.none => const SizedBox.shrink(),
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (child, animation) {
        final childPanel = (child.key! as ValueKey<_Panel>).value;
        if (childPanel == _Panel.none) return child;
        return SlideTransition(
          position:
              Tween<Offset>(
                begin: Offset(childPanel == _Panel.settings ? -1 : 1, 0),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
          child: child,
        );
      },
      child: KeyedSubtree(key: ValueKey(panel), child: child),
    );
  }

  Widget _buildPlayer() {
    final content = widget.content;
    final nextIndex = content.currPlayIndex + 1;
    final hasNextEpisode = nextIndex < content.videoList.length;
    return ValueSelector<PlaybackCoreState, bool>(
      valueListenable: ctr.core,
      select: (core) => core.failed,
      builder: (context, failed) {
        if (failed) {
          return _buildErrorState();
        }
        if (!widget.inited) {
          return widget.initialFailure ?? _buildLoadingState();
        }
        return BakaPlayer(
          canSearchSource: true,
          danmakuEnabled: true,
          controller: ctr,
          full: true,
          focusNode: _playerFocusNode,
          showPrompts: _panel == _Panel.none,
          hasNextEpisode: hasNextEpisode,
          onNextEpisode: hasNextEpisode
              ? () => widget.onEpisodeChanged(nextIndex)
              : null,
        );
      },
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            color: context.tvTextSecondaryColor,
            size: 64,
          ),
          const SizedBox(height: 16),
          Text(
            '播放失败，请换源重试',
            style: TextStyle(color: context.tvTextSecondaryColor, fontSize: 20),
          ),
          const SizedBox(height: 24),
          TvFocusable(
            autofocus: true,
            onPressed: () => _openPanel(_Panel.episodes),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: context.tvHighlightColor(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '切换线路',
                style: TextStyle(color: context.tvTextColor, fontSize: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              color: context.tvTextColor,
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            widget.isSearching ? '正在自动匹配源中...' : '正在加载...',
            style: TextStyle(color: context.tvTextSecondaryColor, fontSize: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildControlOverlay() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            context.tvShadowColor(0.54),
            Colors.transparent,
            Colors.transparent,
            context.tvShadowColor(0.87),
          ],
          stops: const [0.0, 0.2, 0.7, 1.0],
        ),
      ),
      child: Column(
        children: [_buildTopInfo(), const Spacer(), _buildBottomControls()],
      ),
    );
  }

  Widget _buildTopInfo() {
    final content = widget.content;
    final epTitle = content.currentVideoItem?.title ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 32, 48, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  content.title,
                  style: TextStyle(
                    color: context.tvTextColor,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (epTitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      epTitle,
                      style: TextStyle(
                        color: context.tvHighlightColor(0.7),
                        fontSize: 16,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          TvFocusable(
            onPressed: widget.onWatchPartyPressed,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: context.tvHighlightColor(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.group_rounded,
                color: context.tvTextColor,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 20),
          ValueListenableBuilder<String>(
            valueListenable: _clock,
            builder: (_, v, _) => Text(
              v,
              style: TextStyle(
                color: context.tvTextColor,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 0, 48, 32),
      child: Column(
        children: [
          ValueListenableBuilder<PlaybackTimelineState>(
            valueListenable: ctr.timeline,
            builder: (context, timeline, _) {
              final pos = timeline.position;
              final dur = timeline.duration;
              final progress = dur.inMilliseconds > 0
                  ? pos.inMilliseconds / dur.inMilliseconds
                  : 0.0;
              return Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SkipSegmentTrack(
                      data: ctr.skipData,
                      duration: dur,
                      position: pos,
                      barHeight: 4,
                      child: LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        backgroundColor: context.tvTextHintColor,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Theme.of(context).colorScheme.primary,
                        ),
                        minHeight: 4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        _fmtDuration(pos),
                        style: TextStyle(
                          color: context.tvTextSecondaryColor,
                          fontSize: 14,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _fmtDuration(dur),
                        style: TextStyle(
                          color: context.tvTextSecondaryColor,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _hint(Icons.arrow_left, '快退10s'),
              const SizedBox(width: 32),
              _hint(Icons.pause_circle_outline, '播放/暂停'),
              const SizedBox(width: 32),
              _hint(Icons.arrow_right, '快进10s'),
              const SizedBox(width: 32),
              _hint(Icons.keyboard_arrow_up, '选集'),
              const SizedBox(width: 32),
              _hint(Icons.keyboard_arrow_down, '设置'),
              const SizedBox(width: 32),
              _hint(Icons.arrow_back, '返回'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _hint(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: context.tvTextSecondaryColor, size: 20),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(color: context.tvTextSecondaryColor, fontSize: 13),
        ),
      ],
    );
  }

  static String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '${h.toString().padLeft(2, '0')}:$mm:$ss' : '$mm:$ss';
  }
}
