import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:baka/api/post.dart';
import 'package:baka/api/request_cache.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/services/matching/match_memory_service.dart';
import 'package:baka/services/matching/media_readiness.dart';
import 'package:baka/services/matching/probe_scheduler.dart';
import 'package:baka/services/matching/source_match_engine.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source_search_result.dart';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/source/source_adapter.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/utils/json_values.dart';
import 'package:baka/utils/title_matcher.dart';

final _reAliasSep = RegExp(r'[/／、,，;；\n]');
final _reBrackets = RegExp(r'[（(].*?[）)]');
final _reWhitespace = RegExp(r'\s+');

String _norm(String value) => value.toLowerCase().replaceAll(_reWhitespace, '');

/// 探针状态，按展示优先级声明（换源列表按 index 分桶）：
/// - [direct]：目标集媒体已解析，可即点即播（含预取直链 + headers）
/// - [playable]：剧集目录就绪，媒体地址待点选时再取
/// - [failed]：目录或媒体解析失败
enum SourceProbeStatus { direct, playable, resolving, pending, failed }

/// One candidate resolved for one (episode, preferred line) selection.
class SourceProbeState {
  SourceProbeState(this.item, this.episodeIndex, this.preferredLine);

  SourceSearchResult item;
  final int episodeIndex;
  final int preferredLine;
  SourceProbeStatus status = SourceProbeStatus.pending;
  PlaybackRequest? data;
  String? routeKey;
  int score = 0;
  Future<SourceProbeState>? future;
  SourceOperation? _operation;

  int? get resolvedLineIndex => data?.lineIndex;

  /// 目录就绪即可选；[isInstantPlayable] 额外保证已预取可播媒体。
  bool get isReady => status.index <= SourceProbeStatus.playable.index;
  bool get isInstantPlayable => status == SourceProbeStatus.direct;
}

/// Candidates that resolved to the same media route.
class DirectSourceGroup {
  const DirectSourceGroup({required this.key, required this.origins});

  final String key;
  final List<SourceProbeState> origins;

  SourceProbeState get primary => origins.first;
  SourceProbeStatus get status => primary.status;
  bool get isReady => primary.isReady;
  bool get isInstantPlayable => primary.isInstantPlayable;
}

/// Searches every enabled source for one title, ranks the results, and probes
/// candidates until one is playable (automatic matching) or for the switcher.
class VideoSourceSearchController extends ChangeNotifier {
  VideoSourceSearchController({
    this.seedData,
    String? title,
    this.autoMatchMode = false,
    int targetEpisodeIndex = 0,
    this.onMatchFound,
    this.onMatchFailed,
  }) : title = _resolveTitle(title, seedData),
       _episode = targetEpisodeIndex < 0 ? 0 : targetEpisodeIndex {
    _aliasKey = _bgmId != null ? 'bgm:$_bgmId' : 'title:${_norm(this.title)}';
    manualAliases = MatchMemoryService.readAliases(
      _aliasKey,
      fallbackKey: 'title:${_norm(this.title)}',
    );
  }

  /// Hands a finished detail-page search to the player.
  static VideoSourceSearchController? globalCached;

  static void cacheGlobal(VideoSourceSearchController controller) {
    if (!identical(globalCached, controller)) globalCached?.dispose();
    globalCached = controller;
  }

  static bool isGlobalCached(VideoSourceSearchController controller) =>
      identical(globalCached, controller);

  /// Takes the cached search for this title; once taken, the caller owns it.
  static VideoSourceSearchController? takeCachedFor({
    Map<String, dynamic>? seedData,
    String? title,
  }) {
    final cached = globalCached;
    globalCached = null;
    if (cached?.title == _resolveTitle(title, seedData)) return cached;
    cached?.dispose();
    return null;
  }

  static String _resolveTitle(String? title, Map<String, dynamic>? seedData) {
    final explicit = title?.trim();
    return explicit != null && explicit.isNotEmpty
        ? explicit
        : seedData?['title']?.toString().trim() ?? '';
  }

