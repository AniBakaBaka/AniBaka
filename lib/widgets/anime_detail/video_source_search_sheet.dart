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

class FrostedContainer extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const FrostedContainer({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(20),
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: padding,
      child: child,
    );
  }
}

typedef _RouteView = ({
  DirectSourceGroup group,
  String sources,
  bool isCurrent,
});

/// 视频源搜索与线路切换底部滑栏（合并视频源搜索与线路切换）
///
/// 展示字段（title/cover/score）统一从 [seedData] 解析，调用方不必再拆模型参数。
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
    super.key,
    this.heroTag,
  });

  static Future<SourceSwitchSelection?> show(
    BuildContext context, {
    required Map<String, dynamic> seedData,
    int currentEpisodeIndex = 0,
    int currentLineIndex = 1,
    String? currentSource,
    VideoSourceSearchController? searchController,
    String? heroTag,
  }) {
    return showModalBottomSheet<SourceSwitchSelection>(
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
  }

  @override
  State<VideoSourceSearchSheet> createState() => _VideoSourceSearchSheetState();
}

class _VideoSourceSearchSheetState extends State<VideoSourceSearchSheet> {
  static const _identityKeys = ['seriesId', 'seriesUrl', 'id', 'url'];

  late final VideoSourceSearchController _controller;
  final ValueNotifier<String> _selectedFilterNotifier = ValueNotifier<String>('all');
  /// 源筛选 key 列表；展示元数据按需从 SourceCatalog/AdapterRegistry 解析，
  /// 避免 widget 侧把 AdapterDescriptor 再复制成 _SourceMeta 注册表。
  late final ValueNotifier<List<String>> _sourceKeysNotifier;

  late final Set<String> _currentIds;
  late final String _title;
  late final String _cover;
  late final double? _score;
  late final int? _scoreCount;
  List<_RouteView> _routes = const [];
  String? _selectingKey;
  bool _hasPending = false;
  bool _routeRefreshScheduled = false;

  bool get _isSelecting => _selectingKey != null;

