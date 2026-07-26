import 'package:flutter/material.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/widgets/anime_detail/controller/video_source_search_controller.dart';

class SourceSwitchSelection {
  const SourceSwitchSelection({required this.data, required this.lineIndex});

  final Map<String, dynamic> data;
  final int lineIndex;
}

class SourceSwitchSheet extends StatefulWidget {
  const SourceSwitchSheet({
    required this.title,
    required this.cover,
    required this.seedData,
    required this.currentEpisodeIndex,
    required this.currentLineIndex,
    super.key,
    this.currentSource,
    this.currentSourceName,
    this.searchController,
  });

  final String title;
  final String cover;
  final Map<String, dynamic> seedData;
  final int currentEpisodeIndex;
  final int currentLineIndex;
  final String? currentSource;
  final String? currentSourceName;
  final VideoSourceSearchController? searchController;

  static Future<SourceSwitchSelection?> show(
    BuildContext context, {
    required String title,
    required String cover,
    required Map<String, dynamic> seedData,
    required int currentEpisodeIndex,
    required int currentLineIndex,
    String? currentSource,
    String? currentSourceName,
    VideoSourceSearchController? searchController,
  }) {
    return showModalBottomSheet<SourceSwitchSelection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.42),
      constraints: const BoxConstraints(maxWidth: 860),
      builder: (_) => SourceSwitchSheet(
        title: title,
        cover: cover,
        seedData: seedData,
        currentEpisodeIndex: currentEpisodeIndex,
        currentLineIndex: currentLineIndex,
        currentSource: currentSource,
        currentSourceName: currentSourceName,
        searchController: searchController,
      ),
    );
  }

  @override
  State<SourceSwitchSheet> createState() => _SourceSwitchSheetState();
}

typedef _RouteView = ({
  DirectSourceGroup group,
  String sources,
  bool isCurrent,
});

class _SourceSwitchSheetState extends State<SourceSwitchSheet> {
  static const _identityKeys = ['seriesId', 'seriesUrl', 'id', 'url'];

  late final VideoSourceSearchController _controller;
  late final Set<String> _currentIds;
  List<_RouteView> _routes = const [];
  String? _selectingKey;
  int _readyCount = 0;
  int _checkingCount = 0;
  int _failedCount = 0;
  bool _hasPending = false;
  bool _routeRefreshScheduled = false;

  bool get _isSelecting => _selectingKey != null;

  @override
  void initState() {
    super.initState();
    _currentIds = {
      for (final key in _identityKeys)
        if (widget.seedData[key]?.toString().trim() case final String value
            when value.isNotEmpty)
          value,
    };
    _controller =
        widget.searchController ??
        VideoSourceSearchController(
          title: widget.title,
          cover: widget.cover,
          seedData: widget.seedData,
        );

    _controller.resultsNotifier.addListener(_onCandidatesChanged);
    _controller.candidateRevisionNotifier.addListener(_onCandidatesChanged);
    _controller.progressNotifier.addListener(_onCandidatesChanged);
    _readRoutes();

    if (_controller.resultsNotifier.value.isEmpty &&
        !_controller.isSearchingNotifier.value) {
      _controller.startSearch();
    } else {
      _continueAutoProbe();
    }
  }

