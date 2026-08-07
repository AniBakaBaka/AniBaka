import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/api/post.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/services/alias_storage_service.dart';
import 'package:baka/services/matching/match_memory_service.dart';
import 'package:baka/services/matching/source_match_engine.dart';
import 'package:baka/services/player_service.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/reg_utils.dart';

final _reAliasSep = RegExp(r'[/／、,，;；\n]');
final _reBrackets = RegExp(r'[（(].*?[）)]');

String _norm(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), '');

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

class SearchResultItem {
  SearchResultItem({
    required String title,
    required String sourceType,
    required Map<String, dynamic> data,
  }) : matchCandidate = SourceMatchCandidate(
         key:
             '$sourceType|${data['seriesId'] ?? data['id'] ?? data['url'] ?? data['title'] ?? title}',
         title: title,
         sourceType: sourceType,
         data: data,
       );

  final SourceMatchCandidate matchCandidate;

  String get title => matchCandidate.title;
  String get sourceType => matchCandidate.sourceType;
  Map<String, dynamic> get data => matchCandidate.data;
  String get key => matchCandidate.key;

  late final String coverUrl =
      BgmUtils.resolveCoverImage(matchCandidate.data) ?? '';
  late final String? episodeInfo = switch (matchCandidate.episodeCount) {
    final int count when count > 0 => '约 $count 集',
    _ => null,
  };
  late final String? lineInfo = _lineInfo(matchCandidate.data);
  late final String? updateInfo = _updateInfo(matchCandidate.data);

