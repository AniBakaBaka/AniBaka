import 'package:baka/source/source_registry.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/reg_utils.dart';
import 'package:baka/widgets/platform/windows/windows_post_card.dart';
import 'package:flutter/material.dart';

const _kTagTextStyle = TextStyle(
  color: Colors.white,
  fontSize: 10,
  fontWeight: FontWeight.bold,
);

typedef PostCardMeta = ({String displayTag, String? scoreText});
typedef ProgressInfo = ({
  double progress,
  String watchTimeText,
  String positionText,
  String episodeText,
});

PostCardMeta resolvePostCardMeta(Map data) {
  final scoreText = _resolveScoreText(data['score']);
  final source = data['source']?.toString();

  final displayTag = switch (source) {
    'bgm' => _buildBgmTag(data['info']?.toString(), scoreText),
    _ when AdapterRegistry.isAdapterSource(source) =>
      data['tag']?.toString() ?? '番剧',
    _ => '',
  };

  return (displayTag: displayTag, scoreText: scoreText);
}

ProgressInfo resolveProgressInfo(Map data) {
  final positionText = _formatPosition(data['position']);
  final indexData = data['index'];
  final episodeIndex = indexData is int
      ? indexData
      : int.tryParse(indexData?.toString() ?? '');
  final line = data['url']?.toString();

  return (
    progress: _resolveProgress(data['position'], data['duration']),
    watchTimeText: _formatWatchTime(data['watchTime']),
    positionText: positionText,
    episodeText: [
      if (episodeIndex != null) '第${episodeIndex + 1}集',
      if (positionText.isNotEmpty) positionText,
      if (line != null && line.isNotEmpty) '线路$line',
    ].join(' · '),
  );
}

String? _resolveScoreText(dynamic value) {
  if (value == null) return null;
  final score = _asDouble(value);
  return score > 0 ? score.toStringAsFixed(1) : null;
}

String _buildBgmTag(String? info, String? scoreText) {
  String? ep;
  if (info != null) {
    for (final p in info.split('/')) {
      if (p.contains('话')) {
        ep = p.trim();
        break;
      }
    }
  }
  if (ep != null && scoreText != null) return '$ep · $scoreText';
  return ep ?? (scoreText != null ? '评分 $scoreText' : '');
}

double _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0.0;
  return 0.0;
}

String _formatWatchTime(dynamic watchTimeMs) {
  final watchTimeValue = _asDouble(watchTimeMs).toInt();
  if (watchTimeValue <= 0) return '';

  final diff = DateTime.now().millisecondsSinceEpoch - watchTimeValue;
  if (diff < 0) return '刚刚';

  if (diff >= 86400000) return '${diff ~/ 86400000}天前';
  if (diff >= 3600000) return '${diff ~/ 3600000}小时前';
  if (diff >= 60000) return '${diff ~/ 60000}分钟前';
  return '刚刚';
}

String _formatPosition(dynamic positionMs) {
  final position = _asDouble(positionMs);
  if (position <= 0) return '';
  final secs = (position / 1000).round();
  return '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
}

double _resolveProgress(dynamic position, dynamic duration) {
  final total = _asDouble(duration);
  return total > 0 ? (_asDouble(position) / total).clamp(0.0, 1.0) : 0.0;
}

String coverHeroTag(Map data) {
  final override = data['_heroTag'];
  if (override != null) return override.toString();
  final base = data['url']?.toString() ?? data['title']?.toString() ?? 'cover';
  return '${base}_${data.hashCode}';
}

void navigateToDetail(BuildContext context, Map data, {int? posIndex}) {
  NavigationService.toDetail(context, data, posIndex: posIndex);
}

Widget buildCachedImage(
  Object? imageUrl,
  double width,
  double height, {
  BoxFit fit = BoxFit.cover,
}) {
  final resolvedUrl = imageUrl is Map
      ? BgmUtils.resolveCoverImage(imageUrl) ?? getSuo(imageUrl['content'])
      : getSuo(imageUrl?.toString() ?? '');
  return CachedNetworkImage(
    memCacheWidth: 300,
    imageUrl: resolvedUrl,
    width: width,
    height: height,
    fit: fit,
    useOldImageOnUrlChange: true,
    fadeInDuration: Duration.zero,
    fadeOutDuration: Duration.zero,
    placeholder: (context, url) => Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
    errorWidget: (context, url, error) {
      final theme = Theme.of(context);
      return ColoredBox(
        color: theme.cardColor.withValues(alpha: 0.5),
        child: Center(
          child: Icon(
            Icons.broken_image_outlined,
            color: theme.disabledColor,
            size: 24,
          ),
        ),
      );
    },
  );
}

class PostCard extends StatelessWidget {
  final Map data;
  final VoidCallback? onTap;

  const PostCard(this.data, {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final meta = resolvePostCardMeta(data);

    return GestureDetector(
      onTap: onTap ?? () => navigateToDetail(context, data),
      child: Instances.isWindows
          ? WindowsCard(
              data: data,
              displayTag: meta.displayTag,
              scoreText: meta.scoreText,
              heroTag: coverHeroTag(data),
              image: buildCachedImage(data, double.infinity, double.infinity),
            )
          : _MobileCard(data: data, meta: meta),
    );
  }
}

class _MobileCard extends StatelessWidget {
  final Map data;
  final PostCardMeta meta;

  const _MobileCard({required this.data, required this.meta});

  @override
  Widget build(BuildContext context) {
    final cover = AspectRatio(
      aspectRatio: 2 / 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12.0),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Hero(
              tag: coverHeroTag(data),
              child: buildCachedImage(data, double.infinity, double.infinity),
            ),
            if (meta.displayTag.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Text(
                      meta.displayTag,
                      style: _kTagTextStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    // 瀑布流（SliverMasonryGrid）给的是无界高度，Expanded 会直接抛
    // RenderFlex 断言；只有在高度有界的网格里才用 Expanded 收缩封面。
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded = constraints.hasBoundedHeight;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
          children: [
            if (bounded) Expanded(child: cover) else cover,
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                data['title']?.toString() ?? '未知标题',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  color: Theme.of(context).textTheme.bodyMedium?.color,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