  static const _engine = SourceMatchEngine();
  static const _manualMaxLines = 4;
  static const _maxResults = 100;
  static const _maxResultsPerSource = 20;
  static const _maxSwitchProbes = 4;

  final String title;
  final Map<String, dynamic>? seedData;
  final bool autoMatchMode;
  final int _episode;
  final ValueChanged<PlaybackRequest>? onMatchFound;
  final VoidCallback? onMatchFailed;
  final SourceAdapterService _repository = sourceRepository;

  late final int? _bgmId = toInt(seedData?['bgmId']);
  late final String _aliasKey;
  late final Map<String, dynamic> _seedMetadata = {
    for (final key in const [
      'bgmId',
      'score',
      'bgmDetailData',
      'bgmImageUrl',
      'logoUrl',
    ])
      key: ?seedData?[key],
  };

  List<String> manualAliases = const [];
  late final List<String> automaticAliases = _buildAutoAliases();
  final Set<String> activeAutoAliases = {};

  final _results = <String, SourceSearchResult>{};
  final _scores = <String, SourceMatchScore>{};
  final _sourceCounts = <String, int>{};
  final _errors = <String>[];
  final _progressing = <String>{};
  int _finished = 0;
  SourceMatchContext? _matchContext;

  /// Bounded LRU of loaded catalogs; also shares in-flight loads.
  final _catalogs = RequestCache<String, PlaybackRequest>(limit: 32);
  final _probes = <String, SourceProbeState>{};
  (int, int)? _probeSelection;
  Object? _groupsKey;
  List<SourceProbeState> _ranked = const [];
  List<DirectSourceGroup>? _groups;

  ProbeScheduler<SourceSearchResult>? _autoProbes;
  final _autoProbesBySource = <String, int>{};
  int _autoProbeCount = 0;
  Timer? _deadline;
  Completer<void>? _autoDone;

  SourceOperation _operation = SourceOperation();
  int _runId = 0;
  bool _searching = false;
  bool _disposed = false;
  bool _userSelected = false;
  bool _matched = false;

  bool get isSearching => _searching;
  bool get isDisposed => _disposed;
  bool get hasMatched => _matched;
  Iterable<SourceSearchResult> get results => _results.values;
  bool hasResult(SourceSearchResult item) =>
      identical(_results[item.key], item);
  int resultCountFor(String source) => _sourceCounts[source] ?? 0;
  Set<String> get progressingSources => _progressing;
  int get finishedCount => _finished;
  List<String> get searchErrors => _errors;

  @protected
  Duration get candidateTimeout => const Duration(seconds: 15);

  @protected
  Duration get raceTimeout => const Duration(seconds: 5);

  bool get _autoSettled => _autoDone?.isCompleted ?? false;

  SourceMatchContext get _context => _matchContext ??= SourceMatchContext(
    primaryTitle: title,
    manualAliases: manualAliases,
    automaticAliases: automaticAliases,
    // v0 eps is the declared episode count; total_episodes includes specials.
    bgmEpisodeCount:
        (seedData?['bgmDetailData'] as Map<String, dynamic>?)?['eps'] as int?,
  );

  bool _alive(int runId) => !_disposed && runId == _runId;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// A probe changed state: the switch grouping must be rebuilt.
  void _changed() {
    _groups = null;
    _notify();
  }

  void markUserSelected() {
    _userSelected = true;
    if (autoMatchMode && _searching) cancelSearch();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (identical(globalCached, this)) globalCached = null;
    _runId++;
    _stopBackgroundWork();
    _operation
      ..cancel()
      ..close();
    _completeAuto();
    _clearSession();
    super.dispose();
  }

  List<String> _buildAutoAliases() {
    final pool = <String>{title};
    final detail = seedData?['bgmDetailData'] as Map<String, dynamic>?;
    for (final raw in [detail?['name_cn'], detail?['name']]) {
      if (raw == null) continue;
      for (final part in raw.toString().split(_reAliasSep)) {
        if (part.trim() case final alias when alias.isNotEmpty) pool.add(alias);
      }
    }
    final out = <String>[];
    final seen = {_norm(title)};
    for (final name in pool) {
      for (final candidate in [
        name,
        name.replaceAll(_reBrackets, '').replaceAll(_reWhitespace, ' ').trim(),
        extractBaseTitle(name),
      ]) {
        if (candidate.isNotEmpty && seen.add(_norm(candidate))) {
          out.add(candidate);
          if (out.length >= 6) return out;
        }
      }
    }
    return out;
  }

