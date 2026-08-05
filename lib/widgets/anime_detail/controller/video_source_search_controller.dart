import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/api/post.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/services/alias_storage_service.dart';
import 'package:baka/services/matching/match_memory_service.dart';
import 'package:baka/services/matching/source_match_engine.dart';
import 'package:baka/services/player_service.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/reg_utils.dart';

final _reWhitespace = RegExp(r'\s+');
final _reAliasSep = RegExp(r'[/／、,，;；\n]');
final _reBrackets = RegExp(r'[（(].*?[）)]');

String _norm(String value) => value.toLowerCase().replaceAll(_reWhitespace, '');

/// 响应式搜索与进度状态（是否搜索中以 isSearchingNotifier 为唯一真源）
class ProgressState {
  final Set<String> progressingSources;
  final Set<String> finishedSources;
  final List<String> searchErrors;

  const ProgressState({
    required this.progressingSources,
    required this.finishedSources,
    required this.searchErrors,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProgressState &&
          setEquals(progressingSources, other.progressingSources) &&
          setEquals(finishedSources, other.finishedSources) &&
          listEquals(searchErrors, other.searchErrors);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(progressingSources),
    Object.hashAllUnordered(finishedSources),
    Object.hashAll(searchErrors),
  );
}

/// 搜索结果项
class SearchResultItem {
  final String title;
  final String sourceType;
  final Map<String, dynamic> data;

  late final String key =
      '$sourceType|${data['seriesId'] ?? data['id'] ?? data['url'] ?? data['title'] ?? title}';

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
  late final String? lineInfo = _lineInfo(data);
  late final String? updateInfo = _updateInfo(data);

  SearchResultItem({
    required this.title,
    required this.sourceType,
    required this.data,
  });
}

String? _lineInfo(Map data) {
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

String? _updateInfo(Map data) {
  final s = data['time']?.toString().trim() ?? '';
  return s.isEmpty ? null : BgmUtils.formatTimeString(s, '更新时间');
}

class _Policy {
  static const searchConcurrency = 4;
  static const maxManualAliases = 3;
  static const maxAutoAliases = 3;
  static const minResultsBeforeAlias = 8;
  static const perSourceLimit = 20;
  static const globalLimit = 100;
  static const autoProbeLimit = 12;
  static const autoProbePerSource = 2;
  static const autoProbeConcurrency = 3;
  static const switchProbeLimit = 4;
  static const resolveTimeout = Duration(seconds: 12);
  static const directProbeTimeout = Duration(seconds: 8);
  static const memoryProbeTimeout = Duration(seconds: 5);
}

enum SourceProbeStatus { pending, resolving, playable, direct, failed }

class SourceProbeState {
  final SearchResultItem item;
  final int episodeIndex;
  final int preferredLine;
  SourceProbeStatus status = SourceProbeStatus.pending;
  Map<String, dynamic>? data;
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
  bool get isReady => probe.isReady;
}

/// 同一直链 URL 的候选归组。
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

class _CacheEntry {
  final List<Map<String, dynamic>> items;
  final DateTime at;
  const _CacheEntry(this.items, this.at);
  bool get fresh => DateTime.now().difference(at) < const Duration(minutes: 10);
}

/// 源搜索结果短时缓存（跨控制器实例共享）。
class _ResultCache {
  static const maxSize = 48;
  static const maxItems = 30;
  static final _cache = <String, _CacheEntry>{};
  static final _inflight = <String, Future<List<Map<String, dynamic>>>>{};

  static String key(String source, String keyword, {String version = ''}) =>
      '$source|${_norm(keyword)}|$version';

  static Future<List<Map<String, dynamic>>> load(
    String cacheKey,
    Future<List<Map<String, dynamic>>> Function() loader,
  ) async {
    final hit = _cache[cacheKey];
    if (hit != null && hit.fresh) {
      _cache
        ..remove(cacheKey)
        ..[cacheKey] = hit;
      return hit.items;
    }
    _cache.remove(cacheKey);

    final running = _inflight[cacheKey];
    if (running != null) return running;

    final future = loader().then((items) {
      final clipped = items.length <= maxItems
          ? items
          : items.sublist(0, maxItems);
      if (_cache.length >= maxSize) _cache.remove(_cache.keys.first);
      _cache[cacheKey] = _CacheEntry(clipped, DateTime.now());
      return clipped;
    });
    _inflight[cacheKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_inflight[cacheKey], future)) _inflight.remove(cacheKey);
    }
  }
}

/// 去重关键词列表。
class _Keywords {
  final items = <String>[];
  final _seen = <String>{};

