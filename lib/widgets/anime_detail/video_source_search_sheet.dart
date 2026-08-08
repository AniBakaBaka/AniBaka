import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/widgets/anime_detail/controller/video_source_search_controller.dart';

class SourceSwitchSelection {
  const SourceSwitchSelection({required this.data, required this.lineIndex});
  final Map<String, dynamic> data;
  final int lineIndex;
}

/// 视频源搜索与线路切换底部滑栏
class VideoSourceSearchSheet extends StatefulWidget {
  final Map<String, dynamic> seedData;
  final int targetEpisodeIndex;
  final int currentEpisodeIndex;
  final int currentLineIndex;
  final String? currentSource;
  final VideoSourceSearchController? searchController;
  final String? heroTag;

  const VideoSourceSearchSheet({
    required this.seedData,
    this.targetEpisodeIndex = 0,
    this.currentEpisodeIndex = 0,
    this.currentLineIndex = 1,
    this.currentSource,
    this.searchController,
    this.heroTag,
    super.key,
  });

  static Future<SourceSwitchSelection?> show(
    BuildContext context, {
    required Map<String, dynamic> seedData,
    int currentEpisodeIndex = 0,
    int currentLineIndex = 1,
    String? currentSource,
    VideoSourceSearchController? searchController,
    String? heroTag,
  }) => showModalBottomSheet<SourceSwitchSelection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.42),
    constraints: const BoxConstraints(maxWidth: 860),
    builder: (_) => VideoSourceSearchSheet(
      seedData: seedData,
      targetEpisodeIndex: currentEpisodeIndex,
      currentEpisodeIndex: currentEpisodeIndex,
      currentLineIndex: currentLineIndex,
      currentSource: currentSource,
      searchController: searchController,
      heroTag: heroTag,
    ),
  );

  @override
  State<VideoSourceSearchSheet> createState() => _VideoSourceSearchSheetState();
}

class _VideoSourceSearchSheetState extends State<VideoSourceSearchSheet> {
  static const _identityKeys = ['seriesId', 'seriesUrl', 'id', 'url'];

  late final VideoSourceSearchController _controller;
  final _selectedFilterNotifier = ValueNotifier<String>('all');
  late final ValueNotifier<List<String>> _sourceKeysNotifier;

  late final Set<String> _currentIds;
  late final String _title;
  late final String _cover;
  late final double? _score;
  late final int? _scoreCount;

  List<DirectSourceGroup> _routes = const [];
  String? _selectingKey;
  bool _hasPending = false;
  bool _routeRefreshScheduled = false;

  bool get _isSelecting => _selectingKey != null;
  bool get _isFromPlayer =>
      widget.currentSource != null || widget.searchController != null;

  @override
  void initState() {
    super.initState();
    final seed = widget.seedData;
    _title = seed['title']?.toString().trim() ?? '';
    _cover = BgmUtils.resolveCoverImage(seed) ?? '';
    _score = BgmUtils.readFromData(seed).score;
    final rating = BgmUtils.asMap(
      BgmUtils.asMap(seed['bgmDetailData'])?['rating'],
    );
    _scoreCount = BgmUtils.toInt(rating?['total']);

    _currentIds = {
      for (final key in _identityKeys)
        if (seed[key]?.toString().trim() case final String v when v.isNotEmpty)
          v,
    };

    _controller =
        widget.searchController ??
        VideoSourceSearchController(
          seedData: seed,
          targetEpisodeIndex: widget.targetEpisodeIndex,
        );

    _sourceKeysNotifier = ValueNotifier<List<String>>(_currentSourceKeys());

    for (final n in [
      _controller.resultsNotifier,
      _controller.candidateRevisionNotifier,
      _controller.progressNotifier,
      _controller.isSearchingNotifier,
    ]) {
      n.addListener(_onCandidatesChanged);
    }

    _controller.ensureAdapterReady().then((_) {
      if (!mounted) {
        return;
      }
      final next = _currentSourceKeys();
      if (!listEquals(_sourceKeysNotifier.value, next)) {
        _sourceKeysNotifier.value = next;
      }
    });

    _readRoutes();
    if (_controller.resultsNotifier.value.isEmpty &&
        !_controller.isSearchingNotifier.value) {
      _controller.startSearch();
    } else {
      _continueAutoProbe();
    }
  }

