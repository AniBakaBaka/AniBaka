import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:baka/instance.dart';
import 'package:baka/theme.dart';
import 'package:baka/utils/app_logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_fonts/google_fonts.dart';

import 'controller.dart';

const double _trackSpacing = 1.05;
const double _scrollGapPx = 12;
const double _topDurationMs = 6000;
const double _bottomDurationMs = 2500;
const double _repeatWindowMs = 10000;
const double _seekThresholdMs = 1200;

class DanmakuView extends StatefulWidget {
  const DanmakuView({required this.controller, super.key});

  final DanmakuController controller;

  @override
  State<DanmakuView> createState() => _DanmakuViewState();
}

class _DanmakuViewState extends State<DanmakuView>
    with SingleTickerProviderStateMixin
    implements DanmakuListener {
  late final Ticker _ticker;
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  final List<_Entry> _active = [];
  final DanmakuRepeatWindow _repeatWindow = DanmakuRepeatWindow();

  List<DanmakuScrollTrack> _scrollTracks = const [];
  List<double> _topBusyUntil = const [];
  List<double> _bottomBusyUntil = const [];

  Timer? _wakeTimer;
  int _cursor = 0;
  double _clockMs = 0;
  Duration _lastElapsed = Duration.zero;
  double _viewWidth = 0;
  double _viewHeight = 0;
  double _lineHeight = 0;
  double _nextExpiryMs = double.infinity;
  bool? _lastReportedRunning;
  DateTime? _lastDriftLogAt;
  String? _cachedFontFamily;
  TextStyle? _cachedFontStyle;

  DanmakuController get _controller => widget.controller;
  bool get _hasViewport => _viewWidth > 0 && _viewHeight > 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    widget.controller.attach(this);
    _log('Danmaku view created: items=${_controller.items.length}');
  }

  @override
  void didUpdateWidget(covariant DanmakuView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _log('Danmaku controller replaced');
      oldWidget.controller.detach(this);
      widget.controller.attach(this);
      onDanmakuReset();
    }
  }

  @override
  void dispose() {
    _log(
      'Danmaku view disposed: active=${_active.length} cursor=$_cursor '
      'clockMs=${_clockMs.round()}',
    );
    widget.controller.detach(this);
    _stopWork();
    _clearActive();
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final delta = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    if (delta <= Duration.zero) return;

    _clockMs += delta.inMicroseconds / 1000 * _controller.playbackRate;
    _emitDue();
    _expire();
    _repaint.value++;

    if (_active.isEmpty) _scheduleWork();
  }

  @override
  void onDanmakuTimeSync(Duration position) {
    final positionMs = position.inMilliseconds.toDouble();
    final drift = positionMs - _clockMs;
    if (drift.abs() > _seekThresholdMs) {
      final now = DateTime.now();
      if (_lastDriftLogAt == null ||
          now.difference(_lastDriftLogAt!) >= const Duration(seconds: 5)) {
        _lastDriftLogAt = now;
        _log(
          'Danmaku clock resync: driftMs=${drift.round()} '
          'active=${_active.length} cursor=$_cursor',
        );
      }
      _clockMs = positionMs;
      _clearActive();
      _resetTracks();
      _clearRecentTexts();
      _cursor = _lowerBound(_controller.items, positionMs);
      _repaint.value++;
      _emitDue();
      _scheduleWork(rescheduleWake: true);
      return;
    } else if (_ticker.isActive) {
      _clockMs += drift.clamp(-16.0, 16.0);
    } else {
      _clockMs = positionMs;
    }
    _emitDue();
    _scheduleWork();
  }

  @override
  void onDanmakuPlaybackRateChanged(double rate) =>
      _scheduleWork(rescheduleWake: true);

  @override
  void onDanmakuItemsChanged() {
    _clearActive();
    _resetTracks();
    _clearRecentTexts();
    _cursor = _lowerBound(_controller.items, _clockMs);
    _log(
      'Danmaku items changed: count=${_controller.items.length} '
      'cursor=$_cursor clockMs=${_clockMs.round()}',
    );
    _repaint.value++;
    _scheduleWork(rescheduleWake: true);
  }

  @override
  void onDanmakuInject(DanmakuItem item) {
    if (!_hasViewport) return;
    _tryEmit(item, checkBlock: false);
    _repaint.value++;
    _scheduleWork();
  }

  @override
  void onDanmakuOptionChanged(DanmakuOption next, DanmakuOption previous) {
    _log(
      'Danmaku option changed: fontSize=${next.fontSize} area=${next.area} '
      'fontFamily=${next.fontFamily} '
      'opacity=${next.opacity} hideScroll=${next.hideScroll} '
      'hideTop=${next.hideTop} hideBottom=${next.hideBottom}',
    );
    _active.removeWhere((entry) {
      final hidden = switch (entry.item.type) {
        1 => next.hideScroll,
        5 => next.hideTop,
        3 || 4 => next.hideBottom,
        _ => true,
      };
      if (hidden) entry.layout.dispose();
      return hidden;
    });
    _recalculateNextExpiry();

    final styleChanged =
        next.fontSize != previous.fontSize ||
        next.fontFamily != previous.fontFamily ||
        next.strokeWidth != previous.strokeWidth ||
        next.opacity != previous.opacity;
    if ((styleChanged || next.area != previous.area) && _hasViewport) {
      _rebuildTracks(next);
      _relayout(next, relayoutText: styleChanged);
    }
    _repaint.value++;
    _scheduleWork();
  }

  @override
  void onDanmakuPause() {
    if (_lastReportedRunning != false) {
      _lastReportedRunning = false;
      _log('Danmaku paused: active=${_active.length} cursor=$_cursor');
    }
    _stopWork();
  }

  @override
  void onDanmakuResume() {
    if (_lastReportedRunning != true) {
      _lastReportedRunning = true;
      _log('Danmaku resumed: active=${_active.length} cursor=$_cursor');
    }
    _scheduleWork();
  }

  @override
  void onDanmakuReset() {
    _stopWork();
    _clearActive();
    _resetTracks();
    _clearRecentTexts();
    _cursor = 0;
    _clockMs = 0;
    _repaint.value++;
  }

  void _scheduleWork({bool rescheduleWake = false}) {
    if (!_controller.running || !_hasViewport || !mounted) {
      _stopWork();
      return;
    }
    if (_active.isNotEmpty) {
      _wakeTimer?.cancel();
      _wakeTimer = null;
      _ensureTicker();
      return;
    }

    _stopTicker();
    final items = _controller.items;
    if (_cursor >= items.length) {
      _wakeTimer?.cancel();
      _wakeTimer = null;
      return;
    }
    if (!rescheduleWake && _wakeTimer?.isActive == true) return;
    _wakeTimer?.cancel();
    final rate = _controller.playbackRate;
    final delayMs = math.max(0.0, (items[_cursor].time - _clockMs) / rate);
    _wakeTimer = Timer(
      Duration(microseconds: math.max(1, (delayMs * 1000).round())),
      () {
        _wakeTimer = null;
        if (!_controller.running || !mounted) return;
        if (_cursor < _controller.items.length) {
          _clockMs = math.max(
            _clockMs,
            _controller.items[_cursor].time.toDouble(),
          );
        }
        _emitDue();
        _expire();
        _repaint.value++;
        _scheduleWork();
      },
    );
  }

  void _emitDue() {
    final items = _controller.items;
    while (_cursor < items.length && items[_cursor].time <= _clockMs) {
      _tryEmit(items[_cursor]);
      _cursor++;
    }
  }

  void _tryEmit(DanmakuItem item, {bool checkBlock = true}) {
    if (!_hasViewport) return;
    final option = _controller.option;
    if (checkBlock) {
      if (_controller.isBlocked(item.text)) return;
      if (_controller.isColorBlocked(item.color)) return;
      if (_controller.blockRepeat &&
          _repeatWindow.shouldBlock(item.text, _clockMs)) {
        return;
      }
    }

    switch (item.type) {
      case 1:
        if (!option.hideScroll) _emitScroll(item, option);
      case 5:
        if (!option.hideTop) _emitFixed(item, option, top: true);
      case 3:
      case 4:
        if (!option.hideBottom) _emitFixed(item, option, top: false);
    }
  }

  void _emitScroll(DanmakuItem item, DanmakuOption option) {
    if (_scrollTracks.isEmpty) return;
    final layout = _layoutDanmaku(item.text, item.color, option);
    if (layout == null) return;
    final durationMs = option.duration * 1000;
    final speed = (_viewWidth + layout.size.width) / durationMs;

    for (var index = 0; index < _scrollTracks.length; index++) {
      if (!_scrollTracks[index].canAccept(_clockMs, speed, _viewWidth)) {
        continue;
      }
      final entry = _Entry(
        item: item,
        track: index,
        startMs: _clockMs,
        durationMs: durationMs,
        speed: speed,
        x: 0,
        y: index * _lineHeight * _trackSpacing,
        layout: layout,
      );
      _active.add(entry);
      _nextExpiryMs = math.min(_nextExpiryMs, entry.endMs);
      _scrollTracks[index].register(
        startMs: entry.startMs,
        width: entry.layout.size.width,
        endMs: entry.endMs,
        speed: entry.speed,
      );
      return;
    }
    layout.dispose();
  }

  void _emitFixed(DanmakuItem item, DanmakuOption option, {required bool top}) {
    final busy = top ? _topBusyUntil : _bottomBusyUntil;
    var trackIndex = -1;
    for (var index = 0; index < busy.length; index++) {
      if (_clockMs >= busy[index]) {
        trackIndex = index;
        break;
      }
    }
    if (trackIndex < 0) return;

    final layout = _layoutDanmaku(item.text, item.color, option);
    if (layout == null) return;
    final durationMs = top ? _topDurationMs : _bottomDurationMs;
    busy[trackIndex] = _clockMs + durationMs;
    final entry = _Entry(
      item: item,
      track: trackIndex,
      startMs: _clockMs,
      durationMs: durationMs,
      speed: 0,
      x: (_viewWidth - layout.size.width) / 2,
      y: _fixedTrackY(trackIndex, top: top),
      layout: layout,
    );
    _active.add(entry);
    _nextExpiryMs = math.min(_nextExpiryMs, entry.endMs);
  }

  void _expire() {
    if (_clockMs < _nextExpiryMs) return;
    _nextExpiryMs = double.infinity;
    _active.removeWhere((entry) {
      if (_clockMs < entry.endMs) {
        _nextExpiryMs = math.min(_nextExpiryMs, entry.endMs);
        return false;
      }
      entry.layout.dispose();
      return true;
    });
  }

  void _updateViewport(BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    if (width == _viewWidth && height == _viewHeight) return;
    final previousWidth = _viewWidth;
    final previousHeight = _viewHeight;
    _viewWidth = width;
    _viewHeight = height;
    _log(
      'Danmaku viewport changed: '
      '${previousWidth.toStringAsFixed(1)}x${previousHeight.toStringAsFixed(1)} '
      '-> ${width.toStringAsFixed(1)}x${height.toStringAsFixed(1)}',
    );
    if (!_hasViewport) return;
    _rebuildTracks(_controller.option);
    _relayout(_controller.option, relayoutText: false);
    _scheduleWork();
  }

  void _rebuildTracks(DanmakuOption option) {
    _lineHeight = _measureLineHeight(option);
    final available = math.max(0.0, _viewHeight * option.area);
    final rows = _lineHeight > 0
        ? (available / (_lineHeight * _trackSpacing)).floor()
        : 0;
    _scrollTracks = List.generate(rows, (_) => DanmakuScrollTrack());
    _topBusyUntil = List.filled(
      rows ~/ 2,
      double.negativeInfinity,
      growable: false,
    );
    _bottomBusyUntil = List.filled(
      rows ~/ 2,
      double.negativeInfinity,
      growable: false,
    );
  }

  void _relayout(DanmakuOption option, {required bool relayoutText}) {
    _active.removeWhere((entry) {
      final scroll = entry.item.type == 1;
      final trackCount = scroll ? _scrollTracks.length : _topBusyUntil.length;
      if (entry.track >= trackCount) {
        entry.layout.dispose();
        return true;
      }
      if (relayoutText) {
        final layout = _layoutDanmaku(
          entry.item.text,
          entry.item.color,
          option,
        );
        if (layout == null) {
          entry.layout.dispose();
          return true;
        }
        entry.layout.dispose();
        entry.layout = layout;
      }
      if (scroll) {
        final progress = ((_clockMs - entry.startMs) / entry.durationMs).clamp(
          0.0,
          1.0,
        );
        entry.startMs = _clockMs - entry.durationMs * progress;
        entry.speed = (_viewWidth + entry.layout.size.width) / entry.durationMs;
        entry.y = entry.track * _lineHeight * _trackSpacing;
      } else {
        entry.x = (_viewWidth - entry.layout.size.width) / 2;
        entry.y = _fixedTrackY(entry.track, top: entry.item.type == 5);
      }
      return false;
    });

    _resetTracks();
    for (final entry in _active) {
      switch (entry.item.type) {
        case 1:
          _scrollTracks[entry.track].register(
            startMs: entry.startMs,
            width: entry.layout.size.width,
            endMs: entry.endMs,
            speed: entry.speed,
          );
        case 5:
          _topBusyUntil[entry.track] = math.max(
            _topBusyUntil[entry.track],
            entry.endMs,
          );
        case 3:
        case 4:
          _bottomBusyUntil[entry.track] = math.max(
            _bottomBusyUntil[entry.track],
            entry.endMs,
          );
      }
    }
    _recalculateNextExpiry();
  }

  double _fixedTrackY(int index, {required bool top}) => top
      ? index * _lineHeight * _trackSpacing
      : _viewHeight - (index + 1) * _lineHeight * _trackSpacing;

  void _resetTracks() {
    for (final track in _scrollTracks) {
      track.reset();
    }
    // A controller may replay its current position from attach() before this
    // view receives its first layout. The pre-layout track lists are const
    // empty lists, so even an empty fillRange is unsupported.
    if (_topBusyUntil.isNotEmpty) {
      _topBusyUntil.fillRange(0, _topBusyUntil.length, double.negativeInfinity);
    }
    if (_bottomBusyUntil.isNotEmpty) {
      _bottomBusyUntil.fillRange(
        0,
        _bottomBusyUntil.length,
        double.negativeInfinity,
      );
    }
  }

  void _clearActive() {
    for (final entry in _active) {
      entry.layout.dispose();
    }
    _active.clear();
    _nextExpiryMs = double.infinity;
  }

  void _recalculateNextExpiry() {
    var next = double.infinity;
    for (final entry in _active) {
      next = math.min(next, entry.endMs);
    }
    _nextExpiryMs = next;
  }

  void _clearRecentTexts() {
    _repeatWindow.clear();
  }

  void _ensureTicker() {
    _wakeTimer?.cancel();
    _wakeTimer = null;
    if (!_controller.running || _ticker.isActive || !mounted) return;
    _lastElapsed = Duration.zero;
    _ticker.start();
  }

  void _stopTicker() {
    if (_ticker.isActive) _ticker.stop();
  }

  void _stopWork() {
    _wakeTimer?.cancel();
    _wakeTimer = null;
    _stopTicker();
  }

  void _log(String message) {
    if (!Instances.isTV) return;
    AppLogger.instance.info(message, tag: 'TvDanmaku');
  }

  double _measureLineHeight(DanmakuOption option) {
    final painter = _textPainter('弹幕Ag', _fillStyle(Colors.white, option));
    final height = painter.size.height;
    painter.dispose();
    return height;
  }

  TextStyle _fontStyle(String fontFamily) {
    if (_cachedFontFamily != fontFamily) {
      _cachedFontFamily = fontFamily;
      _cachedFontStyle = AppFonts.isSystemFont(fontFamily)
          ? const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2)
          : GoogleFonts.getFont(
              fontFamily,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            );
      if (!AppFonts.isSystemFont(fontFamily)) {
        GoogleFonts.pendingFonts().then((_) {
          if (!mounted || _cachedFontFamily != fontFamily || !_hasViewport) {
            return;
          }
          final option = _controller.option;
          _rebuildTracks(option);
          _relayout(option, relayoutText: true);
          _repaint.value++;
        });
      }
    }
    return _cachedFontStyle!;
  }

  TextStyle _fillStyle(Color color, DanmakuOption option) =>
      _fontStyle(option.fontFamily).copyWith(
        color: color.withValues(alpha: option.opacity.clamp(0.0, 1.0)),
        fontSize: option.fontSize,
      );

  TextPainter _textPainter(String text, TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
    maxLines: 1,
  )..layout();

  _TextLayout? _layoutDanmaku(String text, Color color, DanmakuOption option) {
    final fill = _textPainter(text, _fillStyle(color, option));
    if (fill.size.isEmpty) {
      fill.dispose();
      return null;
    }
    final stroke = option.strokeWidth <= 0
        ? null
        : _textPainter(
            text,
            _fontStyle(option.fontFamily).copyWith(
              fontSize: option.fontSize,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = option.strokeWidth
                ..color = Colors.black.withValues(
                  alpha: option.opacity.clamp(0.0, 1.0),
                ),
            ),
          );
    return _TextLayout(fill: fill, stroke: stroke);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _updateViewport(constraints);
        return IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              isComplex: true,
              willChange: true,
              painter: _DanmakuPainter(repaint: _repaint, state: this),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }
}

