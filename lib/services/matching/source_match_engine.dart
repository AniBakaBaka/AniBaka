import 'package:baka/source/models/source_search_result.dart';

import 'package:baka/utils/title_matcher.dart';

/// 一次匹配会话的查询上下文。
class SourceMatchContext {
  SourceMatchContext({
    required this.primaryTitle,
    this.manualAliases = const <String>[],
    this.automaticAliases = const <String>[],
    this.bgmEpisodeCount,
    int? querySeason,
  }) : _explicitSeason = querySeason;

  final String primaryTitle;
  final List<String> manualAliases;
  final List<String> automaticAliases;
  final int? bgmEpisodeCount;
  final int? _explicitSeason;

  Iterable<String> get titles sync* {
    yield primaryTitle;
    yield* manualAliases;
    yield* automaticAliases;
  }

  late final List<TitleFingerprint> queryFingerprints = _uniqueFingerprints();

  List<TitleFingerprint> _uniqueFingerprints() {
    final seen = <String>{};
    final result = <TitleFingerprint>[];
    for (final title in titles) {
      final fingerprint = TitleFingerprint(title);
      if (!fingerprint.isEmpty && seen.add(fingerprint.normalized)) {
        result.add(fingerprint);
      }
    }
    return result;
  }

  late final int? querySeason = _explicitSeason ?? _seasonFromTitles();

  int? _seasonFromTitles() {
    for (final title in titles) {
      final season = extractSeason(title);
      if (season != null) return season;
    }
    return null;
  }
}

class SourceMatchScore {
  SourceMatchScore._(
    this._baseConfidence, {
    required this.candidate,
    required this.titleSimilarity,
    required this.seasonConflict,
    required this.severeEpisodeConflict,
  }) : confidence = _cap(
         _baseConfidence,
         seasonConflict,
         severeEpisodeConflict,
       );

  final SourceSearchResult candidate;

  /// 综合置信度 ∈ [0,1]，排序与阈值判断的唯一依据。
  final double confidence;
  final double titleSimilarity;
  final bool seasonConflict;
  final bool severeEpisodeConflict;
  // Before the conflict caps, so the switching UI can add its current-source
  // bonus without redoing title/episode work or changing cap ordering.
  final double _baseConfidence;

  int scoreForCurrentSource(String? currentSource) =>
      (_cap(
                _baseConfidence +
                    (candidate.source == currentSource ? 0.02 : 0),
                seasonConflict,
                severeEpisodeConflict,
              ) *
              100)
          .round();

  static double _cap(double value, bool season, bool episode) {
    if (season) value = value.clamp(0.0, 0.28);
    if (episode) value = value.clamp(0.0, 0.32);
    return value.clamp(0.0, 1.0);
  }

  /// 供 UI 展示的整数分。
  int get score => (confidence * 100).round();

  /// 结果刚到时立刻发起「目录 + 媒体」探针。
  bool get shouldProbeImmediately =>
      confidence >= SourceMatchEngine.immediateProbeConfidence &&
      !seasonConflict &&
      !severeEpisodeConflict;
}

/// 候选源排序：标题相似度为主，季度/集数/类型做有界修正。
class SourceMatchEngine {
  const SourceMatchEngine();

  static final _movieRe = RegExp(
    r'剧场版|劇場版|映画|movie|the\s+movie|ova|oad|special',
    caseSensitive: false,
  );

  /// 结果刚到达时的展示准入：低于此分的结果不进入列表。
  static const double admissionConfidence = 0.18;

  /// 结果刚到时立刻发起「目录 + 媒体」探针（唯一的探针准入线）。
  static const double immediateProbeConfidence = 0.70;

  /// 自动匹配探针并发（同时按「手动点选」路径处理的候选数）。
  static const int raceConcurrency = 6;

  /// 单候选竞速最多尝试的线路数。
  static const int maxLinesPerCandidate = 2;

  /// 每个源最多探针数，防止单源结果挤占全部探针名额。
  static const int raceProbesPerSource = 2;

  /// 自动匹配全局探针上限。
  static const int maxAutoProbes = 16;

  /// 单个源搜索上限，避免无响应源拖住整轮匹配。
  static const Duration sourceSearchBudget = Duration(seconds: 8);

  /// 自动匹配与聚合搜索共用的源搜索并发上限。
  static const int autoSearchConcurrency = 10;

  /// 自动匹配绝对上限：到时无论是否命中都要给出结论。
  static const Duration hardDeadline = Duration(seconds: 10);

  /// 排序比较器：置信度降序，相同时按标题相似度降序。
  static int compareScores(SourceMatchScore a, SourceMatchScore b) {
    final byConf = b.confidence.compareTo(a.confidence);
    return byConf != 0
        ? byConf
        : b.titleSimilarity.compareTo(a.titleSimilarity);
  }

  SourceMatchScore score(
    SourceSearchResult candidate,
    SourceMatchContext context,
  ) {
    final fingerprint = TitleFingerprint(candidate.title);
    var similarity = 0.0;
    for (final query in context.queryFingerprints) {
      final v = fingerprint.similarityTo(query);
      if (v > similarity) similarity = v;
      if (similarity >= 1) break;
    }

    final qSeason = context.querySeason;
    final cSeason = qSeason == null ? null : extractSeason(candidate.title);
    final seasonConflict =
        qSeason != null && cSeason != null && qSeason != cSeason;

    final expected = context.bgmEpisodeCount;
    final hasEpisodeCount = expected != null && expected > 0;
    final actual = hasEpisodeCount ? candidate.episodeCount : null;
    final severeEpisodeConflict = _severeEpisodeConflict(
      expected: expected,
      actual: actual,
    );

    // 标题主导；精确命中额外加权，低相似度强惩罚。
    var confidence = similarity * 0.88;
    if (similarity >= 0.98) {
      confidence += 0.08;
    } else if (similarity >= 0.90) {
      confidence += 0.04;
    } else if (similarity < 0.40) {
      confidence *= 0.45;
    }

    if (qSeason != null && cSeason != null) {
      confidence += cSeason == qSeason ? 0.10 : -0.22;
    } else if (qSeason != null && cSeason == null && similarity >= 0.85) {
      // 候选无季号但标题很像：轻微加分，避免被有错误季号的条目挤掉。
      confidence += 0.02;
    }

    if (expected != null && expected > 0 && actual != null && actual > 0) {
      final diff = (actual - expected).abs();
      if (diff == 0) {
        confidence += 0.06;
      } else if (diff == 1) {
        confidence += 0.03;
      } else if (actual > expected + _tol(expected, 0.35, 3)) {
        confidence -= 0.06;
      }
    }

    // 剧场版 vs 长篇 TV
    if (hasEpisodeCount && _movieRe.hasMatch(candidate.title)) {
      final eps = expected;
      if (eps >= 6 && (actual ?? 1) <= 2) {
        confidence -= 0.08;
      } else if (eps > 0 && eps <= 2) {
        confidence += 0.04;
      }
    }

    return SourceMatchScore._(
      confidence,
      candidate: candidate,
      titleSimilarity: similarity,
      seasonConflict: seasonConflict,
      severeEpisodeConflict: severeEpisodeConflict,
    );
  }

  bool _severeEpisodeConflict({required int? expected, required int? actual}) {
    if (expected == null || expected <= 0 || actual == null || actual <= 0) {
      return false;
    }
    if (actual > expected + _tol(expected, 0.5, 3)) return true;
    return false;
  }

  int _tol(int expected, double ratio, int min) {
    final scaled = (expected * ratio).ceil();
    return scaled > min ? scaled : min;
  }
}
