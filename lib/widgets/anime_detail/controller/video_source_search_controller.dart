import 'package:baka/utils/title_matcher.dart';
import 'package:baka/source/models/source_search_result.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/utils/json_values.dart';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/api/request_cache.dart';
import 'package:baka/models/playback_request.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/api/post.dart';
import 'package:baka/services/matching/match_memory_service.dart';
import 'package:baka/services/matching/media_readiness.dart';
import 'package:baka/services/matching/probe_scheduler.dart';
import 'package:baka/services/matching/source_match_engine.dart';
import 'package:baka/services/source/source_repository.dart';

final _reAliasSep = RegExp(r'[/／、,，;；\n]');
final _reBrackets = RegExp(r'[（(].*?[）)]');
final _reWhitespace = RegExp(r'\s+');

String _norm(String value) => value.toLowerCase().replaceAll(_reWhitespace, '');

/// 探针状态：
/// - [direct]：目标集媒体已解析并可即点即播（含预取直链 + headers）
/// - [playable]：剧集目录就绪，但媒体地址尚未解析（点选时仍会再取直链）
/// - [failed]：目录或媒体解析失败
enum SourceProbeStatus { pending, resolving, playable, direct, failed }

class SourceProbeState {
  SourceSearchResult item;
  final int episodeIndex;
  final int preferredLine;
  SourceProbeStatus status = SourceProbeStatus.pending;
  PlaybackRequest? data;
  String? routeKey;
  int? get resolvedLineIndex => data?.lineIndex;
  String? error;
  int score = 0;
  SourceOperation? operation;
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

class DirectSourceGroup {
  const DirectSourceGroup({required this.key, required this.origins});

  final String key;
  final List<SourceProbeState> origins;
  SourceProbeStatus get status => primary.status;

  SourceProbeState get primary => origins.first;
  bool get isReady => primary.isReady;
  bool get isInstantPlayable => primary.isInstantPlayable;
}

/// 视频源搜索与切换逻辑控制器
class VideoSourceSearchController extends ChangeNotifier {
  static VideoSourceSearchController? globalCached;

  static void cacheGlobal(VideoSourceSearchController controller) {
    if (!identical(globalCached, controller)) globalCached?.dispose();
    globalCached = controller;
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
        VideoSourceSearchController(seedData: seedData, title: title);
  }

  static VideoSourceSearchController? takeCachedFor({
    Map<String, dynamic>? seedData,
    String? title,
  }) {
    final cached = globalCached;
    globalCached = null;
    if (cached?.title == resolveTitle(title: title, seedData: seedData)) {
      return cached;
    }
    cached?.dispose();
    return null;
  }

  static String resolveTitle({String? title, Map<String, dynamic>? seedData}) {
    final explicit = title?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return seedData?['title']?.toString().trim() ?? '';
  }

  final String title;
  final Map<String, dynamic>? seedData;
  late final Map<String, dynamic> _seedMetadata = {
    for (final key in const [
      'bgmId',
      'score',
      'bgmDetailData',
      'bgmImageUrl',
      'logoUrl',
    ])
      if (seedData?[key] case final value?) key: value,
  };
  final bool autoMatchMode;
  final int targetEpisodeIndex;
  final ValueChanged<PlaybackRequest>? onMatchFound;
  final VoidCallback? onMatchFailed;

  bool isSearching = false;
  List<String> manualAliases = const [];
  late final List<String> automaticAliases;
  final Set<String> activeAutoAliases = {};

  Iterable<SourceSearchResult> get results => _results.values;
  int resultCountFor(String source) => _sourceCounts[source] ?? 0;
  Set<String> get progressingSources => _progressing;
  Set<String> get finishedSources => _finished;
  List<String> get searchErrors => _errors;

  final _adapter = sourceRepository;
  final _engine = const SourceMatchEngine();
  final _results = <String, SourceSearchResult>{};
  final _sourceCounts = <String, int>{};
  final _errors = <String>[];
  final _finished = <String>{};
  final _progressing = <String>{};

