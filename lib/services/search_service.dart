import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/api/post.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SearchService {
  static const int gvMinLength = 2;
  static const int maxHistoryCount = 15;
  static const String _searchHistoryKey = 'search_history';
  static const String noDescriptionText = '暂无描述';

  final ValueNotifier<List<dynamic>> resultsNotifier =
      ValueNotifier<List<dynamic>>(const []);
  final ValueNotifier<int> selectedSourceIndexNotifier = ValueNotifier<int>(0);
  final ValueNotifier<String> keywordNotifier = ValueNotifier<String>('');
  final ValueNotifier<List<String>> searchHistoryNotifier =
      ValueNotifier<List<String>>(const []);
  final ValueNotifier<bool> showResultsNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isLoadingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<List<String>> sourceLabelsNotifier =
      ValueNotifier<List<String>>(const ['BGM']);

  List<dynamic> get results => resultsNotifier.value;
  set results(List<dynamic> v) => resultsNotifier.value = v;

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

  int activeSearchId = 0;

  final SourceAdapterService _sourceAdapterService = SourceAdapterService();
  List<CustomSourceConfig> customSources = [];
  List<AdapterDescriptor> builtinAdapterSources = [];
  SharedPreferences? _prefs;

  Future<void> init({int? initialSource, String? initialKeyword}) async {
    _prefs = await SharedPreferences.getInstance();
    await reloadCustomSources();

    if (initialSource != null) {
      selectedSourceIndex = initialSource;
    }
    searchHistory = _getSearchHistory();

    if (initialKeyword != null) {
      keyword = initialKeyword;
    }
  }

  Future<void> reloadCustomSources() async {
    await _sourceAdapterService.init();
    customSources = _sourceAdapterService.enabledCustomSources;
    builtinAdapterSources = _sourceAdapterService.enabledBuiltinSources;

    sourceLabelsNotifier.value = List<String>.unmodifiable([
      'BGM',
      ...builtinAdapterSources.map((source) => source.displayName),
      ...customSources.map((source) => source.name),
    ]);

    final maxSourceIndex = sourceLabels.length - 1;
    if (selectedSourceIndex > maxSourceIndex) {
      selectedSourceIndex = 0;
    }
  }

  String get selectedSourceLabel =>
      selectedSourceIndex >= 0 && selectedSourceIndex < sourceLabels.length
      ? sourceLabels[selectedSourceIndex]
      : 'BGM';

  AdapterDescriptor? _selectedBuiltinSource() {
    final index = selectedSourceIndex - 1;
    if (index < 0 || index >= builtinAdapterSources.length) {
      return null;
    }
    return builtinAdapterSources[index];
  }

  CustomSourceConfig? _selectedCustomSource() {
    final index = selectedSourceIndex - builtinAdapterSources.length - 1;
    if (index < 0 || index >= customSources.length) {
      return null;
    }
    return customSources[index];
  }

  void resetSearch() {
    activeSearchId++;
    keyword = '';
    showResults = false;
    results = const [];
    isLoading = false;
  }

  bool isActiveSearch(int searchId) => searchId == activeSearchId;

  Future<List<dynamic>> executeSearch(String searchKey) async {
    final query = searchKey.trim();
    if (query.isEmpty) {
      return const [];
    }

    keyword = query;
    final searchResults = await _resolveSearch(query);

    if (!_isGvKey(query)) {
      addSearchHistory(query);
    }

    return searchResults;
  }

  Future<List<dynamic>> _resolveSearch(String query) async {
    if (_isGvKey(query)) {
      return _searchByGv(query);
    }

    return _searchSelectedSource(query);
  }

  bool _isGvKey(String query) =>
      query.length > gvMinLength && query.startsWith('gv');

  Future<List<dynamic>> _searchByGv(String query) async {
    final gv = int.tryParse(query.substring(2));
    if (gv == null) {
      return const [];
    }

    final detail = jsonDecode((await getPostDetail(gv)).data)['data'];
    return detail == null ? const [] : <dynamic>[detail];
  }

  Future<List<dynamic>> _searchSelectedSource(String searchKey) async {
    try {
      if (selectedSourceIndex == 0) {
        final subjects = await BgmService.searchSubjects(searchKey);
        return subjects.map(_withReliablePoster).toList(growable: false);
      }

      final builtinSource = _selectedBuiltinSource();
      if (builtinSource != null) {
        return _sourceAdapterService.searchBuiltin(
          searchKey,
          builtinSource,
          fallbackDescription: noDescriptionText,
        );
      }

      final customSource = _selectedCustomSource();
      if (customSource == null) {
        return const [];
      }

      return _sourceAdapterService.searchCustom(
        searchKey,
        customSource,
        fallbackDescription: noDescriptionText,
      );
    } catch (error) {
      debugPrint('Search failed for $selectedSourceLabel: $error');
      return const [];
    }
  }

  BgmSubjectInfo _withReliablePoster(BgmSubjectInfo subject) {
    return BgmSubjectInfo(
      subjectId: subject.subjectId,
      name: subject.name,
      nameCn: subject.nameCn,
      summary: subject.summary,
      imageUrl: BgmUtils.bgmCoverProxyUrl(subject.subjectId),
      score: subject.score,
      aliases: subject.aliases,
      hasDetail: subject.hasDetail,
    );
  }

  Future<Map<String, dynamic>?> buildPlayerData(
    Map<String, dynamic> item,
  ) async {
    return _sourceAdapterService.buildPlayerData(item);
  }

  List<String> _getSearchHistory() {
    final historyJson = _prefs?.getString(_searchHistoryKey);
    if (historyJson == null) {
      return const [];
    }

    try {
      final decoded = jsonDecode(historyJson);
      if (decoded is! List) {
        return const [];
      }

      return decoded
          .map((item) => item.toString())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  void _saveSearchHistory() {
    _prefs?.setString(_searchHistoryKey, jsonEncode(searchHistory));
  }

  void addSearchHistory(String value) {
    if (value.trim().isEmpty) {
      return;
    }

    searchHistory = <String>[
      value,
      ...searchHistory.where((item) => item != value),
    ];
    if (searchHistory.length > maxHistoryCount) {
      searchHistory = searchHistory.sublist(0, maxHistoryCount);
    }
    _saveSearchHistory();
  }

  void removeSearchHistory(String value) {
    searchHistory = searchHistory
        .where((item) => item != value)
        .toList(growable: false);
    _saveSearchHistory();
  }

  void clearSearchHistory() {
    _prefs?.remove(_searchHistoryKey);
    searchHistory = const [];
  }

  void dispose() {
    _sourceAdapterService.dispose();
    resultsNotifier.dispose();
    selectedSourceIndexNotifier.dispose();
    keywordNotifier.dispose();
    searchHistoryNotifier.dispose();
    showResultsNotifier.dispose();
    isLoadingNotifier.dispose();
    sourceLabelsNotifier.dispose();
  }
}
