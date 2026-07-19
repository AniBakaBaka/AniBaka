import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/api/post.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/alias_storage_service.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/services/matching/match_memory_service.dart';
import 'package:baka/services/matching/source_match_engine.dart';
import 'package:baka/services/player_service.dart';
import 'package:baka/services/source_reputation_service.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/reg_utils.dart';

// ──────────────────── 预编译正则 ────────────────────
final _reWhitespace = RegExp(r'\s+');
final _reAliasSep = RegExp(r'[/／、,，;；\n]');
final _reBrackets = RegExp(r'[（(].*?[）)]');

// ──────────────────── 工具函数 ────────────────────
String _normalizeKeyword(String value) =>
    value.toLowerCase().replaceAll(_reWhitespace, '');

Iterable<String> _splitAliasText(String value) sync* {
  for (final part in value.split(_reAliasSep)) {
    final alias = part.trim();
    if (alias.isNotEmpty) yield alias;
  }
}

Iterable<String> _buildKeywordVariants(String keyword) sync* {
  final text = keyword.trim();
  if (text.isEmpty) return;

  const replacements = <(String, String)>[
    ('工房', '工坊'),
    ('工坊', '工房'),
    ('后', '後'),
    ('後', '后'),
    ('台', '臺'),
    ('臺', '台'),
  ];
  for (final (from, to) in replacements) {
    if (text.contains(from)) yield text.replaceAll(from, to);
  }

  final bracketFree = text
      .replaceAll(_reBrackets, '')
      .replaceAll(_reWhitespace, ' ')
      .trim();
  if (bracketFree.isNotEmpty && bracketFree != text) yield bracketFree;

  final baseTitle = RegUtils.extractBaseTitle(text);
  if (baseTitle.isNotEmpty && baseTitle != text) yield baseTitle;
}

// ──────────────────── 数据结构 ────────────────────

/// 响应式搜索与进度状态（带相等性判断，减少无效 UI 刷新）
class ProgressState {
  final bool isSearching;
  final Set<String> progressingSources;
  final Set<String> finishedSources;
  final List<String> searchErrors;

  const ProgressState({
    required this.isSearching,
    required this.progressingSources,
    required this.finishedSources,
    required this.searchErrors,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProgressState &&
          isSearching == other.isSearching &&
          setEquals(progressingSources, other.progressingSources) &&
          setEquals(finishedSources, other.finishedSources) &&
          listEquals(searchErrors, other.searchErrors);

  @override
  int get hashCode => Object.hash(
    isSearching,
    Object.hashAllUnordered(progressingSources),
    Object.hashAllUnordered(finishedSources),
    Object.hashAll(searchErrors),
  );
}

/// 搜索结果项（延迟计算附加信息）
class SearchResultItem {
  final String title;
  final String sourceType;
  final Map<String, dynamic> data;

  /// 去重/追踪用的稳定键（只计算一次，避免排序与匹配中反复拼接）
  late final String key =
      '$sourceType|${data['seriesId'] ?? data['id'] ?? data['url'] ?? data['title'] ?? title}';

  /// 匹配候选与其标题指纹/集数等特征在此缓存，多轮排序间复用。
  late final SourceMatchCandidate matchCandidate = SourceMatchCandidate(
    key: key,
    title: title,
    sourceType: sourceType,
    data: data,
  );

  late final String coverUrl = BgmUtils.resolveCoverImage(data) ?? '';
  late final String? episodeInfo = switch (matchCandidate.episodeCount) {
    final int count when count > 0 => '约 $count 集',
    _ => null,
  };
  late final String? lineInfo = _extractLineInfo(data);
  late final String? updateInfo = _extractUpdateInfo(data);

  SearchResultItem({
    required this.title,
    required this.sourceType,
    required this.data,
  });
}

String? _extractLineInfo(Map data) {
  if (data['videos'] case final String s when s.trim().isNotEmpty) {
    final lines = s
        .split('\n')
        .where((l) => l.trim().isNotEmpty && l.contains('#'))
        .length;
    return lines > 1 ? '包含 $lines 条线路' : null;
  }
  if (data['lineCount'] case final num c when c > 0) {
    return '包含 ${c.toInt()} 条线路';
  }
  return null;
}

String? _extractUpdateInfo(Map data) {
  final s = data['time']?.toString().trim() ?? '';
  return s.isEmpty ? null : BgmUtils.formatTimeString(s, '更新时间');
}

class _SearchPolicy {
  static const int searchConcurrency = 4;
  static const int maxManualAliasKeywords = 3;
  static const int maxActiveAutoAliasKeywords = 3;
  static const int minResultsBeforeAliasFallback = 8;
  static const int perSourceResultLimit = 20;
  static const int globalResultLimit = 100;
  static const int autoProbeLimit = 6;
  static const int autoProbeConcurrency = 3;
  static const int switchAutoProbeLimit = 4;
  static const Duration resolveTimeout = Duration(seconds: 12);
  static const Duration directProbeTimeout = Duration(seconds: 8);
  static const Duration memoryProbeTimeout = Duration(seconds: 5);
}

enum SourceProbeStatus { pending, resolving, playable, direct, failed }

class SourceLineChoice {
  final int index;
  final String name;

  const SourceLineChoice({required this.index, required this.name});
}

class SourceProbeState {
  final SearchResultItem item;
  final int episodeIndex;
  final int preferredLine;
  SourceProbeStatus status = SourceProbeStatus.pending;
  Map<String, dynamic>? data;
  List<SourceLineChoice> lines = const <SourceLineChoice>[];
  String? directUrl;
  String? routeKey;
  int? resolvedLineIndex;
  String? error;
  Future<SourceProbeState>? future;

  SourceProbeState({
    required this.item,
    required this.episodeIndex,
    required this.preferredLine,
  });

  bool get isReady =>
      status == SourceProbeStatus.playable ||
      status == SourceProbeStatus.direct;
}

class SourceCandidateState {
  final SearchResultItem item;
  final int score;
  final SourceProbeState probe;

  const SourceCandidateState({
    required this.item,
    required this.score,
    required this.probe,
  });

  SourceProbeStatus get status => probe.status;
  Map<String, dynamic>? get data => probe.data;
  List<SourceLineChoice> get lines => probe.lines;
  String? get error => probe.error;
  bool get isReady => probe.isReady;
}

/// A playable route. Candidates resolving to the same media URL share one
/// group; the URL stays in controller state and is never rendered by the UI.
class DirectSourceGroup {
  const DirectSourceGroup({
    required this.key,
    required this.origins,
    required this.status,
  });

  final String key;
  final List<SourceCandidateState> origins;
  final SourceProbeStatus status;

  SourceCandidateState get primary => origins.first;
  bool get isReady => primary.isReady;
}

class _SearchSession {
  final int id;
  bool autoMatched = false;
  bool autoMatchRerunRequested = false;
  bool autoMatchFinalPassRequested = false;
  Future<void>? autoMatchFuture;

  _SearchSession(this.id);
}

// ──────────────────── 搜索结果缓存 ────────────────────
class _CachedEntry {
  final List<Map<String, dynamic>> items;
  final DateTime cachedAt;
  const _CachedEntry(this.items, this.cachedAt);
  bool get isFresh =>
      DateTime.now().difference(cachedAt) < _SearchResultCache.ttl;
}

class _SearchResultCache {
  static const Duration ttl = Duration(minutes: 10);
  static const int maxSize = 120;

  static final LinkedHashMap<String, _CachedEntry> _cache = LinkedHashMap();
  static final Map<String, Future<List<Map<String, dynamic>>>> _inflight = {};

  static String makeKey(
    String sourceKey,
    String keyword, {
    String version = '',
  }) => '$sourceKey|${_normalizeKeyword(keyword)}|$version';

  static Future<List<Map<String, dynamic>>> load(
    String key,
    Future<List<Map<String, dynamic>>> Function() loader,
  ) async {
    final cached = _cache[key];
    if (cached != null && cached.isFresh) {
      _cache
        ..remove(key)
        ..[key] = cached;
      return cached.items;
    }
    _cache.remove(key);

    final running = _inflight[key];
    if (running != null) return await running;

    final future = loader().then((items) {
      if (_cache.length >= maxSize) _cache.remove(_cache.keys.first);
      _cache[key] = _CachedEntry(items, DateTime.now());
      return items;
    });
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    }
  }
}

// ──────────────────── 关键词去重辅助 ────────────────────
class _KeywordList {
  final List<String> items = [];
  final Set<String> _normalized = {};

