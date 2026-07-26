import 'package:cached_network_image/cached_network_image.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:baka/models/download_task.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/services/download_service.dart';
import 'package:baka/widgets/common/shimmer.dart';

class DownloadManagerController extends GetxController {
  final service = DownloadService.instance;
  final tasks = <DownloadTask>[].obs;

  late final VoidCallback _listener;

  @override
  void onInit() {
    super.onInit();
    service.init();
    _listener = () => tasks.value = List.from(service.tasksNotifier.value);
    service.tasksNotifier.addListener(_listener);
    _listener();
  }

  @override
  void onClose() {
    service.tasksNotifier.removeListener(_listener);
    super.onClose();
  }

  List<DownloadTask> get activeTasks => tasks.reversed
      .where((t) => t.status != DownloadStatus.completed)
      .toList();

  List<DownloadTask> get completedTasks => tasks.reversed
      .where((t) => t.status == DownloadStatus.completed)
      .toList();

  Map<String, List<DownloadTask>> get groupedCompletedTasks {
    final grouped = <String, List<DownloadTask>>{};
    for (final task in completedTasks) {
      if (!grouped.containsKey(task.title)) {
        grouped[task.title] = [];
      }
      grouped[task.title]!.add(task);
    }
    return grouped;
  }

  void pauseAll() => service.pauseAll();
  void resumeAll() => service.resumeAll();
  void clearCompleted() => service.clearCompleted();
}

class DownloadManagerPage extends StatelessWidget {
  const DownloadManagerPage({super.key});

  static void show(BuildContext context) {
    DownloadService.instance.init();
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const DownloadManagerPage()));
  }

  @override
  Widget build(BuildContext context) {
    final c = Get.put(DownloadManagerController());
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('缓存'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (val) {
              if (val == 'pause_all') c.pauseAll();
              if (val == 'resume_all') c.resumeAll();
              if (val == 'clear_completed') c.clearCompleted();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'pause_all', child: Text('全部暂停')),
              PopupMenuItem(value: 'resume_all', child: Text('全部继续')),
              PopupMenuItem(value: 'clear_completed', child: Text('清除已完成记录')),
            ],
          ),
        ],
      ),
      body: Obx(() {
        final active = c.activeTasks;
        final groups = c.groupedCompletedTasks.entries.toList();

        if (c.tasks.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.download_done_rounded,
                  size: 48,
                  color: theme.disabledColor,
                ),
                const SizedBox(height: 12),
                Text(
                  '暂时没有任何下载',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            if (active.isNotEmpty) ...[
              _sectionTitle(theme, '下载中 · ${active.length}'),
              for (final task in active)
                _TaskCard(key: ValueKey(task.id), task: task),
            ],
            if (groups.isNotEmpty) ...[
              _sectionTitle(theme, '已完成 · ${groups.length}'),
              for (final group in groups)
                _AnimeGroupCard(
                  key: ValueKey('group_${group.key}'),
                  title: group.key,
                  tasks: group.value,
                ),
            ],
          ],
        );
      }),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

