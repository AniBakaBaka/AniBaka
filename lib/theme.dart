import 'dart:io';
import 'dart:ui' show loadFontFromList;

import 'package:baka/app/page_routes.dart';
import 'package:baka/instance.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';

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

  static const _builtInFonts = {
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

  static String? _importedFont;

  static Map<String, String> get fontOptions => {
    ..._builtInFonts,
    ?_importedFont: '自定义字体',
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
  static bool isImportedFont(String fontName) => fontName == _importedFont;

  static String normalizeFont(String? fontName) =>
      fontName != null &&
          (_builtInFonts.containsKey(fontName) || isImportedFont(fontName))
      ? fontName
      : defaultFont;

  static Future<File> _importedFontFile() async {
    final directory = await getApplicationSupportDirectory();
    return File.fromUri(directory.uri.resolve('app-font'));
  }

  static Future<void> restoreImportedFont() async {
    final file = await _importedFontFile();
    if (await file.exists()) await _loadFont(file);
  }

  static Future<String> importFont(File source) async =>
      _loadFont(source, destination: await _importedFontFile());

  static Future<String> _loadFont(File source, {File? destination}) async {
    if (await source.length() > 64 * 1024 * 1024) {
      throw const FormatException('字体文件不能超过 64 MB');
    }
    final bytes = await source.readAsBytes();
    final data = ByteData.sublistView(bytes);
    const signatures = {0x00010000, 0x4f54544f, 0x74727565};
    if (bytes.length < 12 ||
        !signatures.contains(data.getUint32(0)) ||
        data.getUint16(4) == 0 ||
        12 + 16 * data.getUint16(4) > bytes.length) {
      throw const FormatException('字体文件无效或已损坏');
    }
    final family = 'baka-custom-${sha256.convert(bytes)}';
    if (!isImportedFont(family)) {
      await loadFontFromList(bytes, fontFamily: family);
    }
    if (destination != null) {
      final staged = File('${destination.path}.tmp');
      await staged.writeAsBytes(bytes, flush: true);
      await staged.rename(destination.path);
    }
    return _importedFont = family;
  }

  static String getSavedFont() => normalizeFont(Instances.sp.getString(spKey));

  static double getSavedFontScale() =>
      Instances.sp.getDouble(fontScaleKey) ?? defaultFontScale;

  static int getSavedFontWeightIndex() =>
      Instances.sp.getInt(fontWeightKey) ?? defaultFontWeightIndex;
}

const _pageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: ContainerPageTransitionsBuilder(),
    TargetPlatform.iOS: ContainerPageTransitionsBuilder(),
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
    var textTheme = base.textTheme;
    if (AppFonts.isImportedFont(fontFamily)) {
      textTheme = textTheme.apply(fontFamily: fontFamily);
    } else if (!AppFonts.isSystemFont(fontFamily)) {
      textTheme = GoogleFonts.getTextTheme(fontFamily, textTheme);
    }
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
