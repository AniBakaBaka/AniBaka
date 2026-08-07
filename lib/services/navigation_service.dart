import 'package:flutter/material.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/pages/player/bgm_detail_page.dart';
import 'package:baka/pages/search/search_page.dart';
import 'package:baka/pages/search/tag_page.dart';
import 'package:baka/pages/setting/danmaku_settings_page.dart';
import 'package:baka/pages/setting/subtitle_settings_page.dart';
import 'package:baka/pages/setting/player_settings_page.dart';
import 'package:baka/pages/home/miniapp_page.dart'; // exports WebViewPage
import 'package:baka/pages/library/library_page.dart';
import 'package:baka/pages/player/download_page.dart';
import 'package:baka/pages/source/source_management_page.dart';
import 'package:baka/pages/setting/app_settings_page.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:baka/widgets/danmaku/danmaku_list_sheet.dart';
import 'package:baka/utils/platform_page_route.dart';




/// 集中管理页面导航，解耦 Widget 对具体 Page 的直接依赖。
class NavigationService {
  NavigationService._();

  static PageRoute<void> _slideRoute(Widget page, {Duration? duration}) {
    return platformPageRoute<void>(
      builder: (_) => page,
      transitionDuration: duration ?? const Duration(milliseconds: 350),
      transitionsBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return SlideTransition(
          position: Tween(
            begin: const Offset(0.3, 0.0),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: animation, child: child),
        );
      },
    );
  }

  /// 导航到番剧详情/播放页面（pushAndRemoveUntil，保留首页）
  static void toDetail(
    BuildContext context,
    Map data, {
    int? posIndex,
    bool autoMatch = false,
  }) {
    Navigator.pushAndRemoveUntil(
      context,
      _slideRoute(PlayerPage(data: data, posIndex: posIndex, autoMatch: autoMatch)),
      (route) => route.isFirst,
    );
  }

  static void toPlayer(
    BuildContext context,
    Map data, {
    int? posIndex,
    bool popFirst = false,
    bool fade = false,
    bool autoMatch = true,
  }) {
    if (popFirst) Navigator.of(context).pop();
    final PageRoute<void> route = fade
        ? platformPageRoute<void>(
            builder: (_) => PlayerPage(data: data, posIndex: posIndex, autoMatch: autoMatch),
            transitionsBuilder: (_, anim, _, child) =>
                FadeTransition(opacity: anim, child: child),
            transitionDuration: const Duration(milliseconds: 300),
          )
        : _slideRoute(PlayerPage(data: data, posIndex: posIndex, autoMatch: autoMatch));
    Navigator.push(context, route);
  }

  /// 导航到搜索页面
  static void toSearch(
    BuildContext context, {
    String? keyword,
    int? initialSource,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchPage(k: keyword, initialSource: initialSource),
      ),
    );
  }

  /// 导航到标签搜索页面
  static void toTag(BuildContext context, String tag, int index) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TagPage(tag, index)),
    );
  }

  /// 显示 BGM 详情底部弹窗
  static Future<void> showBgmDetail(
    BuildContext context, {
    required String title,
    int? subjectId,
    String? imageUrl,
    String? fixedSummary,
    double? initialScore,
  }) {
    return BgmDetailPage.show(
      context,
      title: title,
      subjectId: subjectId,
      imageUrl: imageUrl,
      fixedSummary: fixedSummary,
      initialScore: initialScore,
    );
  }

  /// 显示弹幕设置对话框
  static Future<void> showDanmakuSettings(
    BuildContext context,
    DanmakuController controller, {
    String? defaultTitle,
    int? defaultEpisode,
  }) {
    return DanmakuSettingsPage.show(
      context,
      controller,
      defaultTitle: defaultTitle,
      defaultEpisode: defaultEpisode,
    );
  }

  /// 显示手动弹幕检索对话框（统一合并使用 DanmakuListSheet）
  static Future<void> showDanmakuSearch(
    BuildContext context,
    DanmakuController controller, {
    String? defaultTitle,
    int? defaultEpisode,
  }) {
    return DanmakuListSheet.show(
      context,
      controller,
      defaultTitle: defaultTitle,
      defaultEpisode: defaultEpisode,
      initialShowSearch: true,
    );
  }





  /// 显示字幕设置对话框
  static Future<void> showSubtitleSettings(
    BuildContext context,
    PlaybackController controller,
  ) {
    return SubtitleSettingsPage.show(context, controller);
  }

  /// 显示播放器设置
  static Future<void> showPlayerSettings(
    BuildContext context,
    PlaybackController controller,
  ) {
    return PlayerSettingsPage.show(context, controller);
  }

  /// 导航到应用设置
  static void toAppSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AppSettingsPage()),
    );
  }

  /// 导航到 WebView 页面
  static void toWebView(
    BuildContext context, {
    required String url,
    required String title,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WebViewPage(url: url, title: title),
      ),
    );
  }

  /// 导航到收藏库页面
  static void toLibrary(BuildContext context, {int initialIndex = 0}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LibraryPage(initialIndex: initialIndex),
      ),
    );
  }

  /// 导航到源管理页面
  static void toSourceManagement(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SourceManagementPage()),
    );
  }

  /// 显示下载管理页面
  static void showDownloadManager(BuildContext context) {
    DownloadManagerPage.show(context);
  }
}
