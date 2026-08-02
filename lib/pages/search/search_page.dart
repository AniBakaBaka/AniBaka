import 'dart:async';

import 'package:baka/instance.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/pages/source/source_management_page.dart';
import 'package:baka/services/search_service.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:flutter/material.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.k, this.initialSource});

  final String? k;
  final int? initialSource;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  static const _debounceDuration = Duration(milliseconds: 300);
  static const _unknownTitle = '未知标题';
  static const _noDescription = '暂无描述';

  final _searchController = TextEditingController();
  final _inFlightSearches =
      <({int source, String query}), Future<List<dynamic>>>{};
  late final SearchService _searchService;
  Timer? _debounce;

  bool get _isWindows => Instances.isWindows;

  @override
  void initState() {
    super.initState();
    _searchService = SearchService();
    _init();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchService.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _searchService.init(
      initialSource: widget.initialSource,
      initialKeyword: widget.k,
    );
    if (!mounted || widget.k == null) return;

    _searchController.text = _searchService.keyword;
    await _search(_searchService.keyword);
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    // A response for the previous text must not replace the current query.
    _searchService.activeSearchId++;
    _searchService.keyword = value;

    if (value.trim().isEmpty) {
      _searchService.resetSearch();
      return;
    }

    _debounce = Timer(_debounceDuration, () => _search(value));
  }

  Future<void> _search(String value) async {
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      _searchService.resetSearch();
      return;
    }

    final searchId = ++_searchService.activeSearchId;
    final key = (source: _searchService.selectedSourceIndex, query: query);

    _searchService.keyword = query;
    // Set loading before showing the result area so stale results never flash.
    _searchService.isLoading = true;
    _searchService.showResults = true;

    final request = _inFlightSearches.putIfAbsent(
      key,
      () => _searchService.executeSearch(query),
    );

    try {
      final rawResults = await request;
      if (!mounted || !_searchService.isActiveSearch(searchId)) return;
      _searchService.results = _normalizeResults(rawResults);
    } catch (error) {
      debugPrint('Search error for "$query": $error');
      if (!mounted || !_searchService.isActiveSearch(searchId)) return;
      _searchService.results = const [];
    } finally {
      if (identical(_inFlightSearches[key], request)) {
        _inFlightSearches.remove(key);
      }
      if (mounted && _searchService.isActiveSearch(searchId)) {
        _searchService.isLoading = false;
      }
    }
  }

  List<Map<String, dynamic>> _normalizeResults(List<dynamic> rawResults) {
    final results = <Map<String, dynamic>>[];

    for (final item in rawResults) {
      if (item is BgmSubjectInfo) {
        final chineseTitle = item.nameCn?.trim();
        final originalTitle = item.name?.trim();
        final title = chineseTitle?.isNotEmpty == true
            ? chineseTitle!
            : originalTitle?.isNotEmpty == true
            ? originalTitle!
            : _unknownTitle;
        final subtitle =
            chineseTitle?.isNotEmpty == true &&
                originalTitle?.isNotEmpty == true &&
                originalTitle != chineseTitle
            ? originalTitle!
            : item.summary ?? _noDescription;
        final heroTag = 'bgm_cover_${item.subjectId}';

        results.add({
          'source': 'bgm',
          'title': title,
          'subtitle': subtitle,
          'content': item.imageUrl,
          'bgmId': item.subjectId,
          'bgmImageUrl': item.imageUrl,
          '_heroTag': heroTag,
          if (item.score != null) 'score': item.score,
        });
        continue;
      }

      if (item is! Map) continue;
      final data = Map<String, dynamic>.from(item);
      final source = data['source']?.toString();

      if (AdapterRegistry.isAdapterSource(source)) {
        if (data['content']?.toString().isNotEmpty != true) {
          data['content'] = data['image'];
        }
        if (data['subtitle']?.toString().isNotEmpty != true) {
          data['subtitle'] = data['description'] ?? _noDescription;
        }
        if (data['tag']?.toString().isNotEmpty != true) {
          data['tag'] = data['sourceDisplayName'] ?? source ?? '自定义源';
        }
      }

      results.add(data);
    }

    return List.unmodifiable(results);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ValueListenableBuilder<bool>(
          valueListenable: _searchService.isVerticalLayoutNotifier,
          builder: (context, isVertical, _) {
            if (isVertical) {
              return Column(
                children: [
                  _buildHeaderBar(),
                  Expanded(
                    child: Row(
                      children: [
                        _buildVerticalSourceSidebar(),
                        Expanded(
                          child: ValueListenableBuilder<bool>(
                            valueListenable:
                                _searchService.showResultsNotifier,
                            builder: (context, showResults, _) {
                              if (!showResults) {
                                return ValueListenableBuilder<List<String>>(
                                  valueListenable:
                                      _searchService.searchHistoryNotifier,
                                  builder: (context, history, _) {
                                    return CustomScrollView(
                                      physics: const BouncingScrollPhysics(),
                                      slivers: [
                                        _buildHistory(history, isVertical: true),
                                      ],
                                    );
                                  },
                                );
                              }

                              return ValueListenableBuilder<bool>(
                                valueListenable:
                                    _searchService.isLoadingNotifier,
                                builder: (context, isLoading, _) {
                                  if (isLoading) {
                                    return const Center(
                                      child: CircularProgressIndicator(),
                                    );
                                  }

                                  return ValueListenableBuilder<List<dynamic>>(
                                    valueListenable:
                                        _searchService.resultsNotifier,
                                    builder: (context, results, _) {
                                      return CustomScrollView(
                                        physics: const BouncingScrollPhysics(),
                                        slivers: [
                                          _buildResults(results, isVertical: true),
                                          const SliverToBoxAdapter(
                                            child: SizedBox(height: 40),
                                          ),
                                        ],
                                      );
                                    },
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }

            return CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                _buildSearchBar(),
                ValueListenableBuilder<bool>(
                  valueListenable: _searchService.showResultsNotifier,
                  builder: (context, showResults, _) {
                    if (!showResults) {
                      return ValueListenableBuilder<List<String>>(
                        valueListenable: _searchService.searchHistoryNotifier,
                        builder: (context, history, _) => _buildHistory(history),
                      );
                    }

                    return SliverMainAxisGroup(
                      slivers: [
                        _buildSourceSelector(),
                        ValueListenableBuilder<bool>(
                          valueListenable: _searchService.isLoadingNotifier,
                          builder: (context, isLoading, _) {
                            if (isLoading) {
                              return const SliverFillRemaining(
                                hasScrollBody: false,
                                child: Center(child: CircularProgressIndicator()),
                              );
                            }

                            return ValueListenableBuilder<List<dynamic>>(
                              valueListenable: _searchService.resultsNotifier,
                              builder: (context, results, _) =>
                                  _buildResults(results),
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 40)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSearchBarContent() {
    final theme = Theme.of(context);

    return Center(
      child: Container(
        constraints: BoxConstraints(
          maxWidth: _isWindows ? 600 : double.infinity,
        ),
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: theme.dividerColor.withValues(alpha: 0.1),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.search, color: theme.hintColor, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  hintText: '搜索...',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
                textInputAction: TextInputAction.search,
                onChanged: _onSearchChanged,
                onSubmitted: _search,
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _searchController,
              builder: (context, value, _) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    _searchController.clear();
                    _debounce?.cancel();
                    _searchService.resetSearch();
                  },
                );
              },
            ),
            const SizedBox(width: 4),
            ValueListenableBuilder<bool>(
              valueListenable: _searchService.isVerticalLayoutNotifier,
              builder: (context, isVertical, _) {
                return IconButton(
                  tooltip: isVertical ? '切换为横向源列表' : '切换为竖向源列表',
                  icon: Icon(
                    isVertical
                        ? Icons.view_day_outlined
                        : Icons.view_sidebar_outlined,
                    size: 20,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  color:
                      isVertical ? theme.colorScheme.primary : theme.hintColor,
                  onPressed: () {
                    _searchService.isVerticalLayout = !isVertical;
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderBar() {
    final theme = Theme.of(context);
    final height = _isWindows ? 80.0 : 70.0;

    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: theme.scaffoldBackgroundColor,
      child: Row(
        children: [
          if (_isWindows)
            IconButton(
              icon: const Icon(Icons.arrow_back),
              color: theme.colorScheme.primary,
              onPressed: () => Navigator.of(context).pop(),
            ),
          Expanded(child: _buildSearchBarContent()),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    final theme = Theme.of(context);

    return SliverAppBar(
      floating: true,
      pinned: true,
      automaticallyImplyLeading: false,
      toolbarHeight: _isWindows ? 80 : 70,
      leading: _isWindows
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              color: theme.colorScheme.primary,
              onPressed: () => Navigator.of(context).pop(),
            )
          : null,
      title: _buildSearchBarContent(),
    );
  }

  Future<void> _openSourceManagement() async {
    _debounce?.cancel();
    _searchService.activeSearchId++;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const SourceManagementPage(),
      ),
    );
    if (!mounted) return;

    await _searchService.reloadCustomSources();
    if (!mounted) return;
    _inFlightSearches.clear();

    final query = _searchService.keyword.trim();
    if (query.isNotEmpty) await _search(query);
  }

  Widget _buildVerticalSourceSidebar() {
    final theme = Theme.of(context);
    final sidebarWidth = _isWindows ? 120.0 : 96.0;

    return ValueListenableBuilder<List<String>>(
      valueListenable: _searchService.sourceLabelsNotifier,
      builder: (context, sources, _) {
        return ValueListenableBuilder<int>(
          valueListenable: _searchService.selectedSourceIndexNotifier,
          builder: (context, selectedSource, _) {
            return Container(
              width: sidebarWidth,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow
                    .withValues(alpha: 0.4),
                border: Border(
                  right: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.08),
                  ),
                ),
              ),
              child: ListView.builder(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(
                  vertical: 6,
                  horizontal: 4,
                ),
                itemCount: sources.length,
                itemBuilder: (context, index) {
                        final isSelected = selectedSource == index;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () {
                              _searchService.selectedSourceIndex = index;
                              if (_searchService.keyword.trim().isNotEmpty) {
                                _search(_searchService.keyword);
                              }
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? theme.colorScheme.primaryContainer
                                        .withValues(alpha: 0.65)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected
                                      ? theme.colorScheme.primary
                                          .withValues(alpha: 0.35)
                                      : Colors.transparent,
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                children: [
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    width: 3,
                                    height: isSelected ? 14 : 0,
                                    margin: EdgeInsets.only(
                                      right: isSelected ? 5 : 0,
                                    ),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      borderRadius: BorderRadius.circular(1.5),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      sources[index],
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: isSelected
                                            ? FontWeight.w600
                                            : FontWeight.normal,
                                        color: isSelected
                                            ? theme.colorScheme.primary
                                            : theme.textTheme.bodyMedium?.color,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            );
          },
        );
      },
    );
  }

  Widget _buildSourceSelector() {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _PinnedHeaderDelegate(
        height: 56,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        child: ValueListenableBuilder<List<String>>(
          valueListenable: _searchService.sourceLabelsNotifier,
          builder: (context, sources, _) {
            return ValueListenableBuilder<int>(
              valueListenable: _searchService.selectedSourceIndexNotifier,
              builder: (context, selectedSource, _) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.symmetric(
                    horizontal: _isWindows ? 24 : 16,
                  ),
                  child: Row(
                    children: [
                      for (var index = 0; index < sources.length; index++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(sources[index]),
                            selected: selectedSource == index,
                            showCheckmark: false,
                            onSelected: (selected) {
                              if (!selected) return;
                              _searchService.selectedSourceIndex = index;
                              if (_searchService.keyword.trim().isNotEmpty) {
                                _search(_searchService.keyword);
                              }
                            },
                          ),
                        ),
                      IconButton(
                        tooltip: '管理搜索源',
                        icon: const Icon(Icons.settings_outlined, size: 19),
                        onPressed: _openSourceManagement,
                      ),
                      IconButton(
                        tooltip: '切换为竖向源列表',
                        icon: const Icon(Icons.view_sidebar_outlined, size: 19),
                        onPressed: () => _searchService.isVerticalLayout = true,
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildHistory(List<String> history, {bool isVertical = false}) {
    if (history.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final theme = Theme.of(context);
    final horizontalPadding = isVertical
        ? (_isWindows ? 20.0 : 12.0)
        : (_isWindows ? 32.0 : 24.0);

    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          horizontalPadding,
          _isWindows ? 16 : 8,
          horizontalPadding,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '最近搜索',
                  style: TextStyle(
                    fontSize: _isWindows ? 18 : 16,
                    fontWeight: FontWeight.bold,
                    color: theme.textTheme.titleLarge?.color,
                  ),
                ),
                TextButton(
                  onPressed: _searchService.clearSearchHistory,
                  child: Text(
                    '清除',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: _isWindows ? 10 : 8,
              runSpacing: _isWindows ? 10 : 8,
              children: [
                for (final item in history)
                  InputChip(
                    label: Text(item),
                    onPressed: () {
                      _searchController.text = item;
                      _search(item);
                    },
                    onDeleted: () => _searchService.removeSearchHistory(item),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(List<dynamic> results, {bool isVertical = false}) {
    if (results.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Text('未找到结果', style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    final wideLayout = _isWindows || isTablet;

    final double maxExtent;
    final double childAspectRatio;
    final EdgeInsets padding;
    final double crossSpacing;
    final double mainSpacing;

    if (isVertical) {
      padding = EdgeInsets.symmetric(
        horizontal: wideLayout ? 16 : 8,
        vertical: 12,
      );
      maxExtent = _isWindows ? 220 : (isTablet ? 180 : 140);
      childAspectRatio = _isWindows ? 0.68 : (isTablet ? 0.65 : 0.62);
      crossSpacing = isTablet ? 12 : 8;
      mainSpacing = isTablet ? 16 : 10;
    } else {
      padding = EdgeInsets.symmetric(
        horizontal: wideLayout ? 24 : 16,
        vertical: 16,
      );
      maxExtent = _isWindows ? 280 : (isTablet ? 250 : 220);
      childAspectRatio = _isWindows ? 0.65 : 0.58;
      crossSpacing = isTablet ? 20 : 16;
      mainSpacing = isTablet ? 28 : 24;
    }

    return SliverPadding(
      padding: padding,
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: maxExtent,
          childAspectRatio: childAspectRatio,
          crossAxisSpacing: crossSpacing,
          mainAxisSpacing: mainSpacing,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final data = results[index] as Map<String, dynamic>;
          final source = data['source']?.toString();
          VoidCallback? onTap;

          if (source == 'bgm') {
            onTap = () {
              final playerData = <String, dynamic>{
                'title': data['title'],
                'bgmId': data['bgmId'],
                '_heroTag': data['_heroTag'],
                if (data['bgmImageUrl'] != null)
                  'bgmImageUrl': data['bgmImageUrl'],
                if (data['score'] != null) 'score': data['score'],
              };
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerPage(data: playerData),
                ),
              );
            };
          } else if (AdapterRegistry.isAdapterSource(source)) {
            onTap = () => _openSeries(data);
          }

          return PostCard(data, onTap: onTap);
        }, childCount: results.length),
      ),
    );
  }

  Future<void> _openSeries(Map<String, dynamic> item) async {
    final source =
        item['sourceDisplayName']?.toString() ??
        item['source']?.toString() ??
        '';

    try {
      final playerData = await _searchService.buildPlayerData(item);
      if (!mounted) return;
      if (playerData != null) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => PlayerPage(data: playerData)),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('未找到剧集数据: $source'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (error) {
      debugPrint('Error opening $source: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('打开失败: $source'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }
}

class _PinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedHeaderDelegate({
    required this.child,
    required this.height,
    required this.backgroundColor,
  });

  final Widget child;
  final double height;
  final Color backgroundColor;

  @override
  double get maxExtent => height;

  @override
  double get minExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ColoredBox(
      color: backgroundColor.withValues(alpha: 0.95),
      child: SizedBox(
        height: height,
        child: Center(child: child),
      ),
    );
  }

  @override
  bool shouldRebuild(_PinnedHeaderDelegate oldDelegate) {
    return oldDelegate.child != child ||
        oldDelegate.height != height ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}