  @override
  void dispose() {
    _controller.resultsNotifier.removeListener(_onCandidatesChanged);
    _controller.candidateRevisionNotifier.removeListener(_onCandidatesChanged);
    _controller.progressNotifier.removeListener(_onCandidatesChanged);
    if (widget.searchController == null) _controller.dispose();
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
    var ready = 0;
    var checking = 0;
    var failed = 0;
    var hasPending = false;
    final routes = <_RouteView>[];

    for (final group in _controller.getDirectSourceGroups(
      episodeIndex: widget.currentEpisodeIndex,
      preferredLine: widget.currentLineIndex,
      currentSource: widget.currentSource,
    )) {
      switch (group.status) {
        case SourceProbeStatus.direct:
        case SourceProbeStatus.playable:
          ready++;
        case SourceProbeStatus.resolving:
          checking++;
        case SourceProbeStatus.pending:
          hasPending = true;
          checking++;
        case SourceProbeStatus.failed:
          failed++;
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
    _readyCount = ready;
    _checkingCount = checking;
    _failedCount = failed;
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
        (origin.probe.resolvedLineIndex ?? origin.probe.preferredLine) !=
            widget.currentLineIndex) {
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
      if (route.group.isReady) return _select(route.group);
      if (fallback == null && route.group.status != SourceProbeStatus.failed) {
        fallback = route.group;
      }
    }
    if (fallback != null) return _select(fallback);
    _message('暂时没有可用线路');
  }

  Future<void> _select(DirectSourceGroup group) async {
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
        Navigator.of(
          context,
        ).pop(SourceSwitchSelection(data: selectionData, lineIndex: lineIndex));
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

  String _summary(bool isSearching) {
    if (isSearching && _readyCount == 0) return '正在搜索并验证线路';
    final text = [
      if (_readyCount > 0) '$_readyCount 条可用',
      if (_checkingCount > 0) '$_checkingCount 条检测中',
      if (_failedCount > 0) '$_failedCount 条不可用',
    ].join(' · ');
    return text.isEmpty ? '暂无线路' : text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSearching = _controller.progressNotifier.value.isSearching;
    final initialSize = MediaQuery.sizeOf(context).height < 700 ? 0.88 : 0.76;

    return DraggableScrollableSheet(
      initialChildSize: initialSize,
      minChildSize: 0.46,
      maxChildSize: 0.94,
      builder: (context, scrollController) => Material(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              _Header(
                summary: _summary(isSearching),
                currentSource: widget.currentSourceName,
                isSelecting: _isSelecting,
                onBest: _selectBest,
                onClose: Navigator.of(context).pop,
              ),
              if (isSearching)
                const LinearProgressIndicator(minHeight: 2)
              else
                const SizedBox(height: 1),
              Expanded(
                child: _routes.isEmpty
                    ? _EmptyState(isSearching: isSearching)
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final wide = constraints.maxWidth >= 560;
                          return Scrollbar(
                            controller: scrollController,
                            child: GridView.builder(
                              controller: scrollController,
                              padding: EdgeInsets.fromLTRB(
                                wide ? 18 : 12,
                                12,
                                wide ? 18 : 12,
                                24,
                              ),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: wide ? 2 : 1,
                                    mainAxisExtent: 84,
                                    crossAxisSpacing: 10,
                                    mainAxisSpacing: 10,
                                  ),
                              itemCount: _routes.length,
                              itemBuilder: (context, index) {
                                final route = _routes[index];
                                return _RouteTile(
                                  index: index,
                                  group: route.group,
                                  sources: route.sources,
                                  isCurrent: route.isCurrent,
                                  isRecommended:
                                      index == 0 &&
                                      route.group.isReady &&
                                      !route.isCurrent,
                                  isSelecting: _selectingKey == route.group.key,
                                  enabled:
                                      !_isSelecting ||
                                      _selectingKey == route.group.key,
                                  onTap: () => _select(route.group),
                                );
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.summary,
    required this.currentSource,
    required this.isSelecting,
    required this.onBest,
    required this.onClose,
  });

  final String summary;
  final String? currentSource;
  final bool isSelecting;
  final VoidCallback onBest;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final current = currentSource?.trim();
    final subtitle = current == null || current.isEmpty
        ? summary
        : '当前 $current · $summary';

    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(18, 4, 8, 9),
      horizontalTitleGap: 11,
      leading: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(
          Icons.swap_horiz_rounded,
          color: colors.onPrimaryContainer,
          size: 21,
        ),
      ),
      title: Text(
        '切换播放线路',
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w800,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: '自动选择最优线路',
            child: FilledButton.icon(
              onPressed: isSelecting ? null : onBest,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 38),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              icon: isSelecting
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_rounded, size: 17),
              label: Text(isSelecting ? '切换中' : '优选'),
            ),
          ),
          IconButton(
            onPressed: onClose,
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _RouteTile extends StatelessWidget {
  const _RouteTile({
    required this.index,
    required this.group,
    required this.sources,
    required this.isCurrent,
    required this.isRecommended,
    required this.isSelecting,
    required this.enabled,
    required this.onTap,
  });

  final int index;
  final DirectSourceGroup group;
  final String sources;
  final bool isCurrent;
  final bool isRecommended;
  final bool isSelecting;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (status, statusIcon, statusColor) = switch (group.status) {
      SourceProbeStatus.direct => (
        '已验证',
        Icons.check_circle_rounded,
        colors.primary,
      ),
      SourceProbeStatus.playable => (
        '可播放',
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
        colors.onSurfaceVariant,
      ),
      SourceProbeStatus.failed => (
        '不可用',
        Icons.error_outline_rounded,
        colors.error,
      ),
    };
    final accent = isCurrent ? colors.primary : statusColor;

    final borderColor = isCurrent
        ? colors.primary.withValues(alpha: 0.7)
        : isRecommended
        ? colors.primary.withValues(alpha: 0.24)
        : colors.outlineVariant.withValues(alpha: 0.55);

    return Material(
      color: Colors.transparent,
      child: ListTile(
        onTap: enabled ? onTap : null,
        selected: isCurrent,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        horizontalTitleGap: 11,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: borderColor),
        ),
        tileColor: colors.surfaceContainerLow,
        selectedTileColor: colors.primaryContainer.withValues(alpha: 0.42),
        leading: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '${index + 1}'.padLeft(2, '0'),
            style: theme.textTheme.labelLarge?.copyWith(
              color: accent,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        title: Text(
          sources,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Row(
          children: [
            Icon(statusIcon, size: 13, color: statusColor),
            const SizedBox(width: 4),
            Text(
              status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: statusColor,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (isCurrent || isRecommended) ...[
              const SizedBox(width: 8),
              Text(
                isCurrent ? '当前线路' : '推荐',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
        trailing: isSelecting
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: accent),
              )
            : Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.isSearching});

  final bool isSearching;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSearching)
            const CircularProgressIndicator(strokeWidth: 2)
          else
            Icon(
              Icons.link_off_rounded,
              size: 38,
              color: colors.onSurfaceVariant,
            ),
          const SizedBox(height: 12),
          Text(
            isSearching ? '正在寻找可用线路' : '没有匹配到可用线路',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
