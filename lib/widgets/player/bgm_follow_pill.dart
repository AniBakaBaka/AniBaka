import 'package:flutter/material.dart';

import 'package:baka/pages/player/bgm_detail_page.dart';
import 'package:baka/utils/bgm_utils.dart';

class BgmFollowPill extends StatelessWidget {
  final String title;
  final BgmInfo bgmInfo;
  final bool isFollowed;
  final VoidCallback onFollowPressed;

  const BgmFollowPill({
    required this.title,
    required this.bgmInfo,
    required this.isFollowed,
    required this.onFollowPressed,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final score = bgmInfo.score;
    final followColor = isFollowed
        ? const Color(0xFF34C759)
        : theme.colorScheme.primary;

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: followColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: followColor.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (score != null) ...[
            Tooltip(
              message: bgmInfo.subjectId == null
                  ? 'Bangumi 评分'
                  : '查看 Bangumi 详情',
              child: InkWell(
                onTap: bgmInfo.subjectId == null
                    ? null
                    : () => BgmDetailPage.show(
                        context,
                        subjectId: bgmInfo.subjectId!,
                        title: title,
                        imageUrl: bgmInfo.imageUrl ?? '',
                        initialScore: score,
                      ),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 5,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        size: 15,
                        color: Colors.orange,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        score.toStringAsFixed(1),
                        style: const TextStyle(
                          color: Colors.orange,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              width: 1,
              height: 16,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              color: theme.dividerColor.withValues(alpha: 0.32),
            ),
          ],
          Tooltip(
            message: isFollowed ? '已追番，点击更新状态' : '追番',
            child: InkWell(
              onTap: onFollowPressed,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isFollowed
                          ? Icons.play_circle_fill_rounded
                          : Icons.add_rounded,
                      size: 15,
                      color: followColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isFollowed ? '在看' : '追番',
                      style: TextStyle(
                        color: followColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
