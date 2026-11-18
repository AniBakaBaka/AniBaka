import 'dart:async';
import 'dart:io';

import 'package:baka/api/api_config.dart';
import 'package:baka/api/auth_api.dart';
import 'package:baka/api/bangumi_account_api.dart';
import 'package:baka/app/navigation.dart';
import 'package:baka/app/platform_setup.dart';
import 'package:baka/app/usage_tracker.dart';
import 'package:baka/app/watch_party_links.dart';
import 'package:baka/app_state.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/core/app_logger.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/core/network_service.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/player/download_page.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/services/collection/bangumi_sync.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/download/download_manager.dart';
import 'package:baka/services/playback/animejanai_playback.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/services/playback/dlss_global_playback.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/playback/media_session.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/services/playback/watch_party.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/theme.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:hive_flutter/hive_flutter.dart';

/// Composition root and owner of application-lifetime resources.
class AppRuntime {
  AppRuntime({this.platformSetup = configurePlatform, this.incomingLinks});
  final Future<void> Function() platformSetup;
  final Stream<Uri>? incomingLinks;
  final _cleanup = <FutureOr<void> Function()>[];
  bool _ready = false;
  Map<String, int> _notifiedSourceUpdates = const {};
  Future<void>? _initializing, _closing;
  final playbacks = <PlaybackController>{};
  late AccountSession account;
  late WatchPartyService party;
  late WatchPartyLinks links;
  final mediaSession = MediaSessionService();

