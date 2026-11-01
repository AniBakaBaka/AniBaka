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
    this.fontSize = 24.0,
    this.position = 95.0,
    this.fontColor = Colors.white,
    this.backgroundColor = const Color(0x00000000),
    this.borderWidth = 2.0,
    this.borderColor = Colors.black,
    this.bold = false,
    this.opacity = 1.0,
    this.fontFamily = '',
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

  static String _hex(Color color) =>
      color.toARGB32().toRadixString(16).padLeft(8, '0');

  Map<String, dynamic> toJson() => {
    'fontSize': fontSize,
    'position': position,
    'fontColor': _hex(fontColor),
    'backgroundColor': _hex(backgroundColor),
    'borderWidth': borderWidth,
    'borderColor': _hex(borderColor),
    'bold': bold,
    'opacity': opacity,
    'fontFamily': fontFamily,
  };

  factory SubtitleConfig.fromJson(Map<String, dynamic> json) {
    const defaults = SubtitleConfig();
    Color color(String key, Color fallback) => switch (json[key]) {
      final String hex => Color(int.parse(hex, radix: 16)),
      _ => fallback,
    };
    final font = json['fontFamily'];
    return SubtitleConfig(
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? defaults.fontSize,
      position: (json['position'] as num?)?.toDouble() ?? defaults.position,
      fontColor: color('fontColor', defaults.fontColor),
      backgroundColor: color('backgroundColor', defaults.backgroundColor),
      borderWidth:
          (json['borderWidth'] as num?)?.toDouble() ?? defaults.borderWidth,
      borderColor: color('borderColor', defaults.borderColor),
      bold: json['bold'] as bool? ?? defaults.bold,
      opacity: (json['opacity'] as num?)?.toDouble() ?? defaults.opacity,
      fontFamily: fonts.containsKey(font)
          ? font as String
          : defaults.fontFamily,
    );
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
