import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/api/collection.dart';
import 'package:baka/api/post.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/anime_detail_view_data.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/services/play_history_sync_service.dart';
import 'package:baka/services/playback_settings_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/shimmer.dart';
import 'package:baka/widgets/anime_detail/video_source_search_sheet.dart';
import 'package:baka/services/navigation_service.dart';

import 'package:baka/widgets/anime_detail/collection_sheet.dart';
import 'package:baka/widgets/anime_detail/character_detail_sheet.dart';
import 'package:baka/widgets/anime_detail/anime_detail_header.dart';
import 'package:baka/widgets/anime_detail/anime_detail_comments.dart';
import 'package:baka/widgets/anime_detail/anime_detail_related.dart';

class AnimeDetailPlaceholder extends StatefulWidget {
  final Map data;

  const AnimeDetailPlaceholder({required this.data, super.key});

  @override
  State<AnimeDetailPlaceholder> createState() => _AnimeDetailPlaceholderState();
}

class _AnimeDetailPlaceholderState extends State<AnimeDetailPlaceholder> {
  late final int? _postId;
  bool _hasHandledInitialSearchSheet = false;
  bool _isSearchSheetOpen = false;
  bool _isAutoMatching = false;
  bool _isDetailLoading = true;
  int _autoMatchTargetEpisodeIndex = 0;
  late final Future<void> _initialDataFuture;
  late List<Map<String, dynamic>> _initialComments;
  late int _initialCommentTotal;

  AnimeCollection? _collection;
  bool _isCollectionLoading = false;
  bool _isStatusUpdating = false;

  late BgmInfo _bgmInfo;
  Map<String, dynamic>? _detailData;
  Map<String, dynamic>? _anibakaData;
  late AnimeDetailViewData _detail;

  int? get _subjectId => _bgmInfo.subjectId;

  int _resolveAutoMatchEpisodeIndex() {
    final remembered = PlayHistorySyncService.getResumeSelection(widget.data);
    if (remembered != null) return remembered.episodeIndex;

    final watched = _collection?.epWatched;
    if (watched != null && watched > 0) return watched - 1;
    return 0;
  }

  int? get _validPostId {
    final postId = _postId;
    return (postId != null && postId > 0) ? postId : null;
  }

  bool get _isLoggedIn => Instances.userToken.isNotEmpty;

  void _rebuildDetail() {
    _bgmInfo = BgmUtils.readFromData(widget.data);
    _detailData = BgmUtils.asMap(widget.data['bgmDetailData']);
    _detail = AnimeDetailViewData.from(
      source: widget.data,
      bgmInfo: _bgmInfo,
      anibaka: _anibakaData,
      bgm: _detailData,
    );
  }

  @override
  void initState() {
    super.initState();
    _postId = BgmUtils.toInt(widget.data['id']);
    _initialComments = BgmUtils.asMapList(widget.data['bgmComments']);
    _initialCommentTotal =
        BgmUtils.toInt(widget.data['bgmCommentTotal']) ??
        _initialComments.length;
    _rebuildDetail();
    _isDetailLoading = _detailData == null;
    _isCollectionLoading = _isLoggedIn;
    _initialDataFuture = _loadInitialData();
    _scheduleInitialSearchSheet();
  }

  void _scheduleInitialSearchSheet() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.any([
        _initialDataFuture,
        Future<void>.delayed(const Duration(milliseconds: 300)),
      ]);
      if (!mounted || _hasHandledInitialSearchSheet) return;

