import 'package:flutter/material.dart';
import 'package:baka/utils/format_utils.dart';

import 'package:baka/models/download_task.dart';
import 'package:baka/services/download_service.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:baka/services/torrent/torrent_engine.dart';
import 'package:baka/services/torrent/torrent_service.dart';

class ActiveDownloadIndicator extends StatefulWidget {
  final String taskIdPrefix;

  const ActiveDownloadIndicator({required this.taskIdPrefix, super.key});

  @override
  State<ActiveDownloadIndicator> createState() =>
      _ActiveDownloadIndicatorState();
}

class _ActiveDownloadIndicatorState extends State<ActiveDownloadIndicator> {
  late final VoidCallback _listener;
  DownloadTask? _currentTask;
  int _activeTaskCount = 0;

  @override
  void initState() {
    super.initState();
    DownloadService.instance.init();
    _listener = _refresh;
    DownloadService.instance.tasksListenable.addListener(_listener);
    _refresh();
  }

  @override
  void dispose() {
    DownloadService.instance.tasksListenable.removeListener(_listener);
    super.dispose();
  }

  void _refresh() {
    DownloadTask? first;
    DownloadTask? downloading;
    var count = 0;
    for (final task in DownloadService.instance.tasks) {
      if (!task.id.startsWith(widget.taskIdPrefix) ||
          task.status == DownloadStatus.completed) {
        continue;
      }
      first ??= task;
      if (task.status == DownloadStatus.downloading) downloading ??= task;
      count++;
    }
    if (mounted) {
      setState(() {
        _currentTask = downloading ?? first;
        _activeTaskCount = count;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _currentTask;
    if (current == null) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return GestureDetector(
      onTap: () => NavigationService.showDownloadManager(context),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.15),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '正在缓存 ${current.subtitle ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.textTheme.bodyMedium?.color,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$_activeTaskCount 个任务',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: theme.colorScheme.primary.withValues(alpha: 0.6),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<double>(
              valueListenable: current.progressNotifier,
              builder: (context, progress, _) {
                return Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        minHeight: 4,
                        backgroundColor: theme.colorScheme.primary.withValues(
                          alpha: 0.1,
                        ),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        ValueListenableBuilder<DownloadStatus>(
                          valueListenable: current.statusNotifier,
                          builder: (context, status, _) {
                            String label;
                            switch (status) {
                              case DownloadStatus.downloading:
                                label = '下载中';
                              case DownloadStatus.waiting:
                                label = '等待中';
                              case DownloadStatus.paused:
                                label = '已暂停';
                              case DownloadStatus.failed:
                                label = '失败';
                              default:
                                label = '';
                            }
                            return Text(
                              label,
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.textTheme.bodyMedium?.color
                                    ?.withValues(alpha: 0.5),
                              ),
                            );
                          },
                        ),
                        Text(
                          '${(progress * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class MobileBtProgressIndicator extends StatelessWidget {
  const MobileBtProgressIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final torrent = TorrentService.instance;
    return ValueListenableBuilder<TorrentStats?>(
      valueListenable: torrent.statsNotifier,
      builder: (context, stats, _) {
        if (stats == null || stats.state == TorrentState.idle) {
          return const SizedBox.shrink();
        }
        return _buildIndicator(context, stats);
      },
    );
  }

  Widget _buildIndicator(BuildContext context, TorrentStats stats) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final bodyColor = theme.textTheme.bodyMedium?.color;
    const readyColor = Color(0xFF34C759);

    final String stateText;
    final IconData stateIcon;
    final Color stateColor;
    switch (stats.state) {
      case TorrentState.resolving:
        stateText = '解析中';
        stateIcon = Icons.manage_search_rounded;
        stateColor = theme.colorScheme.secondary;
      case TorrentState.connecting:
        stateText = '连接 Peers';
        stateIcon = Icons.sync_rounded;
        stateColor = theme.colorScheme.secondary;
      case TorrentState.downloading:
        stateText = '${(stats.progress * 100).toStringAsFixed(1)}%';
        stateIcon = Icons.downloading_rounded;
        stateColor = primary;
      case TorrentState.seeding:
        stateText = '做种中';
        stateIcon = Icons.check_circle_outline_rounded;
        stateColor = readyColor;
      case TorrentState.error:
        stateText = stats.errorMessage ?? '错误';
        stateIcon = Icons.error_outline_rounded;
        stateColor = theme.colorScheme.error;
      default:
        return const SizedBox.shrink();
    }

    final readyToPlay = stats.readyToPlay;
    final speed = stats.downloadSpeed;
    final uploadSpeed = stats.uploadSpeed;
    final uploadedBytes = stats.uploadedBytes;
    final peers = stats.peers;
    final total = stats.totalBytes;
    final contiguous = stats.contiguousBytes;
    final required = stats.bufferRequiredBytes;
    final remaining = (required - contiguous).clamp(0, required);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: stateColor.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: stateColor.withValues(alpha: 0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(stateIcon, size: 14, color: stateColor),
                const SizedBox(width: 6),
                Text(
                  'BT $stateText',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: stateColor,
                  ),
                ),
                if (speed > 0 || uploadSpeed > 0) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.arrow_downward_rounded,
                    size: 11,
                    color: primary.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    formatBytesPerSecond(speed),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.arrow_upward_rounded,
                    size: 11,
                    color: Colors.orange.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    formatBytesPerSecond(uploadSpeed),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange,
                    ),
                  ),
                ],
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: readyToPlay
                        ? readyColor.withValues(alpha: 0.1)
                        : bodyColor?.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    readyToPlay ? '可播放' : '缓冲中',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: readyToPlay
                          ? readyColor
                          : bodyColor?.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                if (peers > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    '$peers peers',
                    style: TextStyle(
                      fontSize: 10,
                      color: bodyColor?.withValues(alpha: 0.4),
                    ),
                  ),
                ],
                if (uploadedBytes > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    '↑${formatBytes(uploadedBytes)}',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.orange.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: stats.progress.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: stateColor.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation<Color>(stateColor),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  readyToPlay
                      ? '缓冲 ${formatBytes(contiguous)}/${formatBytes(required)}'
                      : '待缓冲 ${formatBytes(remaining)}',
                  style: TextStyle(
                    fontSize: 10,
                    color: bodyColor?.withValues(alpha: 0.45),
                  ),
                ),
                if (total > 0)
                  Text(
                    '${formatBytes(stats.downloadedBytes)} / ${formatBytes(total)}',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: bodyColor?.withValues(alpha: 0.5),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
