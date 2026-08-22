import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/api/anibaka_api.dart';
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
  const TvHomePage({required this.svc, super.key});

  final HomeDataService svc;

  @override
  State<TvHomePage> createState() => _TvHomePageState();
}

class _TvHomePageState extends State<TvHomePage> {
  _TvSection _selectedSection = _TvSection.home;
  Map? _focusedItem;
  final ScrollController _scrollController = ScrollController();
  bool _loadingMore = false;
  String? _exhaustedTag;

  int? _detailSubjectId;
  int? _loadingDetailSubjectId;
  int _detailRequest = 0;
  AnimeDetailViewData? _focusedDetail;

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
    final subjectId = BgmUtils.toInt(item['bgmId']);
    if (subjectId == null || subjectId <= 0) return;
    if (_detailSubjectId == subjectId || _loadingDetailSubjectId == subjectId) {
      return;
    }

    _loadingDetailSubjectId = subjectId;
    final request = ++_detailRequest;

    final bgmInfo = BgmInfo(
      score: BgmUtils.toDouble(item['score']),
      subjectId: subjectId,
    );

    () async {
      try {
        final bgmFuture = getBgmSubject(subjectId);
        final anibakaFuture = AniBakaApi.getAnimeDetail(subjectId);
        final detailData = await bgmFuture;
        final anibakaData = await anibakaFuture;
        if (!mounted || request != _detailRequest) return;
        final detail = AnimeDetailViewData.from(
          source: item,
          bgmInfo: bgmInfo,
          anibaka: anibakaData,
          bgm: detailData,
        );
        setState(() {
          _detailSubjectId = subjectId;
          _focusedDetail = detail;
        });
      } catch (error) {
        debugPrint('TV 首页详情加载失败: $error');
      } finally {
        if (request == _detailRequest) {
          _loadingDetailSubjectId = null;
        }
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

              Expanded(child: _buildSelectedPage()),
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
        _buildSideIcon(
          icon: Icons.person_outline_rounded,
          section: _TvSection.mine,
        ),
        const SizedBox(height: 20),
        _buildSideIcon(icon: Icons.search_rounded, section: _TvSection.search),
        const SizedBox(height: 20),
        _buildSideIcon(
          icon: Icons.explore_outlined,
          section: _TvSection.home,
          autofocus: true,
        ),
        const SizedBox(height: 20),
        _buildSideIcon(
          icon: Icons.star_outline_rounded,
          section: _TvSection.favorites,
        ),
        const SizedBox(height: 20),
        _buildSideIcon(
          icon: Icons.settings_outlined,
          section: _TvSection.settings,
        ),
      ],
    );
  }

  Widget _buildSelectedPage() => switch (_selectedSection) {
    _TvSection.mine => const TvMyPage(),
    _TvSection.search => const TvSearchPage(),
    _TvSection.home => _buildFixedHeaderWaterfallView(),
    _TvSection.favorites => const TvFavoritesPage(),
    _TvSection.settings => const TvSettingsPage(),
  };

  Widget _buildSideIcon({
    required IconData icon,
    required _TvSection section,
    bool autofocus = false,
  }) {
    final isSelected = _selectedSection == section;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return TvFocusable(
      autofocus: autofocus,
      onPressed: () {
        if (!isSelected) setState(() => _selectedSection = section);
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
    return ValueListenableBuilder<HomeItems>(
      valueListenable: widget.svc.feed,
      builder: (context, items, _) {
        final currentFocused =
            _focusedItem ?? (items.isNotEmpty ? items.first : null);

        if (currentFocused != null) {
          _loadAnimeDetail(currentFocused);
        }

        final subjectId = BgmUtils.toInt(currentFocused?['bgmId']);
        final detail = subjectId == _detailSubjectId ? _focusedDetail : null;

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
                            final item = items[index];
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

    final title = detail?.title ?? item?['title']?.toString() ?? '';
    final scoreNum = detail?.score ?? BgmUtils.toDouble(item?['score']) ?? 0;
    final scoreText = scoreNum.toStringAsFixed(1);
    final summary = detail?.summary ?? item?['summary']?.toString() ?? '';
    final backdropUrl =
        detail?.backgroundUrl ??
        item?['backdropUrl']?.toString() ??
        item?['bgmImageUrl']?.toString() ??
        item?['content']?.toString() ??
        '';
    final logoUrl = detail?.logoUrl ?? item?['logoUrl']?.toString() ?? '';
    final rankNum = BgmUtils.toInt(item?['rank']) ?? 0;

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
                  memCacheWidth: 1520,
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

                          if (rankNum > 0) ...[
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
          memCacheHeight: 170,
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
}

enum _TvSection { mine, search, home, favorites, settings }

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
