import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/services/search_service.dart';
import 'package:baka/utils/bgm_utils.dart';
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
      debugPrint('TV Search error: $e');
      if (!mounted || !_svc.isActiveSearch(searchId)) return;
      _svc.results = const [];
      _svc.isLoading = false;
    }
  }

  void _activateSearchField() async {
    if (!_textFieldFocusNode.hasFocus) {
      FocusScope.of(context).requestFocus(_textFieldFocusNode);
      await Future<void>.delayed(Duration.zero);
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
      debugPrint('Error opening series: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.tvBgColor,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSearchBar(),
            Expanded(
              child: ValueListenableBuilder<bool>(
                valueListenable: _svc.showResultsNotifier,
                builder: (_, showResults, _) => Column(
                  children: [
                    if (showResults)
                      ValueListenableBuilder<List<String>>(
                        valueListenable: _svc.sourceLabelsNotifier,
                        builder: (_, labels, _) => _buildSourceSelector(labels),
                      ),
                    Expanded(
                      child: showResults
                          ? _buildResultsArea()
                          : _buildHistoryView(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 24, 48, 16),
      child: Row(
        children: [
          TvFocusable(
            onPressed: () => Navigator.of(context).maybePop(),
            borderRadius: BorderRadius.circular(24),
            enableScale: false,
            enableGlow: false,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.tvHighlightColor(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.arrow_back,
                color: context.tvTextSecondaryColor,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: TvFocusable(
              autofocus: true,
              focusNode: _searchBoxFocusNode,
              onPressed: _activateSearchField,
              borderRadius: BorderRadius.circular(28),
              enableScale: false,
              enableGlow: false,
              child: Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                decoration: BoxDecoration(
                  color: context.tvHighlightColor(0.08),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: context.tvHighlightColor(0.1)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.search,
                      color: context.tvTextSecondaryColor,
                      size: 24,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        focusNode: _textFieldFocusNode,
                        style: TextStyle(
                          color: context.tvTextColor,
                          fontSize: 18,
                        ),
                        decoration: InputDecoration(
                          hintText: '搜索番剧...',
                          hintStyle: TextStyle(
                            color: context.tvTextHintColor,
                            fontSize: 18,
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
                        if (value.text.isEmpty) return const SizedBox.shrink();
                        return TvFocusable(
                          onPressed: () {
                            _searchController.clear();
                            _svc.resetSearch();
                          },
                          borderRadius: BorderRadius.circular(16),
                          enableScale: false,
                          enableBorder: false,
                          enableGlow: false,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.close,
                              color: context.tvTextSecondaryColor,
                              size: 20,
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
        ],
      ),
    );
  }

  Widget _buildSourceSelector(List<String> sources) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 8),
      child: SingleChildScrollView(
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
                    fontSize: 14,
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
      ),
    );
  }

  Widget _buildHistoryView() {
    return ValueListenableBuilder<List<String>>(
      valueListenable: _svc.searchHistoryNotifier,
      builder: (_, history, _) {
        if (history.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search, color: context.tvTextHintColor, size: 64),
                const SizedBox(height: 16),
                Text(
                  '搜索你想看的番剧',
                  style: TextStyle(
                    color: context.tvTextHintColor,
                    fontSize: 18,
                  ),
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    '最近搜索',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: context.tvTextSecondaryColor,
                    ),
                  ),
                  const Spacer(),
                  TvFocusable(
                    onPressed: () => _svc.clearSearchHistory(),
                    borderRadius: BorderRadius.circular(16),
                    enableScale: false,
                    enableGlow: false,
                    enableBorder: false,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Text(
                        '清除',
                        style: TextStyle(color: Colors.redAccent, fontSize: 14),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final item in history)
                    TvFocusableChip(
                      label: item,
                      fontSize: 15,
                      onPressed: () {
                        _searchController.text = item;
                        _search(item);
                      },
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildResultsArea() {
    return ValueListenableBuilder<bool>(
      valueListenable: _svc.isLoadingNotifier,
      builder: (_, isLoading, _) {
        if (isLoading) {
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(48, 16, 48, 60),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 5,
              childAspectRatio: 0.55,
              crossAxisSpacing: 16,
              mainAxisSpacing: 24,
            ),
            itemCount: 10,
            itemBuilder: (_, _) => AppSkeletonizer(
              enabled: true,
              child: _TvSearchResultCard(
                title: '搜索动画标题占位符',
                imageUrl: '',
                sourceName: '数据源',
                score: 8.5,
                onPressed: () {},
              ),
            ),
          );
        }
        return ValueListenableBuilder<List<dynamic>>(
          valueListenable: _svc.resultsNotifier,
          builder: (_, results, _) {
            if (results.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.search_off,
                      color: context.tvTextHintColor,
                      size: 64,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '没有找到相关结果',
                      style: TextStyle(
                        color: context.tvTextHintColor,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '试试换个关键词或切换搜索源',
                      style: TextStyle(
                        color: context.tvTextHintColor,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              );
            }
            return FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(48, 16, 48, 60),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  childAspectRatio: 0.55,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 24,
                ),
                itemCount: results.length,
                itemBuilder: (_, index) => _buildResultCard(results[index]),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildResultCard(dynamic item) {
    String title;
    String? imageUrl;
    String sourceName;
    double? score;
    VoidCallback onPressed;

    if (item is BgmSubjectInfo) {
      title = item.nameCn?.isNotEmpty == true
          ? item.nameCn!
          : item.name ?? '未知';
      imageUrl = item.imageUrl;
      sourceName = 'BGM';
      score = item.score;
      final data = <String, dynamic>{
        'title': title,
        'bgmId': item.subjectId,
        if (item.imageUrl != null) 'bgmImageUrl': item.imageUrl,
        if (item.score != null) 'score': item.score,
      };
      onPressed = () => NavigationService.toPlayer(context, data);
    } else if (item is Map &&
        !AdapterRegistry.isAdapterSource(item['source']?.toString())) {
      title = item['title']?.toString() ?? '未知';
      imageUrl = item['image']?.toString();
      sourceName = '站内';
      onPressed = () => navigateToDetail(context, item);
    } else {
      final sourceKey = item is Map ? item['source']?.toString() : null;
      title = item['title']?.toString() ?? '未知';
      imageUrl = item['image']?.toString();
      sourceName = (item is Map && item['sourceDisplayName'] != null)
          ? item['sourceDisplayName'].toString()
          : sourceKey ?? 'Custom';
      onPressed = () => _openSeries(Map<String, dynamic>.from(item as Map));
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
                  imageUrl != null && imageUrl!.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: imageUrl!,
                          fit: BoxFit.cover,
                          placeholder: (_, _) => Container(
                            color: context.tvHighlightColor(0.05),
                          ),
                          errorWidget: (_, _, _) => Container(
                            color: context.tvHighlightColor(0.05),
                            child: Icon(
                              Icons.broken_image,
                              color: context.tvTextHintColor,
                              size: 32,
                            ),
                          ),
                        )
                      : Container(
                          color: context.tvHighlightColor(0.05),
                          child: Icon(
                            Icons.movie,
                            color: context.tvTextHintColor,
                            size: 32,
                          ),
                        ),

                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: context.tvShadowColor(0.7),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        sourceName,
                        style: TextStyle(
                          color: context.tvTextColor,
                          fontSize: 11,
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
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: context.tvShadowColor(0.7),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.star,
                              color: Colors.amber,
                              size: 14,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              score!.toStringAsFixed(1),
                              style: TextStyle(
                                color: context.tvTextColor,
                                fontSize: 12,
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