  /// 已解析的完整播放数据（含在途请求去重）；有界 LRU，避免长时间搜索堆积。
  final _resolved = RequestCache<String, PlaybackRequest>(limit: 32);
  final _probes = <String, SourceProbeState>{};
  (int, int)? _probeSelection;
  final _rankCache = <String, SourceMatchScore>{};
  SourceMatchContext? _matchContext;
  (SourceMatchContext, int, int, int, String?)? _switchKey;
  List<SourceProbeState> _switchCandidates = const [];
  List<DirectSourceGroup>? _switchGroups;
  final _autoProbesBySource = <String, int>{};
  int _autoProbesTotal = 0;
  Timer? _deadlineTimer;
  ProbeScheduler<SourceSearchResult>? _probeScheduler;
  DateTime? _autoMatchStartedAt;
  Completer<void>? _autoMatchGate;

  /// 最近一次自动匹配耗时（认领或失败），供调试/对比。
  Duration? lastAutoMatchDuration;

  static const _manualMaxLines = 4;

  late final String _aliasKey;
  int _runId = 0;
  SourceOperation _sourceOperation = SourceOperation();
  bool _disposed = false;
  bool _userSelected = false;
  bool _autoMatched = false;

  void markUserSelected() {
    _userSelected = true;
    if (autoMatchMode && isSearching) cancelSearch();
  }

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
    if (identical(globalCached, this)) {
      globalCached = null;
    }
    _sourceOperation.cancel();
    _sourceOperation.close();
    _runId++;
    _cancelAutoDeadline();
    _probeScheduler?.close();
    _completeAutoMatch();
    // 释放已解析的候选 / 播放数据；控制器在播放器侧仍被引用，但不再需要它们。
    _releaseRetainedData();
    super.dispose();
  }

  /// 清空一次搜索会话的全部派生数据。
  void _releaseRetainedData() {
    _switchKey = null;
    _switchCandidates = const [];
    _switchGroups = null;
    _results.clear();
    _sourceCounts.clear();
    _errors.clear();
    _finished.clear();
    _progressing.clear();
    _resolved.clear();
    for (final probe in _probes.values) {
      probe.operation?.cancel();
    }
    _probes.clear();
    _probeSelection = null;
    _rankCache.clear();
    _matchContext = null;
    _autoProbesBySource.clear();
    _autoProbesTotal = 0;
  }

