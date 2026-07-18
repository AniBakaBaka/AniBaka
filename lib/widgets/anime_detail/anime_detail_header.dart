import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/models/collection.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/widgets/anime_detail/collection_sheet.dart';
import 'package:baka/widgets/common/scale_button.dart';
import 'package:baka/widgets/common/shimmer.dart';

class AnimeDetailHeader extends StatelessWidget {
  final String imageUrl;
  final String title;
  final String alias;
  final double? score;
  final int scoreCount;
  final List<String> tags;
  final String? updateTime;
  final String? category;
  final Object heroTag;
  final AnimeCollection? collection;
  final bool isCollectionLoading;
  final VoidCallback onCollectionTap;
  final VoidCallback? onSearchTap;

  const AnimeDetailHeader({
    required this.imageUrl,
    required this.title,
    required this.alias,
    required this.score,
    required this.scoreCount,
    required this.tags,
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 800;
        final coverWidth = isWide ? 240.0 : 110.0;
        final coverHeight = isWide ? 336.0 : 154.0;
        final hasScore = score != null && score! > 0;
        final tagList = _TagsWrap(
          tags: tags,
          updateTime: updateTime,
          category: category,
          isDark: isDark,
        );
        final actions = Row(
          children: [
            if (isWide)
              SizedBox(
                width: 160,
                child: _CollectionButton(
                  isLoading: isCollectionLoading,
                  collection: collection,
                  onTap: onCollectionTap,
                ),
              )
            else
              Expanded(
                child: _CollectionButton(
                  isLoading: isCollectionLoading,
                  collection: collection,
                  onTap: onCollectionTap,
                ),
              ),
            if (onSearchTap != null) ...[
              SizedBox(width: isWide ? 16 : 12),
              if (isWide)
                SizedBox(
                  width: 160,
                  child: _SearchSourceButton(onTap: onSearchTap),
                )
              else
                Expanded(child: _SearchSourceButton(onTap: onSearchTap)),
            ],
          ],
        );
        final text = SizedBox(
          height: isWide ? null : coverHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
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
              if (alias.isNotEmpty && alias != title) ...[
                SizedBox(height: isWide ? 12 : 6),
                Text(
                  alias,
                  style: TextStyle(
                    fontSize: isWide ? 16 : 13,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                    color: isDark ? Colors.white54 : const Color(0xFF8E8E93),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (isWide && hasScore) const SizedBox(height: 20),
              if (!isWide) const Spacer(),
              if (hasScore)
                _ScoreRow(
                  score: score!,
                  scoreCount: scoreCount,
                  isDark: isDark,
                ),
              if (isWide) ...[
                const SizedBox(height: 20),
                tagList,
                const SizedBox(height: 32),
                actions,
              ],
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
            SizedBox(width: isWide ? 48 : 20),
            Expanded(child: text),
          ],
        );

        if (isWide) return intro;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            intro,
            const SizedBox(height: 24),
            tagList,
            const SizedBox(height: 24),
            actions,
          ],
        );
      },
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
    this.width = 110,
    this.height = 154,
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
                  placeholder: (context, url) => const ShimmerBox(
                    width: double.infinity,
                    height: double.infinity,
                  ),
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

class _TagsWrap extends StatelessWidget {
  final List<String> tags;
  final String? updateTime;
  final String? category;
  final bool isDark;

  const _TagsWrap({
    required this.tags,
    required this.isDark,
    this.updateTime,
    this.category,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (updateTime != null && updateTime!.trim().isNotEmpty)
          _buildPill(BgmUtils.formatTimeString(updateTime!, '更新于')),
        if (category?.trim().isNotEmpty == true) _buildPill(category!.trim()),
        ...tags.take(3).map(_buildPill),
        if (tags.length > 3) _buildPill('+${tags.length - 3}'),
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
  final bool isLoading;
  final AnimeCollection? collection;
  final VoidCallback onTap;

  const _CollectionButton({
    required this.isLoading,
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
          child: isLoading
              ? const ShimmerTextLine(width: 64, height: 14)
              : Row(
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
            Icon(Icons.search_rounded, size: 18, color: textColor),
            const SizedBox(width: 6),
            Text(
              '找资源',
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
