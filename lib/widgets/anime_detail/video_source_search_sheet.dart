import 'package:baka/utils/format_utils.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/utils/json_values.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/app/navigation.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/widgets/anime_detail/controller/video_source_search_controller.dart';

/// 视频源搜索与线路切换底部滑栏
class VideoSourceSearchSheet extends StatefulWidget {
  final Map<String, dynamic> seedData;
  final int currentEpisodeIndex;
  final int currentLineIndex;
  final String? currentSource;
  final VideoSourceSearchController? searchController;

  const VideoSourceSearchSheet({
    required this.seedData,
    this.currentEpisodeIndex = 0,
    this.currentLineIndex = 1,
    this.currentSource,
    this.searchController,
    super.key,
  });

  static Future<PlaybackRequest?> show(
    BuildContext context, {
    required Map<String, dynamic> seedData,
    int currentEpisodeIndex = 0,
    int currentLineIndex = 1,
    String? currentSource,
    VideoSourceSearchController? searchController,
  }) => showModalBottomSheet<PlaybackRequest>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.42),
    constraints: const BoxConstraints(maxWidth: 860),
    builder: (_) => VideoSourceSearchSheet(
      seedData: seedData,
      currentEpisodeIndex: currentEpisodeIndex,
      currentLineIndex: currentLineIndex,
      currentSource: currentSource,
      searchController: searchController,
    ),
  );

  @override
  State<VideoSourceSearchSheet> createState() => _VideoSourceSearchSheetState();
}

class _VideoSourceSearchSheetState extends State<VideoSourceSearchSheet> {
  late final VideoSourceSearchController _controller;
  late final bool _ownsController;
  String _selectedFilter = 'all';

  late final String? _currentId;
  late final String _title;
  late final String _cover;
  late final String? _scoreText;
  late final int? _scoreCount;

  List<DirectSourceGroup> _routes = const [];
  List<DirectSourceGroup> _visibleRoutes = const [];
  int _readyRouteCount = 0;
  bool _probeScheduled = false;
  late int _coverCacheWidth;
  String? _selectingKey;

  bool get _isSelecting => _selectingKey != null;
  bool get _isFromPlayer =>
      widget.currentSource != null || widget.searchController != null;

  @override
  void initState() {
    super.initState();
    final seed = widget.seedData;
    _title = seed['title']?.toString().trim() ?? '';
    _cover = resolveCoverImage(seed) ?? '';
    final score = BgmInfo.fromData(seed).score;
    _scoreText = score != null && score > 0 ? score.toStringAsFixed(1) : null;
    final rating = (seed['bgmDetailData'] as Map?)?['rating'] as Map?;
    _scoreCount = toInt(rating?['total']);
    _currentId = trimmed(
      (seed['seriesId'] ?? seed['seriesUrl'] ?? seed['id'] ?? seed['url'])
          ?.toString(),
    );

    _ownsController = widget.searchController == null;
    _controller =
        widget.searchController ??
        VideoSourceSearchController(
          seedData: seed,
          targetEpisodeIndex: widget.currentEpisodeIndex,
        );

    if (_controller.results.isEmpty && !_controller.isSearching) {
      _controller.startSearch();
    }
  }

  List<({String key, String label, IconData icon})> _readSources() => [
    (key: 'all', label: '全部', icon: Icons.all_inclusive_rounded),
    (key: 'internal', label: '站内', icon: Icons.shield_moon_rounded),
    for (final s in sourceCatalog.quickSearchSources)
      (key: s.key, label: s.displayName, icon: s.icon),
    for (final s in sourceCatalog.enabledCustomSources)
      (
        key: AdapterRegistry.customSourceKey(s.id),
        label: s.name,
        icon: Icons.extension_rounded,
      ),
  ];

  @override
  void dispose() {
    if (_ownsController &&
        !VideoSourceSearchController.isGlobalCached(_controller)) {
      _controller.dispose();
    }
    super.dispose();
  }

