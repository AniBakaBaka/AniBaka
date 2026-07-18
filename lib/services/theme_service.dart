import 'package:baka/instance.dart';
import 'package:baka/theme.dart';

class ThemeService {
  static const _themeModeKey = 'theme_mode';

  static int getThemeMode() => Instances.sp.getInt(_themeModeKey) ?? 1;

  static Future<void> setThemeMode(int mode) =>
      Instances.sp.setInt(_themeModeKey, mode);

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
