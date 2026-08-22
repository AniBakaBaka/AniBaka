import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:baka/instance.dart';
import 'package:baka/theme.dart';

class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.qq,
    required this.sign,
    required this.level,
    this.passwordMarker,
  });

  const AppUser.guest()
    : id = 0,
      name = '点击登录',
      qq = '',
      sign = '',
      level = 0,
      passwordMarker = null;

  factory AppUser.fromJson(
    Map<String, dynamic> json, {
    String? retainedPasswordMarker,
  }) => AppUser(
    id: (json['id'] as num).toInt(),
    name: json['name'] as String,
    qq: json['qq'] as String? ?? '',
    sign: json['sign'] as String? ?? '',
    level: (json['level'] as num).toInt(),
    passwordMarker: json['pwd'] as String? ?? retainedPasswordMarker,
  );

  final int id;
  final String name;
  final String qq;
  final String sign;
  final int level;
  final String? passwordMarker;

  bool get isLoggedIn => id != 0;
  bool get hasPassword => passwordMarker != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'qq': qq,
    'sign': sign,
    'level': level,
    if (passwordMarker != null) 'pwd': passwordMarker,
  };
}

/// 应用级共享状态：会话、主界面壳和主题。
class AppState extends GetxService {
  static const themeModeLabels = <String>['跟随系统', '浅色模式', '深色模式'];
  static const _themeModeKey = 'theme_mode';
  static const _dynamicColorKey = 'dynamic_color';
  static const _reduceVisualEffectsKey = 'reduce_visual_effects';

  final user = Rx<AppUser>(const AppUser.guest());

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

  bool get isLoggedIn => user.value.isLoggedIn;

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
    _refreshUserInfo();
    isHideBottomNavOnScroll.value =
        Instances.sp.getBool('hide_bottom_nav_on_scroll') ?? true;
    _themeMode.value = Instances.sp.getInt(_themeModeKey) ?? 1;
    _dynamicColor.value = Instances.sp.getBool(_dynamicColorKey) ?? false;
    _fontFamily.value = AppFonts.getSavedFont();
    _fontScale.value = AppFonts.getSavedFontScale();
    _fontWeightIndex.value = AppFonts.getSavedFontWeightIndex();
    _reduceVisualEffects.value =
        Instances.sp.getBool(_reduceVisualEffectsKey) ?? false;
    WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged =
        () {
          if (_themeMode.value == 0) {
            _themeMode.refresh();
          }
        };
  }

  void _refreshUserInfo() {
    final u = Instances.sp.getString('userinfo');
    if (u == null) {
      user.value = const AppUser.guest();
      return;
    }
    try {
      user.value = AppUser.fromJson(jsonDecode(u) as Map<String, dynamic>);
    } catch (_) {
      user.value = const AppUser.guest();
    }
  }

  void triggerLoginRefresh() {
    _refreshUserInfo();
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
    AppUser user, {
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
    await saveUser(user);
  }

  Future<void> saveTokenResponse(Map<String, dynamic> data) async {
    final token = data['token'] as String?;
    if (token == null || token.isEmpty) return;

    await Instances.sp.setString('usertoken', token);
    final refreshToken = data['refresh_token'] as String?;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await Instances.sp.setString('refresh_token', refreshToken);
    }
    final expiresIn = (data['expires_in'] as num?)?.toInt();
    if (expiresIn != null) {
      await Instances.sp.setString(
        'token_expires_at',
        DateTime.now()
            .add(Duration(seconds: expiresIn))
            .toUtc()
            .toIso8601String(),
      );
    }
  }

  Future<void> saveUser(AppUser next) async {
    await Instances.sp.setString('userinfo', jsonEncode(next.toJson()));
    user.value = next;
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
    Instances.sp.setInt(_themeModeKey, mode);
  }

  void setDynamicColor(bool value) {
    _dynamicColor.value = value;
    Instances.sp.setBool(_dynamicColorKey, value);
  }

  void setFontFamily(String fontFamily) {
    _fontFamily.value = fontFamily;
    Instances.sp.setString(AppFonts.spKey, fontFamily);
  }

  void setFontScale(double scale) {
    _fontScale.value = scale.clamp(0.8, 1.4);
    Instances.sp.setDouble(AppFonts.fontScaleKey, _fontScale.value);
  }

  void setFontWeightIndex(int index) {
    _fontWeightIndex.value = index.clamp(
      0,
      AppFonts.availableWeights.length - 1,
    );
    Instances.sp.setInt(AppFonts.fontWeightKey, _fontWeightIndex.value);
  }

  void setReduceVisualEffects(bool value) {
    _reduceVisualEffects.value = value;
    Instances.sp.setBool(_reduceVisualEffectsKey, value);
  }

  @override
  void onClose() {
    WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged =
        null;
    super.onClose();
  }
}
