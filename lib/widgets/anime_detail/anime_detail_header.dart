import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/models/anime_detail_view_data.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/widgets/anime_detail/collection_sheet.dart';
import 'package:baka/widgets/anime_detail/score_distribution_chart.dart';
import 'package:baka/widgets/common/scale_button.dart';

class AnimeDetailHeader extends StatelessWidget {
  /// 直接消费详情模型，避免调用方把 title/alias/score/tags 等字段再拆一遍。
  final AnimeDetailViewData detail;
  final String? updateTime;
  final String? category;
  final Object heroTag;
  final AnimeCollection? collection;
  final bool isCollectionLoading;
  final VoidCallback onCollectionTap;
  final VoidCallback? onSearchTap;

  const AnimeDetailHeader({
    required this.detail,
    required this.heroTag,
    required this.collection,
    required this.isCollectionLoading,
    required this.onCollectionTap,
    this.onSearchTap,
    this.updateTime,
    this.category,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = detail.title;
    final alias = detail.alias;
    final score = detail.score;
    final scoreCount = detail.scoreCount;
    final imageUrl = detail.coverUrl;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 800;
        final coverWidth = isWide ? 270.0 : 130.0;
        final coverHeight = isWide ? 378.0 : 182.0;
        final hasScore = score != null && score > 0;
        // 标签：优先完整分类 genres；桌面限高区域展示，移动端限数量。
        final categoryTags = detail.genres.isNotEmpty
            ? detail.genres
            : detail.tags;
        final tagList = _TagsWrap(
          tags: categoryTags,
          updateTime: updateTime,
          category: category,
          isDark: isDark,
          // 移动端最多 5 个（另含更新时间/分类 pill 时仍截断 tags 本身）
          limit: isWide ? null : 5,
        );
        Widget actionsRow({required bool expand}) => Row(
          children: [
            if (expand)
              Expanded(
                child: _CollectionButton(
                  collection: collection,
                  onTap: onCollectionTap,
                ),
              )
            else
              SizedBox(
                width: 160,
                child: _CollectionButton(
                  collection: collection,
                  onTap: onCollectionTap,
                ),
              ),
            if (onSearchTap != null) ...[
              SizedBox(width: expand ? 12 : 16),
              if (expand)
                Expanded(child: _SearchSourceButton(onTap: onSearchTap))
              else
                SizedBox(
                  width: 160,
                  child: _SearchSourceButton(onTap: onSearchTap),
                ),
            ],
          ],
        );

        if (isWide) {
          // 宽屏：封面 | 标题+限高标签；右下角 柱形图 + 分数/排名
          return SizedBox(
            height: coverHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _CoverImage(
                  imageUrl: imageUrl,
                  heroTag: heroTag,
                  isDark: isDark,
                  width: coverWidth,
                  height: coverHeight,
                ),
                const SizedBox(width: 48),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTitleOrLogo(
                        title,
                        detail.logoUrl,
                        true,
                        isDark,
                      ),
                      if (alias.isNotEmpty && alias != title) ...[
                        const SizedBox(height: 12),
                        Text(
                          alias,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            height: 1.3,
                            color: isDark
                                ? Colors.white54
                                : const Color(0xFF8E8E93),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 16),
                      // 限高标签区：约 3 行，超出可滚动
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: 36,
                          maxHeight: 96,
                        ),
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          child: tagList,
                        ),
                      ),
                      const Spacer(),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          actionsRow(expand: false),
                          const Spacer(),
                          _DesktopScoreCorner(
                            score: hasScore ? score : null,
                            scoreCount: scoreCount,
                            rank: detail.rank,
                            distribution: detail.scoreDistribution,
                            isDark: isDark,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        final text = SizedBox(
          height: coverHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTitleOrLogo(title, detail.logoUrl, false, isDark),
              if (alias.isNotEmpty && alias != title) ...[
                const SizedBox(height: 6),
                Text(
                  alias,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                    color: isDark ? Colors.white54 : const Color(0xFF8E8E93),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const Spacer(),
              if (hasScore)
                _ScoreRow(
                  score: score,
                  scoreCount: scoreCount,
                  isDark: isDark,
                ),
            ],
          ),
        );
        final intro = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CoverImage(
              imageUrl: imageUrl,
              heroTag: heroTag,
              isDark: isDark,
              width: coverWidth,
              height: coverHeight,
            ),
            const SizedBox(width: 20),
            Expanded(child: text),
          ],
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            intro,
            const SizedBox(height: 24),
            tagList,
            const SizedBox(height: 24),
            actionsRow(expand: true),
          ],
        );
      },
    );
  }
  Widget _buildTitleOrLogo(
    String title,
    String logoUrl,
    bool isWide,
    bool isDark,
  ) {
    if (logoUrl.isNotEmpty) {
      return Container(
        height: isWide ? 85 : 55,
        alignment: Alignment.centerLeft,
        child: CachedNetworkImage(
          key: ValueKey(logoUrl),
          imageUrl: logoUrl,
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          errorWidget: (context, url, error) => Text(
            title,
            style: TextStyle(
              fontSize: isWide ? 38 : 22,
              fontWeight: FontWeight.w800,
              letterSpacing: isWide ? -0.8 : -0.6,
              height: 1.2,
              color: isDark ? Colors.white : const Color(0xFF111111),
            ),
            maxLines: isWide ? 2 : 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    return Text(
      title,
      style: TextStyle(
        fontSize: isWide ? 38 : 22,
        fontWeight: FontWeight.w800,
        letterSpacing: isWide ? -0.8 : -0.6,
        height: 1.2,
        color: isDark ? Colors.white : const Color(0xFF111111),
      ),
      maxLines: isWide ? 2 : 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _CoverImage extends StatelessWidget {
  final String imageUrl;
  final Object heroTag;
  final bool isDark;
  final double width;
  final double height;

  const _CoverImage({
    required this.imageUrl,
    required this.heroTag,
    required this.isDark,
    this.width = 130,
    this.height = 182,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : const Color(0xFFF2F2F7),
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          size: width * 0.24,
          color: isDark ? Colors.white24 : Colors.black26,
        ),
      ),
    );

    return Hero(
      tag: heroTag,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.04),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.16),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11.5),
          child: imageUrl.isEmpty
              ? fallback
              : CachedNetworkImage(
                  imageUrl: imageUrl,
                  fit: BoxFit.cover,
                  useOldImageOnUrlChange: true,
                  fadeInDuration: Duration.zero,
                  fadeOutDuration: Duration.zero,
                  memCacheWidth: (width * 2).round(),
                  placeholder: (context, url) => fallback,
                  errorWidget: (context, url, error) => fallback,
                ),
        ),
      ),
    );
  }
}

