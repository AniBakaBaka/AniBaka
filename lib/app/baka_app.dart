import 'package:baka/models/playback_request.dart';
import 'package:baka/app/app_runtime.dart';
import 'package:baka/core/account_session.dart';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/home/home_page.dart';
import 'package:baka/services/download/download_resolve_manager.dart';
import 'package:baka/pages/library/library_page.dart';
import 'package:baka/pages/login/login_page.dart';
import 'package:baka/pages/mine/mine_page.dart';
import 'package:baka/pages/player/download_page.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/pages/schedule/update_schedule_page.dart';
import 'package:baka/pages/thread/thread_page.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/navigation/bottom_navigation.dart';
import 'package:baka/widgets/platform/macos/macos_title_bar.dart';
import 'package:baka/widgets/platform/windows/windows_sidebar.dart';
import 'package:baka/widgets/platform/windows/windows_title_bar.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:get/get.dart' hide ContextExtensionss;

import 'package:baka/theme.dart';

class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  static final Set<PointerDeviceKind> _dragDevices =
      Set<PointerDeviceKind>.unmodifiable({
        ...const MaterialScrollBehavior().dragDevices,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
      });

  @override
  Set<PointerDeviceKind> get dragDevices => _dragDevices;
}

class BakaApp extends StatelessWidget {
  const BakaApp({super.key});

