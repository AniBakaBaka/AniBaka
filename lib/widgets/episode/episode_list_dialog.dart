import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/models/download_task.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/services/download_service.dart';
import 'package:baka/services/player_service.dart';
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
  required Function(int) onEpisodeChanged,
  bool isFullScreen = false,
  Map? postDetail,
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
    onEpisodeChanged: onEpisodeChanged,
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
  final Function(int) onEpisodeChanged;
  final Map? postDetail;
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
    required this.onEpisodeChanged,
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

  late final Set<String> _queuedIds;
  late final String _taskIdPrefix;
  late final List<int> _selectableIndexes;

  @override
  void initState() {
    super.initState();
    _downloadMode = widget.startInDownloadMode && widget.canDownload;
    if (widget.canDownload) {
      DownloadService.instance.init();
      _queuedIds = DownloadService.instance.tasks.map((t) => t.id).toSet();
      final detail = widget.postDetail!;
      final source = detail['source']?.toString() ?? '';
      final id = detail['id'];
      _taskIdPrefix = source.isNotEmpty ? '${source}_${id}_' : '${id}_';
      _selectableIndexes = [
        for (var i = 0; i < widget.videoList.length; i++)
          if (!_queuedIds.contains(_taskId(i))) i,
      ];
    } else {
      _queuedIds = const {};
      _taskIdPrefix = '';
      _selectableIndexes = const [];
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _taskId(int index) => '$_taskIdPrefix${index + 1}';

  List<int> get _visibleIndexes => PlaybackEpisodeCatalog.filterIndexes(
    widget.videoList,
    searchQuery: _searchQuery,
    ascending: _sortAscending,
  );

  bool get _isAllSelected =>
      _selectableIndexes.isNotEmpty &&
      _selected.length == _selectableIndexes.length;

  int get _lineCount {
    final i = widget.currentIndex;
    if (i < 0 || i >= widget.videoList.length) return 0;
    return widget.videoList[i].lineCount;
  }

  bool get _canSwitchLine =>
      !_downloadMode && widget.onLineChanged != null && _lineCount > 1;

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
      if (!_downloadMode) _selected.clear();
    });
  }

  void _toggleSelectAll() {
    if (_selectableIndexes.isEmpty) return;
    setState(() {
      if (_isAllSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_selectableIndexes);
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
    final indices = _selected.toList()..sort();
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('开始在后台解析 ${indices.length} 集')));
    Navigator.pop(context);
    _resolveAndEnqueue(indices);
  }

  Future<void> _resolveAndEnqueue(List<int> indices) async {
    final service = DownloadService.instance;
    final detail = widget.postDetail!;
    final bgmId = (await BgmService.resolveFromData(
      detail,
    )).subjectId?.toString();

    final sourceName = detail['sourceDisplayName']?.toString() ?? '';
    final title = (detail['title'] ?? '未知标题').toString();
    final thumbnail =
        (detail['pic'] ?? detail['image'] ?? detail['bgmImageUrl'] ?? '')
            .toString();
    final filenamePrefix = sourceName.isNotEmpty
        ? '${title}_[$sourceName]_'
        : '${title}_';
    final subtitlePrefix = sourceName.isNotEmpty ? '$sourceName · ' : '';

    for (final index in indices) {
      try {
        final resolvedUrl = await widget.urlResolver!(index);
        if (resolvedUrl == null || resolvedUrl.isEmpty) continue;
        final episodeTitle = widget.videoList[index].title;
        final kind = DownloadTask.inferKind(resolvedUrl);
        final extension = kind == DownloadTaskKind.hls ? 'm3u8' : 'mp4';
        service.addTasks([
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
        ]);
      } catch (_) {}
    }
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
    final visible = _visibleIndexes;

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
            itemCount: visible.length,
            itemBuilder: (_, i) => _buildItem(visible[i], textColor),
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
            onPressed: _toggleSelectAll,
            style: textColor == null
                ? null
                : TextButton.styleFrom(foregroundColor: textColor),
            child: Text(_isAllSelected ? '取消全选' : '全选'),
          )
        else
          IconButton(
            onPressed: () => setState(() => _sortAscending = !_sortAscending),
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
        itemCount: _lineCount,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final lineIndex = index + 1;
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
        onChanged: (value) => setState(() => _searchQuery = value),
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
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
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
        isQueued: _queuedIds.contains(_taskId(index)),
        isDownloadSelected: selected,
        textColor: textColor,
        onTap: () {
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
      isWatched: VideoUtils.isEpisodeWatched(widget.videoId, index, null),
      textColor: textColor,
      onTap: () {
        widget.onEpisodeChanged(index);
        Navigator.pop(context, index);
      },
    );
  }
}
