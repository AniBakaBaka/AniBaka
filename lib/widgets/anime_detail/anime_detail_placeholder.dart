import 'package:baka/core/content_filter.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/utils/json_values.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/api/anibaka_api.dart';
import 'package:baka/models/anime_detail_view_data.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/app/navigation.dart';

import 'dart:async';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:baka/widgets/common/scale_button.dart';

import 'package:baka/widgets/anime_detail/collection_sheet.dart';
import 'package:baka/widgets/anime_detail/character_detail_sheet.dart';
import 'package:baka/widgets/anime_detail/anime_detail_header.dart';
import 'package:baka/widgets/anime_detail/anime_detail_background.dart';
import 'package:baka/widgets/anime_detail/anime_detail_comments.dart';
import 'package:baka/widgets/anime_detail/anime_detail_related.dart';

class AnimeDetailPlaceholder extends StatefulWidget {
  final Map<String, dynamic> data;

  const AnimeDetailPlaceholder({required this.data, super.key});

  @override
  State<AnimeDetailPlaceholder> createState() => _AnimeDetailPlaceholderState();
}

class _AnimeDetailPlaceholderState extends State<AnimeDetailPlaceholder> {
  int _loadGeneration = 0;
  int _collectionRevision = 0;

  Animation<double>? _routeAnimation;
  ModalRoute<dynamic>? _route;
  bool _initialRouteTransitionFinished = false;
  bool _detailPending = false;

  bool get _canPublishInitialUpdates =>
      _route == null ||
      (_route!.isCurrent &&
          !_route!.offstage &&
          (_routeAnimation == null || _routeAnimation!.isCompleted));

  void _publishInitialUpdates() {
    _initialRouteTransitionFinished = true;
    if (_detailPending) {
      _rebuildDetail();
      _detailPending = false;
    }
  }

  final _collection = ValueNotifier<AnimeCollection?>(null);
  bool _isStatusUpdating = false;

  late BgmInfo _bgmInfo;
  Map<String, dynamic>? _detailData;
  Map<String, dynamic>? _anibakaData;
  late AnimeDetailViewData _detail;

  int? get _subjectId => _bgmInfo.subjectId;
  int? get _postId => toInt(widget.data['id']);

  int? get _validPostId => AnimeCollection.postIdFrom(widget.data);

  void _rebuildDetail() {
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
    _initializeData(BgmInfo.fromData(widget.data));
  }

