import 'package:flutter/material.dart';

import 'package:baka/services/player_service.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/utils/date_util.dart';
import 'package:baka/utils/reg_utils.dart';

final _reSpecial = RegExp(r'(ova|sp|剧场版)', caseSensitive: false);
final _reEpisodeNoise = RegExp(r'[\d第集话章回]');

/// 选集网格中的单集卡片。
class EpisodeItem extends StatelessWidget {
  final int index;
  final String rawTitle;
  final bool isSelected;
  final bool isWatched;
  final bool isDownloadMode;
  final bool isQueued;
  final bool isDownloadSelected;
  final VoidCallback? onTap;
  final Color? textColor;

  const EpisodeItem({
    required this.index,
    required this.rawTitle,
    super.key,
    this.isSelected = false,
    this.isWatched = false,
    this.isDownloadMode = false,
    this.isQueued = false,
    this.isDownloadSelected = false,
    this.onTap,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = textColor ?? theme.colorScheme.onSurface;
    final highlighted = isDownloadMode
        ? (isDownloadSelected || isQueued)
        : isSelected;
    final accent = isQueued ? Colors.green : theme.colorScheme.primary;

    final title = isDownloadMode || _reSpecial.hasMatch(rawTitle)
        ? rawTitle
        : rawTitle.replaceAll(_reEpisodeNoise, '').trim();

    final foreground = highlighted
        ? accent
        : base.withValues(alpha: isWatched ? 0.35 : 0.85);

    return Material(
      color: highlighted
          ? accent.withValues(alpha: 0.12)
          : base.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: (isDownloadMode && isQueued) ? null : onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    (index + 1).toString().padLeft(2, '0'),
                    style: TextStyle(
                      color: foreground,
                      fontSize: title.isEmpty ? 15 : 12,
                      fontWeight: highlighted
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                  if (highlighted) ...[
                    const SizedBox(width: 3),
                    Icon(
                      isDownloadMode
                          ? Icons.check_rounded
                          : Icons.play_arrow_rounded,
                      size: 13,
                      color: foreground,
                    ),
                  ],
                ],
              ),
              if (title.isNotEmpty)
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: foreground.withValues(alpha: 0.7),
                    fontSize: 10,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 播放页选集工具栏：更新信息、排序方向、展开全部。
Widget buildEpisodeToolbar({
  required BuildContext context,
  required bool sortAscending,
  required VoidCallback onSortDirectionChanged,
  required VoidCallback onShowVideoList,
  List? videoList,
  String? updateTime,
  String? content,
}) {
  final primary = Theme.of(context).colorScheme.primary;
  final delayInfo = RegUtils.parseDelayOrSuspensionInfo(content);
  final infoColor = delayInfo != null ? Colors.orange : primary;
  final info = _episodeInfo(videoList?.length ?? 0, delayInfo, updateTime);

  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (info != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: infoColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            info,
            style: TextStyle(
              fontSize: 10,
              color: infoColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      IconButton(
        onPressed: onSortDirectionChanged,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
          size: 16,
          color: primary,
        ),
      ),
      IconButton(
        onPressed: onShowVideoList,
        visualDensity: VisualDensity.compact,
        icon: Icon(Icons.keyboard_arrow_down, color: primary),
      ),
    ],
  );
}

String? _episodeInfo(int count, String? delayInfo, String? updateTime) {
  if (delayInfo != null) return '$count | $delayInfo';
  if (updateTime == null) return null;
  if (updateTime.isEmpty) return '$count';
  final formatted = DateTime.tryParse(updateTime)?.toZhWeekTime() ?? updateTime;
  final parts = formatted.split(', ');
  return parts.length == 2
      ? '$count | ${parts[0]}${parts[1]}更'
      : '$count | 更$formatted';
}

/// 桌面端选集网格。
Widget buildWindowsEpisodeList({
  required BuildContext context,
  required List<PlaybackEpisode> videoList,
  required List<int> visibleIndexes,
  required int currPlayIndex,
  required Function(int) onEpisodeChanged,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            '选集列表',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          Text(
            '${currPlayIndex + 1}/${videoList.length}',
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
      const SizedBox(height: 10),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 2.4,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: visibleIndexes.length,
        itemBuilder: (context, i) {
          final index = visibleIndexes[i];
          return EpisodeItem(
            index: index,
            rawTitle: videoList[index].title,
            isSelected: index == currPlayIndex,
            onTap: () => onEpisodeChanged(index),
          );
        },
      ),
    ],
  );
}

/// 播放页横向滚动选集列表。
Widget buildHorizontalEpisodeList({
  required BuildContext context,
  required List<PlaybackEpisode> videoList,
  required List<int> filteredList,
  required int currPlayIndex,
  required String videoId,
  required Function(int) onEpisodeChanged,
}) {
  return SizedBox(
    height: 52,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: filteredList.length,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (context, i) {
        final index = filteredList[i];
        return SizedBox(
          width: 120,
          child: EpisodeItem(
            index: index,
            rawTitle: videoList[index].title,
            isSelected: index == currPlayIndex,
            isWatched: VideoUtils.isEpisodeWatched(videoId, index),
            onTap: () => onEpisodeChanged(index),
          ),
        );
      },
    ),
  );
}