  void add(String? value, {String? exclude}) {
    final k = value?.trim();
    if (k == null || k.isEmpty) return;
    final n = _norm(k);
    if (n.isEmpty) return;
    if (exclude != null && n == _norm(exclude)) return;
    if (_seen.add(n)) items.add(k);
  }
}

class VideoSourceSearchController {
  static VideoSourceSearchController? globalCached;
  static String? globalCachedTitle;

  static void cacheGlobal(
    String title,
    VideoSourceSearchController controller,
  ) {
    if (!identical(globalCached, controller)) globalCached?.dispose();
    globalCached = controller;
    globalCachedTitle = title;
  }

  static bool isGlobalCached(VideoSourceSearchController controller) =>
      identical(globalCached, controller);

  /// 按标题复用全局缓存控制器；标题不同则重建（沿用旧 seedData 的语义与此前一致）
  static VideoSourceSearchController sharedFor({
    required String title,
    Map<String, dynamic>? seedData,
  }) {
    if (globalCachedTitle != title || globalCached == null) {
      globalCached?.dispose();
      globalCached = VideoSourceSearchController(
        title: title,
        seedData: seedData,
      );
      globalCachedTitle = title;
    }
    return globalCached!;
  }

  final String title;
  final Map<String, dynamic>? seedData;
  final bool autoMatchMode;
  final int targetEpisodeIndex;
  final ValueChanged<Map<String, dynamic>>? onMatchFound;
  final VoidCallback? onMatchFailed;

  final isSearchingNotifier = ValueNotifier(false);
  final resultsNotifier = ValueNotifier<List<SearchResultItem>>(const []);
  final progressNotifier = ValueNotifier(
    const ProgressState(
      progressingSources: {},
      finishedSources: {},
      searchErrors: [],
    ),
  );
  final manualAliasesNotifier = ValueNotifier<List<String>>(const []);
  final automaticAliasesNotifier = ValueNotifier<List<String>>(const []);
  final activeAutoAliasesNotifier = ValueNotifier<Set<String>>({});
  final candidateRevisionNotifier = ValueNotifier(0);

  final _adapter = SourceAdapterService();

  Future<void>? _adapterInitFuture;

  /// 适配器初始化（含自定义源加载）；结果记忆化，失败保持粘滞
  Future<void> ensureAdapterReady() => _adapterInitFuture ??= _adapter.init();

  final _results = <String, SearchResultItem>{};
  final _sourceCounts = <String, int>{};
  final _errors = <String>[];
  final _finished = <String>{};
  final _progressing = <String>{};
  final _resolvedCache = <String, Map<String, dynamic>>{};
  final _resolveFutures = <String, Future<Map<String, dynamic>>>{};
  final _probes = <String, SourceProbeState>{};
  final _scoreCache = <String, Map<String, int>>{};
  final _rankCache = <String, SourceMatchScore>{};
  final _triedProbes = <String>{};
  final _engine = const SourceMatchEngine();

  late final String _primary;
  late final String _aliasKey;
  int _runId = 0;
  bool _disposed = false;
  bool _userSelected = false;
  bool _autoMatched = false;
  Future<void>? _autoMatchFuture;
  Future<SourceMatchContext>? _matchContextFuture;

  void markUserSelected() => _userSelected = true;

  VideoSourceSearchController({
    required this.title,
    this.seedData,
    this.autoMatchMode = false,
    this.targetEpisodeIndex = 0,
    this.onMatchFound,
    this.onMatchFailed,
  }) {
    _primary = title.trim();
    _aliasKey = _buildAliasKey();
    manualAliasesNotifier.value = _readManualAliases();
    automaticAliasesNotifier.value = _buildAutoAliases();
  }

