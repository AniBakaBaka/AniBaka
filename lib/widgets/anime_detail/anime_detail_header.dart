import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/models/anime_detail_view_data.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/widgets/anime_detail/collection_sheet.dart';
import 'package:baka/widgets/anime_detail/score_distribution_chart.dart';
import 'package:baka/widgets/common/scale_button.dart';

class AnimeDetailHeader extends StatelessWidget {
  /// 直接消费详情模型，避免调用方把 title/alias/score/tags 等字段再拆一遍。
  final AnimeDetailViewData detail;
  final String? updateTime;
  final String? category;
  final Object heroTag;
  final bool enableCoverEffects;
  final ValueListenable<AnimeCollection?> collection;
  final VoidCallback onCollectionTap;
  final VoidCallback onSearchTap;

  const AnimeDetailHeader({
    required this.detail,
    required this.heroTag,
    required this.collection,
    required this.onCollectionTap,
    required this.onSearchTap,
    this.enableCoverEffects = true,
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
        final cover = _CoverImage(
          imageUrl: imageUrl,
          heroTag: heroTag,
          isDark: isDark,
          enableEffects: enableCoverEffects,
          width: coverWidth,
          height: coverHeight,
        );
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
        final collectionButton = ValueListenableBuilder<AnimeCollection?>(
          valueListenable: collection,
          builder: (context, value, _) =>
              _CollectionButton(collection: value, onTap: onCollectionTap),
        );
        final searchButton = _SearchSourceButton(onTap: onSearchTap);
        final actionsRow = Row(
          children: [
            isWide
                ? SizedBox(width: 160, child: collectionButton)
                : Expanded(child: collectionButton),
            SizedBox(width: isWide ? 16 : 12),
            isWide
                ? SizedBox(width: 160, child: searchButton)
                : Expanded(child: searchButton),
          ],
        );

        if (isWide) {
          // 宽屏：封面 | 标题+限高标签；右下角 柱形图 + 分数/排名
          return SizedBox(
            height: coverHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                cover,
                const SizedBox(width: 48),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTitleOrLogo(title, detail.logoUrl, true, isDark),
                      if (alias.isNotEmpty) ...[
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
                          actionsRow,
                          const Spacer(),
                          _DesktopScoreCorner(detail: detail, isDark: isDark),
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
              if (alias.isNotEmpty) ...[
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
                _ScoreRow(score: score, scoreCount: scoreCount, isDark: isDark),
            ],
          ),
        );
        final intro = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cover,
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
            actionsRow,
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
    late final fallback = Text(
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
    if (logoUrl.isNotEmpty) {
      return Container(
        height: isWide ? 85 : 55,
        alignment: Alignment.centerLeft,
        child: CachedNetworkImage(
          key: ValueKey(logoUrl),
          imageUrl: logoUrl,
          memCacheHeight: 170,
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          errorWidget: (context, url, error) => fallback,
        ),
      );
    }

    return fallback;
  }
}

class _CoverImage extends StatelessWidget {
  final String imageUrl;
  final Object heroTag;
  final bool isDark;
  final bool enableEffects;
  final double width;
  final double height;

  const _CoverImage({
    required this.imageUrl,
    required this.heroTag,
    required this.isDark,
    required this.enableEffects,
    this.width = 130,
    this.height = 182,
  });

  @override
  Widget build(BuildContext context) {
    late final fallback = ColoredBox(
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
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.04),
            width: 0.5,
          ),
          boxShadow: enableEffects
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.16),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(11.5)),
          child: imageUrl.isEmpty
              ? fallback
              : CachedNetworkImage(
                  imageUrl: imageUrl,
                  fit: BoxFit.cover,
                  useOldImageOnUrlChange: true,
                  fadeInDuration: Duration.zero,
                  fadeOutDuration: Duration.zero,
                  // The mobile cover already fits the card's 300 px decode.
                  // Do not decode the same AVIF again at 260 px after entry.
                  // Only the larger desktop cover needs an upgrade.
                  memCacheWidth: enableEffects && width > 150
                      ? (width * 2).round()
                      : 300,
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
  const _DesktopScoreCorner({required this.detail, required this.isDark});

  final AnimeDetailViewData detail;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final score = detail.score;
    final scoreCount = detail.scoreCount;
    final rank = detail.rank;
    final hasChart = detail.hasScoreDistribution;
    final hasScore = score != null && score > 0;
    if (!hasChart && !hasScore) return const SizedBox.shrink();

    final subColor = isDark ? Colors.white38 : const Color(0xFF8E8E93);
    final hasRank = rank != null && rank > 0;
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
                    score.toStringAsFixed(1),
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
              if (hasRank || scoreCount > 0) ...[
                const SizedBox(height: 6),
                Text(
                  hasRank
                      ? scoreCount > 0
                            ? '#$rank · $scoreCount 人评价'
                            : '#$rank'
                      : '$scoreCount 人评价',
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
        ScoreDistributionChart(counts: detail.scoreDistribution),
        if (scoreCol != null) ...[const SizedBox(width: 20), scoreCol],
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
    final shownCount = limited == null || limited > tags.length
        ? tags.length
        : limited;
    final overflow = tags.length - shownCount;
    final trimmedCategory = category?.trim();
    late final decoration = BoxDecoration(
      color: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : const Color(0xFFF2F2F7),
      borderRadius: const BorderRadius.all(Radius.circular(6)),
    );
    late final style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      color: isDark ? Colors.white70 : const Color(0xFF3A3A3C),
    );
    Widget buildPill(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: decoration,
      child: Text(text, style: style),
    );

    final allPills = <Widget>[
      if (updateTime != null && updateTime!.trim().isNotEmpty)
        buildPill('更新于 ${formatDate(updateTime!)}'),
      if (trimmedCategory != null && trimmedCategory.isNotEmpty)
        buildPill(trimmedCategory),
      for (var i = 0; i < shownCount; i++) buildPill(tags[i]),
      if (overflow > 0) buildPill('+$overflow'),
    ];

    if (allPills.isEmpty) return const SizedBox.shrink();

    return Wrap(spacing: 6, runSpacing: 6, children: allPills);
  }
}

class _CollectionButton extends StatelessWidget {
  final AnimeCollection? collection;
  final VoidCallback onTap;

  const _CollectionButton({required this.collection, required this.onTap});

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
      final visual = collectionStatusVisuals[status]!;
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
          borderRadius: const BorderRadius.all(Radius.circular(12)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
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
    );
  }
}

class _SearchSourceButton extends StatelessWidget {
  final VoidCallback onTap;

  const _SearchSourceButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7);
    final textColor = isDark ? Colors.white : Colors.black;

    return ScaleButton(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
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
