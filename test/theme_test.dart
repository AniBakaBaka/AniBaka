import 'package:baka/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dynamic Material 3 color schemes are applied to both themes', () {
    final lightScheme = ColorScheme.fromSeed(
      seedColor: Colors.green,
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: Colors.orange,
      brightness: Brightness.dark,
    );

    final themes = AppTheme.resolve(
      fontFamily: AppFonts.systemFont,
      fontWeight: FontWeight.w400,
      lightColorScheme: lightScheme,
      darkColorScheme: darkScheme,
    );

    expect(themes.light.useMaterial3, isTrue);
    expect(themes.dark.useMaterial3, isTrue);
    expect(themes.light.colorScheme.primary, lightScheme.primary);
    expect(themes.dark.colorScheme.primary, darkScheme.primary);
    expect(themes.light.scaffoldBackgroundColor, lightScheme.surface);
    expect(themes.dark.scaffoldBackgroundColor, darkScheme.surface);
  });
}
