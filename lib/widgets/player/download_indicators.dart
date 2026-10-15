import 'package:flutter/material.dart';
import 'package:baka/utils/format_utils.dart';

import 'package:baka/models/download_task.dart';
import 'package:baka/pages/player/download_page.dart';
import 'package:baka/services/download/download_manager.dart';
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
  DownloadTask? _currentTask;
  int _activeTaskCount = 0;

  @override
  void initState() {
    super.initState();
    downloads.init();
    downloads.tasksListenable.addListener(_refresh);
    _refresh();
  }

  @override
  void dispose() {
    downloads.tasksListenable.removeListener(_refresh);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ActiveDownloadIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskIdPrefix != widget.taskIdPrefix) _refresh();
  }

  void _refresh() {
    DownloadTask? first;
    DownloadTask? downloading;
    var count = 0;
    for (final task in downloads.tasks) {
      if (!task.id.startsWith(widget.taskIdPrefix) ||
          task.status == DownloadStatus.completed) {
        continue;
      }
      first ??= task;
      if (task.status == DownloadStatus.downloading) downloading ??= task;
      count++;
    }
    final current = downloading ?? first;
    if (current != _currentTask || count != _activeTaskCount) {
      setState(() {
        _currentTask = current;
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
      onTap: () => DownloadManagerPage.show(context),
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
              child: ValueListenableBuilder<DownloadStatus>(
                valueListenable: current.statusNotifier,
                builder: (context, status, _) => Text(
                  switch (status) {
                    DownloadStatus.downloading => '下载中',
                    DownloadStatus.waiting => '等待中',
                    DownloadStatus.paused => '已暂停',
                    DownloadStatus.failed => '失败',
                    DownloadStatus.completed => '',
                  },
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.textTheme.bodyMedium?.color?.withValues(
                      alpha: 0.5,
                    ),
                  ),
                ),
              ),
              builder: (context, progress, status) {
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
                        status!,
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

class BtProgressIndicator extends StatelessWidget {
  const BtProgressIndicator({
    required this.torrent,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 12),
    super.key,
  });
  final TorrentService torrent;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
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
    final Color stateColor;
    switch (stats.state) {
      case TorrentState.resolving:
        stateText = '解析中';
        stateColor = theme.colorScheme.secondary;
      case TorrentState.connecting:
        stateText = '连接 Peers';
        stateColor = theme.colorScheme.secondary;
      case TorrentState.downloading:
        stateText = '${(stats.progress * 100).toStringAsFixed(1)}%';
        stateColor = primary;
      case TorrentState.seeding:
        stateText = '做种中';
        stateColor = readyColor;
      case TorrentState.error:
        stateText = stats.errorMessage ?? '错误';
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
      padding: padding,
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
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'BT $stateText',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: stateColor,
                  ),
                ),
                if (speed > 0 || uploadSpeed > 0) ...[
                  Text(
                    '↓ ${formatBytesPerSecond(speed)}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: primary,
                    ),
                  ),
                  Text(
                    '↑ ${formatBytesPerSecond(uploadSpeed)}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange,
                    ),
                  ),
                ],
                if (stats.state != TorrentState.error)
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
                  Text(
                    '$peers peers',
                    style: TextStyle(
                      fontSize: 10,
                      color: bodyColor?.withValues(alpha: 0.4),
                    ),
                  ),
                ],
                if (uploadedBytes > 0) ...[
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
                value:
                    stats.state == TorrentState.resolving ||
                        stats.state == TorrentState.connecting
                    ? null
                    : stats.progress.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: stateColor.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation<Color>(stateColor),
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                if (stats.state != TorrentState.error)
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