@visibleForTesting
class DanmakuScrollTrack {
  double _lastStartMs = double.negativeInfinity;
  double _tailFreeMs = double.negativeInfinity;
  double _endMs = double.negativeInfinity;
  double _speed = double.infinity;

  void reset() {
    _lastStartMs = double.negativeInfinity;
    _tailFreeMs = double.negativeInfinity;
    _endMs = double.negativeInfinity;
    _speed = double.infinity;
  }

  bool canAccept(double nowMs, double speed, double viewWidth) {
    if (nowMs < _tailFreeMs) return false;
    if (speed <= _speed) return true;
    return nowMs >= _endMs - (viewWidth - _scrollGapPx) / speed;
  }

  void register({
    required double startMs,
    required double width,
    required double endMs,
    required double speed,
  }) {
    if (startMs < _lastStartMs) return;
    _lastStartMs = startMs;
    _tailFreeMs = startMs + (width + _scrollGapPx) / speed;
    _endMs = endMs;
    _speed = speed;
  }
}

class _Entry {
  _Entry({
    required this.item,
    required this.track,
    required this.startMs,
    required this.durationMs,
    required this.speed,
    required this.x,
    required this.y,
    required this.layout,
  });

  final DanmakuItem item;
  final int track;
  double startMs;
  double durationMs;
  double speed;
  double x;
  double y;
  _TextLayout layout;

