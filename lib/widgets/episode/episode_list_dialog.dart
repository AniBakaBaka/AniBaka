import 'package:baka/core/app_logger.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/api/anibaka_api.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/download_task.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/services/download/download_manager.dart';
import 'package:baka/services/playback/episode_numbering.dart';
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
  int? bgmSubjectId,
  List<Map<String, dynamic>> bgmEpisodes = const [],
  List<String>? sourceNames,
  ValueChanged<int>? onLineChanged,
  Future<bool> Function(int episodeIndex, bool watched)? onSetEpisodeWatched,
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
    bgmSubjectId: bgmSubjectId,
    bgmEpisodes: bgmEpisodes,
    sourceNames: sourceNames,
    onLineChanged: onLineChanged,
    onSetEpisodeWatched: onSetEpisodeWatched,
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
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    clipBehavior: Clip.antiAlias,
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
  final int? bgmSubjectId;
  final List<Map<String, dynamic>> bgmEpisodes;
  final List<String>? sourceNames;
  final ValueChanged<int>? onLineChanged;

  /// 手动点格子。为 null 表示当前不可用（未登录 Bangumi 或不是 Bangumi 条目）。
  final Future<bool> Function(int episodeIndex, bool watched)?
  onSetEpisodeWatched;

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
    this.bgmSubjectId,
    this.bgmEpisodes = const [],
    this.sourceNames,
    this.onLineChanged,
    this.onSetEpisodeWatched,
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
  late final EpisodeNumbering _numbering = EpisodeNumbering(
    widget.videoList.map((episode) => episode.title),
  );

  /// 本次会话里手动点过的格子，用于列表即时反馈。
  /// 长按后的即时状态。本地写入是异步的，靠它先让角标跟上手指。
  final Map<int, bool> _watchedOverride = {};
  final Set<int> _marking = {};
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
        Log.w('Download', 'resolve download episode ${index + 1}: $error');
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

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: _buildBody(null),
        ),
      ),
    );
  }

  /// 集号：Bangumi 与弹幕都按它记账，而不是源数组的下标。
  int _episodeNumber(int index) => _numbering.numberAt(index) ?? index + 1;

  bool _isWatched(int index) {
    final override = _watchedOverride[_episodeNumber(index)];
    if (override != null) return override;
    return HistoryRepository.isEpisodeWatched(widget.videoId, index);
  }

  /// 长按直接切换：没标过的标为看过，标过的取消。
  Future<void> _toggleWatched(int index) async {
    final setter = widget.onSetEpisodeWatched;
    if (setter == null || _marking.contains(index)) return;
    final number = _episodeNumber(index);
    final watched = !_isWatched(index);
    HapticFeedback.selectionClick();
    setState(() {
      _marking.add(index);
      _watchedOverride[number] = watched;
    });
    try {
      final ok = await setter(index, watched);
      if (!mounted) return;
      // 写失败就退回长按前的状态。
      if (!ok) setState(() => _watchedOverride.remove(number));
    } catch (_) {
      if (mounted) setState(() => _watchedOverride.remove(number));
    } finally {
      if (mounted) setState(() => _marking.remove(index));
    }
  }

  Widget _buildBody(Color? textColor) {
    final showSearch =
        widget.videoList.length > _kSearchThreshold && !_downloadMode;
    final visible = _downloadMode ? null : _visibleIndexes;
    final count = visible?.length ?? widget.videoList.length;

    return Column(
      mainAxisSize: MainAxisSize.min,
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
        Flexible(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 宽屏用带剧照的卡片，手机上仍用原来的紧凑格子。
              final cards = !_downloadMode && constraints.maxWidth >= 520;
              return GridView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 16),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cards ? 4 : 3,
                  childAspectRatio: cards ? 1.65 : 1.5,
                  crossAxisSpacing: cards ? 10 : 8,
                  mainAxisSpacing: cards ? 10 : 8,
                ),
                itemCount: count,
                itemBuilder: (_, i) {
                  final position = _sortAscending ? i : count - 1 - i;
                  final index = visible?[position] ?? position;
                  return cards
                      ? _buildCardItem(index, textColor)
                      : _buildItem(index, textColor);
                },
              );
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
          '${_episodeNumber(widget.currentIndex)} / ${widget.videoList.length}',
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

  /// 宽屏选集卡片：剧照打底，标题叠在图上。
  Widget _buildCardItem(int index, Color? textColor) {
    final theme = Theme.of(context);
    final bgmId = widget.bgmSubjectId;
    return _EpisodeCard(
      number: _episodeNumber(index).toString().padLeft(2, '0'),
      label: _episodeLabel(index, widget.videoList[index].title),
      selected: index == widget.currentIndex,
      watched: _isWatched(index),
      still: bgmId == null || bgmId <= 0
          ? null
          : AniBakaApi.getEpisodeStills(
              bgmId: bgmId,
              season: 1,
              episode: _episodeNumber(index),
            ),
      base: textColor ?? theme.colorScheme.onSurface,
      accent: theme.colorScheme.primary,
      onTap: () => Navigator.pop(context, index),
      onLongPress: widget.onSetEpisodeWatched == null
          ? null
          : () => _toggleWatched(index),
    );
  }

  /// 卡片标题优先用 Bangumi 的集名；源的分集标题往往只有编号。
  String _episodeLabel(int index, String rawTitle) {
    final episodes = widget.bgmEpisodes;
    if (episodes.isNotEmpty) {
      final entry = BgmEpisodeOrder.byNumber(episodes, _episodeNumber(index));
      final name = entry == null ? null : (entry['name_cn'] ?? entry['name']);
      if (name is String && name.trim().isNotEmpty) return name.trim();
    }
    return rawTitle.replaceAll(RegExp(r'[\d第集话回章]'), '').trim();
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
      isWatched: _isWatched(index),
      textColor: textColor,
      onTap: () => Navigator.pop(context, index),
      onLongPress: widget.onSetEpisodeWatched == null
          ? null
          : () => _toggleWatched(index),
    );
  }
}
/// 选集卡片：剧照铺满，标题压在底部渐变上。
/// 悬停轻微放大；长按标记时从上往下扫过一道光，作为按下的反馈。
class _EpisodeCard extends StatefulWidget {
  const _EpisodeCard({
    required this.number,
    required this.label,
    required this.selected,
    required this.watched,
    required this.still,
    required this.base,
    required this.accent,
    required this.onTap,
    required this.onLongPress,
  });

