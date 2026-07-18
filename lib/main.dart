import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/home/home_page.dart';
import 'package:baka/pages/login/login_page.dart';
import 'package:baka/pages/mine/mine_page.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/pages/schedule/update_schedule_page.dart';
import 'package:baka/pages/thread/thread_page.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/services/cache_manager.dart';
import 'package:baka/services/dau_tracker.dart';
import 'package:baka/services/media_session_service.dart';
import 'package:baka/services/playback_settings_service.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/services/system_proxy_service.dart';
import 'package:baka/utils/app_logger.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/navigation/bottom_navigation.dart';
import 'package:baka/widgets/platform/macos/macos_title_bar.dart';
import 'package:baka/widgets/platform/windows/windows_sidebar.dart';
import 'package:baka/widgets/platform/windows/windows_title_bar.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'theme.dart';

Future<void> main() {
  return AppLogger.runZoned(_bootstrap);
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemProxyService.initialize();
  await Instances.init();
  await AppLogger.instance.init();
  AppLogger.instance.debug('Application bootstrap started', tag: 'Bootstrap');

  if (Instances.isDesktopPlatform) {
    await Instances.prepareDesktopWorkspace(
      legacyHiveBoxes: const [
        AppStorage.videoProgressBoxName,
        AppStorage.customSourcesBoxName,
        AppStorage.downloadTasksBoxName,
        AppStorage.playHistoryBoxName,
        AppStorage.threadCommentsBoxName,
        AppStorage.bgmCacheBoxName,
        AppStorage.homeCacheBoxName,
        'storage_configs',
      ],
    );
    Hive.init((await Instances.desktopDataDirectory('hive')).path);
  } else {
    await Hive.initFlutter();
  }
  await AppStorage.init();
  await SourceAdapterService.instance.init();
  MediaKit.ensureInitialized();
  await MediaSessionService.init();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
  );

  if (Platform.isAndroid) {
    FlutterDisplayMode.setHighRefreshRate().catchError((_) {});
    try {
      Instances.isTV =
          await const MethodChannel(
            'baka/platform',
          ).invokeMethod<bool>('isTV') ??
          false;
    } catch (_) {
      Instances.isTV = false;
    }

    if (Instances.isTV) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  if (Instances.isDesktopPlatform) {
    doWhenWindowReady(() {
      appWindow.minSize = const Size(800, 600);
      appWindow.size = const Size(1280, 720);
      appWindow.alignment = Alignment.center;
      appWindow.title = 'Baka';
      appWindow.show();
    });
  }

  Get.put(AppState(), permanent: true);

  DauTracker.track();

  runApp(const BakaApp());
}

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
            builder: (_) => PlayerPage(data: args!['data']),
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
    return Obx(() {
      final themes = AppTheme.resolve(
        fontFamily: appState.fontFamily,
        fontWeight: appState.fontWeight,
      );
      return MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(appState.fontScale)),
        child: MaterialApp(
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
        ),
      );
    });
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

  late final List<Widget> _pages;
  late final AppState _appState;

  int _lastBackPressTime = 0;
  bool _hasClearedCacheOnExit = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appState = Get.find<AppState>();

    _pages = Instances.isDesktopPlatform
        ? const [
            RepaintBoundary(child: HomePage()),
            RepaintBoundary(child: ThreadPage()),
            RepaintBoundary(child: MinePage()),
          ]
        : const [
            RepaintBoundary(child: HomePage()),
            RepaintBoundary(child: UpdateSchedulePage()),
            RepaintBoundary(child: ThreadPage()),
            RepaintBoundary(child: MinePage()),
          ];
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _clearCacheOnExit();
    }
  }

  Future<void> _clearCacheOnExit() async {
    if (_hasClearedCacheOnExit) return;
    _hasClearedCacheOnExit = true;
    if (PlaybackSettingsService.getClearCacheOnExit()) {
      await CacheManagerService.instance.clearAllCache();
    }
  }

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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        extendBody: !Instances.isDesktopPlatform,
        body: Stack(
          children: [
            Column(
              children: [
                if (Platform.isWindows) const WindowsTitleBar(),
                if (Platform.isMacOS) const MacOSTitleBar(title: 'Baka'),
                Expanded(
                  child: Row(
                    children: [
                      if (Instances.isDesktopPlatform)
                        Obx(
                          () => WindowsSidebar(
                            currentPageIndex: _appState.currentPageIndex.value,
                            userInfo: _appState.userInfo.value,
                            onPageChange: _appState.changePage,
                          ),
                        ),
                      Expanded(
                        child: Obx(
                          () => IndexedStack(
                            index: _appState.currentPageIndex.value,
                            children: _pages,
                          ),
                        ),
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
                return Positioned(
                  right: 24,
                  bottom: 96,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    offset: _appState.isBottomNavVisible.value
                        ? Offset.zero
                        : const Offset(0, 3),
                    child: _buildPostButton(theme),
                  ),
                );
              }),
          ],
        ),
        bottomNavigationBar: !Instances.isDesktopPlatform
            ? Obx(
                () => AnimatedSlide(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  offset: _appState.isBottomNavVisible.value
                      ? Offset.zero
                      : const Offset(0, 1),
                  child: AppBottomNavigation(
                    currentIndex: _appState.currentPageIndex.value,
                    onTap: _appState.changePage,
                    items: _navItems,
                  ),
                ),
              )
            : null,
      ),
    );
  }

  Widget _buildPostButton(ThemeData theme) {
    const radius = BorderRadius.all(Radius.circular(28));
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
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.primary.withValues(alpha: 0.4),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(Icons.edit_rounded, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}
