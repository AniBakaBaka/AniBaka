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
    // 与播放器目录同一个扫描器：过去这里手抄了一份，对 videoList 还漏了空串过滤。
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

  bool get shouldProbeImmediately =>
      confidence >= 0.8 && !seasonConflict && !severeEpisodeConflict;
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

    // 标题主导；结构化信号只做小幅修正，冲突用硬顶。
    var confidence = similarity * 0.85 + 0.05;

    if (qSeason != null && cSeason != null) {
      confidence += cSeason == qSeason ? 0.08 : -0.20;
    }

    if (expected != null && expected > 0 && actual != null && actual > 0) {
      final diff = (actual - expected).abs();
      if (diff == 0) {
        confidence += 0.05;
      } else if (diff == 1) {
        confidence += 0.02;
      } else if (actual > expected + _tol(expected, 0.35, 3)) {
        confidence -= 0.05;
      } else if (context.bgmCompleted &&
          actual < expected - _tol(expected, 0.25, 2)) {
        confidence -= 0.03;
      }
    }

    // 剧场版 vs 长篇 TV
    if (candidate.isMovieLike) {
      final eps = expected ?? 0;
      if (eps >= 6 && (actual ?? 1) <= 2) {
        confidence -= 0.06;
      } else if (eps > 0 && eps <= 2) {
        confidence += 0.03;
      }
    }

    if (candidate.sourceType == context.currentSource) confidence += 0.02;

    if (seasonConflict) confidence = confidence.clamp(0.0, 0.35);
    if (severeEpisodeConflict) confidence = confidence.clamp(0.0, 0.58);

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
