import 'package:baka/core/app_logger.dart';
import 'package:baka/core/content_filter.dart';
import 'package:baka/source/models/source_search_result.dart';
import 'package:baka/services/source/source_repository.dart';
import 'dart:async';

import 'package:baka/instance.dart';
import 'package:baka/pages/source/source_management_page.dart';
import 'package:baka/pages/search/search_controller.dart';
import 'package:baka/app/navigation.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.k, this.initialSource});

  final String? k;
  final int? initialSource;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  static const _debounceDuration = Duration(milliseconds: 300);
  final _searchController = TextEditingController();
  late final AnimeSearchController _searchService;
  Timer? _debounce;
  late final _sourceChanges = Listenable.merge([
    _searchService.sourceLabelsNotifier,
    _searchService.selectedSourceIndexNotifier,
  ]);
  late final _resultChanges = Listenable.merge([
    _searchService.isLoadingNotifier,
    _searchService.resultsNotifier,
    _searchPageNotifier,
    contentFilter,
  ]);

  static const int _searchPageSize = 30;
  final ValueNotifier<int> _searchPageNotifier = ValueNotifier<int>(1);
  final TextEditingController _jumpPageController = TextEditingController();
  final FocusNode _jumpFocus = FocusNode();

  bool get _isWindows => Instances.isDesktopPlatform;

  @override
  void initState() {
    super.initState();
    _searchService = AnimeSearchController();
    // 跳页框初始留空，仅在用户输入并跳转后填充；翻页时不自动回填，保持“ /总页”样式。
    _init();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _jumpPageController.dispose();
    _jumpFocus.dispose();
    _searchPageNotifier.dispose();
    _searchService.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _searchService.init(
      initialSource: widget.initialSource,
      initialKeyword: widget.k,
    );
    if (!mounted || widget.k == null) return;

    _searchController.text = _searchService.keywordNotifier.value;
    await _search(_searchService.keywordNotifier.value);
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    // A response for the previous text must not replace the current query.
    _searchService.invalidateSearch();
    _searchService.keywordNotifier.value = value;

    if (value.trim().isEmpty) {
      _searchService.resetSearch();
      return;
    }

    _debounce = Timer(_debounceDuration, () => _search(value));
  }

  Future<void> _search(String value) async {
    _debounce?.cancel();
    _searchPageNotifier.value = 1;
    await _searchService.search(value);
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
                            valueListenable: _searchService.showResultsNotifier,
                            builder: (context, showResults, _) {
                              if (showResults) {
                                return _buildResultsArea(isVertical: true);
                              }
                              return ValueListenableBuilder<List<String>>(
                                valueListenable:
                                    _searchService.searchHistoryNotifier,
                                builder: (context, history, _) =>
                                    CustomScrollView(
                                      physics: const BouncingScrollPhysics(),
                                      slivers: [
                                        _buildHistory(
                                          history,
                                          isVertical: true,
                                        ),
                                      ],
                                    ),
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
                        builder: (context, history, _) =>
                            _buildHistory(history),
                      );
                    }
                    return SliverMainAxisGroup(
                      slivers: [_buildSourceSelector(), _buildResultsArea()],
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

  Widget _buildResultsArea({bool isVertical = false}) {
    return ListenableBuilder(
      listenable: _resultChanges,
      builder: (context, _) {
        final isLoading = _searchService.isLoadingNotifier.value;
        final all = contentFilter.visibleItems(
          _searchService.resultsNotifier.value,
        );
        if (isLoading && all.isEmpty) {
          if (isVertical) {
            return const Center(child: CircularProgressIndicator());
          }
          return const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final totalPages =
            all.isEmpty ? 1 : ((all.length - 1) ~/ _searchPageSize + 1);
        final currentPage = _searchPageNotifier.value.clamp(1, totalPages);
        final start = (currentPage - 1) * _searchPageSize;
        final end = start + _searchPageSize < all.length
            ? start + _searchPageSize
            : all.length;
        final pageItems = all.sublist(start, end);
        final results = SliverMainAxisGroup(
          slivers: [
            if (isLoading)
              const SliverToBoxAdapter(child: LinearProgressIndicator()),
            _buildResults(pageItems, isVertical: isVertical),
          ],
        );
        final pageBar = _buildPageBar(totalPages, currentPage);
        if (isVertical) {
          return CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              results,
              pageBar,
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          );
        }
        return SliverMainAxisGroup(slivers: [results, pageBar]);
      },
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
          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.1)),
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
                  color: isVertical
                      ? theme.colorScheme.primary
                      : theme.hintColor,
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
    _searchService.invalidateSearch();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SourceManagementPage()),
    );
    if (!mounted) return;

    await _searchService.reloadCustomSources();
    if (!mounted) return;
    final query = _searchService.keywordNotifier.value.trim();
    if (query.isNotEmpty) await _search(query);
  }

  Widget _buildVerticalSourceSidebar() {
    final theme = Theme.of(context);
    final sidebarWidth = _isWindows ? 120.0 : 96.0;

    return ListenableBuilder(
      listenable: _sourceChanges,
      builder: (context, _) {
        final sources = _searchService.sourceLabelsNotifier.value;
        final selectedSource = _searchService.selectedSourceIndexNotifier.value;
        return Container(
          width: sidebarWidth,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.4),
            border: Border(
              right: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.08),
              ),
            ),
          ),
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            itemCount: sources.length,
            itemBuilder: (context, index) {
              final isSelected = selectedSource == index;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    if (_searchService.selectedSourceIndexNotifier.value ==
                        index) {
                      return;
                    }
                    _searchService.selectedSourceIndexNotifier.value = index;
                    if (_searchService.keywordNotifier.value
                        .trim()
                        .isNotEmpty) {
                      _search(_searchService.keywordNotifier.value);
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
                          ? theme.colorScheme.primaryContainer.withValues(
                              alpha: 0.65,
                            )
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? theme.colorScheme.primary.withValues(alpha: 0.35)
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
                          margin: EdgeInsets.only(right: isSelected ? 5 : 0),
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
  }

  Widget _buildSourceSelector() {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _PinnedHeaderDelegate(
        height: 56,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        child: ListenableBuilder(
          listenable: _sourceChanges,
          builder: (context, _) {
            final sources = _searchService.sourceLabelsNotifier.value;
            final selectedSource =
                _searchService.selectedSourceIndexNotifier.value;
            return ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.symmetric(horizontal: _isWindows ? 24 : 16),
              itemCount: sources.length + 2,
              itemBuilder: (context, index) {
                if (index < sources.length) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(sources[index]),
                        selected: selectedSource == index,
                        showCheckmark: false,
                        onSelected: (selected) {
                          if (!selected) return;
                          _searchService.selectedSourceIndexNotifier.value =
                              index;
                          if (_searchService.keywordNotifier.value
                              .trim()
                              .isNotEmpty) {
                            _search(_searchService.keywordNotifier.value);
                          }
                        },
                      ),
                    ),
                  );
                }
                if (index == sources.length) {
                  return IconButton(
                    tooltip: '管理搜索源',
                    icon: const Icon(Icons.settings_outlined, size: 19),
                    onPressed: _openSourceManagement,
                  );
                }
                return IconButton(
                  tooltip: '切换为竖向源列表',
                  icon: const Icon(Icons.view_sidebar_outlined, size: 19),
                  onPressed: () => _searchService.isVerticalLayout = true,
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

  Widget _buildResults(
    List<Map<String, dynamic>> results, {
    bool isVertical = false,
  }) {
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

    final int crossCount;
    final double childAspectRatio;
    final EdgeInsets padding;
    final double crossSpacing;
    final double mainSpacing;

    if (isVertical) {
      padding = EdgeInsets.symmetric(
        horizontal: wideLayout ? 16 : 8,
        vertical: 12,
      );
      // 桌面端固定每行 6 条，封面更大；窄屏退化为 3 条，避免卡片过小。
      crossCount = wideLayout ? 6 : 3;
      childAspectRatio = wideLayout ? 0.72 : 0.68;
      crossSpacing = isTablet ? 12 : 8;
      mainSpacing = isTablet ? 16 : 10;
    } else {
      padding = EdgeInsets.symmetric(
        horizontal: wideLayout ? 24 : 16,
        vertical: 16,
      );
      crossCount = wideLayout ? 6 : 3;
      childAspectRatio = wideLayout ? 0.72 : 0.68;
      crossSpacing = isTablet ? 20 : 16;
      mainSpacing = isTablet ? 28 : 24;
    }

    return SliverPadding(
      padding: padding,
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossCount,
          childAspectRatio: childAspectRatio,
          crossAxisSpacing: crossSpacing,
          mainAxisSpacing: mainSpacing,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final data = results[index];
          final source = data['source']?.toString();
          VoidCallback? onTap;

          if (source == 'bgm') {
            onTap = () {
              final detailData = <String, dynamic>{
                'title': data['title'],
                'bgmId': data['bgmId'],
                '_heroTag': coverHeroTag(data),
                if (data['bgmImageUrl'] != null)
                  'bgmImageUrl': data['bgmImageUrl'],
                if (data['score'] != null) 'score': data['score'],
              };
              NavigationService.toDetail(
                context,
                detailData,
                cardContext: context,
                cardPreview: PostCard(data),
              );
            };
          } else if (source != null && source.isNotEmpty) {
            onTap = () => _openSeries(data);
          }

          return PostCard(data, onTap: onTap);
        }, childCount: results.length),
      ),
    );
  }

  Widget _buildPageBar(int totalPages, int currentPage) {
    if (totalPages <= 1) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final theme = Theme.of(context);
    // 结果超过 20 页时只展示一个 20 页的窗口，避免一次性渲染过多。
    final useWindow = totalPages > 20;
    final windowStart = useWindow ? ((currentPage - 1) ~/ 20) * 20 + 1 : 1;
    final windowEnd =
        useWindow ? (windowStart + 19).clamp(1, totalPages) : totalPages;

    final List<int> pageList;
    if (useWindow) {
      pageList = [for (var p = windowStart; p <= windowEnd; p++) p];
    } else {
      pageList =
          _computeVisiblePages(currentPage, totalPages)
              .whereType<int>()
              .toList();
    }

    final children = <Widget>[
      IconButton(
        icon: const Icon(Icons.chevron_left),
        tooltip: '上一页',
        onPressed: currentPage > 1
            ? () => _gotoPage(currentPage - 1, totalPages)
            : null,
      ),
    ];
    for (final p in pageList) {
      final selected = p == currentPage;
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(36, 36),
              backgroundColor: selected
                  ? theme.colorScheme.primaryContainer
                  : null,
              foregroundColor: selected
                  ? theme.colorScheme.onPrimaryContainer
                  : null,
            ),
            onPressed: selected ? null : () => _gotoPage(p, totalPages),
            child: Text('$p'),
          ),
        ),
      );
    }
    children.add(
      IconButton(
        icon: const Icon(Icons.chevron_right),
        tooltip: '下一页',
        onPressed: currentPage < totalPages
            ? () => _gotoPage(currentPage + 1, totalPages)
            : null,
      ),
    );
    children.add(const SizedBox(width: 12));
    children.add(_buildJumpToPage(totalPages));

    final barRow = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );

    final widgets = <Widget>[barRow];
    if (useWindow) {
      widgets.add(const SizedBox(height: 8));
      widgets.add(Center(child: _buildTooManyLine(windowStart, totalPages)));
    }

    return SliverToBoxAdapter(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: widgets,
        ),
      ),
    );
  }

  /// 结果过多（超过 20 页）时，在页码栏下方居中提示，并提供前进/后退 20 页的按钮。
  Widget _buildTooManyLine(int windowStart, int totalPages) {
    final theme = Theme.of(context);
    final children = <Widget>[
      Text(
        '当前搜索作品过多，仅展示20页，是否继续展示',
        style: TextStyle(color: theme.hintColor, fontSize: 13),
      ),
    ];
    if (windowStart > 1) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: TextButton(
            onPressed: () =>
                _gotoPage((windowStart - 20).clamp(1, totalPages), totalPages),
            child: const Text('前20页'),
          ),
        ),
      );
    }
    if (windowStart + 19 < totalPages) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: TextButton(
            onPressed: () =>
                _gotoPage((windowStart + 20).clamp(1, totalPages), totalPages),
            child: const Text('后20页'),
          ),
        ),
      );
    }
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  List<int?> _computeVisiblePages(int current, int total) {
    if (total <= 7) {
      return [for (var i = 1; i <= total; i++) i];
    }
    final pages = <int?>[];
    pages.add(1);
    final left = (current - 1).clamp(2, total - 1);
    final right = (current + 1).clamp(2, total - 1);
    if (left > 2) pages.add(null);
    for (var i = left; i <= right; i++) pages.add(i);
    if (right < total - 1) pages.add(null);
    pages.add(total);
    return pages;
  }

  void _gotoPage(int page, int totalPages) {
    final target = page.clamp(1, totalPages);
    if (target != _searchPageNotifier.value) {
      _searchPageNotifier.value = target;
    }
  }

  void _submitJump(int totalPages) {
    var v = int.tryParse(_jumpPageController.text.trim()) ?? 1;
    if (v < 1) v = 1;
    if (v > totalPages) v = totalPages;
    _jumpPageController.text = '$v';
    _gotoPage(v, totalPages);
  }

  Widget _buildJumpToPage(int totalPages) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.3),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 36,
                child: TextField(
                  controller: _jumpPageController,
                  focusNode: _jumpFocus,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  textAlign: TextAlign.center,
                  onSubmitted: (_) => _submitJump(totalPages),
                  onChanged: (val) {
                    final raw = val.trim();
                    if (raw.isEmpty) return; // 允许清空输入框
                    final v = int.tryParse(raw);
                    if (v == null) return;
                    if (v < 1) {
                      // 0 / 00 / 000 … 一律按 0 处理，钳为 1。
                      // 光标置于开头，使后续再输入的 0 插在最前（变成 "01"）
                      // 而被重新钳回 1，避免 "0"→"1" 后再追 0 变成 "10" 乃至越界成总页数。
                      _jumpPageController.text = '1';
                      _jumpPageController.selection =
                          TextSelection.collapsed(offset: 0);
                    } else if (v > totalPages) {
                      _jumpPageController.text = '$totalPages';
                      _jumpPageController.selection = TextSelection.collapsed(
                        offset: '$totalPages'.length,
                      );
                    }
                  },
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              Text(
                ' / $totalPages',
                style: TextStyle(color: theme.hintColor, fontSize: 14),
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        TextButton(
          onPressed: () => _submitJump(totalPages),
          child: const Text('跳转'),
        ),
      ],
    );
  }

  Future<void> _openSeries(Map<String, dynamic> item) async {
    final source =
        item['sourceDisplayName']?.toString() ??
        item['source']?.toString() ??
        '';

    try {
      final playerData = await sourceRepository.buildPlaybackRequest(
        SourceSearchResult.fromLegacy(item),
      );
      if (!mounted) return;
      if (playerData != null) {
        NavigationService.toPlayback(context, playerData, autoMatch: false);
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('未找到剧集数据: $source'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (error) {
      Log.w('Search', 'Error opening $source: $error');
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
      color: backgroundColor,
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
