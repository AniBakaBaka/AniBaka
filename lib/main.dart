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
import 'package:baka/services/media_session_service.dart';
import 'package:baka/services/network_service.dart';
import 'package:baka/services/playback_settings_service.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/services/system_proxy_service.dart';
import 'package:baka/utils/app_logger.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/navigation/bottom_navigation.dart';
import 'package:baka/widgets/platform/macos/macos_title_bar.dart';
import 'package:baka/widgets/platform/windows/windows_sidebar.dart';
import 'package:baka/widgets/platform/windows/windows_title_bar.dart';
import 'package:dynamic_color/dynamic_color.dart';
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
  PlaybackSettingsService.applyLowMemoryMode(
    PlaybackSettingsService.getLowMemoryMode(),
  );
  await AppLogger.instance.init();
  AppLogger.instance.info('Application bootstrap started', tag: 'Bootstrap');

  Directory? desktopHiveDirectory;
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
    desktopHiveDirectory = await Instances.desktopDataDirectory('hive');
    Hive.init(desktopHiveDirectory.path);
  } else {
    await Hive.initFlutter();
  }
  final storageRecoveries = await AppStorage.init(
    hiveDirectory: desktopHiveDirectory,
  );
  for (final recovery in storageRecoveries) {
    AppLogger.instance.warning(
      'Recovered unreadable Hive box "${recovery.boxName}"'
      '${recovery.backupPath == null ? '' : ' (backup: ${recovery.backupPath})'}',
      tag: 'Storage',
      error: recovery.reason,
    );
  }
  await SourceAdapterService.instance.init();
  MediaKit.ensureInitialized();
  await MediaSessionService.init();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
  );

  if (Platform.isAndroid) {
    const platformChannel = MethodChannel('baka/platform');
    Map<String, dynamic>? displayDiagnostics;
    try {
      Instances.isTV =
          await platformChannel.invokeMethod<bool>('isTV') ?? false;
    } catch (error, stackTrace) {
      Instances.isTV = false;
      AppLogger.instance.warning(
        'Android TV detection failed; using phone behavior',
        tag: 'Display',
        error: error,
        stackTrace: stackTrace,
      );
    }

    try {
      displayDiagnostics = await platformChannel
          .invokeMapMethod<String, dynamic>('getDisplayDiagnostics');
      AppLogger.instance.info(
        'Android display diagnostics: $displayDiagnostics',
        tag: 'Display',
      );
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'Unable to read Android display diagnostics',
        tag: 'Display',
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (Instances.isTV) {
      AppLogger.instance.info(
        'TV rendering policy: system display mode, '
        'impeller=${displayDiagnostics?['impellerEnabled']}',
        tag: 'Display',
      );
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      // Let Android TV keep the display mode selected by the system. Forcing
      // the highest phone refresh mode can make Flutter and video textures
      // alternate frames on TV firmware with incomplete mode support.
      try {
        await FlutterDisplayMode.setHighRefreshRate();
        AppLogger.instance.info(
          'Android rendering policy: high refresh mode request completed',
          tag: 'Display',
        );
      } catch (error, stackTrace) {
        AppLogger.instance.warning(
          'Android high refresh mode request failed',
          tag: 'Display',
          error: error,
          stackTrace: stackTrace,
        );
      }
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
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => Obx(() {
        final useDynamicColor = appState.dynamicColor && !Instances.isTV;
        final themes = AppTheme.resolve(
          fontFamily: appState.fontFamily,
          fontWeight: appState.fontWeight,
          lightColorScheme: useDynamicColor ? lightDynamic : null,
          darkColorScheme: useDynamicColor ? darkDynamic : null,
        );
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(
            textScaler: TextScaler.linear(appState.fontScale),
            disableAnimations:
                mediaQuery.disableAnimations || appState.reduceVisualEffects,
          ),
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
      await AppStorage.clearAllCache();
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
                if (Platform.isWindows) const WindowsTitleBar(),
                if (Platform.isMacOS) const MacOSTitleBar(title: 'Baka'),
                Expanded(
                  child: Row(
                    children: [
                      if (Instances.isDesktopPlatform)
                        Obx(() {
                          _appState.loginTrigger.value;
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
                                  child: _pages[index],
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
                () => AnimatedSlide(
                  duration: navigationDuration,
                  curve: Curves.easeOutCubic,
                  offset: _appState.isBottomNavVisible.value
                      ? Offset.zero
                      : const Offset(0, 1),
                  child: ExcludeSemantics(
                    excluding: !_appState.isBottomNavVisible.value,
                    child: AppBottomNavigation(
                      currentIndex: _appState.currentPageIndex.value,
                      onTap: _appState.changePage,
                      items: _navItems,
                    ),
                  ),
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