      final autoMatch = PlaybackSettingsService.getAutoMatchSource();
      if (autoMatch) {
        _hasHandledInitialSearchSheet = true;
        _autoMatchTargetEpisodeIndex = _resolveAutoMatchEpisodeIndex();
        setState(() => _isAutoMatching = true);
      } else {
        await _showSearchBottomSheet();
      }
    });
  }

  void _handleAutoMatchFound(Map<String, dynamic> resolvedData) {
    if (!mounted) return;
    setState(() => _isAutoMatching = false);
    NavigationService.toPlayer(context, resolvedData, fade: true);
  }

  void _handleAutoMatchFailed() {
    if (!mounted) return;
    setState(() => _isAutoMatching = false);
    _showSearchBottomSheet();
  }

  Future<void> _loadInitialData() async {
    try {
      if (_subjectId == null) {
        await BgmService.resolveFromData(widget.data);
        _bgmInfo = BgmUtils.readFromData(widget.data);
      }

      final bgmId = _subjectId;
      final results = await Future.wait<Object?>([
        if (bgmId != null && _anibakaData == null)
          getAnimeDetail(bgmId)
        else
          Future<Object?>.value(_anibakaData),
        if (bgmId != null && _detailData == null)
          getBgmAnimePageDetail(bgmId)
        else
          Future<Object?>.value(_detailData),
        if (_isLoggedIn && bgmId != null)
          CollectionApi.getByBgmId(bgmId)
        else
          Future<Object?>.value(null),
      ]);

      _anibakaData = BgmUtils.asMap(results[0]);
      _detailData = BgmUtils.asMap(results[1]);
      if (_detailData != null) widget.data['bgmDetailData'] = _detailData;
      _collection = results[2] as AnimeCollection?;
      _rebuildDetail();
    } catch (e) {
      debugPrint('加载番剧详情失败: $e');
    }
    if (!mounted) return;
    setState(() {
      _isDetailLoading = false;
      _isCollectionLoading = false;
    });
  }

  AnimeCollection _buildCollection(int statusValue) {
    return AnimeCollection(
      postId: _validPostId,
      bgmId: _subjectId,
      status: statusValue,
      postTitle: widget.data['title']?.toString() ?? '',
      postCover: _detail.coverUrl,
      bgmImage: _bgmInfo.imageUrl,
      bgmTitle:
          _detailData?['name_cn']?.toString() ??
          _detailData?['name']?.toString() ??
          widget.data['title']?.toString() ??
          '',
    );
  }

  Future<void> _updateCollectionStatus(CollectionStatus status) async {
    if (!_isLoggedIn) {
      showSnackBar('请先登录');
      return;
    }
    if (_isStatusUpdating) return;
    setState(() => _isStatusUpdating = true);

    try {
      if (_collection != null && _collection!.status == status.value) {
        await _deleteCollection();
        return;
      }

      HapticFeedback.mediumImpact();
      final result = await CollectionApi.addOrUpdate(
        _buildCollection(status.value),
      );
      if (result != null && mounted) {
        setState(() => _collection = result);
        showSnackBar('已标记为「${status.label}」');
      } else if (mounted) {
        showSnackBar('操作失败，请重试');
      }
    } catch (e) {
      debugPrint('更新收藏状态失败: $e');
      if (mounted) showSnackBar('操作失败: $e');
    } finally {
      if (mounted) setState(() => _isStatusUpdating = false);
    }
  }

  Future<void> _deleteCollection() async {
    if (_collection == null) return;
    HapticFeedback.mediumImpact();

    final bgmId = _collection!.bgmId ?? _subjectId;
    bool success = false;
    if (bgmId != null) {
      success = await CollectionApi.deleteByBgmId(bgmId);
    } else {
      final postId = _validPostId;
      if (postId != null) {
        success = await CollectionApi.delete(postId);
      }
    }
    if (success && mounted) {
      setState(() => _collection = null);
      showSnackBar('已取消收藏');
    }
  }

  void _handleCollectionTap() {
    if (!_isLoggedIn) {
      showSnackBar('请先登录');
      return;
    }
    if (_collection != null &&
        CollectionStatus.fromValue(_collection!.status) ==
            CollectionStatus.doing) {
      _showCollectionSheet();
      return;
    }
    _updateCollectionStatus(CollectionStatus.doing);
  }

  void _showCollectionSheet() {
    if (!_isLoggedIn) {
      showSnackBar('请先登录');
      return;
    }

    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => CollectionStatusSheet(
        currentStatus: _collection != null
            ? CollectionStatus.fromValue(_collection!.status)
            : null,
        onSelect: (status) {
          Navigator.pop(ctx);
          _updateCollectionStatus(status);
        },
        onRemove: _collection != null
            ? () {
                Navigator.pop(ctx);
                _deleteCollection();
              }
            : null,
      ),
    );
  }

  Future<void> _showSearchBottomSheet() async {
    if (!mounted || _isSearchSheetOpen) return;

    _hasHandledInitialSearchSheet = true;
    _isSearchSheetOpen = true;

    try {
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => VideoSourceSearchSheet(
          title: widget.data['title'] ?? '',
          cover: _detail.coverUrl,
          score: _detail.score,
          scoreCount: _detail.scoreCount > 0 ? _detail.scoreCount : null,
          seedData: _buildVideoSeedData(),
          heroTag: coverHeroTag(widget.data),
          autoMatchMode: false,
          targetEpisodeIndex: _resolveAutoMatchEpisodeIndex(),
        ),
      );
    } finally {
      _isSearchSheetOpen = false;
    }
  }

  Map<String, dynamic> _buildVideoSeedData() {
    return {
      if (_bgmInfo.subjectId != null) 'bgmId': _bgmInfo.subjectId,
      if (_detail.score != null) 'score': _detail.score,
      if (_detail.coverUrl.isNotEmpty) 'bgmImageUrl': _detail.coverUrl,
      if (_detailData != null) 'bgmDetailData': _detailData,
    };
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _textColor => _isDark ? Colors.white : Colors.black;
  Color get _subtitleColor =>
      _isDark ? Colors.white54 : const Color(0xFF8E8E93);
  Color get _cardColor =>
      _isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF2F2F7);
  Color get _dividerColor => _isDark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.05);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    final isWide = MediaQuery.of(context).size.width > 800;
    final tabs = _buildTabs(isWide);
    final surfaceColor = Theme.of(context).scaffoldBackgroundColor;
    final backgroundUrl = isWide ? _detail.backgroundUrl : _detail.coverUrl;

    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: isWide ? 560 : 420,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CachedNetworkImage(
                imageUrl: backgroundUrl,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                memCacheWidth: isWide ? 1280 : 720,
                useOldImageOnUrlChange: true,
                fadeInDuration: Duration.zero,
                fadeOutDuration: Duration.zero,
                errorWidget: (context, url, error) => const SizedBox(),
              ),
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        surfaceColor.withValues(alpha: 0.2),
                        surfaceColor.withValues(alpha: 0.8),
                        surfaceColor,
                      ],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: DefaultTabController(
                length: tabs.length,
                child: NestedScrollView(
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  headerSliverBuilder: (context, innerBoxIsScrolled) {
                    final tabBar = TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      labelColor: _textColor,
                      unselectedLabelColor: _subtitleColor,
                      indicatorColor: _textColor,
                      indicatorWeight: 3,
                      indicatorPadding: const EdgeInsets.only(top: 44),
                      labelPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      labelStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                      dividerColor: Colors.transparent,
                      splashFactory: NoSplash.splashFactory,
                      overlayColor: WidgetStateProperty.all(Colors.transparent),
                      tabs: [for (final tab in tabs) Tab(text: tab.$1)],
                    );

                    return [
                      SliverAppBar(
                        backgroundColor: Colors.transparent,
                        elevation: 0,
                        pinned: false,
                        foregroundColor: Colors.white,
                        title: Text(
                          widget.data['title'] ?? '番剧详情',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                            letterSpacing: -0.5,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                        sliver: SliverToBoxAdapter(
                          child: AnimeDetailHeader(
                            imageUrl: _detail.coverUrl,
                            title: _detail.title,
                            alias: _detail.alias,
                            score: _detail.score,
                            scoreCount: _detail.scoreCount,
                            tags: _detail.tags,
                            updateTime: widget.data['time']?.toString(),
                            category: widget.data['sort']?.toString(),
                            heroTag: coverHeroTag(widget.data),
                            collection: _collection,
                            isCollectionLoading: _isCollectionLoading,
                            onCollectionTap: _handleCollectionTap,
                            onSearchTap: _showSearchBottomSheet,
                          ),
                        ),
                      ),
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _TabBarDelegate(
                          tabBar: tabBar,
                          backgroundColor: surfaceColor,
                          borderColor: _dividerColor,
                          isWide: isWide,
                        ),
                      ),
                    ];
                  },
                  body: Container(
                    color: surfaceColor,
                    child: TabBarView(
                      physics: const BouncingScrollPhysics(),
                      children: [
                        for (final tab in tabs) Builder(builder: tab.$2),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAutoMatchSheet() {
    if (!_isAutoMatching) return const SizedBox.shrink();
    return VideoSourceSearchSheet(
      title: widget.data['title']?.toString() ?? '',
      cover: _detail.coverUrl,
      score: _detail.score,
      seedData: _buildVideoSeedData(),
      autoMatchMode: true,
      headlessMode: true,
      targetEpisodeIndex: _autoMatchTargetEpisodeIndex,
      onMatchFound: _handleAutoMatchFound,
      onMatchFailed: _handleAutoMatchFailed,
    );
  }

  List<(String title, WidgetBuilder builder)> _buildTabs(bool isWide) {
    final tabs = <(String title, WidgetBuilder builder)>[
      (
        '概览',
        (_) {
          final summary = _isDetailLoading
              ? _buildSkeletonGrid(
                  itemCount: 6,
                  columns: 1,
                  itemHeight: 14,
                  spacing: 10,
                )
              : _buildSummarySection(_detail.summary);
          final genresSection = _detail.genres.isEmpty
              ? const SizedBox.shrink()
              : _buildGenresSection(_detail.genres);
          return _wrapTabContent(
            isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: Column(
                          children: [
                            if (_isAutoMatching) ...[
                              _buildAutoMatchSheet(),
                              const SizedBox(height: 24),
                            ],
                            summary,
                            const SizedBox(height: 24),
                            genresSection,
                          ],
                        ),
                      ),
                      if (_detail.infobox.isNotEmpty) ...[
                        const SizedBox(width: 32),
                        Expanded(
                          flex: 1,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: 20,
                              horizontal: 16,
                            ),
                            decoration: BoxDecoration(
                              color: _cardColor,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 20),
                                  child: Text(
                                    '基本信息',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                _buildInfoSection(
                                  _detail.infobox,
                                  isWide: true,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  )
                : Column(
                    children: [
                      if (_isAutoMatching) ...[
                        _buildAutoMatchSheet(),
                        const SizedBox(height: 24),
                      ],
                      summary,
                      const SizedBox(height: 24),
                      genresSection,
                    ],
                  ),
          );
        },
      ),
    ];

    tabs.add((
      '评论',
      (_) => _subjectId != null
          ? AnimeCommentsTab(
              subjectId: _subjectId!,
              initialComments: _initialComments,
              initialTotal: _initialCommentTotal,
              onCommentsChanged: (result) {
                _initialComments = result.$1;
                _initialCommentTotal = result.$2;
                widget.data['bgmComments'] = result.$1;
                widget.data['bgmCommentTotal'] = result.$2;
              },
            )
          : _isDetailLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildEmptySection('暂无评论数据'),
    ));

    if (!isWide) {
      tabs.add((
        '信息',
        (_) => _buildTabSection(
          content: _detail.infobox.isEmpty
              ? null
              : _buildInfoSection(_detail.infobox),
          skeleton: _buildSkeletonGrid(
            itemCount: 6,
            columns: 1,
            itemHeight: 44,
            spacing: 1,
          ),
          emptyText: '暂无基本信息',
        ),
      ));
    }

    if (_detail.backdrops.isNotEmpty || _detail.posters.length > 1) {
      tabs.add(('图集', (_) => _buildGalleryTab()));
    }

    tabs.add((
      '角色',
      (_) => _buildTabSection(
        content: _detail.characters.isEmpty
            ? null
            : CharactersSection(
                characters: _detail.characters,
                onCharacterTap: (character) =>
                    showCharacterDetailSheet(context, character),
              ),
        skeleton: _buildSkeletonGrid(
          itemCount: 0,
          columns: 0,
          itemHeight: 0,
          square: true,
        ),
        emptyText: '暂无角色信息',
      ),
    ));

    final subjectId = _subjectId;
    if (subjectId != null) {
      tabs.add((
        '相关',
        (_) => _wrapTabContent(
          AnimeDetailRelatedSection(
            subjectId: subjectId,
            onAnimeTap: (data) =>
                NavigationService.toPlayer(context, <String, dynamic>{
                  'id': data['bgmId'] ?? 0,
                  'sort': '番剧',
                  'content': '',
                  'tag': '番剧',
                  ...data,
                }, fade: true),
          ),
        ),
      ));
    }

    return tabs;
  }

  Widget _wrapTabContent(Widget child) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
      child: child,
    );
  }

  Widget _buildTabSection({
    required Widget? content,
    required Widget skeleton,
    required String emptyText,
  }) {
    return _wrapTabContent(
      _isDetailLoading ? skeleton : content ?? _buildEmptySection(emptyText),
    );
  }

  Widget _buildEmptySection(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Text(message, style: TextStyle(color: _subtitleColor)),
      ),
    );
  }

  Widget _buildSkeletonGrid({
    required int itemCount,
    required int columns,
    required double itemHeight,
    double spacing = 12,
    bool square = false,
  }) {
    return AppShimmer(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columnCount = columns > 0
                ? columns
                : (constraints.maxWidth / 120).floor().clamp(3, 12);
            final width =
                (constraints.maxWidth - spacing * (columnCount - 1)) /
                columnCount;
            final count = itemCount > 0 ? itemCount : columnCount * 2;
            final color = AppShimmer.defaultBaseColor(Theme.of(context));

            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (var i = 0; i < count; i++)
                  SizedBox(
                    width: width,
                    height: square ? width : itemHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildGenresSection(List<String> genres) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '分类',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: _textColor,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 10,
            children: [
              for (final genre in genres)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _cardColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    genre,
                    style: TextStyle(
                      color: _isDark ? Colors.white70 : const Color(0xFF3A3A3C),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGalleryTab() {
    final backdrops = _detail.backdrops;
    final posters = _detail.posters;
    final imageWidth = MediaQuery.sizeOf(context).width > 800 ? 960 : 720;
    final sectionStyle = TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w800,
      color: _textColor,
      letterSpacing: -0.4,
    );

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        if (backdrops.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text('剧照 / 背景图', style: sectionStyle),
                  );
                }
                final backdrop = backdrops[index - 1];
                final url =
                    BgmUtils.trimmed(backdrop['url']) ??
                    BgmUtils.trimmed(backdrop['thumbnail']) ??
                    '';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CachedNetworkImage(
                        imageUrl: url,
                        fit: BoxFit.cover,
                        memCacheWidth: imageWidth,
                        placeholder: (context, url) => const ShimmerBox(
                          width: double.infinity,
                          height: double.infinity,
                        ),
                        errorWidget: (context, url, error) =>
                            const SizedBox.shrink(),
                      ),
                    ),
                  ),
                );
              }, childCount: backdrops.length + 1),
            ),
          ),
        if (posters.length > 1)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              20,
              backdrops.isEmpty ? 16 : 8,
              20,
              24,
            ),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('海报', style: sectionStyle),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 220,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemExtent: 162,
                      itemCount: posters.length,
                      itemBuilder: (context, index) {
                        final poster = posters[index];
                        final url =
                            BgmUtils.trimmed(poster['url']) ??
                            BgmUtils.trimmed(poster['thumbnail']) ??
                            '';
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: CachedNetworkImage(
                              imageUrl: url,
                              width: 150,
                              height: 220,
                              fit: BoxFit.cover,
                              memCacheWidth: 400,
                              placeholder: (context, url) =>
                                  const ShimmerBox(width: 150, height: 220),
                              errorWidget: (context, url, error) =>
                                  const SizedBox.shrink(),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildInfoSection(
    List<Map<String, dynamic>> infobox, {
    bool isWide = false,
  }) {
    final itemCount = infobox.length < 30 ? infobox.length : 30;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isWide ? 0 : 20),
      child: Column(
        children: [
          for (var i = 0; i < itemCount; i++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 90,
                    child: Text(
                      infobox[i]['key'] as String? ?? '',
                      style: TextStyle(
                        color: _subtitleColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      _formatInfoboxValue(infobox[i]['value']),
                      style: TextStyle(
                        color: _textColor,
                        fontSize: 14,
                        height: 1.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (i < itemCount - 1)
              Divider(
                color: _dividerColor,
                height: 1,
                thickness: 0.5,
                indent: 106,
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummarySection(String summary) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '剧情简介',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: _textColor,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(
            summary,
            style: TextStyle(
              color: _isDark
                  ? Colors.white.withValues(alpha: 0.8)
                  : const Color(0xFF3A3A3C),
              fontSize: 15,
              height: 1.65,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  String _formatInfoboxValue(dynamic value) {
    if (value is String) return value;
    if (value is List) {
      return value
          .map(
            (item) =>
                item is Map ? (item['v'] ?? item).toString() : item.toString(),
          )
          .join('、');
    }
    return value?.toString() ?? '';
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  final Color backgroundColor;
  final Color borderColor;
  final bool isWide;

  _TabBarDelegate({
    required this.tabBar,
    required this.backgroundColor,
    required this.borderColor,
    this.isWide = false,
  });

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: isWide
            ? const BorderRadius.vertical(top: Radius.circular(24))
            : null,
        border: Border(bottom: BorderSide(color: borderColor, width: 0.5)),
      ),
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) {
    return tabBar != oldDelegate.tabBar ||
        backgroundColor != oldDelegate.backgroundColor ||
        borderColor != oldDelegate.borderColor;
  }
}
