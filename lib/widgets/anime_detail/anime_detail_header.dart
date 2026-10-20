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
  final AnimeDetailViewData detail;
  final ValueListenable<AnimeCollection?> collection;
  final VoidCallback onCollectionTap;
  final VoidCallback onSearchTap;

  const AnimeDetailHeader({
    required this.detail,
    required this.collection,
    required this.onCollectionTap,
    required this.onSearchTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = detail.title;
    final alias = detail.alias;
    final score = detail.score;
    final scoreCount = detail.scoreCount;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 800;
        final coverWidth = isWide ? 270.0 : 130.0;
        final coverHeight = isWide ? 378.0 : 182.0;
        final hasScore = score != null && score > 0;
        final cover = _buildCover(isDark, coverWidth, coverHeight);
        final tagList = _buildTags(isDark, limit: isWide ? null : 5);
        final collectionButton = ValueListenableBuilder<AnimeCollection?>(
          valueListenable: collection,
          builder: (context, value, _) {
            final status = value != null
                ? CollectionStatus.fromValue(value.status)
                : null;
            if (status != null) {
              final visual = collectionStatusVisuals[status]!;
              return _buildActionButton(
                icon: visual.$2,
                label: status.label,
                bgColor: visual.$1.withValues(alpha: isDark ? 0.15 : 0.1),
                textColor: visual.$1,
                onTap: onCollectionTap,
                animated: true,
              );
            }
            return _buildActionButton(
              icon: Icons.add_rounded,
              label: '追番',
              bgColor: isDark ? Colors.white : Colors.black,
              textColor: isDark ? Colors.black : Colors.white,
              onTap: onCollectionTap,
              animated: true,
            );
          },
        );
        final searchButton = _buildActionButton(
          icon: Icons.play_arrow_rounded,
          label: '开始观看',
          bgColor: isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7),
          textColor: isDark ? Colors.white : Colors.black,
          onTap: onSearchTap,
        );
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
                          _buildDesktopScoreCorner(isDark),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                cover,
                const SizedBox(width: 20),
                Expanded(
                  child: SizedBox(
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
                              color: isDark
                                  ? Colors.white54
                                  : const Color(0xFF8E8E93),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const Spacer(),
                        if (hasScore)
                          Row(
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
                              const Icon(
                                Icons.star_rounded,
                                size: 16,
                                color: Color(0xFFFF9500),
                              ),
                              if (scoreCount > 0) ...[
                                const SizedBox(width: 8),
                                Text(
                                  '$scoreCount 人评价',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: isDark
                                        ? Colors.white38
                                        : const Color(0xFF8E8E93),
                                  ),
                                ),
                              ],
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
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
    if (logoUrl.isEmpty) return fallback;
    return Container(
      height: isWide ? 85 : 55,
      alignment: Alignment.centerLeft,
      child: CachedNetworkImage(
        key: ValueKey(logoUrl),
        imageUrl: logoUrl,
        memCacheHeight: 170,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }

  Widget _buildCover(bool isDark, double width, double height) {
    final imageUrl = detail.coverUrl;
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
      tag: detail.heroTag,
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
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.16),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
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
                  memCacheWidth: width > 150 ? (width * 2).round() : 300,
                  placeholder: (_, _) => fallback,
                  errorWidget: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }

  Widget _buildDesktopScoreCorner(bool isDark) {
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
                      ? (scoreCount > 0
                            ? '#$rank · $scoreCount 人评价'
                            : '#$rank')
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

  Widget _buildTags(bool isDark, {int? limit}) {
    final tags = detail.genres.isNotEmpty ? detail.genres : detail.tags;
    final shownCount = limit == null || limit > tags.length
        ? tags.length
        : limit;
    final overflow = tags.length - shownCount;
    final updateTime = detail.updateTime;
    final category = detail.category;

    final decoration = BoxDecoration(
      color: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : const Color(0xFFF2F2F7),
      borderRadius: const BorderRadius.all(Radius.circular(6)),
    );
    final style = TextStyle(
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
      if (updateTime != null) buildPill('更新于 ${formatDate(updateTime)}'),
      if (category != null) buildPill(category),
      for (var i = 0; i < shownCount; i++) buildPill(tags[i]),
      if (overflow > 0) buildPill('+$overflow'),
    ];
    if (allPills.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 6, runSpacing: 6, children: allPills);
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color bgColor,
    required Color textColor,
    required VoidCallback onTap,
    bool animated = false,
  }) {
    final decoration = BoxDecoration(
      color: bgColor,
      borderRadius: const BorderRadius.all(Radius.circular(12)),
    );
    final content = Row(
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
    );
    return ScaleButton(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: animated
          ? AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 44,
              decoration: decoration,
              child: content,
            )
          : Container(height: 44, decoration: decoration, child: content),
    );
  }
}
