import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/theme_service.dart';
import 'package:get/get.dart';

/// 「我的」页面业务逻辑服务
///
/// 会话与主题模式的唯一真源是 [AppState]，这里只做页面级的取值与动作，
/// 不再自己重新 jsonDecode 一份 userinfo、也不再维护第二份 themeMode 与主题文案表。
class MineService {
  static const String tronUsdtAddress = 'TB26auGFvm6DWkHm166a3zTtTDJuX7LZpH';
  static const String qqGroupNumber = 'anibakabaka';
  static const String qqGroupUrl = 'https://t.me/bakabakatv';

  static const String _primaryHost = 'www.anibaka.com';
  static const String _mirrorHost = 'doro.bakaup.com';

  AppState get _appState => Get.find<AppState>();

  String currentHost = Instances.sp.getString('host') ?? _primaryHost;

  Map<String, dynamic> get userInfo => _appState.userInfo.value;

  bool get isLogin => _appState.isLoggedIn;

  String get displayName => isLogin ? (userInfo['name'] ?? 'Baka 用户') : '游客，你好';

  String get displaySubtitle =>
      isLogin ? (userInfo['sign'] ?? '这个人很懒，还没有签名') : '你还未登录哦〒▽〒';

  String get avatarQq => userInfo['qq'] ?? '';

  int get uid => userInfo['id'] ?? 0;

  int get themeMode => _appState.themeMode;

  String get themeText => ThemeService.themeModeLabel(themeMode);

  void switchTheme(int mode) => _appState.setThemeMode(mode);

  void switchHost() {
    currentHost = currentHost == _primaryHost ? _mirrorHost : _primaryHost;
    Instances.sp.setString('host', currentHost);
  }

  Future<bool> copyUid() async {
    if (uid == 0) return false;
    await Clipboard.setData(ClipboardData(text: uid.toString()));
    return true;
  }

  Future<bool> joinQqGroup() async {
    try {
      return await launchUrlString(
        qqGroupUrl,
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      debugPrint('打开群链接失败: $e');
      return false;
    }
  }

  Future<void> copySponsorAddress() async {
    await Clipboard.setData(const ClipboardData(text: tronUsdtAddress));
  }
}