  static String? _lineInfo(Map data) {
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

  static String? _updateInfo(Map data) {
    final s = data['time']?.toString().trim() ?? '';
    if (s.isEmpty) {
      return null;
    }
    return BgmUtils.formatTimeString(s, '更新时间');
  }
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

/// 视频源搜索与切换逻辑控制器
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

  static String resolveTitle({String? title, Map<String, dynamic>? seedData}) {
    final explicit = title?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return seedData?['title']?.toString().trim() ?? '';
  }

  static VideoSourceSearchController sharedFor({
    Map<String, dynamic>? seedData,
    String? title,
  }) {
    final resolved = resolveTitle(title: title, seedData: seedData);
    if (globalCachedTitle != resolved || globalCached == null) {
      globalCached?.dispose();
      globalCached = VideoSourceSearchController(
        seedData: seedData,
        title: resolved,
      );
      globalCachedTitle = resolved;
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
  final _engine = const SourceMatchEngine();
  Future<void>? _adapterInitFuture;

  Future<void> ensureAdapterReady() => _adapterInitFuture ??= _adapter.init();

  final _results = <String, SearchResultItem>{};
  final _sourceCounts = <String, int>{};
  final _errors = <String>[];
  final _finished = <String>{};
  final _progressing = <String>{};
  final _resolvedCache = <String, Map<String, dynamic>>{};
  final _resolveFutures = <String, Future<Map<String, dynamic>>>{};
  final _probes = <String, SourceProbeState>{};
  final _rankCache = <String, SourceMatchScore>{};
  final _triedProbes = <String>{};

  late final String _primary;
  late final String _aliasKey;
  int _runId = 0;
  bool _disposed = false;
  bool _userSelected = false;
  bool _autoMatched = false;
  Future<void>? _autoMatchFuture;

  void markUserSelected() => _userSelected = true;
  bool get isDisposed => _disposed;
  bool get hasMatched => _autoMatched;

  VideoSourceSearchController({
    this.seedData,
    String? title,
    this.autoMatchMode = false,
    this.targetEpisodeIndex = 0,
    this.onMatchFound,
    this.onMatchFailed,
  }) : title = resolveTitle(title: title, seedData: seedData) {
    _primary = this.title;
    _aliasKey = switch (seedData?['bgmId']?.toString().trim()) {
      final String id when id.isNotEmpty => 'bgm:$id',
      _ => 'title:${_norm(this.title)}',
    };
    manualAliasesNotifier.value = _readManualAliases();
    automaticAliasesNotifier.value = _buildAutoAliases();
  }

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

  // ── 别名 ──
  List<String> _buildAutoAliases() {
    final pool = <String>{_primary};
    final detail = BgmUtils.asMap(seedData?['bgmDetailData']);
    if (detail != null) {
      for (final raw in [detail['name_cn'], detail['name']]) {
        if (raw != null) {
          pool.addAll(
            raw
                .toString()
                .split(_reAliasSep)
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty),
          );
        }
      }
    }
    final out = <String>[];
    final seen = {_norm(_primary)};
    for (final c in pool) {
      final clean = c
          .replaceAll(_reBrackets, '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final base = RegUtils.extractBaseTitle(c);
      for (final candidate in [c, clean, base]) {
        if (candidate.isNotEmpty && seen.add(_norm(candidate))) {
          out.add(candidate);
          if (out.length >= 6) return out;
        }
      }
    }
    return out;
  }

  List<String> _readManualAliases() {
    final store = AliasStorageService.readStore();
    final raw = store[_aliasKey] ?? store['title:${_norm(title)}'];
    if (raw is! List) return const [];
    final seen = {_norm(_primary)};
    return [
      for (final item in raw)
        if (item?.toString().trim() case final String a
            when a.isNotEmpty && seen.add(_norm(a)))
          a,
    ];
  }

  Future<void> toggleAutoAlias(String alias) async {
    if (isSearchingNotifier.value) return;
    final next = Set<String>.of(activeAutoAliasesNotifier.value);
    if (!next.remove(alias)) {
      next.add(alias);
    }
    activeAutoAliasesNotifier.value = next;
    await startSearch();
  }

  Future<bool> addManualAlias(String value) async {
    if (isSearchingNotifier.value) return false;
    final next = List<String>.of(manualAliasesNotifier.value);
    final seen = {_norm(_primary), for (final a in next) _norm(a)};
    var added = false;
    for (final part in value.split(_reAliasSep)) {
      final alias = part.trim();
      if (alias.isNotEmpty && seen.add(_norm(alias))) {
        next.add(alias);
        added = true;
      }
    }
    if (!added) return false;
    manualAliasesNotifier.value = next;
    await AliasStorageService.saveAliases(_aliasKey, next);
    await startSearch();
    return true;
  }

  Future<void> removeManualAlias(String alias) async {
    if (isSearchingNotifier.value) return;
    manualAliasesNotifier.value = manualAliasesNotifier.value
        .where((a) => _norm(a) != _norm(alias))
        .toList();
    await AliasStorageService.saveAliases(
      _aliasKey,
      manualAliasesNotifier.value,
    );
    await startSearch();
  }

  // ── 搜索流程 ──
  Future<void> startSearch() async {
    final runId = ++_runId;
    _autoMatched = false;
    _autoMatchFuture = null;
    _resetState();
    isSearchingNotifier.value = true;
    _emitProgress();

    await ensureAdapterReady();
    if (!_alive(runId)) return;

    final memoryFuture = autoMatchMode ? _tryMemory(runId) : null;
    final quick = SourceCatalog.instance.quickSearchSources;
    final custom = SourceCatalog.instance.enabledCustomSources;
    final keywords = [
      _primary,
      ...manualAliasesNotifier.value.take(3),
      ...automaticAliasesNotifier.value
          .where(activeAutoAliasesNotifier.value.contains)
          .take(3),
    ];

    _progressing
      ..clear()
      ..addAll([
        'internal',
        ...quick.map((s) => s.key),
        ...custom.map((s) => AdapterRegistry.customSourceKey(s.id)),
      ]);

    final tasks = [
      () => _searchSource(
        runId: runId,
        keywords: keywords,
        sourceKey: 'internal',
        load: _loadInternal,
        errorMsg: '站内搜索失败',
      ),
      for (final s in quick)
        () => _searchSource(
          runId: runId,
          keywords: keywords,
          sourceKey: s.key,
          load: (kw) => _adapter.searchBuiltin(kw, s, skipBgmEnhancement: true),
          errorMsg: '${s.displayName} 搜索失败',
        ),
      for (final s in custom)
        () => _searchSource(
          runId: runId,
          keywords: keywords,
          sourceKey: AdapterRegistry.customSourceKey(s.id),
          load: (kw) => _adapter.searchCustom(kw, s, skipBgmEnhancement: true),
          errorMsg: '${s.name} 搜索失败',
        ),
    ];

    final searchFuture = _runPool(
      tasks,
      8,
      shouldStop: () => _autoMatched || !_alive(runId),
    );
    if (memoryFuture != null && await memoryFuture) {
      unawaited(_finishSearch(runId, searchFuture));
      return;
    }
    await _finishSearch(runId, searchFuture);
  }

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
      ).timeout(const Duration(milliseconds: 3500));
      if (!_alive(runId) || _autoMatched || _userSelected) return true;
      if (probe.status == SourceProbeStatus.direct && probe.data != null) {
        _autoMatched = true;
        onMatchFound?.call(Map<String, dynamic>.from(probe.data!));
        unawaited(persistMatchMemory(item, probe.data!));
        return true;
      }
    } catch (_) {}

    try {
      await MatchMemoryService.remove(bgmId: bgmId, title: _primary);
    } catch (_) {}
    return false;
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
    if (n > 0) {
      await Future.wait(List.generate(n, (_) => worker()));
    }
  }