  @override
  void initState() {
    super.initState();
    final seed = widget.seedData;
    _title = seed['title']?.toString().trim() ?? '';
    _cover = BgmUtils.resolveCoverImage(seed) ?? '';
    final bgm = BgmUtils.readFromData(seed);
    _score = bgm.score;
    final detail = BgmUtils.asMap(seed['bgmDetailData']);
    final rating = BgmUtils.asMap(detail?['rating']);
    _scoreCount = BgmUtils.toInt(rating?['total']);

    _currentIds = {
      for (final key in _identityKeys)
        if (seed[key]?.toString().trim() case final String value when value.isNotEmpty)
          value,
    };

    _controller = widget.searchController ??
        VideoSourceSearchController(
          seedData: seed,
          targetEpisodeIndex: widget.targetEpisodeIndex,
        );

    _sourceKeysNotifier = ValueNotifier<List<String>>(_currentSourceKeys());

    _controller.resultsNotifier.addListener(_onCandidatesChanged);
    _controller.candidateRevisionNotifier.addListener(_onCandidatesChanged);
    _controller.progressNotifier.addListener(_onCandidatesChanged);
    _controller.isSearchingNotifier.addListener(_onCandidatesChanged);

    _controller.ensureAdapterReady().then((_) {
      if (!mounted) return;
      final next = _currentSourceKeys();
      if (!listEquals(_sourceKeysNotifier.value, next)) {
        _sourceKeysNotifier.value = next;
      }
    });

    _readRoutes();

    if (_controller.resultsNotifier.value.isEmpty && !_controller.isSearchingNotifier.value) {
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
    _controller.resultsNotifier.removeListener(_onCandidatesChanged);
    _controller.candidateRevisionNotifier.removeListener(_onCandidatesChanged);
    _controller.progressNotifier.removeListener(_onCandidatesChanged);
    _controller.isSearchingNotifier.removeListener(_onCandidatesChanged);

    if (widget.searchController == null && !VideoSourceSearchController.isGlobalCached(_controller)) {
      _controller.dispose();
    }
    _selectedFilterNotifier.dispose();
    _sourceKeysNotifier.dispose();
    super.dispose();
  }

  void _onCandidatesChanged() {
    if (!mounted || _routeRefreshScheduled) return;
    _routeRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _routeRefreshScheduled = false;
      if (!mounted) return;
      setState(_readRoutes);
      _continueAutoProbe();
    });
  }

  void _continueAutoProbe() {
    if (!_hasPending) return;
    _controller.startSwitchProbes(
      _routes.expand((route) => route.group.origins),
    );
  }

  void _readRoutes() {
    var hasPending = false;
    final routes = <_RouteView>[];

    for (final group in _controller.getDirectSourceGroups(
      episodeIndex: widget.currentEpisodeIndex,
      preferredLine: widget.currentLineIndex,
      currentSource: widget.currentSource,
    )) {
      if (group.status == SourceProbeStatus.pending) {
        hasPending = true;
      }

      final labels = <String>{};
      var isCurrent = false;
      for (final origin in group.origins) {
        labels.add(_sourceLabel(origin.item));
        if (!isCurrent && _matchesCurrent(origin)) isCurrent = true;
      }
      routes.add((
        group: group,
        sources: labels.isEmpty ? '未知来源' : labels.join(' · '),
        isCurrent: isCurrent,
      ));
    }

    _routes = routes;
    _hasPending = hasPending;
  }

  String _sourceLabel(SearchResultItem item) {
    if (item.sourceType == 'internal') return '站内';
    final descriptor = AdapterRegistry.descriptorFor(item.sourceType);
    if (descriptor != null) return descriptor.displayName;
    final name = item.data['sourceDisplayName']?.toString().trim();
    return name == null || name.isEmpty ? '自定义源' : name;
  }

  bool _matchesCurrent(SourceCandidateState origin) {
    if (_currentIds.isEmpty ||
        origin.item.sourceType != widget.currentSource ||
        (origin.probe.resolvedLineIndex ?? origin.probe.preferredLine) != widget.currentLineIndex) {
      return false;
    }
    for (final key in _identityKeys) {
      final value = origin.item.data[key]?.toString().trim();
      if (value != null && _currentIds.contains(value)) return true;
    }
    return false;
  }

  Future<void> _selectBest() async {
    if (_isSelecting) return;
    DirectSourceGroup? fallback;
    for (final route in _routes) {
      if (route.group.isReady) return _selectRoute(route.group);
      if (fallback == null && route.group.status != SourceProbeStatus.failed) {
        fallback = route.group;
      }
    }
    if (fallback != null) return _selectRoute(fallback);
    _message('暂时没有可用线路');
  }

  Future<void> _selectRoute(DirectSourceGroup group) async {
    if (_isSelecting) return;

    var origin = group.primary;
    for (final candidate in group.origins) {
      if (candidate.item.sourceType == widget.currentSource) {
        origin = candidate;
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
        final selection = SourceSwitchSelection(data: selectionData, lineIndex: lineIndex);
        Navigator.of(context).pop(selection);
      }
    } finally {
      if (mounted) setState(() => _selectingKey = null);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          showCloseIcon: true,
        ),
      );
  }

  Future<void> _showAddAliasDialog() async {
    if (_controller.isSearchingNotifier.value) return;

    final textController = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
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
        );
      },
    );
    textController.dispose();

    if (!mounted || value == null) return;

    final success = await _controller.addManualAlias(value);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('别名已存在')),
      );
    }
  }

  Future<void> _openVideo(SearchResultItem item) async {
    _controller.markUserSelected();
    try {
      final videoData = await _controller.resolveVideoData(item);
      if (!mounted) return;
      final navigator = Navigator.of(context);
      final isCurrentRoute = ModalRoute.of(context)?.isCurrent == true;
      if (navigator.canPop() && isCurrentRoute) {
        final selection = SourceSwitchSelection(data: videoData, lineIndex: 1);
        navigator.pop(selection);
        return;
      }
      _navigateToPlayer(videoData);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败: $e')),
        );
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
  Widget build(BuildContext context) => _buildNormalSheet();

  Widget _buildNormalSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DraggableScrollableSheet(
      initialChildSize: 0.76,
      minChildSize: 0.46,
      maxChildSize: 0.96,
      builder: (context, scrollController) {
        return RepaintBoundary(
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildSheetBackground(isDark),
                SafeArea(
                  top: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      _buildDragHandle(isDark),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: _SearchHeaderCard(
                          title: _title,
                          cover: _cover,
                          score: _score,
                          scoreCount: _scoreCount,
                          heroTag: widget.heroTag,
                          controller: _controller,
                          onAddAlias: _showAddAliasDialog,
                          hasRoutes: _routes.isNotEmpty,
                          isSelecting: _isSelecting,
                          onBest: _selectBest,
                        ),
                      ),
                      _SearchErrorBanner(controller: _controller),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _SearchProgressIndicator(
                              controller: _controller,
                              sourceKeysNotifier: _sourceKeysNotifier,
                            ),
                            const SizedBox(height: 8),
                            _SourceFilterChips(
                              selectedFilterNotifier: _selectedFilterNotifier,
                              sourceKeysNotifier: _sourceKeysNotifier,
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: _VideoSearchResultList(
                          scrollController: scrollController,
                          controller: _controller,
                          sharedCover: _cover,
                          selectedFilterNotifier: _selectedFilterNotifier,
                          sourceKeysNotifier: _sourceKeysNotifier,
                          routes: _routes,
                          selectingKey: _selectingKey,
                          isSelecting: _isSelecting,
                          onSelectRoute: _selectRoute,
                          onOpenVideo: _openVideo,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDragHandle(bool isDark) {
    return Center(
      child: Container(
        width: 46,
        height: 5,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          color: isDark
              ? Colors.white.withValues(alpha: 0.18)
              : Colors.black.withValues(alpha: 0.12),
        ),
      ),
    );
  }

  Widget _buildSheetBackground(bool isDarkMode) {
    return Container(
      decoration: BoxDecoration(
        color: isDarkMode
            ? const Color(0xFF0F0E15).withValues(alpha: 0.95)
            : const Color(0xFFF8F9FC).withValues(alpha: 0.95),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(
          color: isDarkMode
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.08),
        ),
      ),
      child: _cover.isNotEmpty
          ? ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: Opacity(
                opacity: 0.08,
                child: CachedNetworkImage(
                  imageUrl: _cover,
                  fit: BoxFit.cover,
                  useOldImageOnUrlChange: true,
                  fadeInDuration: Duration.zero,
                  fadeOutDuration: Duration.zero,
                  width: double.infinity,
                  height: double.infinity,
                  color: Colors.black.withValues(alpha: isDarkMode ? 0.3 : 0.2),
                  colorBlendMode: BlendMode.srcOver,
                ),
              ),
            )
          : null,
    );
  }
}



/// 头部信息卡片组件
class _SearchHeaderCard extends StatelessWidget {
  final String title;
  final String cover;
  final double? score;
  final int? scoreCount;
  final String? heroTag;
  final VideoSourceSearchController controller;
  final Future<void> Function() onAddAlias;
  final bool hasRoutes;
  final bool isSelecting;
  final VoidCallback onBest;

  const _SearchHeaderCard({
    required this.title,
    required this.cover,
    required this.controller,
    required this.onAddAlias,
    required this.hasRoutes,
    required this.isSelecting,
    required this.onBest,
    this.score,
    this.scoreCount,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final badgeColor = Theme.of(context).colorScheme.primary;
    final scoreText = (score ?? 0) > 0 ? score!.toStringAsFixed(1) : null;

    return FrostedContainer(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              cover.isEmpty
                  ? Container(
                      width: 60,
                      height: 80,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: isDarkMode
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.black.withValues(alpha: 0.05),
                        border: Border.all(
                          color: isDarkMode ? Colors.white24 : Colors.black12,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.tv_rounded,
                        color: isDarkMode ? Colors.white54 : Colors.black38,
                        size: 24,
                      ),
                    )
                  : Hero(
                      tag: 'sheet_${heroTag ?? cover}',
                      child: _CoverThumb(imageUrl: cover),
                    ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (hasRoutes) ...[
                          const SizedBox(width: 8),
                          Tooltip(
                            message: '自动选择最优线路',
                            child: FilledButton.icon(
                              onPressed: isSelecting ? null : onBest,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(0, 32),
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: isSelecting
                                  ? const SizedBox(
                                      width: 13,
                                      height: 13,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.auto_awesome_rounded, size: 15),
                              label: Text(isSelecting ? '切换中' : '优选', style: const TextStyle(fontSize: 12)),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (scoreText != null && scoreCount != null && scoreCount! > 0) ...[
                      const SizedBox(height: 4),
                      SizedBox(
                        width: double.infinity,
                        child: _CompactBadge(
                          icon: Icons.star_rounded,
                          label: '$scoreText 分 · $scoreCount 人评分',
                          color: const Color(0xFFFFC107).withValues(alpha: isDarkMode ? 0.25 : 0.2),
                          foreground: const Color(0xFFFFC107),
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.movie_filter_rounded,
                          size: 14,
                          color: badgeColor.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '播放源与线路选择',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDarkMode ? Colors.white70 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _AliasBar(controller: controller, onAddAlias: onAddAlias),
        ],
      ),
    );
  }
}

/// 别名 Chip 栏（合并自动/手动别名与添加按钮）
class _AliasBar extends StatelessWidget {
  final VideoSourceSearchController controller;
  final Future<void> Function() onAddAlias;

  const _AliasBar({required this.controller, required this.onAddAlias});

  static const _activeColor = Color(0xFF66BB6A);
  static const _manualColor = Color(0xFF42A5F5);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.isSearchingNotifier,
        controller.automaticAliasesNotifier,
        controller.manualAliasesNotifier,
        controller.activeAutoAliasesNotifier,
      ]),
      builder: (context, _) {
        final isSearching = controller.isSearchingNotifier.value;
        final activeAuto = controller.activeAutoAliasesNotifier.value;

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: [
              for (final alias in controller.automaticAliasesNotifier.value)
                _chip(
                  alias: alias,
                  active: activeAuto.contains(alias),
                  color: activeAuto.contains(alias)
                      ? _activeColor
                      : (isDark ? Colors.white30 : Colors.black26),
                  icon: activeAuto.contains(alias)
                      ? Icons.auto_awesome_rounded
                      : Icons.add_circle_outline_rounded,
                  onPressed: isSearching ? null : () => controller.toggleAutoAlias(alias),
                ),
              for (final alias in controller.manualAliasesNotifier.value)
                _chip(
                  alias: alias,
                  active: true,
                  color: _manualColor,
                  icon: Icons.edit_rounded,
                  // 手动别名固定 InputChip，搜索中仅禁用删除，避免控件类型切换闪烁。
                  deletable: true,
                  onDelete: isSearching
                      ? null
                      : () => controller.removeManualAlias(alias),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  avatar: Icon(Icons.add_rounded, size: 16, color: primary),
                  label: const Text('别名'),
                  onPressed: isSearching ? null : onAddAlias,
                  labelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: primary),
                  backgroundColor: primary.withValues(alpha: isDark ? 0.16 : 0.10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: primary.withValues(alpha: 0.22)),
                  ),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static Widget _chip({
    required String alias,
    required bool active,
    required Color color,
    required IconData icon,
    VoidCallback? onPressed,
    VoidCallback? onDelete,
    bool deletable = false,
  }) {
    final bgAlpha = active ? 0.15 : 0.08;
    final borderAlpha = active ? 0.2 : 0.1;
    final style = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: color.withValues(alpha: borderAlpha)),
    );
    final label = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Text(alias, overflow: TextOverflow.ellipsis, maxLines: 1),
    );

    return Padding(
      padding: const EdgeInsets.only(right: 6),
      // 用 deletable 而非 onDelete != null 决定控件类型，避免搜索时 InputChip ↔ ActionChip 切换。
      child: deletable
          ? InputChip(
              avatar: Icon(icon, size: 14, color: color),
              label: label,
              onDeleted: onDelete,
              deleteIcon: const Icon(Icons.close_rounded, size: 14),
              labelStyle: style,
              backgroundColor: color.withValues(alpha: bgAlpha),
              shape: shape,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : ActionChip(
              avatar: Icon(icon, size: 14, color: color),
              label: label,
              onPressed: onPressed,
              labelStyle: style,
              backgroundColor: color.withValues(alpha: bgAlpha),
              shape: shape,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
    );
  }
}

class _CompactBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color foreground;

  const _CompactBadge({
    required this.icon,
    required this.label,
    required this.color,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: foreground),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索失败提示（精简单行式）
class _SearchErrorBanner extends StatelessWidget {
  final VideoSourceSearchController controller;
  const _SearchErrorBanner({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller.progressNotifier, controller.isSearchingNotifier]),
      builder: (context, _) {
        final errors = controller.progressNotifier.value.searchErrors;
        if (errors.isEmpty) return const SizedBox.shrink();
        final isDark = Theme.of(context).brightness == Brightness.dark;

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: FrostedContainer(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFFFFB347)),
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
                  onPressed: controller.isSearchingNotifier.value ? null : controller.startSearch,
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
  }
}

/// 进度状态与多源状态圆点指示器组件
class _SearchProgressIndicator extends StatelessWidget {
  final VideoSourceSearchController controller;
  final ValueNotifier<List<String>> sourceKeysNotifier;

  const _SearchProgressIndicator({
    required this.controller,
    required this.sourceKeysNotifier,
  });

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.progressNotifier,
        controller.isSearchingNotifier,
        controller.resultsNotifier,
        sourceKeysNotifier,
      ]),
      builder: (context, _) {
        final progressState = controller.progressNotifier.value;
        final results = controller.resultsNotifier.value;
        final sourceKeys = sourceKeysNotifier.value;
        final isSearching = controller.isSearchingNotifier.value;
        final completed = progressState.finishedSources;
        final inProgress = progressState.progressingSources;
        final primaryColor = Theme.of(context).colorScheme.primary;

        final totalSourcesCount = (sourceKeys.length - 1).clamp(1, 99);
        final progressFraction = totalSourcesCount > 0
            ? (completed.length / totalSourcesCount).clamp(0.05, 0.98)
            : 1.0;

        final indicatorItems = sourceKeys
            .where((key) => key != 'all')
            .map(
              (key) => _buildSourceDot(
                _resolveSourceMeta(key),
                completed.contains(key),
                inProgress.contains(key) && !completed.contains(key),
                isDarkMode,
              ),
            )
            .toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isSearching) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: completed.isEmpty ? null : progressFraction,
                  minHeight: 3,
                  backgroundColor: primaryColor.withValues(alpha: isDarkMode ? 0.15 : 0.08),
                  color: primaryColor,
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
                      color: primaryColor,
                    ),
                  )
                else
                  Icon(
                    Icons.check_circle_rounded,
                    size: 16,
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
                      color: isSearching ? primaryColor : (isDarkMode ? Colors.white70 : Colors.black87),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: isDarkMode ? 0.18 : 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${completed.length}/$totalSourcesCount 源已完成',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: primaryColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(children: indicatorItems),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSourceDot(
    _SourceMeta meta,
    bool isCompleted,
    bool isInProgress,
    bool isDarkMode,
  ) {
    final color = isCompleted
        ? meta.color
        : isInProgress
            ? meta.color.withValues(alpha: 0.6)
            : (isDarkMode ? Colors.white24 : Colors.black12);
    final labelColor = isCompleted
        ? meta.color
        : isInProgress
            ? meta.color.withValues(alpha: 0.8)
            : (isDarkMode ? Colors.white54 : Colors.black45);

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: isCompleted || isInProgress
                  ? null
                  : Border.all(
                      color: isDarkMode ? Colors.white24 : Colors.black12,
                    ),
            ),
          ),
          const SizedBox(width: 4),
          Text(meta.label, style: TextStyle(fontSize: 11, color: labelColor)),
        ],
      ),
    );
  }
}

