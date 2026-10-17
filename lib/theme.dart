import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'instance.dart';

class ThemeColors {
  static const primary = Color.fromRGBO(0, 119, 182, 1);
  static const contentLight = Color.fromARGB(255, 25, 25, 25);
  static const contentDark = Color(0xfff3f3f3);
  static const error = Color(0xFFF03738);
}

class AppFonts {
  static const String systemFont = 'system';
  static const String defaultFont = 'Noto Serif SC';
  static const String spKey = 'app_font_family';

  static const fontOptions = {
    systemFont: '系统默认',
    'Noto Sans SC': '思源黑体',
    'M PLUS Rounded 1c': 'M PLUS 圆体',
    'Zen Maru Gothic': '禅丸圆体',
    'Sawarabi Gothic': '早蕨黑体',
    'Noto Serif SC': '思源宋体',
    'Sawarabi Mincho': '早蕨明朝体',
    'ZCOOL KuaiLe': '站酷快乐体',
    'ZCOOL XiaoWei': '站酷小薇体',
    'ZCOOL QingKe HuangYou': '站酷庆科黄油体',
  };

  static const String fontScaleKey = 'app_font_scale';
  static const String fontWeightKey = 'app_font_weight';
  static const double defaultFontScale = 1.0;
  static const int defaultFontWeightIndex = 3;

  static const List<FontWeight> availableWeights = FontWeight.values;

  static const List<String> weightLabels = [
    '极细 W100',
    '特细 W200',
    '细体 W300',
    '常规 W400',
    '中等 W500',
    '半粗 W600',
    '粗体 W700',
    '特粗 W800',
    '极粗 W900',
  ];

  static bool isSystemFont(String fontName) => fontName == systemFont;

  static String normalizeFont(String? fontName) =>
      fontName != null && fontOptions.containsKey(fontName)
      ? fontName
      : defaultFont;

  static String getSavedFont() => normalizeFont(Instances.sp.getString(spKey));

  static double getSavedFontScale() =>
      Instances.sp.getDouble(fontScaleKey) ?? defaultFontScale;

  static int getSavedFontWeightIndex() =>
      Instances.sp.getInt(fontWeightKey) ?? defaultFontWeightIndex;
}

// Keep Flutter's gesture tracking/cancellation, but finish ordinary back
// navigation promptly. The SDK default inherits the 450 ms forward duration.
class _AppPredictiveBackPageTransitionsBuilder
    extends PredictiveBackPageTransitionsBuilder {
  const _AppPredictiveBackPageTransitionsBuilder();

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 220);
}

const _pageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: _AppPredictiveBackPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: ZoomPageTransitionsBuilder(),
  },
);

class AppTheme {
  // Keep only the current color bases; font changes reuse their typography.
  static ThemeData _lightBase = _baseTheme(Brightness.light);
  static ThemeData _darkBase = _baseTheme(Brightness.dark);

  static String? _cachedFontFamily;
  static FontWeight? _cachedFontWeight;
  static ColorScheme? _cachedLightColorScheme;
  static ColorScheme? _cachedDarkColorScheme;
  static ({ThemeData light, ThemeData dark})? _cachedThemes;

  static ({ThemeData light, ThemeData dark}) resolve({
    required String fontFamily,
    required FontWeight fontWeight,
    ColorScheme? lightColorScheme,
    ColorScheme? darkColorScheme,
  }) {
    final cached = _cachedThemes;
    if (cached != null &&
        _cachedFontFamily == fontFamily &&
        _cachedFontWeight == fontWeight &&
        _cachedLightColorScheme == lightColorScheme &&
        _cachedDarkColorScheme == darkColorScheme) {
      return cached;
    }

    final lightBase = _cachedLightColorScheme == lightColorScheme
        ? _lightBase
        : _baseTheme(Brightness.light, dynamicColorScheme: lightColorScheme);
    final darkBase = _cachedDarkColorScheme == darkColorScheme
        ? _darkBase
        : _baseTheme(Brightness.dark, dynamicColorScheme: darkColorScheme);
    final themes = (
      light: _withFont(lightBase, fontFamily, fontWeight),
      dark: _withFont(darkBase, fontFamily, fontWeight),
    );
    _lightBase = lightBase;
    _darkBase = darkBase;
    _cachedFontFamily = fontFamily;
    _cachedFontWeight = fontWeight;
    _cachedLightColorScheme = lightColorScheme;
    _cachedDarkColorScheme = darkColorScheme;
    return _cachedThemes = themes;
  }