  double get endMs => startMs + durationMs;
}

class _TextLayout {
  const _TextLayout({required this.fill, required this.stroke});

  final TextPainter fill;
  final TextPainter? stroke;
  Size get size => fill.size;

  void paint(Canvas canvas, Offset offset) {
    stroke?.paint(canvas, offset);
    fill.paint(canvas, offset);
  }

  void dispose() {
    stroke?.dispose();
    fill.dispose();
  }
}

@visibleForTesting
class DanmakuRepeatWindow {
  final LinkedHashMap<String, double> _latest = LinkedHashMap<String, double>();

  bool shouldBlock(String text, double nowMs) {
    final cutoff = nowMs - _repeatWindowMs;
    while (_latest.isNotEmpty && _latest.values.first <= cutoff) {
      _latest.remove(_latest.keys.first);
    }

    final previous = _latest.remove(text);
    final duplicate = previous != null && nowMs - previous < _repeatWindowMs;
    _latest[text] = nowMs;
    return duplicate;
  }

  void clear() => _latest.clear();

  @visibleForTesting
  int get retainedEventCount => _latest.length;
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({required Listenable repaint, required this.state})
    : super(repaint: repaint);

  final _DanmakuViewState state;

  @override
  void paint(Canvas canvas, Size size) {
    final now = state._clockMs;
    for (final entry in state._active) {
      final x = entry.item.type == 1
          ? size.width - (now - entry.startMs) * entry.speed
          : entry.x;
      final textSize = entry.layout.size;
      if (x >= size.width || x + textSize.width <= 0) continue;
      if (entry.y >= size.height || entry.y + textSize.height <= 0) continue;
      entry.layout.paint(canvas, Offset(x, entry.y));
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) => false;
}

int _lowerBound(List<DanmakuItem> items, double targetMs) {
  var left = 0;
  var right = items.length;
  while (left < right) {
    final middle = (left + right) >> 1;
    if (items[middle].time < targetMs) {
      left = middle + 1;
    } else {
      right = middle;
    }
  }
  return left;
}
