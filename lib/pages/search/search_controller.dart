import 'package:baka/source/runtime/source_operation.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/api/post.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/services/matching/source_match_engine.dart';
import 'package:baka/utils/bgm_utils.dart';

class AnimeSearchController {
  static const int gvMinLength = 2;
  static const int maxHistoryCount = 15;
  static const String _searchHistoryKey = 'search_history';
  static const String noDescriptionText = '暂无描述';
  static const int aggregateSourceIndex = 1;

  static const String _isVerticalLayoutKey = 'search_is_vertical_layout';

  final _results = _SearchResults();
  ValueListenable<List<Map<String, dynamic>>> get resultsNotifier => _results;
  final ValueNotifier<int> selectedSourceIndexNotifier = ValueNotifier<int>(0);
  final ValueNotifier<String> keywordNotifier = ValueNotifier<String>('');
  final ValueNotifier<List<String>> searchHistoryNotifier =
      ValueNotifier<List<String>>(const []);
  final ValueNotifier<bool> showResultsNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isLoadingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<List<String>> sourceLabelsNotifier =
      ValueNotifier<List<String>>(const ['BGM', '聚合搜索']);
  final ValueNotifier<bool> isVerticalLayoutNotifier = ValueNotifier<bool>(
    false,
  );

  bool get isVerticalLayout => isVerticalLayoutNotifier.value;
  set isVerticalLayout(bool v) {
    isVerticalLayoutNotifier.value = v;
    Instances.sp.setBool(_isVerticalLayoutKey, v);
  }

  bool _disposed = false;
  _SearchTask? _running;
  _SearchTask? _pending;
  int _sourceRevision = 0;

  final SourceAdapterService _sourceAdapterService = sourceRepository;
  List<CustomSourceConfig> customSources = [];
  List<AdapterDescriptor> builtinAdapterSources = [];
  Future<void> init({int? initialSource, String? initialKeyword}) async {
    isVerticalLayoutNotifier.value =
        Instances.sp.getBool(_isVerticalLayoutKey) ?? false;
    await reloadCustomSources();
    if (_disposed) return;

    if (initialSource != null &&
        initialSource >= 0 &&
        initialSource < sourceLabelsNotifier.value.length) {
      selectedSourceIndexNotifier.value = initialSource;
    }
    searchHistoryNotifier.value = _loadHistory();
    if (initialKeyword != null) keywordNotifier.value = initialKeyword;
  }

  Future<void> reloadCustomSources() async {
    invalidateSearch();
    _sourceRevision++;
    await _sourceAdapterService.init();
    if (_disposed) return;
    customSources = sourceCatalog.enabledCustomSources;
    builtinAdapterSources = sourceCatalog.enabledBuiltinSources;

    sourceLabelsNotifier.value = List<String>.unmodifiable([
      'BGM',
      '聚合搜索',
      ...builtinAdapterSources.map((s) => s.displayName),
      ...customSources.map((s) => s.name),
    ]);

    if (selectedSourceIndexNotifier.value >=
        sourceLabelsNotifier.value.length) {
      selectedSourceIndexNotifier.value = 0;
    }
  }

  String get selectedSourceLabel =>
      selectedSourceIndexNotifier.value >= 0 &&
          selectedSourceIndexNotifier.value < sourceLabelsNotifier.value.length
      ? sourceLabelsNotifier.value[selectedSourceIndexNotifier.value]
      : 'BGM';

  void resetSearch() {
    invalidateSearch();
    keywordNotifier.value = '';
    showResultsNotifier.value = false;
    _results.value = const [];
    isLoadingNotifier.value = false;
  }

  // Input changes invalidate queued work immediately, before the debounce fires.
  // Cancel source work too, so the newest queued keyword can start immediately.
  void invalidateSearch() {
    _running?.wanted = false;
    _running?.operation.cancel();
    _pending?.completion.complete();
    _pending = null;
  }