  static ThemeData _withFont(
    ThemeData base,
    String fontFamily,
    FontWeight fontWeight,
  ) {
    var textTheme = AppFonts.isSystemFont(fontFamily)
        ? base.textTheme
        : GoogleFonts.getTextTheme(fontFamily, base.textTheme);
    if (fontWeight != FontWeight.w400) {
      TextStyle? apply(TextStyle? style) =>
          style?.copyWith(fontWeight: fontWeight);
      textTheme = TextTheme(
        displayLarge: apply(textTheme.displayLarge),
        displayMedium: apply(textTheme.displayMedium),
        displaySmall: apply(textTheme.displaySmall),
        headlineLarge: apply(textTheme.headlineLarge),
        headlineMedium: apply(textTheme.headlineMedium),
        headlineSmall: apply(textTheme.headlineSmall),
        titleLarge: apply(textTheme.titleLarge),
        titleMedium: apply(textTheme.titleMedium),
        titleSmall: apply(textTheme.titleSmall),
        bodyLarge: apply(textTheme.bodyLarge),
        bodyMedium: apply(textTheme.bodyMedium),
        bodySmall: apply(textTheme.bodySmall),
        labelLarge: apply(textTheme.labelLarge),
        labelMedium: apply(textTheme.labelMedium),
        labelSmall: apply(textTheme.labelSmall),
      );
    }
    return identical(textTheme, base.textTheme)
        ? base
        : base.copyWith(textTheme: textTheme);
  }

  static ThemeData _baseTheme(
    Brightness brightness, {
    ColorScheme? dynamicColorScheme,
  }) {
    final isDark = brightness == Brightness.dark;
    final colorScheme =
        dynamicColorScheme?.copyWith(brightness: brightness) ??
        ColorScheme.fromSeed(
          seedColor: ThemeColors.primary,
          brightness: brightness,
        ).copyWith(
          error: ThemeColors.error,
          surface: isDark ? const Color(0xFF1C1C1E) : Colors.white,
          surfaceContainerHighest: isDark
              ? const Color(0x1AFFFFFF)
              : const Color(0x0D000000),
          onSurface: isDark ? Colors.white : const Color(0xFF191919),
          onSurfaceVariant: isDark
              ? const Color(0xB3FFFFFF)
              : const Color(0x8A000000),
        );
    final usesDynamicColor = dynamicColorScheme != null;

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: usesDynamicColor
          ? colorScheme.surface
          : isDark
          ? Colors.black
          : const Color(0xFFF2F2F7),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          statusBarBrightness: brightness,
        ),
      ),
      iconTheme: IconThemeData(color: colorScheme.onSurface),
      inputDecorationTheme: InputDecorationTheme(
        fillColor: colorScheme.surfaceContainerHighest,
        hintStyle: TextStyle(
          color: usesDynamicColor
              ? colorScheme.onSurfaceVariant.withValues(alpha: 0.6)
              : isDark
              ? const Color(0x61FFFFFF)
              : const Color(0x61000000),
        ),
      ),
      shadowColor: usesDynamicColor
          ? colorScheme.shadow
          : isDark
          ? const Color.fromRGBO(0, 0, 0, 0.6)
          : const Color.fromRGBO(0, 0, 0, 0.3),
      pageTransitionsTheme: _pageTransitionsTheme,
    );
  }
}

extension ThemeX on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colorScheme => theme.colorScheme;
  Color get primaryColor => colorScheme.primary;
  Color get cardColor => theme.cardColor;

  TextStyle withAppFont(TextStyle style) {
    final ambient = DefaultTextStyle.of(this).style;
    return style.copyWith(
      fontFamily: ambient.fontFamily,
      fontFamilyFallback: ambient.fontFamilyFallback,
    );
  }
}
