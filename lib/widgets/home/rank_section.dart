import 'package:flutter/material.dart';

import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/skeletonizer.dart';

class RankSection extends StatelessWidget {
  static const double _cardWidth = 136;
  static const double _cardAspectRatio = 2 / 3;
  static const double _cardHeight = _cardWidth / _cardAspectRatio;
  static const _goldColor = Color(0xFFFFD700);
  static const _rankNames = ['总榜', '季榜', '月榜', '日榜'];

  final List<Map> items;
  final int selectedIndex;
  final Function(int) onTypeChanged;

  const RankSection({
    required this.items,
    required this.selectedIndex,
    required this.onTypeChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(context),
        SizedBox(
          height: _cardHeight + 42,
          child: items.isEmpty
              ? _buildLoadingCards()
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  itemCount: items.length,
                  itemBuilder: (context, index) =>
                      _buildRankItem(context, items[index], index),
                ),
        ),
      ],
    );
  }

  Widget _buildLoadingCards() {
    return AppSkeletonizer(
      enabled: true,
      child: ListView.separated(
        padding: EdgeInsets.zero,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 5,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) => _buildRankItem(context, const {
          'title': '排行动画标题',
          'images': {'common': ''},
        }, index),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '热门排行',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
              color: Theme.of(context).textTheme.titleLarge?.color,
            ),
          ),
          _buildModernSelector(context),
        ],
      ),
    );
  }

  Widget _buildModernSelector(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_rankNames.length, (index) {
        final isSelected = selectedIndex == index;
        return GestureDetector(
          onTap: () => onTypeChanged(index),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: EdgeInsets.only(left: index == 0 ? 0 : 16),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.5),
              ),
              child: Text(_rankNames[index]),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildRankItem(BuildContext context, Map item, int index) {
    final rank = index + 1;
    final rankColor = _getRankColor(rank);

    return Padding(
      padding: const EdgeInsets.only(right: 12, top: 4),
      child: GestureDetector(
        onTap: () => navigateToDetail(context, item),
        child: SizedBox(
          width: _cardWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: _cardHeight,
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: AspectRatio(
                        aspectRatio: _cardAspectRatio,
                        child: buildCachedImage(
                          item,
                          double.infinity,
                          double.infinity,
                        ),
                      ),
                    ),
                    _buildRankBadge(rank, rankColor),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                item['title'] as String,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                  color: Theme.of(context).textTheme.bodyMedium?.color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRankBadge(int rank, Color rankColor) {
    return Positioned(
      top: 0,
      left: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: rankColor,
          borderRadius: const BorderRadius.only(
            bottomRight: Radius.circular(8),
          ),
        ),
        child: Text(
          '#$rank',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic,
            fontSize: 12,
            height: 1.1,
          ),
        ),
      ),
    );
  }

  Color _getRankColor(int rank) {
    if (rank == 1) return _goldColor;
    if (rank == 2) return const Color(0xFFC0C0C0);
    if (rank == 3) return const Color(0xFFCD7F32);
    return Colors.blueGrey.withValues(alpha: 0.8);
  }
}
