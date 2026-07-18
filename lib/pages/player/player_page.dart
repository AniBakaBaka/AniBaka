import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/instance.dart';
import 'package:baka/pages/player/bgm_detail_page.dart';
import 'package:baka/pages/player/dlna_page.dart';
import 'package:baka/pages/setting/player_settings_page.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/services/playback_session_coordinator.dart';
import 'package:baka/services/player_service.dart';

import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/utils/platform_page_route.dart';
import 'package:baka/widgets/anime_detail/anime_detail_placeholder.dart';
import 'package:baka/widgets/baka_player/index.dart';
import 'package:baka/widgets/comment/comment_card.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:baka/widgets/common/tab_indicator.dart';
import 'package:baka/widgets/common/scale_button.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:baka/widgets/danmaku/view.dart';
import 'package:baka/widgets/episode/episode_list_dialog.dart';
import 'package:baka/widgets/episode/episode_widgets.dart';
import 'package:baka/widgets/platform/tv/tv_anime_detail.dart';
import 'package:baka/widgets/platform/tv/tv_player_layout.dart';
import 'package:baka/widgets/platform/windows/windows_player_layout.dart';
import 'package:baka/widgets/player/download_indicators.dart';
import 'package:baka/widgets/player/source_switch_sheet.dart';
import 'package:baka/widgets/player/video_detail_card.dart';
import 'package:baka/widgets/anime_detail/controller/video_source_search_controller.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    required this.data,
    super.key,
    this.posIndex,
    this.autoMatchMode = false,
  });

  final Map data;
  final int? posIndex;
  final bool autoMatchMode;

  @override
  State<StatefulWidget> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with TickerProviderStateMixin {
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

  late final PlayerService _svc;
  late final PlaybackSessionCoordinator _session;
  late final TabController _tabController;
  List<String> _cachedTags = const [];
  late final String _fixedSummary;
  late final String _taskIdPrefix;
  String _resolvedUrl = '';
  final GlobalKey<CommentListState> commentKey = GlobalKey();
  final PlaybackController ctr = PlaybackController();
  final DanmakuController danmakuController = DanmakuController();
  final ValueNotifier<bool> _followNotifier = ValueNotifier<bool>(false);
  // 细化重建粒度：以下 Notifier 替代过去多处 setState(() {})，避免播放器整页重建
  // - _initedNotifier：仅驱动「加载中 / 播放器」切换
  // - _pageDataVersion：剧集/线路/标签/BGM 元数据变化时整页数据刷新的信号
  // - _showDetailNotifier：移动端 BGM 详情抽屉显隐
  // - _sortAscendingNotifier：移动端选集排序方向
  final ValueNotifier<bool> _initedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<int> _pageDataVersion = ValueNotifier<int>(0);
  final ValueNotifier<bool> _showDetailNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _sortAscendingNotifier = ValueNotifier<bool>(true);
  final ValueNotifier<bool> _playerFullscreen = ValueNotifier<bool>(false);

  SystemUiOverlayStyle _exitStatusBarStyle = _lightStatusBarStyle;

  void _bumpPageData() {
    if (!mounted) return;
    _pageDataVersion.value = _pageDataVersion.value + 1;
  }

  List<PlaybackEpisode> get videoList => _svc.videoList;
  int get currPlayIndex => _svc.currPlayIndex;
  int get currUrl => _svc.currUrl;
  bool get inited => _initedNotifier.value;
  bool get isWindows => Instances.isWindows;
  bool get _isAdapter => _svc.isAdapter;
  bool get _isLocalSource => _svc.isLocalSource;
  BgmInfo get _bgmInfo => _svc.bgmInfo;
  String get _currentEpisodeTitle => _svc.currentEpisodeTitle;
  List<String>? get _sourceNames => _svc.sourceNames;

  bool _isStale(int requestId) => !mounted || !_session.isCurrent(requestId);

  @override
  void initState() {
    super.initState();
    _svc = PlayerService(data: widget.data, posIndex: widget.posIndex);
    _session = PlaybackSessionCoordinator(
      controller: ctr,
      danmakuController: danmakuController,
      content: _svc,
      onNextEpisode: _playNextEpisode,
      onPreviousEpisode: _playPreviousEpisode,
    );
    _tabController = TabController(length: 2, vsync: this);
    final source = widget.data['source']?.toString() ?? '';
    final id = widget.data['id'];
    _taskIdPrefix = source.isNotEmpty ? '${source}_${id}_' : '${id}_';
    _updateCachedTagsFromBgm();
    final raw = widget.data['content'] as String?;
    final cut = raw?.indexOf('>') ?? -1;
    _fixedSummary = raw == null
        ? ''
        : (cut != -1 ? raw.substring(cut + 1).trim() : raw);

    _applyMediaInfo(_svc.initialMediaInfo);
    _followNotifier.value = _svc.isFollow();
    _loadInitialData();
  }

  void _playNextEpisode() {
    if (mounted && currPlayIndex + 1 < videoList.length) {
      changePlayIndex(currPlayIndex + 1);
    }
  }

  void _playPreviousEpisode() {
    if (mounted && currPlayIndex > 0) changePlayIndex(currPlayIndex - 1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _exitStatusBarStyle = Theme.of(context).brightness == Brightness.dark
        ? _darkStatusBarStyle
        : _lightStatusBarStyle;
  }

  Future<void> _loadInitialData() async {
    try {
      await Future.wait([
        getDetail(),
        if (!_isLocalSource) _svc.ensureBgmInfo(),
      ]);
      if (!_isLocalSource) {
        await _svc.ensureBgmDetail();
        _updateCachedTagsFromBgm();
      }
    } catch (e) {
      debugPrint('加载初始数据失败: $e');
    }
    if (mounted) {
      _applyMediaInfo(_svc.currentMediaInfo);
      _bumpPageData();
    }
  }

  void _updateCachedTagsFromBgm() {
    final bgmDetail = _svc.bgmDetailData;
    if (bgmDetail != null) {
      final tags = BgmUtils.asMapList(bgmDetail['tags']);
      if (tags.isNotEmpty) {
        _cachedTags = tags
            .take(6)
            .map((t) => t['name']?.toString())
            .whereType<String>()
            .toList();
        return;
      }
    }

    final rawTags = (widget.data['tag']?.toString().split(' ') ?? const [])
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    final sourceDisplayName = widget.data['sourceDisplayName']?.toString();
    final sourceVal = widget.data['source']?.toString();
    _cachedTags = rawTags
        .where((t) {
          if (t == sourceDisplayName || t == sourceVal) return false;
          if (t == _currentSourceName) return false;
          return true;
        })
        .take(5)
        .toList();
  }

  void _applyMediaInfo(PlaybackMediaInfo info) => ctr.setMediaInfo(info);

  @override
  void dispose() {
    unawaited(
      _session.dispose().whenComplete(() async {
        await ctr.dispose();
        _svc.dispose();
      }),
    );
    _tabController.dispose();
    _followNotifier.dispose();
    _initedNotifier.dispose();
    _pageDataVersion.dispose();
    _showDetailNotifier.dispose();
    _sortAscendingNotifier.dispose();
    _playerFullscreen.dispose();
    SystemChrome.setSystemUIOverlayStyle(_exitStatusBarStyle);
    super.dispose();
  }

  void showCast(BuildContext context) {
    final castUrl = _getCurrentVideoUrl();
    if (castUrl.isEmpty) {
      showSnackBar('无法获取视频地址，无法投屏');
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DlnaCastPanel(
        datasource: castUrl,
        animeTitle: widget.data['title']?.toString() ?? '',
        videoList: videoList,
        currentEpisodeIndex: currPlayIndex,
        urlResolver: (idx) => _svc.resolveEpisodeUrl(idx),
        onEpisodeChanged: (idx) {
          if (mounted) changePlayIndex(idx);
        },
      ),
    );
  }

  Future<void> getDetail() async {
    await _svc.loadDetail();
    if (videoList.isNotEmpty) await initVideoController(_session.generation);
    _bumpPageData();
  }

  /// 标记播放器表面就绪。仅切换 _initedNotifier，让「加载占位 → 播放器」的局部子树重建。
  void _markInited() {
    if (!inited && mounted) _initedNotifier.value = true;
  }

  Future<void> initVideoController(int requestId) async {
    if (_isStale(requestId)) return;
    _resolvedUrl = '';
    try {
      if (_isLocalSource) {
        await _initLocalSourcePlayer(requestId);
      } else if (_isAdapter) {
        await _initAdapterSourcePlayer(requestId);
      } else {
        await _initInternalSourcePlayer(requestId);
      }
    } catch (e) {
      if (_isStale(requestId)) return;
      debugPrint('初始化视频控制器失败: $e');
      showSnackBar('初始化播放器失败');
    }
  }

  Future<void> _initLocalSourcePlayer(int requestId) async {
    final filePath = _svc.localFilePath;
    if (filePath == null) return;
    _applyMediaInfo(_svc.currentMediaInfo);
    if (!inited) {
      await _initializePlayer(skipDataSource: true);
      if (_isStale(requestId)) return;
    }
    await ctr.open(
      filePath,
      autoplay: true,
      httpHeaders: _svc.localHttpHeaders,
    );
    if (_isStale(requestId)) return;
    _markInited();
    final content = await _svc.readLocalDanmakuFile(filePath);
    if (!_isStale(requestId) && content != null) {
      await _session.parseAndSetDanmakuItems(BgmUtils.parseJsonList(content));
    }
  }

  Future<void> _initAdapterSourcePlayer(int requestId) async {
    final adapter = await _svc.prepareAdapterSource();
    if (_isStale(requestId)) return;
    _applyMediaInfo(_svc.currentMediaInfo);
    if (!inited) {
      await _initializePlayer(skipDataSource: true);
      if (_isStale(requestId)) return;
    }
    final episodeId = _svc.currentEpisodeId;
    _svc.stopAdapterPlaybackKeepAlive();
    if (adapter.requiresCustomPlayback) {
      final videoController = ctr.videoController;
      if (videoController == null) {
        throw StateError('Video controller is not initialized');
      }
      await adapter.play(episodeId, videoController);
      await ctr.applyPlaybackConfiguration();
    } else {
      final media = await _svc.resolveAdapterPlaybackMedia(adapter, episodeId);
      if (media.url.isEmpty) throw Exception('Unable to resolve media url');
      if (_isStale(requestId)) return;
      final keepAliveGeneration = await _svc.startAdapterPlaybackKeepAlive(
        adapter,
        media.url,
      );
      if (_isStale(requestId)) {
        _svc.stopAdapterPlaybackKeepAlive(keepAliveGeneration);
        return;
      }
      final playbackMedia = await adapter.preparePlaybackMedia(media);
      if (_isStale(requestId)) {
        _svc.stopAdapterPlaybackKeepAlive(keepAliveGeneration);
        return;
      }
      _resolvedUrl = media.url;
      try {
        await ctr.open(
          playbackMedia.url,
          autoplay: true,
          httpHeaders: playbackMedia.httpHeaders,
        );
      } catch (_) {
        _svc.stopAdapterPlaybackKeepAlive(keepAliveGeneration);
        rethrow;
      }
    }
    if (_isStale(requestId)) return;
    _markInited();
    await _loadDanmakuAsync();
  }

  Future<void> _initInternalSourcePlayer(int requestId) async {
    _applyMediaInfo(_svc.currentMediaInfo);
    final videoUrl = await _svc.getVideoUrl();
    if (_isStale(requestId)) return;
    if (videoUrl == null) {
      showSnackBar('无法获取视频地址');
      return;
    }
    _resolvedUrl = videoUrl;
    if (!inited) {
      await _initializePlayer();
    } else {
      // open 默认自动播放，无需再次调用 play。
      await ctr.open(_resolvedUrl);
    }
    if (_isStale(requestId)) return;
    _markInited();
    await _loadDanmakuAsync();
  }

  Future<void> _loadDanmakuAsync() async {
    final requestId = _session.generation;
    final episodeIndex = currPlayIndex;
    final danmuList = await _svc.fetchDanmakuData(episodeIndex);
    bool stale() =>
        !_session.isCurrent(requestId) || episodeIndex != currPlayIndex;
    if (stale()) return;
    await _startDanmakuPlay(danmuList, shouldAbort: stale);
  }

  Future<void> _startDanmakuPlay(
    List<DanmakuItem> danmuList, {
    bool Function()? shouldAbort,
  }) async {
    if (shouldAbort?.call() ?? false) return;
    _session.setDanmakuItems(danmuList);
    if (shouldAbort?.call() ?? false) danmakuController.reset();
  }

  Future<void> _initializePlayer({bool skipDataSource = false}) async {
    await _session.start();
    if (!skipDataSource && _resolvedUrl.isNotEmpty) {
      await ctr.open(_resolvedUrl, autoplay: true);
    } else {
      await ctr.initialize();
    }
    if (ctr.preferences.value.rememberLastPosition) {
      final position = _svc.getSavedProgress();
      if (position.inSeconds > 10) {
        Future.delayed(const Duration(milliseconds: 1000), () {
          if (mounted) ctr.showJumpToPositionPrompt(position);
        });
      }
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
    final currentRequestId = _session.nextGeneration();
    await _session.saveAndResetForSwitch();
    if (_isStale(currentRequestId)) return;
    if (!_svc.prepareSwitchEpisode(episodeIndex, lineIndex: lineIndex)) return;
    // currPlayIndex/currUrl 变化 → 仅触发依赖剧集数据的子树刷新
    _bumpPageData();
    await ctr.stop();
    _svc.stopAdapterPlaybackKeepAlive();
    await initVideoController(currentRequestId);
    // initVideoController 内部已通过 _markInited 与异步任务驱动局部重建，无需再 setState 整页
  }

  Future<void> changePlayIndex(int i) => _switchEpisode(i);

  Future<void> changeUrl(int urlIndex) =>
      _switchEpisode(currPlayIndex, lineIndex: urlIndex);

  @override
  Widget build(BuildContext context) {
    if (_isLocalSource) return _buildLocalLayout(context);
    // 仅在 _pageDataVersion 触发时重建顶层布局分发（videoList / 剧集 / BGM 元数据等）
    return ListenableBuilder(
      listenable: _pageDataVersion,
      builder: (context, _) {
        if (videoList.isEmpty) {
          return Instances.isTV
              ? TvAnimeDetailPlaceholder(data: widget.data)
              : AnimeDetailPlaceholder(data: widget.data);
        }
        if (Instances.isTV) return _buildTvLayout(context);
        if (isWindows || context.isTablet) {
          return _buildWindowsTabletLayout(context);
        }
        return _buildMobileLayout(context);
      },
    );
  }

  Widget _buildTvLayout(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _initedNotifier,
      builder: (context, isInited, _) {
        return TvPlayerLayout(
          data: widget.data,
          videoList: videoList,
          currPlayIndex: currPlayIndex,
          currUrl: currUrl,
          sourceNames: _sourceNames,
          inited: isInited,
          controller: ctr,
          danmakuController: danmakuController,
          onEpisodeChanged: changePlayIndex,
          onUrlChanged: changeUrl,
        );
      },
    );
  }

  Widget _buildWindowsTabletLayout(BuildContext context) {
    return _withImmersiveStatusBar(
      ListenableBuilder(
        listenable: _initedNotifier,
        builder: (context, _) {
          return WindowsPlayerLayout(
            data: widget.data,
            videoList: videoList,
            currPlayIndex: currPlayIndex,
            currUrl: currUrl,
            sourceNames: _sourceNames,
            inited: _initedNotifier.value,
            controller: ctr,
            danmakuController: danmakuController,
            bgmInfo: _bgmInfo,
            followNotifier: _followNotifier,
            cachedTags: _cachedTags,
            sourceName: _currentSourceName,
            lineName: _currentLineName,
            onShowDetail: () => BgmDetailPage.show(
              context,
              title: _svc.title,
              subjectId: _bgmInfo.subjectId,
              imageUrl: _svc.coverImageUrl ?? '',
              fixedSummary: _fixedSummary,
              initialScore: _bgmInfo.score,
            ),
            onSourceTap: _openSourceSwitchSheet,
            commentKey: commentKey,
            onEpisodeChanged: changePlayIndex,
            onCastPressed: () => showCast(context),
            onPickEpisode: () => _pickAndPlayEpisode(context),
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
              onChangePlayIndex: changePlayIndex,
            ),
            onDownloadPressed: () => _pickAndDownloadEpisode(context),
            onFollowPressed: toggleFollow,
          );
        },
      ),
    );
  }

  String _getCurrentVideoUrl() {
    if (_resolvedUrl.isNotEmpty) return _resolvedUrl;
    if (!_isAdapter) return '';
    return ctr.currentMediaUri ?? '';
  }

  String get _currentSourceName {
    final displayName = widget.data['sourceDisplayName']?.toString().trim();
    if (displayName != null && displayName.isNotEmpty) return displayName;
    final source = widget.data['source']?.toString().trim();
    if (source != null && source.isNotEmpty) return source;
    return '播放源';
  }

  String? get _currentLineName {
    final names = _sourceNames;
    final index = currUrl - 1;
    if (names == null || index < 0 || index >= names.length) return null;
    final lineName = names[index].trim();
    return lineName.isEmpty ? null : lineName;
  }

  String get _currentSourceSummary {
    final lineName = _currentLineName;
    return lineName == null
        ? _currentSourceName
        : '$_currentSourceName - $lineName';
  }

  Map<String, dynamic> _buildSourceSeedData() {
    final seed = Map<String, dynamic>.from(widget.data);
    final bgmInfo = _bgmInfo;
    final coverImageUrl = _svc.coverImageUrl;

    if (bgmInfo.subjectId != null) seed['bgmId'] = bgmInfo.subjectId;
    if (bgmInfo.score != null) seed['score'] = bgmInfo.score;
    if (coverImageUrl != null && coverImageUrl.isNotEmpty) {
      seed['bgmImageUrl'] = coverImageUrl;
    }
    if (_svc.bgmDetailData != null) {
      seed['bgmDetailData'] = _svc.bgmDetailData;
    }
    return seed;
  }

  Future<void> _openSourceSwitchSheet() async {
    if (_isLocalSource) return;

    if (VideoSourceSearchController.globalCachedTitle != _svc.title) {
      VideoSourceSearchController.globalCached?.dispose();
      VideoSourceSearchController.globalCached = VideoSourceSearchController(
        title: _svc.title,
        cover: _svc.coverImageUrl ?? '',
        seedData: _buildSourceSeedData(),
      );
      VideoSourceSearchController.globalCachedTitle = _svc.title;
    }

    final selection = await SourceSwitchSheet.show(
      context,
      title: _svc.title,
      cover: _svc.coverImageUrl ?? '',
      seedData: _buildSourceSeedData(),
      currentEpisodeIndex: currPlayIndex,
      currentLineIndex: currUrl,
      currentSource: widget.data['source']?.toString(),
      currentSourceName: _currentSourceSummary,
      searchController: VideoSourceSearchController.globalCached,
    );
    if (!mounted || selection == null) return;

    final nextData = Map<String, dynamic>.from(selection.data)
      ..['currPlayIndex'] = currPlayIndex
      ..['currUrl'] = selection.lineIndex;

    final isSameSource =
        widget.data['source'] == nextData['source'] &&
        widget.data['seriesUrl'] == nextData['seriesUrl'];
    final isSameLine = currUrl == selection.lineIndex;

    if (isSameSource) {
      if (nextData['_prefetchedPlayback'] != null) {
        _svc.data['_prefetchedPlayback'] = nextData['_prefetchedPlayback'];
      }
      if (!isSameLine) {
        changeUrl(selection.lineIndex);
      }
      return;
    }

    await _session.saveProgress();
    if (!mounted) return;
    _svc.saveHistory(
      positionMs: ctr.timeline.value.position.inMilliseconds,
      durationMs: ctr.timeline.value.duration.inMilliseconds,
    );

    Navigator.of(context).pushReplacement(
      platformPageRoute<void>(
        builder: (_) => PlayerPage(data: nextData, posIndex: currPlayIndex),
        transitionDuration: const Duration(milliseconds: 220),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  Widget _withImmersiveStatusBar(Widget child) {
    if (Instances.isDesktopPlatform || Instances.isTV) return child;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _immersiveStatusBarStyle,
      child: child,
    );
  }

  Widget _buildLocalLayout(BuildContext context) {
    // 仅在 _initedNotifier 切换时重建本地播放器的 body，外层 Scaffold/AnnotatedRegion 保持稳定
    return _withImmersiveStatusBar(
      Scaffold(
        backgroundColor: Colors.black,
        body: ValueListenableBuilder<bool>(
          valueListenable: _initedNotifier,
          builder: (context, isInited, _) {
            if (isInited) {
              return BakaPlayer(
                controller: ctr,
                full: true,
                hasNextEpisode: currPlayIndex + 1 < videoList.length,
                onNextEpisode: _playNextEpisode,
                headerControl: Padding(
                  padding: const EdgeInsets.only(right: 16.0),
                  child: _buildGlassIconButton(
                    icon: Icons.more_horiz_rounded,
                    onPressed: () => PlayerSettingsPage.show(context, ctr),
                  ),
                ),
                danmuWidget: DanmakuView(controller: danmakuController),
              );
            }
            if (_svc.localFilePath != null) {
              return const Center(
                child: CircularProgressIndicator(color: Colors.white),
              );
            }
            return const SizedBox.shrink();
          },
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
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _initedNotifier,
                      builder: (context, isInited, _) {
                        if (isInited) {
                          return BakaPlayer(
                            controller: ctr,
                            detail: widget.data,
                            danmuWidget: DanmakuView(
                              controller: danmakuController,
                              created: (e) async => await ctr.play(),
                            ),
                            headerControl: _buildImmersiveHeader(context),
                            onPickEpisode: () => _pickAndPlayEpisode(context),
                            hasNextEpisode:
                                currPlayIndex + 1 < videoList.length,
                            onNextEpisode: _playNextEpisode,
                            onFullScreenChanged: (value) {
                              _playerFullscreen.value = value;
                            },
                            full: false,
                          );
                        }
                        return const Center(
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white24,
                          ),
                        );
                      },
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
                                          _buildEpisodeTab(context),
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
            onPressed: () => _pickAndDownloadEpisode(context),
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
        : (int.tryParse(widget.data['id'].toString()) ?? 11);
    return CIslandCommentWidget(
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
        onChangePlayIndex: changePlayIndex,
      ),
    );
  }

  Future<void> _pickAndPlayEpisode(BuildContext context) async {
    final useFullscreenPanel = _playerFullscreen.value && !isWindows;
    final i = await showEpisodeListDialog(
      context: context,
      videoList: videoList,
      currentIndex: currPlayIndex,
      videoId: widget.data['id'].toString(),
      isFullScreen: useFullscreenPanel,
      postDetail: widget.data,
      urlResolver: (idx) => _svc.resolveEpisodeUrl(idx),
      onEpisodeChanged: changePlayIndex,
      currentLineIndex: currUrl,
      sourceNames: _sourceNames,
      onLineChanged: changeUrl,
    );
    if (i != null) changePlayIndex(i);
  }

  Future<void> _pickAndDownloadEpisode(BuildContext context) async {
    await showEpisodeListDialog(
      context: context,
      videoList: videoList,
      currentIndex: currPlayIndex,
      videoId: widget.data['id'].toString(),
      isFullScreen: _playerFullscreen.value,
      postDetail: widget.data,
      urlResolver: (idx) => _svc.resolveEpisodeUrl(idx),
      onEpisodeChanged: changePlayIndex,
      startInDownloadMode: true,
    );
  }

  Future<void> toggleFollow() async {
    try {
      await _svc.toggleFollow();
      _followNotifier.value = _svc.isFollow();
    } catch (e) {
      debugPrint('追番操作失败: $e');
      showSnackBar('登录失效，请重新登录');
    }
  }

  Widget _buildEpisodeTab(BuildContext context) {
    final isDesktop = isWindows || MediaQuery.of(context).size.width > 600;

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        children: [
          VideoDetailCard(
            detail: widget.data,
            bgmInfo: _bgmInfo,
            followNotifier: _followNotifier,
            cachedTags: _cachedTags,
            onFollowPressed: toggleFollow,
            onShowDetail: () => _showDetailNotifier.value = true,
            sourceName: _currentSourceName,
            lineName: _currentLineName,
            onSourceTap: _openSourceSwitchSheet,
          ),

          ActiveDownloadIndicator(taskIdPrefix: _taskIdPrefix),
          const MobileBtProgressIndicator(),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Divider(
              height: 1,
              color: Theme.of(context).dividerColor.withValues(alpha: 0.08),
            ),
          ),
          // 排序方向切换仅在此处局部重建工具栏 + 列表
          ValueListenableBuilder<bool>(
            valueListenable: _sortAscendingNotifier,
            builder: (context, sortAscending, _) {
              final visibleEpisodeIndexes =
                  PlaybackEpisodeCatalog.filterIndexes(
                    videoList,
                    ascending: sortAscending,
                  );
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '选集',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        buildEpisodeToolbar(
                          context: context,
                          sortAscending: sortAscending,
                          onSortDirectionChanged: () =>
                              _sortAscendingNotifier.value = !sortAscending,
                          onShowVideoList: () => _pickAndPlayEpisode(context),
                          videoList: videoList,
                          updateTime: widget.data['time'],
                          content: widget.data['content'],
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: isDesktop
                        ? buildWindowsEpisodeList(
                            context: context,
                            videoList: videoList,
                            visibleIndexes: visibleEpisodeIndexes,
                            currPlayIndex: currPlayIndex,
                            onEpisodeChanged: changePlayIndex,
                          )
                        : buildHorizontalEpisodeList(
                            context: context,
                            videoList: videoList,
                            filteredList: visibleEpisodeIndexes,
                            currPlayIndex: currPlayIndex,
                            videoId: widget.data['id'].toString(),
                            onEpisodeChanged: changePlayIndex,
                          ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
