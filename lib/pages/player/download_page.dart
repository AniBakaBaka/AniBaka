import 'package:baka/models/playback_request.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/models/download_task.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/services/download/download_manager.dart';

/// 多选状态下按 Esc 退出（取消全选不再自动退出多选）。
class _ExitSelectIntent extends Intent {
  const _ExitSelectIntent();
}

/// 仅多选状态下挂接 Esc 快捷键；非多选状态原样返回，避免拦截对话框等 Esc。
class _EscapeExitWrapper extends StatelessWidget {
  const _EscapeExitWrapper({
    required this.enabled,
    required this.onExit,
    required this.child,
  });

  final bool enabled;
  final VoidCallback onExit;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): _ExitSelectIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ExitSelectIntent: CallbackAction<_ExitSelectIntent>(
            onInvoke: (_) {
              onExit();
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

/// 标题右侧的长按提示（仅下载管理主页使用；已完成详情页只显示作品名，不显示提示）。
/// 用 FittedBox 在空间不足时整体缩小，避免窄窗口下 AppBar 标题溢出。
Widget _titleWithHint(BuildContext context, String title) {
  final theme = Theme.of(context);
  final titleStyle =
      theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge;
  final hintSize = (titleStyle?.fontSize ?? 20) * 0.8;
  return FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title),
        const SizedBox(width: 12),
        Text(
          '【提示：长按列表任务可进入多选删除界面】',
          style: titleStyle?.copyWith(
            fontSize: hintSize,
            fontWeight: FontWeight.normal,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

class DownloadManagerPage extends StatefulWidget {
  final bool embedded;

  const DownloadManagerPage({super.key, this.embedded = false});

  static void show(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const DownloadManagerPage()));
  }

  @override
  State<DownloadManagerPage> createState() => _DownloadManagerPageState();
}

class _DownloadManagerPageState extends State<DownloadManagerPage> {
  final _service = downloads;
  List<DownloadTask> _active = [];
  List<MapEntry<String, List<DownloadTask>>> _completed = [];
  bool _selectMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _readTasks();
    _service.tasksListenable.addListener(_onTasksChanged);
    downloads.warning.addListener(_onWarningChanged);
    _service.init();
  }

  @override
  void dispose() {
    _service.tasksListenable.removeListener(_onTasksChanged);
    downloads.warning.removeListener(_onWarningChanged);
    super.dispose();
  }

  void _onTasksChanged() => setState(_readTasks);

  void _onWarningChanged() {
    final msg = downloads.warning.value;
    if (msg != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 6)),
      );
    }
  }

  void _enterSelectModeEmpty() {
    setState(() {
      _selectMode = true;
    });
  }

  Future<void> _confirmClearCompleted() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: const Text(
          '将清除全部的【已完成】任务，且无法还原，是否继续',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              '是',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              '否',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) await _service.clearCompleted();
  }

  void _readTasks() {
    final active = <DownloadTask>[];
    final grouped = <String, List<DownloadTask>>{};
    for (final task in _service.tasks.reversed) {
      if (task.status != DownloadStatus.completed) {
        active.add(task);
      } else {
        (grouped[task.title] ??= <DownloadTask>[]).add(task);
      }
    }
    _active = active;
    _completed = grouped.entries.toList(growable: false);
  }

  /// 全部已完成的任务（多选「全选（已完成）」用）。
  List<DownloadTask> get _completedTasks => [
    for (final group in _completed) ...group.value,
  ];

  // ---- 多选删除 ----

  void _enterSelectMode(String id) {
    setState(() {
      _selectMode = true;
      _selectedIds.add(id);
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
      // 取消到一项不剩时仍停留在多选界面，只能手动按 Esc / 左上角关闭退出。
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  bool get _allActiveSelected =>
      _active.isNotEmpty && _active.every((t) => _selectedIds.contains(t.id));

  bool get _allCompletedSelected =>
      _completedTasks.isNotEmpty &&
      _completedTasks.every((t) => _selectedIds.contains(t.id));

  /// 只全选/取消「下载中」任务，不影响已完成任务的选中状态。
  void _toggleSelectAllActive() {
    setState(() {
      final all = _allActiveSelected;
      for (final t in _active) {
        if (all) {
          _selectedIds.remove(t.id);
        } else {
          _selectedIds.add(t.id);
        }
      }
    });
  }

  /// 只全选/取消「已完成」任务，不影响下载中任务的选中状态。
  void _toggleSelectAllCompleted() {
    setState(() {
      final all = _allCompletedSelected;
      for (final t in _completedTasks) {
        if (all) {
          _selectedIds.remove(t.id);
        } else {
          _selectedIds.add(t.id);
        }
      }
    });
  }

  /// 主页「已完成」以作品分组卡片展示，勾选即选中该组全部剧集。
  void _toggleSelectGroup(List<DownloadTask> tasks) {
    setState(() {
      final all = tasks.every((t) => _selectedIds.contains(t.id));
      for (final t in tasks) {
        if (all) {
          _selectedIds.remove(t.id);
        } else {
          _selectedIds.add(t.id);
        }
      }
    });
  }

  void _enterSelectModeGroup(List<DownloadTask> tasks) {
    setState(() {
      _selectMode = true;
      _selectedIds.addAll(tasks.map((t) => t.id));
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final count = _selectedIds.length;
    final confirmed = await confirmDeleteDialog(
      context,
      '确定要删除所选的 $count 项吗？正在下载的任务会被停止，本地文件将被删除且无法恢复。',
    );
    if (confirmed != true || !mounted) return;
    final ids = _selectedIds.toSet();
    for (final task in _service.tasks.toList()) {
      if (ids.contains(task.id)) _service.delete(task);
    }
    _exitSelectMode();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final normalAppBar = AppBar(
      automaticallyImplyLeading: !widget.embedded,
      title: _titleWithHint(context, widget.embedded ? '下载管理' : '缓存'),
      actions: [
        PopupMenuButton<String>(
          onSelected: (val) {
            if (val == 'pause_all') _service.pauseAll();
            if (val == 'resume_all') _service.resumeAll();
            if (val == 'clear_completed') _confirmClearCompleted();
            if (val == 'delete_files') _enterSelectModeEmpty();
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'pause_all', child: Text('全部暂停')),
            PopupMenuItem(value: 'resume_all', child: Text('全部继续')),
            PopupMenuItem(
              value: 'clear_completed',
              child: Text('清除已完成记录（非删除）'),
            ),
            PopupMenuItem(value: 'delete_files', child: Text('删除下载文件')),
          ],
        ),
      ],
    );

    final selectAppBar = AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close_rounded),
        tooltip: '退出多选',
        onPressed: _exitSelectMode,
      ),
      title: Text('已选 ${_selectedIds.length} 项'),
      actions: [
        if (_active.isNotEmpty)
          TextButton(
            onPressed: _toggleSelectAllActive,
            child: Text(
              _allActiveSelected ? '取消全选（下载中）' : '全选（下载中）',
            ),
          ),
        if (_completedTasks.isNotEmpty)
          TextButton(
            onPressed: _toggleSelectAllCompleted,
            child: Text(
              _allCompletedSelected ? '取消全选（已完成）' : '全选（已完成）',
            ),
          ),
        TextButton(
          onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
          child: const Text('删除'),
        ),
      ],
    );

    final page = Scaffold(
      appBar: _selectMode ? selectAppBar : normalAppBar,
      body: _active.isEmpty && _completed.isEmpty
          ? Center(
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
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              itemCount:
                  _active.length +
                  _completed.length +
                  (_active.isEmpty ? 0 : 1) +
                  (_completed.isEmpty ? 0 : 1),
              findChildIndexCallback: (key) {
                if (key is! ValueKey<String>) return null;
                final activeIndex = _active.indexWhere(
                  (task) => task.id == key.value,
                );
                if (activeIndex >= 0) return activeIndex + 1;
                final groupIndex = _completed.indexWhere(
                  (group) => 'group_${group.key}' == key.value,
                );
                return groupIndex < 0
                    ? null
                    : (_active.isEmpty ? 0 : _active.length + 1) +
                          groupIndex +
                          1;
              },
              itemBuilder: (context, index) {
                if (_active.isNotEmpty) {
                  if (index == 0) {
                    return _sectionTitle(theme, '下载中 · ${_active.length}');
                  }
                  index--;
                  if (index < _active.length) {
                    final task = _active[index];
                    return _TaskCard(
                      key: ValueKey(task.id),
                      task: task,
                      selectMode: _selectMode,
                      selected: _selectedIds.contains(task.id),
                      onToggle: () => _toggleSelect(task.id),
                      onLongPress: () => _enterSelectMode(task.id),
                    );
                  }
                  index -= _active.length;
                }
                if (index == 0) {
                  return _sectionTitle(theme, '已完成 · ${_completed.length}');
                }
                final group = _completed[index - 1];
                return _AnimeGroupCard(
                  key: ValueKey('group_${group.key}'),
                  title: group.key,
                  tasks: group.value,
                  selectMode: _selectMode,
                  selected: group.value.every(
                    (t) => _selectedIds.contains(t.id),
                  ),
                  onToggle: () => _toggleSelectGroup(group.value),
                  onLongPress: () => _enterSelectModeGroup(group.value),
                );
              },
            ),
    );
    return _EscapeExitWrapper(
      enabled: _selectMode,
      onExit: _exitSelectMode,
      child: page,
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

Future<bool?> confirmDeleteDialog(BuildContext context, String message) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除下载'),
      content: Text(message),
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
                memCacheWidth: 192,
                fit: BoxFit.cover,
                placeholder: (_, _) => fallback,
                errorWidget: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  final DownloadTask task;
  final bool selectMode;
  final bool selected;
  final VoidCallback? onToggle;
  final VoidCallback? onLongPress;

  const _TaskCard({
    required this.task,
    super.key,
    this.selectMode = false,
    this.selected = false,
    this.onToggle,
    this.onLongPress,
  });

  void _onTap(BuildContext context) {
    final service = downloads;
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
                request: PlaybackRequest.fromMap({
                  'source': '_local',
                  'title': task.title,
                  'episodeTitle': task.subtitle,
                  'localFilePath': task.filePath!,
                  'danmakuPath': task.danmakuPath,
                  'id': 0,
                }),
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
      // 多选模式下禁用右滑删除，避免与勾选状态冲突。
      direction: selectMode
          ? DismissDirection.none
          : DismissDirection.endToStart,
      onDismissed: (_) => downloads.delete(task),
      background: _dismissBackground(theme),
      child: ValueListenableBuilder<DownloadStatus>(
        valueListenable: task.statusNotifier,
        builder: (context, status, _) {
          // HLS 任务在分片全部下完后进入拼接阶段（进度定格 0.99），
          // 显示“合并中”避免看起来像卡死。
          final merging =
              status == DownloadStatus.downloading && task.progress >= 0.99;
          final (statusText, actionIcon) = merging
              ? ('合并中', Icons.pause_rounded)
              : _statusInfo(status);
          final statusColor = _statusColor(theme, status);

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: selectMode ? onToggle : () => _onTap(context),
              onLongPress: onLongPress,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    if (selectMode) ...[
                      Checkbox(
                        value: selected,
                        onChanged: (_) => onToggle?.call(),
                      ),
                      const SizedBox(width: 4),
                    ],
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
  final bool selectMode;
  final bool selected;
  final VoidCallback? onToggle;
  final VoidCallback? onLongPress;

  const _AnimeGroupCard({
    required this.title,
    required this.tasks,
    super.key,
    this.selectMode = false,
    this.selected = false,
    this.onToggle,
    this.onLongPress,
  });

  Future<bool?> _confirmDelete(BuildContext context) {
    return confirmDeleteDialog(
      context,
      '确定要删除《$title》的所有已下载剧集吗？这会清除本地文件且无法恢复。',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalBytes = tasks.fold(0, (sum, t) => sum + t.totalBytes);

    return Dismissible(
      key: ValueKey('dismiss_group_$title'),
      // 多选模式下禁用右滑删除，避免与勾选状态冲突。
      direction: selectMode
          ? DismissDirection.none
          : DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) {
        for (final task in tasks) {
          downloads.delete(task);
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
          onTap: selectMode
              ? onToggle
              : () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => _AnimeGroupPage(title: title),
                  ),
                ),
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                if (selectMode) ...[
                  Checkbox(
                    value: selected,
                    onChanged: (_) => onToggle?.call(),
                  ),
                  const SizedBox(width: 4),
                ],
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

class _AnimeGroupPage extends StatefulWidget {
  final String title;

  const _AnimeGroupPage({required this.title});

  @override
  State<_AnimeGroupPage> createState() => _AnimeGroupPageState();
}

class _AnimeGroupPageState extends State<_AnimeGroupPage> {
  final _service = downloads;
  List<DownloadTask> _tasks = [];
  bool _selectMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _readTasks();
    _service.tasksListenable.addListener(_onTasksChanged);
    downloads.warning.addListener(_onWarningChanged);
  }

  @override
  void dispose() {
    _service.tasksListenable.removeListener(_onTasksChanged);
    downloads.warning.removeListener(_onWarningChanged);
    super.dispose();
  }

  void _readTasks() {
    // 这是「已完成」分组的详情界面，只放下载完成的任务；
    // 下载中 / 等待中 / 失败的任务仍归下载管理主页的「下载中」区。
    _tasks = [
      for (final task in _service.tasks.reversed)
        if (task.title == widget.title &&
            task.status == DownloadStatus.completed)
          task,
    ];
  }

  void _onTasksChanged() => setState(_readTasks);

  void _onWarningChanged() {
    final msg = downloads.warning.value;
    if (msg != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 6)),
      );
    }
  }

  void _enterSelectModeEmpty() {
    setState(() {
      _selectMode = true;
    });
  }

  // ---- 多选删除 ----

  void _enterSelectMode(String id) {
    setState(() {
      _selectMode = true;
      _selectedIds.add(id);
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
      // 取消到一项不剩时仍停留在多选界面，只能手动按 Esc / 左上角关闭退出。
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  bool get _allSelected =>
      _tasks.isNotEmpty && _tasks.every((t) => _selectedIds.contains(t.id));

  void _toggleSelectAll() {
    setState(() {
      if (_allSelected) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(_tasks.map((t) => t.id));
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final count = _selectedIds.length;
    final confirmed = await confirmDeleteDialog(
      context,
      '确定要删除所选的 $count 集吗？本地文件将被删除且无法恢复。',
    );
    if (confirmed != true || !mounted) return;
    final ids = _selectedIds.toSet();
    for (final task in _service.tasks.toList()) {
      if (ids.contains(task.id)) _service.delete(task);
    }
    _exitSelectMode();
  }

  @override
  Widget build(BuildContext context) {
    if (_tasks.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            ModalRoute.of(context)?.isCurrent == true &&
            _tasks.isEmpty &&
            Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
    }
    final page = Scaffold(
      appBar: _selectMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: '退出多选',
                onPressed: _exitSelectMode,
              ),
              title: Text('已选 ${_selectedIds.length} 集'),
              actions: [
                if (_tasks.isNotEmpty)
                  TextButton(
                    onPressed: _toggleSelectAll,
                    child: Text(_allSelected ? '取消全选' : '全选'),
                  ),
                TextButton(
                  onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
                  child: const Text('删除'),
                ),
              ],
            )
          : AppBar(
              title: Text(widget.title),
              actions: [
                PopupMenuButton<String>(
                  onSelected: (val) {
                    if (val == 'delete_files') _enterSelectModeEmpty();
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'delete_files',
                      child: Text('删除下载文件'),
                    ),
                  ],
                ),
              ],
            ),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        itemCount: _tasks.length,
        itemBuilder: (context, i) => _TaskCard(
          key: ValueKey(_tasks[i].id),
          task: _tasks[i],
          selectMode: _selectMode,
          selected: _selectedIds.contains(_tasks[i].id),
          onToggle: () => _toggleSelect(_tasks[i].id),
          onLongPress: () => _enterSelectMode(_tasks[i].id),
        ),
      ),
    );
    return _EscapeExitWrapper(
      enabled: _selectMode,
      onExit: _exitSelectMode,
      child: page,
    );
  }
}
