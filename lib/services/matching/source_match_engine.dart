import 'package:baka/models/playback_episode.dart';
import 'package:baka/utils/bgm_utils.dart';

import 'title_matcher.dart';

/// 参与匹配的候选条目。特征惰性计算，同一实例可复用多轮排序。
class SourceMatchCandidate {
  SourceMatchCandidate({
    required this.key,
    required this.title,
    required this.sourceType,
    required this.data,
  });

  final String key;
  final String title;
  final String sourceType;
  final Map<String, dynamic> data;

  late final TitleFingerprint fingerprint = TitleFingerprint(title);
  late final int? season = BgmUtils.extractSeason(title);
  late final int? episodeCount = _episodeCount(data);
  late final bool isMovieLike = _movieRe.hasMatch(title);

  static final RegExp _movieRe = RegExp(
    r'剧场版|劇場版|映画|movie|the\s+movie|ova|oad|special',
    caseSensitive: false,
  );

  static int? _episodeCount(Map<String, dynamic> data) {
    final counted = PlaybackEpisodeCatalog.countFrom(data);
    if (counted > 0) return counted;

    for (final key in const [
      'episodeCount',
      'eps',
      'total_episodes',
      'totalEpisodes',
    ]) {
      final value = BgmUtils.toInt(data[key]);
      if (value != null && value > 0) return value;
    }
    return null;
  }
}

/// 一次匹配会话的查询上下文。
class SourceMatchContext {
  SourceMatchContext({
    required this.primaryTitle,
    this.manualAliases = const <String>[],
    this.automaticAliases = const <String>[],
    this.bgmEpisodeCount,
    this.bgmCompleted = false,
    this.currentSource,
    int? querySeason,
  }) : _explicitSeason = querySeason;

  final String primaryTitle;
  final List<String> manualAliases;
  final List<String> automaticAliases;
  final int? bgmEpisodeCount;
  final bool bgmCompleted;
  final String? currentSource;
  final int? _explicitSeason;

  late final List<TitleFingerprint> queryFingerprints = [
    for (final title in [primaryTitle, ...manualAliases, ...automaticAliases])
      if (title.trim().isNotEmpty) TitleFingerprint(title),
  ];

  late final int? querySeason = _explicitSeason ?? _seasonFromTitles();

  int? _seasonFromTitles() {
    for (final title in [primaryTitle, ...manualAliases, ...automaticAliases]) {
      final season = BgmUtils.extractSeason(title);
      if (season != null) return season;
    }
    return null;
  }
}

class SourceMatchScore {
  const SourceMatchScore({
    required this.candidate,
    required this.confidence,
    required this.titleSimilarity,
    required this.seasonConflict,
    required this.severeEpisodeConflict,
  });

  final SourceMatchCandidate candidate;

  /// 综合置信度 ∈ [0,1]，排序与阈值判断的唯一依据。
  final double confidence;
  final double titleSimilarity;
  final bool seasonConflict;
  final bool severeEpisodeConflict;

  /// 供 UI 展示的整数分。
  int get score => (confidence * 100).round();

  /// 结果刚到时立刻发起「目录 + 媒体」探针（竞速优先）。
  bool get shouldProbeImmediately =>
      confidence >= 0.70 && !seasonConflict && !severeEpisodeConflict;

  /// 全源搜索结束后的兜底探针阈值（略放宽，仍拒绝季/集硬冲突）。
  bool get shouldProbeOnFinalPass =>
      confidence >= 0.60 && !seasonConflict && !severeEpisodeConflict;

  /// 标题极高置信：优先插队探测。
  bool get isHighConfidenceTitle =>
      confidence >= 0.82 && !seasonConflict && !severeEpisodeConflict;
}

/// 候选源排序：标题相似度为主，季度/集数/类型做有界修正。
class SourceMatchEngine {
  const SourceMatchEngine();

  List<SourceMatchScore> rank(
    Iterable<SourceMatchCandidate> candidates,
    SourceMatchContext context,
  ) {
    final scored = [for (final c in candidates) score(c, context)];
    scored.sort(compareScores);
    return scored;
  }

  /// 排序比较器：置信度降序，相同时按标题相似度降序。
  static int compareScores(SourceMatchScore a, SourceMatchScore b) {
    final byConf = b.confidence.compareTo(a.confidence);
    return byConf != 0 ? byConf : b.titleSimilarity.compareTo(a.titleSimilarity);
  }

  SourceMatchScore score(
    SourceMatchCandidate candidate,
    SourceMatchContext context,
  ) {
    var similarity = 0.0;
    for (final query in context.queryFingerprints) {
      final v = candidate.fingerprint.similarityTo(query);
      if (v > similarity) similarity = v;
      if (similarity >= 1) break;
    }

    final qSeason = context.querySeason;
    final cSeason = candidate.season;
    final seasonConflict =
        qSeason != null && cSeason != null && qSeason != cSeason;

    final expected = context.bgmEpisodeCount;
    final actual = candidate.episodeCount;
    final severeEpisodeConflict = _severeEpisodeConflict(
      expected: expected,
      actual: actual,
      completed: context.bgmCompleted,
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
      } else if (context.bgmCompleted &&
          actual < expected - _tol(expected, 0.25, 2)) {
        confidence -= 0.04;
      }
    }

    // 剧场版 vs 长篇 TV
    if (candidate.isMovieLike) {
      final eps = expected ?? 0;
      if (eps >= 6 && (actual ?? 1) <= 2) {
        confidence -= 0.08;
      } else if (eps > 0 && eps <= 2) {
        confidence += 0.04;
      }
    }

    if (candidate.sourceType == context.currentSource) confidence += 0.02;

    if (seasonConflict) confidence = confidence.clamp(0.0, 0.28);
    if (severeEpisodeConflict) confidence = confidence.clamp(0.0, 0.32);

    return SourceMatchScore(
      candidate: candidate,
      confidence: confidence.clamp(0.0, 1.0),
      titleSimilarity: similarity,
      seasonConflict: seasonConflict,
      severeEpisodeConflict: severeEpisodeConflict,
    );
  }

  bool _severeEpisodeConflict({
    required int? expected,
    required int? actual,
    required bool completed,
  }) {
    if (expected == null || expected <= 0 || actual == null || actual <= 0) {
      return false;
    }
    if (actual > expected + _tol(expected, 0.5, 3)) return true;
    if (completed && actual < expected / 2) return true;
    return false;
  }

  int _tol(int expected, double ratio, int min) {
    final scaled = (expected * ratio).ceil();
    return scaled > min ? scaled : min;
  }
}
