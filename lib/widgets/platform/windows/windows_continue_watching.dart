import 'package:baka/app/navigation.dart';
import 'package:baka/core/content_filter.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/services/playback/continue_watching.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/theme.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/platform/windows/windows_home_widgets.dart';
import 'package:flutter/material.dart';

/// 首页「继续观看」：最近看过的番，点一下从上次那一集接着播。
/// 数据来自观看历史；历史落盘会自增 [HistoryRepository.revision]，回到首页自动刷新。
class WindowsContinueWatching extends StatelessWidget {
  const WindowsContinueWatching({
    required this.gutter,
    this.todaySubjects = const {},
    super.key,
  });

  final double gutter;

  /// 今天放送的 Bangumi 条目 id。命中的卡片标「今日更新」，并排到最前面。
  final Set<int> todaySubjects;

  static const double posterWidth = 148;
  static const double cardHeight = posterWidth * 1.5;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: historyRepository.revision,
      builder: (context, _, _) {
        final entries = _entries();
        if (entries.isEmpty) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        return SliverPadding(
          padding: const EdgeInsets.only(top: 40),
          sliver: SliverToBoxAdapter(
            child: WindowsShelf(
              title: '继续观看',
              subtitle: '${entries.length} 部待续',
              gutter: gutter,
              height: cardHeight,
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return SizedBox(
                  width: posterWidth,
                  child: _ContinueCard(
                    entry: entry,
                    updatedToday: _isUpdatedToday(entry),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  List<ContinueWatchingEntry> _entries() {
    final all = buildContinueWatching(historyRepository.getHistoryList());
    final visible = contentFilter.value
        ? all
              .where((entry) => entry.record['nsfw'] != true)
              .toList(growable: false)
        : all;
    // 今天有新一集排在前面，其余按最近观看时间。
    final sorted = [...visible];
    sorted.sort((a, b) {
      final aUpdated = _isUpdatedToday(a);
      final bUpdated = _isUpdatedToday(b);
      if (aUpdated != bUpdated) return aUpdated ? -1 : 1;
      return b.watchedAt.compareTo(a.watchedAt);
    });
    return sorted;
  }

  bool _isUpdatedToday(ContinueWatchingEntry entry) {
    final id = entry.bgmId;
    return id != null && todaySubjects.contains(id);
  }
}

class _ContinueCard extends StatefulWidget {
  const _ContinueCard({required this.entry, required this.updatedToday});

  final ContinueWatchingEntry entry;
  final bool updatedToday;

  @override
  State<_ContinueCard> createState() => _ContinueCardState();
}

class _ContinueCardState extends State<_ContinueCard> {
  bool _hovered = false;

  Future<void> _open() async {
    final request = PlaybackRequest.fromHistory(widget.entry.record);
    // 上一集已经看完时直接落到下一集；越界由播放器夹回最后一集。
    request.episodeIndex = widget.entry.targetEpisodeIndex;
    await NavigationService.toPlayback(context, request, autoMatch: false);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(windowsPosterRadius);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: _open,
        child: AnimatedContainer(
          duration: context.reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: _hovered
                ? const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 18,
                      offset: Offset(0, 8),
                    ),
                  ]
                : const [],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedScale(
                  // 与「每日放送」的海报卡一致：悬停时封面轻微放大，文字与角标不动。
                  scale: _hovered && !context.reduceMotion ? 1.06 : 1,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: buildCachedImage(
                    entry.record,
                    WindowsContinueWatching.posterWidth,
                    WindowsContinueWatching.cardHeight,
                  ),
                ),
                // 底部压暗，保证标题在浅色封面上可读。
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.center,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0xF2000000)],
                    ),
                  ),
                ),
                Positioned(
                  left: 10,
                  right: 48,
                  bottom: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedDefaultTextStyle(
                        duration: context.reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 160),
                        style: context.withAppFont(
                          TextStyle(
                            color: _hovered ? colors.primary : Colors.white,
                            fontSize: 13,
                            height: 1.25,
                            fontWeight: FontWeight.w700,
                            shadows: const [
                              Shadow(blurRadius: 6, color: Colors.black),
                            ],
                          ),
                        ),
                        child: Text(
                          entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        entry.episodeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.78),
                          fontSize: 11,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 160),
                    opacity: _hovered ? 1 : 0.75,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _hovered
                            ? colors.primary
                            : Colors.black.withValues(alpha: 0.5),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.7),
                          width: 1.5,
                        ),
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                if (widget.updatedToday)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colors.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '今日更新',
                        style: TextStyle(
                          color: colors.onPrimary,
                          fontSize: 10,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SizedBox(
                    height: 3,
                    child: ColoredBox(
                      color: Colors.white.withValues(alpha: 0.22),
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: entry.progress.clamp(0.0, 1.0),
                        child: ColoredBox(color: colors.primary),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
