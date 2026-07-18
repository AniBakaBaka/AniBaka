import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:get/get.dart';

/// 「我的」页面业务逻辑服务
///
/// 负责用户信息管理、主题切换、线路切换等。
/// UI 层（MinePage）持有本实例并驱动界面刷新。
class MineService {
  static const String tronUsdtAddress = 'TB26auGFvm6DWkHm166a3zTtTDJuX7LZpH';
  static const String qqGroupNumber = 'anibakabaka';
  static const String qqGroupUrl = 'https://t.me/bakabakatv';

  Map userInfo = {'id': 0};
  int themeMode = Instances.sp.getInt('theme_mode') ?? 1;
  String currentHost = Instances.sp.getString('host') ?? 'www.anibaka.com';

  void initUser() {
    final u = Instances.sp.getString('userinfo');
    userInfo = u == null ? {'id': 0} : jsonDecode(u);
  }

  bool get isLogin => userInfo['id'] != 0;

  String get displayName => isLogin ? (userInfo['name'] ?? 'Baka 用户') : '游客，你好';

  String get displaySubtitle =>
      isLogin ? (userInfo['sign'] ?? '这个人很懒，还没有签名') : '你还未登录哦〒▽〒';

  String get avatarQq => userInfo['qq'] ?? '';

  int get uid => userInfo['id'] ?? 0;

  static const _themeLabels = ['跟随系统', '浅色模式', '深色模式'];

  String get themeText =>
      _themeLabels[themeMode.clamp(0, _themeLabels.length - 1)];

  void switchTheme(int mode) {
    themeMode = mode;
    Get.find<AppState>().setThemeMode(mode);
  }

  void switchHost() {
    currentHost = currentHost == 'www.anibaka.com'
        ? 'doro.bakaup.com'
        : 'www.anibaka.com';
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