  bool get isDisposed => _disposed;
  bool get hasMatched => _autoMatched;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _runId++;
    _adapter.dispose();
    isSearchingNotifier.dispose();
    resultsNotifier.dispose();
    progressNotifier.dispose();
    manualAliasesNotifier.dispose();
    automaticAliasesNotifier.dispose();
    activeAutoAliasesNotifier.dispose();
    candidateRevisionNotifier.dispose();
  }

  // ── aliases ──

  String _buildAliasKey() {
    final bgmId = seedData?['bgmId']?.toString().trim();
    if (bgmId != null && bgmId.isNotEmpty) return 'bgm:$bgmId';
    return 'title:${_norm(title)}';
  }

  List<String> _buildAutoAliases() {
    final pool = _Keywords()..add(title);
    for (final a in _seedAliases()) {
      pool.add(a);
    }

    final out = _Keywords();
    for (final c in pool.items) {
      out.add(c, exclude: _primary);
      // 去括号 / 去季后缀
      final noBracket = c
          .replaceAll(_reBrackets, '')
          .replaceAll(_reWhitespace, ' ')
          .trim();
      if (noBracket.isNotEmpty) out.add(noBracket, exclude: _primary);
      final base = RegUtils.extractBaseTitle(c);
      if (base.isNotEmpty) out.add(base, exclude: _primary);
      if (out.items.length >= 6) break;
    }
    return out.items;
  }

  List<String> _readManualAliases() {
    final store = AliasStorageService.readStore();
    final raw = store[_aliasKey] ?? store['title:${_norm(title)}'];
    if (raw is! List) return const [];
    final out = _Keywords();
    for (final item in raw) {
      out.add(item?.toString());
    }
    return out.items;
  }

  Future<void> _saveManualAliases() =>
      AliasStorageService.saveAliases(_aliasKey, manualAliasesNotifier.value);

  Future<void> toggleAutoAlias(String alias) async {
    if (isSearchingNotifier.value) return;
    final next = Set<String>.of(activeAutoAliasesNotifier.value);
    if (!next.remove(alias)) next.add(alias);
    activeAutoAliasesNotifier.value = next;
    await startSearch();
  }

  Future<bool> addManualAlias(String value) async {
    if (isSearchingNotifier.value) return false;
    final next = List<String>.of(manualAliasesNotifier.value);
    final seen = <String>{
      _norm(_primary),
      for (final a in next) _norm(a),
      for (final a in automaticAliasesNotifier.value)
        if (activeAutoAliasesNotifier.value.contains(a)) _norm(a),
    };
    var added = false;
    for (final part in value.split(_reAliasSep)) {
      final alias = part.trim();
      if (alias.isEmpty) continue;
      if (seen.add(_norm(alias))) {
        next.add(alias);
        added = true;
      }
    }
    if (!added) return false;
    manualAliasesNotifier.value = next;
    await _saveManualAliases();
    await startSearch();
    return true;
  }

  Future<void> removeManualAlias(String alias) async {
    if (isSearchingNotifier.value) return;
    final n = _norm(alias);
    manualAliasesNotifier.value = manualAliasesNotifier.value
        .where((a) => _norm(a) != n)
        .toList(growable: false);
    await _saveManualAliases();
    await startSearch();
  }

  Iterable<String> _seedAliases() sync* {
    final detail = seedData?['bgmDetailData'];
    if (detail is! Map) return;
    yield* _splitAliases(detail['name_cn']?.toString());
    yield* _splitAliases(detail['name']?.toString());
    final infobox = detail['infobox'];
    if (infobox is! List) return;
    for (final item in infobox) {
      if (item is! Map) continue;
      final key = item['key']?.toString() ?? '';
      if (!_isAliasKey(key)) continue;
      yield* _flattenAlias(item['value']);
    }
  }

  bool _isAliasKey(String key) {
    final lower = key.toLowerCase();
    return key.contains('别名') ||
        key.contains('中文名') ||
        key.contains('日文名') ||
        key.contains('英文名') ||
        key.contains('原名') ||
        lower.contains('alias');
  }

  Iterable<String> _splitAliases(String? value) sync* {
    if (value == null || value.isEmpty) return;
    for (final part in value.split(_reAliasSep)) {
      final a = part.trim();
      if (a.isNotEmpty) yield a;
    }
  }

  Iterable<String> _flattenAlias(dynamic value) sync* {
    if (value is String) {
      yield* _splitAliases(value);
    } else if (value is List) {
      for (final item in value) {
        yield* _flattenAlias(item);
      }
    } else if (value is Map) {
      final v = value['v'] ?? value['value'] ?? value['name'];
      if (v != null) yield* _splitAliases(v.toString());
    } else if (value != null) {
      yield* _splitAliases(value.toString());
    }
  }

  // ── search ──

  Future<void> startSearch() async {
    final runId = ++_runId;
    _autoMatched = false;
    _autoMatchFuture = null;
    _resetState();
    isSearchingNotifier.value = true;
    _emitProgress();

    await ensureAdapterReady();
    if (!_alive(runId)) return;

    // 记忆命中与全量搜索并行；命中则先回调，搜索继续填列表。
    final memoryFuture = autoMatchMode ? _tryMemory(runId) : null;

    final quick = SourceCatalog.instance.quickSearchSources;
    final custom = SourceCatalog.instance.enabledCustomSources;
    final keywords = _keywordPlan();

    _progressing
      ..clear()
      ..addAll([
        'internal',
        ...quick.map((s) => s.key),
        ...custom.map((s) => AdapterRegistry.customSourceKey(s.id)),
      ]);

    final tasks = <Future<void> Function()>[
      () => _searchSource(
        runId: runId,
        keywords: keywords,
        sourceKey: 'internal',
        version: '',
        load: _loadInternal,
        errorMsg: '站内搜索失败',
      ),
      for (final s in quick)
        () => _searchSource(
          runId: runId,
          keywords: keywords,
          sourceKey: s.key,
          version: '',
          load: (kw) => _adapter.searchBuiltin(kw, s, skipBgmEnhancement: true),
          errorMsg: '${s.displayName} 搜索失败',
        ),
      for (final s in custom)
        () => _searchSource(
          runId: runId,
          keywords: keywords,
          sourceKey: AdapterRegistry.customSourceKey(s.id),
          version: s.updatedAt.millisecondsSinceEpoch.toString(),
          load: (kw) => _adapter.searchCustom(kw, s, skipBgmEnhancement: true),
          errorMsg: '${s.name} 搜索失败',
        ),
    ];

    final searchFuture = _runPool(
      tasks,
      _Policy.searchConcurrency,
      shouldStop: () => _autoMatched || !_alive(runId),
    );

    if (memoryFuture != null && await memoryFuture) {
      unawaited(_finishSearch(runId, searchFuture));
      return;
    }
    await _finishSearch(runId, searchFuture);
  }

  Future<void> _finishSearch(int runId, Future<void> searchFuture) async {
    await searchFuture;
    if (!_alive(runId)) return;

    if (autoMatchMode && !_userSelected && !_autoMatched) {
      await _runAutoMatch(runId, finalPass: true);
    }
    if (!_alive(runId)) return;

    if (!_disposed) {
      isSearchingNotifier.value = false;
      _emitProgress();
    }

    if (autoMatchMode && !_autoMatched && !_userSelected) {
      onMatchFailed?.call();
    }
  }

  /// 停止当前搜索轮次；已发出的网络请求无法取消，但后续任务不再启动。
  void cancelSearch() {
    _runId++;
    if (!_disposed) {
      isSearchingNotifier.value = false;
      _emitProgress();
    }
  }

  Future<void> _runPool(
    List<Future<void> Function()> tasks,
    int concurrency, {
    bool Function()? shouldStop,
  }) async {
    var next = 0;
    Future<void> worker() async {
      while (next < tasks.length) {
        if (shouldStop?.call() ?? false) return;
        final i = next++;
        await tasks[i]();
      }
    }

    final n = tasks.length < concurrency ? tasks.length : concurrency;
    if (n <= 0) return;
    await Future.wait(List.generate(n, (_) => worker()));
  }

  bool _alive(int runId) => !_disposed && runId == _runId;

  void _resetState() {
    _resolvedCache.clear();
    _resolveFutures.clear();
    _probes.clear();
    _scoreCache.clear();
    _rankCache.clear();
    _triedProbes.clear();
    _matchContextFuture = null;
    _results.clear();
    _sourceCounts.clear();
    _errors.clear();
    _finished.clear();
    _progressing.clear();
    resultsNotifier.value = const [];
  }

  void _emitProgress() {
    final next = ProgressState(
      progressingSources: Set.unmodifiable(_progressing),
      finishedSources: Set.unmodifiable(_finished),
      searchErrors: List.unmodifiable(_errors),
    );
    if (next != progressNotifier.value) progressNotifier.value = next;
  }

  Future<void> _searchSource({
    required int runId,
    required List<String> keywords,
    required String sourceKey,
    required String version,
    required Future<List<Map<String, dynamic>>> Function(String) load,
    required String errorMsg,
  }) async {
    if (keywords.isEmpty) {
      _finishSource(runId, sourceKey);
      return;
    }

    var attempted = 0;
    var failed = 0;
    var found = false;

    for (var i = 0; i < keywords.length; i++) {
      if (!_alive(runId) || _autoMatched) return;
      if (i > 0 && _results.length >= _Policy.minResultsBeforeAlias) break;

      attempted++;
      List<Map<String, dynamic>>? raw;
      try {
        raw = await _ResultCache.load(
          _ResultCache.key(sourceKey, keywords[i], version: version),
          () => load(keywords[i]),
        );
      } catch (_) {
        raw = null;
      }
      if (!_alive(runId) || _autoMatched) return;

      if (raw == null) {
        failed++;
        continue;
      }

      final seen = <String>{};
      final items = <SearchResultItem>[];
      for (final r in raw) {
        final data = Map<String, dynamic>.from(r)
          ..['_searchKeyword'] = keywords[i];
        final item = SearchResultItem(
          title: data['title']?.toString() ?? '',
          sourceType: sourceKey,
          data: data,
        );
        if (seen.add(item.key)) items.add(item);
      }
      if (items.isNotEmpty) {
        found = true;
        _appendResults(runId, items);
        break;
      }
    }

    _finishSource(
      runId,
      sourceKey,
      error: attempted > 0 && failed == attempted && !found ? errorMsg : null,
    );
  }

  List<String> _keywordPlan() {
    final kw = _Keywords()..add(_primary);
    for (final a in manualAliasesNotifier.value.take(
      _Policy.maxManualAliases,
    )) {
      kw.add(a);
    }
    var auto = 0;
    final active = activeAutoAliasesNotifier.value;
    for (final a in automaticAliasesNotifier.value) {
      if (!active.contains(a)) continue;
      kw.add(a);
      if (++auto >= _Policy.maxAutoAliases) break;
    }
    return kw.items;
  }

  Future<List<Map<String, dynamic>>> _loadInternal(String keyword) async {
    final response = await getSearch(keyword);
    final raw = BgmUtils.parseJsonMap(response.data)?['data'];
    if (raw is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is Map && item['videos'] != null) {
        out.add(Map<String, dynamic>.from(item));
      }
    }
    return out;
  }

  void _appendResults(int runId, List<SearchResultItem> items) {
    if (!_alive(runId)) return;
    var accepted = 0;
    for (final item in items) {
      if (_results.containsKey(item.key)) continue;
      if (_results.length >= _Policy.globalLimit) break;
      final count = _sourceCounts[item.sourceType] ?? 0;
      if (count >= _Policy.perSourceLimit) continue;
      _results[item.key] = item;
      _sourceCounts[item.sourceType] = count + 1;
      accepted++;
    }
    if (accepted == 0) return;

    resultsNotifier.value = List.unmodifiable(_results.values);
    if (autoMatchMode && !_userSelected && !_autoMatched) {
      unawaited(_scheduleAutoMatch(runId));
    }
  }

  void _finishSource(int runId, String sourceKey, {String? error}) {
    if (!_alive(runId)) return;
    if (error != null) _errors.add(error);
    _progressing.remove(sourceKey);
    _finished.add(sourceKey);
    _emitProgress();
  }

  // ── auto match ──

  Future<void> _scheduleAutoMatch(int runId) {
    if (!_alive(runId) || _userSelected || _autoMatched) {
      return Future.value();
    }
    return _autoMatchFuture ??= _runAutoMatch(
      runId,
      finalPass: false,
    ).whenComplete(() => _autoMatchFuture = null);
  }

  Future<void> _runAutoMatch(int runId, {required bool finalPass}) async {
    if (!_alive(runId) || _userSelected || _autoMatched) return;

    final context = await _matchContext();
    if (!_alive(runId) || _userSelected || _autoMatched) return;

    // 每批结果只为新增候选打分：分数是纯函数且 context 在一轮搜索内不变，
    // 全量重排改为增量记忆化，避免 O(源数²) 的重复 bigram 相似度计算。
    final ranked = [
      for (final item in _results.values)
        if (item.sourceType != 'internal')
          _rankCache[item.key] ??= _engine.score(item.matchCandidate, context),
    ]..sort(SourceMatchEngine.compareScores);

    // 每源最多 2 个，轮询取样，避免单源占满探测预算。
    final bySource = <String, List<SearchResultItem>>{};
    for (final s in ranked) {
      if (finalPass) {
        if (s.confidence < 0.45) break;
      } else if (!s.shouldProbeImmediately) {
        continue;
      }
      final item = _results[s.candidate.key];
      if (item == null) continue;
      final key = _probeKey(item, _ep, 1);
      if (_triedProbes.contains(key)) continue;
      final list = bySource.putIfAbsent(item.sourceType, () => []);
      if (list.length < _Policy.autoProbePerSource) list.add(item);
    }

    final candidates = <SearchResultItem>[];
    for (var round = 0; round < _Policy.autoProbePerSource; round++) {
      for (final list in bySource.values) {
        if (round < list.length) {
          candidates.add(list[round]);
          if (candidates.length >= _Policy.autoProbeLimit) break;
        }
      }
      if (candidates.length >= _Policy.autoProbeLimit) break;
    }
    if (candidates.isEmpty) return;

    var next = 0;
    Future<void> worker() async {
      while (next < candidates.length && _alive(runId) && !_autoMatched) {
        if (_userSelected) return;
        final item = candidates[next++];
        _triedProbes.add(_probeKey(item, _ep, 1));
        final probe = await ensureCandidatePlayable(
          item,
          episodeIndex: _ep,
          preferredLine: 1,
        );
        if (!_alive(runId) || _userSelected || _autoMatched) return;
        if (probe.status == SourceProbeStatus.direct && probe.data != null) {
          _autoMatched = true;
          onMatchFound?.call(Map<String, dynamic>.from(probe.data!));
          unawaited(_remember(item, probe.data!));
          return;
        }
      }
    }

    final n = candidates.length < _Policy.autoProbeConcurrency
        ? candidates.length
        : _Policy.autoProbeConcurrency;
    await Future.wait(List.generate(n, (_) => worker()));
  }

  /// 查找下一个备用可播放的候选源数据（排除排除列表中的键）
  Future<Map<String, dynamic>?> findNextPlayableCandidate({
    required Set<String> excludedKeys,
    int? episodeIndex,
  }) async {
    final ep = episodeIndex ?? _ep;
    final context = await _matchContext();

    final ranked = [
      for (final item in _results.values)
        if (item.sourceType != 'internal' &&
            !excludedKeys.contains(item.key) &&
            !excludedKeys.contains(item.sourceType))
          _rankCache[item.key] ??= _engine.score(item.matchCandidate, context),
    ]..sort(SourceMatchEngine.compareScores);

    for (final rankedItem in ranked) {
      final item = _results[rankedItem.candidate.key];
      if (item == null) continue;
      final probe = await ensureCandidatePlayable(
        item,
        episodeIndex: ep,
        preferredLine: 1,
      );
      if (probe.status == SourceProbeStatus.direct && probe.data != null) {
        unawaited(_remember(item, probe.data!));
        return Map<String, dynamic>.from(probe.data!);
      }
    }
    return null;
  }

  int get _ep => targetEpisodeIndex < 0 ? 0 : targetEpisodeIndex;

  Future<SourceMatchContext> _matchContext() {
    return _matchContextFuture ??= Future(() {
      final detail = BgmUtils.asMap(seedData?['bgmDetailData']);
      final declared = BgmUtils.toInt(
        detail?['eps'] ?? detail?['total_episodes'] ?? detail?['totalEpisodes'],
      );
      final episodes = detail?['episodes'];
      final loaded = episodes is List
          ? episodes
                .where((e) => e is Map && (BgmUtils.toInt(e['type']) ?? 0) == 0)
                .length
          : 0;
      return SourceMatchContext(
        primaryTitle: _primary,
        manualAliases: manualAliasesNotifier.value,
        automaticAliases: automaticAliasesNotifier.value,
        bgmEpisodeCount: declared ?? (loaded > 0 ? loaded : null),
        bgmCompleted: declared != null && loaded >= declared,
      );
    });
  }

  SourceMatchContext _baseContext({String? currentSource}) =>
      SourceMatchContext(
        primaryTitle: _primary,
        manualAliases: manualAliasesNotifier.value,
        automaticAliases: automaticAliasesNotifier.value,
        currentSource: currentSource,
      );

  Future<bool> _tryMemory(int runId) async {
    final bgmId = BgmUtils.toInt(seedData?['bgmId']);
    final memory = MatchMemoryService.read(bgmId: bgmId, title: _primary);
    if (memory == null) return false;

    final data = <String, dynamic>{
      'title': memory.title?.isNotEmpty == true ? memory.title : _primary,
      'seriesId': memory.seriesId,
      'source': memory.source,
      'sourceDisplayName': memory.sourceDisplayName ?? memory.source,
    };
    final item = SearchResultItem(
      title: data['title']?.toString() ?? _primary,
      sourceType: memory.source,
      data: _mergeSeed(data),
    );

    try {
      final probe = await ensureCandidatePlayable(
        item,
        episodeIndex: _ep,
        preferredLine: 1,
        probeDirect: true,
      ).timeout(_Policy.memoryProbeTimeout);
      if (!_alive(runId) || _autoMatched || _userSelected) return true;
      if (probe.status == SourceProbeStatus.direct && probe.data != null) {
        _autoMatched = true;
        onMatchFound?.call(Map<String, dynamic>.from(probe.data!));
        unawaited(_remember(item, probe.data!));
        return true;
      }
    } catch (_) {}

    try {
      await MatchMemoryService.remove(bgmId: bgmId, title: _primary);
    } catch (_) {}
    return false;
  }

  Future<void> persistMatchMemory(
    SearchResultItem item,
    Map<String, dynamic> data,
  ) => _remember(item, data);

  Future<void> _remember(SearchResultItem item, Map<String, dynamic> data) {
    return MatchMemoryService.writeSuccess(
      bgmId: BgmUtils.toInt(seedData?['bgmId'] ?? data['bgmId']),
      title: _primary,
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

  // ── switch / probe ──

  List<DirectSourceGroup> getDirectSourceGroups({
    required int episodeIndex,
    required int preferredLine,
    String? currentSource,
  }) {
    final cache = _scoreCache.putIfAbsent(
      currentSource ?? '',
      () => <String, int>{},
    );
    SourceMatchContext? ctx;
    int scoreOf(SearchResultItem item) => cache.putIfAbsent(
      item.key,
      () => _engine
          .score(
            item.matchCandidate,
            ctx ??= _baseContext(currentSource: currentSource),
          )
          .score,
    );

    final scored =
        [
          for (final item in _results.values)
            SourceCandidateState(
              item: item,
              score: scoreOf(item),
              probe: _probeFor(item, episodeIndex, preferredLine),
            ),
        ]..sort((a, b) {
          final byStatus = _statusRank(
            a.status,
          ).compareTo(_statusRank(b.status));
          return byStatus != 0 ? byStatus : b.score.compareTo(a.score);
        });
    final grouped = <String, List<SourceCandidateState>>{};
    for (final c in scored) {
      final key = c.probe.routeKey ?? 'candidate:${c.item.key}';
      (grouped[key] ??= []).add(c);
    }
    return [
      for (final e in grouped.entries)
        DirectSourceGroup(
          key: e.key,
          origins: e.value,
          status: e.value.first.status,
        ),
    ];
  }

  void startSwitchProbes(Iterable<SourceCandidateState> candidates) {
    var active = 0;
    for (final c in candidates) {
      if (c.status == SourceProbeStatus.resolving) {
        if (++active >= _Policy.switchProbeLimit) return;
      } else if (c.status == SourceProbeStatus.pending) {
        unawaited(
          ensureCandidatePlayable(
            c.item,
            episodeIndex: c.probe.episodeIndex,
            preferredLine: c.probe.preferredLine,
          ),
        );
        if (++active >= _Policy.switchProbeLimit) return;
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

  int _statusRank(SourceProbeStatus s) => switch (s) {
    SourceProbeStatus.direct => 0,
    SourceProbeStatus.playable => 1,
    SourceProbeStatus.resolving => 2,
    SourceProbeStatus.pending => 3,
    SourceProbeStatus.failed => 4,
  };

  Future<SourceProbeState> ensureCandidatePlayable(
    SearchResultItem item, {
    required int episodeIndex,
    required int preferredLine,
    bool probeDirect = true,
  }) {
    final probe = _probeFor(item, episodeIndex, preferredLine);
    if (probe.isReady) return Future.value(probe);
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
    return _probes.putIfAbsent(
      key,
      () => SourceProbeState(
        item: item,
        episodeIndex: episodeIndex,
        preferredLine: preferredLine,
      ),
    );
  }

  String _probeKey(SearchResultItem item, int ep, int line) =>
      '${item.key}|$ep|$line';

  Future<SourceProbeState> _resolveProbe(
    SourceProbeState probe, {
    required bool probeDirect,
  }) async {
    probe
      ..status = SourceProbeStatus.resolving
      ..error = null;
    _bump();

    try {
      final data = await resolveVideoData(
        probe.item,
      ).timeout(_Policy.resolveTimeout);

      if (PlaybackEpisodeCatalog.countFrom(data) == 0) {
        probe
          ..status = SourceProbeStatus.failed
          ..error = '没有可播放剧集';
        return probe;
      }

      if (_lineCountFor(data, probe.episodeIndex) <= 0) {
        probe
          ..status = SourceProbeStatus.failed
          ..error = '当前集没有可用线路';
        return probe;
      }

      probe.data = data;

      final source = data['source']?.toString();
      if (!probeDirect ||
          source == null ||
          source.isEmpty ||
          source == 'internal') {
        probe.status = SourceProbeStatus.playable;
        return probe;
      }

      final direct = await _probeDirect(data, probe);
      if (direct == null) {
        probe.status = SourceProbeStatus.playable;
      } else {
        probe
          ..status = SourceProbeStatus.direct
          ..routeKey = 'direct:${_canonicalUrl(direct.url)}'
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
      _bump();
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
  _probeDirect(Map<String, dynamic> data, SourceProbeState probe) async {
    final adapter = _adapterFor(data);
    if (adapter == null) return null;

    final total = PlaybackEpisodeCatalog.countFrom(data);
    if (total == 0) return null;

    final ep = probe.episodeIndex.clamp(0, total - 1).toInt();
    final episode = PlaybackEpisodeCatalog.episodeAt(data, ep);
    final lineCount = episode?.lineCount ?? 0;
    if (lineCount <= 0) return null;

    final preferred = probe.preferredLine.clamp(1, lineCount).toInt();
    final order = <int>[
      preferred,
      for (var i = 1; i <= lineCount; i++)
        if (i != preferred) i,
    ];

    for (final line in order.take(2)) {
      final episodeId = episode!.lineAt(line);
      if (episodeId == null || episodeId.isEmpty) continue;
      final media = await _resolveDirect(adapter, episodeId);
      if (media != null) {
        return (
          url: media.url,
          episodeId: episodeId,
          lineIndex: line,
          httpHeaders: media.httpHeaders,
        );
      }
    }
    return null;
  }

  Future<({String url, Map<String, String> httpHeaders})?> _resolveDirect(
    AdapterBase adapter,
    String episodeId,
  ) async {
    try {
      final media = await adapter
          .resolvePlaybackMedia(
            episodeId,
            skipValidation: !adapter.validateAutoMatchedUrls,
          )
          .timeout(
            _Policy.directProbeTimeout,
            onTimeout: () => (url: '', httpHeaders: const <String, String>{}),
          );
      return VideoUrlExtractor.isVideoUrl(media.url) ? media : null;
    } catch (_) {
      return null;
    }
  }

  AdapterBase? _adapterFor(Map<String, dynamic> data) {
    final source = data['source']?.toString();
    if (source == null || source.isEmpty) return null;

    if (AdapterRegistry.isCustomSource(source)) {
      final raw = data['sourceConfig'];
      CustomSourceConfig? config;
      if (raw is CustomSourceConfig) {
        config = raw;
      } else {
        final id = source.substring(AdapterRegistry.customSourcePrefix.length);
        config = SourceCatalog.instance.customSourceById(id);
      }
      return config == null ? null : _adapter.getCustomAdapter(config);
    }
    return _adapter.getBuiltinAdapter(source);
  }

  /// 请求集数对应的可用线路数
  int _lineCountFor(Map<String, dynamic> data, int requestedEp) {
    final total = PlaybackEpisodeCatalog.countFrom(data);
    if (total == 0) return 0;
    final ep = requestedEp.clamp(0, total - 1).toInt();
    return PlaybackEpisodeCatalog.episodeAt(data, ep)?.lineCount ?? 0;
  }

  String _canonicalUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) return value;
    final query = uri.queryParametersAll.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return uri
        .replace(
          scheme: uri.scheme.toLowerCase(),
          host: uri.host.toLowerCase(),
          fragment: '',
          queryParameters: {for (final e in query) e.key: e.value},
        )
        .toString();
  }

  void _bump() {
    if (!_disposed) {
      candidateRevisionNotifier.value++;
    }
  }

  // ── resolve video data ──

  Future<Map<String, dynamic>> resolveVideoData(SearchResultItem item) async {
    final key = item.key;
    final cached = _resolvedCache[key];
    if (cached != null) return Map<String, dynamic>.from(cached);

    final running = _resolveFutures[key];
    if (running != null) {
      return running.then((d) => Map<String, dynamic>.from(d));
    }

    final runId = _runId;
    final future = _resolveUncached(item).then((data) {
      if (!_disposed && runId == _runId) {
        _resolvedCache[key] = Map<String, dynamic>.from(data);
      }
      return data;
    });
    _resolveFutures[key] = future;
    try {
      return Map<String, dynamic>.from(await future);
    } finally {
      if (identical(_resolveFutures[key], future)) {
        _resolveFutures.remove(key);
      }
    }
  }

  Future<Map<String, dynamic>> _resolveUncached(SearchResultItem item) async {
    final itemData = _mergeSeed(Map<String, dynamic>.from(item.data));
    if (item.sourceType == 'internal') return itemData;
    final resolved = await _adapter.buildPlayerData(itemData);
    return _mergeSeed(resolved ?? itemData);
  }

  Map<String, dynamic> _mergeSeed(Map<String, dynamic> data) {
    final seed = seedData;
    if (seed == null || seed.isEmpty) return data;

    final bgmId = BgmUtils.toInt(seed['bgmId']);
    if (bgmId != null && bgmId > 0) data['bgmId'] = bgmId;
    if (seed['score'] != null) data['score'] = seed['score'];
    if (seed['bgmDetailData'] != null) {
      data['bgmDetailData'] = seed['bgmDetailData'];
    }
    final img = seed['bgmImageUrl']?.toString().trim();
    if (img != null && img.isNotEmpty) {
      data['bgmImageUrl'] = seed['bgmImageUrl'];
    }
    return data;
  }
}
