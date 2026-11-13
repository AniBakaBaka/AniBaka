import 'package:flutter/material.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:baka/instance.dart';
import 'package:baka/theme.dart';
import 'package:baka/core/content_filter.dart';

/// 应用级共享状态：主界面壳和主题。
class AppState extends GetxService with WidgetsBindingObserver {
  static const themeModeLabels = <String>['跟随系统', '浅色模式', '深色模式'];
  static const _themeModes = [
    ThemeMode.system,
    ThemeMode.light,
    ThemeMode.dark,
  ];
  static const _themeModeKey = 'theme_mode';
  static const _dynamicColorKey = 'dynamic_color';
  static const _reduceVisualEffectsKey = 'reduce_visual_effects';
  static const _hideBottomNavKey = 'hide_bottom_nav_on_scroll';

  final currentPageIndex = 0.obs;
  final isBottomNavVisible = true.obs;
  final isHideBottomNavOnScroll = true.obs;

  final _themeMode = 1.obs;
  final _dynamicColor = false.obs;
  final _fontFamily = ''.obs;
  final _fontScale = 1.0.obs;
  final _fontWeightIndex = 3.obs;
  final _reduceVisualEffects = false.obs;

  String get fontFamily => _fontFamily.value;
  double get fontScale => _fontScale.value;
  int get fontWeightIndex => _fontWeightIndex.value;
  FontWeight get fontWeight => AppFonts.availableWeights[fontWeightIndex];
  int get themeMode => _themeMode.value;
  bool get dynamicColor => _dynamicColor.value;
  bool get reduceVisualEffects => _reduceVisualEffects.value;
  String get themeModeLabel => themeModeLabels[themeMode];
  ThemeMode get currentThemeMode => _themeModes[themeMode];

  @override
  void onInit() {
    super.onInit();
    contentFilter.load();
    final sp = Instances.sp;
    isHideBottomNavOnScroll.value = sp.getBool(_hideBottomNavKey) ?? true;
    _themeMode.value = (sp.getInt(_themeModeKey) ?? 1).clamp(0, 2);
    _dynamicColor.value = sp.getBool(_dynamicColorKey) ?? false;
    _fontFamily.value = AppFonts.getSavedFont();
    _fontScale.value = AppFonts.getSavedFontScale();
    _fontWeightIndex.value = AppFonts.getSavedFontWeightIndex();
    _reduceVisualEffects.value = sp.getBool(_reduceVisualEffectsKey) ?? false;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangePlatformBrightness() {
    if (_themeMode.value == 0) _themeMode.refresh();
  }

  void changePage(int index) => currentPageIndex.value = index;

  /// Scrolling content hides the mobile navigation bar unless disabled.
  void showBottomNav(bool visible) {
    if (Instances.isDesktopPlatform) return;
    isBottomNavVisible.value = visible || !isHideBottomNavOnScroll.value;
  }

  void toggleHideBottomNavOnScroll(bool value) {
    if (isHideBottomNavOnScroll.value == value) return;
    isHideBottomNavOnScroll.value = value;
    Instances.sp.setBool(_hideBottomNavKey, value);
    if (!value) isBottomNavVisible.value = true;
  }

  void setThemeMode(int mode) {
    if (mode < 0 || mode > 2 || _themeMode.value == mode) return;
    _themeMode.value = mode;
    Instances.sp.setInt(_themeModeKey, mode);
  }

  void setDynamicColor(bool value) {
    if (_dynamicColor.value == value) return;
    _dynamicColor.value = value;
    Instances.sp.setBool(_dynamicColorKey, value);
  }

  void setFontFamily(String fontFamily) {
    fontFamily = AppFonts.normalizeFont(fontFamily);
    if (_fontFamily.value == fontFamily) return;
    _fontFamily.value = fontFamily;
    Instances.sp.setString(AppFonts.spKey, fontFamily);
  }

  void setFontScale(double scale) {
    final next = scale.clamp(0.8, 1.4);
    if (_fontScale.value == next) return;
    _fontScale.value = next;
    Instances.sp.setDouble(AppFonts.fontScaleKey, next);
  }

  void setFontWeightIndex(int index) {
    final next = index.clamp(0, AppFonts.availableWeights.length - 1);
    if (_fontWeightIndex.value == next) return;
    _fontWeightIndex.value = next;
    Instances.sp.setInt(AppFonts.fontWeightKey, next);
  }

  void setReduceVisualEffects(bool value) {
    if (_reduceVisualEffects.value == value) return;
    _reduceVisualEffects.value = value;
    Instances.sp.setBool(_reduceVisualEffectsKey, value);
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }
}