  void add(String? value, {String? exclude}) {
    final keyword = value?.trim();
    if (keyword == null || keyword.isEmpty) return;
    final norm = _normalizeKeyword(keyword);
    if (norm.isEmpty) return;
    if (exclude != null && norm == _normalizeKeyword(exclude)) return;
    if (_normalized.add(norm)) items.add(keyword);
  }
}

// ──────────────────── 主控制器 ────────────────────
class VideoSourceSearchController {
  static VideoSourceSearchController? globalCached;
  static String? globalCachedTitle;

  static void cacheGlobal(
    String title,
    VideoSourceSearchController controller,
  ) {
    if (!identical(globalCached, controller)) {
      globalCached?.dispose();
    }
    globalCached = controller;
    globalCachedTitle = title;
  }

  static bool isGlobalCached(VideoSourceSearchController controller) {
    return globalCached == controller;
  }

  final String title;
  final String cover;
  final Map<String, dynamic>? seedData;
  final bool autoMatchMode;
  final int targetEpisodeIndex;

  /// 匹配结果回调
  final ValueChanged<Map<String, dynamic>>? onMatchFound;
  final VoidCallback? onMatchFailed;

  // 反应式状态通知器
  final ValueNotifier<bool> isSearchingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<List<SearchResultItem>> resultsNotifier =
      ValueNotifier<List<SearchResultItem>>([]);
  final ValueNotifier<ProgressState> progressNotifier =
      ValueNotifier<ProgressState>(
        const ProgressState(
          isSearching: false,
          progressingSources: {},
          finishedSources: {},
          searchErrors: [],
        ),
      );

  final ValueNotifier<List<String>> manualAliasesNotifier =
      ValueNotifier<List<String>>([]);
  final ValueNotifier<List<String>> automaticAliasesNotifier =
      ValueNotifier<List<String>>([]);
  final ValueNotifier<Set<String>> activeAutoAliasesNotifier =
      ValueNotifier<Set<String>>({});

  final SourceAdapterService _sourceAdapterService = SourceAdapterService();
  SourceAdapterService get sourceAdapterService => _sourceAdapterService;

  final ValueNotifier<int> candidateRevisionNotifier = ValueNotifier<int>(0);

  final Map<String, SearchResultItem> _resultMap = <String, SearchResultItem>{};
  final Map<String, int> _sourceResultCounts = <String, int>{};
  final List<String> _searchErrors = [];
  final Set<String> _finishedSources = <String>{};
  final Set<String> _progressingSources = <String>{};
  final Map<String, Map<String, dynamic>> _resolvedVideoDataCache =
      <String, Map<String, dynamic>>{};
  final Map<String, Future<Map<String, dynamic>>> _resolveVideoDataFutures =
      <String, Future<Map<String, dynamic>>>{};
  final Map<String, SourceProbeState> _probeStates =
      <String, SourceProbeState>{};
  final Map<String, Map<String, int>> _switchScoreCache =
      <String, Map<String, int>>{};
  final Set<String> _autoTriedProbeKeys = <String>{};
  final SourceMatchEngine _matchEngine = const SourceMatchEngine();

  late final String _primaryKeyword;
  late final String _aliasStorageKey;
  int _searchRunId = 0;
  bool _isDisposed = false;
  bool _userSelected = false;
  _SearchSession? _activeSession;
  Future<SourceMatchContext>? _matchContextFuture;

  void markUserSelected() => _userSelected = true;

