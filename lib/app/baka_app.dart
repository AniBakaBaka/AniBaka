import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:baka/app/app_runtime.dart';
import 'package:baka/app_state.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/home/home_page.dart';
import 'package:baka/pages/library/library_page.dart';
import 'package:baka/pages/mine/mine_page.dart';
import 'package:baka/pages/player/download_page.dart';
import 'package:baka/pages/schedule/update_schedule_page.dart';
import 'package:baka/pages/thread/thread_page.dart';
import 'package:baka/theme.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/navigation/bottom_navigation.dart';
import 'package:baka/widgets/platform/macos/macos_title_bar.dart';
import 'package:baka/widgets/platform/windows/windows_sidebar.dart';
import 'package:baka/widgets/platform/windows/windows_title_bar.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:get/get.dart' hide ContextExtensionss;

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
          builder: (context, child) => Obx(() {
            final mediaQuery = MediaQuery.of(context);
            return MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: TextScaler.linear(appState.fontScale),
                disableAnimations:
                    mediaQuery.disableAnimations ||
                    appState.reduceVisualEffects,
              ),
              child: child!,
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

  final _appState = Get.find<AppState>();

  /// Tab pages are built on first visit and then kept.
  final _pages = List<Widget?>.filled(
    Instances.isDesktopPlatform ? 6 : 4,
    null,
  );

  int _lastBackPressTime = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    } else if (state == AppLifecycleState.detached) {
      Get.find<AppRuntime>().close();
    }
  }

  void _onPopInvoked(bool didPop, Object? result) {
    if (didPop) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastBackPressTime > 1000) {
      showSnackBar('再按一次退出应用', gravity: ToastGravity.CENTER);
      _lastBackPressTime = now;
    } else {
      Get.find<AppRuntime>().close().whenComplete(SystemNavigator.pop);
    }
  }

  /// Hides the navigation bar while content scrolls down. User scroll
  /// notifications only arrive when the drag direction changes.
  bool _onUserScroll(UserScrollNotification notification) {
    if (notification.metrics.axis == Axis.vertical &&
        notification.direction != ScrollDirection.idle) {
      _appState.showBottomNav(
        notification.direction == ScrollDirection.forward,
      );
    }
    return false;
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

    final desktop = Instances.isDesktopPlatform;
    final pages = Obx(() {
      final current = _appState.currentPageIndex.value;
      return IndexedStack(
        index: current,
        children: [
          for (var i = 0; i < _pages.length; i++)
            TickerMode(
              enabled: i == current,
              child: i == current
                  ? _pageAt(i)
                  : _pages[i] ?? const SizedBox.shrink(),
            ),
        ],
      );
    });

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        extendBody: !desktop,
        body: desktop
            ? Column(
                children: [
                  if (Platform.isWindows) const WindowsTitleBar(),
                  if (Platform.isMacOS) const MacOSTitleBar(title: 'Baka'),
                  Expanded(
                    child: Row(
                      children: [
                        Obx(() {
                          Get.find<AccountSession>().user.value;
                          return WindowsSidebar(
                            currentPageIndex: _appState.currentPageIndex.value,
                            onPageChange: _appState.changePage,
                          );
                        }),
                        Expanded(child: pages),
                      ],
                    ),
                  ),
                ],
              )
            : NotificationListener<UserScrollNotification>(
                onNotification: _onUserScroll,
                child: pages,
              ),
        bottomNavigationBar: desktop
            ? null
            : Obx(
                () => AppBottomNavigation(
                  visible: _appState.isBottomNavVisible.value,
                  currentIndex: _appState.currentPageIndex.value,
                  onTap: _appState.changePage,
                  items: _navItems,
                ),
              ),
      ),
    );
  }
}
