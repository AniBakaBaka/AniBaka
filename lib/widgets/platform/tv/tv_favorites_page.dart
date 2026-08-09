import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/models/collection.dart';
import 'package:baka/services/collection_service.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/skeletonizer.dart';

class TvFavoritesPage extends StatefulWidget {
  const TvFavoritesPage({super.key});

  @override
  State<TvFavoritesPage> createState() => _TvFavoritesPageState();
}

class _TvFavoritesPageState extends State<TvFavoritesPage> {
  bool _isLoading = true;
  List<AnimeCollection> _allCollections = [];
  int _selectedTabStatus = 3; // 默认：3 (在看)。1:想看, 2:看过, 3:在看, 4:搁置/抛弃

  final List<({int statusValue, String label, IconData icon})> _tabs = [
    (statusValue: 3, label: '在看', icon: Icons.play_circle_outline_rounded),
    (statusValue: 1, label: '想看', icon: Icons.favorite_border_rounded),
    (statusValue: 2, label: '看过', icon: Icons.check_circle_outline_rounded),
    (statusValue: 4, label: '已搁置', icon: Icons.pause_circle_outline_rounded),
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final data = await CollectionService.getAll(refreshBangumi: true);
      if (mounted) {
        setState(() {
          _allCollections = data;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('加载追番列表错误: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<AnimeCollection> get _filteredCollections {
    return _allCollections.where((item) {
      if (_selectedTabStatus == 4) {
        return item.status == 4 || item.status == 5;
      }
      return item.status == _selectedTabStatus;
    }).toList();
  }

  void _onTabPressed(int status) {
    if (_selectedTabStatus == status) return;
    setState(() {
      _selectedTabStatus = status;
    });
  }

  void _openDetail(AnimeCollection item) {
    final data = <String, dynamic>{
      'title': item.displayTitle,
      'bgmId': item.bgmId,
      'postId': item.postId,
      'cover': item.displayCover,
      'bgmImageUrl': item.bgmImage,
      'score': item.bgmRating,
    };
    navigateToDetail(context, data);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredCollections;

    return Focus(
      canRequestFocus: false,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.goBack)) {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.ignored;
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.star_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Text(
                  '我的追番',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: context.tvTextColor,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                TvFocusable(
                  onPressed: _loadData,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: context.tvHighlightColor(0.08),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.refresh_rounded,
                          size: 18,
                          color: context.tvTextColor,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '同步云端',
                          style: TextStyle(
                            fontSize: 14,
                            color: context.tvTextColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            Row(
              children: _tabs.map((tab) {
                final isSelected = _selectedTabStatus == tab.statusValue;
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: TvFocusableChip(
                    label: tab.label,
                    icon: tab.icon,
                    isSelected: isSelected,
                    onPressed: () => _onTabPressed(tab.statusValue),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),

            Expanded(
              child: _isLoading
                  ? _buildSkeletonGrid()
                  : filtered.isEmpty
                      ? _buildEmptyView()
                      : FocusTraversalGroup(
                          policy: ReadingOrderTraversalPolicy(),
                          child: GridView.builder(
                            physics: const BouncingScrollPhysics(),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 6,
                              childAspectRatio: 0.55,
                              crossAxisSpacing: 16,
                              mainAxisSpacing: 24,
                            ),
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final item = filtered[index];
                              return _TvFavoriteCard(
                                key: ValueKey('fav_${item.bgmId ?? item.postId ?? index}'),
                                item: item,
                                onPressed: () => _openDetail(item),
                              );
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSkeletonGrid() {
    return AppSkeletonizer(
      enabled: true,
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 6,
          childAspectRatio: 0.55,
          crossAxisSpacing: 16,
          mainAxisSpacing: 24,
        ),
        itemCount: 12,
        itemBuilder: (context, index) => Container(
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.star_outline_rounded,
            color: context.tvTextHintColor,
            size: 64,
          ),
          const SizedBox(height: 16),
          Text(
            '这里空空如也，快去添加收藏吧',
            style: TextStyle(
              color: context.tvTextHintColor,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}

class _TvFavoriteCard extends StatelessWidget {
  final AnimeCollection item;
  final VoidCallback onPressed;

  const _TvFavoriteCard({
    required this.item,
    required this.onPressed,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final rating = item.bgmRating;

    return TvFocusable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  buildNetworkImage(
                    item.displayCover,
                    double.infinity,
                    double.infinity,
                  ),
                  if (item.epWatched != null && item.epWatched! > 0)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: context.tvShadowColor(0.8),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '看到第${item.epWatched}集',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  if (rating != null && rating > 0)
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: context.tvShadowColor(0.8),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.star,
                              color: Colors.amber,
                              size: 12,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              rating.toStringAsFixed(1),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            item.displayTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.tvTextColor,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}
