import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/bangumi_sync_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/reg_utils.dart';
import 'package:get/get.dart';

/// 「我的」页面业务逻辑服务
///
/// 会话与主题模式的唯一真源是 [AppState]，这里只做页面级的取值与动作，
class MineService {
  static const String tronUsdtAddress = 'TB26auGFvm6DWkHm166a3zTtTDJuX7LZpH';
  static const String qqGroupNumber = 'anibakabaka';
  static const String qqGroupUrl = 'https://t.me/bakabakatv';

  static const String _primaryHost = 'www.anibaka.com';
  static const String _mirrorHost = 'doro.bakaup.com';

  AppState get _appState => Get.find<AppState>();

  String currentHost = Instances.sp.getString('host') ?? _primaryHost;

  AppUser get user => _appState.user.value;

  bool get isLogin => _appState.isLoggedIn;

  bool get isBangumiLogin => BangumiSyncService.instance.isConnected;

  bool get hasIdentity => isLogin || isBangumiLogin;

  BangumiAccount? get bangumiAccount => BangumiSyncService.instance.account;

  String get displayName {
    if (isLogin) return user.name;
    if (isBangumiLogin) {
      final account = bangumiAccount;
      return account?.nickname.isNotEmpty == true
          ? account!.nickname
          : (account?.username ?? 'Bangumi 用户');
    }
    return '游客，你好';
  }

  String get displaySubtitle {
    if (isLogin) return user.sign.isEmpty ? '这个人很懒，还没有签名' : user.sign;
    if (isBangumiLogin) return 'Bangumi 登录 · 播放历史仅保存在本机';
    return '你还未登录哦〒▽〒';
  }

  String get avatarQq => user.qq;

  String get avatarUrl {
    if (isLogin) return getAvatar(avatar: avatarQq);
    final source = bangumiAccount?.avatarUrl ?? '';
    return BgmUtils.bgmImageProxyUrl(source, width: 240);
  }

  int get uid => user.id;

  int get themeMode => _appState.themeMode;

  String get themeText => _appState.themeModeLabel;

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
