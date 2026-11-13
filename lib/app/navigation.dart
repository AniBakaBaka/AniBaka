import 'package:baka/instance.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/pages/login/login_page.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/pages/search/search_page.dart';
import 'package:baka/pages/source/source_management_page.dart';
import 'package:baka/widgets/anime_detail/anime_detail_placeholder.dart';
import 'package:baka/widgets/platform/tv/tv_anime_detail.dart';
import 'package:flutter/material.dart';

/// Opens the app's pages. Pages use [MaterialPageRoute], so transitions and
/// back gestures come from the theme's [PageTransitionsTheme].
abstract final class NavigationService {
  static final _desktopFade = CurveTween(curve: Curves.easeInOutCubic);

  static Future<T?> push<T>(BuildContext context, Widget page) =>
      Navigator.of(context).push<T>(MaterialPageRoute<T>(builder: (_) => page));

  /// Opens the detail page of [data], which it reads without copying.
  ///
  /// On mobile the page grows out of the pressed card like every other page.
  /// Desktop fades it in while the cover flies as a [Hero] tagged [heroTag].
  static void toDetail(
    BuildContext context,
    Map data, {
    int? posIndex,
    Object? heroTag,
  }) {
    final navigator = Navigator.of(context);
    if (Instances.isTV) {
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              TvAnimeDetailPlaceholder(data: data, episodeIndex: posIndex),
        ),
      );
      return;
    }
    final page = AnimeDetailPlaceholder(
      data: data,
      heroTag: heroTag,
      episodeIndex: posIndex,
    );
    if (!Instances.isDesktopPlatform) {
      navigator.push(MaterialPageRoute<void>(builder: (_) => page));
      return;
    }
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 300);
    navigator.push(
      PageRouteBuilder<void>(
        transitionDuration: duration,
        reverseTransitionDuration: duration,
        pageBuilder: (_, _, _) => page,
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: animation.drive(_desktopFade),
          child: child,
        ),
      ),
    );
  }

  static Future<void> toPlayback(
    BuildContext context,
    PlaybackRequest request, {
    int? posIndex,
    bool popFirst = false,
    bool autoMatch = true,
  }) {
    final navigator = Navigator.of(context);
    if (popFirst) navigator.pop();
    return navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          request: request,
          posIndex: posIndex,
          autoMatch: autoMatch,
        ),
      ),
    );
  }

  static void toSearch(
    BuildContext context, {
    String? keyword,
    int? initialSource,
  }) =>
      push<void>(context, SearchPage(k: keyword, initialSource: initialSource));

  static void toSourceManagement(BuildContext context) =>
      push<void>(context, const SourceManagementPage());

  static void toLogin(BuildContext context) =>
      push<void>(context, const Login());
}
