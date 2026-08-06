import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/instance.dart';
import 'package:baka/pages/player/bgm_detail_page.dart';
import 'package:baka/pages/player/dlna_page.dart';
import 'package:baka/pages/setting/player_settings_page.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/services/playback_session_coordinator.dart';
import 'package:baka/services/player_service.dart';

import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/utils/platform_page_route.dart';
import 'package:baka/widgets/baka_player/index.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:baka/widgets/common/tab_indicator.dart';
import 'package:baka/widgets/common/scale_button.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:baka/widgets/danmaku/view.dart';
import 'package:baka/widgets/episode/episode_list_dialog.dart';
import 'package:baka/widgets/episode/episode_widgets.dart';
import 'package:baka/widgets/anime_detail/anime_detail_placeholder.dart';
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
    this.autoMatch = false,
  });

  final Map data;
  final int? posIndex;
  final bool autoMatch;

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
  final GlobalKey<CIslandCommentWidgetState> commentKey = GlobalKey();
  final PlaybackController ctr = PlaybackController();
  final DanmakuController danmakuController = DanmakuController();
  final ValueNotifier<bool> _followNotifier = ValueNotifier<bool>(false);
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

  VideoSourceSearchController? _autoMatchController;

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

    ctr.setMediaInfo(_svc.initialMediaInfo);
    _followNotifier.value = _svc.isFollow();
    
    final shouldAutoMatch = !_isLocalSource && widget.autoMatch;
    if (shouldAutoMatch) {
      _startHeadlessAutoMatch();
    } else {
      _loadInitialData();
    }
  }

  void _startHeadlessAutoMatch() {
    _autoMatchController = VideoSourceSearchController(
      seedData: _svc.buildSourceSeedData(),
      autoMatchMode: true,
      targetEpisodeIndex: currPlayIndex,
      onMatchFound: (resolvedData) {
        if (!mounted) return;
        _autoMatchController?.cancelSearch();
        _autoMatchController = null;
        _svc.adoptPrefetchedPlayback(resolvedData);
        _bumpPageData();
        initVideoController(_session.nextGeneration());
      },
      onMatchFailed: () {
        if (!mounted) return;
        _autoMatchController = null;
        _loadInitialData();
      },
    );
    _autoMatchController?.startSearch();
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
      final bgmFuture = _isLocalSource ? null : _svc.ensureBgmInfo();
      await _svc.loadDetail();
      if (videoList.isNotEmpty) {
        await initVideoController(_session.generation);
      }
      _bumpPageData();
      if (!_isLocalSource) {
        await bgmFuture;
        await _svc.ensureBgmDetail();
        _updateCachedTagsFromBgm();
      }
    } catch (e) {
      debugPrint('加载初始数据失败: $e');
    }
    if (mounted) {
      ctr.setMediaInfo(_svc.currentMediaInfo);
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

  @override
  void dispose() {
    _autoMatchController?.cancelSearch();
    _autoMatchController?.dispose();
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

  Future<void> initVideoController(int requestId) async {
    if (_isStale(requestId)) return;
    _resolvedUrl = '';
    try {
      final localPath = _isLocalSource ? _svc.localFilePath : null;
      if (_isLocalSource && localPath == null) return;
      final adapter = _isAdapter ? await _svc.prepareAdapterSource() : null;
      if (_isStale(requestId)) return;

      ctr.setMediaInfo(_svc.currentMediaInfo);
      if (!inited) {
        await _session.start();
        if (_isStale(requestId)) return;

        if (ctr.preferences.value.rememberLastPosition) {
          final position = _svc.getSavedProgress();
          if (position.inSeconds > 10) {
            unawaited(
              Future.delayed(const Duration(seconds: 1), () {
                if (!_isStale(requestId)) {
                  ctr.showJumpToPositionPrompt(position);
                }
              }),
            );
          }
        }
      }

      if (localPath != null) {
        await ctr.open(
          localPath,
          autoplay: true,
          httpHeaders: _svc.localHttpHeaders,
        );
      } else if (adapter != null) {
        final episodeId = _svc.currentEpisodeId;
        _svc.stopAdapterPlaybackKeepAlive();
        final media = await _svc.resolveAdapterPlaybackMedia(
          adapter,
          episodeId,
        );
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
      } else {
        final videoUrl = await _svc.resolveEpisodeUrl(currPlayIndex);
        if (_isStale(requestId)) return;
        if (videoUrl == null || videoUrl.isEmpty) {
          throw Exception('无法获取视频播放地址');
        }
        _resolvedUrl = videoUrl;
        await ctr.open(videoUrl, autoplay: true);
      }

      if (_isStale(requestId)) return;
      await _svc.rememberCurrentEpisode();
      if (_isStale(requestId)) return;
      if (!inited) _initedNotifier.value = true;

      if (localPath != null) {
        final content = await _svc.readLocalDanmakuFile(localPath);
        if (!_isStale(requestId) && content != null) {
          await _session.parseAndSetDanmakuItems(
            BgmUtils.parseJsonList(content),
          );
        }
      } else {
        final episodeIndex = currPlayIndex;
        final danmaku = await _svc.fetchDanmakuData(episodeIndex);
        if (!_isStale(requestId) && episodeIndex == currPlayIndex) {
          _session.setDanmakuItems(danmaku);
        }
      }
    } catch (e) {
      if (_isStale(requestId)) return;
      debugPrint('初始化视频控制器失败: $e');
      await _handlePlaybackInitializationFailure(e);
    }
  }

  final Set<String> _failedSourceKeys = {};
  bool _isAutoSwitchingSource = false;

  Future<void> _handlePlaybackInitializationFailure(Object error) async {
    if (!mounted || _isAutoSwitchingSource) return;
    _isAutoSwitchingSource = true;

    try {
      final currentSourceKey = widget.data['source']?.toString() ?? '';
      if (currentSourceKey.isNotEmpty) {
        _failedSourceKeys.add(currentSourceKey);
      }
      final currentSeriesId = widget.data['seriesId'] ?? widget.data['id'] ?? widget.data['url'];
      if (currentSourceKey.isNotEmpty && currentSeriesId != null) {
        _failedSourceKeys.add('$currentSourceKey|$currentSeriesId');
      }

      // 1. 尝试当前剧集的下一条线路
      final currentEp = _svc.currentVideoItem;
      if (currentEp != null && currUrl < currentEp.lineCount) {
        await changeUrl(currUrl + 1);
        return;
      }

      // 2. 静默自动匹配备用源
      final seedData = _svc.buildSourceSeedData();
      final controller = _autoMatchController ??
          VideoSourceSearchController.sharedFor(seedData: seedData);

      final nextCandidateData = await controller.findNextPlayableCandidate(
        excludedKeys: _failedSourceKeys,
        episodeIndex: currPlayIndex,
      );

      if (!mounted) return;

      if (nextCandidateData != null) {
        _svc.adoptPrefetchedPlayback(nextCandidateData);
        _bumpPageData();
        await initVideoController(_session.nextGeneration());
        return;
      }
    } catch (e) {
      debugPrint('[PlayerPage] Auto fallback error: $e');
    } finally {
      _isAutoSwitchingSource = false;
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
    // 期间状态只可能被并发切换改变，而并发切换已被上面的 stale 检查拦截
    _svc.applySelection(selection);
    // currPlayIndex/currUrl 变化 → 仅触发依赖剧集数据的子树刷新
    _bumpPageData();
    await ctr.stop();
    _svc.stopAdapterPlaybackKeepAlive();
    await initVideoController(currentRequestId);
    // 播放器与弹幕在 initVideoController 内完成局部更新，无需重建整页。
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
        if (videoList.isEmpty && !widget.autoMatch && _autoMatchController == null) {
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
          isSearching: _autoMatchController != null,
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
            isSearching: _autoMatchController != null,
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
              onChangePlayIndex: changePlayIndex,
            ),
            onDownloadPressed: () => _showEpisodePicker(downloadMode: true),
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

  Future<void> _openSourceSwitchSheet() async {
    if (_isLocalSource) return;

    final seedData = _svc.buildSourceSeedData();

    final searchController =
        VideoSourceSearchController.sharedFor(seedData: seedData);

    final selection = await SourceSwitchSheet.show(
      context,
      seedData: seedData,
      currentEpisodeIndex: currPlayIndex,
      currentLineIndex: currUrl,
      currentSource: widget.data['source']?.toString(),
      searchController: searchController,
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
      _svc.adoptPrefetchedPlayback(nextData);
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
                            onPickEpisode: () => _showEpisodePicker(),
                            hasNextEpisode:
                                currPlayIndex + 1 < videoList.length,
                            onNextEpisode: _playNextEpisode,
                            onFullScreenChanged: (value) {
                              _playerFullscreen.value = value;
                            },
                            full: false,
                          );
                        }
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
                                (_autoMatchController != null || widget.autoMatch)
                                    ? '正在自动匹配源中...'
                                    : '正在加载播放器...',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ],
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

  /// 选集与缓存共用同一个面板；差别只有初始模式和是否提供线路切换。
  Future<void> _showEpisodePicker({bool downloadMode = false}) async {
    final index = await showEpisodeListDialog(
      context: context,
      videoList: videoList,
      currentIndex: currPlayIndex,
      videoId: widget.data['id'].toString(),
      isFullScreen: downloadMode
          ? _playerFullscreen.value
          : _playerFullscreen.value && !isWindows,
      postDetail: widget.data,
      urlResolver: _svc.resolveEpisodeUrl,
      startInDownloadMode: downloadMode,
      currentLineIndex: downloadMode ? null : currUrl,
      sourceNames: downloadMode ? null : _sourceNames,
      onLineChanged: downloadMode ? null : changeUrl,
    );
    if (index != null) changePlayIndex(index);
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
            isSearching: _autoMatchController != null,
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
                          onShowVideoList: () => _showEpisodePicker(),
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