  VideoSourceSearchController({
    required this.title,
    required this.cover,
    this.seedData,
    this.autoMatchMode = false,
    this.targetEpisodeIndex = 0,
    this.onMatchFound,
    this.onMatchFailed,
  }) {
    _primaryKeyword = title.trim();
    _aliasStorageKey = _buildAliasStorageKey();
    manualAliasesNotifier.value = _readManualAliases();
    automaticAliasesNotifier.value = _buildAutomaticAliases();
  }

  bool get isDisposed => _isDisposed;

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _searchRunId++;
    _activeSession = null;
    _sourceAdapterService.dispose();
    isSearchingNotifier.dispose();
    resultsNotifier.dispose();
    progressNotifier.dispose();
    manualAliasesNotifier.dispose();
    automaticAliasesNotifier.dispose();
    activeAutoAliasesNotifier.dispose();
    candidateRevisionNotifier.dispose();
  }

  // ──────── 别名存储 ────────

  String _buildAliasStorageKey() {
    final bgmId = seedData?['bgmId']?.toString().trim();
    if (bgmId != null && bgmId.isNotEmpty) return 'bgm:$bgmId';
    return 'title:${_normalizeKeyword(title)}';
  }

  List<String> _buildAutomaticAliases() {
    final candidates = _KeywordList();
    candidates.add(title);
    for (final alias in _extractSeedAliasCandidates()) {
      candidates.add(alias);
    }

    final aliases = _KeywordList();
    for (final candidate in candidates.items) {
      aliases.add(candidate, exclude: _primaryKeyword);
      for (final variant in _buildKeywordVariants(candidate)) {
        aliases.add(variant, exclude: _primaryKeyword);
        if (aliases.items.length >= 6) return aliases.items;
      }
    }
    return aliases.items;
  }

  List<String> _readManualAliases() {
    final store = AliasStorageService.readStore();
    final titleKey = 'title:${_normalizeKeyword(title)}';
    final raw = store[_aliasStorageKey] ?? store[titleKey];
    if (raw is! List) return [];

    final aliases = _KeywordList();
    for (final item in raw) {
      aliases.add(item?.toString());
    }
    return aliases.items;
  }

  Future<void> _saveManualAliases() async {
    await AliasStorageService.saveAliases(
      _aliasStorageKey,
      manualAliasesNotifier.value,
    );
  }

  Future<void> toggleAutoAlias(String alias) async {
    if (isSearchingNotifier.value) return;
    final nextActive = Set<String>.of(activeAutoAliasesNotifier.value);
    if (!nextActive.remove(alias)) nextActive.add(alias);
    activeAutoAliasesNotifier.value = nextActive;
    await startSearch();
  }

  Future<bool> addManualAlias(String value) async {
    if (isSearchingNotifier.value) return false;

    final nextAliases = List<String>.of(manualAliasesNotifier.value);
    final existingNorm = <String>{
      _normalizeKeyword(_primaryKeyword),
      for (final a in manualAliasesNotifier.value) _normalizeKeyword(a),
      for (final a in automaticAliasesNotifier.value)
        if (activeAutoAliasesNotifier.value.contains(a)) _normalizeKeyword(a),
    };
    var added = false;

    for (final alias in _splitAliasText(value)) {
      final normalized = _normalizeKeyword(alias);
      if (normalized.isNotEmpty && existingNorm.add(normalized)) {
        nextAliases.add(alias.trim());
        added = true;
      }
    }
    if (!added) return false;

    manualAliasesNotifier.value = nextAliases;
    await _saveManualAliases();
    await startSearch();
    return true;
  }

  Future<void> removeManualAlias(String alias) async {
    if (isSearchingNotifier.value) return;
    final normAlias = _normalizeKeyword(alias);
    manualAliasesNotifier.value = manualAliasesNotifier.value
        .where((item) => _normalizeKeyword(item) != normAlias)
        .toList(growable: false);
    await _saveManualAliases();
    await startSearch();
  }

  // ──────── 种子别名提取 ────────

  Iterable<String> _extractSeedAliasCandidates() sync* {
    final detail = seedData?['bgmDetailData'];
    if (detail is! Map) return;

    yield* _splitAliasText(detail['name_cn']?.toString() ?? '');
    yield* _splitAliasText(detail['name']?.toString() ?? '');

    final infobox = detail['infobox'];
    if (infobox is List) {
      for (final item in infobox) {
        if (item is! Map) continue;
        final key = item['key']?.toString() ?? '';
        if (!_isAliasInfoKey(key)) continue;
        yield* _flattenAliasValue(item['value']);
      }
    }
  }

  bool _isAliasInfoKey(String key) {
    final lower = key.toLowerCase();
    return key.contains('别名') ||
        key.contains('中文名') ||
        key.contains('日文名') ||
        key.contains('英文名') ||
        key.contains('原名') ||
        lower.contains('alias');
  }

  Iterable<String> _flattenAliasValue(dynamic value) sync* {
    if (value is String) {
      yield* _splitAliasText(value);
    } else if (value is List) {
      for (final item in value) {
        yield* _flattenAliasValue(item);
      }
    } else if (value is Map) {
      final alias = value['v'] ?? value['value'] ?? value['name'];
      if (alias != null) yield* _splitAliasText(alias.toString());
    } else if (value != null) {
      yield* _splitAliasText(value.toString());
    }
  }

  // ──────── 搜索执行 ────────