class _ScoreRow extends StatelessWidget {
  final double score;
  final int scoreCount;
  final bool isDark;

  const _ScoreRow({
    required this.score,
    required this.scoreCount,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          score.toStringAsFixed(1),
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
        const SizedBox(width: 4),
        const Icon(Icons.star_rounded, size: 16, color: Color(0xFFFF9500)),
        if (scoreCount > 0) ...[
          const SizedBox(width: 8),
          Text(
            '$scoreCount 人评价',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.white38 : const Color(0xFF8E8E93),
            ),
          ),
        ],
      ],
    );
  }
}

/// 桌面右下角：柱形图 + 分数 / 排名（并排）。
class _DesktopScoreCorner extends StatelessWidget {
  const _DesktopScoreCorner({
    required this.score,
    required this.scoreCount,
    required this.rank,
    required this.distribution,
    required this.isDark,
  });

  final double? score;
  final int scoreCount;
  final int? rank;
  final List<int> distribution;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final hasChart =
        distribution.length == 10 && distribution.any((c) => c > 0);
    final hasScore = score != null && score! > 0;
    if (!hasChart && !hasScore) return const SizedBox.shrink();

    final subColor = isDark ? Colors.white38 : const Color(0xFF8E8E93);
    final scoreCol = hasScore
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    score!.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                      height: 1,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.star_rounded,
                    size: 22,
                    color: Color(0xFFFF9500),
                  ),
                ],
              ),
              if ((rank != null && rank! > 0) || scoreCount > 0) ...[
                const SizedBox(height: 6),
                Text(
                  [
                    if (rank != null && rank! > 0) '#$rank',
                    if (scoreCount > 0) '$scoreCount 人评价',
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: subColor,
                  ),
                ),
              ],
            ],
          )
        : null;

    if (!hasChart) return scoreCol ?? const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        ScoreDistributionChart(
          counts: distribution,
          maxBarHeight: 72,
          barWidth: 14,
          barGap: 5,
          compact: true,
          showLabels: true,
        ),
        if (scoreCol != null) ...[
          const SizedBox(width: 20),
          scoreCol,
        ],
      ],
    );
  }
}

