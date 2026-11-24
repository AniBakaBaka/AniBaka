import 'package:baka/models/bgm.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/widgets/anime_detail/collection_sheet.dart';
import 'package:flutter/material.dart';
import 'package:baka/widgets/common/platform_tooltip.dart';

import 'package:baka/pages/player/bgm_detail_page.dart';

class BgmFollowPill extends StatelessWidget {
  final String title;
  final BgmInfo bgmInfo;
  final CollectionStatus? status;
  final VoidCallback onFollowPressed;

  const BgmFollowPill({
    required this.title,
    required this.bgmInfo,
    required this.onFollowPressed,
    this.status,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final score = bgmInfo.score;
    final subjectId = bgmInfo.subjectId;
    final visual = status == null ? null : collectionStatusVisuals[status];
    final followColor = visual?.$1 ?? theme.colorScheme.primary;
    final followIcon = visual?.$2 ?? Icons.add_rounded;
    final followLabel = status?.label ?? '追番';

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
            PlatformTooltip(
              message: subjectId == null ? 'Bangumi 评分' : '查看 Bangumi 详情',
              child: InkWell(
                onTap: subjectId == null
                    ? null
                    : () => BgmDetailPage.show(
                        context,
                        subjectId: subjectId,
                        title: title,
                        imageUrl: bgmInfo.imageUrl,
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
          PlatformTooltip(
            message: status == null ? '追番' : '已标记为「${status!.label}」，点击修改',
            child: InkWell(
              onTap: onFollowPressed,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(followIcon, size: 15, color: followColor),
                    const SizedBox(width: 4),
                    Text(
                      followLabel,
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
