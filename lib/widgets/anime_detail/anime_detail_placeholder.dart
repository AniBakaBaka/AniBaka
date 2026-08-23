import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/api/anibaka_api.dart';
import 'package:baka/models/anime_detail_view_data.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/services/collection_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/services/navigation_service.dart';

import 'dart:async';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:baka/widgets/common/scale_button.dart';

import 'package:baka/widgets/anime_detail/collection_sheet.dart';
import 'package:baka/widgets/anime_detail/character_detail_sheet.dart';
import 'package:baka/widgets/anime_detail/anime_detail_header.dart';
import 'package:baka/widgets/anime_detail/anime_detail_comments.dart';
import 'package:baka/widgets/anime_detail/anime_detail_related.dart';

class AnimeDetailPlaceholder extends StatefulWidget {
  final Map<String, dynamic> data;

  const AnimeDetailPlaceholder({required this.data, super.key});

  @override
  State<AnimeDetailPlaceholder> createState() => _AnimeDetailPlaceholderState();
}

class _AnimeDetailPlaceholderState extends State<AnimeDetailPlaceholder> {
  late final int? _postId;

  Animation<double>? _routeAnimation;
  bool _initialRouteTransitionFinished = false;

  late List<Map<String, dynamic>> _initialComments;
  late int _initialCommentTotal;

  AnimeCollection? _collection;
  bool _isCollectionLoading = false;
  bool _isStatusUpdating = false;

  late BgmInfo _bgmInfo;
  Map<String, dynamic>? _detailData;
  Map<String, dynamic>? _anibakaData;
  List<Map<String, dynamic>> _characters = const [];
  bool _charactersLoading = false;
  bool _charactersLoaded = false;
  late AnimeDetailViewData _detail;

  int? get _subjectId => _bgmInfo.subjectId;

  int? get _validPostId {
    final postId = _postId;
    return (postId != null && postId > 0) ? postId : null;
  }

  void _rebuildDetail() {
    _bgmInfo = BgmUtils.readFromData(widget.data);
    _detailData = BgmUtils.asMap(widget.data['bgmDetailData']);
    if (!_charactersLoaded) {
      _characters = BgmUtils.asMapList(_detailData?['characters']);
      _charactersLoaded = _characters.isNotEmpty;
    }
    _detail = AnimeDetailViewData.from(
      source: widget.data,
      bgmInfo: _bgmInfo,
      anibaka: _anibakaData,
      bgm: _detailData,
      characters: _characters,
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

    _isCollectionLoading = _subjectId != null;
    _loadInitialData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (!identical(animation, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
      _routeAnimation = animation;
      animation?.addStatusListener(_handleRouteAnimationStatus);
    }
    if (animation == null || animation.status == AnimationStatus.completed) {
      _initialRouteTransitionFinished = true;
    }
  }

  void _handleRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed ||
        _initialRouteTransitionFinished ||
        !mounted) {
      return;
    }
    setState(() => _initialRouteTransitionFinished = true);
  }