class _TagsWrap extends StatelessWidget {
  final List<String> tags;
  final String? updateTime;
  final String? category;
  final bool isDark;

  /// `null` = 展示全部；否则截断并显示 +N。
  final int? limit;

  const _TagsWrap({
    required this.tags,
    required this.isDark,
    this.updateTime,
    this.category,
    this.limit = 3,
  });

  @override
  Widget build(BuildContext context) {
    final limited = limit;
    final shown = limited == null ? tags : tags.take(limited).toList();
    final overflow =
        limited != null && tags.length > limited ? tags.length - limited : 0;

    final allPills = <Widget>[
      if (updateTime != null && updateTime!.trim().isNotEmpty)
        _buildPill(BgmUtils.formatTimeString(updateTime!, '更新于')),
      if (category?.trim().isNotEmpty == true) _buildPill(category!.trim()),
      ...shown.map(_buildPill),
      if (overflow > 0) _buildPill('+$overflow'),
    ];

    if (allPills.isEmpty) return const SizedBox.shrink();

    final List<Widget> chunkedWraps = [];
    for (var i = 0; i < allPills.length; i += 7) {
      final chunk = allPills.sublist(
        i,
        i + 7 > allPills.length ? allPills.length : i + 7,
      );
      chunkedWraps.add(
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: chunk,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < chunkedWraps.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          chunkedWraps[i],
        ],
      ],
    );
  }

  Widget _buildPill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : const Color(0xFFF2F2F7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: isDark ? Colors.white70 : const Color(0xFF3A3A3C),
        ),
      ),
    );
  }
}

class _CollectionButton extends StatelessWidget {
  final AnimeCollection? collection;
  final VoidCallback onTap;

  const _CollectionButton({
    required this.collection,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final status = collection != null
        ? CollectionStatus.fromValue(collection!.status)
        : null;

    final Color bgColor;
    final Color textColor;
    final String label;
    final IconData icon;

    if (status != null) {
      final visual = statusVisual(status);
      bgColor = visual.$1.withValues(alpha: isDark ? 0.15 : 0.1);
      textColor = visual.$1;
      label = status.label;
      icon = visual.$2;
    } else {
      bgColor = isDark ? Colors.white : Colors.black;
      textColor = isDark ? Colors.black : Colors.white;
      label = '追番';
      icon = Icons.add_rounded;
    }

    return ScaleButton(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 44,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: textColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchSourceButton extends StatelessWidget {
  final VoidCallback? onTap;

  const _SearchSourceButton({this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7);
    final textColor = isDark ? Colors.white : Colors.black;

    return ScaleButton(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap?.call();
      },
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.play_arrow_rounded, size: 20, color: textColor),
            const SizedBox(width: 4),
            Text(
              '开始观看',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