  final String number;
  final String label;
  final bool selected;
  final bool watched;
  final Future<Map<String, dynamic>?>? still;
  final Color base;
  final Color accent;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<_EpisodeCard> createState() => _EpisodeCardState();
}

class _EpisodeCardState extends State<_EpisodeCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scan = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  bool _hovered = false;

  @override
  void dispose() {
    _scan.dispose();
    super.dispose();
  }

  void _longPress() {
    if (!context.reduceMotion) _scan.forward(from: 0);
    widget.onLongPress?.call();
  }

  Widget _buildStill() {
    final placeholder = Container(
      color: widget.base.withValues(alpha: 0.08),
      alignment: Alignment.center,
      child: Icon(
        Icons.movie_outlined,
        size: 20,
        color: widget.base.withValues(alpha: 0.28),
      ),
    );
    final future = widget.still;
    if (future == null) return placeholder;
    return FutureBuilder<Map<String, dynamic>?>(
      future: future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final url = (data?['still_thumb'] ?? data?['still_url']) as String?;
        if (url == null || url.isEmpty) return placeholder;
        return CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          memCacheWidth: 320,
          fadeInDuration: const Duration(milliseconds: 150),
          placeholder: (_, _) => placeholder,
          errorWidget: (_, _, _) => placeholder,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final motion = !context.reduceMotion;
    final dimmed = widget.watched && !widget.selected;
    final radius = BorderRadius.circular(10);
    final animated = Duration(milliseconds: motion ? 200 : 0);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _hovered && motion ? 1.05 : 1,
        duration: animated,
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: animated,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [
              if (_hovered)
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
            ],
          ),
          child: Material(
            color: widget.base.withValues(alpha: 0.07),
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onTap,
              onLongPress: widget.onLongPress == null ? null : _longPress,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Opacity(opacity: dimmed ? 0.5 : 1, child: _buildStill()),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0.4, 1],
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.78),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 7,
                    right: 7,
                    bottom: 6,
                    child: Row(
                      children: [
                        Text(
                          widget.number,
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(
                              alpha: dimmed ? 0.55 : 0.75,
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            widget.label.isEmpty
                                ? '第 ${widget.number} 集'
                                : widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.2,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withValues(
                                alpha: dimmed ? 0.55 : 1,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.watched)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  if (widget.selected)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(color: widget.accent, width: 2),
                      ),
                    ),
                  if (motion)
                    AnimatedBuilder(
                      animation: _scan,
                      builder: (context, _) {
                        if (!_scan.isAnimating) {
                          return const SizedBox.shrink();
                        }
                        return IgnorePointer(
                          child: Align(
                            alignment: Alignment(
                              0,
                              Curves.easeInOut.transform(_scan.value) * 2 - 1,
                            ),
                            child: Container(
                              height: 30,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Colors.white.withValues(alpha: 0.28),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
