import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/models/download_task.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/services/download/download_manager.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/widgets/episode/episode_widgets.dart';

const _kSearchThreshold = 12;
const _kSidebarWidth = 300.0;

/// 选集/缓存选择面板：全屏播放时为右侧栏，否则为底部弹层。
Future<int?> showEpisodeListDialog({
  required BuildContext context,
  required List<PlaybackEpisode> videoList,
  required int currentIndex,
  required String videoId,
  bool isFullScreen = false,
  Map<String, dynamic>? postDetail,
  Future<String?> Function(int episodeIndex)? urlResolver,
  bool startInDownloadMode = false,
  int? currentLineIndex,
  List<String>? sourceNames,
  ValueChanged<int>? onLineChanged,
}) {
  final panel = EpisodeListDialog(
    videoList: videoList,
    currentIndex: currentIndex,
    videoId: videoId,
    isFullScreen: isFullScreen,
    postDetail: postDetail,
    urlResolver: urlResolver,
    startInDownloadMode: startInDownloadMode,
    currentLineIndex: currentLineIndex,
    sourceNames: sourceNames,
    onLineChanged: onLineChanged,
  );

  if (isFullScreen) {
    return showGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '选集',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (_, _, _) =>
          Align(alignment: Alignment.centerRight, child: panel),
      transitionBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: child,
      ),
    );
  }

  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (_) => panel,
  );
}

class EpisodeListDialog extends StatefulWidget {
  final List<PlaybackEpisode> videoList;
  final int currentIndex;
  final String videoId;
  final bool isFullScreen;
  final Map<String, dynamic>? postDetail;
  final Future<String?> Function(int episodeIndex)? urlResolver;
  final bool startInDownloadMode;
  final int? currentLineIndex;
  final List<String>? sourceNames;
  final ValueChanged<int>? onLineChanged;

  bool get canDownload => postDetail != null && urlResolver != null;

  const EpisodeListDialog({
    required this.videoList,
    required this.currentIndex,
    required this.videoId,
    required this.isFullScreen,
    super.key,
    this.postDetail,
    this.urlResolver,
    this.startInDownloadMode = false,
    this.currentLineIndex,
    this.sourceNames,
    this.onLineChanged,
  });

  @override
  State<EpisodeListDialog> createState() => _EpisodeListDialogState();
}

