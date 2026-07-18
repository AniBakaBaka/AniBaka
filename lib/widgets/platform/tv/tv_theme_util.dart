import 'package:flutter/material.dart';

extension TvThemeExtension on BuildContext {
  bool get isTvDark => Theme.of(this).brightness == Brightness.dark;

  Color get tvBgColor =>
      isTvDark ? const Color(0xFF0D0D0D) : const Color(0xFFF2F2F7);
  Color get tvPanelBgColor =>
      isTvDark ? const Color(0xF0111111) : const Color(0xF0E5E5EA);

  Color get tvTextColor => isTvDark ? Colors.white : Colors.black87;
  Color get tvTextSecondaryColor => isTvDark ? Colors.white70 : Colors.black54;
  Color get tvTextHintColor => isTvDark ? Colors.white38 : Colors.black38;

  Color tvHighlightColor(double opacity) => isTvDark
      ? Colors.white.withValues(alpha: opacity)
      : Colors.black.withValues(alpha: opacity);

  Color tvShadowColor(double opacity) => isTvDark
      ? Colors.black.withValues(alpha: opacity)
      : Colors.grey.withValues(alpha: opacity);
}
