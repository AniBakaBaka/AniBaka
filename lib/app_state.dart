import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/theme_service.dart';
import 'package:baka/theme.dart';

/// 应用级共享状态：会话、主界面壳和主题。
class AppState extends GetxService {
  // 会话
  final userInfo = Rx<Map<String, dynamic>>({
    'name': '点击登录',
    'qq': '',
    'id': 0,
  });
  final loginTrigger = 0.obs;

  // 主界面壳
  final currentPageIndex = 0.obs;
  final isBottomNavVisible = true.obs;
  final isHideBottomNavOnScroll = true.obs;
  final sendCommentTrigger = 0.obs;

  // 主题
  final _themeMode = 1.obs;
  final _dynamicColor = false.obs;
  final _fontFamily = ''.obs;
  final _fontScale = 1.0.obs;
  final _fontWeightIndex = 3.obs;
  final _reduceVisualEffects = false.obs;

  bool get isLoggedIn {
    final id = userInfo.value['id'];
    return id != null && id != 0;
  }

  String get fontFamily => _fontFamily.value;
  double get fontScale => _fontScale.value;
  int get fontWeightIndex => _fontWeightIndex.value;
  FontWeight get fontWeight => AppFonts.availableWeights[fontWeightIndex];
  int get themeMode => _themeMode.value;
  bool get dynamicColor => _dynamicColor.value;
  bool get reduceVisualEffects => _reduceVisualEffects.value;

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
    _refreshUserInfo();
    isHideBottomNavOnScroll.value =
        Instances.sp.getBool('hide_bottom_nav_on_scroll') ?? true;
    _themeMode.value = ThemeService.getThemeMode();
    _dynamicColor.value = ThemeService.getDynamicColor();
    _fontFamily.value = ThemeService.getFontFamily();
    _fontScale.value = ThemeService.getFontScale();
    _fontWeightIndex.value = ThemeService.getFontWeightIndex();
    _reduceVisualEffects.value = ThemeService.getReduceVisualEffects();
    WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged =
        () {
          if (_themeMode.value == 0) {
            _themeMode.refresh();
          }
        };
  }

  void _refreshUserInfo() {
    final u = Instances.sp.getString('userinfo');
    if (u != null) {
      userInfo.value = Map<String, dynamic>.from(jsonDecode(u));
    } else {
      userInfo.value = {'name': '点击登录', 'qq': '', 'id': 0};
    }
  }

  void triggerLoginRefresh() {
    _refreshUserInfo();
    loginTrigger.value++;
  }

  void performLogout() {
    for (final key in [
      'usertoken',
      'refresh_token',
      'token_expires_at',
      'token_expires_in',
      'userinfo',
    ]) {
      Instances.sp.remove(key);
    }
    triggerLoginRefresh();
  }

  /// 保存登录信息到 SP 并触发刷新
  Future<void> saveLoginInfo(
    String token,
    Map<String, dynamic> user, {
    String? refreshToken,
    String? tokenExpiresAt,
  }) async {
    await Instances.sp.setString('usertoken', token);
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await Instances.sp.setString('refresh_token', refreshToken);
    }
    if (tokenExpiresAt != null && tokenExpiresAt.isNotEmpty) {
      await Instances.sp.setString('token_expires_at', tokenExpiresAt);
    }
    await Instances.sp.setString('userinfo', jsonEncode(user));
    triggerLoginRefresh();
  }

  void changePage(int index) {
    currentPageIndex.value = index;
  }

  void updateScrollDirection(bool isScrollingDown) {
    if (Instances.isWindows) return;
    isBottomNavVisible.value = isHideBottomNavOnScroll.value
        ? !isScrollingDown
        : true;
  }

  void toggleHideBottomNavOnScroll(bool value) {
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
    if (mode < 0 || mode > 2) return;
    _themeMode.value = mode;
    ThemeService.setThemeMode(mode);
  }

  void setDynamicColor(bool value) {
    _dynamicColor.value = value;
    ThemeService.setDynamicColor(value);
  }

  void setFontFamily(String fontFamily) {
    _fontFamily.value = fontFamily;
    ThemeService.setFontFamily(fontFamily);
  }

  void setFontScale(double scale) {
    _fontScale.value = scale.clamp(0.8, 1.4);
    ThemeService.setFontScale(_fontScale.value);
  }

  void setFontWeightIndex(int index) {
    _fontWeightIndex.value = index.clamp(
      0,
      AppFonts.availableWeights.length - 1,
    );
    ThemeService.setFontWeightIndex(_fontWeightIndex.value);
  }

  void setReduceVisualEffects(bool value) {
    _reduceVisualEffects.value = value;
    ThemeService.setReduceVisualEffects(value);
  }

  @override
  void onClose() {
    WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged =
        null;
    super.onClose();
  }
}