  String _sourceKey(int source) {
    if (source == 0) return 'bgm';
    if (source == aggregateSourceIndex) return 'all';
    final builtin = source - 2;
    if (builtin >= 0 && builtin < builtinAdapterSources.length) {
      return builtinAdapterSources[builtin].key;
    }
    final custom = builtin - builtinAdapterSources.length;
    return custom >= 0 && custom < customSources.length
        ? AdapterRegistry.customSourceKey(customSources[custom].id)
        : '';
  }

  Future<void> search(String searchKey) {
    if (_disposed) return SynchronousFuture(null);
    final query = searchKey.trim();
    if (query.isEmpty) {
      resetSearch();
      return SynchronousFuture(null);
    }

    keywordNotifier.value = query;
    final source = _sourceKey(selectedSourceIndexNotifier.value);
    final key = (source: source, query: query, revision: _sourceRevision);
    if (_pending?.key == key) return _pending!.completion.future;
    _pending?.completion.complete();
    _pending = null;
    if (_running?.key == key && !_running!.operation.isCancelled) {
      _running!.wanted = true;
      return _running!.completion.future;
    }
    final task = _SearchTask(key);
    isLoadingNotifier.value = true;
    _results.value = const [];
    showResultsNotifier.value = true;
    if (_running == null) {
      _running = task;
      unawaited(_drainSearches(task));
    } else {
      _running!.wanted = false;
      _running!.operation.cancel();
      _pending = task;
    }
    return task.completion.future;
  }

  Future<void> _drainSearches(_SearchTask task) async {
    while (true) {
      try {
        final query = task.key.query;
        final List<Map<String, dynamic>> results;
        results = await task.operation.run(() async {
          if (!_isGvKey(query)) return _searchSelectedSource(task);
          final gv = int.tryParse(query.substring(2));
          if (gv == null) return const <Map<String, dynamic>>[];
          final abort = Completer<void>();
          final detach = task.operation.token.onCancel(abort.complete);
          try {
            return [await getPostDetail(gv, abortTrigger: abort.future)];
          } finally {
            detach();
          }
        });
        final accepted = !_disposed && task.wanted;
        if (accepted) {
          if (!_isGvKey(query)) addSearchHistory(query);
          _results.value = results;
        }
      } catch (error) {
        if (!_disposed && task.wanted) {
          debugPrint('Search failed for ${task.key.query}: $error');
          _results.value = const [];
        }
      } finally {
        if (!_disposed && task.wanted) isLoadingNotifier.value = false;
        task.completion.complete();
        task.operation.close();
      }
      final next = _pending;
      _pending = null;
      _running = next;
      if (next == null) return;
      task = next;
    }
  }

  bool _isGvKey(String query) =>
      query.length > gvMinLength && query.startsWith('gv');

  Future<List<Map<String, dynamic>>> _searchSelectedSource(
    _SearchTask task,
  ) async {
    final searchKey = task.key.query;
    final source = task.key.source;
    if (source == 'all') return _searchAllSources(task);
    if (source == 'bgm') {
      final subjects = await searchBgmSubjects(searchKey);
      if (_disposed || !task.wanted) return const [];
      return List.generate(subjects.length, (index) {
        final subject = subjects[index];
        final cover = BgmUtils.bgmCoverProxyUrl(subject.subjectId);
        return <String, dynamic>{
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
          'content': cover,
          'bgmImageUrl': cover,
          'bgmId': subject.subjectId,
          'nsfw': subject.nsfw,
          '_heroTag': 'bgm_cover_${subject.subjectId}',
          if (subject.score != null) 'score': subject.score,
        };
      });
    }

    if (source.isEmpty) return const [];
    final results = await _sourceAdapterService.search(
      source,
      searchKey,
      fallbackDescription: noDescriptionText,
      skipBgmEnhancement: AdapterRegistry.isCustomSource(source),
    );
    return [for (final result in results) result.toLegacyMap()];
  }

