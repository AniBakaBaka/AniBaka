import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:baka/api/api_config.dart';
import 'package:baka/api/auth_api.dart';
import 'package:baka/api/bangumi_account_api.dart';
import 'package:baka/app/platform_setup.dart';
import 'package:baka/app/navigation.dart';
import 'package:baka/app/usage_tracker.dart';
import 'package:baka/app/watch_party_links.dart';
import 'package:baka/app_state.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/core/system_proxy.dart';
import 'package:baka/core/network_service.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/player/download_page.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/services/collection/bangumi_sync.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/download/download_manager.dart';
import 'package:baka/services/playback/media_session.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/services/playback/dlss_global_playback.dart';
import 'package:baka/services/playback/watch_party.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/core/app_logger.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' as cached_file;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:hive_flutter/hive_flutter.dart';

/// Composition root and owner of application-lifetime resources.
class AppRuntime {
  AppRuntime({Future<void> Function()? platformSetup, this.incomingLinks})
    : platformSetup = platformSetup ?? configurePlatform;
  final Future<void> Function() platformSetup;
  final Stream<Uri>? incomingLinks;
  final _cleanup = <FutureOr<void> Function()>[];
  bool _ready = false;
  String? _notifiedSourceUpdates;
  Future<void>? _initializing, _closing;
  Set<PlaybackController>? _playbacks;
  Set<PlaybackController> get playbacks =>
      _playbacks ??= <PlaybackController>{};
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
    SystemProxyService.initialize();
    await Instances.init();
    NetworkService.initialize(Instances.sp);
    _cleanup.add(NetworkService.close);
    PlaybackSettingsService.applyLowMemoryMode(
      PlaybackSettingsService.getLowMemoryMode(),
    );
    await AppLogger.instance.init();
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
    final privateImageCache = CacheManager(
      Config(
        'libCachedImageData',
        fileService: HttpFileService(httpClient: imageClient),
      ),
    );
    final imageCache = MonitoredImageCache(privateImageCache, networkNotices);
    CachedNetworkImageProvider.defaultCacheManager = imageCache;
    _cleanup.add(() {
      networkNotices.dispose();
      if (identical(
        CachedNetworkImageProvider.defaultCacheManager,
        imageCache,
      )) {
        CachedNetworkImageProvider.defaultCacheManager = previousImageCache;
      }
    });
    _cleanup.add(() async {
      await privateImageCache.dispose();
      imageClient.close();
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
    links = WatchPartyLinks(party, incoming: incomingLinks)..initializeLinks();
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
          if (context != null) {
            Navigator.of(context).push(
              PageRouteBuilder(
                pageBuilder: (_, _, _) => const DownloadManagerPage(),
              ),
            );
          }
        },
      ),
    );
  }

  void markReady() {
    if (_closing != null) return;
    _ready = true;
    links.markReady();
    unawaited(DauTracker.track());
    unawaited(checkSourceUpdates());
  }

  Future<void> checkSourceUpdates() async {
    if (!_ready || _closing != null) return;
    await ruleRepository.checkForUpdates();
    if (!_ready || _closing != null || ruleRepository.updateCount == 0) return;
    final versions =
        ruleRepository.hubCatalog.updates
            .map((rule) => '${rule.item.id}:${rule.item.version}')
            .toList()
          ..sort();
    final signature = versions.join(',');
    if (_notifiedSourceUpdates == signature) return;
    _notifiedSourceUpdates = signature;
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
        AppLogger.instance.warning(
          'Resource shutdown failed',
          tag: 'Lifecycle',
          error: error,
          stackTrace: stack,
        );
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
        AppLogger.instance.warning(
          'Playback shutdown failed',
          tag: 'Lifecycle',
          error: error,
          stackTrace: stack,
        );
      }
    }
    playbacks.clear();
    await _releaseResources();
    if (PlaybackSettingsService.getClearCacheOnExit()) {
      await AppStorage.clearAllCache();
    }
    await Hive.close();
  }
}

/// Observes the shared image cache, preserving its storage and resize behavior.
class MonitoredImageCache extends BaseCacheManager with ImageCacheManager {
  MonitoredImageCache(this.delegate, this.notices);

  final BaseCacheManager delegate;
  final NetworkNotices notices;

  Stream<FileResponse> _observe(
    String url,
    Stream<FileResponse> responses,
  ) async* {
    notices.reportImageStarted(url);
    var hasImage = false;
    try {
      await for (final response in responses) {
        if (response is FileInfo && !hasImage) {
          hasImage = true;
          notices.reportImageResult(url, succeeded: true);
        }
        yield response;
      }
    } catch (error) {
      // A failed refresh must not flag an image already displayed from cache.
      // Local storage errors are also unrelated to regional connectivity.
      if (!hasImage &&
          (error is HttpException || NetworkNotices.isNetworkError(error))) {
        notices.reportImageResult(url, succeeded: false);
      }
      rethrow;
    }
  }

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => _observe(
    url,
    delegate.getFileStream(
      url,
      key: key,
      headers: headers,
      withProgress: withProgress,
    ),
  );

  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) {
    final cache = delegate;
    if (cache is ImageCacheManager) {
      return _observe(
        url,
        cache.getImageFile(
          url,
          key: key,
          headers: headers,
          withProgress: withProgress,
          maxHeight: maxHeight,
          maxWidth: maxWidth,
        ),
      );
    }
    return super.getImageFile(
      url,
      key: key,
      headers: headers,
      withProgress: withProgress,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
    );
  }

  @override
  Future<cached_file.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) => delegate.getSingleFile(
    url,
    key: key ?? url,
    headers: headers ?? const {},
  );

  @override
  Stream<FileInfo> getFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) => getFileStream(
    url,
    key: key,
    headers: headers,
  ).where((r) => r is FileInfo).cast<FileInfo>();

  @override
  Future<FileInfo> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool force = false,
  }) => delegate.downloadFile(
    url,
    key: key,
    authHeaders: authHeaders,
    force: force,
  );

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) => delegate.getFileFromCache(key, ignoreMemCache: ignoreMemCache);

  @override
  Future<FileInfo?> getFileFromMemory(String key) =>
      delegate.getFileFromMemory(key);

  @override
  Future<cached_file.File> putFile(
    String url,
    Uint8List fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) => delegate.putFile(
    url,
    fileBytes,
    key: key,
    eTag: eTag,
    maxAge: maxAge,
    fileExtension: fileExtension,
  );

  @override
  Future<cached_file.File> putFileStream(
    String url,
    Stream<List<int>> source, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) => delegate.putFileStream(
    url,
    source,
    key: key,
    eTag: eTag,
    maxAge: maxAge,
    fileExtension: fileExtension,
  );

  @override
  Future<void> removeFile(String key) => delegate.removeFile(key);

  @override
  Future<void> emptyCache() => delegate.emptyCache();

  @override
  Future<void> dispose() => delegate.dispose();
}
