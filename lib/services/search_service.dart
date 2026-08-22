import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/api/post.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/utils/bgm_utils.dart';

class SearchService {
  static const int gvMinLength = 2;
  static const int maxHistoryCount = 15;
  static const String _searchHistoryKey = 'search_history';
  static const String noDescriptionText = '暂无描述';

  static const String _isVerticalLayoutKey = 'search_is_vertical_layout';

  final ValueNotifier<List<Map<String, dynamic>>> resultsNotifier =
      ValueNotifier<List<Map<String, dynamic>>>(const []);
  final ValueNotifier<int> selectedSourceIndexNotifier = ValueNotifier<int>(0);
  final ValueNotifier<String> keywordNotifier = ValueNotifier<String>('');
  final ValueNotifier<List<String>> searchHistoryNotifier =
      ValueNotifier<List<String>>(const []);
  final ValueNotifier<bool> showResultsNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isLoadingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<List<String>> sourceLabelsNotifier =
      ValueNotifier<List<String>>(const ['BGM']);
  final ValueNotifier<bool> isVerticalLayoutNotifier = ValueNotifier<bool>(
    false,
  );

  List<Map<String, dynamic>> get results => resultsNotifier.value;
  set results(List<Map<String, dynamic>> v) => resultsNotifier.value = v;

  int get selectedSourceIndex => selectedSourceIndexNotifier.value;
  set selectedSourceIndex(int v) => selectedSourceIndexNotifier.value = v;

  String get keyword => keywordNotifier.value;
  set keyword(String v) => keywordNotifier.value = v;

  List<String> get searchHistory => searchHistoryNotifier.value;
  set searchHistory(List<String> v) => searchHistoryNotifier.value = v;

  bool get showResults => showResultsNotifier.value;
  set showResults(bool v) => showResultsNotifier.value = v;

  bool get isLoading => isLoadingNotifier.value;
  set isLoading(bool v) => isLoadingNotifier.value = v;

  List<String> get sourceLabels => sourceLabelsNotifier.value;

  bool get isVerticalLayout => isVerticalLayoutNotifier.value;
  set isVerticalLayout(bool v) {
    isVerticalLayoutNotifier.value = v;
    Instances.sp.setBool(_isVerticalLayoutKey, v);
  }

  int activeSearchId = 0;
  bool _disposed = false;

  final SourceAdapterService _sourceAdapterService =
      SourceAdapterService.instance;
  List<CustomSourceConfig> customSources = [];
  List<AdapterDescriptor> builtinAdapterSources = [];
  Future<void> init({int? initialSource, String? initialKeyword}) async {
    isVerticalLayoutNotifier.value =
        Instances.sp.getBool(_isVerticalLayoutKey) ?? false;
    await reloadCustomSources();
    if (_disposed) return;

    if (initialSource != null) selectedSourceIndex = initialSource;
    searchHistory = _loadHistory();
    if (initialKeyword != null) keyword = initialKeyword;
  }

  Future<void> reloadCustomSources() async {
    await _sourceAdapterService.init();
    if (_disposed) return;
    customSources = SourceCatalog.instance.enabledCustomSources;
    builtinAdapterSources = SourceCatalog.instance.enabledBuiltinSources;

    sourceLabelsNotifier.value = List<String>.unmodifiable([
      'BGM',
      ...builtinAdapterSources.map((s) => s.displayName),
      ...customSources.map((s) => s.name),
    ]);

    if (selectedSourceIndex >= sourceLabels.length) {
      selectedSourceIndex = 0;
    }
  }

  String get selectedSourceLabel =>
      selectedSourceIndex >= 0 && selectedSourceIndex < sourceLabels.length
      ? sourceLabels[selectedSourceIndex]
      : 'BGM';

  void resetSearch() {
    activeSearchId++;
    keyword = '';
    showResults = false;
    results = const [];
    isLoading = false;
  }

  bool isActiveSearch(int searchId) => searchId == activeSearchId;

  Future<List<Map<String, dynamic>>> executeSearch(String searchKey) async {
    if (_disposed) return const [];
    final query = searchKey.trim();
    if (query.isEmpty) return const [];

    keyword = query;
    final searchResults = await _resolveSearch(query);
    if (!_isGvKey(query)) addSearchHistory(query);
    return searchResults;
  }