Widget _dismissBackground(ThemeData theme) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: theme.colorScheme.error,
      borderRadius: BorderRadius.circular(12),
    ),
    alignment: Alignment.centerRight,
    padding: const EdgeInsets.only(right: 24),
    child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
  );
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = ColoredBox(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
      child: Icon(Icons.movie_outlined, color: theme.disabledColor),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 96,
        height: 60,
        child: (url == null || url!.isEmpty)
            ? fallback
            : CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                placeholder: (_, _) => const ShimmerBox(
                  width: double.infinity,
                  height: double.infinity,
                ),
                errorWidget: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  final DownloadTask task;

  const _TaskCard({required this.task, super.key});

  void _onTap(BuildContext context) {
    final service = DownloadService.instance;
    switch (task.status) {
      case DownloadStatus.downloading:
        service.pause(task);
      case DownloadStatus.paused:
      case DownloadStatus.failed:
      case DownloadStatus.waiting:
        service.resume(task);
      case DownloadStatus.completed:
        if (task.filePath != null) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlayerPage(
                data: {
                  'source': '_local',
                  'title': task.title,
                  'episodeTitle': task.subtitle,
                  'localFilePath': task.filePath!,
                  'danmakuPath': task.danmakuPath,
                  'id': 0,
                },
              ),
            ),
          );
        }
    }
  }

  (String, IconData) _statusInfo(DownloadStatus status) {
    return switch (status) {
      DownloadStatus.waiting => ('等待中', Icons.schedule_rounded),
      DownloadStatus.downloading => ('下载中', Icons.pause_rounded),
      DownloadStatus.paused => ('已暂停', Icons.play_arrow_rounded),
      DownloadStatus.completed => ('已完成', Icons.play_arrow_rounded),
      DownloadStatus.failed => ('下载失败', Icons.refresh_rounded),
    };
  }

  Color _statusColor(ThemeData theme, DownloadStatus status) {
    return switch (status) {
      DownloadStatus.downloading => theme.colorScheme.primary,
      DownloadStatus.paused => const Color(0xFFF59E0B),
      DownloadStatus.failed => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dismissible(
      key: ValueKey('dismiss_${task.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => DownloadService.instance.delete(task),
      background: _dismissBackground(theme),
      child: ValueListenableBuilder<DownloadStatus>(
        valueListenable: task.statusNotifier,
        builder: (context, status, _) {
          final (statusText, actionIcon) = _statusInfo(status);
          final statusColor = _statusColor(theme, status);

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _onTap(context),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    _Thumbnail(url: task.thumbnail),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            task.subtitle ?? '未知剧集',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (status == DownloadStatus.completed) ...[
                            const SizedBox(height: 4),
                            Text(
                              formatBytes(task.totalBytes),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ] else ...[
                            const SizedBox(height: 8),
                            ValueListenableBuilder<double>(
                              valueListenable: task.progressNotifier,
                              builder: (context, progress, _) => ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: progress.clamp(0.0, 1.0),
                                  minHeight: 3,
                                  backgroundColor: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.08),
                                  color: statusColor,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            ValueListenableBuilder<int>(
                              valueListenable: task.downloadedBytesNotifier,
                              builder: (context, bytes, _) => Text(
                                task.totalBytes > 0
                                    ? '$statusText · ${formatBytes(bytes)} / ${formatBytes(task.totalBytes)}'
                                    : '$statusText · ${(task.progress * 100).toStringAsFixed(0)}%',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: statusColor,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      actionIcon,
                      size: 22,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AnimeGroupCard extends StatelessWidget {
  final String title;
  final List<DownloadTask> tasks;

  const _AnimeGroupCard({required this.title, required this.tasks, super.key});

  Future<bool?> _confirmDelete(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除合集'),
        content: Text('确定要删除《$title》的所有已下载剧集吗？这会清除本地文件且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalBytes = tasks.fold(0, (sum, t) => sum + t.totalBytes);

    return Dismissible(
      key: ValueKey('dismiss_group_$title'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) {
        for (final task in tasks) {
          DownloadService.instance.delete(task);
        }
      },
      background: _dismissBackground(theme),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => _AnimeGroupPage(title: title)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                _Thumbnail(url: tasks.first.thumbnail),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '共 ${tasks.length} 集 · ${formatBytes(totalBytes)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimeGroupPage extends StatelessWidget {
  final String title;

  const _AnimeGroupPage({required this.title});

  @override
  Widget build(BuildContext context) {
    final c = Get.find<DownloadManagerController>();

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Obx(() {
        final groupTasks = c.completedTasks
            .where((t) => t.title == title)
            .toList();

        if (groupTasks.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          });
          return const SizedBox.shrink();
        }

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          itemCount: groupTasks.length,
          itemBuilder: (context, i) =>
              _TaskCard(key: ValueKey(groupTasks[i].id), task: groupTasks[i]),
        );
      }),
    );
  }
}
