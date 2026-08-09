import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/services/search_service.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/skeletonizer.dart';

class TvSearchPage extends StatefulWidget {
  final String? initialKeyword;
  const TvSearchPage({this.initialKeyword, super.key});

  @override
  State<TvSearchPage> createState() => _TvSearchPageState();
}

class _TvSearchPageState extends State<TvSearchPage> {
  late final SearchService _svc;
  final _searchController = TextEditingController();
  final _searchBoxFocusNode = FocusNode();
  final _textFieldFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _svc = SearchService();
    _initSearch();
  }

  Future<void> _initSearch() async {
    await _svc.init(initialKeyword: widget.initialKeyword);
    if (widget.initialKeyword != null) {
      _searchController.text = _svc.keyword;
      await _search(_svc.keyword);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchBoxFocusNode.dispose();
    _textFieldFocusNode.dispose();
    _svc.dispose();
    super.dispose();
  }

  Future<void> _search(String searchKey) async {
    final query = searchKey.trim();
    if (query.isEmpty) {
      _svc.resetSearch();
      return;
    }
    final searchId = ++_svc.activeSearchId;
    _svc.keyword = query;
    _svc.showResults = true;
    _svc.isLoading = true;
    try {
      final results = await _svc.executeSearch(query);
      if (!mounted || !_svc.isActiveSearch(searchId)) return;
      _svc.results = results;
      _svc.isLoading = false;
    } catch (e) {
      debugPrint('TV 搜索报错: $e');
      if (!mounted || !_svc.isActiveSearch(searchId)) return;
      _svc.results = const [];
      _svc.isLoading = false;
    }
  }

  void _activateSearchField() async {
    if (!_textFieldFocusNode.hasFocus) {
      FocusScope.of(context).requestFocus(_textFieldFocusNode);
    }
    await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  }

  void _finishSearchEditing() {
    if (_textFieldFocusNode.hasFocus) _textFieldFocusNode.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    if (!_searchBoxFocusNode.hasFocus) _searchBoxFocusNode.requestFocus();
  }

  void _openSeries(Map<String, dynamic> item) async {
    try {
      final playerData = await _svc.buildPlayerData(item);
      if (playerData != null && mounted) {
        NavigationService.toPlayer(context, playerData, autoMatch: false);
      }
    } catch (e) {
      debugPrint('打开剧集错误: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 4,
              child: Container(
                decoration: BoxDecoration(
                  color: context.tvHighlightColor(0.04),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: context.tvHighlightColor(0.08),
                    width: 1,
                  ),
                ),
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '搜索中心',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: context.tvTextColor,
                      ),
                    ),
                    const SizedBox(height: 20),

                    TvFocusable(
                      focusNode: _searchBoxFocusNode,
                      onPressed: _activateSearchField,
                      borderRadius: BorderRadius.circular(16),
                      enableScale: false,
                      enableGlow: false,
                      child: Container(
                        height: 52,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: context.tvHighlightColor(0.06),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: context.tvHighlightColor(0.1),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.search,
                              color: context.tvTextSecondaryColor,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                focusNode: _textFieldFocusNode,
                                style: TextStyle(
                                  color: context.tvTextColor,
                                  fontSize: 16,
                                ),
                                decoration: InputDecoration(
                                  hintText: '输入关键词搜索...',
                                  hintStyle: TextStyle(
                                    color: context.tvTextHintColor,
                                    fontSize: 16,
                                  ),
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                                onTap: _activateSearchField,
                                onEditingComplete: _finishSearchEditing,
                                onSubmitted: (v) {
                                  _search(v);
                                  _finishSearchEditing();
                                },
                                textInputAction: TextInputAction.search,
                              ),
                            ),
                            ValueListenableBuilder<TextEditingValue>(
                              valueListenable: _searchController,
                              builder: (_, value, _) {
                                if (value.text.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return TvFocusable(
                                  onPressed: () {
                                    _searchController.clear();
                                    _svc.resetSearch();
                                  },
                                  borderRadius: BorderRadius.circular(12),
                                  enableScale: false,
                                  enableBorder: false,
                                  enableGlow: false,
                                  child: Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: Icon(
                                      Icons.close,
                                      color: context.tvTextSecondaryColor,
                                      size: 18,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),
                    Text(
                      '搜索源选择',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: context.tvTextSecondaryColor,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ValueListenableBuilder<List<String>>(
                      valueListenable: _svc.sourceLabelsNotifier,
                      builder: (_, labels, _) => _buildSourceChips(labels),
                    ),

                    const SizedBox(height: 24),
                    Expanded(child: _buildRecentHistoryView()),
                  ],
                ),
              ),
            ),

            const SizedBox(width: 24),

            Expanded(
              flex: 6,
              child: ValueListenableBuilder<bool>(
                valueListenable: _svc.showResultsNotifier,
                builder: (_, showResults, _) {
                  if (!showResults) {
                    return _buildPlaceholderView();
                  }
                  return _buildResultsArea();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceChips(List<String> sources) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ValueListenableBuilder<int>(
        valueListenable: _svc.selectedSourceIndexNotifier,
        builder: (_, selectedIndex, _) => Row(
          children: [
            for (var index = 0; index < sources.length; index++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TvFocusableChip(
                  label: sources[index],
                  isSelected: selectedIndex == index,
                  fontSize: 13,
                  onPressed: () {
                    if (_svc.selectedSourceIndex != index) {
                      _svc.selectedSourceIndex = index;
                      if (_svc.keyword.trim().isNotEmpty) {
                        _search(_svc.keyword);
                      }
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentHistoryView() {
    return ValueListenableBuilder<List<String>>(
      valueListenable: _svc.searchHistoryNotifier,
      builder: (_, history, _) {
        if (history.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '最近搜索',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: context.tvTextSecondaryColor,
                  ),
                ),
                const Spacer(),
                TvFocusable(
                  onPressed: () => _svc.clearSearchHistory(),
                  borderRadius: BorderRadius.circular(12),
                  enableScale: false,
                  enableGlow: false,
                  enableBorder: false,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text(
                      '清除',
                      style: TextStyle(color: Colors.redAccent, fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item in history)
                      TvFocusableChip(
                        label: item,
                        fontSize: 13,
                        onPressed: () {
                          _searchController.text = item;
                          _search(item);
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPlaceholderView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_rounded, color: context.tvTextHintColor, size: 64),
          const SizedBox(height: 16),
          Text(
            '搜索你想看的番剧',
            style: TextStyle(
              color: context.tvTextColor,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '左侧选择好搜索源，输入剧名或角色',
            style: TextStyle(color: context.tvTextHintColor, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsArea() {
    return ValueListenableBuilder<bool>(
      valueListenable: _svc.isLoadingNotifier,
      builder: (_, isLoading, _) {
        if (isLoading) {
          return AppSkeletonizer(
            enabled: true,
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 0.55,
                crossAxisSpacing: 16,
                mainAxisSpacing: 24,
              ),
              itemCount: 8,
              itemBuilder: (context, index) => Container(
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          );
        }

        return ValueListenableBuilder<List<Map<String, dynamic>>>(
          valueListenable: _svc.resultsNotifier,
          builder: (_, results, _) {
            if (results.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.search_off_rounded,
                      color: context.tvTextHintColor,
                      size: 64,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '未找到相关结果',
                      style: TextStyle(
                        color: context.tvTextHintColor,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '请尝试更换搜索词或选择其他源',
                      style: TextStyle(
                        color: context.tvTextHintColor,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '搜索结果 (${results.length})',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: context.tvTextColor,
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: FocusTraversalGroup(
                    policy: ReadingOrderTraversalPolicy(),
                    child: GridView.builder(
                      physics: const BouncingScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            childAspectRatio: 0.55,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 24,
                          ),
                      itemCount: results.length,
                      itemBuilder: (context, index) =>
                          _buildResultCard(results[index]),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildResultCard(Map<String, dynamic> item) {
    String title;
    String? imageUrl;
    String sourceName;
    double? score;
    VoidCallback onPressed;

    final sourceKey = item['source']?.toString();
    if (sourceKey == 'bgm') {
      title = item['title'] as String;
      imageUrl = item['bgmImageUrl'] as String?;
      sourceName = 'BGM';
      score = item['score'] as double?;
      onPressed = () => NavigationService.toPlayer(context, item);
    } else if (!AdapterRegistry.isAdapterSource(sourceKey)) {
      title = item['title'] as String;
      imageUrl = item['image'] as String?;
      sourceName = '站内';
      onPressed = () => navigateToDetail(context, item);
    } else {
      title = item['title'] as String;
      imageUrl = item['image'] as String?;
      sourceName = item['sourceDisplayName'] as String;
      onPressed = () => _openSeries(item);
    }

    return _TvSearchResultCard(
      title: title,
      imageUrl: imageUrl,
      sourceName: sourceName,
      score: score,
      onPressed: onPressed,
    );
  }
}

class _TvSearchResultCard extends StatelessWidget {
  final String title;
  final String? imageUrl;
  final String sourceName;
  final double? score;
  final VoidCallback onPressed;

  const _TvSearchResultCard({
    required this.title,
    required this.imageUrl,
    required this.sourceName,
    required this.onPressed,
    this.score,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  buildNetworkImage(
                    imageUrl ?? '',
                    double.infinity,
                    double.infinity,
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: context.tvShadowColor(0.8),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        sourceName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  if (score != null && score! > 0)
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: context.tvShadowColor(0.8),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.star,
                              color: Colors.amber,
                              size: 12,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              score!.toStringAsFixed(1),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.tvTextColor,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}