  void _updateInitialState(VoidCallback update) {
    if (!mounted) return;
    if (_initialRouteTransitionFinished) {
      setState(update);
    } else {
      // Keep the Hero destination stable while the route is moving. The
      // completed animation listener publishes accumulated results together.
      update();
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
    super.dispose();
  }

  void _startWatching() {
    if (_detail.logoUrl.isNotEmpty) {
      widget.data['logoUrl'] = _detail.logoUrl;
    }
    NavigationService.toPlayer(context, widget.data, autoMatch: true);
  }

  Future<void> _loadInitialData() async {
    // Phase 1: 解析 bgmId（若未知）
    if (_subjectId == null) {
      try {
        await BgmService.resolveFromData(widget.data);
        _updateInitialState(() {
          _bgmInfo = BgmUtils.readFromData(widget.data);
          _rebuildDetail();
        });
      } catch (e) {
        debugPrint('解析bgmId失败: $e');
      }
    }

    final bgmId = _subjectId;
    if (bgmId == null) {
      _updateInitialState(() => _isCollectionLoading = false);
      return;
    }

    // Phase 2: 并发启动所有请求，各自独立更新 UI
    // AniBaka 自有 API（含 overview）
    if (_anibakaData == null) {
      AniBakaApi.getAnimeDetail(bgmId)
          .then((data) {
            _updateInitialState(() {
              _anibakaData = BgmUtils.asMap(data);
              _rebuildDetail();
            });
          })
          .catchError((_) {});
    }

    // BGM 主条目；角色数据只在用户打开角色页时请求。
    if (_detailData == null) {
      getBgmSubject(bgmId)
          .then((data) {
            _updateInitialState(() {
              _detailData = data;
              widget.data['bgmDetailData'] = data;
              _rebuildDetail();
            });
          })
          .catchError((_) {});
    }

    // Phase 3: 收藏状态独立加载
    CollectionService.getByBgmId(bgmId)
        .then((collection) {
          _updateInitialState(() {
            _collection = collection;
            _isCollectionLoading = false;
          });
        })
        .catchError((_) {
          _updateInitialState(() => _isCollectionLoading = false);
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
      bgmTitle: _detail.bgmTitle,
    );
  }

  Future<void> _loadCharacters() async {
    final subjectId = _subjectId;
    if (subjectId == null || _charactersLoaded || _charactersLoading) return;
    setState(() => _charactersLoading = true);
    try {
      final characters = await getBgmCharacters(subjectId);
      if (!mounted) return;
      setState(() {
        _characters = characters;
        _charactersLoaded = true;
        _charactersLoading = false;
        _rebuildDetail();
      });
    } catch (error) {
      debugPrint('获取Bangumi角色失败: $error');
      if (mounted) setState(() => _charactersLoading = false);
    }
  }

  Future<void> _updateCollectionStatus(CollectionStatus status) async {
    if (_isStatusUpdating) return;
    setState(() => _isStatusUpdating = true);

    try {
      if (_collection != null && _collection!.status == status.value) {
        await _deleteCollection();
        return;
      }

      HapticFeedback.mediumImpact();
      final result = await CollectionService.addOrUpdate(
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
    try {
      final bgmId = _collection!.bgmId ?? _subjectId;
      bool success = false;
      if (bgmId != null) {
        success = await CollectionService.deleteByBgmId(bgmId);
      } else {
        final postId = _validPostId;
        if (postId != null) {
          success = await CollectionService.delete(postId);
        }
      }
      if (success && mounted) {
        setState(() => _collection = null);
        showSnackBar('已取消收藏');
      }
    } catch (e) {
      if (mounted) showSnackBar(e.toString(), isError: true);
    }
  }

  void _handleCollectionTap() {
    if (_collection != null &&
        CollectionStatus.fromValue(_collection!.status) ==
            CollectionStatus.doing) {
      _showCollectionSheet();
      return;
    }
    _updateCollectionStatus(CollectionStatus.doing);
  }

  void _showCollectionSheet() {
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
              if (_initialRouteTransitionFinished && backgroundUrl.isNotEmpty)
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
                      onTap: (index) {
                        if (tabs[index].$1 == '角色') {
                          unawaited(_loadCharacters());
                        }
                      },
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
                            detail: _detail,
                            updateTime: widget.data['time']?.toString(),
                            category: widget.data['sort']?.toString(),
                            heroTag: coverHeroTag(widget.data),
                            enableCoverEffects: _initialRouteTransitionFinished,
                            collection: _collection,
                            isCollectionLoading: _isCollectionLoading,
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

  List<(String title, WidgetBuilder builder)> _buildTabs(bool isWide) {
    final tabs = <(String title, WidgetBuilder builder)>[
      (
        '概览',
        (_) {
          final summary = _buildSummarySection(_detail.summary);
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
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [summary],
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
          : _buildEmptySection('暂无评论数据'),
    ));

    if (_detail.infobox.isNotEmpty) {
      tabs.add((
        '信息',
        (_) => _wrapTabContent(
          _detail.infobox.isNotEmpty
              ? _buildInfoSection(_detail.infobox)
              : _buildEmptySection('暂无基本信息'),
        ),
      ));
    }

    if (_detail.backdrops.isNotEmpty || _detail.posters.length > 1) {
      tabs.add(('图集', (_) => _buildGalleryTab()));
    }

    tabs.add((
      '角色',
      (_) => _wrapTabContent(
        _charactersLoading
            ? const Center(child: CircularProgressIndicator())
            : _detail.characters.isEmpty
            ? _buildEmptySection('暂无角色信息')
            : CharactersSection(
                characters: _detail.characters,
                onCharacterTap: (character) =>
                    showCharacterDetailSheet(context, character),
              ),
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

  Widget _buildEmptySection(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Text(message, style: TextStyle(color: _subtitleColor)),
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
    final bgmId =
        _detail.bgmId ??
        _subjectId ??
        BgmUtils.toInt(widget.data['bgmId']) ??
        BgmUtils.toInt(widget.data['id']);
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
      final tmdbUrl = tmdbId.contains('/')
          ? 'https://www.themoviedb.org/$tmdbId'
          : 'https://www.themoviedb.org/tv/$tmdbId';
      links.add(('TMDB', tmdbUrl));
    }

    if (tvdbId != null && tvdbId.isNotEmpty) {
      final tvdbUrl = (tvdbId.contains('/') || tvdbId.startsWith('series/'))
          ? 'https://thetvdb.com/$tvdbId'
          : 'https://thetvdb.com/dereferer/series/$tvdbId';
      links.add(('TVDB', tvdbUrl));
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

    return links.map((link) {
      final (label, url) = link;
      return ScaleButton(
        onTap: () {
          HapticFeedback.lightImpact();
          unawaited(launchUrlString(url, mode: LaunchMode.externalApplication));
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
      );
    }).toList();
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
