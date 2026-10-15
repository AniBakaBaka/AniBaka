import 'package:baka/core/content_filter.dart';
import 'package:baka/models/anime_filter.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/utils/json_values.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/api/anibaka_api.dart';
import 'package:baka/models/anime_detail_view_data.dart';
import 'package:baka/pages/home/home_controller.dart';
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

  final HomeController svc;

  @override
  State<TvHomePage> createState() => _TvHomePageState();
}

class _TvHomePageState extends State<TvHomePage> {
  _TvSection _selectedSection = _TvSection.home;
  final _focusedItem = ValueNotifier<Map?>(null);
  final ScrollController _scrollController = ScrollController();
  final _loadingMore = ValueNotifier(false);
  AnimeFilter? _exhaustedFilter;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _focusedItem.dispose();
    _loadingMore.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMore.value) return;
    if (_exhaustedFilter == widget.svc.filter.value) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 500) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore.value || _exhaustedFilter == widget.svc.filter.value) {
      return;
    }
    _loadingMore.value = true;
    final filter = widget.svc.filter.value;
    try {
      final hasMore = await widget.svc.loadMore();
      if (!hasMore && widget.svc.filter.value == filter) {
        _exhaustedFilter = filter;
      }
    } finally {
      if (mounted) {
        _loadingMore.value = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: contentFilter,
    builder: (context, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
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
      builder: (context, rawItems, _) {
        final items = contentFilter.visibleItems(rawItems);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<Map?>(
              valueListenable: _focusedItem,
              builder: (context, focused, _) {
                final item = focused != null && contentFilter.allows(focused)
                    ? focused
                    : (items.isEmpty ? null : items.first);
                return item == null
                    ? const SizedBox.shrink()
                    : _TvHomeHero(key: ObjectKey(item), item: item);
              },
            ),

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

                            return _TvPosterCard(
                              key: ValueKey(
                                'waterfall_${item['bgmId'] ?? item['id'] ?? index}',
                              ),
                              data: item,
                              autofocus: index == 0,
                              onFocused: () {
                                _focusedItem.value = item;
                                if (index >= items.length - 7) {
                                  _loadMore();
                                }
                              },
                            );
                          }, childCount: items.length),
                        ),

                  SliverToBoxAdapter(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _loadingMore,
                      builder: (_, loading, child) =>
                          loading ? child! : const SizedBox.shrink(),
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
}

class _TvHomeHero extends StatefulWidget {
  const _TvHomeHero({required this.item, super.key});
  final Map item;

  @override
  State<_TvHomeHero> createState() => _TvHomeHeroState();
}

class _TvHomeHeroState extends State<_TvHomeHero> {
  late final _detail = _loadDetail();

  Future<AnimeDetailViewData?> _loadDetail() async {
    final item = widget.item;
    final subjectId = toInt(item['bgmId']);
    if (subjectId == null || subjectId <= 0) return null;
    final data = await Future.wait([
      getBgmSubject(subjectId),
      AniBakaApi.getAnimeDetail(subjectId),
    ]);
    return AnimeDetailViewData.from(
      source: item,
      bgmInfo: BgmInfo(score: toDouble(item['score']), subjectId: subjectId),
      bgm: data[0],
      anibaka: data[1],
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AnimeDetailViewData?>(
    future: _detail,
    builder: (context, snapshot) => _buildHeader(snapshot.data),
  );

  Widget _buildHeader(AnimeDetailViewData? detail) {
    final item = widget.item;

    final title = detail?.title ?? item['title']?.toString() ?? '';
    final scoreNum = detail?.score ?? toDouble(item['score']) ?? 0;
    final scoreText = scoreNum.toStringAsFixed(1);
    final summary = detail?.summary ?? item['summary']?.toString() ?? '';
    final backdropUrl =
        detail?.backgroundUrl ??
        item['backdropUrl']?.toString() ??
        item['bgmImageUrl']?.toString() ??
        item['content']?.toString() ??
        '';
    final logoUrl = detail?.logoUrl ?? item['logoUrl']?.toString() ?? '';
    final rankNum = toInt(item['rank']) ?? 0;

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
                  memCacheWidth: (760 * MediaQuery.devicePixelRatioOf(context))
                      .ceil(),
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
    final text = Text(
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
    if (logoUrl.isEmpty) return text;
    return SizedBox(
      height: 85,
      child: CachedNetworkImage(
        key: ValueKey(logoUrl),
        imageUrl: logoUrl,
        memCacheHeight: (85 * MediaQuery.devicePixelRatioOf(context)).ceil(),
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        errorWidget: (context, url, error) => text,
      ),
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
    required this.onFocused,
    this.autofocus = false,
    super.key,
  });

  final Map data;
  final VoidCallback onFocused;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      borderRadius: BorderRadius.circular(12),
      focusScale: 1.08,
      onFocusChange: (focused) {
        if (focused) onFocused();
      },
      onPressed: () => navigateToDetail(context, data, posIndex: data['index']),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: buildCachedImage(data, double.infinity, double.infinity),
      ),
    );
  }
}
