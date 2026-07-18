import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _subtitleSettingsKey = 'subtitle_settings';

/// 字幕设置数据模型
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
  static const List<Map<String, String>> availableFonts = [
    {'name': '系统默认', 'value': ''},
    {'name': 'Microsoft YaHei', 'value': 'Microsoft YaHei'},
    {'name': 'SimHei (黑体)', 'value': 'SimHei'},
    {'name': 'SimSun (宋体)', 'value': 'SimSun'},
    {'name': 'KaiTi (楷体)', 'value': 'KaiTi'},
    {'name': 'FangSong (仿宋)', 'value': 'FangSong'},
    {'name': 'Noto Sans SC', 'value': 'Noto Sans SC'},
    {'name': 'Source Han Sans', 'value': 'Source Han Sans'},
    {'name': 'Arial', 'value': 'Arial'},
    {'name': 'Segoe UI', 'value': 'Segoe UI'},
  ];

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
  }) {
    return SubtitleConfig(
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
  }

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

  factory SubtitleConfig.fromJson(Map<String, dynamic> json) {
    return SubtitleConfig(
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
      fontFamily: json['fontFamily'] as String? ?? defaultFontFamily,
    );
  }

  static Color _parseColor(dynamic value, Color fallback) {
    if (value is String && value.isNotEmpty) {
      final parsed = int.tryParse(value, radix: 16);
      if (parsed != null) return Color(parsed);
    }
    return fallback;
  }

  /// 从持久化加载
  static Future<SubtitleConfig> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_subtitleSettingsKey);
      if (raw != null) {
        return SubtitleConfig.fromJson(jsonDecode(raw));
      }
    } catch (_) {}
    return const SubtitleConfig();
  }

  /// 持久化保存
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subtitleSettingsKey, jsonEncode(toJson()));
  }
}

extension SubtitleColorHex on Color {
  String toSubtitleHex() {
    final a = (this.a * 255.0)
        .round()
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0');
    final r = (this.r * 255.0)
        .round()
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0');
    final g = (this.g * 255.0)
        .round()
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0');
    final b = (this.b * 255.0)
        .round()
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0');
    return '$a$r$g$b';
  }
}
