import 'package:flutter/material.dart';

/// 字幕设置数据模型
@immutable
class SubtitleConfig {
  final double fontSize;
  final double position; // 0.0 (顶部) ~ 100.0 (底部)
  final Color fontColor;
  final Color backgroundColor;
  final double borderWidth;
  final Color borderColor;
  final bool bold;
  final double opacity;
  final String fontFamily;

  static const double defaultFontSize = 24.0;
  static const double defaultPosition = 95.0;
  static const Color defaultFontColor = Colors.white;
  static const Color defaultBackgroundColor = Color(0x00000000);
  static const double defaultBorderWidth = 2.0;
  static const Color defaultBorderColor = Colors.black;
  static const bool defaultBold = false;
  static const double defaultOpacity = 1.0;
  static const String defaultFontFamily = '';

  /// 可选字体列表
  static const fonts = {
    '': '系统默认',
    'Microsoft YaHei': 'Microsoft YaHei',
    'SimHei': 'SimHei (黑体)',
    'SimSun': 'SimSun (宋体)',
    'KaiTi': 'KaiTi (楷体)',
    'FangSong': 'FangSong (仿宋)',
    'Noto Sans SC': 'Noto Sans SC',
    'Source Han Sans': 'Source Han Sans',
    'Arial': 'Arial',
    'Segoe UI': 'Segoe UI',
  };

  const SubtitleConfig({
    this.fontSize = defaultFontSize,
    this.position = defaultPosition,
    this.fontColor = defaultFontColor,
    this.backgroundColor = defaultBackgroundColor,
    this.borderWidth = defaultBorderWidth,
    this.borderColor = defaultBorderColor,
    this.bold = defaultBold,
    this.opacity = defaultOpacity,
    this.fontFamily = defaultFontFamily,
  });

  SubtitleConfig copyWith({
    double? fontSize,
    double? position,
    Color? fontColor,
    Color? backgroundColor,
    double? borderWidth,
    Color? borderColor,
    bool? bold,
    double? opacity,
    String? fontFamily,
  }) => SubtitleConfig(
    fontSize: fontSize ?? this.fontSize,
    position: position ?? this.position,
    fontColor: fontColor ?? this.fontColor,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    borderWidth: borderWidth ?? this.borderWidth,
    borderColor: borderColor ?? this.borderColor,
    bold: bold ?? this.bold,
    opacity: opacity ?? this.opacity,
    fontFamily: fontFamily ?? this.fontFamily,
  );

  Map<String, dynamic> toJson() => {
    'fontSize': fontSize,
    'position': position,
    'fontColor': fontColor.toSubtitleHex(),
    'backgroundColor': backgroundColor.toSubtitleHex(),
    'borderWidth': borderWidth,
    'borderColor': borderColor.toSubtitleHex(),
    'bold': bold,
    'opacity': opacity,
    'fontFamily': fontFamily,
  };

  factory SubtitleConfig.fromJson(Map<String, dynamic> json) => SubtitleConfig(
    fontSize: (json['fontSize'] as num?)?.toDouble() ?? defaultFontSize,
    position: (json['position'] as num?)?.toDouble() ?? defaultPosition,
    fontColor: _parseColor(json['fontColor'], defaultFontColor),
    backgroundColor: _parseColor(
      json['backgroundColor'],
      defaultBackgroundColor,
    ),
    borderWidth:
        (json['borderWidth'] as num?)?.toDouble() ?? defaultBorderWidth,
    borderColor: _parseColor(json['borderColor'], defaultBorderColor),
    bold: json['bold'] as bool? ?? defaultBold,
    opacity: (json['opacity'] as num?)?.toDouble() ?? defaultOpacity,
    fontFamily: fonts.containsKey(json['fontFamily'])
        ? json['fontFamily'] as String
        : defaultFontFamily,
  );

  static Color _parseColor(dynamic value, Color fallback) {
    if (value is String && value.isNotEmpty) {
      final parsed = int.tryParse(value, radix: 16);
      if (parsed != null) return Color(parsed);
    }
    return fallback;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubtitleConfig &&
          fontSize == other.fontSize &&
          position == other.position &&
          fontColor == other.fontColor &&
          backgroundColor == other.backgroundColor &&
          borderWidth == other.borderWidth &&
          borderColor == other.borderColor &&
          bold == other.bold &&
          opacity == other.opacity &&
          fontFamily == other.fontFamily;

  @override
  int get hashCode => Object.hash(
    fontSize,
    position,
    fontColor,
    backgroundColor,
    borderWidth,
    borderColor,
    bold,
    opacity,
    fontFamily,
  );
}

extension SubtitleColorHex on Color {
  String toSubtitleHex() {
    var packed = 0;
    for (final channel in [a, r, g, b]) {
      packed = (packed << 8) | (channel * 255.0).round().clamp(0, 255);
    }
    return packed.toRadixString(16).padLeft(8, '0');
  }
}
