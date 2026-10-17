import 'package:flutter/material.dart';

abstract final class ExpressiveSliderTheme {
  static const trackHeight = 16.0;
  static const trackGap = 6.0;
  static const horizontalInset = 4.0;

  static SliderThemeData from(ColorScheme colors) => SliderThemeData(
    // Flutter 3.44 still defaults to the old appearance without this opt-in.
    // ignore: deprecated_member_use
    year2023: false,
    trackHeight: trackHeight,
    trackGap: trackGap,
    trackShape: const GappedSliderTrackShape(),
    thumbShape: const HandleThumbShape(),
    activeTrackColor: colors.primary,
    inactiveTrackColor: colors.surfaceContainerHighest,
    thumbColor: colors.primary,
    activeTickMarkColor: colors.onPrimary,
    inactiveTickMarkColor: colors.onSurfaceVariant,
    showValueIndicator: ShowValueIndicator.onDrag,
    padding: const EdgeInsets.symmetric(horizontal: horizontalInset),
  );
}