  bool _alive(int runId) => !_disposed && runId == _runId;

  void _resetState() {
    _resolvedCache.clear();
    _resolveFutures.clear();
    _probes.clear();
    _rankCache.clear();
    _triedProbes.clear();
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
    required Future<List<Map<String, dynamic>>> Function(String) load,
    required String errorMsg,
  }) async {
    if (keywords.isEmpty) {
      return _finishSource(runId, sourceKey);
    }
    var attempted = 0;
    var failed = 0;
    var found = false;

    Future<List<Map<String, dynamic>>?> tryKeyword(String kw) async {
      try {
        return await load(kw);
      } catch (_) {
        return null;
      }
    }

    List<SearchResultItem> parseRaw(
      List<Map<String, dynamic>> raw,
      String kw,
    ) {
      final seen = <String>{};
      final items = <SearchResultItem>[];
      for (final r in raw) {
        final data = Map<String, dynamic>.from(r)
          ..['_searchKeyword'] = kw;
        final item = SearchResultItem(
          title: data['title']?.toString() ?? '',
          sourceType: sourceKey,
          data: data,
        );
        if (seen.add(item.key)) items.add(item);
      }
      return items;
    }

    // 核心优化：并行并发发起主标题与首个别名搜索
    final coreKeywords = keywords.take(2).toList();
    final extraKeywords = keywords.skip(2).toList();

    if (coreKeywords.isNotEmpty) {
      attempted += coreKeywords.length;
      final results = await Future.wait(
        coreKeywords.map((kw) => tryKeyword(kw)),
      );
      if (!_alive(runId) || _autoMatched) return;

      for (var i = 0; i < coreKeywords.length; i++) {
        final raw = results[i];
        if (raw == null) {
          failed++;
          continue;
        }
        final items = parseRaw(raw, coreKeywords[i]);
        if (items.isNotEmpty) {
          found = true;
          _appendResults(runId, items);
          break;
        }
      }
    }

    if (!found && !_autoMatched && _alive(runId)) {
      for (final kw in extraKeywords) {
        if (!_alive(runId) || _autoMatched) return;
        if (_results.length >= 8) break;
        attempted++;

        final raw = await tryKeyword(kw);
        if (!_alive(runId) || _autoMatched) return;
        if (raw == null) {
          failed++;
          continue;
        }

        final items = parseRaw(raw, kw);
        if (items.isNotEmpty) {
          found = true;
          _appendResults(runId, items);
          break;
        }
      }
    }

    _finishSource(
      runId,
      sourceKey,
      error: attempted > 0 && failed == attempted && !found ? errorMsg : null,
    );
  }

  Future<List<Map<String, dynamic>>> _loadInternal(String keyword) async {
    final response = await getSearch(keyword);
    final raw = BgmUtils.parseJsonMap(response.data)?['data'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map && item['videos'] != null)
          Map<String, dynamic>.from(item),
    ];
  }

  void _appendResults(int runId, List<SearchResultItem> items) {
    if (!_alive(runId)) return;
    final context = _syncContext();
    var accepted = 0;
    SearchResultItem? topConfidenceItem;

    for (final item in items) {
      if (_results.containsKey(item.key) || _results.length >= 100) break;
      final count = _sourceCounts[item.sourceType] ?? 0;
      if (count >= 20) continue;

      if (item.sourceType != 'internal') {
        final score = _rankCache[item.key] ??= _engine.score(
          item.matchCandidate,
          context,
        );
        if (score.confidence < 0.20) continue;
        if (score.confidence >= 0.80 && topConfidenceItem == null) {
          topConfidenceItem = item;
        }
      }

      _results[item.key] = item;
      _sourceCounts[item.sourceType] = count + 1;
      accepted++;
    }
    if (accepted == 0) return;

    resultsNotifier.value = List.unmodifiable(_results.values);

    if (autoMatchMode && !_userSelected && !_autoMatched) {
      if (topConfidenceItem != null) {
        final highItem = topConfidenceItem;
        unawaited(
          ensureCandidatePlayable(
            highItem,
            episodeIndex: _ep,
            preferredLine: 1,
          ).then((probe) {
            if (_alive(runId) &&
                !_userSelected &&
                !_autoMatched &&
                probe.status == SourceProbeStatus.direct &&
                probe.data != null) {
              _autoMatched = true;
              onMatchFound?.call(Map<String, dynamic>.from(probe.data!));
              unawaited(persistMatchMemory(highItem, probe.data!));
            }
          }),
        );
      }
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

  // ── 自动匹配 ──
  Future<void> _scheduleAutoMatch(int runId) {
    if (!_alive(runId) || _userSelected || _autoMatched) return Future.value();
    return _autoMatchFuture ??= _runAutoMatch(
      runId,
      finalPass: false,
    ).whenComplete(() => _autoMatchFuture = null);
  }

  Future<void> _runAutoMatch(int runId, {required bool finalPass}) async {
    if (!_alive(runId) || _userSelected || _autoMatched) return;
    final context = _syncContext();

    final ranked = [
      for (final item in _results.values)
        if (item.sourceType != 'internal')
          _rankCache[item.key] ??= _engine.score(item.matchCandidate, context),
    ]..sort(SourceMatchEngine.compareScores);

    final bySource = <String, List<SearchResultItem>>{};
    for (final s in ranked) {
      if (finalPass ? s.confidence < 0.70 : !s.shouldProbeImmediately) continue;
      final item = _results[s.candidate.key];
      if (item == null) continue;
      if (_triedProbes.contains('${item.key}|$_ep|1')) continue;
      final list = bySource.putIfAbsent(item.sourceType, () => []);
      if (list.length < 2) list.add(item);
    }

    final candidates = <SearchResultItem>[];
    for (var round = 0; round < 2; round++) {
      for (final list in bySource.values) {
        if (round < list.length) {
          candidates.add(list[round]);
          if (candidates.length >= 4) break;
        }
      }
      if (candidates.length >= 4) break;
    }
    if (candidates.isEmpty) return;

    var next = 0;
    Future<void> worker() async {
      while (next < candidates.length && _alive(runId) && !_autoMatched) {
        if (_userSelected) return;
        final item = candidates[next++];
        _triedProbes.add('${item.key}|$_ep|1');
        final probe = await ensureCandidatePlayable(
          item,
          episodeIndex: _ep,
          preferredLine: 1,
        );
        if (!_alive(runId) || _userSelected || _autoMatched) return;
        if (probe.status == SourceProbeStatus.direct && probe.data != null) {
          _autoMatched = true;
          onMatchFound?.call(Map<String, dynamic>.from(probe.data!));
          unawaited(persistMatchMemory(item, probe.data!));
          return;
        }
      }
    }

    final n = candidates.length < 4 ? candidates.length : 4;
    await Future.wait(List.generate(n, (_) => worker()));
  }

  Future<Map<String, dynamic>?> findNextPlayableCandidate({
    required Set<String> excludedKeys,
    int? episodeIndex,
  }) async {
    final ep = episodeIndex ?? _ep;
    final context = _syncContext();

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
      try {
        final probe = await ensureCandidatePlayable(
          item,
          episodeIndex: ep,
          preferredLine: 1,
        ).timeout(const Duration(milliseconds: 4500));
        if (probe.status == SourceProbeStatus.direct && probe.data != null) {
          unawaited(persistMatchMemory(item, probe.data!));
          return Map<String, dynamic>.from(probe.data!);
        }
      } catch (_) {}
    }
    return null;
  }

  int get _ep => targetEpisodeIndex < 0 ? 0 : targetEpisodeIndex;

  SourceMatchContext _syncContext({String? currentSource}) {
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
      currentSource: currentSource,
    );
  }

  Future<void> persistMatchMemory(
    SearchResultItem item,
    Map<String, dynamic> data,
  ) {
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

  // ── 切换 / 线路探针 ──
  List<DirectSourceGroup> getDirectSourceGroups({
    required int episodeIndex,
    required int preferredLine,
    String? currentSource,
  }) {
    final context = _syncContext(currentSource: currentSource);
    int scoreOf(SearchResultItem item) =>
        (_rankCache[item.key] ??= _engine.score(
          item.matchCandidate,
          context,
        )).score;

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
        if (++active >= 4) return;
      } else if (c.status == SourceProbeStatus.pending) {
        unawaited(
          ensureCandidatePlayable(
            c.item,
            episodeIndex: c.probe.episodeIndex,
            preferredLine: c.probe.preferredLine,
          ),
        );
        if (++active >= 4) {
          return;
        }
      }
    }
  }

  Future<SourceProbeState> resolveSwitchCandidate(
    SourceCandidateState candidate,
  ) {
    final probe = candidate.probe;
    if (probe.isReady) {
      return Future.value(probe);
    }
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
    if (probe.isReady) {
      return Future.value(probe);
    }
    final running = probe.future;
    if (running != null) {
      return running;
    }

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
    final key = '${item.key}|$episodeIndex|$preferredLine';
    return _probes.putIfAbsent(
      key,
      () => SourceProbeState(
        item: item,
        episodeIndex: episodeIndex,
        preferredLine: preferredLine,
      ),
    );
  }

  Future<SourceProbeState> _resolveProbe(
    SourceProbeState probe, {
    bool probeDirect = true,
  }) async {
    probe.status = SourceProbeStatus.resolving;
    candidateRevisionNotifier.value++;

    try {
      final videoData = await resolveVideoData(
        probe.item,
      ).timeout(const Duration(milliseconds: 4500));
      final rawEpisodes = PlaybackEpisodeCatalog.rawEpisodesOf(
        videoData,
      ).map(PlaybackEpisode.parse).whereType<PlaybackEpisode>().toList();

      if (rawEpisodes.isNotEmpty) {
        final epIndex =
            (probe.episodeIndex >= 0 && probe.episodeIndex < rawEpisodes.length)
            ? probe.episodeIndex
            : 0;
        final episodeItem = rawEpisodes[epIndex];
        final totalLines = episodeItem.lines.length;
        final lineIndex =
            (probe.preferredLine >= 1 && probe.preferredLine <= totalLines)
            ? probe.preferredLine
            : 1;
        probe.resolvedLineIndex = lineIndex;

        final episodesData = rawEpisodes.map((e) => e.serialize()).toList();
        final readyData = Map<String, dynamic>.from(videoData)
          ..['videoList'] = episodesData
          ..['episodes'] = episodesData
          ..['currPlayIndex'] = epIndex
          ..['currUrl'] = lineIndex;

        final directUrl = episodeItem.lineAt(lineIndex);
        if (directUrl != null && directUrl.isNotEmpty) {
          probe.routeKey = 'direct:${_norm(directUrl)}';
          if (probeDirect &&
              (directUrl.startsWith('http://') ||
                  directUrl.startsWith('https://'))) {
            PlayerService.storePrefetchedPlaybackMedia(
              readyData,
              episodeIndex: epIndex,
              lineIndex: lineIndex,
              episodeId: episodeItem.title,
              url: directUrl,
              httpHeaders: const {},
            );
            probe.status = SourceProbeStatus.direct;
          } else {
            probe.status = SourceProbeStatus.playable;
          }
        } else {
          probe.status = SourceProbeStatus.playable;
        }

        probe.data = readyData;
        _resolvedCache[probe.item.key] = readyData;
      } else {
        probe.status = SourceProbeStatus.failed;
        probe.error = '未找到可播放剧集';
      }
    } catch (e) {
      probe.status = SourceProbeStatus.failed;
      probe.error = e.toString();
    }

    candidateRevisionNotifier.value++;
    return probe;
  }

  Future<Map<String, dynamic>> resolveVideoData(SearchResultItem item) async {
    final cached = _resolvedCache[item.key];
    if (cached != null) return cached;

    // 零二次请求核心：优先复用自动探针/后台探针中已解析就绪的完整播放数据 (probe.data)
    for (final probe in _probes.values) {
      if (probe.item.key == item.key && probe.isReady && probe.data != null) {
        _resolvedCache[item.key] = probe.data!;
        return probe.data!;
      }
    }

    final existing = _resolveFutures[item.key];
    if (existing != null) return existing;

    final future = _doResolveVideoData(item);
    _resolveFutures[item.key] = future;
    try {
      final data = await future;
      _resolvedCache[item.key] = data;
      return data;
    } finally {
      if (identical(_resolveFutures[item.key], future)) {
        _resolveFutures.remove(item.key);
      }
    }
  }

  Future<Map<String, dynamic>> _doResolveVideoData(
    SearchResultItem item,
  ) async {
    Map<String, dynamic> videoData;
    if (item.sourceType == 'internal') {
      videoData = Map<String, dynamic>.from(item.data);
    } else {
      final built = await _adapter.buildPlayerData(item.data);
      videoData = built != null
          ? Map<String, dynamic>.from(built)
          : Map<String, dynamic>.from(item.data);
    }
    videoData['source'] = item.sourceType;
    videoData['sourceDisplayName'] =
        item.data['sourceDisplayName'] ?? _sourceDisplayName(item.sourceType);
    return _mergeSeed(videoData);
  }

  String _sourceDisplayName(String sourceType) {
    if (sourceType == 'internal') {
      return '站内';
    }
    final descriptor = AdapterRegistry.descriptorFor(sourceType);
    if (descriptor != null) {
      return descriptor.displayName;
    }
    return '自定义源';
  }

  Map<String, dynamic> _mergeSeed(Map<String, dynamic> data) {
    final seed = seedData;
    if (seed == null) {
      return data;
    }

    data.putIfAbsent('title', () => _primary);
    if (seed['bgmId'] != null) {
      data['bgmId'] = seed['bgmId'];
    }
    if (seed['score'] != null) {
      data['score'] = seed['score'];
    }
    if (seed['bgmDetailData'] != null) {
      data['bgmDetailData'] = seed['bgmDetailData'];
    }
    if (seed['bgmImageUrl']?.toString().trim() case final String img
        when img.isNotEmpty) {
      data['bgmImageUrl'] = img;
    }
    return data;
  }
}