  List<String> _buildAutoAliases() {
    final pool = <String>{title};
    final detail = seedData?['bgmDetailData'] as Map<String, dynamic>?;
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
    final seen = {_norm(title)};
    for (final c in pool) {
      final clean = c
          .replaceAll(_reBrackets, '')
          .replaceAll(_reWhitespace, ' ')
          .trim();
      final base = extractBaseTitle(c);
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
    final raw = MatchMemoryService.readAliases(
      _aliasKey,
      fallbackKey: 'title:${_norm(title)}',
    );
    final seen = {_norm(title)};
    return [
      for (final item in raw)
        if (item.trim() case final String a
            when a.isNotEmpty && seen.add(_norm(a)))
          a,
    ];
  }

  Future<void> toggleAutoAlias(String alias) async {
    if (_disposed || isSearching) return;
    if (!activeAutoAliases.remove(alias)) {
      activeAutoAliases.add(alias);
    }
    notifyListeners();
    await startSearch();
  }

  Future<bool> addManualAlias(String value) async {
    if (_disposed || isSearching) return false;
    List<String>? next;
    final seen = {_norm(title), for (final a in manualAliases) _norm(a)};
    for (final part in value.split(_reAliasSep)) {
      final alias = part.trim();
      if (alias.isNotEmpty && seen.add(_norm(alias))) {
        (next ??= List.of(manualAliases)).add(alias);
      }
    }
    if (next == null) return false;
    manualAliases = next;
    final runId = _runId;
    notifyListeners();
    await MatchMemoryService.saveAliases(_aliasKey, next);
    if (_alive(runId)) await startSearch();
    return true;
  }

  Future<void> removeManualAlias(String alias) async {
    if (_disposed || isSearching) return;
    final normalized = _norm(alias);
    manualAliases = manualAliases.where((a) => _norm(a) != normalized).toList();
    final runId = _runId;
    notifyListeners();
    await MatchMemoryService.saveAliases(_aliasKey, manualAliases);
    if (_alive(runId)) await startSearch();
  }

  Future<void> startSearch() async {
    if (_disposed) return;
    _cancelAutoDeadline();
    _completeAutoMatch();
    _sourceOperation.cancel();
    _sourceOperation.close();
    _sourceOperation = SourceOperation();
    final runId = ++_runId;
    final operation = _sourceOperation;
    _autoMatched = false;
    lastAutoMatchDuration = null;
    _autoMatchStartedAt = autoMatchMode ? DateTime.now() : null;
    final gate = autoMatchMode ? Completer<void>() : null;
    _autoMatchGate = gate;
    _releaseRetainedData();
    _probeScheduler?.close();
    final scheduler = _probeScheduler = autoMatchMode
        ? ProbeScheduler<SourceSearchResult>(
            concurrency: SourceMatchEngine.raceConcurrency,
            keyOf: (item) => item.key,
            run: (item) => _runAutoProbe(runId, item),
          )
        : null;
    isSearching = true;
    _emitProgress();

    try {
      await operation.wait(_adapter.init());
    } catch (_) {
      if (!_alive(runId) || operation.isCancelled) return;
      _errors.add('搜索初始化失败');
      _stopBackgroundWork();
      _completeAutoMatch();
      isSearching = false;
      _emitProgress();
      if (_alive(runId) && autoMatchMode && !_userSelected) {
        _recordAutoMatchDuration();
        onMatchFailed?.call();
      }
      return;
    }
    if (!_alive(runId)) return;

    final memoryFuture = autoMatchMode ? _tryMemory(runId) : null;
    final sources = [
      for (final source in sourceCatalog.quickSearchSources)
        (key: source.key, error: '${source.displayName} 搜索失败'),
      for (final source in sourceCatalog.enabledCustomSources)
        (
          key: AdapterRegistry.customSourceKey(source.id),
          error: '${source.name} 搜索失败',
        ),
      // 站内源只用于手动列表，不参与自动匹配。
      if (!autoMatchMode) (key: 'internal', error: '站内搜索失败'),
    ];

    // 自动匹配只搜主标题：最快的路径，别名回退已移除。
    final keywords = autoMatchMode
        ? <String>[title]
        : <String>[
            title,
            ...manualAliases.take(3),
            ...automaticAliases.where(activeAutoAliases.contains).take(3),
          ];

    _progressing.addAll(sources.map((source) => source.key));

    var nextSource = 0;
    final concurrency = autoMatchMode
        ? SourceMatchEngine.autoSearchConcurrency
        : 8;
    final searchFuture = Future.wait(
      List.generate(sources.length.clamp(0, concurrency), (_) async {
        while (nextSource < sources.length && !operation.isCancelled) {
          final source = sources[nextSource++];
          await _searchSource(
            runId: runId,
            operation: operation,
            keywords: keywords,
            sourceKey: source.key,
            errorMsg: source.error,
          );
        }
      }),
    );

    if (!autoMatchMode) {
      await searchFuture;
      if (!_alive(runId)) return;
      isSearching = false;
      _emitProgress();
      return;
    }

    _startAutoDeadline(runId);
    unawaited(
      _driveAutoMatch(
        runId,
        operation,
        searchFuture,
        memoryFuture,
        scheduler!,
      ).catchError((Object error, StackTrace _) {
        if (kDebugMode) debugPrint('[AutoMatch] aborted: $error');
        if (_alive(runId)) {
          _stopBackgroundWork();
          _completeAutoMatch();
        }
      }),
    );

    // gate 必在「认领 / 全源结束 / 硬截止」三者之一完成，不再傻等慢源。
    await gate!.future;
    if (!_alive(runId)) return;
    isSearching = false;
    _emitProgress();
    if (_alive(runId) && !_autoMatched && !_userSelected) {
      _recordAutoMatchDuration();
      onMatchFailed?.call();
    }
  }

  void _startAutoDeadline(int runId) {
    _cancelAutoDeadline();
    // 硬截止：停止后续探针并给出结论。这是自动匹配唯一的兜底计时器，
    // 结果一到就探（first-ready）之外不再有任何补探轮次。
    _deadlineTimer = Timer(SourceMatchEngine.hardDeadline, () {
      if (!_alive(runId)) return;
      _stopBackgroundWork();
      _completeAutoMatch();
    });
  }

  bool get _autoMatchSettled {
    final gate = _autoMatchGate;
    return gate != null && gate.isCompleted;
  }

  void _cancelAutoDeadline() {
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
  }

  Future<void> _driveAutoMatch(
    int runId,
    SourceOperation operation,
    Future<void> searchFuture,
    Future<void>? memoryFuture,
    ProbeScheduler<SourceSearchResult> scheduler,
  ) async {
    if (memoryFuture != null) await memoryFuture;
    if (!_alive(runId)) return;
    if (_autoMatched || _userSelected) {
      _completeAutoMatch();
      return;
    }

    try {
      await operation.wait(searchFuture);
      await operation.wait(scheduler.drained);
      if (_alive(runId) && !_autoMatchSettled) {
        _stopBackgroundWork();
        _completeAutoMatch();
      }
    } catch (_) {
      if (!operation.isCancelled) rethrow;
    }
  }

  void _completeAutoMatch() {
    final gate = _autoMatchGate;
    if (gate != null && !gate.isCompleted) gate.complete();
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

  Future<void> _tryMemory(int runId) async {
    final bgmId = toInt(seedData?['bgmId']);
    final memory = MatchMemoryService.read(bgmId: bgmId, title: title);
    if (memory == null) return;

    final item = SourceSearchResult(
      Series(
        memory.seriesId,
        memory.title?.isNotEmpty == true ? memory.title! : title,
      ),
      source: memory.source,
      displayName: memory.sourceDisplayName ?? memory.source,
    );

    try {
      // 记忆命中必须完整解析到可播媒体，避免「匹配成功却播不了」。
      final probe = await ensureCandidatePlayable(
        item,
        episodeIndex: _ep,
        preferredLine: 1,
        raceMode: true,
      );
      if (!_alive(runId) || _autoMatched || _userSelected) return;
      if (probe.isInstantPlayable && probe.data != null) {
        _claimAutoMatch(runId, item, probe.data!);
        return;
      }
    } catch (_) {}

    if (!_alive(runId) || _autoMatched || _userSelected || _autoMatchSettled) {
      return;
    }
    try {
      await MatchMemoryService.remove(bgmId: bgmId, title: title);
    } catch (_) {}
  }

  /// 原子认领自动匹配结果；成功后停止后续搜索/探针。
  void _claimAutoMatch(
    int runId,
    SourceSearchResult item,
    PlaybackRequest data,
  ) {
    if (!_alive(runId) || _autoMatched || _userSelected || _autoMatchSettled) {
      return;
    }
    _autoMatched = true;
    _stopBackgroundWork();
    _recordAutoMatchDuration();
    _completeAutoMatch();
    onMatchFound?.call(data.copyWith());
    unawaited(persistMatchMemory(item, data));
  }

  void cancelSearch() {
    _runId++;
    _stopBackgroundWork();
    _completeAutoMatch();
    if (!_disposed) {
      isSearching = false;
      _progressing.clear();
      _emitProgress();
    }
  }

  void _stopBackgroundWork() {
    _sourceOperation.cancel();
    _sourceOperation.close();
    _sourceOperation = SourceOperation();
    _cancelAutoDeadline();
    _probeScheduler?.close();
    _progressing.clear();
    for (final probe in _probes.values) {
      if (probe.future == null && probe.status != SourceProbeStatus.resolving) {
        continue;
      }
      probe.future = null;
      if (probe.isInstantPlayable) continue;
      if (probe.data == null) _resolved.remove(probe.item.key);
      probe.status = SourceProbeStatus.pending;
      _switchGroups = null;
    }
  }

  bool _alive(int runId) => !_disposed && runId == _runId;

  void _emitProgress() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _searchSource({
    required int runId,
    required SourceOperation operation,
    required List<String> keywords,
    required String sourceKey,
    required String errorMsg,
  }) async {
    var failures = 0;
    final search = SourceOperation(
      parent: operation,
      timeout: SourceMatchEngine.sourceSearchBudget,
    );
    Future<List<SourceSearchResult>> load(String keyword) async {
      try {
        return await search.run(
          () => sourceKey == 'internal'
              ? _loadInternal(keyword)
              : _adapter.search(sourceKey, keyword, skipBgmEnhancement: true),
        );
      } catch (_) {
        failures++;
        return const [];
      }
    }

    try {
      List<SourceSearchResult> rows;
      if (keywords.length == 1) {
        rows = await load(keywords.first);
      } else {
        final done = Completer<List<SourceSearchResult>>();
        var remaining = 2;
        for (var i = 0; i < 2; i++) {
          unawaited(
            load(keywords[i]).then((rows) {
              if ((rows.isNotEmpty || --remaining == 0) && !done.isCompleted) {
                done.complete(rows);
              }
            }),
          );
        }
        rows = await done.future;
      }
      for (var i = 2; rows.isEmpty && i < keywords.length; i++) {
        if (!_alive(runId) || operation.isCancelled || _autoMatchSettled) {
          return;
        }
        if (search.isCancelled) break;
        rows = await load(keywords[i]);
      }
      if (!_alive(runId) || operation.isCancelled) return;
      if (rows.isNotEmpty) _appendResults(runId, sourceKey, rows);
      _finishSource(
        runId,
        sourceKey,
        error: rows.isEmpty && (search.timedOut || failures == keywords.length)
            ? errorMsg
            : null,
      );
    } finally {
      // The first successful keyword owns the result; cancel its siblings.
      search.cancel();
      search.close();
    }
  }

  Future<List<SourceSearchResult>> _loadInternal(String keyword) async {
    final raw = await getSearch(keyword);
    return [
      for (final item in raw)
        if (item['videos'] != null) SourceSearchResult.internal(item),
    ];
  }

  void _appendResults(
    int runId,
    String source,
    Iterable<SourceSearchResult> rows,
  ) {
    if (!_alive(runId)) return;
    final context = _syncContext();
    final previousCount = _sourceCounts[source] ?? 0;
    var count = previousCount;
    final seen = <String>{};
    SourceMatchScore? first;
    SourceMatchScore? second;

    for (final data in rows) {
      if (_results.length >= 100) break;
      if (count >= 20) break;
      final key = data.key;
      if (_results.containsKey(key) || !seen.add(key)) continue;
      if (data.source != 'internal') {
        final score = _engine.score(data, context);
        if (score.confidence < SourceMatchEngine.admissionConfidence) {
          continue;
        }
        _rankCache[key] = score;
        if (autoMatchMode && score.shouldProbeImmediately) {
          // Only two probes per source can run; select them in one pass.
          if (first == null || score.confidence > first.confidence) {
            second = first;
            first = score;
          } else if (second == null || score.confidence > second.confidence) {
            second = score;
          }
        }
      }

      _results[key] = data;
      count++;
    }
    if (count == previousCount) return;
    _sourceCounts[source] = count;
    _switchGroups = null;

    if (!_disposed) notifyListeners();

    if (autoMatchMode && !_userSelected && !_autoMatched) {
      if (first != null) _enqueueAutoProbe(runId, first.candidate);
      if (second != null) _enqueueAutoProbe(runId, second.candidate);
    }
  }

  void _finishSource(int runId, String sourceKey, {String? error}) {
    if (!_alive(runId)) return;
    if (error != null) _errors.add(error);
    _progressing.remove(sourceKey);
    _finished.add(sourceKey);
    _emitProgress();
  }

  void _enqueueAutoProbe(int runId, SourceSearchResult item) {
    if (!_alive(runId) || _autoMatched || _userSelected) return;
    if (_autoMatchSettled || _probeScheduler?.isClosed != false) return;
    if (item.source == 'internal') return;
    if (_autoProbesTotal >= SourceMatchEngine.maxAutoProbes) return;

    final used = _autoProbesBySource[item.source] ?? 0;
    if (used >= SourceMatchEngine.raceProbesPerSource) return;

    final score = _rankCache[item.key];
    if (score != null && !score.shouldProbeImmediately) return;

    if (!_probeScheduler!.add(item)) return;
    _autoProbesBySource[item.source] = used + 1;
    _autoProbesTotal++;
  }

  Future<void> _runAutoProbe(int runId, SourceSearchResult item) async {
    if (!_alive(runId) || _autoMatched || _userSelected || _autoMatchSettled) {
      return;
    }
    try {
      final probe = await ensureCandidatePlayable(
        item,
        episodeIndex: _ep,
        preferredLine: 1,
        raceMode: true,
      );
      if (probe.isInstantPlayable) _claimAutoMatch(runId, item, probe.data!);
    } catch (_) {
      // Cancellation of this run releases the scheduler slot.
    }
  }

  Future<PlaybackRequest?> findNextPlayableCandidate({
    required Set<String> excludedKeys,
    int? episodeIndex,
  }) async {
    final runId = _runId;
    final ep = episodeIndex ?? _ep;
    final context = _syncContext();

    final ranked = [
      for (final item in _results.values)
        if (item.source != 'internal' &&
            !excludedKeys.contains(item.key) &&
            !excludedKeys.contains(item.source))
          _rankCache[item.key] ??= _engine.score(item, context),
    ]..sort(SourceMatchEngine.compareScores);

    for (final rankedItem in ranked) {
      if (!_alive(runId)) return null;
      final item = rankedItem.candidate;
      try {
        final probe = await ensureCandidatePlayable(
          item,
          episodeIndex: ep,
          preferredLine: 1,
          raceMode: true,
        );
        if (probe.isInstantPlayable && probe.data != null) {
          unawaited(persistMatchMemory(item, probe.data!));
          return probe.data!;
        }
      } catch (_) {}
    }
    return null;
  }

  int get _ep => targetEpisodeIndex < 0 ? 0 : targetEpisodeIndex;

  SourceMatchContext _syncContext() => _matchContext ??= SourceMatchContext(
    primaryTitle: title,
    manualAliases: manualAliases,
    automaticAliases: automaticAliases,
    // v0 eps is the declared episode count; total_episodes includes specials.
    bgmEpisodeCount:
        (seedData?['bgmDetailData'] as Map<String, dynamic>?)?['eps'] as int?,
  );

  Future<void> persistMatchMemory(
    SourceSearchResult item,
    PlaybackRequest data,
  ) {
    return MatchMemoryService.writeSuccess(
      bgmId: toInt(seedData?['bgmId'] ?? data.metadata['bgmId']),
      title: title,
      source: item.source,
      seriesId: item.id,
      candidateTitle: item.title,
      sourceDisplayName: item.displayName,
    );
  }

  List<DirectSourceGroup> getDirectSourceGroups({
    required int episodeIndex,
    required int preferredLine,
    String? currentSource,
  }) {
    if (_disposed) return const [];
    final context = _syncContext();
    final key = (
      context,
      episodeIndex,
      preferredLine,
      _results.length,
      currentSource,
    );
    if (_switchKey != key) {
      _switchGroups = null;
      _switchCandidates =
          [
            for (final item in _results.values)
              _probeFor(item, episodeIndex, preferredLine)
                ..score = (_rankCache[item.key] ??= _engine.score(
                  item,
                  context,
                )).scoreForCurrentSource(currentSource),
          ]..sort((a, b) {
            final score = b.score.compareTo(a.score);
            return score != 0 ? score : a.item.key.compareTo(b.item.key);
          });
    }
    _switchKey = key;
    final cached = _switchGroups;
    if (cached != null) return cached;
    // 匹配分只在候选/上下文变化时排序；探针更新按五种状态线性分桶。
    final buckets = List.generate(5, (_) => <SourceProbeState>[]);
    for (final candidate in _switchCandidates) {
      buckets[_statusRank(candidate.status)].add(candidate);
    }
    final grouped = <String, List<SourceProbeState>>{};
    for (final c in buckets.expand((bucket) => bucket)) {
      final key = c.routeKey ?? 'candidate:${c.item.key}';
      (grouped[key] ??= []).add(c);
    }
    return _switchGroups = [
      for (final e in grouped.entries)
        DirectSourceGroup(key: e.key, origins: e.value),
    ];
  }

  void startSwitchProbes(Iterable<SourceProbeState> candidates) {
    var active = candidates
        .where((c) => c.status == SourceProbeStatus.resolving)
        .length;
    if (active >= 4) return;
    for (final c in candidates) {
      if (c.status == SourceProbeStatus.pending) {
        unawaited(
          ensureCandidatePlayable(
            c.item,
            episodeIndex: c.episodeIndex,
            preferredLine: c.preferredLine,
          ).then<void>((_) {}, onError: (Object _) {}),
        );
        if (++active >= 4) {
          return;
        }
      }
    }
  }

  int _statusRank(SourceProbeStatus s) => switch (s) {
    SourceProbeStatus.direct => 0,
    SourceProbeStatus.playable => 1,
    SourceProbeStatus.resolving => 2,
    SourceProbeStatus.pending => 3,
    SourceProbeStatus.failed => 4,
  };

  Future<SourceProbeState> ensureCandidatePlayable(
    SourceSearchResult item, {
    required int episodeIndex,
    required int preferredLine,
    bool raceMode = false,
  }) {
    if (_disposed) throw StateError('Search controller is disposed');
    final probe = _probeFor(item, episodeIndex, preferredLine);
    if (probe.isReady) return Future.value(probe);
    return probe.future ??= _resolveProbe(probe, raceMode: raceMode);
  }

  SourceProbeState _probeFor(SourceSearchResult item, int episode, int line) {
    final selection = (episode, line);
    if (_probeSelection != selection) {
      for (final probe in _probes.values) {
        probe.operation?.cancel();
        if (probe.future != null && probe.data == null) {
          _resolved.remove(probe.item.key);
        }
      }
      _probes.clear();
      _probeSelection = selection;
      _switchKey = null;
      _switchCandidates = const [];
      _switchGroups = null;
    }
    return _probes.putIfAbsent(
      item.key,
      () => SourceProbeState(
        item: item,
        episodeIndex: episode,
        preferredLine: line,
      ),
    )..item = item;
  }

  @protected
  Duration get candidateTimeout => const Duration(seconds: 15);

  @protected
  Duration get raceTimeout => const Duration(seconds: 5);

  Future<SourceProbeState> _resolveProbe(
    SourceProbeState probe, {
    required bool raceMode,
  }) async {
    final parent = _sourceOperation;
    final operation = probe.operation = SourceOperation(
      parent: parent,
      timeout: raceMode ? raceTimeout : candidateTimeout,
    );
    probe.status = SourceProbeStatus.resolving;
    probe.error = null;
    _switchGroups = null;
    _emitProgress();
    try {
      await operation.run(() async {
        final catalog = await resolveVideoData(probe.item);
        SourceOperation.check();
        final ep = probe.episodeIndex;
        if (ep < 0 || ep >= catalog.episodes.length) {
          throw StateError('未找到目标剧集');
        }
        final episode = catalog.episodes[ep];
        final preferred = episode.lineAt(probe.preferredLine) != null
            ? probe.preferredLine
            : episode.availableLineIndexes.firstOrNull;
        if (preferred == null) throw StateError('目标剧集无可播放线路');
        final data = probe.data = catalog.copyWith(
          episodeIndex: ep,
          lineIndex: preferred,
        );
        if (catalog.source == 'internal') {
          final token = episode.lineAt(preferred)!;
          probe.routeKey = _routeKeyFor(catalog.source, token);
          // Internal tokens can be resolved by the player's internal-source path.
          if (MediaReadiness.isAcceptablePlaybackUrl(token)) {
            data.storePrefetched(
              episodeIndex: ep,
              lineIndex: preferred,
              episodeId: token,
              url: token,
              httpHeaders: const {},
            );
            probe.status = SourceProbeStatus.direct;
          } else {
            probe.status = SourceProbeStatus.playable;
          }
          return;
        }

        final lines = <(int, String)>[];
        final seen = <String>{};
        final limit = raceMode
            ? SourceMatchEngine.maxLinesPerCandidate
            : _manualMaxLines;
        for (
          var i = 0;
          i <= episode.lines.length && lines.length < limit;
          i++
        ) {
          final line = i == 0 ? preferred : i;
          if (i != 0 && line == preferred) continue;
          final token = episode.lineAt(line);
          if (token != null && seen.add(token)) lines.add((line, token));
        }
        final mediaOperation = SourceOperation(parent: operation);
        Object? lastError;
        Future<bool> resolve((int, String) line) async {
          try {
            return await mediaOperation.run(() async {
              final media = await resolveLineMedia(
                sourceKey: catalog.source,
                lineToken: line.$2,
              );
              SourceOperation.check();
              if (!MediaReadiness.isAcceptablePlaybackUrl(media.url)) {
                throw StateError('线路返回不可播放地址');
              }
              if (probe.isInstantPlayable) return false;
              data.lineIndex = line.$1;
              data.storePrefetched(
                episodeIndex: ep,
                lineIndex: line.$1,
                episodeId: line.$2,
                url: media.url,
                httpHeaders: media.httpHeaders,
              );
              probe.routeKey = _routeKeyFor(catalog.source, line.$2);
              probe.status = SourceProbeStatus.direct;
              return true;
            });
          } catch (error) {
            lastError = error;
            return false;
          }
        }

        try {
          if (raceMode) {
            final done = Completer<void>();
            var remaining = lines.length;
            for (final line in lines) {
              unawaited(
                resolve(line).then((matched) {
                  if ((matched || --remaining == 0) && !done.isCompleted) {
                    done.complete();
                  }
                }),
              );
            }
            await operation.wait(done.future);
          } else {
            for (final line in lines) {
              if (await resolve(line)) break;
              SourceOperation.check();
            }
          }
        } finally {
          mediaOperation.cancel();
          mediaOperation.close();
        }
        SourceOperation.check();
        if (!probe.isInstantPlayable) throw lastError ?? StateError('无法解析播放地址');
      });
    } catch (error) {
      if (parent.isCancelled ||
          (!operation.timedOut && operation.isCancelled)) {
        rethrow;
      }
      probe.status = SourceProbeStatus.failed;
      probe.error = operation.timedOut ? '解析超时' : error.toString();
      // Failed candidates must not retain catalogs beyond the bounded cache.
      probe.data = null;
    } finally {
      operation.cancel();
      operation.close();
      if (identical(probe.operation, operation)) {
        probe.operation = null;
        probe.future = null;
        if (identical(_probes[probe.item.key], probe)) {
          _switchGroups = null;
          _emitProgress();
        }
      }
    }
    return probe;
  }

  @protected
  Future<({String url, Map<String, String> httpHeaders})> resolveLineMedia({
    required String sourceKey,
    required String lineToken,
  }) async {
    final kind = MediaReadiness.classify(lineToken);
    if (kind == MediaTokenKind.torrent) {
      return (url: lineToken, httpHeaders: const <String, String>{});
    }
    final adapter = _adapter.adapterFor(sourceKey);
    if (adapter == null) throw StateError('视频源不可用: $sourceKey');
    if (kind == MediaTokenKind.directMedia) {
      if (!await adapter.isPlaybackUrlReachable(lineToken)) {
        throw StateError('媒体地址不可访问');
      }
      final headers = adapter.mediaValidationHeaders;
      return (
        url: lineToken,
        httpHeaders: VideoUrlExtractor.isSignedCdnUrl(lineToken)
            ? {
                for (final entry in headers.entries)
                  if (entry.key.toLowerCase() != 'referer')
                    entry.key: entry.value,
              }
            : headers,
      );
    }
    return adapter.resolvePlaybackMedia(lineToken, maxAttempts: 1);
  }

  String _routeKeyFor(String source, String token) =>
      MediaReadiness.classify(token) == MediaTokenKind.needsResolve
      ? '$source|$token'
      : token;

  Future<PlaybackRequest> resolveVideoData(SourceSearchResult item) =>
      _resolved.get(item.key, () => _doResolveVideoData(item));

  Future<PlaybackRequest> _doResolveVideoData(SourceSearchResult item) async {
    final operation = SourceOperation(
      parent: SourceOperation.current ?? _sourceOperation,
      timeout: const Duration(seconds: 10),
    );
    try {
      return await operation.run(() async {
        if (item.internalData case final data?) {
          return PlaybackRequest.fromMap(
            data,
            source: item.source,
            metadataUpdates: _seedMetadata,
          );
        }
        final request = await _adapter.buildPlaybackRequest(item);
        if (request == null) {
          throw StateError(
            'Source returned no playback catalog: ${item.source}',
          );
        }
        return _seedMetadata.isEmpty
            ? request
            : request.copyWith(metadataUpdates: _seedMetadata);
      });
    } finally {
      operation.close();
    }
  }

}
