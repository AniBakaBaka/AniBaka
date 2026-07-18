import 'package:baka/services/home_service.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/shimmer.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'package:flutter/material.dart';

int _columnsFor(double width) {
  if (width > 1600) return 7;
  if (width > 1200) return 6;
  if (width > 900) return 5;
  if (width > 600) return 4;
  return 3;
}

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
  final ScrollController _scrollController = ScrollController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _loadingMore = false;
  String? _exhaustedTag;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMore) return;
    if (_exhaustedTag == widget.svc.tag.value) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    _loadingMore = true;
    final tag = widget.svc.tag.value;
    try {
      final hasMore = await widget.svc.loadMore();
      if (!hasMore && widget.svc.tag.value == tag) _exhaustedTag = tag;
    } finally {
      _loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.svc;
    return Scaffold(
      backgroundColor: context.tvBgColor,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: svc.tag,
              builder: (context, tag, _) => _TvTopBar(
                tag: tag,
                tags: svc.displayTags,
                searchFocusNode: _searchFocusNode,
                onTagChanged: (value) {
                  _exhaustedTag = null;
                  svc.selectTag(value);
                },
                onSearchTap: widget.onSearchTap,
                onMyPageTap: widget.onMyPageTap,
              ),
            ),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: svc.tag,
                builder: (context, tag, _) =>
                    ValueListenableBuilder<List<dynamic>>(
                      valueListenable: svc.feed,
                      builder: (context, items, _) {
                        if (items.isEmpty) return const _TvHomeSkeleton();
                        return _buildContentGrid(tag, items);
                      },
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContentGrid(String title, List<dynamic> items) {
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = _columnsFor(constraints.maxWidth - 96);
          return CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(48, 24, 48, 16),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Container(
                        width: 4,
                        height: 24,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: context.tvTextColor,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 20,
                    childAspectRatio: 1 / 1.45,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final item = items[index] as Map;
                      return _TvAnimeCard(
                        key: ValueKey(
                          'feed_${item['bgmId'] ?? item['id'] ?? index}',
                        ),
                        data: item,
                        autofocus: index == 0,
                      );
                    },
                    childCount: items.length,
                    addAutomaticKeepAlives: false,
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 60)),
            ],
          );
        },
      ),
    );
  }
}

class _TvTopBar extends StatelessWidget {
  const _TvTopBar({
    required this.tag,
    required this.tags,
    required this.searchFocusNode,
    required this.onTagChanged,
    required this.onSearchTap,
    required this.onMyPageTap,
  });

  final String tag;
  final List<String> tags;
  final FocusNode searchFocusNode;
  final ValueChanged<String> onTagChanged;
  final VoidCallback onSearchTap;
  final VoidCallback onMyPageTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Row(
        children: [
          Text(
            'Baka',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: context.tvTextColor,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(width: 40),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final t in tags)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: TvFocusableChip(
                        label: t,
                        isSelected: tag == t,
                        onPressed: () => onTagChanged(t),
                        fontSize: 15,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          _buildActionChip(
            context,
            icon: Icons.search,
            label: '搜索',
            focusNode: searchFocusNode,
            onPressed: onSearchTap,
          ),
          const SizedBox(width: 12),
          _buildActionChip(
            context,
            icon: Icons.person_outline,
            label: '我的',
            onPressed: onMyPageTap,
          ),
        ],
      ),
    );
  }

  Widget _buildActionChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    FocusNode? focusNode,
  }) {
    return TvFocusable(
      focusNode: focusNode,
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(24),
      enableScale: false,
      enableGlow: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: context.tvHighlightColor(0.1),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: context.tvTextSecondaryColor, size: 22),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: context.tvTextSecondaryColor,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvHomeSkeleton extends StatelessWidget {
  const _TvHomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(48, 24, 48, 60),
      physics: const NeverScrollableScrollPhysics(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = _columnsFor(constraints.maxWidth);
          final cardWidth =
              (constraints.maxWidth - (columns - 1) * 16) / columns;
          final cardHeight = cardWidth * 1.45;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  ShimmerBox(
                    width: 4,
                    height: 24,
                    borderRadius: BorderRadius.all(Radius.circular(2)),
                  ),
                  SizedBox(width: 12),
                  ShimmerBox(
                    width: 120,
                    height: 24,
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 20,
                children: [
                  for (var index = 0; index < columns * 2; index++)
                    SizedBox(
                      width: cardWidth,
                      height: cardHeight,
                      child: const _TvPosterSkeletonCard(),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TvPosterSkeletonCard extends StatelessWidget {
  const _TvPosterSkeletonCard();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: [
        ShimmerBox(borderRadius: BorderRadius.all(Radius.circular(12))),
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShimmerTextLine(height: 15, widthFactor: 0.8),
              SizedBox(height: 8),
              ShimmerTextLine(height: 12, widthFactor: 0.48),
            ],
          ),
        ),
      ],
    );
  }
}

class _TvAnimeCard extends StatelessWidget {
  const _TvAnimeCard({required this.data, this.autofocus = false, super.key});

  final Map data;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final title = data['title']?.toString() ?? '';
    final subtitle = data['subtitle']?.toString() ?? '';
    return TvFocusable(
      autofocus: autofocus,
      borderRadius: BorderRadius.circular(12),
      focusScale: 1.08,
      onPressed: () => navigateToDetail(context, data, posIndex: data['index']),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: buildCachedImage(data, double.infinity, double.infinity),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(12),
                bottomRight: Radius.circular(12),
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 32, 12, 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, context.tvShadowColor(0.9)],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.tvTextColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.tvHighlightColor(0.7),
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