class _EpisodeListDialogState extends State<EpisodeListDialog> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  bool _sortAscending = true;
  late bool _downloadMode;
  final Set<int> _selected = {};

  Set<int>? _queuedIndexes;
  late final String _taskIdPrefix;
  List<int>? _visibleIndexes;
  late final List<int> _lineIndexes =
      widget.currentIndex < 0 || widget.currentIndex >= widget.videoList.length
      ? const []
      : widget.videoList[widget.currentIndex].availableLineIndexes.toList(
          growable: false,
        );

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _downloadMode = widget.startInDownloadMode && widget.canDownload;
    if (widget.canDownload) {
      final detail = widget.postDetail!;
      final source = detail['source'] as String? ?? '';
      final id = detail['id'];
      _taskIdPrefix = source.isNotEmpty ? '${source}_${id}_' : '${id}_';
      if (_downloadMode) _loadQueuedEpisodes();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _taskId(int index) => '$_taskIdPrefix${index + 1}';

  Future<void> _loadQueuedEpisodes() async {
    await downloads.init();
    if (!mounted || !_downloadMode) return;
    setState(() {
      _queuedIndexes = {
        for (final task in downloads.tasks)
          if (task.id.startsWith(_taskIdPrefix))
            if (task.episodeIndex case final episode?)
              if (episode > 0 &&
                  episode <= widget.videoList.length &&
                  task.id == _taskId(episode - 1))
                episode - 1,
      };
    });
  }

  void _onSearchChanged() {
    final query = _searchController.text;
    if (_searchQuery == query) return;
    setState(() {
      final normalized = query.trim().toLowerCase();
      if (normalized != _searchQuery.trim().toLowerCase()) {
        _visibleIndexes = normalized.isEmpty
            ? null
            : PlaybackEpisodeCatalog.filterIndexes(
                widget.videoList,
                searchQuery: normalized,
                ascending: true,
              );
      }
      _searchQuery = query;
    });
  }

  bool get _isAllSelected =>
      _selected.isNotEmpty &&
      _selected.length == widget.videoList.length - _queuedIndexes!.length;

  bool get _canSwitchLine =>
      !_downloadMode && widget.onLineChanged != null && _lineIndexes.length > 1;

  String _lineName(int lineIndex) {
    final names = widget.sourceNames;
    if (names != null && lineIndex > 0 && lineIndex <= names.length) {
      final name = names[lineIndex - 1].trim();
      if (name.isNotEmpty) return name;
    }
    return '线路 $lineIndex';
  }

  void _toggleDownloadMode() {
    HapticFeedback.lightImpact();
    setState(() {
      _downloadMode = !_downloadMode;
      _queuedIndexes = null;
      _selected.clear();
    });
    if (_downloadMode) _loadQueuedEpisodes();
  }

  void _toggleSelectAll() {
    setState(() {
      if (_isAllSelected) {
        _selected.clear();
      } else {
        _selected.clear();
        for (var i = 0; i < widget.videoList.length; i++) {
          if (!_queuedIndexes!.contains(i)) _selected.add(i);
        }
      }
    });
  }

  void _selectLine(int lineIndex) {
    if (lineIndex == (widget.currentLineIndex ?? 1)) return;
    HapticFeedback.selectionClick();
    widget.onLineChanged?.call(lineIndex);
    Navigator.pop(context);
  }

  void _submitDownload() {
    if (_selected.isEmpty) return;
    final indices = [
      for (var index = 0; index < widget.videoList.length; index++)
        if (_selected.contains(index)) index,
    ];
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('开始在后台解析 ${indices.length} 集')));
    Navigator.pop(context);
    _resolveAndEnqueue(indices).ignore();
  }

  Future<void> _resolveAndEnqueue(List<int> indices) async {
    final service = downloads;
    final detail = widget.postDetail!;
    final bgmId = (await resolveBgmFromData(detail)).subjectId;

    final sourceName = detail['sourceDisplayName'] as String? ?? '';
    final title = detail['title'] as String? ?? '';
    final thumbnail = resolveCoverImage(detail);
    final filenamePrefix = sourceName.isNotEmpty
        ? '${title}_[$sourceName]_'
        : '${title}_';
    final subtitlePrefix = sourceName.isNotEmpty ? '$sourceName · ' : '';

    final tasks = <DownloadTask>[];
    for (final index in indices) {
      try {
        final resolvedUrl = await widget.urlResolver!(index);
        if (resolvedUrl == null || resolvedUrl.isEmpty) continue;
        final episodeTitle = widget.videoList[index].title;
        final kind = DownloadTask.inferKind(resolvedUrl);
        final extension = kind == DownloadTaskKind.hls ? 'm3u8' : 'mp4';
        tasks.add(
          DownloadTask(
            id: _taskId(index),
            url: resolvedUrl,
            filename: '$filenamePrefix${episodeTitle}_${index + 1}.$extension',
            title: title,
            subtitle: '$subtitlePrefix$episodeTitle',
            thumbnail: thumbnail,
            bgmId: bgmId,
            episodeIndex: index + 1,
            kind: kind,
          ),
        );
      } catch (error) {
        debugPrint('resolve download episode ${index + 1}: $error');
      }
    }
    service.addTasks(tasks);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isFullScreen) {
      return Material(
        color: Colors.black.withValues(alpha: 0.88),
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: _kSidebarWidth,
          height: double.infinity,
          child: SafeArea(
            left: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: _buildBody(Colors.white),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.68,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: _buildBody(null),
        ),
      ),
    );
  }

  Widget _buildBody(Color? textColor) {
    final showSearch =
        widget.videoList.length > _kSearchThreshold && !_downloadMode;
    final visible = _downloadMode ? null : _visibleIndexes;
    final count = visible?.length ?? widget.videoList.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(textColor),
        if (_canSwitchLine) ...[
          _buildLineChips(textColor),
          const SizedBox(height: 10),
        ],
        if (showSearch) ...[
          _buildSearchField(textColor),
          const SizedBox(height: 10),
        ],
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.only(bottom: 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 1.5,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: count,
            itemBuilder: (_, i) {
              final position = _sortAscending ? i : count - 1 - i;
              return _buildItem(visible?[position] ?? position, textColor);
            },
          ),
        ),
        if (_downloadMode)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                onPressed: _selected.isEmpty ? null : _submitDownload,
                child: Text(
                  _selected.isEmpty
                      ? '请选择要缓存的集数'
                      : '开始缓存 (${_selected.length})',
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHeader(Color? textColor) {
    final muted = (textColor ?? Theme.of(context).colorScheme.onSurface)
        .withValues(alpha: 0.5);

    return Row(
      children: [
        Text(
          _downloadMode ? '缓存' : '选集',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${widget.currentIndex + 1} / ${widget.videoList.length}',
          style: TextStyle(fontSize: 12, color: muted),
        ),
        const Spacer(),
        if (_downloadMode)
          TextButton(
            onPressed: _queuedIndexes == null ? null : _toggleSelectAll,
            style: textColor == null
                ? null
                : TextButton.styleFrom(foregroundColor: textColor),
            child: Text(_isAllSelected ? '取消全选' : '全选'),
          )
        else
          IconButton(
            onPressed: () => setState(() {
              _sortAscending = !_sortAscending;
            }),
            icon: Icon(
              _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
              size: 20,
              color: textColor,
            ),
          ),
        if (widget.canDownload)
          IconButton(
            onPressed: _toggleDownloadMode,
            icon: Icon(
              _downloadMode ? Icons.close_rounded : Icons.download_rounded,
              size: 20,
              color: textColor,
            ),
          ),
        if (!_downloadMode)
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: Icon(Icons.close, size: 20, color: textColor),
          ),
      ],
    );
  }

  Widget _buildLineChips(Color? textColor) {
    final theme = Theme.of(context);
    final base = textColor ?? theme.colorScheme.onSurface;
    final primary = theme.colorScheme.primary;
    final current = widget.currentLineIndex ?? 1;

    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _lineIndexes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final lineIndex = _lineIndexes[index];
          final selected = lineIndex == current;
          return InkWell(
            onTap: selected ? null : () => _selectLine(lineIndex),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 132),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? primary.withValues(alpha: 0.15)
                    : base.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                _lineName(lineIndex),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected
                      ? (textColor ?? primary)
                      : base.withValues(alpha: 0.7),
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSearchField(Color? textColor) {
    final base = textColor ?? Theme.of(context).colorScheme.onSurface;

    return SizedBox(
      height: 36,
      child: TextField(
        controller: _searchController,
        style: TextStyle(color: textColor, fontSize: 13),
        decoration: InputDecoration(
          hintText: '搜索剧集',
          hintStyle: TextStyle(
            color: base.withValues(alpha: 0.4),
            fontSize: 13,
          ),
          prefixIcon: Icon(
            Icons.search,
            size: 18,
            color: base.withValues(alpha: 0.4),
          ),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  onPressed: _searchController.clear,
                  icon: Icon(
                    Icons.close,
                    size: 16,
                    color: base.withValues(alpha: 0.5),
                  ),
                ),
          filled: true,
          fillColor: base.withValues(alpha: 0.06),
          isDense: true,
          contentPadding: EdgeInsets.zero,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildItem(int index, Color? textColor) {
    final rawTitle = widget.videoList[index].title;

    if (_downloadMode) {
      final selected = _selected.contains(index);
      return EpisodeItem(
        index: index,
        rawTitle: rawTitle,
        isDownloadMode: true,
        isQueued: _queuedIndexes?.contains(index) ?? false,
        isDownloadSelected: selected,
        textColor: textColor,
        onTap: _queuedIndexes == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                setState(() {
                  if (selected) {
                    _selected.remove(index);
                  } else {
                    _selected.add(index);
                  }
                });
              },
      );
    }

    return EpisodeItem(
      index: index,
      rawTitle: rawTitle,
      isSelected: index == widget.currentIndex,
      isWatched: HistoryRepository.isEpisodeWatched(widget.videoId, index),
      textColor: textColor,
      onTap: () => Navigator.pop(context, index),
    );
  }
}
