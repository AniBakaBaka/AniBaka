import 'package:baka/core/content_filter.dart';
import 'package:baka/models/anime_filter.dart';
import 'package:baka/pages/home/home_controller.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/refresh.dart';
import 'package:baka/widgets/platform/windows/windows_home_widgets.dart';
import 'package:baka/widgets/search/tag_filter_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

const _weekLabels = <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
const _rankLabels = <String>['总榜', '季榜', '月榜', '日榜'];
const _rankHints = <String>['按 Bangumi 排名', '近 90 天开播', '近 30 天开播', '近 2 天开播'];

const double _gutter = 32;
const double _bannerTopGap = 35;

const double _sectionGap = 40;
const double _shelfPosterWidth = 148;
const double _rankPosterWidth = 132;
const double _feedMinTileWidth = 156;
const double _feedColumnGap = 20;
const double _feedRowGap = 28;

/// Windows 桌面版主页。各板块独立订阅数据源，避免整页重建。
class WindowsHomePage extends StatelessWidget {
  const WindowsHomePage({
    required this.svc,
    required this.onRefresh,
    super.key,
  });

  final HomeController svc;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: contentFilter,
    builder: (context, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final textHeight = windowsTileTextHeight(context);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: LayoutBuilder(
        builder: (context, constraints) => RefreshWrapper(
          onLoadMore: svc.loadMore,
          onRefresh: onRefresh,
          loadMoreResetListenable: svc.filter,
          showInitialIndicator: false,
          child: CustomScrollView(
            scrollCacheExtent: const ScrollCacheExtent.pixels(800),
            slivers: [
              _buildBanner(),
              _buildSchedule(textHeight),
              _buildRanks(textHeight),
              _buildFeedHeader(),
              _buildFeedGrid(constraints.maxWidth, textHeight),
              const SliverToBoxAdapter(child: SizedBox(height: 48)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBanner() {
    return ValueListenableBuilder<HomeItems>(
      valueListenable: svc.swipers,
      builder: (context, rawSwipers, _) {
        final swipers = contentFilter.visibleItems(rawSwipers);
        if (swipers.isEmpty) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            _gutter,
            _bannerTopGap,
            _gutter,
            0,
          ),
          sliver: SliverToBoxAdapter(child: WindowsHeroBanner(items: swipers)),
        );
      },
    );
  }

  Widget _buildSchedule(double textHeight) {
    return ValueListenableBuilder<List<HomeItems>>(
      valueListenable: svc.schedule,
      builder: (context, schedule, _) {
        if (schedule.every((day) => day.isEmpty)) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        return SliverPadding(
          padding: const EdgeInsets.only(top: _sectionGap),
          sliver: SliverToBoxAdapter(
            child: ValueListenableBuilder<int>(
              valueListenable: svc.week,
              builder: (context, week, _) {
                final items = contentFilter.visibleItems(schedule[week]);
                final today = DateTime.now().weekday - 1;
                final dayName = week == today ? '今天' : _weekLabels[week];
                return WindowsShelf(
                  title: '每日放送',
                  subtitle: items.isEmpty
                      ? '$dayName暂无更新'
                      : '$dayName · ${items.length} 部',
                  gutter: _gutter,
                  resetKey: week,
                  height: _shelfPosterWidth * 1.5 + textHeight,
                  actions: [
                    WindowsSegmentedTabs(
                      labels: [
                        for (var i = 0; i < _weekLabels.length; i++)
                          i == today ? '今天' : _weekLabels[i],
                      ],
                      selected: week,
                      onChanged: (index) => svc.week.value = index,
                    ),
                  ],
                  placeholder: const _EmptyShelf(message: '这一天没有番剧更新'),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return SizedBox(
                      width: _shelfPosterWidth,
                      child: WindowsPosterTile(
                        data: item,
                        heroTag: 'home_${coverHeroTag(item)}',
                        posIndex: item['index'] ?? 0,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildRanks(double textHeight) {
    return SliverPadding(
      padding: const EdgeInsets.only(top: _sectionGap),
      sliver: SliverToBoxAdapter(
        child: ValueListenableBuilder<int>(
          valueListenable: svc.rankIndex,
          builder: (context, index, _) =>
              ValueListenableBuilder<List<HomeItems>>(
                valueListenable: svc.ranks,
                builder: (context, ranks, _) {
                  final items = contentFilter.visibleItems(ranks[index]);
                  return WindowsShelf(
                    title: '热门排行',
                    subtitle: _rankHints[index],
                    gutter: _gutter,
                    resetKey: index,
                    height: _rankPosterWidth * 1.5 + textHeight,
                    actions: [
                      WindowsSegmentedTabs(
                        labels: _rankLabels,
                        selected: index,
                        onChanged: svc.selectRank,
                      ),
                    ],
                    placeholder: const WindowsRankSkeleton(
                      posterWidth: _rankPosterWidth,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, rankIndex) {
                      final item = items[rankIndex];
                      // 排行与下方信息流可能出现同一部番剧，Hero 标签需要单独的前缀。
                      return WindowsPosterTile(
                        data: item,
                        rank: rankIndex + 1,
                        heroTag: 'rank_${coverHeroTag(item)}',
                        posterWidth: _rankPosterWidth,
                      );
                    },
                  );
                },
              ),
        ),
      ),
    );
  }

  Widget _buildFeedHeader() {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(_gutter, _sectionGap + 4, _gutter, 18),
      sliver: SliverToBoxAdapter(
        child: ValueListenableBuilder<AnimeFilter>(
          valueListenable: svc.filter,
          builder: (context, selected, _) => Row(
            children: [
              Text(
                '发现',
                style: WindowsSectionHeader.titleStyle(
                  Theme.of(context).colorScheme,
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: _TagChips(
                  filters: svc.displayFilters,
                  selected: selected,
                  onSelected: svc.selectFilter,
                ),
              ),
              const SizedBox(width: 12),
              _MoreTagsButton(
                onPressed: () async {
                  final filter = await TagFilterSheet.show(context, selected);
                  if (filter != null) await svc.selectFilter(filter);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeedGrid(double width, double textHeight) {
    // SliverConstraints 随滚动逐帧变化，列数只需要依赖窗口的可用宽度。
    final available = width - _gutter * 2;
    if (available < _feedMinTileWidth) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final columns =
        ((available + _feedColumnGap) / (_feedMinTileWidth + _feedColumnGap))
            .floor()
            .clamp(2, 10);
    final tileWidth = (available - _feedColumnGap * (columns - 1)) / columns;
    return ValueListenableBuilder<HomeItems>(
      valueListenable: svc.feed,
      builder: (context, rawItems, _) {
        final items = contentFilter.visibleItems(rawItems);
        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: _gutter),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: _feedColumnGap,
              mainAxisSpacing: _feedRowGap,
              mainAxisExtent: tileWidth * 1.5 + textHeight,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final item = items[index];
                return WindowsPosterTile(
                  key: ValueKey('feed_${item['bgmId'] ?? item['id'] ?? index}'),
                  data: item,
                  heroTag: coverHeroTag(item),
                );
              },
              childCount: items.length,
              addAutomaticKeepAlives: false,
            ),
          ),
        );
      },
    );
  }
}

class _EmptyShelf extends StatelessWidget {
  final String message;

  const _EmptyShelf({required this.message});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.event_busy_outlined,
              size: 28,
              color: colors.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _TagChips extends StatelessWidget {
  final Iterable<AnimeFilter> filters;
  final AnimeFilter selected;
  final ValueChanged<AnimeFilter> onSelected;

  const _TagChips({
    required this.filters,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final filter in filters)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Material(
                  color: filter == selected
                      ? colors.primary
                      : colors.onSurface.withValues(
                          alpha: isDark ? 0.08 : 0.05,
                        ),
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onSelected(filter),
                    splashFactory: NoSplash.splashFactory,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      child: Text(
                        filter.label,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          fontWeight: filter == selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: filter == selected
                              ? colors.onPrimary
                              : colors.onSurface.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MoreTagsButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _MoreTagsButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.onSurface,
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.8)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      icon: const Icon(Icons.tune_rounded, size: 17),
      label: const Text('更多标签'),
    );
  }
}