  List<String> _currentSourceKeys() => [
    'all',
    'internal',
    for (final s in SourceCatalog.instance.quickSearchSources) s.key,
    for (final s in SourceCatalog.instance.enabledCustomSources)
      AdapterRegistry.customSourceKey(s.id),
  ];

  @override
  void dispose() {
    for (final n in [
      _controller.resultsNotifier,
      _controller.candidateRevisionNotifier,
      _controller.progressNotifier,
      _controller.isSearchingNotifier,
    ]) {
      n.removeListener(_onCandidatesChanged);
    }
    if (widget.searchController == null &&
        !VideoSourceSearchController.isGlobalCached(_controller)) {
      _controller.dispose();
    }
    _selectedFilterNotifier.dispose();
    _sourceKeysNotifier.dispose();
    super.dispose();
  }

  void _onCandidatesChanged() {
    if (!mounted || _routeRefreshScheduled) {
      return;
    }
    _routeRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _routeRefreshScheduled = false;
      if (!mounted) return;
      setState(_readRoutes);
      _continueAutoProbe();
    });
  }

  void _continueAutoProbe() {
    if (_hasPending) {
      _controller.startSwitchProbes(_routes.expand((g) => g.origins));
    }
  }

  void _readRoutes() {
    var hasPending = false;
    final groups = _controller.getDirectSourceGroups(
      episodeIndex: widget.currentEpisodeIndex,
      preferredLine: widget.currentLineIndex,
      currentSource: widget.currentSource,
    );
    for (final g in groups) {
      if (g.status == SourceProbeStatus.pending) {
        hasPending = true;
        break;
      }
    }
    _routes = groups;
    _hasPending = hasPending;
  }

  bool _matchesCurrent(SourceCandidateState origin) {
    if (_currentIds.isEmpty ||
        origin.item.sourceType != widget.currentSource ||
        (origin.probe.resolvedLineIndex ?? origin.probe.preferredLine) !=
            widget.currentLineIndex) {
      return false;
    }
    for (final key in _identityKeys) {
      final val = origin.item.data[key]?.toString().trim();
      if (val != null && _currentIds.contains(val)) return true;
    }
    return false;
  }

  Future<void> _selectBest() async {
    if (_isSelecting) {
      return;
    }
    DirectSourceGroup? fallback;
    for (final g in _routes) {
      if (g.isReady) {
        return _selectRoute(g);
      }
      if (fallback == null && g.status != SourceProbeStatus.failed) {
        fallback = g;
      }
    }
    if (fallback != null) {
      return _selectRoute(fallback);
    }
    _message('暂时没有可用线路');
  }

  Future<void> _selectRoute(DirectSourceGroup group) async {
    if (_isSelecting) return;
    var origin = group.primary;
    for (final c in group.origins) {
      if (c.item.sourceType == widget.currentSource) {
        origin = c;
        break;
      }
    }

    setState(() => _selectingKey = group.key);
    try {
      final probe = await _controller.resolveSwitchCandidate(origin);
      final data = probe.data;
      if (!probe.isReady || data == null) {
        _message('线路解析失败，请尝试其他线路');
        return;
      }
      final lineIndex = probe.resolvedLineIndex ?? probe.preferredLine;
      final selectionData = Map<String, dynamic>.from(data)
        ..['currPlayIndex'] = widget.currentEpisodeIndex
        ..['currUrl'] = lineIndex;
      await _controller.persistMatchMemory(origin.item, selectionData);
      if (mounted) {
        if (_isFromPlayer) {
          Navigator.of(context).pop(
            SourceSwitchSelection(data: selectionData, lineIndex: lineIndex),
          );
        } else {
          _navigateToPlayer(selectionData);
        }
      }
    } finally {
      if (mounted) setState(() => _selectingKey = null);
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
    if (_controller.isSearchingNotifier.value) return;
    final textController = TextEditingController();
    final value = await showDialog<String>(
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
            onPressed: () => Navigator.pop(dialogContext, textController.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    textController.dispose();

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

  Future<void> _openVideo(SearchResultItem item) async {
    _controller.markUserSelected();
    try {
      // 完整解析到可播媒体并写入预取，进入播放器后即点即播。
      final videoData = await _controller.prepareForPlayback(
        item,
        episodeIndex: widget.currentEpisodeIndex,
        preferredLine: widget.currentLineIndex,
      );
      if (!mounted) return;
      if (videoData == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('打开失败: 无法解析播放地址')));
        return;
      }
      if (_isFromPlayer && Navigator.of(context).canPop()) {
        final line =
            BgmUtils.toInt(videoData['currUrl']) ?? widget.currentLineIndex;
        Navigator.of(
          context,
        ).pop(SourceSwitchSelection(data: videoData, lineIndex: line));
        return;
      }
      _navigateToPlayer(videoData);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开失败: $e')));
      }
    }
  }

  void _navigateToPlayer(Map<String, dynamic> videoData) {
    if (!mounted) return;
    _controller.cancelSearch();
    VideoSourceSearchController.cacheGlobal(_title, _controller);
    NavigationService.toPlayer(context, videoData, popFirst: true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return DraggableScrollableSheet(
      initialChildSize: 0.76,
      minChildSize: 0.46,
      maxChildSize: 0.96,
      builder: (context, scrollController) => RepaintBoundary(
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF0F0E15).withValues(alpha: 0.96)
                      : const Color(0xFFF8F9FC).withValues(alpha: 0.96),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                ),
                child: _cover.isNotEmpty
                    ? ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(24),
                        ),
                        child: Opacity(
                          opacity: 0.06,
                          child: CachedNetworkImage(
                            imageUrl: _cover,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                            color: Colors.black.withValues(
                              alpha: isDark ? 0.3 : 0.2,
                            ),
                            colorBlendMode: BlendMode.srcOver,
                          ),
                        ),
                      )
                    : null,
              ),
              SafeArea(
                top: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(2),
                          color: isDark ? Colors.white24 : Colors.black12,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: _buildHeaderCard(isDark, primary),
                    ),
                    _buildErrorBanner(isDark),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildProgressSection(isDark, primary),
                          const SizedBox(height: 8),
                          _buildFilterChips(isDark),
                        ],
                      ),
                    ),
                    Expanded(child: _buildResultList(scrollController, isDark)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderCard(bool isDark, Color primary) {
    final scoreText = (_score ?? 0) > 0 ? _score!.toStringAsFixed(1) : null;
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
                          GestureDetector(
                            onTap: _isSelecting ? null : _selectBest,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: primary,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _isSelecting
                                      ? const SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.auto_awesome_rounded,
                                          size: 14,
                                          color: Colors.white,
                                        ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _isSelecting ? '切换中' : '优选',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (scoreText != null &&
                        _scoreCount != null &&
                        _scoreCount > 0) ...[
                      const SizedBox(height: 4),
                      _chipBadge(
                        label: '$scoreText 分 · $_scoreCount 人评分',
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

  Widget _buildAliasBar(bool isDark, Color primary) => ListenableBuilder(
    listenable: Listenable.merge([
      _controller.isSearchingNotifier,
      _controller.automaticAliasesNotifier,
      _controller.manualAliasesNotifier,
      _controller.activeAutoAliasesNotifier,
    ]),
    builder: (context, _) {
      final isSearching = _controller.isSearchingNotifier.value;
      final activeAuto = _controller.activeAutoAliasesNotifier.value;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: [
            for (final alias in _controller.automaticAliasesNotifier.value)
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
            for (final alias in _controller.manualAliasesNotifier.value)
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
    },
  );

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

  Widget _buildErrorBanner(bool isDark) => ListenableBuilder(
    listenable: Listenable.merge([
      _controller.progressNotifier,
      _controller.isSearchingNotifier,
    ]),
    builder: (context, _) {
      final errors = _controller.progressNotifier.value.searchErrors;
      if (errors.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
                onPressed: _controller.isSearchingNotifier.value
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
    },
  );

  Widget _buildProgressSection(
    bool isDarkMode,
    Color primary,
  ) => ListenableBuilder(
    listenable: Listenable.merge([
      _controller.progressNotifier,
      _controller.isSearchingNotifier,
      _controller.resultsNotifier,
      _sourceKeysNotifier,
    ]),
    builder: (context, _) {
      final progressState = _controller.progressNotifier.value;
      final results = _controller.resultsNotifier.value;
      final sourceKeys = _sourceKeysNotifier.value;
      final isSearching = _controller.isSearchingNotifier.value;
      final completed = progressState.finishedSources;
      final inProgress = progressState.progressingSources;

      final totalSourcesCount = (sourceKeys.length - 1).clamp(1, 99);
      final progressFraction = totalSourcesCount > 0
          ? (completed.length / totalSourcesCount).clamp(0.05, 0.98)
          : 1.0;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isSearching) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: completed.isEmpty ? null : progressFraction,
                minHeight: 2.5,
                backgroundColor: primary.withValues(
                  alpha: isDarkMode ? 0.15 : 0.08,
                ),
                color: primary,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              if (isSearching)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: primary,
                  ),
                )
              else
                Icon(
                  Icons.check_circle_rounded,
                  size: 15,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  isSearching
                      ? '正在自动匹配全网资源与解析优选线路...'
                      : '资源匹配完成 (${results.length} 个结果)',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isSearching
                        ? primary
                        : (isDarkMode ? Colors.white70 : Colors.black87),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: isDarkMode ? 0.15 : 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${completed.length}/$totalSourcesCount 源',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: [
                for (final key in sourceKeys)
                  if (key != 'all')
                    _buildSourceDot(
                      key,
                      completed.contains(key),
                      inProgress.contains(key) && !completed.contains(key),
                      isDarkMode,
                    ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _buildSourceDot(
    String key,
    bool isCompleted,
    bool isInProgress,
    bool isDarkMode,
  ) {
    final meta = _getSourceMeta(key);
    final color = isCompleted
        ? meta.color
        : isInProgress
        ? meta.color.withValues(alpha: 0.6)
        : (isDarkMode ? Colors.white24 : Colors.black12);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 4),
          Text(
            meta.label,
            style: TextStyle(
              fontSize: 11,
              color: isCompleted
                  ? meta.color
                  : (isDarkMode ? Colors.white54 : Colors.black45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChips(bool isDarkMode) => ListenableBuilder(
    listenable: Listenable.merge([
      _selectedFilterNotifier,
      _sourceKeysNotifier,
    ]),
    builder: (context, _) {
      final selectedFilter = _selectedFilterNotifier.value;
      final sourceKeys = _sourceKeysNotifier.value;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: [
            for (final key in sourceKeys)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => _selectedFilterNotifier.value = key,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: selectedFilter == key
                          ? _getSourceMeta(key).color
                          : (isDarkMode
                                ? Colors.white.withValues(alpha: 0.05)
                                : Colors.black.withValues(alpha: 0.04)),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      _getSourceMeta(key).label,
                      style: TextStyle(
                        fontSize: 12,
                        color: selectedFilter == key
                            ? Colors.white
                            : (isDarkMode ? Colors.white70 : Colors.black54),
                        fontWeight: selectedFilter == key
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  Widget _buildResultList(ScrollController scrollController, bool isDarkMode) {
    final colors = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge([
        _selectedFilterNotifier,
        _controller.resultsNotifier,
        _sourceKeysNotifier,
        _controller.isSearchingNotifier,
      ]),
      builder: (context, _) {
        final selectedFilter = _selectedFilterNotifier.value;
        final results = _controller.resultsNotifier.value;
        final isSearching = _controller.isSearchingNotifier.value;

        if (isSearching && results.isEmpty && _routes.isEmpty) {
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            children: [
              _buildEmptyMessage(
                '正在搜索各个视频站点与线路...',
                isDarkMode,
                isLoading: true,
              ),
            ],
          );
        }

        final entries = <Object>[];
        if (_routes.isNotEmpty &&
            (selectedFilter == 'all' || selectedFilter == 'internal')) {
          entries.add('__SECTION_ROUTES__');
          for (var i = 0; i < _routes.length; i++) {
            entries.add((index: i, group: _routes[i]));
          }
        }

        String? lastSource;
        for (final item in results) {
          if (selectedFilter != 'all' && item.sourceType != selectedFilter) {
            continue;
          }
          if (lastSource != item.sourceType) {
            lastSource = item.sourceType;
            entries.add(lastSource);
          }
          entries.add(item);
        }

        if (entries.isEmpty) {
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            children: [
              _buildEmptyMessage(
                '未找到匹配的视频源或线路',
                isDarkMode,
                isSearching: isSearching,
              ),
            ],
          );
        }

        return ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            if (entry == '__SECTION_ROUTES__') {
              return _buildSectionHeader(
                '可用线路 (${_routes.length})',
                Icons.alt_route_rounded,
                colors.primary,
                isDarkMode,
              );
            }
            if (entry is ({int index, DirectSourceGroup group})) {
              return RepaintBoundary(
                child: _buildRouteTile(
                  entry.index,
                  entry.group,
                  isDarkMode,
                  colors,
                ),
              );
            }
            if (entry is String) {
              final m = _getSourceMeta(entry);
              return _buildSectionHeader(m.label, m.icon, m.color, isDarkMode);
            }
            return RepaintBoundary(
              child: _buildResultTile(entry as SearchResultItem, isDarkMode),
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyMessage(
    String message,
    bool isDarkMode, {
    bool isLoading = false,
    bool isSearching = false,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    decoration: BoxDecoration(
      color: isDarkMode
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
            color: isDarkMode ? Colors.white38 : Colors.black38,
          ),
        const SizedBox(height: 12),
        Text(
          message,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDarkMode ? Colors.white70 : Colors.black87,
          ),
        ),
        if (!isLoading) ...[
          const SizedBox(height: 14),
          ElevatedButton.icon(
            onPressed: isSearching ? null : _controller.startSearch,
            icon: const Icon(Icons.refresh_rounded, size: 15),
            label: const Text('重新搜索', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: const Size(80, 32),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _buildSectionHeader(
    String title,
    IconData icon,
    Color color,
    bool isDarkMode,
  ) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6),
    child: Row(
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDarkMode
                ? Colors.white.withValues(alpha: 0.9)
                : Colors.black87,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Divider(
            height: 1,
            thickness: 0.5,
            color: isDarkMode ? Colors.white12 : Colors.black12,
          ),
        ),
      ],
    ),
  );

  Widget _buildTile({
    required String title,
    required bool isDark,
    Widget? leading,
    List<Widget>? chips,
    Widget? trailing,
    bool isCurrent = false,
    bool isRecommended = false,
    Color? accentColor,
    VoidCallback? onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    final accent = accentColor ?? colors.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
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
                if (leading != null) ...[leading, const SizedBox(width: 12)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
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
                      if (chips != null && chips.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Wrap(spacing: 4, runSpacing: 4, children: chips),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRouteTile(
    int index,
    DirectSourceGroup group,
    bool isDark,
    ColorScheme colors,
  ) {
    final labels = <String>{};
    var isCurrent = false;
    for (final origin in group.origins) {
      labels.add(_sourceLabel(origin.item));
      if (!isCurrent && _matchesCurrent(origin)) isCurrent = true;
    }
    final sourcesStr = labels.isEmpty ? '未知来源' : labels.join(' · ');
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

    return _buildTile(
      title: sourcesStr,
      isDark: isDark,
      isCurrent: isCurrent,
      isRecommended: isRecommended,
      accentColor: accent,
      onTap: (!_isSelecting || isSelectingThis)
          ? () => _selectRoute(group)
          : null,
      leading: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: isDark ? 0.18 : 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '${index + 1}'.padLeft(2, '0'),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: accent,
          ),
        ),
      ),
      chips: [
        _chipBadge(label: statusLabel, icon: statusIcon, color: statusColor),
        if (isCurrent)
          _chipBadge(label: '当前线路', color: colors.primary, isDark: isDark),
        if (isRecommended && !isCurrent)
          _chipBadge(label: '优选推荐', color: colors.primary, isDark: isDark),
      ],
      trailing: isSelectingThis
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: accent),
            )
          : Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
    );
  }

  Widget _buildResultTile(SearchResultItem item, bool isDark) {
    final meta = _getSourceMeta(item.sourceType);
    final img = _cover.isNotEmpty ? _cover : item.coverUrl;

    return _buildTile(
      title: item.title,
      isDark: isDark,
      accentColor: meta.color,
      onTap: () => _openVideo(item),
      leading: _buildCoverThumb(
        img,
        isDark: isDark,
        fallbackIcon: meta.icon,
        fallbackColor: meta.color,
      ),
      chips: [
        _chipBadge(label: meta.label, icon: meta.icon, color: meta.color),
        if (item.episodeInfo case final ep?)
          _chipBadge(
            label: ep,
            icon: Icons.playlist_play_rounded,
            color: meta.color,
          ),
        if (item.lineInfo case final ln?)
          _chipBadge(label: ln, icon: Icons.hub_rounded, color: meta.color),
        if (item.updateInfo case final up?)
          _chipBadge(
            label: up,
            icon: Icons.schedule_rounded,
            color: isDark ? Colors.white54 : Colors.black54,
          ),
      ],
      trailing: Icon(
        Icons.play_circle_filled_rounded,
        size: 26,
        color: meta.color.withValues(alpha: isDark ? 0.8 : 0.7),
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
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: color,
            height: 1,
          ),
        ),
      ],
    ),
  );

  static String _sourceLabel(SearchResultItem item) {
    if (item.sourceType == 'internal') {
      return '站内';
    }
    final descriptor = AdapterRegistry.descriptorFor(item.sourceType);
    if (descriptor != null) {
      return descriptor.displayName;
    }
    final name = item.data['sourceDisplayName']?.toString().trim();
    if (name == null || name.isEmpty) {
      return '自定义源';
    }
    return name;
  }
}

({String label, IconData icon, Color color}) _getSourceMeta(String key) {
  if (key == 'all') {
    return (
      label: '全部',
      icon: Icons.all_inclusive_rounded,
      color: const Color(0xFF9E9E9E),
    );
  }
  if (key == 'internal') {
    return (
      label: '站内',
      icon: Icons.shield_moon_rounded,
      color: const Color(0xFF4CAF50),
    );
  }

  final descriptor = AdapterRegistry.descriptorFor(key);
  if (descriptor != null) {
    return (
      label: descriptor.displayName,
      icon: descriptor.icon,
      color: descriptor.color,
    );
  }

  if (AdapterRegistry.isCustomSource(key)) {
    final id = key.substring(AdapterRegistry.customSourcePrefix.length);
    for (final s in SourceCatalog.instance.enabledCustomSources) {
      if (s.id == id) {
        const colors = [
          Color(0xFF7C4DFF),
          Color(0xFF00BCD4),
          Color(0xFFFF5722),
          Color(0xFF8BC34A),
          Color(0xFFE91E63),
          Color(0xFF3F51B5),
        ];
        return (
          label: s.name,
          icon: Icons.extension_rounded,
          color: colors[s.name.hashCode.abs() % colors.length],
        );
      }
    }
  }
  return (
    label: '其他来源',
    icon: Icons.layers_rounded,
    color: const Color(0xFF9E9E9E),
  );
}
