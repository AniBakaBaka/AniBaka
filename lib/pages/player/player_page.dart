import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart' hide ContextExtensionss;

import 'package:baka/api/bgm.dart';
import 'package:baka/app/app_runtime.dart';
import 'package:baka/core/content_filter.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/ai_rule_authoring.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/models/skip_segment.dart';
import 'package:baka/pages/player/bgm_detail_page.dart';
import 'package:baka/pages/player/dlna_page.dart';
import 'package:baka/pages/setting/player_settings_page.dart';
import 'package:baka/pages/source/ai_rule_authoring_page.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/matching/match_memory_service.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/playback/media_session.dart';
import 'package:baka/services/playback/playback_content.dart';
import 'package:baka/services/playback/playback_progress.dart';
import 'package:baka/services/playback/watch_party.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/anime_detail/anime_detail_placeholder.dart';
import 'package:baka/widgets/anime_detail/controller/video_source_search_controller.dart';
import 'package:baka/widgets/anime_detail/video_source_search_sheet.dart';
import 'package:baka/widgets/baka_player/index.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:baka/widgets/common/scale_button.dart';
import 'package:baka/widgets/common/tab_indicator.dart';
import 'package:baka/widgets/episode/episode_list_dialog.dart';
import 'package:baka/widgets/episode/episode_widgets.dart';
import 'package:baka/widgets/platform/tv/tv_anime_detail.dart';
import 'package:baka/widgets/platform/tv/tv_player_layout.dart';
import 'package:baka/widgets/platform/windows/windows_player_layout.dart';
import 'package:baka/widgets/player/download_indicators.dart';
import 'package:baka/widgets/player/player_tab.dart';
import 'package:baka/widgets/player/video_detail_card.dart';
import 'package:baka/widgets/watch_party/watch_party_sheet.dart';

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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _immersiveStatusBar = SystemUiOverlayStyle(
    statusBarColor: Colors.black,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
  );

  late final PlaybackContent _content = PlaybackContent(
    sources: sourceRepository,
    collections: collections,
    history: historyRepository,
    request: widget.request,
    posIndex: widget.posIndex,
  );
  late final _tabs = TabController(length: 2, vsync: this);
  final _party = Get.find<WatchPartyService>();
  final _mediaSession = Get.find<MediaSessionService>();
  final ctr = PlaybackController();
  final _danmaku = DanmakuController();
  final _followed = ValueNotifier(false);
  final _showDetail = ValueNotifier(false);
  final _sortAscending = ValueNotifier(true);
  final _failedSources = <String>{};
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// Recovery must not inherit the cancellation context of the failed open.
  final Zone _zone = Zone.current;

  PlaybackProgress? _progress;
  Future<void>? _playerReady;
  Future<void> _hlsReload = Future<void>.value();
  SourceOperation? _operation;
  VideoSourceSearchController? _autoMatch;
  VideoSourceSearchController? _sourceSearch;
  DlnaCastController? _cast;
  PlayerFailureContext? _failure;
  Object? _lastError;
  String? _refreshedMediaKey;

  /// The upstream media URL; a renderer cannot reach local HLS proxies.
  String _castUrl = '';
  int _generation = 0;
  bool _inited = false;
  bool _opened = false;
  bool _recovering = false;
  bool _wasPlaying = false;
  bool _fullscreen = false;
  bool _darkTheme = false;
  bool _updatingFollow = false;

  bool get _hidden => contentFilter.value && _content.isNsfw;
  bool get _hasNext => _content.currPlayIndex + 1 < _content.videoList.length;
  bool _isStale(int id) => !mounted || id != _generation;

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    contentFilter.addListener(_onContentFilterChanged);
    _sourceSearch = VideoSourceSearchController.takeCachedFor(
      seedData: _content.data,
    );
    Get.find<AppRuntime>().playbacks.add(ctr);
    ctr.setMediaInfo(_content.currentMediaInfo);
    ctr.core.addListener(_onCoreChanged);
    ctr.onHlsAdFilterChanged = _reloadHlsFilter;
    unawaited(_loadFollowState());
    if (!_content.isLocalSource &&
        (widget.autoMatch || _content.needsSourceMatch)) {
      _startAutoMatch();
    } else {
      unawaited(_loadInitialData());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _darkTheme = Theme.of(context).brightness == Brightness.dark;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_save(_progress));
  }

  @override
  void dispose() {
    contentFilter.removeListener(_onContentFilterChanged);
    WidgetsBinding.instance.removeObserver(this);
    _operation?.cancel();
    ctr.onHlsAdFilterChanged = null;
    ctr.core.removeListener(_onCoreChanged);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _releaseAutoMatch();
    _sourceSearch?.dispose();
    _cast?.dispose();
    Get.find<AppRuntime>().playbacks.remove(ctr);
    _mediaSession.detach(ctr);
    _party.detachPlayer(ctr);
    ctr.detachDanmaku();
    unawaited(_flushProgress());
    unawaited(ctr.dispose());
    unawaited(_content.dispose());
    _danmaku.dispose();
    _tabs.dispose();
    _followed.dispose();
    _showDetail.dispose();
    _sortAscending.dispose();
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: _darkTheme
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: _darkTheme ? Brightness.dark : Brightness.light,
        systemStatusBarContrastEnforced: false,
      ),
    );
    super.dispose();
  }

  Future<void> _save(PlaybackProgress? progress, {bool seeked = false}) async {
    // OP/ED calibration may pause, seek to the ending, or enter the background.
    // Those preview positions must not replace watch progress or mark it watched.
    if (progress == null || ctr.skipSelection.value != null) return;
    try {
      await progress.save(
        ctr.timeline.value,
        rememberPosition: ctr.preferences.value.rememberLastPosition,
        seeked: seeked,
      );
    } catch (error) {
      debugPrint('保存播放进度失败: $error');
    }
  }

  /// Saves before the media is replaced: stop/open reset the timeline.
  Future<void> _flushProgress() {
    final progress = _progress;
    _progress = null;
    return _save(progress);
  }

  void _onContentFilterChanged() {
    if (_hidden) {
      ++_generation;
      _operation?.cancel();
      _releaseAutoMatch();
      unawaited(ctr.pause());
    } else if (_content.isNsfw && !_inited) {
      unawaited(_loadInitialData());
    }
    _refresh();
  }

  void _onCoreChanged() {
    final core = ctr.core.value;
    if (_wasPlaying && !core.playing) unawaited(_save(_progress));
    _wasPlaying = core.playing;
    if (core.failed) {
      _scheduleRecovery(
        core.errorMessage.isNotEmpty ? core.errorMessage : '视频播放异常',
      );
    }
  }

  void _startAutoMatch() {
    if (_hidden || _autoMatch != null) return;
    _failure = null;
    late final VideoSourceSearchController search;
    search = VideoSourceSearchController(
      seedData: _content.buildDetailData(),
      autoMatchMode: true,
      targetEpisodeIndex: _content.currPlayIndex,
      onMatchFound: (request) {
        if (identical(_autoMatch, search)) unawaited(_adopt(request));
      },
      onMatchFailed: () {
        if (!identical(_autoMatch, search)) return;
        _releaseAutoMatch();
        // Try an existing local route once, then expose failure. An unresolved
        // cloud record must not restart matching or leave an empty player.
        unawaited(_loadInitialData(allowSourceMatch: false));
      },
    );
    _autoMatch = search;
    _refresh();
    unawaited(
      search.startSearch().catchError((Object error) {
        if (!identical(_autoMatch, search)) return;
        _releaseAutoMatch();
        _fail(error);
      }),
    );
    unawaited(_loadBgmMeta());
  }

  void _releaseAutoMatch() {
    final search = _autoMatch;
    _autoMatch = null;
    search
      ?..cancelSearch()
      ..dispose();
  }

  /// Display metadata only; matching and opening run in parallel.
  Future<void> _loadBgmMeta() async {
    if (_content.isLocalSource) return;
    await _content.ensureBgmDetail();
    if (!mounted) return;
    if (_hidden) {
      _onContentFilterChanged();
      return;
    }
    ctr.setMediaInfo(_content.currentMediaInfo);
    _refresh();
    _party.publishCurrentMedia();
  }

  Future<void> _loadInitialData({bool allowSourceMatch = true}) async {
    if (_hidden) return;
    final id = _generation;
    unawaited(_loadBgmMeta());
    var ready = false;
    Object? error;
    try {
      ready = await _content.prepareInitialPlayback();
    } catch (e) {
      debugPrint('加载初始数据失败: $e');
      error = e;
    }
    if (_isStale(id)) return;
    ctr.setMediaInfo(_content.currentMediaInfo);
    _refresh();
    if (ready) {
      await _open(id);
    } else if (allowSourceMatch && !_content.isLocalSource) {
      _startAutoMatch();
    } else {
      _fail(error ?? '未找到可播放的线路，请选择播放源后重试');
    }
  }

  /// Subscriptions belong to the page; reopening a URL reuses this setup.
  Future<void> _initPlayer() async {
    ctr.attachDanmaku(_danmaku);
    DanmakuController.loadSettings(_danmaku);
    await Future.wait([ctr.initialize(), _mediaSession.init()]);
    if (!mounted) return;
    _subscriptions.addAll([
      ctr.completed.listen((_) => _playNext()),
      ctr.seekEvents.listen((_) => unawaited(_save(_progress, seeked: true))),
    ]);
    _mediaSession.attach(
      ctr,
      onNextEpisode: _playNext,
      onPreviousEpisode: _playPrevious,
    );
    _party.attachPlayer(ctr, _content, onEpisodeRequested: _switchEpisode);
  }

  void _playNext() {
    if (_hasNext) unawaited(_switchEpisode(_content.currPlayIndex + 1));
  }

  void _playPrevious() {
    final index = _content.currPlayIndex;
    if (index > 0) unawaited(_switchEpisode(index - 1));
  }

  Future<void> _reloadHlsFilter(bool enabled) {
    // Serialize toggles so two proxy manifests never close each other.
    final id = _generation;
    return _hlsReload = _hlsReload
        .then((_) async {
          if (_isStale(id) ||
              !_content.isAdapter ||
              ctr.currentMediaUri == null ||
              ctr.preferences.value.filterHlsAds != enabled) {
            return;
          }
          final position = ctr.timeline.value.position;
          final core = ctr.core.value;
          // Stop the old manifest before replacing the proxy, so its closed
          // connection is not mistaken for a broken line.
          await _flushProgress();
          if (_isStale(id)) return;
          await ctr.stop();
          if (_isStale(id)) return;
          await _open(
            id,
            resumeAt: position,
            autoplay: core.playing,
            filterHlsAds: enabled,
          );
          if (!_isStale(id) && _opened) await ctr.setRate(core.playbackRate);
        })
        .catchError((Object _) {
          if (!_isStale(id)) {
            showSnackBar('重新应用去广告失败，请重新打开当前集', isError: true);
          }
        });
  }

  Future<void> _open(
    int id, {
    Duration? resumeAt,
    bool autoplay = true,
    bool? filterHlsAds,
  }) {
    if (_hidden || _isStale(id)) return Future<void>.value();
    if (!identical(SourceOperation.current, _operation)) _operation?.cancel();
    final operation = _operation = SourceOperation();
    return operation
        .run(
          () => _openMedia(
            id,
            resumeAt: resumeAt,
            autoplay: autoplay,
            filterHlsAds: filterHlsAds,
          ),
        )
        .catchError((Object error) {
          if (!operation.isCancelled) throw error;
        });
  }

  Future<void> _openMedia(
    int id, {
    Duration? resumeAt,
    bool autoplay = true,
    bool? filterHlsAds,
  }) async {
    await _flushProgress();
    if (_isStale(id)) return;
    if (_failure != null) {
      _failure = null;
      _refresh();
    }
    _opened = false;
    _lastError = null;
    _castUrl = '';
    ctr.setSkipContext(null);
    final content = _content;
    var timeline = 'original';
    int? keepAlive;
    try {
      var url = content.isLocalSource ? content.localFilePath! : null;
      var headers = content.isLocalSource ? content.localHttpHeaders : null;
      final adapter = content.isAdapter
          ? await content.prepareAdapterSource()
          : null;
      if (_isStale(id)) return;
      ctr.setMediaInfo(content.currentMediaInfo);
      await (_playerReady ??= _initPlayer());
      if (_isStale(id)) return;

      if (adapter != null) {
        content.stopAdapterPlaybackKeepAlive();
        final media = await content.resolveAdapterPlaybackMedia(
          adapter,
          content.currentEpisodeId,
        );
        if (media.url.isEmpty) {
          content.clearPrefetchedPlaybackMedia();
          throw Exception('Unable to resolve media url');
        }
        if (_isStale(id)) return;
        keepAlive = await content.startAdapterPlaybackKeepAlive(
          adapter,
          media.url,
        );
        if (_isStale(id)) {
          content.stopAdapterPlaybackKeepAlive(keepAlive);
          return;
        }
        final playable = await adapter.preparePlaybackMedia(
          media,
          filterHlsAds: filterHlsAds,
          onTimelinePrepared: (key) => timeline = key,
          onHlsAdFilterStatus: (message) {
            if (!_isStale(id)) showSnackBar(message);
          },
        );
        if (_isStale(id)) {
          content.stopAdapterPlaybackKeepAlive(keepAlive);
          return;
        }
        _castUrl = media.url;
        url = playable.url;
        headers = playable.httpHeaders;
      } else if (url == null) {
        url = await content.resolveEpisodeUrl(content.currPlayIndex);
        if (_isStale(id)) return;
        if (url == null || url.isEmpty) throw Exception('无法获取视频播放地址');
        _castUrl = url;
      }

      final bgmId = content.bgmInfo.subjectId;
      final start =
          resumeAt ??
          (ctr.preferences.value.rememberLastPosition
              ? historyRepository.getResumePosition(
                  videoKey: content.videoKey,
                  request: content.request,
                  bgmId: bgmId,
                )
              : Duration.zero);
      final progress = PlaybackProgress(
        history: historyRepository,
        request: content.request.copyWith(
          metadataUpdates: {'nsfw': content.isNsfw},
        ),
        videoKey: content.videoKey,
        start: start,
        bgmId: bgmId,
        cover: content.coverImageUrl,
      );
      await ctr.open(
        url,
        autoplay: autoplay,
        httpHeaders: headers,
        start: start > Duration.zero ? start : null,
      );
      if (_isStale(id)) return;
      _progress = progress;
      _opened = true;
      final skip = content.buildSkipContext(timeline);
      ctr.setSkipContext(skip);
      unawaited(_bindSkipEpisode(id, skip));
      if (!content.isLocalSource && content.videoList.isNotEmpty) {
        await historyRepository.rememberEpisode(
          request: content.request,
          bgmId: bgmId,
          episodeIndex: content.currPlayIndex,
          urlIndex: content.currUrl,
        );
        if (_isStale(id)) return;
      }
      if (!_inited || _failure != null) {
        _inited = true;
        _failure = null;
        _refresh();
      }
      if (resumeAt == null) {
        final episode = content.currPlayIndex;
        await _danmaku.load(
          (abort) => content.fetchDanmakuData(episode, abortTrigger: abort),
        );
      }
    } catch (error) {
      if (_isStale(id) || SourceOperation.current?.isCancelled == true) return;
      debugPrint('打开视频失败: $error');
      _lastError = error;
      if (_opened) return;
      content.clearPrefetchedPlaybackMedia();
      if (keepAlive != null) content.stopAdapterPlaybackKeepAlive(keepAlive);
      _scheduleRecovery(error);
    }
  }

  Future<void> _bindSkipEpisode(int id, SkipContext skip) async {
    final subjectId = skip.subjectId;
    if (subjectId == null || skip.bound) return;
    try {
      final episodeId = matchSkipEpisode(
        _content.currentEpisodeTitle,
        await getBgmEpisodes(subjectId),
      );
      if (episodeId != null &&
          !_isStale(id) &&
          identical(skip, ctr.skipContext)) {
        ctr.setSkipContext(skip.bind(subjectId, episodeId));
      }
    } catch (_) {
      /* Local annotations remain available without metadata. */
    }
  }

  void _scheduleRecovery(Object error) {
    if (mounted && !_recovering) _zone.run(() => unawaited(_recover(error)));
  }

  /// Refresh the signed URL once, then try the remaining lines of this
  /// episode, then other matched sources; only then surface the failure.
  Future<void> _recover(Object error) async {
    final content = _content;
    if (content.isLocalSource) {
      _fail(error);
      return;
    }
    _recovering = true;
    bool playing() => _opened && !ctr.core.value.failed;
    try {
      final refreshKey =
          '${content.request.source}|${content.currentEpisodeId}';
      if (content.isAdapter &&
          _castUrl.isNotEmpty &&
          _refreshedMediaKey != refreshKey) {
        _refreshedMediaKey = refreshKey;
        (await content.prepareAdapterSource()).invalidateDownloadUrl(
          content.currentEpisodeId,
        );
        content.clearPrefetchedPlaybackMedia();
        await _open(_generation);
        if (playing()) return;
      }
      _markSourceFailed();
      // A remembered dead match or prefetch must not be hit again.
      content.clearPrefetchedPlaybackMedia();
      if (content.title.isNotEmpty) {
        await MatchMemoryService.remove(
          bgmId: content.bgmInfo.subjectId,
          title: content.title,
        );
      }

      final startLine = content.currUrl;
      final lines = [
        ...?content.currentVideoItem?.availableLineIndexes.where(
          (line) => line > startLine,
        ),
      ];
      for (final line in lines) {
        if (!mounted) return;
        showSnackBar('当前线路播放异常，正在自动为您切换线路 $line...');
        await _changeLine(line);
        if (playing()) return;
        content.clearPrefetchedPlaybackMedia();
        content.stopAdapterPlaybackKeepAlive();
      }

      final search = _sourceSearch ??= _newSourceSearch(
        content.buildDetailData(),
      );
      if (search.results.isEmpty) await search.startSearch();
      while (mounted) {
        final next = await search.findNextPlayableCandidate(
          excludedSources: _failedSources,
          episodeIndex: content.currPlayIndex,
        );
        if (!mounted) return;
        if (next == null) break;
        showSnackBar(
          '当前视频源播放失败，已自动为您切换至：'
          '${next.metadata['sourceDisplayName'] ?? next.source}',
        );
        await _adopt(next);
        if (playing()) return;
        _markSourceFailed();
        content.clearPrefetchedPlaybackMedia();
        content.stopAdapterPlaybackKeepAlive();
      }
      showSnackBar('所有可用匹配源均播放失败，请点击源名称手动搜索选择', isError: true);
      _fail(_lastError ?? error);
    } catch (e) {
      debugPrint('[PlayerPage] 自动换源失败: $e');
      _fail(e);
    } finally {
      _recovering = false;
    }
  }

  static VideoSourceSearchController _newSourceSearch(
    Map<String, dynamic> seedData,
  ) =>
      VideoSourceSearchController.takeCachedFor(seedData: seedData) ??
      VideoSourceSearchController(seedData: seedData);

  /// Search candidates are excluded by source key.
  void _markSourceFailed() {
    final source = _content.request.source;
    if (source.isNotEmpty) _failedSources.add(source);
  }

  void _fail(Object error) {
    if (!mounted) return;
    final data = _content.data;
    _failure = PlayerFailureContext(
      message: error.toString(),
      title: _content.title,
      sourceKey: _content.request.source,
      seriesId: (data['seriesId'] ?? data['seriesUrl'])?.toString(),
      episodeId: _content.currentEpisodeId,
    );
    _refresh();
  }

  Future<void> _openAiRepair() async {
    final failure = _failure;
    if (failure == null || Instances.isTV) return;
    await sourceRepository.init();
    final key = failure.sourceKey;
    final config = AdapterRegistry.isCustomSource(key)
        ? sourceCatalog.customSourceById(
            key.substring(AdapterRegistry.customSourcePrefix.length),
          )
        : AdapterRegistry.isBuiltinSource(key)
        ? sourceCatalog.builtinSourceById(key)
        : null;
    if (!mounted) return;
    final repairing = config != null;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AiRuleAuthoringPage(
          seed: RuleAuthoringSeed(
            mode: repairing
                ? RuleAuthoringMode.repair
                : RuleAuthoringMode.create,
            siteUrl: config?.baseUrl ?? '',
            keyword: failure.title,
            sourceKey: repairing ? key : null,
            currentConfig: config,
            seriesId: failure.seriesId,
            episodeId: failure.episodeId,
            failureMessage: failure.message,
          ),
        ),
      ),
    );
    if (!mounted || saved != true) return;
    _failure = null;
    _failedSources.clear();
    _refresh();
    if (repairing) {
      await _open(++_generation);
    } else {
      await _openSourceSheet();
    }
  }

  /// Every media replacement: save, swap the selection, stop, open, publish.
  Future<void> _replacePlayback(VoidCallback apply) async {
    _operation?.cancel();
    final id = ++_generation;
    await _flushProgress();
    if (_isStale(id)) return;
    _danmaku.reset();
    apply();
    _refresh();
    await ctr.stop();
    _content.stopAdapterPlaybackKeepAlive();
    await _open(id);
    if (!_isStale(id)) _party.publishCurrentMedia();
  }

  Future<void> _switchEpisode(int episodeIndex, {int? lineIndex}) {
    final content = _content;
    final selection = content.normalizeSelection(
      episodeIndex,
      lineIndex ?? content.currUrl,
    );
    if (selection.episodeIndex == content.currPlayIndex &&
        selection.lineIndex == content.currUrl) {
      return Future<void>.value();
    }
    return _replacePlayback(() => content.applySelection(selection));
  }

  Future<void> _changeLine(int line) =>
      _switchEpisode(_content.currPlayIndex, lineIndex: line);

  Future<void> _adopt(PlaybackRequest request) {
    // A manual choice wins over a still-running history match.
    _releaseAutoMatch();
    return _replacePlayback(() => _content.adoptPlaybackRequest(request));
  }

  Future<void> _openSourceSheet() async {
    final content = _content;
    if (content.isLocalSource) return;
    final seedData = content.buildDetailData();
    final selection = await VideoSourceSearchSheet.show(
      context,
      seedData: seedData,
      currentEpisodeIndex: content.currPlayIndex,
      currentLineIndex: content.currUrl,
      currentSource: content.request.source,
      searchController: _sourceSearch ??= _newSourceSearch(seedData),
    );
    if (!mounted || selection == null) return;
    final line = selection.lineIndex ?? content.currUrl;
    if (content.request.source == selection.source &&
        content.data['seriesUrl'] == selection.metadata['seriesUrl'] &&
        content.currUrl == line) {
      return;
    }
    await _adopt(
      selection.copyWith(episodeIndex: content.currPlayIndex, lineIndex: line),
    );
  }

  /// Episode picking and caching share one panel; only the mode differs.
  Future<void> _showEpisodePicker({bool downloadMode = false}) async {
    final content = _content;
    final index = await showEpisodeListDialog(
      context: context,
      videoList: content.videoList,
      currentIndex: content.currPlayIndex,
      videoId: '${content.data['id']}',
      isFullScreen:
          _fullscreen && (downloadMode || !Instances.isDesktopPlatform),
      postDetail: content.buildDetailData(),
      urlResolver: content.resolveEpisodeUrl,
      startInDownloadMode: downloadMode,
      currentLineIndex: downloadMode ? null : content.currUrl,
      sourceNames: downloadMode ? null : content.sourceNames,
      onLineChanged: downloadMode ? null : _changeLine,
    );
    if (index != null) unawaited(_switchEpisode(index));
  }

  void _showCast() {
    if (_castUrl.isEmpty && _cast?.connected != true) {
      showSnackBar('无法获取视频地址，无法投屏');
      return;
    }
    DlnaCastPanel.show(
      context,
      _cast ??= DlnaCastController(_content, onEpisodeChanged: _switchEpisode),
      url: _castUrl,
    );
  }

  void _showWatchParty() => WatchPartySheet.show(context, _party);

  void _showSettings() => PlayerSettingsPage.show(context, ctr);

  Future<void> _loadFollowState() async {
    try {
      await _content.refreshCollection();
      if (mounted) _followed.value = _content.isFollow();
    } catch (error) {
      debugPrint('读取追番状态失败: $error');
    }
  }

  Future<void> _toggleFollow() async {
    if (_updatingFollow) return;
    _updatingFollow = true;
    try {
      await _content.toggleFollow();
      if (mounted) _followed.value = _content.isFollow();
    } catch (e) {
      if (mounted) showSnackBar(e.toString(), isError: true);
    } finally {
      _updatingFollow = false;
    }
  }

  void _onCommentLink(String text, String? url, String title) =>
      handleCommentLinkTap(
        text: text,
        url: url,
        title: title,
        controller: ctr,
        currentPlayIndex: _content.currPlayIndex,
        videoList: _content.videoList,
        onChangePlayIndex: _switchEpisode,
      );

  @override
  Widget build(BuildContext context) {
    if (_hidden) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('已隐藏 NSFW 内容')),
      );
    }
    final content = _content;
    if (content.isLocalSource) return _immersive(_buildLocalLayout());
    final source = content.request.source.trim();
    if ((source.isEmpty || source == 'bgm') &&
        _autoMatch == null &&
        _failure == null) {
      return Instances.isTV
          ? TvAnimeDetailPlaceholder(
              data: content.buildDetailData(),
              episodes: content.videoList,
            )
          : AnimeDetailPlaceholder(data: content.buildDetailData());
    }
    if (Instances.isTV) {
      return TvPlayerLayout(
        content: content,
        inited: _inited,
        controller: ctr,
        danmakuController: _danmaku,
        onEpisodeChanged: _switchEpisode,
        onUrlChanged: _changeLine,
        onWatchPartyPressed: _showWatchParty,
        isSearching: _autoMatch != null,
        initialFailure: _failure == null ? null : _buildFailure(),
      );
    }
    if (Instances.isDesktopPlatform || context.isTablet) {
      return _immersive(
        WindowsPlayerLayout(
          content: content,
          inited: _inited,
          controller: ctr,
          danmakuController: _danmaku,
          followNotifier: _followed,
          isSearching: _autoMatch != null,
          onSourceTap: _openSourceSheet,
          onEpisodeChanged: _switchEpisode,
          onCastPressed: _showCast,
          onWatchPartyPressed: _showWatchParty,
          onPickEpisode: _showEpisodePicker,
          onFullScreenChanged: (value) => _fullscreen = value,
          onUrlChanged: _changeLine,
          onCommentLinkTap: _onCommentLink,
          onDownloadPressed: () => _showEpisodePicker(downloadMode: true),
          onFollowPressed: _toggleFollow,
          terminalPlaybackFailure: _failure != null,
          onAiRepair: _openAiRepair,
        ),
      );
    }
    return _immersive(_buildMobileLayout(context));
  }

  Widget _immersive(Widget child) {
    if (Instances.isDesktopPlatform || Instances.isTV) return child;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _immersiveStatusBar,
      child: child,
    );
  }

  Widget _headerButtons(
    List<(IconData, VoidCallback)> buttons, {
    double spacing = 12,
    double end = 8,
  }) {
    return Padding(
      padding: EdgeInsets.only(right: end),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: spacing,
        children: [
          for (final (icon, onTap) in buttons)
            ScaleButton(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLocalLayout() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _inited
          ? BakaPlayer(
              controller: ctr,
              full: true,
              danmakuEnabled: true,
              hasNextEpisode: _hasNext,
              onNextEpisode: _playNext,
              headerControl: _headerButtons(
                [
                  if (_content.videoList.length > 1)
                    (Icons.video_library_rounded, _showEpisodePicker),
                  (Icons.cast_connected_rounded, _showCast),
                  (Icons.more_horiz_rounded, _showSettings),
                ],
                spacing: 8,
                end: 16,
              ),
            )
          : Center(
              child: _failure == null
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text('视频打开失败', style: TextStyle(color: Colors.white)),
            ),
    );
  }

  Widget _buildFailure() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.redAccent),
          const SizedBox(height: 8),
          Text(
            _failure?.message ?? '播放失败，请换源或使用 AI 修复',
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
                onPressed: _openSourceSheet,
                child: const Text('手动换源'),
              ),
              FilledButton.icon(
                onPressed: _openAiRepair,
                icon: const Icon(Icons.auto_awesome_rounded, size: 17),
                label: const Text('AI 修复'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMobilePlayer() {
    if (_inited) {
      return BakaPlayer(
        controller: ctr,
        canSearchSource: true,
        danmakuEnabled: true,
        headerControl: _headerButtons([
          (Icons.group_rounded, _showWatchParty),
          (Icons.cast_connected_rounded, _showCast),
          (Icons.more_horiz_rounded, _showSettings),
        ]),
        onPickEpisode: _showEpisodePicker,
        hasNextEpisode: _hasNext,
        onNextEpisode: _playNext,
        onFullScreenChanged: (value) => _fullscreen = value,
        showPlaybackError: _failure != null,
        onAiRepair: _openAiRepair,
      );
    }
    if (_failure != null) return _buildFailure();
    return Center(
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
            _autoMatch != null ? '正在自动匹配源中...' : '正在加载播放器...',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout(BuildContext context) {
    // 外层 ValueListenableBuilder 仅在 _showDetail 变化时重建 PopScope，
    // Scaffold 子树以 child 形式被缓存，避免重复构建。
    return ValueListenableBuilder<bool>(
      valueListenable: _showDetail,
      builder: (context, showDetail, child) => PopScope(
        canPop: !showDetail,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _showDetail.value = false;
        },
        child: child!,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              AspectRatio(aspectRatio: 16 / 9, child: _buildMobilePlayer()),
              Expanded(
                child: ColoredBox(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _showDetail,
                    builder: (context, showDetail, _) => AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, animation) => SlideTransition(
                        position: Tween<Offset>(
                          begin: Offset(
                            child.key == const ValueKey('BgmDetail')
                                ? 0.05
                                : -0.05,
                            0,
                          ),
                          end: Offset.zero,
                        ).animate(animation),
                        child: FadeTransition(opacity: animation, child: child),
                      ),
                      child: showDetail
                          ? _buildDetailPanel()
                          : _buildTabs(context),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailPanel() {
    // 贴文 content 中 `>` 之前是站点信息，之后才是简介。
    final raw = _content.data['content'] as String?;
    final cut = raw?.indexOf('>') ?? -1;
    return GestureDetector(
      key: const ValueKey('BgmDetail'),
      onHorizontalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) > 300) _showDetail.value = false;
      },
      child: BgmDetailPage(
        subjectId: _content.bgmInfo.subjectId,
        title: _content.title,
        imageUrl: _content.coverImageUrl ?? '',
        fixedSummary: cut < 0 ? raw : raw!.substring(cut + 1).trim(),
        initialScore: _content.bgmInfo.score,
        onClose: () => _showDetail.value = false,
      ),
    );
  }

  Widget _buildTabs(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      key: const ValueKey('Tabs'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: TabBar(
                  tabAlignment: TabAlignment.start,
                  tabs: const [Text('选集'), Text('BAKA')],
                  controller: _tabs,
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
                  indicator: ArcTabIndicator(color: primary),
                  dividerColor: Colors.transparent,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () => _showEpisodePicker(downloadMode: true),
                icon: const Icon(Icons.download_rounded, size: 20),
                visualDensity: VisualDensity.compact,
                color: primary,
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            physics: const BouncingScrollPhysics(),
            children: [
              PlayerTab(child: _buildEpisodeTab(context)),
              _buildCommentTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCommentTab() {
    final postId = _content.commentPostId;
    if (postId == null) return const Center(child: Text('此视频没有关联评论'));
    return CIslandCommentWidget(
      key: const ValueKey('commentTab'),
      postId: postId,
      bgmSubjectId: _content.bgmInfo.subjectId,
      episodeIndex: _content.currPlayIndex,
      episodeName: _content.currentEpisodeTitle,
      onCommentLinkTap: _onCommentLink,
    );
  }

  Widget _buildEpisodeTab(BuildContext context) {
    final content = _content;
    final videoId = '${content.data['id']}';
    final wide =
        Instances.isDesktopPlatform || MediaQuery.sizeOf(context).width > 600;
    return ValueListenableBuilder<bool>(
      valueListenable: _sortAscending,
      child: Column(
        children: [
          VideoDetailCard(
            content: content,
            followNotifier: _followed,
            onFollowPressed: _toggleFollow,
            onShowDetail: () => _showDetail.value = true,
            danmakuController: _danmaku,
            onSourceTap: _openSourceSheet,
            isSearching: _autoMatch != null,
          ),
          ActiveDownloadIndicator(taskIdPrefix: content.downloadTaskPrefix),
          BtProgressIndicator(torrent: content.torrent),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Divider(
              height: 1,
              color: Theme.of(context).dividerColor.withValues(alpha: 0.08),
            ),
          ),
        ],
      ),
      builder: (context, ascending, header) => CustomScrollView(
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
                    sortAscending: ascending,
                    onSortDirectionChanged: () =>
                        _sortAscending.value = !ascending,
                    onShowVideoList: _showEpisodePicker,
                    videoList: content.videoList,
                    updateTime: content.data['time'],
                    content: content.data['content'],
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            sliver: wide
                ? buildWindowsEpisodeList(
                    context: context,
                    videoList: content.videoList,
                    ascending: ascending,
                    currPlayIndex: content.currPlayIndex,
                    onEpisodeChanged: _switchEpisode,
                  )
                : SliverToBoxAdapter(
                    child: buildHorizontalEpisodeList(
                      context: context,
                      videoList: content.videoList,
                      ascending: ascending,
                      currPlayIndex: content.currPlayIndex,
                      videoId: videoId,
                      onEpisodeChanged: _switchEpisode,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