  void _refreshRoutes() {
    final routes = _controller.getDirectSourceGroups(
      episodeIndex: widget.currentEpisodeIndex,
      preferredLine: widget.currentLineIndex,
      currentSource: widget.currentSource,
    );
    if (identical(routes, _routes)) return;
    _routes = routes;
    _readyRouteCount = 0;
    var hasPending = false;
    for (final group in _routes) {
      if (group.isInstantPlayable) _readyRouteCount++;
      if (group.status == SourceProbeStatus.pending) hasPending = true;
    }
    _filterRoutes();
    if (hasPending) _scheduleProbes();
  }

  void _scheduleProbes() {
    if (_probeScheduled || _isSelecting) return;
    _probeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _probeScheduled = false;
      if (mounted &&
          ModalRoute.of(context)?.isActive == true &&
          !_isSelecting &&
          !_controller.isDisposed) {
        _controller.startSwitchProbes(_routes.expand((group) => group.origins));
      }
    });
  }

  void _filterRoutes() {
    if (_selectedFilter == 'all') {
      _visibleRoutes = _routes;
      return;
    }
    _visibleRoutes = [
      for (final group in _routes)
        if ([
              for (final origin in group.origins)
                if (origin.item.source == _selectedFilter) origin,
            ]
            case final origins when origins.isNotEmpty)
          origins.length == group.origins.length
              ? group
              : DirectSourceGroup(key: group.key, origins: origins),
    ];
  }

  bool _matchesCurrent(SourceProbeState origin) =>
      _currentId != null &&
      origin.item.source == widget.currentSource &&
      (origin.resolvedLineIndex ?? origin.preferredLine) ==
          widget.currentLineIndex &&
      origin.item.id == _currentId;

  Future<void> _selectBest() async {
    if (_isSelecting) return;
    DirectSourceGroup? fallback;
    for (final g in _routes) {
      if (g.isReady) return _selectRoute(g);
      if (fallback == null && g.status != SourceProbeStatus.failed) {
        fallback = g;
      }
    }
    if (fallback != null) return _selectRoute(fallback);
    _message('暂时没有可用线路');
  }

  Future<void> _selectRoute(DirectSourceGroup group) async {
    if (_isSelecting) return;
    final origin = group.primary;
    _controller.markUserSelected();

    var selectionTransferred = false;
    setState(() => _selectingKey = group.key);
    try {
      final probe = await _controller.ensureCandidatePlayable(
        origin.item,
        episodeIndex: origin.episodeIndex,
        preferredLine: origin.preferredLine,
      );
      bool stale() =>
          ModalRoute.of(context)?.isCurrent != true ||
          _controller.isDisposed ||
          !_controller.hasResult(origin.item);
      if (!mounted || stale()) return;
      final data = probe.data;
      if (!probe.isReady || data == null) {
        _message('线路解析失败，请尝试其他线路');
        return;
      }
      await _controller.persistMatchMemory(origin.item);
      if (mounted && !stale()) {
        _controller.cancelSearch();
        if (_isFromPlayer) {
          Navigator.of(context).pop(data);
        } else {
          VideoSourceSearchController.cacheGlobal(_controller);
          NavigationService.toPlayback(
            context,
            data,
            popFirst: true,
            autoMatch: false,
          );
        }
        selectionTransferred = true;
      }
    } catch (_) {
      _message('线路解析失败，请尝试其他线路');
    } finally {
      if (mounted && !selectionTransferred) {
        setState(() => _selectingKey = null);
        _scheduleProbes();
      }
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(text),
            behavior: SnackBarBehavior.floating,
            showCloseIcon: true,
          ),
        );
    }
  }

  Future<void> _showAddAliasDialog() async {
    if (_controller.isSearching) return;
    final textController = TextEditingController();
    String? value;
    try {
      value = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('添加搜索别名'),
          content: TextField(
            controller: textController,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(hintText: '例如 尖帽子的魔法工坊'),
            onSubmitted: (text) => Navigator.pop(dialogContext, text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, textController.text),
              child: const Text('添加'),
            ),
          ],
        ),
      );
    } finally {
      textController.dispose();
    }

    if (!mounted || value == null) {
      return;
    }
    final success = await _controller.addManualAlias(value);
    if (!success && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('别名已存在')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    _coverCacheWidth = (56 * MediaQuery.devicePixelRatioOf(context)).ceil();

    return DraggableScrollableSheet(
      initialChildSize: 0.76,
      minChildSize: 0.46,
      maxChildSize: 0.96,
      builder: (context, scrollController) => Material(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              final sources = _readSources();
              _refreshRoutes();
              return CustomScrollView(
                controller: scrollController,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Container(
                              width: 36,
                              height: 4,
                              decoration: BoxDecoration(
                                color: colors.outlineVariant,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          _buildHeaderCard(isDark, colors.primary),
                          _buildErrorBanner(isDark),
                          const SizedBox(height: 12),
                          _buildProgressSection(
                            colors.primary,
                            sources.length - 1,
                          ),
                          const SizedBox(height: 8),
                          _buildFilterChips(sources),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    sliver: _visibleRoutes.isEmpty
                        ? SliverToBoxAdapter(child: _buildEmptyState(isDark))
                        : SliverList.builder(
                            itemCount: _visibleRoutes.length,
                            itemBuilder: (context, index) => _buildRouteTile(
                              index,
                              _visibleRoutes[index],
                              isDark,
                              colors,
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderCard(bool isDark, Color primary) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCoverThumb(_cover, isDark: isDark),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _title,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_routes.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: _isSelecting ? null : _selectBest,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: _isSelecting
                                ? const SizedBox.square(
                                    dimension: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.play_arrow_rounded,
                                    size: 18,
                                  ),
                            label: Text(_isSelecting ? '切换中' : '优选'),
                          ),
                        ],
                      ],
                    ),
                    if (_scoreText != null &&
                        _scoreCount != null &&
                        _scoreCount > 0) ...[
                      const SizedBox(height: 4),
                      _chipBadge(
                        label: '$_scoreText 分 · $_scoreCount 人评分',
                        icon: Icons.star_rounded,
                        color: const Color(0xFFFFC107),
                        bgColor: const Color(
                          0xFFFFC107,
                        ).withValues(alpha: isDark ? 0.22 : 0.16),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.movie_filter_rounded,
                          size: 13,
                          color: primary.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '播放源与线路选择',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark ? Colors.white70 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildAliasBar(isDark, primary),
        ],
      ),
    );
  }

  Widget _buildAliasBar(bool isDark, Color primary) {
    final isSearching = _controller.isSearching;
    final activeAuto = _controller.activeAutoAliases;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          for (final alias in _controller.automaticAliases)
            _buildAliasTag(
              label: alias,
              color: activeAuto.contains(alias)
                  ? const Color(0xFF66BB6A)
                  : (isDark ? Colors.white30 : Colors.black26),
              icon: activeAuto.contains(alias)
                  ? Icons.auto_awesome_rounded
                  : Icons.add_circle_outline_rounded,
              onTap: isSearching
                  ? null
                  : () => _controller.toggleAutoAlias(alias),
            ),
          for (final alias in _controller.manualAliases)
            _buildAliasTag(
              label: alias,
              color: const Color(0xFF42A5F5),
              icon: Icons.edit_rounded,
              onDelete: isSearching
                  ? null
                  : () => _controller.removeManualAlias(alias),
            ),
          GestureDetector(
            onTap: isSearching ? null : _showAddAliasDialog,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: isDark ? 0.15 : 0.08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 14, color: primary),
                  const SizedBox(width: 3),
                  Text(
                    '别名',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAliasTag({
    required String label,
    required Color color,
    required IconData icon,
    VoidCallback? onTap,
    VoidCallback? onDelete,
  }) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            if (onDelete != null) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onDelete,
                child: Icon(Icons.close_rounded, size: 13, color: color),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _buildErrorBanner(bool isDark) {
    final errors = _controller.searchErrors;
    if (errors.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.info_outline_rounded,
              size: 16,
              color: Color(0xFFFFB347),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${errors.length} 个来源搜索失败',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _controller.isSearching
                  ? null
                  : _controller.startSearch,
              icon: const Icon(Icons.refresh_rounded, size: 14),
              label: const Text('重试', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressSection(Color primary, int total) {
    final searching = _controller.isSearching;
    final completed = _controller.finishedCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                searching
                    ? '搜索中 · $completed/$total 源'
                    : '搜索完成 · ${_controller.results.length} 个结果',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ),
            Text(
              '$_readyRouteCount 个可即播',
              style: TextStyle(
                fontSize: 12,
                color: primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            IconButton(
              tooltip: searching ? '停止搜索' : '重新搜索',
              visualDensity: VisualDensity.compact,
              onPressed: searching
                  ? _controller.cancelSearch
                  : _controller.startSearch,
              icon: Icon(
                searching ? Icons.stop_rounded : Icons.refresh_rounded,
                size: 18,
              ),
            ),
          ],
        ),
        if (searching)
          LinearProgressIndicator(
            value: completed == 0 || total <= 0 ? null : completed / total,
            minHeight: 2,
            borderRadius: BorderRadius.circular(2),
          ),
      ],
    );
  }

  Widget _buildFilterChips(
    List<({String key, String label, IconData icon})> sources,
  ) => SizedBox(
    height: 40,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: sources.length,
      separatorBuilder: (_, _) => const SizedBox(width: 6),
      itemBuilder: (context, index) {
        final source = sources[index];
        final key = source.key;
        final count = key == 'all'
            ? _controller.results.length
            : _controller.resultCountFor(key);
        final searching = _controller.progressingSources.contains(key);
        return ChoiceChip(
          selected: _selectedFilter == key,
          showCheckmark: false,
          avatar: Icon(searching ? Icons.sync_rounded : source.icon, size: 15),
          label: Text('${source.label} $count'),
          onSelected: (_) {
            if (_selectedFilter == key) return;
            setState(() {
              _selectedFilter = key;
              _filterRoutes();
            });
          },
          visualDensity: VisualDensity.compact,
        );
      },
    ),
  );

  Widget _buildEmptyState(bool isDark) {
    final isLoading = _controller.isSearching;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          if (isLoading)
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          else
            Icon(
              Icons.search_off_rounded,
              size: 36,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          const SizedBox(height: 12),
          Text(
            isLoading ? '正在搜索视频源…' : '未找到匹配的视频源',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
          if (!isLoading) ...[
            const SizedBox(height: 14),
            ElevatedButton.icon(
              onPressed: _controller.startSearch,
              icon: const Icon(Icons.refresh_rounded, size: 15),
              label: const Text('重新搜索', style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                minimumSize: const Size(80, 32),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRouteTile(
    int index,
    DirectSourceGroup group,
    bool isDark,
    ColorScheme colors,
  ) {
    final item = group.primary.item;
    final data = group.primary.data;
    final lineCount = data == null
        ? 0
        : data.episodes[data.episodeIndex!].lines.length;
    final labels = <String>{};
    var isCurrent = false;
    for (final origin in group.origins) {
      labels.add(origin.item.displayName);
      if (!isCurrent && _matchesCurrent(origin)) isCurrent = true;
    }
    final sourcesStr = labels.join(' · ');
    final isRecommended = index == 0 && group.isReady && !isCurrent;

    final (statusLabel, statusIcon, statusColor) = switch (group.status) {
      SourceProbeStatus.direct => (
        '可即播',
        Icons.check_circle_rounded,
        colors.primary,
      ),
      SourceProbeStatus.playable => (
        '待取链',
        Icons.play_circle_fill_rounded,
        colors.tertiary,
      ),
      SourceProbeStatus.resolving => (
        '解析中',
        Icons.sync_rounded,
        colors.secondary,
      ),
      SourceProbeStatus.pending => (
        '待检测',
        Icons.schedule_rounded,
        isDark ? Colors.white38 : Colors.black38,
      ),
      SourceProbeStatus.failed => (
        '不可用',
        Icons.error_outline_rounded,
        colors.error,
      ),
    };
    final accent = isCurrent ? colors.primary : statusColor;
    final isSelectingThis = _selectingKey == group.key;

    return Padding(
      key: ValueKey(group.key),
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: (!_isSelecting || isSelectingThis)
              ? () => _selectRoute(group)
              : null,
          borderRadius: BorderRadius.circular(14),
          splashColor: accent.withValues(alpha: 0.1),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: isCurrent
                  ? colors.primaryContainer.withValues(
                      alpha: isDark ? 0.3 : 0.2,
                    )
                  : (isDark
                        ? Colors.white.withValues(alpha: 0.04)
                        : Colors.black.withValues(alpha: 0.03)),
              border: Border.all(
                color: isCurrent
                    ? colors.primary.withValues(alpha: 0.6)
                    : isRecommended
                    ? colors.primary.withValues(alpha: 0.3)
                    : (isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : Colors.black.withValues(alpha: 0.06)),
                width: isCurrent ? 1.2 : 1.0,
              ),
            ),
            child: Row(
              children: [
                _buildCoverThumb(
                  item.cover.isNotEmpty ? item.cover : _cover,
                  isDark: isDark,
                  fallbackIcon: item.source == 'internal'
                      ? Icons.shield_moon_rounded
                      : AdapterRegistry.descriptorFor(item.source)?.icon ??
                            Icons.extension_rounded,
                  fallbackColor: accent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.95)
                              : Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          _chipBadge(
                            label: sourcesStr,
                            color: colors.secondary,
                            isDark: isDark,
                          ),
                          if (item.episodeCount case final int count
                              when count > 0)
                            _chipBadge(
                              label: '约 $count 集',
                              color: colors.secondary,
                              isDark: isDark,
                            ),
                          if (lineCount > 1)
                            _chipBadge(
                              label: '包含 $lineCount 条线路',
                              color: colors.secondary,
                              isDark: isDark,
                            ),
                          if (item.internalData?['time'] case final String time
                              when time.isNotEmpty)
                            _chipBadge(
                              label: '更新时间 ${formatDate(time)}',
                              color: colors.secondary,
                              isDark: isDark,
                            ),
                          _chipBadge(
                            label: statusLabel,
                            icon: statusIcon,
                            color: statusColor,
                          ),
                          if (isCurrent)
                            _chipBadge(
                              label: '当前线路',
                              color: colors.primary,
                              isDark: isDark,
                            ),
                          if (isRecommended)
                            _chipBadge(
                              label: '优选推荐',
                              color: colors.primary,
                              isDark: isDark,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isSelectingThis)
                  SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent,
                    ),
                  )
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCoverThumb(
    String url, {
    required bool isDark,
    IconData? fallbackIcon,
    Color? fallbackColor,
  }) {
    if (url.isEmpty) {
      return Container(
        width: 56,
        height: 74,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: (fallbackColor ?? Colors.grey).withValues(
            alpha: isDark ? 0.2 : 0.12,
          ),
        ),
        alignment: Alignment.center,
        child: Icon(
          fallbackIcon ?? Icons.tv_rounded,
          color: fallbackColor ?? (isDark ? Colors.white54 : Colors.black38),
          size: 22,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: url,
        memCacheWidth: _coverCacheWidth,
        fadeInDuration: Duration.zero,
        fit: BoxFit.cover,
        width: 56,
        height: 74,
        errorWidget: (context, url, error) => Container(
          width: 56,
          height: 74,
          color: isDark ? Colors.white10 : Colors.black12,
          alignment: Alignment.center,
          child: const Icon(
            Icons.broken_image_rounded,
            size: 18,
            color: Colors.grey,
          ),
        ),
      ),
    );
  }

  Widget _chipBadge({
    required String label,
    required Color color,
    IconData? icon,
    Color? bgColor,
    bool isDark = false,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: bgColor ?? color.withValues(alpha: isDark ? 0.18 : 0.08),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: color,
              height: 1,
            ),
          ),
        ),
      ],
    ),
  );
}
