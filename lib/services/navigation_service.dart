import 'package:flutter/material.dart';
import 'package:baka/pages/anime_detail/anime_detail_page.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/pages/search/search_page.dart';
import 'package:baka/pages/source/source_management_page.dart';
import 'package:baka/utils/platform_page_route.dart';

/// 集中管理页面导航，解耦 Widget 对具体 Page 的直接依赖。
class NavigationService {
  NavigationService._();

  static PageRoute<void> _slideRoute(Widget page, {Duration? duration}) {
    return platformPageRoute<void>(
      builder: (_) => page,
      transitionDuration: duration ?? const Duration(milliseconds: 380),
      reverseTransitionDuration: duration ?? const Duration(milliseconds: 360),
      transitionsBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: const Cubic(0.22, 1.0, 0.36, 1.0),
          reverseCurve: const Cubic(0.32, 0.0, 0.67, 0.0),
        );
        final fade = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween(
            begin: const Offset(0.12, 0.0),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: fade, child: child),
        );
      },
    );
  }

  /// 导航到番剧详情页，并保留当前页面以便正常返回。
  static void toDetail(
    BuildContext context,
    Map data, {
    int? posIndex,
    bool autoMatch = false,
  }) {
    // Detail and later playback enrich their route data independently. Keep
    // those mutations away from the source card while retaining its episode.
    final routeData = Map<String, dynamic>.from(data);
    if (posIndex != null) routeData['currPlayIndex'] = posIndex;
    Navigator.push(
      context,
      _slideRoute(
        autoMatch
            ? PlayerPage(data: routeData, posIndex: posIndex, autoMatch: true)
            : AnimeDetailPage(data: routeData),
      ),
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
    final navigator = Navigator.of(context);
    if (popFirst) navigator.pop();
    // Playback selection mutates the page data as episodes and lines change.
    // Do not leak that state back into a detail page or search result card.
    final routeData = Map<String, dynamic>.from(data);
    final PageRoute<void> route = fade
        ? platformPageRoute<void>(
            builder: (_) => PlayerPage(
              data: routeData,
              posIndex: posIndex,
              autoMatch: autoMatch,
            ),
            transitionsBuilder: (_, anim, _, child) =>
                FadeTransition(opacity: anim, child: child),
            transitionDuration: const Duration(milliseconds: 300),
          )
        : _slideRoute(
            PlayerPage(
              data: routeData,
              posIndex: posIndex,
              autoMatch: autoMatch,
            ),
          );
    navigator.push(route);
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

  /// 导航到源管理页面
  static void toSourceManagement(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SourceManagementPage()),
    );
  }
}