  Future<List<Map<String, dynamic>>> _resolveSearch(String query) {
    if (_isGvKey(query)) return _searchByGv(query);
    return _searchSelectedSource(query);
  }

  bool _isGvKey(String query) =>
      query.length > gvMinLength && query.startsWith('gv');

  Future<List<Map<String, dynamic>>> _searchByGv(String query) async {
    final gv = int.tryParse(query.substring(2));
    if (gv == null) return const [];

    return [await getPostDetail(gv)];
  }

  Future<List<Map<String, dynamic>>> _searchSelectedSource(
    String searchKey,
  ) async {
    try {
      if (selectedSourceIndex == 0) {
        final subjects = await BgmService.searchSubjects(searchKey);
        return [
          for (final subject in subjects)
            <String, dynamic>{
              'source': 'bgm',
              'title': subject.nameCn?.isNotEmpty == true
                  ? subject.nameCn
                  : subject.name ?? '未知标题',
              'subtitle':
                  subject.nameCn?.isNotEmpty == true &&
                      subject.name?.isNotEmpty == true &&
                      subject.name != subject.nameCn
                  ? subject.name
                  : subject.summary ?? noDescriptionText,
              'content': BgmUtils.bgmCoverProxyUrl(subject.subjectId),
              'bgmImageUrl': BgmUtils.bgmCoverProxyUrl(subject.subjectId),
              'bgmId': subject.subjectId,
              '_heroTag': 'bgm_cover_${subject.subjectId}',
              if (subject.score != null) 'score': subject.score,
            },
        ];
      }

      final builtinIndex = selectedSourceIndex - 1;
      if (builtinIndex >= 0 && builtinIndex < builtinAdapterSources.length) {
        return _sourceAdapterService.search(
          builtinAdapterSources[builtinIndex].key,
          searchKey,
          fallbackDescription: noDescriptionText,
        );
      }

      final customIndex = builtinIndex - builtinAdapterSources.length;
      if (customIndex < 0 || customIndex >= customSources.length) {
        return const [];
      }

      return _sourceAdapterService.search(
        AdapterRegistry.customSourceKey(customSources[customIndex].id),
        searchKey,
        fallbackDescription: noDescriptionText,
        skipBgmEnhancement: true,
      );
    } catch (error) {
      debugPrint('Search failed for $selectedSourceLabel: $error');
      return const [];
    }
  }

  Future<Map<String, dynamic>?> buildPlayerData(Map<String, dynamic> item) =>
      _sourceAdapterService.buildPlayerData(item);

  List<String> _loadHistory() {
    final historyJson = Instances.sp.getString(_searchHistoryKey);
    if (historyJson == null) return const [];

    try {
      final decoded = jsonDecode(historyJson);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item.toString().isNotEmpty) item.toString(),
      ];
    } catch (_) {
      return const [];
    }
  }

  void _persistHistory(List<String> history) {
    if (_disposed) return;
    searchHistory = history;
    Instances.sp.setString(_searchHistoryKey, jsonEncode(history));
  }

  void addSearchHistory(String value) {
    if (_disposed) return;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;

    final next = <String>[trimmed];
    for (final item in searchHistory) {
      if (item != trimmed) next.add(item);
      if (next.length >= maxHistoryCount) break;
    }
    _persistHistory(next);
  }

  void removeSearchHistory(String value) {
    if (_disposed) return;
    _persistHistory([
      for (final item in searchHistory)
        if (item != value) item,
    ]);
  }

  void clearSearchHistory() {
    if (_disposed) return;
    Instances.sp.remove(_searchHistoryKey);
    searchHistory = const [];
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    activeSearchId++;
    resultsNotifier.dispose();
    selectedSourceIndexNotifier.dispose();
    keywordNotifier.dispose();
    searchHistoryNotifier.dispose();
    showResultsNotifier.dispose();
    isLoadingNotifier.dispose();
    sourceLabelsNotifier.dispose();
    isVerticalLayoutNotifier.dispose();
  }
}
