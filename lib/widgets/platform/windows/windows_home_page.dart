import 'package:baka/services/home_service.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/refresh.dart';
import 'package:baka/widgets/home/rank_section.dart';
import 'package:baka/widgets/home/swiper_banner.dart';
import 'package:baka/widgets/search/tag_filter_sheet.dart';
import 'package:flutter/material.dart';

const _kWeekLabels = <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// Windows 桌面版主页。各板块独立订阅数据源，避免整页重建。
class WindowsHomePage extends StatelessWidget {
  const WindowsHomePage({
    required this.svc,
    required this.onRefresh,
    super.key,
  });

  final HomeDataService svc;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: RefreshWrapper(
        onLoadMore: svc.loadMore,
        onRefresh: onRefresh,
        loadMoreResetListenable: svc.tag,
        showInitialIndicator: false,
        child: CustomScrollView(
          cacheExtent: 600,
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 20)),
            _buildBanner(),
            _buildSchedule(),
            _buildRanks(),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            _buildTagBar(),
            _buildFeedGrid(),
            const SliverToBoxAdapter(child: SizedBox(height: 36)),
          ],
        ),
      ),
    );
  }

  Widget _buildBanner() {
    return ValueListenableBuilder<HomeItems>(
      valueListenable: svc.swipers,
      builder: (context, swipers, _) {
        if (swipers.isEmpty) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 32 / 9,
                child: SwiperBanner(swiperData: swipers),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSchedule() {
    return ValueListenableBuilder<List<HomeItems>>(
      valueListenable: svc.schedule,
      builder: (context, schedule, _) => ValueListenableBuilder<int>(
        valueListenable: svc.week,
        builder: (context, week, _) {
          final items = schedule[week];
          if (items.isEmpty) {
            return const SliverToBoxAdapter(child: SizedBox.shrink());
          }
          return SliverToBoxAdapter(
            child: _buildSection(
              context,
              title: '更新表',
              selector: _buildWeekSelector(context, week),
              items: items,
            ),
          );
        },
      ),
    );
  }

  Widget _buildRanks() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        child: ValueListenableBuilder<int>(
          valueListenable: svc.rankIndex,
          builder: (context, index, _) =>
              ValueListenableBuilder<List<HomeItems>>(
                valueListenable: svc.ranks,
                builder: (context, ranks, _) => RankSection(
                  items: ranks[index],
                  selectedIndex: index,
                  onTypeChanged: svc.selectRank,
                ),
              ),
        ),
      ),
    );
  }

  Widget _buildTagBar() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
        child: ValueListenableBuilder<String>(
          valueListenable: svc.tag,
          builder: (context, selected, _) => Row(
            children: [
              Expanded(child: _buildTagSelector(context, selected)),
              const SizedBox(width: 12),
              _buildMoreTagsButton(context, selected),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeedGrid() {
    return ValueListenableBuilder<HomeItems>(
      valueListenable: svc.feed,
      builder: (context, items, _) => SliverLayoutBuilder(
        builder: (context, constraints) {
          final columns = _columnsFor(constraints.crossAxisExtent);
          return SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                childAspectRatio: 0.68,
                crossAxisSpacing: 16,
                mainAxisSpacing: 18,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final item = items[index];
                  return PostCard(
                    item,
                    key: ValueKey(
                      'feed_${item['bgmId'] ?? item['id'] ?? index}',
                    ),
                  );
                },
                childCount: items.length,
                addAutomaticKeepAlives: false,
              ),
            ),
          );
        },
      ),
    );
  }

  static int _columnsFor(double width) {
    if (width > 1600) return 7;
    if (width > 1200) return 6;
    if (width > 900) return 5;
    if (width > 600) return 4;
    return 2;
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required Widget selector,
    required List items,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).textTheme.titleLarge?.color,
                ),
              ),
              selector,
            ],
          ),
        ),
        SizedBox(
          height: 240,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            addAutomaticKeepAlives: false,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _buildScrollCard(context, items[index] as Map),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildScrollCard(BuildContext context, Map data) {
    final heroTag = 'home_${coverHeroTag(data)}';
    final title = data['title']?.toString() ?? '';
    final subtitle = data['subtitle']?.toString() ?? '';

    return InkWell(
      onTap: () => navigateToDetail(
        context,
        data,
        posIndex: data['index'] ?? 0,
        heroTag: heroTag,
      ),
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 160.0,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Hero(
                tag: heroTag,
                child: buildCachedImage(data, double.infinity, double.infinity),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 24, 10, 10),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87],
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
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          height: 1.2,
                        ),
                      ),
                      if (subtitle.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
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
    );
  }

  Widget _buildWeekSelector(BuildContext context, int selected) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;
    final unselectedColor = isDark ? Colors.white60 : Colors.black54;

    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(_kWeekLabels.length, (index) {
          final isSelected = selected == index;
          return Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            child: InkWell(
              onTap: () => svc.week.value = index,
              borderRadius: BorderRadius.circular(7),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isSelected ? primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                ),
                alignment: Alignment.center,
                child: Text(
                  _kWeekLabels[index],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: isSelected ? Colors.white : unselectedColor,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildTagSelector(BuildContext context, String selected) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final tag in svc.displayTags)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  onTap: () => svc.selectTag(tag),
                  borderRadius: BorderRadius.circular(16),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: tag == selected
                          ? primaryColor.withValues(alpha: 0.15)
                          : (theme.brightness == Brightness.dark
                              ? Colors.white.withValues(alpha: 0.05)
                              : Colors.black.withValues(alpha: 0.04)),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: tag == selected
                            ? primaryColor.withValues(alpha: 0.5)
                            : Colors.transparent,
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      tag,
                      style: TextStyle(
                        color: tag == selected
                            ? primaryColor
                            : theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.8),
                        fontSize: 12.0,
                        fontWeight: tag == selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMoreTagsButton(BuildContext context, String selected) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final secondaryColor = theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          final tag = await TagFilterSheet.show(context, selected);
          if (tag != null && tag.isNotEmpty) await svc.selectTag(tag);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.black.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '更多',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: secondaryColor,
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.keyboard_arrow_down, size: 15, color: secondaryColor),
            ],
          ),
        ),
      ),
    );
  }
}