/// 数据源筛选 Chips 栏组件
class _SourceFilterChips extends StatelessWidget {
  final ValueNotifier<String> selectedFilterNotifier;
  final ValueNotifier<List<String>> sourceKeysNotifier;

  const _SourceFilterChips({
    required this.selectedFilterNotifier,
    required this.sourceKeysNotifier,
  });

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return ListenableBuilder(
      listenable: Listenable.merge([
        selectedFilterNotifier,
        sourceKeysNotifier,
      ]),
      builder: (context, _) {
        final selectedFilter = selectedFilterNotifier.value;
        final sourceKeys = sourceKeysNotifier.value;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: sourceKeys.map((key) {
              final meta = _resolveSourceMeta(key);
              final selected = selectedFilter == key;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(meta.label),
                  selected: selected,
                  onSelected: (value) {
                    if (value) selectedFilterNotifier.value = key;
                  },
                  backgroundColor: isDarkMode
                      ? Colors.white.withValues(alpha: 0.04)
                      : Colors.black.withValues(alpha: 0.04),
                  selectedColor: meta.color.withValues(
                    alpha: isDarkMode ? 0.3 : 0.2,
                  ),
                  checkmarkColor: Colors.white,
                  labelStyle: TextStyle(
                    fontSize: 12,
                    color: selected
                        ? Colors.white
                        : (isDarkMode ? Colors.white70 : Colors.black54),
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}

/// 视频搜索结果与探针线路滚动列表组件
class _VideoSearchResultList extends StatelessWidget {
  final ScrollController scrollController;
  final VideoSourceSearchController controller;
  final String sharedCover;
  final ValueNotifier<String> selectedFilterNotifier;
  final ValueNotifier<List<String>> sourceKeysNotifier;
  final List<_RouteView> routes;
  final String? selectingKey;
  final bool isSelecting;
  final ValueChanged<DirectSourceGroup> onSelectRoute;
  final ValueChanged<SearchResultItem> onOpenVideo;

  const _VideoSearchResultList({
    required this.scrollController,
    required this.controller,
    required this.sharedCover,
    required this.selectedFilterNotifier,
    required this.sourceKeysNotifier,
    required this.routes,
    required this.selectingKey,
    required this.isSelecting,
    required this.onSelectRoute,
    required this.onOpenVideo,
  });

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return ListenableBuilder(
      listenable: Listenable.merge([
        selectedFilterNotifier,
        controller.resultsNotifier,
        sourceKeysNotifier,
        controller.isSearchingNotifier,
      ]),
      builder: (context, _) {
        final selectedFilter = selectedFilterNotifier.value;
        final results = controller.resultsNotifier.value;
        final isSearching = controller.isSearchingNotifier.value;

        if (isSearching && results.isEmpty && routes.isEmpty) {
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            children: [_buildSearchingPlaceholder(context, isDarkMode)],
          );
        }

        final entries = <Object>[];

        if (routes.isNotEmpty && (selectedFilter == 'all' || selectedFilter == 'internal')) {
          entries.add('__SECTION_ROUTES__');
          for (final route in routes) {
            entries.add(route);
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
              _buildEmptyPlaceholder(context, isDarkMode, isSearching),
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
              return _buildSectionHeader('可用线路', Icons.alt_route_rounded, Theme.of(context).colorScheme.primary, isDarkMode);
            }
            if (entry is _RouteView) {
              final idx = routes.indexOf(entry);
              return RepaintBoundary(
                child: _SourceCard.route(
                  index: idx,
                  group: entry.group,
                  sources: entry.sources,
                  isCurrent: entry.isCurrent,
                  isRecommended: idx == 0 && entry.group.isReady && !entry.isCurrent,
                  isSelecting: selectingKey == entry.group.key,
                  enabled: !isSelecting || selectingKey == entry.group.key,
                  onTap: () => onSelectRoute(entry.group),
                  colors: Theme.of(context).colorScheme,
                ),
              );
            }
            if (entry is String) {
              final m = _resolveSourceMeta(entry);
              return _buildSectionHeader(m.label, m.icon, m.color, isDarkMode);
            }
            final result = entry as SearchResultItem;
            return RepaintBoundary(
              child: _SourceCard.result(
                item: result,
                imageUrl: sharedCover.isNotEmpty ? sharedCover : result.coverUrl,
                meta: _resolveSourceMeta(result.sourceType),
                onTap: () => onOpenVideo(result),
                isDark: isDarkMode,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color, bool isDarkMode) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDarkMode ? Colors.white.withValues(alpha: 0.9) : Colors.black87,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Divider(
              thickness: 0.5,
              color: color.withValues(alpha: isDarkMode ? 0.25 : 0.2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchingPlaceholder(BuildContext context, bool isDarkMode) {
    return FrostedContainer(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 12),
          Text(
            '正在搜索各个视频站点与线路...',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDarkMode ? Colors.white : Colors.black87,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyPlaceholder(
    BuildContext context,
    bool isDarkMode,
    bool isSearching,
  ) {
    return FrostedContainer(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 36,
            color: isDarkMode ? Colors.white60 : Colors.black38,
          ),
          const SizedBox(height: 12),
          Text(
            '未找到匹配的视频源或线路',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: isDarkMode ? Colors.white : Colors.black87,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: isSearching ? null : controller.startSearch,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('重新搜索', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(80, 32),
            ),
          ),
        ],
      ),
    );
  }
}

/// 统一视频源卡片组件（合并线路 Tile 与搜索结果卡片）
class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.title,
    required this.accent,
    required this.onTap,
    this.leading,
    this.trailing,
    this.chips,
    this.enabled = true,
    this.highlighted = false,
    this.borderAccent,
  });

  final String title;
  final Color accent;
  final VoidCallback onTap;
  final Widget? leading;
  final Widget? trailing;
  final List<({IconData icon, String label})>? chips;
  final bool enabled;
  final bool highlighted;
  final Color? borderAccent;

  /// 从线路数据快速构建
  factory _SourceCard.route({
    required int index,
    required DirectSourceGroup group,
    required String sources,
    required bool isCurrent,
    required bool isRecommended,
    required bool isSelecting,
    required bool enabled,
    required VoidCallback onTap,
    required ColorScheme colors,
  }) {
    final (status, statusIcon, statusColor) = switch (group.status) {
      SourceProbeStatus.direct => ('已验证', Icons.check_circle_rounded, colors.primary),
      SourceProbeStatus.playable => ('可播放', Icons.play_circle_fill_rounded, colors.tertiary),
      SourceProbeStatus.resolving => ('解析中', Icons.sync_rounded, colors.secondary),
      SourceProbeStatus.pending => ('待检测', Icons.schedule_rounded, colors.onSurfaceVariant),
      SourceProbeStatus.failed => ('不可用', Icons.error_outline_rounded, colors.error),
    };
    final cardAccent = isCurrent ? colors.primary : statusColor;

    return _SourceCard(
      title: sources,
      accent: cardAccent,
      onTap: onTap,
      enabled: enabled,
      highlighted: isCurrent,
      borderAccent: isRecommended ? colors.primary.withValues(alpha: 0.3) : null,
      leading: _IndexBadge(index: index, color: cardAccent),

      chips: [
        (icon: statusIcon, label: status),
        if (isCurrent) (icon: Icons.radio_button_checked, label: '当前线路'),
        if (isRecommended && !isCurrent) (icon: Icons.star_rounded, label: '推荐'),
      ],
      trailing: isSelecting
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: cardAccent),
            )
          : Icon(Icons.chevron_right_rounded, size: 20, color: colors.onSurfaceVariant),
    );
  }

  /// 从搜索结果快速构建
  factory _SourceCard.result({
    required SearchResultItem item,
    required String imageUrl,
    required _SourceMeta meta,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    final c = meta.color;
    return _SourceCard(
      title: item.title,
      accent: c,
      onTap: onTap,
      leading: imageUrl.isNotEmpty
          ? _CoverThumb(
              imageUrl: imageUrl,
              overlayColor: c.withValues(alpha: 0.15),
              placeholder: (ctx, url) => Container(
                width: 60,
                height: 80,
                color: isDark ? Colors.grey[800] : Colors.grey[200],
              ),
              errorWidget: (ctx, url, err) => Container(
                color: isDark ? Colors.grey[800] : Colors.grey[200],
                alignment: Alignment.center,
                child: Icon(
                  Icons.broken_image,
                  color: isDark ? Colors.grey[600] : Colors.grey[400],
                  size: 20,
                ),
              ),
            )
          : Container(
              width: 60,
              height: 80,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: c.withValues(alpha: isDark ? 0.25 : 0.15),
                border: Border.all(color: c.withValues(alpha: 0.3)),
              ),
              alignment: Alignment.center,
              child: Icon(meta.icon, color: Colors.white, size: 24),
            ),
      chips: [
        (icon: meta.icon, label: meta.label),
        (icon: meta.icon, label: meta.statusLabel ?? '其他来源'),
        if (item.episodeInfo case final ep?) (icon: Icons.playlist_play_rounded, label: ep),
        if (item.lineInfo case final ln?) (icon: Icons.hub_rounded, label: ln),
        if (item.updateInfo case final up?) (icon: Icons.schedule_rounded, label: up),
      ],
      trailing: Icon(
        Icons.play_circle_filled_rounded,
        size: 28,
        color: c.withValues(alpha: isDark ? 0.85 : 0.9),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;

    final bg = highlighted
        ? colors.primaryContainer.withValues(alpha: isDark ? 0.35 : 0.25)
        : (isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.03));

    final border = highlighted
        ? colors.primary.withValues(alpha: 0.7)
        : borderAccent ?? accent.withValues(alpha: isDark ? 0.15 : 0.1);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(16),
          splashColor: accent.withValues(alpha: 0.12),
          highlightColor: accent.withValues(alpha: 0.06),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: bg,
              border: Border.all(color: border),
            ),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
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
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                          color: isDark ? Colors.white.withValues(alpha: 0.95) : Colors.black87,
                        ),
                      ),
                      if (chips != null && chips!.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 5,
                          runSpacing: 4,
                          children: [
                            for (final c in chips!)
                              _miniChip(c.icon, c.label, accent, isDark),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _miniChip(IconData icon, String label, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color, height: 1),
          ),
        ],
      ),
    );
  }
}

