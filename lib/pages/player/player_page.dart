import 'package:baka/models/bgm.dart';
import 'package:baka/core/content_filter.dart';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/playback/playback_progress.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/app/app_runtime.dart';
import 'package:baka/services/playback/media_session.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'dart:async';
import 'package:baka/models/skip_segment.dart';
import 'package:baka/api/bgm.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/instance.dart';
import 'package:baka/pages/player/bgm_detail_page.dart';
import 'package:baka/pages/player/dlna_page.dart';
import 'package:baka/pages/source/ai_rule_authoring_page.dart';
import 'package:baka/pages/setting/player_settings_page.dart';
import 'package:baka/models/ai_rule_authoring.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/services/playback/playback_content.dart';
import 'package:baka/services/matching/match_memory_service.dart';
import 'package:baka/services/playback/watch_party.dart';
import 'package:baka/source/source_registry.dart';

import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/baka_player/index.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:baka/widgets/common/tab_indicator.dart';
import 'package:baka/widgets/common/scale_button.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/widgets/episode/episode_list_dialog.dart';
import 'package:baka/widgets/episode/episode_widgets.dart';
import 'package:baka/widgets/anime_detail/anime_detail_placeholder.dart';
import 'package:baka/widgets/platform/tv/tv_anime_detail.dart';
import 'package:baka/widgets/platform/tv/tv_player_layout.dart';
import 'package:baka/widgets/platform/windows/windows_player_layout.dart';
import 'package:baka/widgets/player/download_indicators.dart';
import 'package:baka/widgets/anime_detail/video_source_search_sheet.dart';
import 'package:baka/widgets/player/video_detail_card.dart';
import 'package:baka/widgets/player/player_tab.dart';
import 'package:baka/widgets/watch_party/watch_party_sheet.dart';
import 'package:baka/widgets/anime_detail/controller/video_source_search_controller.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    required this.request,
    super.key,
    this.posIndex,
    this.autoMatch = false,
  });

  final PlaybackRequest request;
  final int? posIndex;
  final bool autoMatch;

  @override
  State<StatefulWidget> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _immersiveStatusBarStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.black,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
  );

  static const _lightStatusBarStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemStatusBarContrastEnforced: false,
  );

  static const _darkStatusBarStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
  );

  late final PlaybackContent _svc;
  late final WatchPartyService _watchParty;
  late final MediaSessionService _mediaSession;
  late final TabController _tabController;
  StreamSubscription<void>? _completedSubscription;
  StreamSubscription<Duration>? _seekSubscription;
  PlaybackProgress? _progress;
  bool _wasPlaying = false;
  Future<void>? _playerReady;
  Future<void> _hlsFilterReload = Future<void>.value();
  List<String> _cachedTags = const [];
  String _resolvedUrl = '';
  final GlobalKey<CIslandCommentWidgetState> commentKey = GlobalKey();
  final PlaybackController ctr = PlaybackController();
  final DanmakuController danmakuController = DanmakuController();
  final ValueNotifier<bool> _followNotifier = ValueNotifier<bool>(false);
  bool inited = false;
  final ValueNotifier<bool> _showDetailNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _sortAscendingNotifier = ValueNotifier<bool>(true);
  final ValueNotifier<bool> _playerFullscreen = ValueNotifier<bool>(false);
  PlayerFailureContext? _terminalFailure;
  int _playbackGeneration = 0;
  bool _lastPlaybackOpenSucceeded = false;
  Object? _lastPlaybackFailure;

  SystemUiOverlayStyle _exitStatusBarStyle = _lightStatusBarStyle;

  void _bumpPageData() {
    if (!mounted) return;
    setState(() {});
  }

  List<PlaybackEpisode> get videoList => _svc.videoList;
  int get currPlayIndex => _svc.currPlayIndex;
  int get currUrl => _svc.currUrl;
  bool get isWindows => Instances.isDesktopPlatform;
  bool get _isAdapter => _svc.isAdapter;
  bool get _isLocalSource => _svc.isLocalSource;
  BgmInfo get _bgmInfo => _svc.bgmInfo;
  String get _currentEpisodeTitle => _svc.currentEpisodeTitle;
  List<String>? get _sourceNames => _svc.sourceNames;

  SourceOperation? _sourceOperation;
  String? _refreshedMediaKey;

  bool _isStale(int requestId) => !mounted || requestId != _playbackGeneration;

  bool get _isNsfw =>
      ContentFilter.isNsfw(_svc.data) || _svc.bgmDetailData?['nsfw'] == true;
  bool get _isContentHidden => contentFilter.value && _isNsfw;

  void _onContentFilterChanged() {
    if (_isContentHidden) {
      ++_playbackGeneration;
      _sourceOperation?.cancel();
      _autoMatchController?.cancelSearch();
      unawaited(ctr.pause());
    } else if (_isNsfw && !inited) {
      unawaited(_loadInitialData());
    }
    _bumpPageData();
  }

  /// 下载任务 id 由「源 + 剧集 id + 集数」拼成，必须在接管新数据后跟着变，
  /// 否则下载进度条会匹配不到本地任务。
  String get _taskIdPrefix {
    final source = _svc.request.source;
    final id = _svc.data['id'];
    return source.isNotEmpty ? '${source}_${id}_' : '${id}_';
  }

  /// 外部简介：贴文的 `content` 里 `>` 之前是站点信息，之后才是简介。
  String get _fixedSummary {
    final raw = _svc.data['content'] as String?;
    if (raw == null) return '';
    final cut = raw.indexOf('>');
    return cut != -1 ? raw.substring(cut + 1).trim() : raw;
  }

  VideoSourceSearchController? _autoMatchController;
  VideoSourceSearchController? _sourceSearchController;

  Future<void> _savePlayback({bool seeked = false}) async {
    // OP/ED calibration may pause, seek to the ending, or enter the background.
    // Those preview positions must not replace watch progress or mark it watched.
    if (ctr.skipSelection.value != null) return;
    try {
      await _progress?.save(
        ctr.timeline.value,
        rememberPosition: ctr.preferences.value.rememberLastPosition,
        seeked: seeked,
      );
    } catch (error) {
      debugPrint('保存播放进度失败: $error');
    }
  }

  Future<void> _saveAndResetForSwitch() async {
    final saving = _savePlayback();
    _progress = null;
    await saving;
    danmakuController.reset();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _svc = PlaybackContent(
      sources: sourceRepository,
      collections: collections,
      history: historyRepository,
      request: widget.request,
      posIndex: widget.posIndex,
    );
    contentFilter.addListener(_onContentFilterChanged);
    _sourceSearchController = VideoSourceSearchController.takeCachedFor(
      seedData: _svc.data,
    );
    _watchParty = Get.find<WatchPartyService>();
    _mediaSession = Get.find<MediaSessionService>();
    Get.find<AppRuntime>().playbacks.add(ctr);
    _tabController = TabController(length: 2, vsync: this);
    _updateCachedTagsFromBgm();
    ctr.setMediaInfo(_svc.initialMediaInfo);
    _followNotifier.value = _svc.isFollow();
    ctr.core.addListener(_onPlaybackCoreChanged);
    ctr.onHlsAdFilterChanged = _reloadHlsFilter;

    final shouldAutoMatch =
        !_isLocalSource && (widget.autoMatch || _svc.needsSourceMatch);
    if (shouldAutoMatch) {
      _startHeadlessAutoMatch();
    } else {
      _loadInitialData();
    }
  }

  void _startHeadlessAutoMatch() {
    if (_isContentHidden) return;
    if (!mounted || _autoMatchController != null) return;
    _terminalFailure = null;
    late final VideoSourceSearchController search;
    search = VideoSourceSearchController(
      seedData: _svc.buildDetailData(),
      autoMatchMode: true,
      targetEpisodeIndex: currPlayIndex,
      onMatchFound: (resolvedData) {
        if (!mounted || !identical(_autoMatchController, search)) return;
        final elapsed = _autoMatchController?.lastAutoMatchDuration;
        if (elapsed != null) {
          debugPrint(
            '[Player] auto-match ready in ${elapsed.inMilliseconds}ms',
          );
        }
        final controller = _autoMatchController;
        _autoMatchController = null;
        controller?.cancelSearch();
        controller?.dispose();
        unawaited(_adoptPlaybackSource(resolvedData));
      },
      onMatchFailed: () {
        if (!mounted || !identical(_autoMatchController, search)) return;
        final controller = _autoMatchController;
        _autoMatchController = null;
        controller?.dispose();
        // Try an existing local route once, then expose failure. An unresolved
        // cloud record must not restart matching or leave an empty player.
        unawaited(_loadInitialData(allowSourceMatch: false));
      },
    );
    _autoMatchController = search;
    _bumpPageData();
    unawaited(
      search.startSearch().catchError((Object error) {
        if (!mounted || !identical(_autoMatchController, search)) return;
        _autoMatchController = null;
        search.dispose();
        _setTerminalPlaybackFailure(error);
      }),
    );
    unawaited(_loadBgmMetaOnly());
  }

  /// 自动匹配期间只拉 BGM 展示信息，不解析播放地址。
  Future<void> _loadBgmMetaOnly() async {
    if (_isLocalSource || !mounted) return;
    try {
      await _svc.ensureBgmInfo();
      if (!mounted) return;
      await _svc.ensureBgmDetail();
      if (!mounted) return;
      if (_isContentHidden) {
        _onContentFilterChanged();
        return;
      }
      _updateCachedTagsFromBgm();
      ctr.setMediaInfo(_svc.currentMediaInfo);
      _bumpPageData();
      _watchParty.publishCurrentMedia();
    } catch (e) {
      debugPrint('加载 BGM 元数据失败: $e');
    }
  }

  void _playNextEpisode() {
    if (mounted && currPlayIndex + 1 < videoList.length) {
      _switchEpisode(currPlayIndex + 1);
    }
  }

  void _playPreviousEpisode() {
    if (mounted && currPlayIndex > 0) _switchEpisode(currPlayIndex - 1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _exitStatusBarStyle = Theme.of(context).brightness == Brightness.dark
        ? _darkStatusBarStyle
        : _lightStatusBarStyle;
  }

  Future<void> _loadInitialData({bool allowSourceMatch = true}) async {
    if (_isContentHidden) return;
    final requestId = _playbackGeneration;
    unawaited(_loadBgmMetaOnly());
    try {
      final ready = await _svc.prepareInitialPlayback();
      if (_isStale(requestId)) return;
      if (ready) {
        await initVideoController(requestId);
      } else if (allowSourceMatch && !_isLocalSource) {
        _startHeadlessAutoMatch();
      } else {
        _setTerminalPlaybackFailure('未找到可播放的线路，请选择播放源后重试');
      }
    } catch (e) {
      if (_isStale(requestId)) return;
      debugPrint('加载初始数据失败: $e');
      if (allowSourceMatch && !_isLocalSource) {
        _startHeadlessAutoMatch();
      } else {
        _setTerminalPlaybackFailure(e);
      }
    }
    if (mounted) {
      ctr.setMediaInfo(_svc.currentMediaInfo);
      _bumpPageData();
    }
  }

  void _updateCachedTagsFromBgm() {
    final bgmDetail = _svc.bgmDetailData;
    if (bgmDetail != null) {
      final tags = bgmDetail['tags'] as List;
      if (tags.isNotEmpty) {
        _cachedTags = [
          for (final tag in tags.take(6)) (tag as Map)['name'] as String,
        ];
        return;
      }
    }

    final sourceDisplayName = _svc.data['sourceDisplayName']?.toString();
    final sourceVal = _svc.request.source;
    final sourceName = _currentSourceName;
    _cachedTags = (_svc.data['tag']?.toString().split(' ') ?? const <String>[])
        .map((t) => t.trim())
        .where(
          (t) =>
              t.isNotEmpty &&
              t != sourceDisplayName &&
              t != sourceVal &&
              t != sourceName,
        )
        .take(5)
        .toList();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_savePlayback());
  }

  @override
  void dispose() {
    contentFilter.removeListener(_onContentFilterChanged);
    WidgetsBinding.instance.removeObserver(this);
    _sourceOperation?.cancel();
    _sourceOperation?.close();
    ctr.onHlsAdFilterChanged = null;
    ctr.core.removeListener(_onPlaybackCoreChanged);
    _completedSubscription?.cancel();
    _seekSubscription?.cancel();
    _autoMatchController?.cancelSearch();
    _autoMatchController?.dispose();
    _sourceSearchController?.dispose();
    Get.find<AppRuntime>().playbacks.remove(ctr);
    _mediaSession.detach(ctr);
    _watchParty.detachPlayer(ctr);
    ctr.detachDanmaku();
    unawaited(_savePlayback());
    _progress = null;
    unawaited(ctr.dispose());
    unawaited(_svc.dispose());
    _tabController.dispose();
    _followNotifier.dispose();
    _showDetailNotifier.dispose();
    _sortAscendingNotifier.dispose();
    _playerFullscreen.dispose();
    SystemChrome.setSystemUIOverlayStyle(_exitStatusBarStyle);
    super.dispose();
  }

  void showCast(BuildContext context) {
    final castUrl = _resolvedUrl.isNotEmpty
        ? _resolvedUrl
        : (_isAdapter ? ctr.currentMediaUri ?? '' : '');
    if (castUrl.isEmpty) {
      showSnackBar('无法获取视频地址，无法投屏');
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (ctx) => DlnaCastPanel(
        datasource: castUrl,
        animeTitle: _svc.data['title']?.toString() ?? '',
        videoList: videoList,
        currentEpisodeIndex: currPlayIndex,
        urlResolver: (idx) => _svc.resolveEpisodeUrl(idx),
        onEpisodeChanged: (idx) {
          if (mounted) _switchEpisode(idx);
        },
      ),
    );
  }

  /// 播放订阅由页面持有，重试地址时复用同一次初始化。
  Future<void> _initializePlayer() async {
    ctr.attachDanmaku(danmakuController);
    DanmakuController.loadSettings(danmakuController);
    await Future.wait([ctr.initialize(), _mediaSession.init()]);
    if (!mounted) return;
    _completedSubscription = ctr.completed.listen((_) => _playNextEpisode());
    _seekSubscription = ctr.seekEvents.listen(
      (_) => unawaited(_savePlayback(seeked: true)),
    );
    _mediaSession.attach(
      ctr,
      onNextEpisode: _playNextEpisode,
      onPreviousEpisode: _playPreviousEpisode,
    );
    _watchParty.attachPlayer(ctr, _svc, onEpisodeRequested: _switchEpisode);
  }

  Future<void> _reloadHlsFilter(bool enabled) {
    // 连续切换开关时串行重新生成代理清单，避免相互关闭对方的代理。
    final requestId = _playbackGeneration;
    return _hlsFilterReload = _hlsFilterReload
        .then((_) async {
          if (_isStale(requestId) ||
              !_isAdapter ||
              _isLocalSource ||
              ctr.currentMediaUri == null ||
              ctr.preferences.value.filterHlsAds != enabled) {
            return;
          }
          final position = ctr.timeline.value.position;
          final playing = ctr.core.value.playing;
          final rate = ctr.core.value.playbackRate;
          // 先停止旧清单请求，再替换本地代理，避免旧连接断开触发自动换线。
          final saving = _savePlayback();
          _progress = null;
          await saving;
          if (_isStale(requestId)) return;
          await ctr.stop();
          if (_isStale(requestId)) return;
          await initVideoController(
            requestId,
            resumeAt: position,
            autoplay: playing,
            filterHlsAds: enabled,
          );
          if (!_isStale(requestId) && _lastPlaybackOpenSucceeded) {
            await ctr.setRate(rate);
          }
        })
        .catchError((Object error) {
          if (!_isStale(requestId)) {
            showSnackBar('重新应用去广告失败，请重新打开当前集', isError: true);
          }
        });
  }

  Future<void> initVideoController(
    int requestId, {
    Duration? resumeAt,
    bool autoplay = true,
    bool? filterHlsAds,
  }) async {
    if (_isContentHidden) return;
    if (_isStale(requestId)) return;
    if (!identical(SourceOperation.current, _sourceOperation)) {
      _sourceOperation?.cancel();
      _sourceOperation?.close();
    }
    final operation = SourceOperation();
    _sourceOperation = operation;
    return operation
        .run(
          () => _initVideoController(
            requestId,
            resumeAt: resumeAt,
            autoplay: autoplay,
            filterHlsAds: filterHlsAds,
          ),
        )
        .catchError((Object error) {
          if (!operation.isCancelled) throw error;
        });
  }

  Future<void> _bindSkipEpisode(
    int requestId,
    SkipContext context,
    String title,
  ) async {
    try {
      final subjectId = context.subjectId;
      if (subjectId == null ||
          context.bound ||
          _isStale(requestId) ||
          !identical(context, ctr.skipContext)) {
        return;
      }
      final episodes = await getBgmEpisodes(subjectId);
      if (_isStale(requestId) || !identical(context, ctr.skipContext)) return;
      final episodeId = matchSkipEpisode(title, episodes);
      if (episodeId != null) {
        ctr.setSkipContext(context.bind(subjectId, episodeId));
      }
    } catch (_) {
      /* Local annotations remain available without metadata. */
    }
  }

  Future<void> _initVideoController(
    int requestId, {
    Duration? resumeAt,
    bool autoplay = true,
    bool? filterHlsAds,
  }) async {
    if (_isStale(requestId)) return;
    final saving = _savePlayback();
    _progress = null;
    await saving;
    if (_isStale(requestId)) return;
    if (_terminalFailure != null) {
      _terminalFailure = null;
      _bumpPageData();
    }
    _lastPlaybackOpenSucceeded = false;
    _lastPlaybackFailure = null;
    _resolvedUrl = '';
    ctr.setSkipContext(null);
    var skipTimeline = 'original';
    int? keepAliveGeneration;
    try {
      final localPath = _isLocalSource ? _svc.localFilePath : null;
      if (_isLocalSource && localPath == null) return;
      final adapter = _isAdapter ? await _svc.prepareAdapterSource() : null;
      if (_isStale(requestId)) return;

      ctr.setMediaInfo(_svc.currentMediaInfo);
      await (_playerReady ??= _initializePlayer());
      if (_isStale(requestId)) return;

      var videoUrl = localPath;
      var headers = localPath == null ? null : _svc.localHttpHeaders;
      if (adapter != null) {
        final episodeId = _svc.currentEpisodeId;
        _svc.stopAdapterPlaybackKeepAlive();
        final media = await _svc.resolveAdapterPlaybackMedia(
          adapter,
          episodeId,
        );
        if (media.url.isEmpty) {
          _svc.clearPrefetchedPlaybackMedia();
          throw Exception('Unable to resolve media url');
        }
        if (_isStale(requestId)) return;

        keepAliveGeneration = await _svc.startAdapterPlaybackKeepAlive(
          adapter,
          media.url,
        );
        if (_isStale(requestId)) {
          _svc.stopAdapterPlaybackKeepAlive(keepAliveGeneration);
          return;
        }
        final playbackMedia = await adapter.preparePlaybackMedia(
          media,
          filterHlsAds: filterHlsAds,
          onTimelinePrepared: (key) => skipTimeline = key,
          onHlsAdFilterStatus: (message) {
            if (!_isStale(requestId)) showSnackBar(message);
          },
        );
        if (_isStale(requestId)) {
          _svc.stopAdapterPlaybackKeepAlive(keepAliveGeneration);
          return;
        }
        _resolvedUrl = media.url;
        videoUrl = playbackMedia.url;
        headers = playbackMedia.httpHeaders;
      } else if (localPath == null) {
        videoUrl = await _svc.resolveEpisodeUrl(currPlayIndex);
        if (_isStale(requestId)) return;
        if (videoUrl == null || videoUrl.isEmpty) {
          throw Exception('无法获取视频播放地址');
        }
        _resolvedUrl = videoUrl;
      }
      final start =
          resumeAt ??
          (ctr.preferences.value.rememberLastPosition
              ? historyRepository.getResumePosition(
                  videoKey: _svc.videoKey,
                  request: _svc.request,
                  bgmId: _svc.bgmInfo.subjectId,
                )
              : Duration.zero);
      final progress = PlaybackProgress(
        history: historyRepository,
        request: _svc.request.copyWith(metadataUpdates: {'nsfw': _isNsfw}),
        videoKey: _svc.videoKey,
        start: start,
        bgmId: _svc.bgmInfo.subjectId,
        cover: _svc.coverImageUrl,
      );
      await ctr.open(
        videoUrl!,
        autoplay: autoplay,
        httpHeaders: headers,
        start: start > Duration.zero ? start : null,
      );

      if (_isStale(requestId)) return;
      _progress = progress;
      _lastPlaybackOpenSucceeded = true;
      final skipSource = SkipContext.sourceIdentity([
        _svc.request.source,
        _svc.request.contentId,
        _svc.currentVideoItem?.lineAt(currUrl),
        _sourceNames != null && currUrl <= _sourceNames!.length
            ? _sourceNames![currUrl - 1]
            : currUrl,
      ]);
      final skipContext = SkipContext(
        sourceKey: skipSource,
        timelineKey: skipTimeline,
        episodeNumber:
            skipEpisodeNumber(_currentEpisodeTitle) ??
            (currPlayIndex + 1).toDouble(),
        seriesKey: SkipContext.sourceIdentity([
          _svc.request.source,
          _svc.request.contentId,
          _sourceNames != null && currUrl <= _sourceNames!.length
              ? _sourceNames![currUrl - 1]
              : currUrl,
        ]),
        // Display metadata may come from fuzzy title search; only an explicit
        // playback identity (or a saved personal binding) can drive a seek.
        subjectId: BgmInfo.fromData(_svc.data).subjectId,
      );
      ctr.setSkipContext(skipContext);
      unawaited(
        _bindSkipEpisode(requestId, ctr.skipContext!, _currentEpisodeTitle),
      );
      _lastPlaybackFailure = null;
      if (!_svc.isLocalSource && videoList.isNotEmpty) {
        await historyRepository.rememberEpisode(
          request: _svc.request,
          bgmId: _svc.bgmInfo.subjectId,
          episodeIndex: currPlayIndex,
          urlIndex: currUrl,
        );
      }
      if (_isStale(requestId)) return;
      if (!inited || _terminalFailure != null) {
        inited = true;
        _terminalFailure = null;
        _bumpPageData();
      }
      if (resumeAt == null) {
        final episodeIndex = currPlayIndex;
        final danmaku = await _svc.fetchDanmakuData(episodeIndex);
        if (!_isStale(requestId) &&
            episodeIndex == currPlayIndex &&
            !identical(danmakuController.items, danmaku)) {
          danmakuController.setItems(danmaku);
        }
      }
    } catch (e) {
      if (_isStale(requestId) || SourceOperation.current?.isCancelled == true) {
        return;
      }
      debugPrint('初始化视频控制器失败: $e');
      _lastPlaybackFailure = e;
      if (_lastPlaybackOpenSucceeded) return;
      _svc.clearPrefetchedPlaybackMedia();
      if (keepAliveGeneration != null) {
        _svc.stopAdapterPlaybackKeepAlive(keepAliveGeneration);
      }
      await _handlePlaybackInitializationFailure(e);
    }
  }

  final Set<String> _failedSourceKeys = {};
  bool _isAutoSwitchingSource = false;

  void _onPlaybackCoreChanged() {
    final playing = ctr.core.value.playing;
    if (_wasPlaying && !playing) unawaited(_savePlayback());
    _wasPlaying = playing;
    if (!mounted || _isAutoSwitchingSource) return;
    if (ctr.core.value.failed) {
      final msg = ctr.core.value.errorMessage;
      _handlePlaybackInitializationFailure(msg.isNotEmpty ? msg : '视频播放异常');
    }
  }

  Future<void> _handlePlaybackInitializationFailure(Object error) async {
    if (!mounted || _isAutoSwitchingSource) return;
    if (_isLocalSource) {
      _setTerminalPlaybackFailure(error);
      return;
    }
    _isAutoSwitchingSource = true;

    try {
      final refreshKey = '${_svc.request.source}|${_svc.currentEpisodeId}';
      if (_isAdapter &&
          _resolvedUrl.isNotEmpty &&
          _refreshedMediaKey != refreshKey) {
        _refreshedMediaKey = refreshKey;
        final adapter = await _svc.prepareAdapterSource();
        adapter.invalidateDownloadUrl(_svc.currentEpisodeId);
        _svc.clearPrefetchedPlaybackMedia();
        await initVideoController(_playbackGeneration);
        if (_lastPlaybackOpenSucceeded && !ctr.core.value.failed) return;
      }
      _rememberFailedCurrentSource();

      // 清除历史无效匹配记忆 + 失效预取，避免再次命中死链
      _svc.clearPrefetchedPlaybackMedia();
      final bgmId = _svc.bgmInfo.subjectId;
      final title = _svc.data['title']?.toString() ?? '';
      if (title.isNotEmpty) {
        await MatchMemoryService.remove(bgmId: bgmId, title: title);
      }

      // 1. 尝试当前剧集的下一条线路（重新解析并校验，不复用死预取）
      var currentEp = _svc.currentVideoItem;
      while (currentEp != null && currUrl < currentEp.lineCount) {
        final nextLine = currentEp.availableLineIndexes
            .where((line) => line > currUrl)
            .firstOrNull;
        if (nextLine == null) break;
        showSnackBar('当前线路播放异常，正在自动为您切换线路 $nextLine...');
        await changeUrl(nextLine);
        if (_lastPlaybackOpenSucceeded && !ctr.core.value.failed) return;
        _svc.clearPrefetchedPlaybackMedia();
        _svc.stopAdapterPlaybackKeepAlive();
        currentEp = _svc.currentVideoItem;
      }

      // 2. 全自动自动匹配并无缝切换至下一个有效视频源
      final seedData = _svc.buildDetailData();
      final controller = _sourceSearchController ??=
          VideoSourceSearchController.takeSharedFor(seedData: seedData);

      if (controller.results.isEmpty && !controller.isSearching) {
        unawaited(controller.startSearch());
      }

      while (mounted) {
        final nextCandidateData = await controller.findNextPlayableCandidate(
          excludedKeys: _failedSourceKeys,
          episodeIndex: currPlayIndex,
        );
        if (!mounted) return;
        if (nextCandidateData == null) break;
        final nextSource =
            nextCandidateData.metadata['sourceDisplayName'] ??
            nextCandidateData.source;
        showSnackBar('当前视频源播放失败，已自动为您切换至：$nextSource');
        _svc.adoptPlaybackRequest(nextCandidateData);
        _bumpPageData();
        await initVideoController(++_playbackGeneration);
        if (_lastPlaybackOpenSucceeded && !ctr.core.value.failed) return;
        _rememberFailedCurrentSource();
        _svc.clearPrefetchedPlaybackMedia();
        _svc.stopAdapterPlaybackKeepAlive();
      }
      showSnackBar('所有可用匹配源均播放失败，请点击源名称手动搜索选择', isError: true);
      _setTerminalPlaybackFailure(_lastPlaybackFailure ?? error);
    } catch (e) {
      debugPrint('[PlayerPage] Auto fallback error: $e');
      _setTerminalPlaybackFailure(e);
    } finally {
      _isAutoSwitchingSource = false;
    }
  }

  void _rememberFailedCurrentSource() {
    final sourceKey = _svc.request.source;
    if (sourceKey.isEmpty) return;
    _failedSourceKeys.add(sourceKey);
    final seriesId =
        _svc.data['seriesId'] ?? _svc.data['id'] ?? _svc.data['url'];
    if (seriesId != null) _failedSourceKeys.add('$sourceKey|$seriesId');
  }

  void _setTerminalPlaybackFailure(Object error) {
    if (!mounted) return;
    _terminalFailure = PlayerFailureContext(
      message: error.toString(),
      title: _svc.data['title']?.toString() ?? '',
      sourceKey: _svc.request.source,
      seriesId: (_svc.data['seriesId'] ?? _svc.data['seriesUrl'])?.toString(),
      episodeId: _svc.currentEpisodeId,
    );
    _bumpPageData();
  }

  Future<void> _openAiRuleRepair() async {
    final failure = _terminalFailure;
    if (failure == null || Instances.isTV) return;
    await sourceRepository.init();
    final sourceKey = failure.sourceKey;
    final catalog = sourceCatalog;
    final currentConfig = AdapterRegistry.isCustomSource(sourceKey)
        ? catalog.customSourceById(
            sourceKey.substring(AdapterRegistry.customSourcePrefix.length),
          )
        : (AdapterRegistry.isBuiltinSource(sourceKey)
              ? catalog.builtinSourceById(sourceKey)
              : null);
    if (!mounted) return;
    final repairing = currentConfig != null;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AiRuleAuthoringPage(
          seed: RuleAuthoringSeed(
            mode: repairing
                ? RuleAuthoringMode.repair
                : RuleAuthoringMode.create,
            siteUrl: currentConfig?.baseUrl ?? '',
            keyword: failure.title,
            sourceKey: repairing ? sourceKey : null,
            currentConfig: currentConfig,
            seriesId: failure.seriesId,
            episodeId: failure.episodeId,
            failureMessage: failure.message,
          ),
        ),
      ),
    );
    if (!mounted || saved != true) return;
    _terminalFailure = null;
    _bumpPageData();
    _failedSourceKeys.clear();
    if (repairing) {
      await initVideoController(++_playbackGeneration);
    } else {
      await _openSourceSwitchSheet();
    }
  }

  Future<void> _switchEpisode(int episodeIndex, {int? lineIndex}) async {
    final selection = _svc.normalizeSelection(
      episodeIndex,
      lineIndex ?? currUrl,
    );
    if (selection.episodeIndex == currPlayIndex &&
        selection.lineIndex == currUrl) {
      return;
    }
    _sourceOperation?.cancel();
    final currentRequestId = ++_playbackGeneration;
    await _saveAndResetForSwitch();
    if (_isStale(currentRequestId)) return;
    // 期间状态只可能被并发切换改变，而并发切换已被上面的 stale 检查拦截
    _svc.applySelection(selection);
    // currPlayIndex/currUrl 变化 → 仅触发依赖剧集数据的子树刷新
    _bumpPageData();
    await ctr.stop();
    _svc.stopAdapterPlaybackKeepAlive();
    await initVideoController(currentRequestId);
    if (_isStale(currentRequestId)) return;
    _watchParty.publishCurrentMedia();
    // 播放器与弹幕在 initVideoController 内完成局部更新，无需重建整页。
  }

  Future<void> changeUrl(int urlIndex) =>
      _switchEpisode(currPlayIndex, lineIndex: urlIndex);

  Future<void> _adoptPlaybackSource(
    PlaybackRequest sourceData, {
    bool resetPlayback = false,
  }) async {
    if (!mounted) return;
    // A manual choice wins over a still-running history match.
    final matching = _autoMatchController;
    _autoMatchController = null;
    matching?.cancelSearch();
    matching?.dispose();
    _sourceOperation?.cancel();
    final requestId = ++_playbackGeneration;
    if (resetPlayback) {
      await _saveAndResetForSwitch();
      if (_isStale(requestId)) return;
    }
    _svc.adoptPlaybackRequest(sourceData);
    _bumpPageData();
    await ctr.stop();
    _svc.stopAdapterPlaybackKeepAlive();
    await initVideoController(requestId);
    if (_isStale(requestId)) return;
    _watchParty.publishCurrentMedia();
  }

  @override
  Widget build(BuildContext context) {
    if (_isContentHidden) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('已隐藏 NSFW 内容')),
      );
    }
    if (_isLocalSource) return _buildLocalLayout(context);
    final source = _svc.request.source.trim();
    final isPureBgmSubject = source.isEmpty || source == 'bgm';

    if (isPureBgmSubject &&
        _autoMatchController == null &&
        _terminalFailure == null) {
      return Instances.isTV
          ? TvAnimeDetailPlaceholder(
              data: _svc.buildDetailData(),
              episodes: videoList,
            )
          : AnimeDetailPlaceholder(data: _svc.buildDetailData());
    }
    if (Instances.isTV) return _buildTvLayout(context);
    if (isWindows || context.isTablet) {
      return _buildWindowsTabletLayout(context);
    }
    return _buildMobileLayout(context);
  }

  Widget _buildTvLayout(BuildContext context) {
    return TvPlayerLayout(
      content: _svc,
      inited: inited,
      controller: ctr,
      danmakuController: danmakuController,
      onEpisodeChanged: _switchEpisode,
      onUrlChanged: changeUrl,
      onWatchPartyPressed: () => WatchPartySheet.show(context, _watchParty),
      isSearching: _autoMatchController != null,
      initialFailure: _terminalFailure == null
          ? null
          : _buildMobileTerminalFailure(),
    );
  }

  Widget _buildWindowsTabletLayout(BuildContext context) {
    return _withImmersiveStatusBar(
      WindowsPlayerLayout(
        content: _svc,
        inited: inited,
        controller: ctr,
        danmakuController: danmakuController,
        followNotifier: _followNotifier,
        sourceName: _currentSourceName,
        lineName: _currentLineName,
        isSearching: _autoMatchController != null,
        onSourceTap: _openSourceSwitchSheet,
        commentKey: commentKey,
        onEpisodeChanged: _switchEpisode,
        onCastPressed: () => showCast(context),
        onWatchPartyPressed: () => WatchPartySheet.show(context, _watchParty),
        onPickEpisode: () => _showEpisodePicker(),
        onFullScreenChanged: (value) {
          _playerFullscreen.value = value;
        },
        onUrlChanged: changeUrl,
        onCommentLinkTap: (text, url, title) => handleCommentLinkTap(
          text: text,
          url: url,
          title: title,
          controller: ctr,
          currentPlayIndex: currPlayIndex,
          videoList: videoList,
          onChangePlayIndex: _switchEpisode,
        ),
        onDownloadPressed: () => _showEpisodePicker(downloadMode: true),
        onFollowPressed: toggleFollow,
        terminalPlaybackFailure: _terminalFailure != null,
        onAiRepair: _openAiRuleRepair,
      ),
    );
  }

  String get _currentSourceName {
    if (_autoMatchController != null && videoList.isEmpty) return '正在匹配播放源';
    if (_svc.needsSourceMatch) return '选择播放源';
    final displayName = _svc.data['sourceDisplayName']?.toString().trim();
    if (displayName != null && displayName.isNotEmpty) return displayName;
    final source = _svc.request.source.trim();
    if (source.isNotEmpty) return source;
    return '播放源';
  }

  String? get _currentLineName {
    final names = _sourceNames;
    final index = currUrl - 1;
    if (names == null || index < 0 || index >= names.length) return null;
    final lineName = names[index].trim();
    return lineName.isEmpty ? null : lineName;
  }

  Future<void> _openSourceSwitchSheet() async {
    if (_isLocalSource) return;

    final seedData = _svc.buildDetailData();

    final searchController = _sourceSearchController ??=
        VideoSourceSearchController.takeSharedFor(seedData: seedData);

    final selection = await VideoSourceSearchSheet.show(
      context,
      seedData: seedData,
      currentEpisodeIndex: currPlayIndex,
      currentLineIndex: currUrl,
      currentSource: _svc.request.source,
      searchController: searchController,
    );
    if (!mounted || selection == null) return;

    final nextData = selection.copyWith(
      episodeIndex: currPlayIndex,
      lineIndex: selection.lineIndex ?? currUrl,
    );

    final isSameSource =
        _svc.request.source == nextData.source &&
        _svc.data['seriesUrl'] == nextData.metadata['seriesUrl'];
    final selectedLine = nextData.lineIndex ?? currUrl;
    if (isSameSource && currUrl == selectedLine) return;
    await _adoptPlaybackSource(nextData, resetPlayback: true);
  }

  Widget _withImmersiveStatusBar(Widget child) {
    if (Instances.isDesktopPlatform || Instances.isTV) return child;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _immersiveStatusBarStyle,
      child: child,
    );
  }

  Widget _buildLocalLayout(BuildContext context) {
    return _withImmersiveStatusBar(
      Scaffold(
        backgroundColor: Colors.black,
        body: inited
            ? BakaPlayer(
                controller: ctr,
                full: true,
                hasNextEpisode: currPlayIndex + 1 < videoList.length,
                onNextEpisode: _playNextEpisode,
                headerControl: Padding(
                  padding: const EdgeInsets.only(right: 16.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (videoList.length > 1) ...[
                        _buildGlassIconButton(
                          icon: Icons.video_library_rounded,
                          onPressed: () => _showEpisodePicker(),
                        ),
                        const SizedBox(width: 8),
                      ],
                      _buildGlassIconButton(
                        icon: Icons.cast_connected_rounded,
                        onPressed: () => showCast(context),
                      ),
                      const SizedBox(width: 8),
                      _buildGlassIconButton(
                        icon: Icons.more_horiz_rounded,
                        onPressed: () => PlayerSettingsPage.show(context, ctr),
                      ),
                    ],
                  ),
                ),
                danmakuEnabled: true,
              )
            : Center(
                child: _terminalFailure == null
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        '视频打开失败',
                        style: TextStyle(color: Colors.white),
                      ),
              ),
      ),
    );
  }

  Widget _buildMobileLayout(BuildContext context) {
    final theme = Theme.of(context);
    // 外层 ValueListenableBuilder 仅在 _showDetailNotifier 变化时重建 PopScope，
    // Scaffold 子树以 child 形式被缓存，避免重复构建。
    return _withImmersiveStatusBar(
      ValueListenableBuilder<bool>(
        valueListenable: _showDetailNotifier,
        builder: (context, showDetail, child) {
          return PopScope(
            canPop: !showDetail,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _showDetailNotifier.value = false;
            },
            child: child!,
          );
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            top: true,
            bottom: false,
            child: Column(
              children: [
                Container(
                  color: Colors.black,
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: _terminalFailure != null && !inited
                        ? _buildMobileTerminalFailure()
                        : inited
                        ? BakaPlayer(
                            controller: ctr,
                            canSearchSource: true,
                            danmakuEnabled: true,
                            headerControl: _buildImmersiveHeader(context),
                            onPickEpisode: () => _showEpisodePicker(),
                            hasNextEpisode:
                                currPlayIndex + 1 < videoList.length,
                            onNextEpisode: _playNextEpisode,
                            onFullScreenChanged: (value) {
                              _playerFullscreen.value = value;
                            },
                            full: false,
                            showPlaybackError: _terminalFailure != null,
                            onAiRepair: _openAiRuleRepair,
                          )
                        : Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white70,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _autoMatchController != null
                                      ? '正在自动匹配源中...'
                                      : '正在加载播放器...',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
                Expanded(
                  child: Container(
                    color: theme.scaffoldBackgroundColor,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _showDetailNotifier,
                      builder: (context, showDetail, _) {
                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          transitionBuilder: (child, animation) {
                            final isDetail =
                                child.key == const ValueKey('BgmDetail');
                            return SlideTransition(
                              position: Tween<Offset>(
                                begin: isDetail
                                    ? const Offset(0.05, 0)
                                    : const Offset(-0.05, 0),
                                end: Offset.zero,
                              ).animate(animation),
                              child: FadeTransition(
                                opacity: animation,
                                child: child,
                              ),
                            );
                          },
                          child: showDetail
                              ? GestureDetector(
                                  onHorizontalDragEnd: (details) {
                                    if ((details.primaryVelocity ?? 0) > 300) {
                                      _showDetailNotifier.value = false;
                                    }
                                  },
                                  child: BgmDetailPage(
                                    key: const ValueKey('BgmDetail'),
                                    subjectId: _bgmInfo.subjectId,
                                    title: _svc.title,
                                    imageUrl: _svc.coverImageUrl ?? '',
                                    fixedSummary: _fixedSummary,
                                    initialScore: _bgmInfo.score,
                                    onClose: () =>
                                        _showDetailNotifier.value = false,
                                  ),
                                )
                              : Column(
                                  key: const ValueKey('Tabs'),
                                  children: [
                                    _buildRestoredTabBar(context),
                                    Expanded(
                                      child: TabBarView(
                                        controller: _tabController,
                                        physics: const BouncingScrollPhysics(),
                                        children: [
                                          PlayerTab(
                                            child: _buildEpisodeTab(context),
                                          ),
                                          _buildCommentTab(),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileTerminalFailure() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.redAccent),
          const SizedBox(height: 8),
          Text(
            _terminalFailure?.message ?? '播放失败，请换源或使用 AI 修复',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: _openSourceSwitchSheet,
                child: const Text('手动换源'),
              ),
              FilledButton.icon(
                onPressed: _openAiRuleRepair,
                icon: const Icon(Icons.auto_awesome_rounded, size: 17),
                label: const Text('AI 修复'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRestoredTabBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: TabBar(
              tabAlignment: TabAlignment.start,
              tabs: const [Text('选集'), Text('BAKA')],
              controller: _tabController,
              labelPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 6,
              ),
              isScrollable: true,
              labelStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
              unselectedLabelStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.normal,
              ),
              indicator: ArcTabIndicator(
                color: Theme.of(context).colorScheme.primary,
              ),
              dividerColor: Colors.transparent,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => _showEpisodePicker(downloadMode: true),
            icon: const Icon(Icons.download_rounded, size: 20),
            visualDensity: VisualDensity.compact,
            color: Theme.of(context).colorScheme.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildImmersiveHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildGlassIconButton(
            icon: Icons.group_rounded,
            onPressed: () => WatchPartySheet.show(context, _watchParty),
          ),
          const SizedBox(width: 12),
          _buildGlassIconButton(
            icon: Icons.cast_connected_rounded,
            onPressed: () => showCast(context),
          ),
          const SizedBox(width: 12),
          _buildGlassIconButton(
            icon: Icons.more_horiz_rounded,
            onPressed: () => PlayerSettingsPage.show(context, ctr),
          ),
        ],
      ),
    );
  }

  Widget _buildGlassIconButton({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return ScaleButton(
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  Widget _buildCommentTab() {
    // 外站源以 bgmId 为 postId（gv bgmid），让不同来源共用评论区
    final effectivePostId = (_isAdapter && _bgmInfo.subjectId != null)
        ? _bgmInfo.subjectId!
        : (int.tryParse(_svc.data['id'].toString()) ?? 11);
    return CIslandCommentWidget(
      key: const ValueKey('commentTab'),
      postId: effectivePostId,
      bgmSubjectId: _bgmInfo.subjectId,
      episodeIndex: currPlayIndex,
      episodeName: _currentEpisodeTitle,
      onCommentLinkTap: (text, url, title) => handleCommentLinkTap(
        text: text,
        url: url,
        title: title,
        controller: ctr,
        currentPlayIndex: currPlayIndex,
        videoList: videoList,
        onChangePlayIndex: _switchEpisode,
      ),
    );
  }

  /// 选集与缓存共用同一个面板；差别只有初始模式和是否提供线路切换。
  Future<void> _showEpisodePicker({bool downloadMode = false}) async {
    final index = await showEpisodeListDialog(
      context: context,
      videoList: videoList,
      currentIndex: currPlayIndex,
      videoId: _svc.data['id'].toString(),
      isFullScreen: downloadMode
          ? _playerFullscreen.value
          : _playerFullscreen.value && !isWindows,
      postDetail: _svc.buildDetailData(),
      urlResolver: _svc.resolveEpisodeUrl,
      startInDownloadMode: downloadMode,
      currentLineIndex: downloadMode ? null : currUrl,
      sourceNames: downloadMode ? null : _sourceNames,
      onLineChanged: downloadMode ? null : changeUrl,
    );
    if (index != null) _switchEpisode(index);
  }

  Future<void> toggleFollow() async {
    try {
      await _svc.toggleFollow();
      _followNotifier.value = _svc.isFollow();
    } catch (e) {
      debugPrint('追番操作失败: $e');
      showSnackBar(e.toString(), isError: true);
    }
  }

  Widget _buildEpisodeTab(BuildContext context) {
    final isDesktop = isWindows || MediaQuery.sizeOf(context).width > 600;
    return ValueListenableBuilder<bool>(
      valueListenable: _sortAscendingNotifier,
      child: Column(
        children: [
          VideoDetailCard(
            content: _svc,
            followNotifier: _followNotifier,
            cachedTags: _cachedTags,
            onFollowPressed: toggleFollow,
            onShowDetail: () => _showDetailNotifier.value = true,
            danmakuController: danmakuController,
            sourceName: _currentSourceName,
            lineName: _currentLineName,
            onSourceTap: _openSourceSwitchSheet,
            isSearching: _autoMatchController != null,
          ),
          ActiveDownloadIndicator(taskIdPrefix: _taskIdPrefix),
          BtProgressIndicator(torrent: _svc.torrent),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Divider(
              height: 1,
              color: Theme.of(context).dividerColor.withValues(alpha: 0.08),
            ),
          ),
        ],
      ),
      builder: (context, sortAscending, header) => CustomScrollView(
        physics: const ClampingScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: header),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '选集',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  buildEpisodeToolbar(
                    context: context,
                    sortAscending: sortAscending,
                    onSortDirectionChanged: () =>
                        _sortAscendingNotifier.value = !sortAscending,
                    onShowVideoList: _showEpisodePicker,
                    videoList: videoList,
                    updateTime: _svc.data['time'],
                    content: _svc.data['content'],
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            sliver: isDesktop
                ? buildWindowsEpisodeList(
                    context: context,
                    videoList: videoList,
                    ascending: sortAscending,
                    currPlayIndex: currPlayIndex,
                    onEpisodeChanged: _switchEpisode,
                  )
                : SliverToBoxAdapter(
                    child: buildHorizontalEpisodeList(
                      context: context,
                      videoList: videoList,
                      ascending: sortAscending,
                      currPlayIndex: currPlayIndex,
                      videoId: _svc.data['id'].toString(),
                      onEpisodeChanged: _switchEpisode,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
