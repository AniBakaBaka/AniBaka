import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/api/post.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/services/settings_service.dart';
import 'package:baka/services/matching/auto_match_strategy.dart';
import 'package:baka/services/matching/match_memory_service.dart';
import 'package:baka/services/matching/media_readiness.dart';
import 'package:baka/services/matching/source_match_engine.dart';
import 'package:baka/services/player_service.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/reg_utils.dart';

final _reAliasSep = RegExp(r'[/／、,，;；\n]');
final _reBrackets = RegExp(r'[（(].*?[）)]');

String _norm(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), '');

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

/// 探针状态：
/// - [direct]：目标集媒体已解析并可即点即播（含预取直链 + headers）
/// - [playable]：剧集目录就绪，但媒体地址尚未解析（点选时仍会再取直链）
/// - [failed]：目录或媒体解析失败
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
  String? mediaUrl;
  Future<SourceProbeState>? future;

  SourceProbeState({
    required this.item,
    required this.episodeIndex,
    required this.preferredLine,
  });

  /// 目录就绪即可选；[direct] 额外保证已预取可播媒体。
  bool get isReady =>
      status == SourceProbeStatus.playable ||
      status == SourceProbeStatus.direct;

  /// 已具备即点即播条件。
  bool get isInstantPlayable => status == SourceProbeStatus.direct;
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
  bool get isInstantPlayable => probe.isInstantPlayable;
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
  bool get isInstantPlayable => primary.isInstantPlayable;
}

/// 视频源搜索与切换逻辑控制器
class VideoSourceSearchController extends ChangeNotifier {
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

  /// The global slot only transfers a completed search from detail to player.
  /// Once consumed, the player owns and disposes the controller.
  static VideoSourceSearchController takeSharedFor({
    Map<String, dynamic>? seedData,
    String? title,
  }) {
    return takeCachedFor(seedData: seedData, title: title) ??
        VideoSourceSearchController(
          seedData: seedData,
          title: resolveTitle(title: title, seedData: seedData),
        );
  }

  static VideoSourceSearchController? takeCachedFor({
    Map<String, dynamic>? seedData,
    String? title,
  }) {
    final resolved = resolveTitle(title: title, seedData: seedData);
    final cached = globalCached;
    if (cached != null && globalCachedTitle == resolved) {
      globalCached = null;
      globalCachedTitle = null;
      return cached;
    }
    cached?.dispose();
    globalCached = null;
    globalCachedTitle = null;
    return null;
  }

  static String resolveTitle({String? title, Map<String, dynamic>? seedData}) {
    final explicit = title?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return seedData?['title']?.toString().trim() ?? '';
  }

  final String title;
  final Map<String, dynamic>? seedData;
  final bool autoMatchMode;
  final int targetEpisodeIndex;
  final ValueChanged<Map<String, dynamic>>? onMatchFound;
  final VoidCallback? onMatchFailed;

  bool isSearching = false;
  List<String> manualAliases = const [];
  late final List<String> automaticAliases;
  final Set<String> activeAutoAliases = {};

  Iterable<SearchResultItem> get results => _results.values;
  Set<String> get progressingSources => _progressing;
  Set<String> get finishedSources => _finished;
  List<String> get searchErrors => _errors;

  final _adapter = SourceAdapterService.instance;
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
  final _probeQueue = <_ProbeJob>[];
  Future<void>? _probePumpFuture;
  DateTime? _autoMatchStartedAt;
  Completer<bool>? _autoMatchGate;

  /// 最近一次自动匹配耗时（认领或失败），供调试/对比。
  Duration? lastAutoMatchDuration;

  /// 目录解析超时（getSources / buildPlayerData）— 竞速档。
  static const Duration _catalogTimeout = Duration(milliseconds: 2400);

  /// 单条线路：解析直链 + 可达性校验 — 竞速档（快失败）。
  static const Duration _mediaTimeout = Duration(milliseconds: 3000);

  /// 单候选总预算：与手动点选「一次 prepare」同级。
  static const Duration _candidateBudget = AutoMatchStrategy.candidateBudget;

  /// 手动点选时稍放宽。
  static const Duration _manualMediaTimeout = Duration(milliseconds: 5500);

  /// 记忆命中总超时。
  static const Duration _memoryTimeout = Duration(milliseconds: 4500);

  /// 自动匹配整轮墙钟上限。
  static const Duration _autoMatchWallClock = AutoMatchStrategy.wallClock;