  Future<List<Map<String, dynamic>>> _searchAllSources(_SearchTask task) async {
    final sources = [
      ...builtinAdapterSources.map((source) => source.key),
      ...customSources.map(
        (source) => AdapterRegistry.customSourceKey(source.id),
      ),
    ];
    final results = <Map<String, dynamic>>[];
    var next = 0;
    bool isActive() => !_disposed && task.wanted && !task.operation.isCancelled;

    Future<void> worker() async {
      while (next < sources.length && isActive()) {
        final source = sources[next++];
        final operation = SourceOperation(
          parent: task.operation,
          timeout: SourceMatchEngine.sourceSearchBudget,
        );
        try {
          final items = await _sourceAdapterService.search(
            source,
            task.key.query,
            operation: operation,
            fallbackDescription: noDescriptionText,
            skipBgmEnhancement: true,
          );
          if (!isActive()) return;
          if (items.isNotEmpty) {
            results.addAll(items.map((result) => result.toLegacyMap()));
            _results.publish(results);
          }
        } catch (error) {
          if (isActive()) debugPrint('Search failed for $source: $error');
        } finally {
          operation.cancel();
          operation.close();
        }
      }
    }

    await Future.wait([
      for (
        var i = 0;
        i < sources.length && i < SourceMatchEngine.autoSearchConcurrency;
        i++
      )
        worker(),
    ]);
    return isActive() ? results : const [];
  }

  List<String> _loadHistory() {
    final historyJson = Instances.sp.getString(_searchHistoryKey);
    if (historyJson == null) return const [];

    try {
      final decoded = jsonDecode(historyJson);
      if (decoded is! List) return const [];
      final history = <String>[];
      final seen = <String>{};
      for (final item in decoded) {
        final value = item.toString().trim();
        if (value.isNotEmpty && seen.add(value)) history.add(value);
        if (history.length == maxHistoryCount) break;
      }
      return history;
    } catch (_) {
      return const [];
    }
  }

  void _persistHistory(List<String> history) {
    if (_disposed) return;
    searchHistoryNotifier.value = history;
    Instances.sp.setString(_searchHistoryKey, jsonEncode(history));
  }

  void addSearchHistory(String value) {
    if (_disposed) return;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    final history = searchHistoryNotifier.value;
    if (history.isNotEmpty && history.first == trimmed) return;

    final next = <String>[trimmed];
    for (final item in history) {
      if (item != trimmed) next.add(item);
      if (next.length >= maxHistoryCount) break;
    }
    _persistHistory(next);
  }

  void removeSearchHistory(String value) {
    if (_disposed) return;
    _persistHistory([
      for (final item in searchHistoryNotifier.value)
        if (item != value) item,
    ]);
  }

  void clearSearchHistory() {
    if (_disposed) return;
    Instances.sp.remove(_searchHistoryKey);
    searchHistoryNotifier.value = const [];
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    invalidateSearch();
    _results.value = const [];
    searchHistoryNotifier.value = const [];
    customSources = const [];
    builtinAdapterSources = const [];
    _results.dispose();
    selectedSourceIndexNotifier.dispose();
    keywordNotifier.dispose();
    searchHistoryNotifier.dispose();
    showResultsNotifier.dispose();
    isLoadingNotifier.dispose();
    sourceLabelsNotifier.dispose();
    isVerticalLayoutNotifier.dispose();
  }
}

final class _SearchTask {
  _SearchTask(this.key);
  final ({String source, String query, int revision}) key;
  final completion = Completer<void>();
  final SourceOperation operation = SourceOperation();
  bool wanted = true;
}

class _SearchResults extends ValueNotifier<List<Map<String, dynamic>>> {
  _SearchResults() : super(const []);

  // One append-only list per query; listeners read it but never mutate it.
  void publish(List<Map<String, dynamic>> results) {
    if (identical(value, results)) {
      notifyListeners();
    } else {
      value = results;
    }
  }
}