  @override
  void didUpdateWidget(covariant AnimeDetailPlaceholder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.data, widget.data)) return;
    final bgmInfo = BgmInfo.fromData(widget.data);
    final oldBgmId = BgmInfo.fromData(oldWidget.data).subjectId;
    if (_postId != toInt(oldWidget.data['id']) ||
        bgmInfo.subjectId != oldBgmId ||
        (_validPostId == null &&
            bgmInfo.subjectId == null &&
            oldWidget.data['title'] != widget.data['title'])) {
      _initializeData(bgmInfo);
      return;
    }
    _bgmInfo = BgmInfo(
      subjectId: bgmInfo.subjectId ?? _subjectId,
      score: bgmInfo.score ?? _bgmInfo.score,
      imageUrl: bgmInfo.imageUrl ?? _bgmInfo.imageUrl,
    );
    _detailData =
        widget.data['bgmDetailData'] as Map<String, dynamic>? ?? _detailData;
    _rebuildDetail();
  }

  void _initializeData(BgmInfo bgmInfo) {
    _loadGeneration++;
    _collectionRevision = 0;
    _detailPending = false;
    _collection.value = null;
    _isStatusUpdating = false;
    // Hydrate from the API-owned cache before constructing the first frame.
    // A warm request still returns a Future; queuing its .then callback behind
    // the transition would incorrectly animate default content for 320 ms.
    final subjectId = bgmInfo.subjectId;
    _anibakaData = subjectId == null
        ? null
        : AniBakaApi.peekAnimeDetail(subjectId);
    _detailData =
        (widget.data['bgmDetailData'] as Map<String, dynamic>?) ??
        (subjectId == null ? null : peekBgmSubject(subjectId));
    _bgmInfo = bgmInfo;
    _rebuildDetail();

    unawaited(_loadInitialData(_loadGeneration));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = _route = ModalRoute.of(context);
    final animation = route?.animation;
    if (!identical(animation, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
      _routeAnimation = animation;
      animation?.addStatusListener(_handleRouteAnimationStatus);
    }
    // Navigator temporarily reports a completed animation while laying the
    // destination out offstage. That is not the end of the visible transition.
    if (_canPublishInitialUpdates) _publishInitialUpdates();
  }

  void _handleRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed ||
        !_canPublishInitialUpdates ||
        (_initialRouteTransitionFinished && !_detailPending) ||
        !mounted) {
      return;
    }
    setState(_publishInitialUpdates);
  }

  void _refreshDetail() {
    if (_initialRouteTransitionFinished && _canPublishInitialUpdates) {
      setState(_rebuildDetail);
    } else {
      // Build one view model from the latest responses when the route settles.
      _detailPending = true;
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
    _collection.dispose();
    super.dispose();
  }

  void _startWatching() {
    NavigationService.toPlayback(
      context,
      PlaybackRequest.fromMap(
        widget.data,
        metadataUpdates: {
          if (_subjectId != null) 'bgmId': _subjectId,
          if (_bgmInfo.score != null) 'score': _bgmInfo.score,
          if (_bgmInfo.imageUrl != null) 'bgmImageUrl': _bgmInfo.imageUrl,
          if (_detailData != null) 'bgmDetailData': _detailData,
          if (_detail.logoUrl.isNotEmpty) 'logoUrl': _detail.logoUrl,
        },
      ),
    );
  }

  Future<void> _loadInitialData(int generation) async {
    var resolved = _bgmInfo;
    final collectionRevision = _collectionRevision;
    // Phase 1: 解析 bgmId（若未知）
    if (_subjectId == null) {
      try {
        resolved = await resolveBgmFromData(widget.data);
        if (!mounted || generation != _loadGeneration) return;
        _bgmInfo = resolved;
        _refreshDetail();
      } catch (e) {
        debugPrint('解析bgmId失败: $e');
      }
    }

    // Subject resolution is available to requests even while its UI update is
    // queued until the transition settles.
    if (!mounted || generation != _loadGeneration) return;
    final bgmId = resolved.subjectId;
    if (bgmId == null) return;

    // Phase 2: 并发启动所有请求，各自独立更新 UI
    // AniBaka 自有 API（含 overview）。空响应或失败时保持无数据，页面回落到
    // BGM 简介与封面。
    if (_anibakaData == null) {
      AniBakaApi.getAnimeDetail(bgmId)
          .then((data) {
            if (!mounted || generation != _loadGeneration || data == null) {
              return;
            }
            _anibakaData = data;
            _refreshDetail();
          })
          .catchError((Object e) {
            debugPrint('获取 AniBaka 详情失败: $e');
          });
    }

    // BGM 主条目；角色数据只在用户打开角色页时请求。
    if (_detailData == null) {
      getBgmSubject(bgmId)
          .then((data) {
            if (!mounted || generation != _loadGeneration) return;
            _detailData = data;
            _refreshDetail();
          })
          .catchError((Object e) {
            debugPrint('获取 BGM 条目失败: $e');
          });
    }

    // Phase 3: 收藏状态独立加载
    collections
        .getByBgmId(bgmId)
        .then((collection) {
          if (!mounted ||
              generation != _loadGeneration ||
              collectionRevision != _collectionRevision) {
            return;
          }
          _collection.value = collection;
        })
        .catchError((Object e) {
          debugPrint('获取收藏状态失败: $e');
        });
  }

  Future<void> _updateCollectionStatus(CollectionStatus? status) async {
    if (!mounted || _isStatusUpdating) return;
    final collection = _collection.value;
    final removing = status == null || collection?.status == status.value;
    if (removing && collection == null) return;
    final generation = _loadGeneration;
    // This is only a request guard; changing it has no visible UI effect.
    _isStatusUpdating = true;
    HapticFeedback.mediumImpact();

    try {
      if (removing) {
        final bgmId = collection!.bgmId ?? _subjectId;
        final postId = _validPostId;
        final success = bgmId != null
            ? await collections.deleteByBgmId(bgmId)
            : postId != null && await collections.delete(postId);
        if (!mounted || generation != _loadGeneration) return;
        if (success) {
          _collectionRevision++;
          _collection.value = null;
          showSnackBar('已取消收藏');
        }
      } else {
        final result = await collections.addOrUpdate(
          AnimeCollection(
            postId: _validPostId,
            bgmId: _subjectId,
            status: status.value,
            nsfw: _detail.nsfw,
            postTitle: widget.data['title'] as String? ?? '',
            postCover: _detail.coverUrl,
            bgmImage: _bgmInfo.imageUrl,
            bgmTitle: _detail.bgmTitle,
          ),
        );
        if (!mounted || generation != _loadGeneration) return;
        _collectionRevision++;
        _collection.value = result;
        showSnackBar('已标记为「${status.label}」');
      }
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      if (removing) {
        showSnackBar(e.toString(), isError: true);
      } else {
        debugPrint('更新收藏状态失败: $e');
        showSnackBar('操作失败: $e');
      }
    } finally {
      if (generation == _loadGeneration) _isStatusUpdating = false;
    }
  }

  void _handleCollectionTap() {
    if (_collection.value?.status == CollectionStatus.doing.value) {
      _showCollectionSheet();
      return;
    }
    _updateCollectionStatus(CollectionStatus.doing);
  }

  void _showCollectionSheet() {
    final collection = _collection.value;
    final generation = _loadGeneration;
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => CollectionStatusSheet(
        currentStatus: collection != null
            ? CollectionStatus.fromValue(collection.status)
            : null,
        onSelect: (status) {
          Navigator.pop(ctx);
          if (generation == _loadGeneration) _updateCollectionStatus(status);
        },
        onRemove: collection != null
            ? () {
                Navigator.pop(ctx);
                if (generation == _loadGeneration) {
                  _updateCollectionStatus(null);
                }
              }
            : null,
      ),
    );
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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: contentFilter,
    builder: (context, _) => _buildPage(context),
  );

  Widget _buildPage(BuildContext context) {
    if (contentFilter.value && _detail.nsfw) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('已隐藏 NSFW 内容')),
      );
    }
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    final isWide = MediaQuery.sizeOf(context).width > 800;
    final theme = Theme.of(context);
    final platform = theme.platform;
    final useBackdrop =
        isWide &&
        (platform == TargetPlatform.windows ||
            platform == TargetPlatform.macOS ||
            platform == TargetPlatform.linux);
    final tabs = _buildTabs(isWide);
    final surfaceColor = theme.scaffoldBackgroundColor;

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
              AnimeDetailBackground(
                coverUrl: _detail.coverUrl,
                backgroundUrl: useBackdrop
                    ? _detail.backgroundUrl
                    : _detail.coverUrl,
                loadBackground: useBackdrop && _initialRouteTransitionFinished,
                cacheWidth: isWide ? 1280 : 720,
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
                      overlayColor: const WidgetStatePropertyAll(
                        Colors.transparent,
                      ),
                      tabs: [for (final tab in tabs) Tab(text: tab.$1)],
                    );

                    return [
                      SliverAppBar(
                        backgroundColor: Colors.transparent,
                        elevation: 0,
                        pinned: false,
                        foregroundColor: Colors.white,
                        title: Text(
                          _detail.title,
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
                            detail: _detail,
                            updateTime: widget.data['time'] as String?,
                            category: widget.data['sort'] as String?,
                            heroTag: coverHeroTag(widget.data),
                            enableCoverEffects: _initialRouteTransitionFinished,
                            collection: _collection,
                            onCollectionTap: _handleCollectionTap,
                            onSearchTap: _startWatching,
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
                        for (final tab in tabs)
                          Builder(
                            key: PageStorageKey((_postId, _subjectId, tab.$1)),
                            builder: tab.$2,
                          ),
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

  List<(String title, WidgetBuilder builder)> _buildTabs(bool isWide) {
    final tabs = <(String title, WidgetBuilder builder)>[
      (
        '概览',
        (_) {
          final summary = _buildSummarySection(_detail.summary);
          return _wrapTabContent(
            isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 2, child: summary),
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      summary,
                      const SizedBox(height: 24),
                      _detail.genres.isEmpty
                          ? const SizedBox.shrink()
                          : _buildGenresSection(_detail.genres),
                    ],
                  ),
          );
        },
      ),
    ];

    tabs.add((
      '评论',
      (_) => _subjectId != null
          ? AnimeCommentsTab(subjectId: _subjectId!)
          : _buildEmptySection('暂无评论数据'),
    ));

    if (_detail.infobox.isNotEmpty) {
      tabs.add((
        '信息',
        (_) => _wrapTabContent(_buildInfoSection(_detail.infobox)),
      ));
    }

    if (_detail.backdrops.isNotEmpty || _detail.posters.length > 1) {
      tabs.add(('图集', (_) => _buildGalleryTab()));
    }

    tabs.add((
      '角色',
      (_) => _subjectId == null
          ? _buildEmptySection('暂无角色信息')
          : CharactersSection(subjectId: _subjectId!),
    ));

    final subjectId = _subjectId;
    if (subjectId != null) {
      tabs.add((
        '相关',
        (_) => _wrapTabContent(
          AnimeDetailRelatedSection(
            subjectId: subjectId,
            onAnimeTap: (data) =>
                NavigationService.toPlayer(context, data, fade: true),
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

  Widget _buildEmptySection(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Text(message, style: TextStyle(color: _subtitleColor)),
      ),
    );
  }

  Widget _buildGenresSection(List<String> genres) {
    final cardColor = _cardColor;
    final genreStyle = TextStyle(
      color: _isDark ? Colors.white70 : const Color(0xFF3A3A3C),
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
    );
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
                    color: cardColor,
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                  ),
                  child: Text(genre, style: genreStyle),
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
                final url = backdrops[index - 1];
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
                        placeholder: (context, url) => Container(
                          width: double.infinity,
                          height: double.infinity,
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
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
                        final url = posters[index];
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
                              placeholder: (context, url) => Container(
                                width: 150,
                                height: 220,
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                              ),
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
    final labelStyle = TextStyle(
      color: _subtitleColor,
      fontSize: 14,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    );
    final valueStyle = TextStyle(
      color: _textColor,
      fontSize: 14,
      height: 1.5,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2,
    );
    final dividerColor = _dividerColor;
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
                    child: Text(infobox[i]['key'] as String, style: labelStyle),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      _formatInfoboxValue(infobox[i]['value']),
                      style: valueStyle,
                    ),
                  ),
                ],
              ),
            ),
            if (i < itemCount - 1)
              Divider(
                color: dividerColor,
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
    final externalLinks = _buildExternalLinks();
    return SizedBox(
      width: double.infinity,
      child: Padding(
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
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white.withValues(alpha: 0.8)
                    : const Color(0xFF3A3A3C),
                fontSize: 15,
                height: 1.65,
                letterSpacing: 0.2,
              ),
            ),
            if (externalLinks.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(
                '外部链接',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: _textColor,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 10, runSpacing: 10, children: externalLinks),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _buildExternalLinks() {
    final bgmId = _subjectId ?? _detail.bgmId;
    final imdbId = _detail.imdbId;
    final tmdbId = _detail.tmdbId;
    final tvdbId = _detail.tvdbId;

    final links = <(String label, String url)>[];

    if (bgmId != null && bgmId > 0) {
      links.add(('Bangumi', 'https://bgm.tv/subject/$bgmId'));
    }

    if (imdbId != null && imdbId.isNotEmpty) {
      final formattedImdb = imdbId.startsWith('tt') ? imdbId : 'tt$imdbId';
      links.add(('IMDb', 'https://www.imdb.com/title/$formattedImdb/'));
    }

    if (tmdbId != null && tmdbId.isNotEmpty) {
      links.add(('TMDB', 'https://www.themoviedb.org/tv/$tmdbId'));
    }

    if (tvdbId != null && tvdbId.isNotEmpty) {
      links.add(('TVDB', 'https://thetvdb.com/dereferer/series/$tvdbId'));
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : const Color(0xFFE5E5EA);
    final textColor = isDark
        ? Colors.white.withValues(alpha: 0.9)
        : const Color(0xFF1C1C1E);
    final iconColor = isDark ? Colors.white70 : const Color(0xFF636366);

    return [
      for (final (label, url) in links)
        ScaleButton(
          onTap: () {
            HapticFeedback.lightImpact();
            unawaited(
              launchUrlString(url, mode: LaunchMode.externalApplication),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.link_rounded, size: 16, color: iconColor),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  String _formatInfoboxValue(dynamic value) => value is String
      ? value
      : (value as List<dynamic>)
            .map((item) => (item as Map<String, dynamic>)['v'] as String)
            .join('、');
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
        borderColor != oldDelegate.borderColor ||
        isWide != oldDelegate.isWide;
  }
}