class _IndexBadge extends StatelessWidget {
  const _IndexBadge({required this.index, required this.color});
  final int index;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '${index + 1}'.padLeft(2, '0'),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// 60×80 圆角封面缩略图
class _CoverThumb extends StatelessWidget {
  final String imageUrl;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, String, Object)? errorWidget;
  final Color? overlayColor;

  const _CoverThumb({
    required this.imageUrl,
    this.placeholder,
    this.errorWidget,
    this.overlayColor,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(10);
    final overlay = overlayColor;
    final image = ClipRRect(
      borderRadius: borderRadius,
      child: CachedNetworkImage(
        imageUrl: imageUrl,
        fit: BoxFit.cover,
        useOldImageOnUrlChange: true,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        width: 60,
        height: 80,
        placeholder: placeholder,
        errorWidget: errorWidget,
      ),
    );

    return Container(
      width: 60,
      height: 80,
      decoration: BoxDecoration(borderRadius: borderRadius),
      child: overlay == null
          ? image
          : Stack(
              children: [
                image,
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: borderRadius,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, overlay],
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 单个源在 UI 上的元数据
class _SourceMeta {
  final String label;
  final IconData icon;
  final Color color;
  final String? statusLabel;
  const _SourceMeta({
    required this.label,
    required this.icon,
    required this.color,
    this.statusLabel,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _SourceMeta &&
          label == other.label &&
          icon == other.icon &&
          color == other.color &&
          statusLabel == other.statusLabel;

  @override
  int get hashCode => Object.hash(label, icon, color, statusLabel);
}

const _SourceMeta _kAllSourceMeta = _SourceMeta(
  label: '全部',
  icon: Icons.all_inclusive,
  color: Color(0xFF9E9E9E),
);

const _SourceMeta _kInternalSourceMeta = _SourceMeta(
  label: '站内',
  icon: Icons.shield_moon_rounded,
  color: Color(0xFF4CAF50),
  statusLabel: '站内源',
);

const _SourceMeta _kFallbackSourceMeta = _SourceMeta(
  label: '其他来源',
  icon: Icons.layers_rounded,
  color: Color(0xFF9E9E9E),
);

const List<Color> _customSourcePalette = [
  Color(0xFF7C4DFF),
  Color(0xFF00BCD4),
  Color(0xFFFF5722),
  Color(0xFF8BC34A),
  Color(0xFFE91E63),
  Color(0xFF3F51B5),
];

Color _customSourceColor(String name) =>
    _customSourcePalette[name.hashCode.abs() % _customSourcePalette.length];

/// 按需解析源展示元数据，复用 AdapterDescriptor / CustomSourceConfig，不在 widget 再建模。
_SourceMeta _resolveSourceMeta(String key) {
  if (key == 'all') return _kAllSourceMeta;
  if (key == 'internal') return _kInternalSourceMeta;

  final descriptor = AdapterRegistry.descriptorFor(key);
  if (descriptor != null) {
    return _SourceMeta(
      label: descriptor.displayName,
      icon: descriptor.icon,
      color: descriptor.color,
      statusLabel: descriptor.statusLabel,
    );
  }

  if (AdapterRegistry.isCustomSource(key)) {
    final id = key.substring(AdapterRegistry.customSourcePrefix.length);
    for (final s in SourceCatalog.instance.enabledCustomSources) {
      if (s.id == id) {
        return _SourceMeta(
          label: s.name,
          icon: Icons.extension_rounded,
          color: _customSourceColor(s.name),
          statusLabel: '自定义源',
        );
      }
    }
  }

  return _kFallbackSourceMeta;
}
