import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/api/post.dart';
import 'package:baka/models/anime_detail_view_data.dart';
import 'package:baka/services/home_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/skeletonizer.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/widgets/platform/tv/tv_my_page.dart';
import 'package:baka/widgets/platform/tv/tv_search_page.dart';
import 'package:baka/widgets/platform/tv/tv_favorites_page.dart';
import 'package:baka/widgets/platform/tv/tv_settings_page.dart';
import 'package:baka/widgets/platform/tv/tv_theme_util.dart';

class TvHomePage extends StatefulWidget {
  const TvHomePage({
    required this.svc,
    required this.onSearchTap,
    required this.onMyPageTap,
    super.key,
  });

  final HomeDataService svc;
  final VoidCallback onSearchTap;
  final VoidCallback onMyPageTap;

  @override
  State<TvHomePage> createState() => _TvHomePageState();
}

class _TvHomePageState extends State<TvHomePage> {
  static const _detailCacheLimit = 24;

  int _selectedNavIndex = 2;
  Map? _focusedItem;
  final ScrollController _scrollController = ScrollController();
  bool _loadingMore = false;
  String? _exhaustedTag;

  final Map<int, AnimeDetailViewData> _detailCache = {};
  final Set<int> _loadingDetails = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMore) return;
    if (_exhaustedTag == widget.svc.tag.value) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 500) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    _loadingMore = true;
    final tag = widget.svc.tag.value;
    try {
      final hasMore = await widget.svc.loadMore();
      if (!hasMore && widget.svc.tag.value == tag) {
        _exhaustedTag = tag;
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingMore = false;
        });
      }
    }
  }

  /// 异步自动预载与详情页完全一致的 AniBaka API 详细数据
  void _loadAnimeDetail(Map item) {
    final rawId = item['bgmId'] ?? item['id'];
    final subjectId = BgmUtils.toInt(rawId);
    if (subjectId == null || subjectId <= 0) return;
    if (_detailCache.containsKey(subjectId) ||
        !_loadingDetails.add(subjectId)) {
      return;
    }

    final bgmInfo = BgmInfo(
      score: BgmUtils.toDouble(item['score']),
      subjectId: subjectId,
    );

    final bgmFuture = getBgmSubject(subjectId);
    final anibakaFuture = getAnimeDetail(subjectId);
    () async {
      try {
        final detailData = await bgmFuture;
        final anibakaData = await anibakaFuture;
        if (!mounted) return;
        final detail = AnimeDetailViewData.from(
          source: item,
          bgmInfo: bgmInfo,
          anibaka: anibakaData,
          bgm: detailData,
        );
        setState(() {
          if (_detailCache.length >= _detailCacheLimit) {
            _detailCache.remove(_detailCache.keys.first);
          }
          _detailCache[subjectId] = detail;
        });
      } catch (_) {
        // 首页保留已有卡片数据，详情预载失败不替换可见内容。
      } finally {
        _loadingDetails.remove(subjectId);
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.tvBgColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 28, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _buildLeftSidebar(),
              ),

              const SizedBox(width: 24),

              Expanded(
                child: IndexedStack(
                  index: _selectedNavIndex,
                  children: [
                    const TvMyPage(),
                    const TvSearchPage(),
                    _buildFixedHeaderWaterfallView(),
                    const TvFavoritesPage(),
                    const TvSettingsPage(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 侧边栏（与 tv_anime_detail 源码 100% 保持一致）
  Widget _buildLeftSidebar() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        _buildSideIcon(icon: Icons.person_outline_rounded, index: 0),
        const SizedBox(height: 20),
        _buildSideIcon(icon: Icons.search_rounded, index: 1),
        const SizedBox(height: 20),
        _buildSideIcon(icon: Icons.explore_outlined, index: 2, autofocus: true),
        const SizedBox(height: 20),
        _buildSideIcon(icon: Icons.star_outline_rounded, index: 3),
        const SizedBox(height: 20),
        _buildSideIcon(icon: Icons.history_rounded, index: 4),
        const SizedBox(height: 20),
        _buildSideIcon(icon: Icons.settings_outlined, index: 5),
      ],
    );
  }

  Widget _buildSideIcon({
    required IconData icon,
    required int index,
    bool autofocus = false,
  }) {
    final isSelected = _selectedNavIndex == index;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return TvFocusable(
      autofocus: autofocus,
      onPressed: () {
        setState(() {
          _selectedNavIndex = index;
        });
      },
      borderRadius: BorderRadius.circular(20),
      focusScale: 1.15,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Icon(
          icon,
          color: isSelected
              ? primaryColor
              : context.tvTextSecondaryColor.withValues(alpha: 0.8),
          size: 22,
        ),
      ),
    );
  }

  /// 主视图：固定顶部 Header 展台 + 下方独立无限瀑布流网格
  Widget _buildFixedHeaderWaterfallView() {
    return ValueListenableBuilder<List<dynamic>>(
      valueListenable: widget.svc.feed,
      builder: (context, items, _) {
        final currentFocused =
            _focusedItem ?? (items.isNotEmpty ? items.first as Map : null);

        if (currentFocused != null) {
          _loadAnimeDetail(currentFocused);
        }

        final rawId = currentFocused?['bgmId'] ?? currentFocused?['id'];
        final subjectId = BgmUtils.toInt(rawId);
        final detail = subjectId != null ? _detailCache[subjectId] : null;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildFixedHeroHeader(currentFocused, detail),

            const SizedBox(height: 8),

            Text(
              '推荐',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
                color: context.tvTextColor,
              ),
            ),
            const SizedBox(height: 10),

            Expanded(
              child: CustomScrollView(
                controller: _scrollController,
                physics: const BouncingScrollPhysics(),
                slivers: [
                  items.isEmpty
                      ? SliverToBoxAdapter(
                          child: AppSkeletonizer(
                            enabled: true,
                            child: GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 7,
                                    crossAxisSpacing: 14,
                                    mainAxisSpacing: 16,
                                    childAspectRatio: 1 / 1.45,
                                  ),
                              itemCount: 14,
                              itemBuilder: (context, index) => Container(
                                decoration: BoxDecoration(
                                  color: Colors.white10,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        )
                      : SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 7,
                                crossAxisSpacing: 14,
                                mainAxisSpacing: 16,
                                childAspectRatio: 1 / 1.45,
                              ),
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final item = items[index] as Map;
                            final isFocused = (currentFocused == item);

                            return _TvPosterCard(
                              key: ValueKey(
                                'waterfall_${item['bgmId'] ?? item['id'] ?? index}',
                              ),
                              data: item,
                              isSelected: isFocused,
                              autofocus: index == 0,
                              onFocused: () {
                                if (_focusedItem != item) {
                                  setState(() {
                                    _focusedItem = item;
                                  });
                                }
                                if (index >= items.length - 7) {
                                  _loadMore();
                                }
                              },
                            );
                          }, childCount: items.length),
                        ),

                  if (_loadingMore)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                  const SliverToBoxAdapter(child: SizedBox(height: 40)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 固定顶部的 Hero 展台：展示区调大至 370px，背景图主导扩大至 760px，信息更靠左
  Widget _buildFixedHeroHeader(Map? item, AnimeDetailViewData? detail) {
    if (item == null && detail == null) return const SizedBox.shrink();

    final title = detail?.title ?? item?['title']?.toString() ?? '你的名字。';
    final scoreNum = detail?.score ?? _getScoreNumber(item);
    final scoreText = scoreNum.toStringAsFixed(1);
    final summary = (detail?.summary != null && detail!.summary.isNotEmpty)
        ? detail.summary
        : _getSummaryText(item);
    final backdropUrl = detail?.backgroundUrl ?? _getBackdropUrl(item);
    final logoUrl = detail?.logoUrl ?? _getLogoUrl(item);
    final rankNum = item?['rank'] ?? item?['ranking'] ?? 1;

    return SizedBox(
      height: 370,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdropUrl.isNotEmpty)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: 760,
              child: ClipRRect(
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
                child: CachedNetworkImage(
                  key: ValueKey(backdropUrl),
                  imageUrl: backdropUrl,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  width: double.infinity,
                  height: double.infinity,
                  fadeInDuration: const Duration(milliseconds: 300),
                  fadeOutDuration: const Duration(milliseconds: 300),
                  errorWidget: (context, url, error) => const SizedBox.shrink(),
                ),
              ),
            ),

          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    context.tvBgColor,
                    context.tvBgColor.withValues(alpha: 0.88),
                    context.tvBgColor.withValues(alpha: 0.15),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.35, 0.65, 1.0],
                ),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTitleOrLogo(title, logoUrl),

                      const SizedBox(height: 14),

                      if (summary.isNotEmpty)
                        Text(
                          summary,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.tvTextSecondaryColor.withValues(
                              alpha: 0.9,
                            ),
                            fontSize: 15,
                            height: 1.5,
                          ),
                        ),

                      const Spacer(),

                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            scoreText,
                            style: const TextStyle(
                              color: Color(0xFFFFB300),
                              fontSize: 42,
                              fontWeight: FontWeight.w900,
                              height: 1.0,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '/10',
                            style: TextStyle(
                              color: const Color(
                                0xFFFFB300,
                              ).withValues(alpha: 0.7),
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 12),

                          _buildStarRating(scoreNum),

                          const SizedBox(width: 28),

                          Text(
                            'Bangumi #$rankNum',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const Expanded(flex: 5, child: SizedBox.expand()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitleOrLogo(String title, String logoUrl) {
    if (logoUrl.isNotEmpty) {
      return Container(
        height: 85,
        alignment: Alignment.centerLeft,
        child: CachedNetworkImage(
          key: ValueKey(logoUrl),
          imageUrl: logoUrl,
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          errorWidget: (context, url, error) => Text(
            title,
            style: TextStyle(
              color: context.tvTextColor,
              fontSize: 44,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              height: 1.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    return Text(
      title,
      style: TextStyle(
        color: context.tvTextColor,
        fontSize: 44,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.5,
        height: 1.1,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildStarRating(double score) {
    final stars = (score / 2.0).clamp(0.0, 5.0);
    final fullStars = stars.floor();
    final hasHalf = (stars - fullStars) >= 0.5;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (index) {
        if (index < fullStars) {
          return const Icon(
            Icons.star_rounded,
            color: Color(0xFFFFB300),
            size: 20,
          );
        } else if (index == fullStars && hasHalf) {
          return const Icon(
            Icons.star_half_rounded,
            color: Color(0xFFFFB300),
            size: 20,
          );
        } else {
          return const Icon(
            Icons.star_outline_rounded,
            color: Color(0xFFFFB300),
            size: 20,
          );
        }
      }),
    );
  }

  double _getScoreNumber(Map? item) {
    if (item == null) return 8.1;
    final score = item['score'] ?? item['rating']?['score'];
    final num = BgmUtils.toDouble(score);
    return (num != null && num > 0) ? num : 8.1;
  }

  String _getSummaryText(Map? item) {
    if (item == null) return '';
    final summary =
        item['summary'] ??
        item['content'] ??
        item['desc'] ??
        item['description'];
    if (summary != null && summary.toString().isNotEmpty) {
      final raw = summary.toString();
      final cut = raw.indexOf('>');
      final clean = cut != -1 ? raw.substring(cut + 1).trim() : raw.trim();
      return clean;
    }
    return '';
  }

  String _getBackdropUrl(Map? item) {
    if (item == null) return '';
    final explicitBackdrop =
        item['backgroundUrl'] ??
        item['backdrop'] ??
        item['images']?['backdrops'];
    if (explicitBackdrop != null && explicitBackdrop.toString().isNotEmpty) {
      if (explicitBackdrop is List && explicitBackdrop.isNotEmpty) {
        return explicitBackdrop.first.toString();
      }
      return explicitBackdrop.toString();
    }

    final resolved = BgmUtils.resolveCoverImage(item);
    if (resolved != null && resolved.isNotEmpty) return resolved;

    return item['cover']?.toString() ?? '';
  }

  String _getLogoUrl(Map? item) {
    if (item == null) return '';
    final logo = item['logoUrl'] ?? item['logo'] ?? item['images']?['logo'];
    if (logo != null && logo.toString().isNotEmpty) {
      if (logo is List && logo.isNotEmpty) return logo.first.toString();
      return logo.toString();
    }
    return '';
  }
}

class _TvPosterCard extends StatelessWidget {
  const _TvPosterCard({
    required this.data,
    required this.isSelected,
    required this.onFocused,
    this.autofocus = false,
    super.key,
  });

  final Map data;
  final bool isSelected;
  final VoidCallback onFocused;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return TvFocusable(
      autofocus: autofocus,
      borderRadius: BorderRadius.circular(12),
      focusScale: 1.08,
      onFocusChange: (focused) {
        if (focused) onFocused();
      },
      onPressed: () => navigateToDetail(context, data, posIndex: data['index']),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: isSelected
              ? Border.all(color: primaryColor, width: 2.5)
              : Border.all(
                  color: Colors.white.withValues(alpha: 0.1),
                  width: 1,
                ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: primaryColor.withValues(alpha: 0.4),
                    blurRadius: 16,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: buildCachedImage(data, double.infinity, double.infinity),
        ),
      ),
    );
  }
}
