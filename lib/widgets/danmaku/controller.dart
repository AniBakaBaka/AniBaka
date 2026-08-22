import 'package:baka/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 弹幕控制器：持有整集弹幕数据与配置。
/// 时间轴以播放器媒体时间为准，由 [syncTime] 驱动，视图通过回调绑定。
class DanmakuController extends ChangeNotifier {
  DanmakuController();

  DanmakuListener? _listener;

  bool _running = true;
  double _playbackRate = 1.0;
  bool blockRepeat = false;
  bool blockColor = false;
  List<String> blockWords = [];
  List<DanmakuItem> _items = const [];
  DanmakuOption _option = DanmakuOption(
    fontSize: DanmakuOption.defaultFontSize,
  );

  double timeOffset = 0.0; // 弹幕时间偏移量（单位：秒，正值延后，负值提前）

  bool get running => _running;
  double get playbackRate => _playbackRate;
  DanmakuOption get option => _option;
  List<DanmakuItem> get items => _items;

  void setTimeOffset(double offsetInSeconds) {
    if (timeOffset == offsetInSeconds) return;
    timeOffset = offsetInSeconds;
    if (_lastPosition != null) {
      syncTime(_lastPosition!);
    }
  }

  Duration? _lastPosition;

  set playbackRate(double value) {
    final rate = value > 0 ? value : 1.0;
    if (_playbackRate == rate) return;
    _playbackRate = rate;
    _listener?.onDanmakuPlaybackRateChanged(rate);
  }

  /// 设置整集弹幕（须按 time 升序）
  void setItems(List<DanmakuItem> items) {
    _items = items;
    _listener?.onDanmakuItemsChanged();
    notifyListeners();
  }

  /// 同步播放进度，视图以此为时间锚点（seek 亦由此感知）
  void syncTime(Duration position) {
    _lastPosition = position;
    if (timeOffset == 0) {
      _listener?.onDanmakuTimeSync(position);
    } else {
      final offsetMs = (timeOffset * 1000).round();
      final adjustedMs = (position.inMilliseconds - offsetMs).clamp(
        0,
        86400000,
      );
      _listener?.onDanmakuTimeSync(Duration(milliseconds: adjustedMs));
    }
  }

  /// 立即注入弹幕（如用户发送）
  void addItem(DanmakuItem item) {
    if (!_running) return;
    _listener?.onDanmakuInject(item);
  }

  void pause() {
    if (!_running) return;
    _running = false;
    _listener?.onDanmakuPause();
  }

  void resume() {
    if (_running) return;
    _running = true;
    _listener?.onDanmakuResume();
  }

  /// 清空数据与屏幕（切集时调用）
  void reset() {
    _items = const [];
    _listener?.onDanmakuReset();
    notifyListeners();
  }

  void updateOption(DanmakuOption option) {
    final old = _option;
    _option = option;
    _listener?.onDanmakuOptionChanged(option, old);
  }

  /// 屏蔽词过滤，由视图在弹幕入场时调用
  bool isBlocked(String text) {
    for (final word in blockWords) {
      if (text.contains(word)) return true;
    }
    return false;
  }

  bool isColorBlocked(Color color) =>
      blockColor && color.toARGB32() != Colors.white.toARGB32();

  void attach(DanmakuListener listener) {
    _listener = listener;
  }

  void detach(DanmakuListener listener) {
    if (identical(_listener, listener)) _listener = null;
  }
}

abstract interface class DanmakuListener {
  void onDanmakuTimeSync(Duration position);
  void onDanmakuPlaybackRateChanged(double rate);
  void onDanmakuItemsChanged();
  void onDanmakuInject(DanmakuItem item);
  void onDanmakuOptionChanged(DanmakuOption next, DanmakuOption previous);
  void onDanmakuPause();
  void onDanmakuResume();
  void onDanmakuReset();
}

class DanmakuOption {
  final double fontSize;
  final String fontFamily;
  final double area;
  final double duration;
  final double opacity;
  final bool hideTop;
  final bool hideBottom;
  final bool hideScroll;
  final double strokeWidth;

  static double get defaultFontSize {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return 14.0;
      default:
        return 22.0;
    }
  }

  const DanmakuOption({
    this.fontSize = 14,
    this.fontFamily = AppFonts.defaultFont,
    this.area = 1.0,
    this.duration = 8,
    this.opacity = 1.0,
    this.hideBottom = false,
    this.hideScroll = false,
    this.hideTop = false,
    this.strokeWidth = 2.0,
  });

  DanmakuOption copyWith({
    double? fontSize,
    String? fontFamily,
    double? area,
    double? duration,
    double? opacity,
    bool? hideTop,
    bool? hideBottom,
    bool? hideScroll,
    double? strokeWidth,
  }) {
    return DanmakuOption(
      area: area ?? this.area,
      fontSize: fontSize ?? this.fontSize,
      fontFamily: fontFamily ?? this.fontFamily,
      duration: duration ?? this.duration,
      opacity: opacity ?? this.opacity,
      hideTop: hideTop ?? this.hideTop,
      hideBottom: hideBottom ?? this.hideBottom,
      hideScroll: hideScroll ?? this.hideScroll,
      strokeWidth: strokeWidth ?? this.strokeWidth,
    );
  }
}

class DanmakuItem {
  final String text;
  final Color color;
  final int type;
  final int time;

  const DanmakuItem(
    this.text, {
    this.color = Colors.white,
    this.type = 1,
    this.time = 0,
  });
}