  Future<void> startSearch() async {
    final session = _SearchSession(++_searchRunId);
    _activeSession = session;
    _resetSearchState();
    isSearchingNotifier.value = true;
    _emitProgress(isSearching: true);

    await _sourceAdapterService.init();
    if (_isSessionStopped(session)) return;

    // 历史命中只是最快路径，失效时不应让完整搜索白等数秒。
    final rememberedMatchFuture = autoMatchMode
        ? _tryRememberedMatch(session)
        : null;

    final quickSources = _sourceAdapterService.enabledQuickSearchSources;
    final customSources = _sourceAdapterService.enabledCustomSources;
    final keywords = _buildKeywordPlan();

    _progressingSources
      ..clear()
      ..addAll([
        'internal',
        ...quickSources.map((s) => s.key),
        ...customSources.map((s) => AdapterRegistry.customSourceKey(s.id)),
      ]);

    final searches = <Future<void> Function()>[
      () => _searchSource(
        session: session,
        keywords: keywords,
        sourceKey: 'internal',
        version: '',
        loadFunc: _loadInternalSearch,
        errorMsg: '站内搜索失败',
      ),
      for (final source in quickSources)
        () => _searchSource(
          session: session,
          keywords: keywords,
          sourceKey: source.key,
          version: '',
          loadFunc: (keyword) => _sourceAdapterService.searchBuiltin(
            keyword,
            source,
            skipBgmEnhancement: true,
          ),
          errorMsg: '${source.displayName} 搜索失败',
        ),
      for (final source in customSources)
        () => _searchSource(
          session: session,
          keywords: keywords,
          sourceKey: AdapterRegistry.customSourceKey(source.id),
          version: source.updatedAt.millisecondsSinceEpoch.toString(),
          loadFunc: (keyword) => _sourceAdapterService.searchCustom(
            keyword,
            source,
            skipBgmEnhancement: true,
          ),
          errorMsg: '${source.name} 搜索失败',
        ),
    ];

    final searchFuture = _runBounded(searches, _SearchPolicy.searchConcurrency);

    // A remembered route opens immediately while the rest of the sources keep
    // filling the route list in the background.
    if (rememberedMatchFuture != null && await rememberedMatchFuture) {
      unawaited(_completeSearch(session, searchFuture));
      return;
    }

    await _completeSearch(session, searchFuture);
  }

  Future<void> _completeSearch(
    _SearchSession session,
    Future<void> searchFuture,
  ) async {
    await searchFuture;
    if (_isSessionStopped(session)) return;

    final finalMatchFuture = autoMatchMode && !_userSelected
        ? _queueAutoMatch(session, finalPass: true)
        : null;
    if (finalMatchFuture != null) await finalMatchFuture;
    if (_isDisposed || _activeSession != session) return;

    isSearchingNotifier.value = false;
    _emitProgress(isSearching: false);

    if (autoMatchMode && !session.autoMatched && !_userSelected) {
      onMatchFailed?.call();
    }
  }