  Route? _onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case 'Baka://home':
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const HomePage(),
        );
      case 'Baka://player':
        final args = settings.arguments as Map<String, dynamic>?;
        if (args?['data'] != null) {
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) =>
                PlayerPage(request: PlaybackRequest.fromMap(args!['data'])),
          );
        }
        return null;
      case 'Baka://login':
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const Login(),
        );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final appState = Get.find<AppState>();
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => Obx(() {
        final useDynamicColor = appState.dynamicColor && !Instances.isTV;
        final themes = AppTheme.resolve(
          fontFamily: appState.fontFamily,
          fontWeight: appState.fontWeight,
          lightColorScheme: useDynamicColor ? lightDynamic : null,
          darkColorScheme: useDynamicColor ? darkDynamic : null,
        );
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          scrollBehavior: const AppScrollBehavior(),
          navigatorKey: Instances.navigatorKey,
          scaffoldMessengerKey: scaffoldMessengerKey,
          themeMode: Instances.isTV
              ? ThemeMode.dark
              : appState.currentThemeMode,
          theme: themes.light,
          darkTheme: themes.dark,
          home: const MyHomePage(),
          title: 'Baka',
          onGenerateRoute: _onGenerateRoute,
          builder: (context, child) => Obx(() {
            final mediaQuery = MediaQuery.of(context);
            return MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: TextScaler.linear(appState.fontScale),
                disableAnimations:
                    mediaQuery.disableAnimations ||
                    appState.reduceVisualEffects,
              ),
              child: Stack(
                children: [
                  child ?? const SizedBox.shrink(),
                  const DownloadResolveBanner(),
                ],
              ),
            );
          }),
        );
      }),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  static const List<AppNavItem> _navItems = [
    AppNavItem(iconPath: 'assets/compass', label: '番组'),
    AppNavItem(iconPath: '', label: '更新', iconData: Icons.timeline),
    AppNavItem(iconPath: 'assets/message-circle', label: 'BAKA'),
    AppNavItem(iconPath: 'assets/smiling-face', label: '我的'),
  ];

  late final List<Widget?> _pages;
  late final AppState _appState;

  int _lastBackPressTime = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appState = Get.find<AppState>();

    _pages = List<Widget?>.filled(Instances.isDesktopPlatform ? 6 : 4, null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Get.find<AppRuntime>().checkSourceUpdates();
    }
    if (state == AppLifecycleState.detached) {
      _clearCacheOnExit();
    }
  }

  Future<void> _clearCacheOnExit() => Get.find<AppRuntime>().close();

  void _onPopInvoked(bool didPop, dynamic result) {
    if (didPop) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastBackPressTime > 1000) {
      showSnackBar('再按一次退出应用', gravity: ToastGravity.CENTER);
      _lastBackPressTime = now;
    } else {
      _clearCacheOnExit().whenComplete(SystemNavigator.pop);
    }
  }

  Widget _pageAt(int index) {
    final cached = _pages[index];
    if (cached != null) return cached;
    final page = Instances.isDesktopPlatform
        ? switch (index) {
            0 => const HomePage(),
            1 => const ThreadPage(),
            2 => MinePage(
              onOpenLibrary: (index) =>
                  _appState.changePage(index == 1 ? 3 : 4),
              onOpenDownloads: () => _appState.changePage(5),
            ),
            3 => const LibraryPage(initialIndex: 1, embedded: true),
            4 => const LibraryPage(embedded: true),
            _ => const DownloadManagerPage(embedded: true),
          }
        : switch (index) {
            0 => const HomePage(),
            1 => const UpdateSchedulePage(),
            2 => const ThreadPage(),
            _ => const MinePage(),
          };
    final content = RepaintBoundary(child: page);
    // 片库与下载重新进入时读取最新数据，离开后释放页面监听与列表状态。
    if (Instances.isDesktopPlatform && index >= 3) return content;
    return _pages[index] = content;
  }

  @override
  Widget build(BuildContext context) {
    if (Instances.isTV) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: _onPopInvoked,
        child: const Scaffold(
          backgroundColor: Color(0xFF0D0D0D),
          body: HomePage(),
        ),
      );
    }

    final theme = Theme.of(context);
    final reduceVisualEffects = context.reduceMotion;
    final navigationDuration = reduceVisualEffects
        ? Duration.zero
        : const Duration(milliseconds: 300);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        extendBody: !Instances.isDesktopPlatform,
        body: Stack(
          children: [
            Column(
              children: [
                if (Platform.isWindows && Instances.isDesktopPlatform)
                  const WindowsTitleBar(),
                if (Platform.isMacOS) const MacOSTitleBar(title: 'Baka'),
                Expanded(
                  child: Row(
                    children: [
                      if (Instances.isDesktopPlatform)
                        Obx(() {
                          Get.find<AccountSession>().user.value;
                          return WindowsSidebar(
                            currentPageIndex: _appState.currentPageIndex.value,
                            onPageChange: _appState.changePage,
                          );
                        }),
                      Expanded(
                        child: Obx(() {
                          final currentIndex = _appState.currentPageIndex.value;
                          return IndexedStack(
                            index: currentIndex,
                            children: [
                              for (
                                var index = 0;
                                index < _pages.length;
                                index++
                              )
                                TickerMode(
                                  enabled: index == currentIndex,
                                  child: index == currentIndex
                                      ? _pageAt(index)
                                      : (_pages[index] ??
                                            const SizedBox.shrink()),
                                ),
                            ],
                          );
                        }),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (!Instances.isDesktopPlatform)
              Obx(() {
                if (_appState.currentPageIndex.value != 2) {
                  return const SizedBox.shrink();
                }
                // 底栏总高 = 70 + max(系统底部安全区, 10)：FAB 必须跟着安全区抬升，
                // 否则在手势条/三键导航设备上会叠进半透明栏里被模糊。
                final safeBottom = MediaQuery.paddingOf(context).bottom;
                final navBarBottom = 70 + (safeBottom < 10 ? 10.0 : safeBottom);
                return Positioned(
                  right: 24,
                  bottom: navBarBottom + 16,
                  child: AnimatedSlide(
                    duration: navigationDuration,
                    curve: Curves.easeOutCubic,
                    offset: _appState.isBottomNavVisible.value
                        ? Offset.zero
                        : const Offset(0, 3),
                    child: ExcludeSemantics(
                      excluding: !_appState.isBottomNavVisible.value,
                      child: _buildPostButton(theme),
                    ),
                  ),
                );
              }),
          ],
        ),
        bottomNavigationBar: !Instances.isDesktopPlatform
            ? Obx(
                () => AppBottomNavigation(
                  visible: _appState.isBottomNavVisible.value,
                  currentIndex: _appState.currentPageIndex.value,
                  onTap: _appState.changePage,
                  items: _navItems,
                ),
              )
            : null,
      ),
    );
  }

  Widget _buildPostButton(ThemeData theme) {
    const radius = BorderRadius.all(Radius.circular(28));
    final reduceVisualEffects = context.reduceMotion;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.mediumImpact();
          _appState.triggerSendComment();
        },
        borderRadius: radius,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: radius,
            // 光晕减淡：按钮悬在毛玻璃底栏上方，重阴影会被玻璃取样成彩色涂抹。
            boxShadow: reduceVisualEffects
                ? null
                : [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.22),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: const Icon(Icons.edit_rounded, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}
