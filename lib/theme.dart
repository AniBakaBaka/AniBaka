import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'instance.dart';

// 主题颜色常量
class ThemeColors {
  static const primary = Color.fromRGBO(0, 119, 182, 1);
  static const contentLight = Color.fromARGB(255, 25, 25, 25);
  static const contentDark = Color(0xfff3f3f3);
  static const error = Color(0xFFF03738);
}

// 可用字体列表
class AppFonts {
  static const String systemFont = 'system';
  static const String defaultFont = 'ZCOOL QingKe HuangYou';
  static const String spKey = 'app_font_family';

  static const List<Map<String, String>> systemFonts = [
    {'name': 'system', 'label': '系统默认', 'preview': '跟随系统'},
  ];

  static const List<Map<String, String>> sansFonts = [
    {'name': 'Noto Sans SC', 'label': '思源黑体', 'preview': '清晰阅读'},
  ];

  static const List<Map<String, String>> serifFonts = [
    {'name': 'Noto Serif SC', 'label': '思源宋体', 'preview': '典雅风格'},
  ];

  static const List<Map<String, String>> handwritingFonts = [
    {'name': 'Ma Shan Zheng', 'label': '马善政楷书', 'preview': '书法韵味'},
    {'name': 'Long Cang', 'label': '龙藏体', 'preview': '洒脱自然'},
    {'name': 'Liu Jian Mao Cao', 'label': '刘建毛草', 'preview': '草书飘逸'},
    {'name': 'Zhi Mang Xing', 'label': '志莽行书', 'preview': '行云流水'},
  ];

  static const List<Map<String, String>> displayFonts = [
    {'name': 'ZCOOL KuaiLe', 'label': '站酷快乐体', 'preview': '快乐追番'},
    {'name': 'ZCOOL XiaoWei', 'label': '站酷小薇体', 'preview': '文艺清新'},
    {
      'name': 'ZCOOL QingKe HuangYou',
      'label': '站酷庆科黄油体',
      'preview': '圆润可爱',
    },
  ];

  static const List<Map<String, String>> _allFonts = [
    ...systemFonts,
    ...sansFonts,
    ...serifFonts,
    ...handwritingFonts,
    ...displayFonts,
  ];

  static final Map<String, String> _fontLabelMap = {
    for (final font in _allFonts) font['name']!: font['label']!,
  };

  static const Map<String, String> categoryLabels = {
    'system': '系统',
    'sans': '黑体',
    'serif': '宋体',
    'handwriting': '手写 / 书法',
    'display': '艺术 / 创意',
  };

  static const String fontScaleKey = 'app_font_scale';
  static const String fontWeightKey = 'app_font_weight';
  static const double defaultFontScale = 1.0;
  static const int defaultFontWeightIndex = 3; // w400

  static const List<FontWeight> availableWeights = [
    FontWeight.w100,
    FontWeight.w200,
    FontWeight.w300,
    FontWeight.w400,
    FontWeight.w500,
    FontWeight.w600,
    FontWeight.w700,
    FontWeight.w800,
    FontWeight.w900,
  ];

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

  static String getSavedFont() =>
      Instances.sp.getString(spKey) ?? defaultFont;

  static double getSavedFontScale() =>
      Instances.sp.getDouble(fontScaleKey) ?? defaultFontScale;

  static int getSavedFontWeightIndex() =>
      Instances.sp.getInt(fontWeightKey) ?? defaultFontWeightIndex;

  static String getLabelForFont(String fontName) =>
      _fontLabelMap[fontName] ?? fontName;
}

const _pageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: ZoomPageTransitionsBuilder(),
  },
);

class AppTheme {
  static final ThemeData _lightBase = _baseTheme(Brightness.light);
  static final ThemeData _darkBase = _baseTheme(Brightness.dark);

  static String? _cachedFontFamily;
  static FontWeight? _cachedFontWeight;
  static ({ThemeData light, ThemeData dark})? _cachedThemes;

  static ({ThemeData light, ThemeData dark}) resolve({
    required String fontFamily,
    required FontWeight fontWeight,
  }) {
    final cached = _cachedThemes;
    if (cached != null &&
        _cachedFontFamily == fontFamily &&
        _cachedFontWeight == fontWeight) {
      return cached;
    }

    final themes = (
      light: _withFont(_lightBase, fontFamily, fontWeight),
      dark: _withFont(_darkBase, fontFamily, fontWeight),
    );
    _cachedFontFamily = fontFamily;
    _cachedFontWeight = fontWeight;
    return _cachedThemes = themes;
  }

  static ThemeData _withFont(
    ThemeData base,
    String fontFamily,
    FontWeight fontWeight,
  ) {
    final textTheme = AppFonts.isSystemFont(fontFamily)
        ? base.textTheme
        : GoogleFonts.getTextTheme(fontFamily, base.textTheme);
    return base.copyWith(
      textTheme: fontWeight == FontWeight.w400
          ? textTheme
          : _withWeight(textTheme, fontWeight),
    );
  }

  static TextTheme _withWeight(TextTheme theme, FontWeight weight) {
    TextStyle? apply(TextStyle? style) => style?.copyWith(fontWeight: weight);
    return theme.copyWith(
      displayLarge: apply(theme.displayLarge),
      displayMedium: apply(theme.displayMedium),
      displaySmall: apply(theme.displaySmall),
      headlineLarge: apply(theme.headlineLarge),
      headlineMedium: apply(theme.headlineMedium),
      headlineSmall: apply(theme.headlineSmall),
      titleLarge: apply(theme.titleLarge),
      titleMedium: apply(theme.titleMedium),
      titleSmall: apply(theme.titleSmall),
      bodyLarge: apply(theme.bodyLarge),
      bodyMedium: apply(theme.bodyMedium),
      bodySmall: apply(theme.bodySmall),
      labelLarge: apply(theme.labelLarge),
      labelMedium: apply(theme.labelMedium),
      labelSmall: apply(theme.labelSmall),
    );
  }

  static ThemeData _baseTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colorScheme =
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

    return ThemeData(useMaterial3: true, colorScheme: colorScheme).copyWith(
      scaffoldBackgroundColor: isDark
          ? Colors.black
          : const Color(0xFFF2F2F7),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark
              ? Brightness.light
              : Brightness.dark,
          statusBarBrightness: brightness,
        ),
      ),
      iconTheme: IconThemeData(
        color: isDark ? ThemeColors.contentDark : ThemeColors.contentLight,
      ),
      inputDecorationTheme: InputDecorationTheme(
        fillColor: isDark ? const Color(0x1AFFFFFF) : const Color(0x0D000000),
        hintStyle: TextStyle(
          color: isDark ? const Color(0x61FFFFFF) : const Color(0x61000000),
        ),
      ),
      shadowColor: isDark
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
}