  Future<void> _runBounded(
    List<Future<void> Function()> tasks,
    int concurrency,
  ) async {
    var next = 0;

    Future<void> worker() async {
      while (next < tasks.length) {
        final task = tasks[next++];
        await task();
      }
    }

    final workerCount = tasks.length < concurrency ? tasks.length : concurrency;
    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  bool _isSessionStopped(_SearchSession session) {
    return _isDisposed ||
        _activeSession != session ||
        session.id != _searchRunId;
  }

  void _resetSearchState() {
    _resolvedVideoDataCache.clear();
    _resolveVideoDataFutures.clear();
    _probeStates.clear();
    _switchScoreCache.clear();
    _autoTriedProbeKeys.clear();
    _matchContextFuture = null;
    _resultMap.clear();
    _sourceResultCounts.clear();
    _searchErrors.clear();
    _finishedSources.clear();
    _progressingSources.clear();
    resultsNotifier.value = const <SearchResultItem>[];
  }

  void _emitProgress({required bool isSearching}) {
    final next = ProgressState(
      isSearching: isSearching,
      progressingSources: Set.unmodifiable(_progressingSources),
      finishedSources: Set.unmodifiable(_finishedSources),
      searchErrors: List.unmodifiable(_searchErrors),
    );
    if (next != progressNotifier.value) {
      progressNotifier.value = next;
    }
  }

  Future<void> _searchSource({
    required _SearchSession session,
    required List<String> keywords,
    required String sourceKey,
    required String version,
    required Future<List<Map<String, dynamic>>> Function(String keyword)
    loadFunc,
    required String errorMsg,
  }) async {
    if (keywords.isEmpty) {
      _finishSource(session, sourceKey);
      return;
    }

    var attempted = 0;
    var failed = 0;
    var foundForSource = false;

    for (var i = 0; i < keywords.length; i++) {
      if (_isSessionStopped(session)) return;
      if (i > 0 &&
          _resultMap.length >= _SearchPolicy.minResultsBeforeAliasFallback) {
        break;
      }

      attempted++;
      final keyword = keywords[i];
      List<Map<String, dynamic>>? rawResults;
      try {
        rawResults = await _SearchResultCache.load(
          _SearchResultCache.makeKey(sourceKey, keyword, version: version),
          () => loadFunc(keyword),
        );
      } catch (_) {
        rawResults = null;
      }
      if (_isSessionStopped(session)) return;

      if (rawResults == null) {
        failed++;
        continue;
      }

      final seen = <String>{};
      final items = <SearchResultItem>[];
      for (final raw in rawResults) {
        final data = Map<String, dynamic>.from(raw)
          ..['_searchKeyword'] = keyword;
        final item = SearchResultItem(
          title: data['title']?.toString() ?? '',
          sourceType: sourceKey,
          data: data,
        );
        if (seen.add(item.key)) items.add(item);
      }
      if (items.isNotEmpty) {
        foundForSource = true;
        _appendResults(session, items);
        break;
      }
    }

    _finishSource(
      session,
      sourceKey,
      error: attempted > 0 && failed == attempted && !foundForSource
          ? errorMsg
          : null,
    );
  }

  List<String> _buildKeywordPlan() {
    final kw = _KeywordList();
    kw.add(_primaryKeyword);
    for (final alias in manualAliasesNotifier.value.take(
      _SearchPolicy.maxManualAliasKeywords,
    )) {
      kw.add(alias);
    }
    final activeAuto = activeAutoAliasesNotifier.value;
    var autoCount = 0;
    for (final alias in automaticAliasesNotifier.value) {
      if (!activeAuto.contains(alias)) continue;
      kw.add(alias);
      if (++autoCount >= _SearchPolicy.maxActiveAutoAliasKeywords) break;
    }
    return kw.items;
  }

  Future<List<Map<String, dynamic>>> _loadInternalSearch(String keyword) async {
    final response = await getSearch(keyword);
    final rawResults = BgmUtils.parseJsonMap(response.data)?['data'];
    if (rawResults is! List) return const <Map<String, dynamic>>[];

    final results = <Map<String, dynamic>>[];
    for (final item in rawResults) {
      if (item is! Map || item['videos'] == null) continue;
      results.add(Map<String, dynamic>.from(item));
    }
    return results;
  }

  void _appendResults(
    _SearchSession session,
    List<SearchResultItem> newResults,
  ) {
    if (_isSessionStopped(session)) return;

    var accepted = 0;
    for (final item in newResults) {
      if (_resultMap.containsKey(item.key)) continue;
      if (_resultMap.length >= _SearchPolicy.globalResultLimit) break;

      final sourceCount = _sourceResultCounts[item.sourceType] ?? 0;
      if (sourceCount >= _SearchPolicy.perSourceResultLimit) continue;

      _resultMap[item.key] = item;
      _sourceResultCounts[item.sourceType] = sourceCount + 1;
      accepted++;
    }

    if (accepted > 0) {
      _switchScoreCache.clear();
      resultsNotifier.value = List.unmodifiable(_resultMap.values);
      if (autoMatchMode && !_userSelected) {
        unawaited(_queueAutoMatch(session));
      }
    }
  }

  void _finishSource(
    _SearchSession session,
    String sourceKey, {
    String? error,
  }) {
    if (_isDisposed || _activeSession != session) return;

    if (error != null) _searchErrors.add(error);
    _progressingSources.remove(sourceKey);
    _finishedSources.add(sourceKey);

    _emitProgress(isSearching: true);
  }

  // ──────── 自动匹配 ────────

  bool _hasPlayableContent(Map<String, dynamic> data) {
    final videos = data['videos'];
    if (videos is String && videos.trim().isNotEmpty) return true;
    final videoList = data['videoList'];
    if (videoList is List && videoList.isNotEmpty) return true;
    return false;
  }

  Future<void> _queueAutoMatch(
    _SearchSession session, {
    bool finalPass = false,
  }) {
    if (_isSessionStopped(session) || session.autoMatched || _userSelected) {
      return Future.value();
    }

    session.autoMatchRerunRequested = true;
    if (finalPass) session.autoMatchFinalPassRequested = true;

    final running = session.autoMatchFuture;
    if (running != null) return running;

    final future = _drainAutoMatchQueue(session);
    session.autoMatchFuture = future;
    future.whenComplete(() {
      if (identical(session.autoMatchFuture, future)) {
        session.autoMatchFuture = null;
      }
    });
    return future;
  }

  Future<void> _drainAutoMatchQueue(_SearchSession session) async {
    while (session.autoMatchRerunRequested &&
        !_isSessionStopped(session) &&
        !session.autoMatched &&
        !_userSelected) {
      session.autoMatchRerunRequested = false;
      final finalPass = session.autoMatchFinalPassRequested;
      session.autoMatchFinalPassRequested = false;
      await _runAutoMatch(session, finalPass: finalPass);
    }
  }

  Future<void> _runAutoMatch(
    _SearchSession session, {
    required bool finalPass,
  }) async {
    if (session.autoMatched) return;
    final context = await _getMatchContext();
    if (_isSessionStopped(session) || session.autoMatched || _userSelected) {
      return;
    }

    final ranked = _matchEngine.rank([
      for (final item in _resultMap.values)
        if (item.sourceType != 'internal') item.matchCandidate,
    ], context);

    final candidates = <SearchResultItem>[];
    for (final score in ranked) {
      if (finalPass) {
        if (score.confidence < 0.45) break;
      } else if (!score.shouldProbeImmediately) {
        continue;
      }
      final item = _resultMap[score.candidate.key];
      if (item != null &&
          !_autoTriedProbeKeys.contains(
            _probeKey(item, _targetEpisodeIndex, 1),
          )) {
        candidates.add(item);
      }
      if (candidates.length >= _SearchPolicy.autoProbeLimit) break;
    }

    var next = 0;
    Future<void> worker() async {
      while (next < candidates.length && !_isSessionStopped(session)) {
        final item = candidates[next++];
        final key = _probeKey(item, _targetEpisodeIndex, 1);
        _autoTriedProbeKeys.add(key);
        final probe = await ensureCandidatePlayable(
          item,
          episodeIndex: _targetEpisodeIndex,
          preferredLine: 1,
        );
        if (_isSessionStopped(session) || _userSelected) return;

        if (probe.status != SourceProbeStatus.direct) {
          unawaited(_recordSourceFailure(item.sourceType));
        }
      }
    }

    final workerCount = candidates.length < _SearchPolicy.autoProbeConcurrency
        ? candidates.length
        : _SearchPolicy.autoProbeConcurrency;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    if (!finalPass ||
        _isSessionStopped(session) ||
        session.autoMatched ||
        _userSelected) {
      return;
    }

    // Auto-match and the player's source switch now consume the same probe
    // states and the same ordering. Do not let network completion order choose
    // the source: wait for the bounded final probe pass, then take the
    // highest-ranked verified route.
    SourceCandidateState? best;
    for (final candidate in getSwitchCandidates(
      episodeIndex: _targetEpisodeIndex,
      preferredLine: 1,
    )) {
      if (candidate.status == SourceProbeStatus.direct &&
          candidate.data != null) {
        best = candidate;
        break;
      }
    }
    if (best == null || !_claimAutoMatch(session)) return;

    _finishAutoMatch(session, best.data!);
    unawaited(_recordMatchSuccess(best.item, best.data!));
  }

  bool _claimAutoMatch(_SearchSession session) {
    if (_isSessionStopped(session) || session.autoMatched || _userSelected) {
      return false;
    }
    session.autoMatched = true;
    return true;
  }

  void _finishAutoMatch(_SearchSession session, Map<String, dynamic> data) {
    if (_isDisposed || _activeSession != session || _userSelected) return;
    onMatchFound?.call(Map<String, dynamic>.from(data));
  }

  Future<SourceMatchContext> _getMatchContext() {
    return _matchContextFuture ??= _buildMatchContext();
  }

  Future<SourceMatchContext> _buildMatchContext() async {
    final detail = BgmUtils.asMap(seedData?['bgmDetailData']);
    final declaredEpisodeCount = BgmUtils.toInt(
      detail?['eps'] ?? detail?['total_episodes'] ?? detail?['totalEpisodes'],
    );
    final episodes = detail?['episodes'];
    final loadedEpisodeCount = episodes is List
        ? episodes.where((episode) {
            return episode is Map &&
                (BgmUtils.toInt(episode['type']) ?? 0) == 0;
          }).length
        : 0;
    final episodeCount =
        declaredEpisodeCount ??
        (loadedEpisodeCount > 0 ? loadedEpisodeCount : null);

    return _baseMatchContext(
      bgmEpisodeCount: episodeCount,
      bgmCompleted:
          declaredEpisodeCount != null &&
          loadedEpisodeCount >= declaredEpisodeCount,
      bgmYear: BgmService.resolveAirYear(detail),
    );
  }

  SourceMatchContext _baseMatchContext({
    String? currentSource,
    int? bgmEpisodeCount,
    bool bgmCompleted = false,
    int? bgmYear,
  }) {
    return SourceMatchContext(
      primaryTitle: _primaryKeyword,
      manualAliases: manualAliasesNotifier.value,
      automaticAliases: automaticAliasesNotifier.value,
      bgmEpisodeCount: bgmEpisodeCount,
      bgmCompleted: bgmCompleted,
      bgmYear: bgmYear,
      sourceReputation: SourceReputationService.snapshotFor(
        _resultMap.values.map((item) => item.sourceType),
      ),
      currentSource: currentSource,
    );
  }

  int get _targetEpisodeIndex =>
      targetEpisodeIndex < 0 ? 0 : targetEpisodeIndex;

  Future<bool> _tryRememberedMatch(_SearchSession session) async {
    final bgmId = BgmUtils.toInt(seedData?['bgmId']);
    final memory = MatchMemoryService.read(
      bgmId: bgmId,
      title: _primaryKeyword,
    );
    if (memory == null) return false;

    final data = <String, dynamic>{
      'title': memory.title?.isNotEmpty == true
          ? memory.title
          : _primaryKeyword,
      'seriesId': memory.seriesId,
      'source': memory.source,
      'sourceDisplayName': memory.sourceDisplayName ?? memory.source,
    };
    final item = SearchResultItem(
      title: data['title']?.toString() ?? _primaryKeyword,
      sourceType: memory.source,
      data: _mergeSeedData(data),
    );

    try {
      final probe = await ensureCandidatePlayable(
        item,
        episodeIndex: _targetEpisodeIndex,
        preferredLine: 1,
        probeDirect: true,
      ).timeout(_SearchPolicy.memoryProbeTimeout);
      if (_isSessionStopped(session) || session.autoMatched || _userSelected) {
        return true;
      }
      if (probe.status == SourceProbeStatus.direct && probe.data != null) {
        if (_claimAutoMatch(session)) {
          _finishAutoMatch(session, probe.data!);
          unawaited(_recordMatchSuccess(item, probe.data!));
        }
        return true;
      }
    } catch (_) {
      // Fall back to a full search below.
    }
    unawaited(_forgetFailedMemory(memory.source, bgmId));
    return false;
  }

  Future<void> _recordMatchSuccess(
    SearchResultItem item,
    Map<String, dynamic> data,
  ) async {
    try {
      await SourceReputationService.recordSuccess(item.sourceType);
      await _rememberMatch(item, data);
    } catch (_) {
      // 记忆与信誉只用于后续排序，不能阻断本次播放。
    }
  }

  Future<void> _recordSourceFailure(String source) async {
    try {
      await SourceReputationService.recordFailure(source);
    } catch (_) {
      // 信誉写入失败不影响继续尝试下一个候选。
    }
  }

  Future<void> _forgetFailedMemory(String source, int? bgmId) async {
    await _recordSourceFailure(source);
    try {
      await MatchMemoryService.remove(bgmId: bgmId, title: _primaryKeyword);
    } catch (_) {
      // 清理失败时下次仍会超时回退，但不影响本次完整搜索。
    }
  }

  Future<void> persistMatchMemory(
    SearchResultItem item,
    Map<String, dynamic> data,
  ) {
    return _rememberMatch(item, data);
  }

  Future<void> _rememberMatch(
    SearchResultItem item,
    Map<String, dynamic> data,
  ) {
    return MatchMemoryService.writeSuccess(
      bgmId: BgmUtils.toInt(seedData?['bgmId'] ?? data['bgmId']),
      title: _primaryKeyword,
      source: item.sourceType,
      seriesId:
          item.data['seriesId']?.toString() ??
          data['seriesUrl']?.toString() ??
          data['id']?.toString() ??
          '',
      candidateTitle: item.title,
      sourceDisplayName:
          item.data['sourceDisplayName']?.toString() ??
          data['sourceDisplayName']?.toString(),
    );
  }

  List<SourceCandidateState> getSwitchCandidates({
    required int episodeIndex,
    required int preferredLine,
    String? currentSource,
  }) {
    final scoreCache = _switchScoreCache.putIfAbsent(
      currentSource ?? '',
      () => <String, int>{},
    );
    SourceMatchContext? context;
    int scoreFor(SearchResultItem item) => scoreCache.putIfAbsent(
      item.key,
      () => _matchEngine
          .score(
            item.matchCandidate,
            context ??= _baseMatchContext(currentSource: currentSource),
          )
          .score,
    );

    final scored = <SourceCandidateState>[
      for (final item in _resultMap.values)
        SourceCandidateState(
          item: item,
          score: scoreFor(item),
          probe: _probeFor(item, episodeIndex, preferredLine),
        ),
    ];

    scored.sort(_compareSwitchCandidates);
    return scored;
  }

  /// Fills the bounded probe window from an already ranked route snapshot.
  void startSwitchProbes(Iterable<SourceCandidateState> candidates) {
    var active = 0;
    for (final candidate in candidates) {
      if (candidate.status == SourceProbeStatus.resolving) {
        if (++active >= _SearchPolicy.switchAutoProbeLimit) return;
      } else if (candidate.status == SourceProbeStatus.pending) {
        unawaited(
          ensureCandidatePlayable(
            candidate.item,
            episodeIndex: candidate.probe.episodeIndex,
            preferredLine: candidate.probe.preferredLine,
          ),
        );
        if (++active >= _SearchPolicy.switchAutoProbeLimit) return;
      }
    }
  }

  Future<SourceProbeState> resolveSwitchCandidate(
    SourceCandidateState candidate,
  ) {
    final probe = candidate.probe;
    if (probe.isReady) return Future.value(probe);
    return ensureCandidatePlayable(
      candidate.item,
      episodeIndex: probe.episodeIndex,
      preferredLine: probe.preferredLine,
    );
  }

  List<DirectSourceGroup> getDirectSourceGroups({
    required int episodeIndex,
    required int preferredLine,
    String? currentSource,
  }) {
    final candidates = getSwitchCandidates(
      episodeIndex: episodeIndex,
      preferredLine: preferredLine,
      currentSource: currentSource,
    );
    final grouped = <String, List<SourceCandidateState>>{};
    for (final candidate in candidates) {
      final key = candidate.probe.routeKey ?? 'candidate:${candidate.item.key}';
      (grouped[key] ??= <SourceCandidateState>[]).add(candidate);
    }

    // Candidate order already reflects status and score. Map insertion order
    // therefore gives the grouped routes the same order without another sort.
    return <DirectSourceGroup>[
      for (final entry in grouped.entries)
        DirectSourceGroup(
          key: entry.key,
          origins: entry.value,
          status: entry.value.first.status,
        ),
    ];
  }

  String _canonicalDirectUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) return value;
    final query = uri.queryParametersAll.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return uri
        .replace(
          scheme: uri.scheme.toLowerCase(),
          host: uri.host.toLowerCase(),
          fragment: '',
          queryParameters: {for (final entry in query) entry.key: entry.value},
        )
        .toString();
  }

  int _compareSwitchCandidates(SourceCandidateState a, SourceCandidateState b) {
    final statusCompare = _probeStatusRank(
      a.status,
    ).compareTo(_probeStatusRank(b.status));
    if (statusCompare != 0) return statusCompare;
    return b.score.compareTo(a.score);
  }

  int _probeStatusRank(SourceProbeStatus status) {
    switch (status) {
      case SourceProbeStatus.direct:
        return 0;
      case SourceProbeStatus.playable:
        return 1;
      case SourceProbeStatus.resolving:
        return 2;
      case SourceProbeStatus.pending:
        return 3;
      case SourceProbeStatus.failed:
        return 4;
    }
  }

  Future<SourceProbeState> ensureCandidatePlayable(
    SearchResultItem item, {
    required int episodeIndex,
    required int preferredLine,
    bool probeDirect = true,
  }) {
    final probe = _probeFor(item, episodeIndex, preferredLine);
    if (probe.status == SourceProbeStatus.direct ||
        probe.status == SourceProbeStatus.playable) {
      return Future.value(probe);
    }

    final running = probe.future;
    if (running != null) return running;

    final future = _resolveProbe(probe, probeDirect: probeDirect);
    probe.future = future;
    future.whenComplete(() {
      if (identical(probe.future, future)) probe.future = null;
    });
    return future;
  }

  SourceProbeState _probeFor(
    SearchResultItem item,
    int episodeIndex,
    int preferredLine,
  ) {
    final key = _probeKey(item, episodeIndex, preferredLine);
    return _probeStates.putIfAbsent(
      key,
      () => SourceProbeState(
        item: item,
        episodeIndex: episodeIndex,
        preferredLine: preferredLine,
      ),
    );
  }

  String _probeKey(SearchResultItem item, int episodeIndex, int preferredLine) {
    return '${item.key}|$episodeIndex|$preferredLine';
  }

  Future<SourceProbeState> _resolveProbe(
    SourceProbeState probe, {
    required bool probeDirect,
  }) async {
    probe
      ..status = SourceProbeStatus.resolving
      ..error = null;
    _bumpCandidateRevision();

    try {
      final data = await resolveVideoData(
        probe.item,
      ).timeout(_SearchPolicy.resolveTimeout);
      if (!_hasPlayableContent(data)) {
        probe
          ..status = SourceProbeStatus.failed
          ..error = '没有可播放剧集';
        return probe;
      }

      final lines = _extractLineChoices(data, probe.episodeIndex);
      if (lines.isEmpty) {
        probe
          ..status = SourceProbeStatus.failed
          ..error = '当前集没有可用线路';
        return probe;
      }

      probe
        ..data = data
        ..lines = lines;

      final source = data['source']?.toString();
      if (!probeDirect ||
          source == null ||
          source.isEmpty ||
          source == 'internal') {
        probe.status = SourceProbeStatus.playable;
        return probe;
      }

      final direct = await _probeDirectLink(data, probe);
      if (direct == null) {
        probe.status = SourceProbeStatus.playable;
      } else {
        probe
          ..status = SourceProbeStatus.direct
          ..directUrl = direct.url
          ..routeKey = 'direct:${_canonicalDirectUrl(direct.url)}'
          ..resolvedLineIndex = direct.lineIndex;
        PlayerService.storePrefetchedPlaybackMedia(
          data,
          episodeIndex: probe.episodeIndex,
          lineIndex: direct.lineIndex,
          episodeId: direct.episodeId,
          url: direct.url,
          httpHeaders: direct.httpHeaders,
        );
      }
      return probe;
    } catch (e) {
      probe
        ..status = SourceProbeStatus.failed
        ..error = e.toString();
      return probe;
    } finally {
      _bumpCandidateRevision();
    }
  }

  Future<
    ({
      String url,
      String episodeId,
      int lineIndex,
      Map<String, String> httpHeaders,
    })?
  >
  _probeDirectLink(Map<String, dynamic> data, SourceProbeState probe) async {
    final adapter = _getAdapterForData(data);
    if (adapter == null || adapter.requiresCustomPlayback) return null;

    final videoList = VideoUtils.extractVideoList(data);
    if (videoList.isEmpty) return null;

    final episodeIndex = probe.episodeIndex
        .clamp(0, videoList.length - 1)
        .toInt();
    final episode = videoList[episodeIndex];
    final lineCount = VideoUtils.getPathCount(episode);
    if (lineCount <= 0) return null;

    final preferredLine = probe.preferredLine.clamp(1, lineCount).toInt();
    final probeLines = <int>[
      preferredLine,
      for (var i = 1; i <= lineCount; i++)
        if (i != preferredLine) i,
    ];

    // Resolve one line at a time. Launching multiple speculative requests was
    // expensive and their successful URLs used to be discarded anyway.
    for (final lineIndex in probeLines.take(2)) {
      final episodeId = VideoUtils.getVideoUrl(episode, lineIndex);
      if (episodeId == null || episodeId.isEmpty) continue;
      final media = await _resolveDirectLink(adapter, episodeId);
      if (media != null) {
        return (
          url: media.url,
          episodeId: episodeId,
          lineIndex: lineIndex,
          httpHeaders: media.httpHeaders,
        );
      }
    }
    return null;
  }

  Future<({String url, Map<String, String> httpHeaders})?> _resolveDirectLink(
    AdapterBase adapter,
    String episodeId,
  ) async {
    try {
      final media = await adapter
          .resolvePlaybackMedia(episodeId)
          .timeout(
            _SearchPolicy.directProbeTimeout,
            onTimeout: () => (url: '', httpHeaders: const <String, String>{}),
          );
      return VideoUrlExtractor.isVideoUrl(media.url) ? media : null;
    } catch (_) {
      return null;
    }
  }

  AdapterBase? _getAdapterForData(Map<String, dynamic> data) {
    final source = data['source']?.toString();
    if (source == null || source.isEmpty) return null;

    if (AdapterRegistry.isCustomSource(source)) {
      final sourceConfig = data['sourceConfig'];
      CustomSourceConfig? config;
      if (sourceConfig is CustomSourceConfig) {
        config = sourceConfig;
      } else {
        final sourceId = source.substring(
          AdapterRegistry.customSourcePrefix.length,
        );
        config = _sourceAdapterService.customSourceById(sourceId);
      }
      return config == null
          ? null
          : _sourceAdapterService.getCustomAdapter(config);
    }

    return _sourceAdapterService.getBuiltinAdapter(source);
  }

  List<SourceLineChoice> _extractLineChoices(
    Map<String, dynamic> data,
    int requestedEpisodeIndex,
  ) {
    final videoList = VideoUtils.extractVideoList(data);
    if (videoList.isEmpty) return const <SourceLineChoice>[];

    final episodeIndex = requestedEpisodeIndex
        .clamp(0, videoList.length - 1)
        .toInt();
    final lineCount = VideoUtils.getPathCount(videoList[episodeIndex]);
    if (lineCount <= 0) return const <SourceLineChoice>[];

    final rawNames = data['sourceNames'];
    final sourceNames = rawNames is List
        ? rawNames.map((item) => item.toString()).toList(growable: false)
        : const <String>[];

    return [
      for (var i = 1; i <= lineCount; i++)
        SourceLineChoice(
          index: i,
          name: (i - 1 < sourceNames.length && sourceNames[i - 1].isNotEmpty)
              ? sourceNames[i - 1]
              : '线路$i',
        ),
    ];
  }

  void _bumpCandidateRevision() {
    if (!_isDisposed) {
      candidateRevisionNotifier.value = candidateRevisionNotifier.value + 1;
    }
  }

  // ──────── 数据解析 ────────

  Future<Map<String, dynamic>> resolveVideoData(SearchResultItem item) async {
    final key = item.key;
    final cached = _resolvedVideoDataCache[key];
    if (cached != null) return Map<String, dynamic>.from(cached);

    final running = _resolveVideoDataFutures[key];
    if (running != null) {
      return running.then((d) => Map<String, dynamic>.from(d));
    }

    final runId = _searchRunId;
    final future = _resolveVideoDataUncached(item).then((data) {
      if (!_isDisposed && runId == _searchRunId) {
        _resolvedVideoDataCache[key] = Map<String, dynamic>.from(data);
      }
      return data;
    });
    _resolveVideoDataFutures[key] = future;
    try {
      return Map<String, dynamic>.from(await future);
    } finally {
      if (identical(_resolveVideoDataFutures[key], future)) {
        _resolveVideoDataFutures.remove(key);
      }
    }
  }

  Future<Map<String, dynamic>> _resolveVideoDataUncached(
    SearchResultItem item,
  ) async {
    final itemData = _mergeSeedData(Map<String, dynamic>.from(item.data));
    if (item.sourceType == 'internal') {
      return itemData;
    }
    final resolved = await _sourceAdapterService.buildPlayerData(itemData);
    return _mergeSeedData(resolved ?? itemData);
  }

  Map<String, dynamic> _mergeSeedData(Map<String, dynamic> data) {
    final seed = seedData;
    if (seed == null || seed.isEmpty) return data;

    final seedBgmId = BgmUtils.toInt(seed['bgmId']);
    if (seedBgmId != null && seedBgmId > 0) data['bgmId'] = seedBgmId;

    if (seed['score'] != null) data['score'] = seed['score'];
    if (seed['bgmDetailData'] != null) {
      data['bgmDetailData'] = seed['bgmDetailData'];
    }

    final seedImageUrl = seed['bgmImageUrl']?.toString().trim();
    if (seedImageUrl != null && seedImageUrl.isNotEmpty) {
      data['bgmImageUrl'] = seed['bgmImageUrl'];
    }
    return data;
  }

  // ──────── 公开只读属性 ────────

  bool get hasMatched => _activeSession?.autoMatched ?? false;
  Set<String> get triedKeys => Set.unmodifiable(_autoTriedProbeKeys);
  List<SearchResultItem> get currentResults =>
      List.unmodifiable(_resultMap.values);
  Set<String> get progressingSources => _progressingSources;
  List<String> get searchErrors => _searchErrors;
}