  Future<void> initialize() => _initializing ??= _initialize().catchError((
    Object error,
    StackTrace stack,
  ) async {
    await _releaseResources();
    _initializing = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _initialize() async {
    WidgetsFlutterBinding.ensureInitialized();
    await Instances.init();
    await Log.init();
    Log.i(
      'App',
      'Baka ${Instances.appVersion} on ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}',
    );
    NetworkService.init(Instances.sp);
    _cleanup.add(NetworkService.close);
    PlaybackSettingsService.applyLowMemoryMode(
      PlaybackSettingsService.getLowMemoryMode(),
    );
    final networkNotices = NetworkNotices(
      onNetworkError: () {
        if (_ready) showSnackBar('网络连接失败，请检查网络和线路＞︿＜', isError: true);
      },
      onImageFailures: () {
        if (_ready) {
          showSnackBar(
            '大量图片加载失败，你可能处于网络限制区域，请尝试切换网络或检查代理设置',
            isError: true,
            duration: const Duration(seconds: 5),
          );
        }
      },
    );
    final previousImageCache = CachedNetworkImageProvider.defaultCacheManager;
    final imageClient = NetworkService.createClient();
    final imageCache = MonitoredImageCache(
      Config(
        'libCachedImageData',
        fileService: HttpFileService(httpClient: imageClient),
      ),
      networkNotices,
    );
    CachedNetworkImageProvider.defaultCacheManager = imageCache;
    _cleanup.add(imageClient.close);
    _cleanup.add(imageCache.dispose);
    _cleanup.add(() {
      networkNotices.dispose();
      if (identical(
        CachedNetworkImageProvider.defaultCacheManager,
        imageCache,
      )) {
        CachedNetworkImageProvider.defaultCacheManager = previousImageCache;
      }
    });
    final client = NetworkService.createClient();
    _cleanup.add(client.close);
    final auth = AuthApi(client, () => ApiConfig.host);
    account = AccountSession(Instances.sp, refreshTokens: auth.refresh);
    apiTransport = ApiTransport(
      session: account,
      client: client,
      version: Instances.appVersion,
      credentialOrigin: () => Uri.parse(ApiConfig.host),
      onError: (error) {
        if (_ready) networkNotices.reportNetworkError(error);
      },
    );
    bangumiSession = BangumiSession(
      Instances.sp,
      account,
      BangumiApi(),
      const BangumiOAuthBroker(),
    );
    historyRepository = HistoryRepository(account, bangumiSession);
    collections = CollectionRepository(account, bangumiSession);
    bangumiSync = BangumiSyncService(bangumiSession, collections);
    sourceCatalog = SourceCatalog(Instances.sp);
    sourceRepository = SourceAdapterService(sourceCatalog);
    ruleRepository = RuleRepositoryService(sourceRepository, sourceCatalog);
    downloads = DownloadService();
    party = WatchPartyService(session: account);
    links = WatchPartyLinks(party, incoming: incomingLinks);
    _cleanup.addAll([
      account.close,
      bangumiSession.api.close,
      bangumiSession.cancelOAuthLogin,
      sourceCatalog.dispose,
      ruleRepository.dispose,
      sourceRepository.dispose,
      mediaSession.close,
      party.dispose,
      downloads.dispose,
      DanmakuController.clearCache,
      links.close,
    ]);

    Directory? directory;
    if (Instances.isDesktopPlatform) {
      await Instances.prepareDesktopWorkspace(
        legacyHiveBoxes: const [...AppStorage.boxNames, 'storage_configs'],
      );
      directory = await Instances.desktopDataDirectory('hive');
      Hive.init(directory.path);
    } else {
      await Hive.initFlutter();
    }
    await AppStorage.init(
      hiveDirectory: directory,
      boxes: AppStorage.startupBoxes,
    );
    await platformSetup();
    await DlssGlobalPlayback.instance.initialize();
    _cleanup.add(DlssGlobalPlayback.instance.close);
    await AnimeJaNaiService.instance.initialize();
    _cleanup.add(AnimeJaNaiService.instance.close);
    try {
      await AppFonts.restoreImportedFont();
    } catch (error, stack) {
      Log.w('Fonts', '无法加载自定义字体', error, stack);
    }
    Get.put(this, permanent: true);
    Get.put(account, permanent: true);
    Get.put(apiTransport, permanent: true);
    Get.put(AppState(), permanent: true);
    Get.put(party, permanent: true);
    Get.put(links, permanent: true);
    Get.put(mediaSession, permanent: true);
    downloads.onCompleted = (task) => showSnackBar(
      '已缓存 ${task.title}',
      action: SnackBarAction(
        label: '前往缓存中心',
        onPressed: () {
          final context = Instances.navigatorKey.currentContext;
          if (context != null) DownloadManagerPage.show(context);
        },
      ),
    );
  }

  void markReady() {
    if (_ready || _closing != null) return;
    _ready = true;
    links.markReady();
    unawaited(trackDailyUsage());
    unawaited(checkSourceUpdates());
  }

  Future<void> checkSourceUpdates() async {
    if (!_ready || _closing != null) return;
    await ruleRepository.checkForUpdates();
    if (!_ready || _closing != null || ruleRepository.updateCount == 0) return;
    final updates = ruleRepository.hubCatalog.updates;
    if (updates.length == _notifiedSourceUpdates.length &&
        updates.every(
          (rule) => _notifiedSourceUpdates[rule.item.id] == rule.item.version,
        )) {
      return;
    }
    _notifiedSourceUpdates = {
      for (final rule in updates) rule.item.id: rule.item.version,
    };
    showSnackBar(
      '${ruleRepository.updateCount} 个源有更新，可修复搜索或播放问题',
      action: SnackBarAction(
        label: '查看更新',
        onPressed: () {
          final context = Instances.navigatorKey.currentContext;
          if (context != null) NavigationService.toSourceManagement(context);
        },
      ),
    );
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _releaseResources() async {
    for (final release in _cleanup.reversed) {
      try {
        await release();
      } catch (error, stack) {
        Log.w('Lifecycle', 'Resource shutdown failed', error, stack);
      }
    }
    _cleanup.clear();
  }

  Future<void> _close() async {
    _ready = false;
    await links.close();
    for (final playback in playbacks.toList()) {
      try {
        await playback.dispose();
      } catch (error, stack) {
        Log.w('Lifecycle', 'Playback shutdown failed', error, stack);
      }
    }
    playbacks.clear();
    await _releaseResources();
    if (PlaybackSettingsService.getClearCacheOnExit()) {
      await AppStorage.clearAllCache();
    }
    await Hive.close();
    Log.i('App', 'Closed');
    await Log.flush();
  }
}

/// Observe the final image stream, including hits on disk-resized variants.
class MonitoredImageCache extends CacheManager with ImageCacheManager {
  MonitoredImageCache(super.config, this.notices);
  final NetworkNotices notices;

  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) {
    final responses = maxHeight == null && maxWidth == null
        ? getFileStream(
            url,
            key: key,
            headers: headers,
            withProgress: withProgress,
          )
        : super.getImageFile(
            url,
            key: key,
            headers: headers,
            withProgress: withProgress,
            maxHeight: maxHeight,
            maxWidth: maxWidth,
          );
    notices.reportImageStarted(url);
    var hasImage = false;
    return responses.transform(
      StreamTransformer.fromHandlers(
        handleData: (response, sink) {
          if (!hasImage && response is FileInfo) {
            hasImage = true;
            notices.reportImageResult(url, succeeded: true);
          }
          sink.add(response);
        },
        handleError: (error, stack, sink) {
          if (!hasImage &&
              (error is HttpException ||
                  NetworkNotices.isNetworkError(error))) {
            notices.reportImageResult(url, succeeded: false);
          }
          sink.addError(error, stack);
        },
      ),
    );
  }
}