  Future<void> toggleAutoAlias(String alias) async {
    if (_disposed || _searching) return;
    if (!activeAutoAliases.remove(alias)) activeAutoAliases.add(alias);
    await startSearch();
  }

  Future<bool> addManualAlias(String value) async {
    if (_disposed || _searching) return false;
    final seen = {
      _norm(title),
      for (final alias in manualAliases) _norm(alias),
    };
    final added = [
      for (final part in value.split(_reAliasSep))
        if (part.trim() case final alias
            when alias.isNotEmpty && seen.add(_norm(alias)))
          alias,
    ];
    if (added.isEmpty) return false;
    await _saveAliases([...manualAliases, ...added]);
    return true;
  }

  Future<void> removeManualAlias(String alias) async {
    if (_disposed || _searching) return;
    await _saveAliases([
      for (final item in manualAliases)
        if (item != alias) item,
    ]);
  }

  Future<void> _saveAliases(List<String> aliases) async {
    manualAliases = aliases;
    final runId = _runId;
    notifyListeners();
    await MatchMemoryService.saveAliases(_aliasKey, aliases);
    if (_alive(runId)) await startSearch();
  }

  /// Searches all sources. In automatic mode it returns once a candidate is
  /// claimed, every source and probe has finished, or the hard deadline hits.
  Future<void> startSearch() async {
    if (_disposed) return;
    _stopBackgroundWork();
    _completeAuto();
    final runId = ++_runId;
    _matched = false;
    _clearSession();
    final operation = _operation;
    final scheduler = _autoProbes = autoMatchMode
        ? ProbeScheduler<SourceSearchResult>(
            concurrency: SourceMatchEngine.raceConcurrency,
            keyOf: (item) => item.key,
            run: (item) => _runAutoProbe(runId, item),
          )
        : null;
    _searching = true;
    _notify();

    try {
      await operation.wait(_repository.init());
    } catch (_) {
      if (!_alive(runId)) return;
      _errors.add('搜索初始化失败');
      return _finishRun(runId);
    }
    if (!_alive(runId)) return;

    final memory = autoMatchMode ? _tryMemory(runId) : null;
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
    // Automatic matching searches only the primary title: the fastest path.
    final keywords = autoMatchMode
        ? [title]
        : [
            title,
            ...manualAliases.take(3),
            ...automaticAliases.where(activeAutoAliases.contains).take(3),
          ];
    _progressing.addAll(sources.map((source) => source.key));
    final search = runConcurrent(
      sources.length,
      autoMatchMode ? SourceMatchEngine.autoSearchConcurrency : 8,
      (i) => _searchSource(runId, operation, keywords, sources[i]),
    );

    if (scheduler == null) {
      await search;
    } else {
      final done = _autoDone = Completer<void>();
      _deadline = Timer(
        SourceMatchEngine.hardDeadline,
        () => _settleAuto(runId),
      );
      unawaited(
        () async {
          try {
            await memory;
            await search;
            await scheduler.drained;
          } finally {
            _settleAuto(runId);
          }
        }().catchError((Object e) {
          debugPrint('[AutoMatch] aborted: $e');
        }),
      );
      await done.future;
    }
    _finishRun(runId);
  }

  void _finishRun(int runId) {
    if (!_alive(runId)) return;
    _searching = false;
    _notify();
    if (autoMatchMode && !_matched && !_userSelected) onMatchFailed?.call();
  }

  void cancelSearch() {
    _runId++;
    _stopBackgroundWork();
    _completeAuto();
    if (_disposed) return;
    _searching = false;
    _notify();
  }

