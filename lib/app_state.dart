import 'package:flutter/material.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:baka/instance.dart';
import 'package:baka/theme.dart';
import 'package:baka/core/content_filter.dart';

/// 应用级共享状态：主界面壳和主题。
class AppState extends GetxService with WidgetsBindingObserver {
  static const themeModeLabels = <String>['跟随系统', '浅色模式', '深色模式'];
  static const _themeModeKey = 'theme_mode';
  static const _dynamicColorKey = 'dynamic_color';
  static const _reduceVisualEffectsKey = 'reduce_visual_effects';

  final currentPageIndex = 0.obs;
  final isBottomNavVisible = true.obs;
  final isHideBottomNavOnScroll = true.obs;
  final sendCommentTrigger = 0.obs;

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
  String get themeModeLabel =>
      themeModeLabels[themeMode.clamp(0, themeModeLabels.length - 1)];

  ThemeMode get currentThemeMode {
    switch (_themeMode.value) {
      case 0:
        return ThemeMode.system;
      case 2:
        return ThemeMode.dark;
      default:
        return ThemeMode.light;
    }
  }

  @override
  void onInit() {
    super.onInit();
    contentFilter.load(Instances.sp);
    isHideBottomNavOnScroll.value =
        Instances.sp.getBool('hide_bottom_nav_on_scroll') ?? true;
    _themeMode.value = Instances.sp.getInt(_themeModeKey) ?? 1;
    _dynamicColor.value = Instances.sp.getBool(_dynamicColorKey) ?? false;
    _fontFamily.value = AppFonts.getSavedFont();
    _fontScale.value = AppFonts.getSavedFontScale();
    _fontWeightIndex.value = AppFonts.getSavedFontWeightIndex();
    _reduceVisualEffects.value =
        Instances.sp.getBool(_reduceVisualEffectsKey) ?? false;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangePlatformBrightness() {
    if (_themeMode.value == 0) {
      _themeMode.refresh();
    }
  }

  void changePage(int index) {
    currentPageIndex.value = index;
  }

  void updateScrollDirection(bool isScrollingDown) {
    if (Instances.isDesktopPlatform) return;
    isBottomNavVisible.value = isHideBottomNavOnScroll.value
        ? !isScrollingDown
        : true;
  }

  void toggleHideBottomNavOnScroll(bool value) {
    if (isHideBottomNavOnScroll.value == value) return;
    isHideBottomNavOnScroll.value = value;
    Instances.sp.setBool('hide_bottom_nav_on_scroll', value);
    if (!value) {
      isBottomNavVisible.value = true;
    }
  }

  void triggerSendComment() {
    sendCommentTrigger.value++;
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
    Instances.sp.setDouble(AppFonts.fontScaleKey, _fontScale.value);
  }

  void setFontWeightIndex(int index) {
    final next = index.clamp(0, AppFonts.availableWeights.length - 1);
    if (_fontWeightIndex.value == next) return;
    _fontWeightIndex.value = next;
    Instances.sp.setInt(AppFonts.fontWeightKey, _fontWeightIndex.value);
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