  /// 自动匹配并发：同时按「手动点选」路径处理的候选数。
  static const int _autoProbeConcurrency = AutoMatchStrategy.raceConcurrency;

  /// 自动匹配每候选最多线路。
  static const int _autoMatchMaxLines = AutoMatchStrategy.maxLinesPerCandidate;

  /// 手动点选最多尝试线路。
  static const int _manualMaxLines = 4;

  /// 可达性探测超时。
  static const Duration _reachTimeout = Duration(milliseconds: 1500);

  late final String _primary;
  late final String _aliasKey;
  int _runId = 0;
  bool _disposed = false;
  bool _userSelected = false;
  bool _autoMatched = false;

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
    manualAliases = _readManualAliases();
    automaticAliases = _buildAutoAliases();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _runId++;
    super.dispose();
  }

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
    final raw = AliasStorageService.readAliases(
      _aliasKey,
      fallbackKey: 'title:${_norm(title)}',
    );
    final seen = {_norm(_primary)};
    return [
      for (final item in raw)
        if (item.trim() case final String a
            when a.isNotEmpty && seen.add(_norm(a)))
          a,
    ];
  }

  Future<void> toggleAutoAlias(String alias) async {
    if (isSearching) return;
    if (!activeAutoAliases.remove(alias)) {
      activeAutoAliases.add(alias);
    }
    notifyListeners();
    await startSearch();
  }

  Future<bool> addManualAlias(String value) async {
    if (isSearching) return false;
    final next = List<String>.of(manualAliases);
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
    manualAliases = next;
    notifyListeners();
    await AliasStorageService.saveAliases(_aliasKey, next);
    await startSearch();
    return true;
  }

  Future<void> removeManualAlias(String alias) async {
    if (isSearching) return;
    manualAliases = manualAliases
        .where((a) => _norm(a) != _norm(alias))
        .toList();
    notifyListeners();
    await AliasStorageService.saveAliases(_aliasKey, manualAliases);
    await startSearch();
  }

  Future<void> startSearch() async {
    final runId = ++_runId;
    _autoMatched = false;
    lastAutoMatchDuration = null;
    _autoMatchStartedAt = autoMatchMode ? DateTime.now() : null;
    _autoMatchGate = autoMatchMode ? Completer<bool>() : null;
    _resetState();
    isSearching = true;
    _emitProgress();

    await ensureAdapterReady();
    if (!_alive(runId)) return;

    final memoryFuture = autoMatchMode ? _tryMemory(runId) : null;
    final quick = SourceCatalog.instance.quickSearchSources;
    final custom = SourceCatalog.instance.enabledCustomSources;

    // 自动匹配：只搜主标题（与用户手动输入一致）；手动模式再带别名。
    final keywords = autoMatchMode
        ? <String>[_primary]
        : <String>[
            _primary,
            ...manualAliases.take(3),
            ...automaticAliases.where(activeAutoAliases.contains).take(3),
          ];

    // 自动匹配跳过站内源：站内需二次 play API，拖慢 first-ready。
    _progressing
      ..clear()
      ..addAll([
        if (!autoMatchMode) 'internal',
        ...quick.map((s) => s.key),
        ...custom.map((s) => AdapterRegistry.customSourceKey(s.id)),
      ]);

    final tasks = [
      if (!autoMatchMode)
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
          load: (kw) => _adapter.search(s.key, kw, skipBgmEnhancement: true),
          errorMsg: '${s.displayName} 搜索失败',
        ),
      for (final s in custom)
        () => _searchSource(
          runId: runId,
          keywords: keywords,
          sourceKey: AdapterRegistry.customSourceKey(s.id),
          load: (kw) => _adapter.search(
            AdapterRegistry.customSourceKey(s.id),
            kw,
            skipBgmEnhancement: true,
          ),
          errorMsg: '${s.name} 搜索失败',
        ),
    ];

    // 自动匹配更高搜索并发，尽快产出首条高置信结果。
    final searchFuture = _runPool(
      tasks,
      autoMatchMode ? 10 : 8,
      shouldStop: () => _autoMatched || !_alive(runId),
    );

    if (memoryFuture != null && await memoryFuture) {
      // 记忆命中：立刻结束，后台搜索可被 cancel。
      unawaited(searchFuture);
      _completeAutoMatchGate(true);
      if (!_disposed) {
        isSearching = false;
        _emitProgress();
      }
      return;
    }

    if (autoMatchMode) {
      // 认领成功 / 全搜+final 结束 / 墙钟：不傻等慢源拖满。
      unawaited(
        _finishSearch(runId, searchFuture).whenComplete(() {
          _completeAutoMatchGate(_autoMatched);
        }),
      );
      try {
        await _autoMatchGate!.future.timeout(_autoMatchWallClock);
      } on TimeoutException {
        // 墙钟到仍未认领：作废本轮，避免迟到的 onMatchFound 与 failed 双回调。
        if (!_autoMatched) {
          _runId++;
          _probeQueue.clear();
        }
      }
      if (!_autoMatched && !_userSelected) {
        _recordAutoMatchDuration();
        onMatchFailed?.call();
      }
      if (!_disposed) {
        isSearching = false;
        _emitProgress();
      }
      return;
    }

    await _finishSearch(runId, searchFuture);
  }

  void _completeAutoMatchGate(bool matched) {
    final gate = _autoMatchGate;
    if (gate != null && !gate.isCompleted) {
      gate.complete(matched);
    }
  }

  void _recordAutoMatchDuration() {
    final started = _autoMatchStartedAt;
    if (started == null) return;
    lastAutoMatchDuration = DateTime.now().difference(started);
    if (kDebugMode) {
      debugPrint(
        '[AutoMatch] done matched=$_autoMatched '
        'in ${lastAutoMatchDuration!.inMilliseconds}ms',
      );
    }
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
      // 记忆命中必须完整解析到可播媒体，避免「匹配成功却播不了」。
      final probe = await ensureCandidatePlayable(
        item,
        episodeIndex: _ep,
        preferredLine: 1,
        resolveMedia: true,
        raceMode: true,
      ).timeout(_memoryTimeout);
      if (!_alive(runId) || _autoMatched || _userSelected) return true;
      if (probe.isInstantPlayable && probe.data != null) {
        return _claimAutoMatch(runId, item, probe.data!);
      }
    } catch (_) {}

    try {
      await MatchMemoryService.remove(bgmId: bgmId, title: _primary);
    } catch (_) {}
    return false;
  }

  /// 原子认领自动匹配结果；成功后停止后续搜索/探针。
  bool _claimAutoMatch(
    int runId,
    SearchResultItem item,
    Map<String, dynamic> data,
  ) {
    if (!_alive(runId) || _autoMatched || _userSelected) return false;
    _autoMatched = true;
    _probeQueue.clear();
    _recordAutoMatchDuration();
    onMatchFound?.call(data);
    unawaited(persistMatchMemory(item, data));
    _completeAutoMatchGate(true);
    return true;
  }

  Future<void> _finishSearch(int runId, Future<void> searchFuture) async {
    await searchFuture;
    if (!_alive(runId)) return;

    if (autoMatchMode && !_userSelected && !_autoMatched) {
      await _runAutoMatch(runId, finalPass: true);
    }
    if (!_alive(runId)) return;

    if (!_disposed && !autoMatchMode) {
      isSearching = false;
      _emitProgress();
    }
    // autoMatch 的失败回调由 startSearch 的 gate 统一处理，避免重复。
    if (!autoMatchMode) return;
    _completeAutoMatchGate(_autoMatched);
  }

  void cancelSearch() {
    _runId++;
    if (!_disposed) {
      isSearching = false;
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
    _probeQueue.clear();
    _results.clear();
    _sourceCounts.clear();
    _errors.clear();
    _finished.clear();
    _progressing.clear();
  }

  void _emitProgress() {
    if (!_disposed) notifyListeners();
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

    List<SearchResultItem> parseRaw(List<Map<String, dynamic>> raw, String kw) {
      final seen = <String>{};
      final items = <SearchResultItem>[];
      for (final r in raw) {
        final data = r..['_searchKeyword'] = kw;
        final item = SearchResultItem(
          title: data['title']?.toString() ?? '',
          sourceType: sourceKey,
          data: data,
        );
        if (seen.add(item.key)) items.add(item);
      }
      return items;
    }

    // 关键词策略：
    // - 自动匹配：只主标题（1 个），尽快出结果
    // - 手动：竞速前 2 个关键词（first non-empty wins），不再 Future.wait 等最慢那个
    final raceKws = keywords
        .take(
          autoMatchMode
              ? AutoMatchStrategy.keywordsPerSourceAuto
              : AutoMatchStrategy.keywordsPerSourceManual,
        )
        .toList();
    final extraKeywords = autoMatchMode
        ? const <String>[]
        : keywords.skip(AutoMatchStrategy.keywordsPerSourceManual).toList();

    if (raceKws.isNotEmpty) {
      attempted += raceKws.length;
      final hit = await _raceKeywords(raceKws, tryKeyword, runId);
      if (!_alive(runId) || _autoMatched) return;
      if (hit == null) {
        failed += raceKws.length;
      } else {
        final items = parseRaw(hit.raw, hit.keyword);
        if (items.isNotEmpty) {
          found = true;
          _appendResults(runId, items);
        } else {
          failed++;
        }
      }
    }

    if (!found && !_autoMatched && _alive(runId) && extraKeywords.isNotEmpty) {
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

  /// 多关键词竞速：谁先返回非空列表谁赢（对齐 first-ready）。
  Future<({String keyword, List<Map<String, dynamic>> raw})?> _raceKeywords(
    List<String> keywords,
    Future<List<Map<String, dynamic>>?> Function(String) load,
    int runId,
  ) async {
    if (keywords.length == 1) {
      final raw = await load(keywords.first);
      if (raw == null || raw.isEmpty) return null;
      return (keyword: keywords.first, raw: raw);
    }

    final done =
        Completer<({String keyword, List<Map<String, dynamic>> raw})?>();
    var remaining = keywords.length;

    for (final kw in keywords) {
      unawaited(() async {
        final raw = await load(kw);
        if (!_alive(runId) || _autoMatched) {
          if (!done.isCompleted) done.complete(null);
          return;
        }
        if (raw != null && raw.isNotEmpty) {
          if (!done.isCompleted) {
            done.complete((keyword: kw, raw: raw));
          }
          return;
        }
        remaining--;
        if (remaining <= 0 && !done.isCompleted) {
          done.complete(null);
        }
      }());
    }

    return done.future;
  }

  Future<List<Map<String, dynamic>>> _loadInternal(String keyword) async {
    final response = await getSearch(keyword);
    final raw = (jsonDecode(response) as Map<String, dynamic>)['data'] as List;
    return [
      for (final item in raw)
        if (item is Map && item['videos'] != null) item as Map<String, dynamic>,
    ];
  }

  void _appendResults(int runId, List<SearchResultItem> items) {
    if (!_alive(runId)) return;
    final context = _syncContext();
    var accepted = 0;
    final freshHigh = <SearchResultItem>[];

    for (final item in items) {
      if (_results.containsKey(item.key) || _results.length >= 100) break;
      final count = _sourceCounts[item.sourceType] ?? 0;
      if (count >= 20) continue;

      if (item.sourceType != 'internal') {
        final score = _rankCache[item.key] ??= _engine.score(
          item.matchCandidate,
          context,
        );
        if (score.confidence < 0.18) continue;
        if (score.shouldProbeImmediately) {
          freshHigh.add(item);
        }
      }

      _results[item.key] = item;
      _sourceCounts[item.sourceType] = count + 1;
      accepted++;
    }
    if (accepted == 0) return;

    if (!_disposed) notifyListeners();

    if (autoMatchMode && !_userSelected && !_autoMatched) {
      // first-ready：每条高置信立刻按「手动 prepare」路径开探，不批处理等待。
      // 按置信度排序后插队，最优结果优先占 worker。
      freshHigh.sort((a, b) {
        final sa = _rankCache[a.key]?.confidence ?? 0;
        final sb = _rankCache[b.key]?.confidence ?? 0;
        return sb.compareTo(sa);
      });
      for (final item in freshHigh) {
        final score = _rankCache[item.key]!;
        _enqueueAutoProbe(runId, item, priority: score.isHighConfidenceTitle);
      }
    } else if (!autoMatchMode) {
      // 手动搜索：后台预解析前几名，点选时尽量零等待。
      _prefetchTopCandidates(limit: 2);
    }
  }

  void _prefetchTopCandidates({int limit = 2}) {
    final context = _syncContext();
    final ranked = [
      for (final item in _results.values)
        if (item.sourceType != 'internal')
          _rankCache[item.key] ??= _engine.score(item.matchCandidate, context),
    ]..sort(SourceMatchEngine.compareScores);

    var n = 0;
    for (final s in ranked) {
      if (n >= limit) break;
      if (!s.shouldProbeImmediately) continue;
      final item = _results[s.candidate.key];
      if (item == null) continue;
      unawaited(
        ensureCandidatePlayable(
          item,
          episodeIndex: _ep,
          preferredLine: 1,
          resolveMedia: true,
        ),
      );
      n++;
    }
  }

  void _finishSource(int runId, String sourceKey, {String? error}) {
    if (!_alive(runId)) return;
    if (error != null) _errors.add(error);
    _progressing.remove(sourceKey);
    _finished.add(sourceKey);
    _emitProgress();
  }

  void _enqueueAutoProbe(
    int runId,
    SearchResultItem item, {
    bool priority = false,
  }) {
    if (!_alive(runId) || _autoMatched || _userSelected) return;
    if (item.sourceType == 'internal') return;
    if (_autoMatchTimedOut) return;
    final key = '${item.key}|$_ep|1';
    if (_triedProbes.contains(key)) return;
    // 队列去重
    for (final job in _probeQueue) {
      if (job.item.key == item.key) return;
    }
    final job = _ProbeJob(runId: runId, item: item);
    if (priority) {
      _probeQueue.insert(0, job);
    } else {
      _probeQueue.add(job);
    }
    _ensureProbePump();
  }

  bool get _autoMatchTimedOut {
    final started = _autoMatchStartedAt;
    if (started == null) return false;
    return DateTime.now().difference(started) >= _autoMatchWallClock;
  }

  void _ensureProbePump() {
    if (_probePumpFuture != null) return;
    _probePumpFuture =
        Future.wait([
          for (var i = 0; i < _autoProbeConcurrency; i++) _autoProbeWorker(),
        ]).whenComplete(() {
          _probePumpFuture = null;
          if (_probeQueue.isNotEmpty &&
              !_autoMatched &&
              !_disposed &&
              !_autoMatchTimedOut) {
            _ensureProbePump();
          }
        });
  }

  Future<void> _autoProbeWorker() async {
    while (!_disposed && !_autoMatched && !_userSelected) {
      if (_autoMatchTimedOut) {
        _probeQueue.clear();
        return;
      }
      if (_probeQueue.isEmpty) return;
      final job = _probeQueue.removeAt(0);
      if (!_alive(job.runId) || _autoMatched || _userSelected) return;
      final probeKey = '${job.item.key}|$_ep|1';
      if (_triedProbes.contains(probeKey)) continue;
      _triedProbes.add(probeKey);

      try {
        final probe = await ensureCandidatePlayable(
          job.item,
          episodeIndex: _ep,
          preferredLine: 1,
          resolveMedia: true,
          raceMode: true,
        ).timeout(_candidateBudget);
        if (!_alive(job.runId) || _userSelected || _autoMatched) return;
        if (probe.isInstantPlayable && probe.data != null) {
          _claimAutoMatch(job.runId, job.item, probe.data!);
          _probeQueue.clear();
          return;
        }
      } catch (_) {
        // One candidate failing must not cancel the remaining sources.
      }
    }
  }

  Future<void> _runAutoMatch(int runId, {required bool finalPass}) async {
    if (!_alive(runId) || _userSelected || _autoMatched) return;
    if (_autoMatchTimedOut) return;
    final context = _syncContext();

    final ranked = [
      for (final item in _results.values)
        if (item.sourceType != 'internal')
          _rankCache[item.key] ??= _engine.score(item.matchCandidate, context),
    ]..sort(SourceMatchEngine.compareScores);

    // final：每源最多 2 条兜底；中间路径已在 _appendResults 即时入队。
    final perSourceCap = finalPass ? 2 : 1;
    final maxCandidates = finalPass ? 8 : 4;
    final bySource = <String, List<SearchResultItem>>{};
    for (final s in ranked) {
      final pass = finalPass
          ? s.shouldProbeOnFinalPass
          : s.shouldProbeImmediately;
      if (!pass) continue;
      final item = _results[s.candidate.key];
      if (item == null) continue;
      if (_triedProbes.contains('${item.key}|$_ep|1')) continue;
      final list = bySource.putIfAbsent(item.sourceType, () => []);
      if (list.length < perSourceCap) list.add(item);
    }

    final candidates = <SearchResultItem>[];
    for (var round = 0; round < perSourceCap; round++) {
      for (final list in bySource.values) {
        if (round < list.length) {
          candidates.add(list[round]);
          if (candidates.length >= maxCandidates) break;
        }
      }
      if (candidates.length >= maxCandidates) break;
    }

    for (final item in candidates) {
      _enqueueAutoProbe(
        runId,
        item,
        priority: _rankCache[item.key]?.isHighConfidenceTitle ?? false,
      );
    }

    // Await the active worker batch directly; no polling delay.
    while (!_autoMatchTimedOut) {
      if (!_alive(runId) || _autoMatched || _userSelected) return;
      final pump = _probePumpFuture;
      if (pump == null) return;
      await pump;
    }
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
          resolveMedia: true,
          raceMode: true,
        ).timeout(_candidateBudget);
        if (probe.isInstantPlayable && probe.data != null) {
          unawaited(persistMatchMemory(item, probe.data!));
          return probe.data!;
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
      manualAliases: manualAliases,
      automaticAliases: automaticAliases,
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
      } else if (c.status == SourceProbeStatus.pending ||
          (c.status == SourceProbeStatus.playable && !c.isInstantPlayable)) {
        unawaited(
          ensureCandidatePlayable(
            c.item,
            episodeIndex: c.probe.episodeIndex,
            preferredLine: c.probe.preferredLine,
            resolveMedia: true,
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
    if (probe.isInstantPlayable) {
      return Future.value(probe);
    }
    return ensureCandidatePlayable(
      candidate.item,
      episodeIndex: probe.episodeIndex,
      preferredLine: probe.preferredLine,
      resolveMedia: true,
    );
  }

  /// 用户点选条目：完整解析到可播媒体后返回 data，供即点即播。
  Future<Map<String, dynamic>?> prepareForPlayback(
    SearchResultItem item, {
    int? episodeIndex,
    int preferredLine = 1,
  }) async {
    final probe = await ensureCandidatePlayable(
      item,
      episodeIndex: episodeIndex ?? _ep,
      preferredLine: preferredLine,
      resolveMedia: true,
      raceMode: false,
    );
    return probe.isReady ? probe.data : null;
  }

  int _statusRank(SourceProbeStatus s) => switch (s) {
    SourceProbeStatus.direct => 0,
    SourceProbeStatus.playable => 1,
    SourceProbeStatus.resolving => 2,
    SourceProbeStatus.pending => 3,
    SourceProbeStatus.failed => 4,
  };

  /// [resolveMedia]：是否继续把目标集解析成真实播放地址并写入预取。
  /// [raceMode]：自动匹配竞速——更短超时、少扫线、解析失败不重试。
  Future<SourceProbeState> ensureCandidatePlayable(
    SearchResultItem item, {
    required int episodeIndex,
    required int preferredLine,
    bool resolveMedia = true,
    bool raceMode = false,
  }) {
    final wantMedia = resolveMedia;
    final probe = _probeFor(item, episodeIndex, preferredLine);

    // 已有即点即播结果，直接复用。
    if (probe.isInstantPlayable) {
      return Future.value(probe);
    }
    // 只要目录即可，且目录已就绪。
    if (!wantMedia && probe.isReady) {
      return Future.value(probe);
    }
    // 目录已就绪但还差媒体：升级解析，避免重复拉详情。
    if (wantMedia &&
        probe.data != null &&
        probe.status == SourceProbeStatus.playable) {
      return _upgradeProbeToMedia(probe, raceMode: raceMode);
    }

    // 若当前 future 正在跑，挂接；媒体需求在目录完成后升级。
    final running = probe.future;
    if (running != null) {
      if (!wantMedia) return running;
      return running.then((state) {
        if (state.isInstantPlayable ||
            state.status == SourceProbeStatus.failed) {
          return state;
        }
        if (state.data != null) {
          return _upgradeProbeToMedia(state, raceMode: raceMode);
        }
        return state;
      });
    }

    final future = _resolveProbe(
      probe,
      resolveMedia: wantMedia,
      raceMode: raceMode,
    );
    probe.future = future;
    future.whenComplete(() {
      if (identical(probe.future, future)) probe.future = null;
    });
    return future;
  }

  Future<SourceProbeState> _upgradeProbeToMedia(
    SourceProbeState probe, {
    bool raceMode = false,
  }) {
    if (probe.isInstantPlayable || probe.data == null) {
      return Future.value(probe);
    }
    final running = probe.future;
    if (running != null) return running;

    final future = _resolveMediaOntoProbe(probe, raceMode: raceMode);
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
    required bool resolveMedia,
    bool raceMode = false,
  }) async {
    probe.status = SourceProbeStatus.resolving;
    _emitProgress();

    try {
      final catalogTimeout = raceMode
          ? _catalogTimeout
          : const Duration(milliseconds: 4000);
      final videoData = await resolveVideoData(
        probe.item,
      ).timeout(catalogTimeout);
      final rawEpisodes = PlaybackEpisodeCatalog.episodesOf(videoData);

      if (rawEpisodes.isEmpty) {
        probe.status = SourceProbeStatus.failed;
        probe.error = '未找到可播放剧集';
        _emitProgress();
        return probe;
      }

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

      final readyData = videoData
        ..['videoList'] = rawEpisodes
        ..['currPlayIndex'] = epIndex
        ..['currUrl'] = lineIndex;

      probe.data = readyData;
      _resolvedCache[probe.item.key] = readyData;

      if (!resolveMedia) {
        // 仅目录：不冒充已验证直链；点选时再升级解析媒体。
        final token = episodeItem.lineAt(lineIndex);
        probe.routeKey = _routeKeyFor(token);
        probe.status = SourceProbeStatus.playable;
        _emitProgress();
        return probe;
      }

      return _attachMedia(
        probe,
        readyData,
        episodeItem,
        epIndex,
        lineIndex,
        raceMode: raceMode,
      );
    } catch (e) {
      probe.status = SourceProbeStatus.failed;
      probe.error = e.toString();
      _emitProgress();
      return probe;
    }
  }

  Future<SourceProbeState> _resolveMediaOntoProbe(
    SourceProbeState probe, {
    bool raceMode = false,
  }) async {
    final data = probe.data;
    if (data == null) {
      return _resolveProbe(probe, resolveMedia: true, raceMode: raceMode);
    }

    probe.status = SourceProbeStatus.resolving;
    _emitProgress();

    try {
      final rawEpisodes = PlaybackEpisodeCatalog.episodesOf(data);
      if (rawEpisodes.isEmpty) {
        probe.status = SourceProbeStatus.failed;
        probe.error = '未找到可播放剧集';
        _emitProgress();
        return probe;
      }

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

      final readyData = data
        ..['currPlayIndex'] = epIndex
        ..['currUrl'] = lineIndex;

      return _attachMedia(
        probe,
        readyData,
        episodeItem,
        epIndex,
        lineIndex,
        raceMode: raceMode,
      );
    } catch (e) {
      probe.status = SourceProbeStatus.failed;
      probe.error = e.toString();
      _emitProgress();
      return probe;
    }
  }

  /// 解析真实媒体地址；必要时轮换线路。成功则写入预取（episodeId = 线路 token）。
  Future<SourceProbeState> _attachMedia(
    SourceProbeState probe,
    Map<String, dynamic> readyData,
    PlaybackEpisode episodeItem,
    int epIndex,
    int preferredLineIndex, {
    bool raceMode = false,
  }) async {
    final sourceKey = readyData['source']?.toString() ?? probe.item.sourceType;
    final lineCount = episodeItem.lines.length;
    if (lineCount <= 0) {
      probe.status = SourceProbeStatus.failed;
      probe.error = '无线路可播';
      probe.data = readyData;
      _emitProgress();
      return probe;
    }

    // 站内源：目录就绪即可选；若线路已是媒体直链则顺便预取。
    if (sourceKey == 'internal') {
      final lineIndex =
          (preferredLineIndex >= 1 && preferredLineIndex <= lineCount)
          ? preferredLineIndex
          : 1;
      final token = episodeItem.lineAt(lineIndex)?.trim() ?? '';
      readyData['currUrl'] = lineIndex;
      probe.resolvedLineIndex = lineIndex;
      probe.routeKey = _routeKeyFor(token);
      probe.data = readyData;
      if (MediaReadiness.isAcceptablePlaybackUrl(token)) {
        PlayerService.storePrefetchedPlaybackMedia(
          readyData,
          episodeIndex: epIndex,
          lineIndex: lineIndex,
          episodeId: token,
          url: token,
          httpHeaders: const {},
        );
        probe.mediaUrl = token;
        probe.status = SourceProbeStatus.direct;
      } else {
        probe.status = SourceProbeStatus.playable;
      }
      _resolvedCache[probe.item.key] = readyData;
      _emitProgress();
      return probe;
    }

    // 竞速只扫 1~2 线；手动点选可多扫几条。
    final maxLines = raceMode ? _autoMatchMaxLines : _manualMaxLines;
    final lineTimeout = raceMode ? _mediaTimeout : _manualMediaTimeout;
    Object? lastError;
    final preferred = preferredLineIndex >= 1 && preferredLineIndex <= lineCount
        ? preferredLineIndex
        : 1;
    var nextLine = 1;
    for (
      var attempt = 0;
      attempt < maxLines && attempt < lineCount;
      attempt++
    ) {
      final int lineIndex;
      if (attempt == 0) {
        lineIndex = preferred;
      } else {
        while (nextLine == preferred) {
          nextLine++;
        }
        lineIndex = nextLine++;
      }
      // 整候选已超时则立刻放弃剩余线路。
      if (raceMode && _autoMatchTimedOut) break;

      final token = episodeItem.lineAt(lineIndex)?.trim() ?? '';
      if (token.isEmpty) continue;

      try {
        final media = await _resolveLineMedia(
          sourceKey: sourceKey,
          lineToken: token,
          raceMode: raceMode,
        ).timeout(lineTimeout);

        if (!MediaReadiness.isAcceptablePlaybackUrl(media.url)) {
          lastError = '线路 $lineIndex 返回不可播地址';
          continue;
        }

        readyData['currUrl'] = lineIndex;
        probe.resolvedLineIndex = lineIndex;
        probe.routeKey = _routeKeyFor(token);
        probe.mediaUrl = media.url;

        // 关键：episodeId 必须与 PlayerService.currentEpisodeId（线路 token）一致。
        PlayerService.storePrefetchedPlaybackMedia(
          readyData,
          episodeIndex: epIndex,
          lineIndex: lineIndex,
          episodeId: token,
          url: media.url,
          httpHeaders: media.httpHeaders,
        );

        probe.data = readyData;
        probe.status = SourceProbeStatus.direct;
        _resolvedCache[probe.item.key] = readyData;
        _emitProgress();
        return probe;
      } catch (e) {
        lastError = e;
      }
    }

    // 媒体全失败：保留目录供 UI 展示，但不标为 direct，避免误匹配。
    probe.data = readyData;
    probe.status = SourceProbeStatus.failed;
    probe.error = lastError?.toString() ?? '无法解析播放地址';
    _emitProgress();
    return probe;
  }

  Future<({String url, Map<String, String> httpHeaders})> _resolveLineMedia({
    required String sourceKey,
    required String lineToken,
    bool raceMode = false,
  }) async {
    final kind = MediaReadiness.classify(lineToken);
    final adapter = _adapter.adapterFor(sourceKey);
    final reachTimeout = raceMode
        ? _reachTimeout
        : const Duration(milliseconds: 2500);

    if (kind == MediaTokenKind.torrent) {
      return (url: lineToken, httpHeaders: const <String, String>{});
    }

    if (kind == MediaTokenKind.directMedia) {
      final headers = <String, String>{...?adapter?.mediaValidationHeaders}
        ..removeWhere((_, v) => v.isEmpty);
      if (VideoUrlExtractor.isSignedCdnUrl(lineToken)) {
        headers.removeWhere((k, _) => k.toLowerCase() == 'referer');
      }
      // 形态像直链仍要探测可达：baofeng 等空壳 m3u8 必须在此处被挡掉。
      final reachable = adapter == null
          ? true
          : await adapter.isPlaybackUrlReachable(
              lineToken,
              timeout: reachTimeout,
            );
      if (!reachable) {
        return (url: '', httpHeaders: const <String, String>{});
      }
      return (url: lineToken, httpHeaders: headers);
    }

    // 必须校验：不可达则返回空，上层换线/换源，绝不预取死链。
    if (adapter == null) {
      throw StateError('Source adapter is unavailable: $sourceKey');
    }
    return adapter.resolvePlaybackMedia(
      lineToken,
      skipValidation: false,
      maxAttempts: 1,
      reachTimeout: reachTimeout,
    );
  }

  String _routeKeyFor(String? token) {
    final value = token?.trim() ?? '';
    if (value.isEmpty) return 'candidate:empty';
    final kind = MediaReadiness.classify(value);
    return switch (kind) {
      MediaTokenKind.directMedia => 'media:${_norm(value)}',
      MediaTokenKind.torrent => 'bt:${_norm(value)}',
      MediaTokenKind.needsResolve => 'token:${_norm(value)}',
      MediaTokenKind.empty => 'candidate:empty',
    };
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
    final videoData = item.sourceType == 'internal'
        ? item.data
        : await _adapter.buildPlayerData(item.data);
    if (videoData == null) {
      throw StateError(
        'Source returned no playback catalog: ${item.sourceType}',
      );
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

class _ProbeJob {
  const _ProbeJob({required this.runId, required this.item});

  final int runId;
  final SearchResultItem item;
}
