import 'package:baka/instance.dart';
import 'package:baka/theme.dart';

class ThemeService {
  static const _themeModeKey = 'theme_mode';
  static const _dynamicColorKey = 'dynamic_color';
  static const _reduceVisualEffectsKey = 'reduce_visual_effects';

  static int getThemeMode() => Instances.sp.getInt(_themeModeKey) ?? 1;

  static Future<void> setThemeMode(int mode) =>
      Instances.sp.setInt(_themeModeKey, mode);

  static bool getDynamicColor() =>
      Instances.sp.getBool(_dynamicColorKey) ?? false;

  static Future<void> setDynamicColor(bool value) =>
      Instances.sp.setBool(_dynamicColorKey, value);

  static bool getReduceVisualEffects() =>
      Instances.sp.getBool(_reduceVisualEffectsKey) ?? false;

  static Future<void> setReduceVisualEffects(bool value) =>
      Instances.sp.setBool(_reduceVisualEffectsKey, value);

  static String getFontFamily() => AppFonts.getSavedFont();

  static Future<void> setFontFamily(String fontFamily) =>
      Instances.sp.setString(AppFonts.spKey, fontFamily);

  static double getFontScale() => AppFonts.getSavedFontScale();

  static Future<void> setFontScale(double scale) =>
      Instances.sp.setDouble(AppFonts.fontScaleKey, scale);

  static int getFontWeightIndex() => AppFonts.getSavedFontWeightIndex();

  static Future<void> setFontWeightIndex(int index) =>
      Instances.sp.setInt(AppFonts.fontWeightKey, index);

  static const _sidebarCollapsedKey = 'sidebarCollapsed';

  static bool getSidebarCollapsed() =>
      Instances.sp.getBool(_sidebarCollapsedKey) ?? false;

  static Future<void> setSidebarCollapsed(bool value) =>
      Instances.sp.setBool(_sidebarCollapsedKey, value);
}