  void _settleAuto(int runId) {
    if (!_alive(runId) || _autoSettled) return;
    _stopBackgroundWork();
    _completeAuto();
  }

  void _completeAuto() {
    final done = _autoDone;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Cancels searches and probes; unfinished probes return to pending so a
  /// manual pick can restart them.
  void _stopBackgroundWork() {
    _operation
      ..cancel()
      ..close();
    _operation = SourceOperation();
    _deadline?.cancel();
    _deadline = null;
    _autoProbes?.close();
    _progressing.clear();
    for (final probe in _probes.values) {
      if (probe.future == null && probe.status != SourceProbeStatus.resolving) {
        continue;
      }
      probe.future = null;
      if (probe.isInstantPlayable) continue;
      if (probe.data == null) _catalogs.remove(probe.item.key);
      probe.status = SourceProbeStatus.pending;
      _groups = null;
    }
  }

  /// Drops every result and probe of the previous search.
  void _clearSession() {
    _results.clear();
    _scores.clear();
    _sourceCounts.clear();
    _errors.clear();
    _progressing.clear();
    _finished = 0;
    _matchContext = null;
    _catalogs.clear();
    _resetProbes();
    _probeSelection = null;
    _autoProbesBySource.clear();
    _autoProbeCount = 0;
  }

  void _resetProbes() {
    for (final probe in _probes.values) {
      probe._operation?.cancel();
    }
    _probes.clear();
    _groupsKey = null;
    _ranked = const [];
    _groups = null;
  }

  Future<void> _tryMemory(int runId) async {
    final memory = MatchMemoryService.read(bgmId: _bgmId, title: title);
    if (memory == null) return;
    final item = SourceSearchResult(
      Series(memory.seriesId, memory.title ?? ''),
      source: memory.source,
      displayName: memory.sourceDisplayName ?? memory.source,
    );
    // A remembered match must still pass the current title check, so an old
    // mismatch (or a record without a title) is confirmed by normal search.
    if (_engine.score(item, _context).shouldProbeImmediately) {
      try {
        final probe = await _probeForPlayback(item, _episode);
        if (probe.isInstantPlayable) return _claim(runId, item, probe.data!);
      } catch (_) {}
    }
    if (_alive(runId) && !_matched && !_userSelected && !_autoSettled) {
      await MatchMemoryService.remove(bgmId: _bgmId, title: title);
    }
  }

  void _claim(int runId, SourceSearchResult item, PlaybackRequest data) {
    if (!_alive(runId) || _matched || _userSelected || _autoSettled) return;
    _matched = true;
    _settleAuto(runId);
    onMatchFound?.call(data);
    unawaited(persistMatchMemory(item));
  }

  Future<void> _searchSource(
    int runId,
    SourceOperation operation,
    List<String> keywords,
    ({String key, String error}) source,
  ) async {
    if (operation.isCancelled) return;
    var failures = 0;
    final search = SourceOperation(
      parent: operation,
      timeout: SourceMatchEngine.sourceSearchBudget,
    );
    Future<List<SourceSearchResult>> load(String keyword) async {
      try {
        return await search.run(
          () => source.key == 'internal'
              ? _loadInternal(keyword)
              : _repository.search(
                  source.key,
                  keyword,
                  skipBgmEnhancement: true,
                ),
        );
      } catch (_) {
        failures++;
        return const [];
      }
    }

    try {
      // The first two keywords race; the rest are tried only after both miss.
      var rows = keywords.length == 1
          ? await load(keywords.first)
          : await _firstAccepted([
              load(keywords[0]),
              load(keywords[1]),
            ], (rows) => rows.isNotEmpty);
      for (var i = 2; rows.isEmpty && i < keywords.length; i++) {
        if (search.isCancelled) break;
        rows = await load(keywords[i]);
      }
      if (!_alive(runId) || operation.isCancelled) return;
      _appendResults(source.key, rows);
      if (rows.isEmpty && (search.timedOut || failures == keywords.length)) {
        _errors.add(source.error);
      }
      _progressing.remove(source.key);
      _finished++;
      _notify();
    } finally {
      // The first successful keyword owns the result; cancel its siblings.
      search
        ..cancel()
        ..close();
    }
  }

  static Future<List<SourceSearchResult>> _loadInternal(String keyword) async =>
      [
        for (final item in await getSearch(keyword))
          if (item['videos'] != null) SourceSearchResult.internal(item),
      ];

  void _appendResults(String source, List<SourceSearchResult> rows) {
    final context = _context;
    final before = _sourceCounts[source] ?? 0;
    var count = before;
    SourceMatchScore? first;
    SourceMatchScore? second;
    for (final item in rows) {
      if (_results.length >= _maxResults || count >= _maxResultsPerSource) {
        break;
      }
      final key = item.key;
      if (_results.containsKey(key)) continue;
      final score = _engine.score(item, context);
      if (item.source != 'internal' &&
          score.confidence < SourceMatchEngine.admissionConfidence) {
        continue;
      }
      _scores[key] = score;
      _results[key] = item;
      count++;
      // Each source runs at most two probes; keep its two best in one pass.
      if (autoMatchMode && score.shouldProbeImmediately) {
        if (first == null || score.confidence > first.confidence) {
          second = first;
          first = score;
        } else if (second == null || score.confidence > second.confidence) {
          second = score;
        }
      }
    }
    if (count == before) return;
    _sourceCounts[source] = count;
    _groups = null;
    if (first != null) _enqueueAutoProbe(first.candidate);
    if (second != null) _enqueueAutoProbe(second.candidate);
  }

  void _enqueueAutoProbe(SourceSearchResult item) {
    final scheduler = _autoProbes;
    if (scheduler == null ||
        scheduler.isClosed ||
        _autoProbeCount >= SourceMatchEngine.maxAutoProbes) {
      return;
    }
    final used = _autoProbesBySource[item.source] ?? 0;
    if (used >= SourceMatchEngine.raceProbesPerSource || !scheduler.add(item)) {
      return;
    }
    _autoProbesBySource[item.source] = used + 1;
    _autoProbeCount++;
  }

  Future<void> _runAutoProbe(int runId, SourceSearchResult item) async {
    try {
      final probe = await _probeForPlayback(item, _episode);
      if (probe.isInstantPlayable) _claim(runId, item, probe.data!);
    } catch (_) {
      // Cancellation of this run releases the scheduler slot.
    }
  }

  Future<SourceProbeState> _probeForPlayback(
    SourceSearchResult item,
    int episode,
  ) => ensureCandidatePlayable(
    item,
    episodeIndex: episode,
    preferredLine: 1,
    raceMode: true,
  );

  /// Player recovery: the best remaining confident candidate that plays.
  Future<PlaybackRequest?> findNextPlayableCandidate({
    required Set<String> excludedSources,
    int? episodeIndex,
  }) async {
    final runId = _runId;
    final ranked = [
      for (final item in _results.values)
        if (item.source != 'internal' && !excludedSources.contains(item.source))
          if (_scores[item.key]! case final score
              when score.shouldProbeImmediately)
            score,
    ]..sort(SourceMatchEngine.compareScores);
    for (final score in ranked) {
      if (!_alive(runId)) return null;
      try {
        final probe = await _probeForPlayback(
          score.candidate,
          episodeIndex ?? _episode,
        );
        if (probe.isInstantPlayable) {
          unawaited(persistMatchMemory(score.candidate));
          return probe.data;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<void> persistMatchMemory(SourceSearchResult item) =>
      MatchMemoryService.writeSuccess(
        bgmId: _bgmId ?? item.series?.bgmId,
        title: title,
        source: item.source,
        seriesId: item.id,
        candidateTitle: item.title,
        sourceDisplayName: item.displayName,
      );

  /// Results grouped by media route. Match scores are sorted only when the
  /// candidates change; probe updates just re-bucket by status in O(n).
  List<DirectSourceGroup> getDirectSourceGroups({
    required int episodeIndex,
    required int preferredLine,
    String? currentSource,
  }) {
    if (_disposed) return const [];
    final key = (episodeIndex, preferredLine, _results.length, currentSource);
    if (_groupsKey != key) {
      _ranked =
          [
            for (final item in _results.values)
              _probeFor(item, episodeIndex, preferredLine)
                ..score = _scores[item.key]!.scoreForCurrentSource(
                  currentSource,
                ),
          ]..sort((a, b) {
            final byScore = b.score.compareTo(a.score);
            return byScore != 0 ? byScore : a.item.key.compareTo(b.item.key);
          });
      _groupsKey = key;
      _groups = null;
    }
    return _groups ??= () {
      final buckets = [
        for (final _ in SourceProbeStatus.values) <SourceProbeState>[],
      ];
      for (final probe in _ranked) {
        buckets[probe.status.index].add(probe);
      }
      final grouped = <String, List<SourceProbeState>>{};
      for (final bucket in buckets) {
        for (final probe in bucket) {
          (grouped[probe.routeKey ?? 'candidate:${probe.item.key}'] ??= []).add(
            probe,
          );
        }
      }
      return [
        for (final entry in grouped.entries)
          DirectSourceGroup(key: entry.key, origins: entry.value),
      ];
    }();
  }

  /// Keeps up to [_maxSwitchProbes] switcher probes running.
  void startSwitchProbes(Iterable<SourceProbeState> candidates) {
    var active = candidates
        .where((c) => c.status == SourceProbeStatus.resolving)
        .length;
    for (final candidate in candidates) {
      if (active >= _maxSwitchProbes) return;
      if (candidate.status != SourceProbeStatus.pending) continue;
      active++;
      ensureCandidatePlayable(
        candidate.item,
        episodeIndex: candidate.episodeIndex,
        preferredLine: candidate.preferredLine,
      ).ignore();
    }
  }

  Future<SourceProbeState> ensureCandidatePlayable(
    SourceSearchResult item, {
    required int episodeIndex,
    required int preferredLine,
    bool raceMode = false,
  }) {
    if (_disposed) throw StateError('Search controller is disposed');
    final probe = _probeFor(item, episodeIndex, preferredLine);
    if (probe.isReady) return Future.value(probe);
    return probe.future ??= _resolveProbe(probe, raceMode);
  }

  /// Probes belong to one selection; changing it cancels the unfinished ones.
  SourceProbeState _probeFor(SourceSearchResult item, int episode, int line) {
    if (_probeSelection != (episode, line)) {
      for (final probe in _probes.values) {
        if (probe.future != null && probe.data == null) {
          _catalogs.remove(probe.item.key);
        }
      }
      _resetProbes();
      _probeSelection = (episode, line);
    }
    return _probes.putIfAbsent(
      item.key,
      () => SourceProbeState(item, episode, line),
    )..item = item;
  }

  Future<SourceProbeState> _resolveProbe(
    SourceProbeState probe,
    bool raceMode,
  ) async {
    final parent = _operation;
    final operation = probe._operation = SourceOperation(
      parent: parent,
      timeout: raceMode ? raceTimeout : candidateTimeout,
    );
    probe.status = SourceProbeStatus.resolving;
    _changed();
    try {
      await operation.run(() => _resolveMedia(probe, raceMode));
    } catch (_) {
      // Cancellation belongs to the caller; a timeout or failure marks the probe.
      if (parent.isCancelled ||
          (operation.isCancelled && !operation.timedOut)) {
        rethrow;
      }
      probe
        ..status = SourceProbeStatus.failed
        ..data = null;
    } finally {
      operation
        ..cancel()
        ..close();
      if (identical(probe._operation, operation)) {
        probe
          .._operation = null
          ..future = null;
        if (identical(_probes[probe.item.key], probe)) _changed();
      }
    }
    return probe;
  }

  Future<void> _resolveMedia(SourceProbeState probe, bool raceMode) async {
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
    final source = catalog.source;
    final data = probe.data = catalog.copyWith(
      episodeIndex: ep,
      lineIndex: preferred,
    );

    if (source == 'internal') {
      // The player resolves internal tokens itself.
      final token = episode.lineAt(preferred)!;
      probe.routeKey = _routeKey(source, token);
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

    // Preferred line first; a token shared by several lines is one route.
    final limit = raceMode
        ? SourceMatchEngine.maxLinesPerCandidate
        : _manualMaxLines;
    final lines = <(int, String)>[];
    final seen = <String>{};
    for (var i = 0; i <= episode.lines.length && lines.length < limit; i++) {
      final line = i == 0 ? preferred : i;
      if (i != 0 && line == preferred) continue;
      if (episode.lineAt(line) case final token? when seen.add(token)) {
        lines.add((line, token));
      }
    }

    final lineOperation = SourceOperation(parent: SourceOperation.current);
    Object? lastError;
    Future<bool> resolve((int, String) line) async {
      final (index, token) = line;
      try {
        return await lineOperation.run(() async {
          final media = await resolveLineMedia(
            sourceKey: source,
            lineToken: token,
          );
          SourceOperation.check();
          if (!MediaReadiness.isAcceptablePlaybackUrl(media.url)) {
            throw StateError('线路返回不可播放地址');
          }
          if (probe.isInstantPlayable) return false;
          data
            ..lineIndex = index
            ..storePrefetched(
              episodeIndex: ep,
              lineIndex: index,
              episodeId: token,
              url: media.url,
              httpHeaders: media.httpHeaders,
            );
          probe
            ..routeKey = _routeKey(source, token)
            ..status = SourceProbeStatus.direct;
          return true;
        });
      } catch (error) {
        lastError = error;
        return false;
      }
    }

    try {
      if (raceMode) {
        await SourceOperation.current!.wait(
          _firstAccepted([for (final line in lines) resolve(line)], (ok) => ok),
        );
      } else {
        for (final line in lines) {
          if (await resolve(line)) break;
          SourceOperation.check();
        }
      }
    } finally {
      // The first playable line wins; its siblings stop here.
      lineOperation
        ..cancel()
        ..close();
    }
    SourceOperation.check();
    if (!probe.isInstantPlayable) throw lastError ?? StateError('无法解析播放地址');
  }

  @protected
  Future<PlaybackMedia> resolveLineMedia({
    required String sourceKey,
    required String lineToken,
  }) async {
    final kind = MediaReadiness.classify(lineToken);
    if (kind == MediaTokenKind.torrent) {
      return (url: lineToken, httpHeaders: const <String, String>{});
    }
    final adapter =
        _repository.adapterFor(sourceKey) ??
        (throw StateError('视频源不可用: $sourceKey'));
    if (kind != MediaTokenKind.directMedia) {
      return adapter.resolvePlaybackMedia(lineToken);
    }
    if (!await adapter.isPlaybackUrlReachable(lineToken)) {
      throw StateError('媒体地址不可访问');
    }
    return (url: lineToken, httpHeaders: adapter.mediaHeadersFor(lineToken));
  }

  String _routeKey(String source, String token) =>
      MediaReadiness.classify(token) == MediaTokenKind.needsResolve
      ? '$source|$token'
      : token;

  /// The candidate's catalog, loaded once per selection and shared by probes.
  Future<PlaybackRequest> resolveVideoData(SourceSearchResult item) =>
      _catalogs.get(item.key, () async {
        if (item.internalData case final data?) {
          return PlaybackRequest.fromMap(
            data,
            source: item.source,
            metadataUpdates: _seedMetadata,
          );
        }
        return await _repository.buildPlaybackRequest(
              item,
              metadata: _seedMetadata,
            ) ??
            (throw StateError(
              'Source returned no playback catalog: ${item.source}',
            ));
      });
}

/// The first result accepted by [test], or the last one when none is.
/// [tasks] must not throw.
Future<T> _firstAccepted<T>(List<Future<T>> tasks, bool Function(T) test) {
  final done = Completer<T>();
  var remaining = tasks.length;
  for (final task in tasks) {
    unawaited(
      task.then((value) {
        if ((test(value) || --remaining == 0) && !done.isCompleted) {
          done.complete(value);
        }
      }),
    );
  }
  return done.future;
}
