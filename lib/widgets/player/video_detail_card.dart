import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:baka/pages/search/tag_page.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/date_util.dart';
import 'package:baka/utils/reg_utils.dart';
import 'package:baka/widgets/common/scale_button.dart';
import 'package:baka/widgets/player/bgm_follow_pill.dart';

import 'package:baka/widgets/danmaku/controller.dart';
import 'package:baka/widgets/danmaku/danmaku_list_sheet.dart';

/// 播放页视频详情卡片
class VideoDetailCard extends StatelessWidget {
  final Map detail;
  final BgmInfo bgmInfo;
  final ValueNotifier<bool> followNotifier;
  final List<String> cachedTags;
  final VoidCallback onFollowPressed;
  final VoidCallback onShowDetail;
  final DanmakuController? danmakuController;
  final String? sourceName;
  final String? lineName;
  final VoidCallback? onSourceTap;
  final bool isSearching;

  const VideoDetailCard({
    required this.detail,
    required this.bgmInfo,
    required this.followNotifier,
    required this.cachedTags,
    required this.onFollowPressed,
    required this.onShowDetail,
    this.danmakuController,
    this.sourceName,
    this.lineName,
    this.onSourceTap,
    this.isSearching = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mutedColor = theme.textTheme.bodyMedium?.color?.withValues(
      alpha: 0.4,
    );
    final airDate = BgmUtils.formatAirDate(detail);
    final time =
        airDate ??
        DateTime.parse((detail['time'] ?? '20231113').toString()).toEnDate();
    final mutedStyle = TextStyle(
      color: mutedColor,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  detail['title'] ?? '',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: theme.textTheme.titleLarge?.color,
                    height: 1.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<bool>(
                valueListenable: followNotifier,
                builder: (context, isFollowed, _) => BgmFollowPill(
                  title: detail['title']?.toString() ?? '',
                  bgmInfo: bgmInfo,
                  isFollowed: isFollowed,
                  onFollowPressed: onFollowPressed,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              ClipOval(
                child: CachedNetworkImage(
                  memCacheWidth: 80,
                  imageUrl: getAvatar(avatar: detail['uqq'] ?? '3179737489'),
                  width: 18,
                  height: 18,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    Text(time, style: mutedStyle),
                    Text('•', style: mutedStyle),
                    Text('gv${detail['id']}', style: mutedStyle),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (danmakuController != null) ...[
                ListenableBuilder(
                  listenable: danmakuController!,
                  builder: (context, _) {
                    final count = danmakuController!.items.length;
                    return ScaleButton(
                      onTap: () => DanmakuListSheet.show(
                        context,
                        danmakuController!,
                        defaultTitle: detail['title']?.toString(),
                        defaultEpisode: (detail['episodeIndex'] is num)
                            ? (detail['episodeIndex'] as num).toInt() + 1
                            : null,
                      ),

                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: theme.cardColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: theme.dividerColor.withValues(alpha: 0.1),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.subtitles_outlined,
                              size: 14,
                              color: theme.textTheme.bodyMedium?.color
                                  ?.withValues(alpha: 0.8),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '弹幕 $count',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: theme.textTheme.bodyMedium?.color
                                    ?.withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
              ],
              ScaleButton(
                onTap: onShowDetail,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: theme.dividerColor.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '简介',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: theme.textTheme.bodyMedium?.color?.withValues(
                            alpha: 0.8,
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 14,
                        color: theme.textTheme.bodyMedium?.color?.withValues(
                          alpha: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (cachedTags.isNotEmpty || sourceName != null) ...[
            const SizedBox(height: 14),

            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  if (sourceName != null && onSourceTap != null) ...[
                    _SourceChip(
                      sourceName: sourceName!,
                      lineName: lineName,
                      isSearching: isSearching,
                      onTap: onSourceTap!,
                    ),
                    if (cachedTags.isNotEmpty) const SizedBox(width: 8),
                  ],
                  for (int i = 0; i < cachedTags.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    _TagChip(tag: cachedTags[i]),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag});

  final String tag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;

    return ScaleButton(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => TagPage(tag, 0)),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: primary.withValues(alpha: isDark ? 0.1 : 0.06),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '#',
              style: TextStyle(
                color: primary.withValues(alpha: 0.5),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 2),
            Text(
              tag,
              style: TextStyle(
                color: theme.textTheme.bodyMedium?.color?.withValues(
                  alpha: 0.75,
                ),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({
    required this.sourceName,
    required this.onTap,
    this.lineName,
    this.isSearching = false,
  });

  final String sourceName;
  final String? lineName;
  final VoidCallback onTap;
  final bool isSearching;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;

    final label = isSearching
        ? '正在解构优选源...'
        : (lineName != null ? '$sourceName · $lineName' : sourceName);

    return ScaleButton(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: primary.withValues(alpha: isDark ? 0.15 : 0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSearching)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: primary,
                  ),
                ),
              )
            else ...[
              Icon(Icons.sensors_rounded, size: 12, color: primary),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                color: primary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.keyboard_arrow_right_rounded,
              size: 13,
              color: primary.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}
