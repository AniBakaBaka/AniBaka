import 'package:baka/utils/bgm_utils.dart';

import 'title_matcher.dart';

/// 参与匹配的候选条目。
///
/// 标题指纹、季度、集数、年份等特征都是 `late final`，
/// 只在首次使用时计算一次；调用方应复用同一实例参与多轮排序。
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
  late final int? episodeCount = _extractEpisodeCount(data);
  late final int? year = _extractYearFromData(data);
  late final bool isMovieLike = _movieRe.hasMatch(title);
  late final bool isTvLike = _tvRe.hasMatch(title);

  static final RegExp _movieRe = RegExp(
    r'剧场版|劇場版|映画|movie|the\s+movie|ova|oad|special',
    caseSensitive: false,
  );
  static final RegExp _tvRe = RegExp(
    r'\btv\b|テレビ|番组|番組|season|第.+[季期]',
    caseSensitive: false,
  );

  static int? _extractEpisodeCount(Map<String, dynamic> data) {
    final videoList = data['videoList'];
    if (videoList is List && videoList.isNotEmpty) return videoList.length;

    final videos = data['videos'];
    if (videos is String && videos.trim().isNotEmpty) {
      final count = videos
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .length;
      if (count > 0) return count;
    }

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

  static int? _extractYearFromData(Map<String, dynamic> data) {
    final detail = data['bgmDetailData'];
    for (final value in [
      data['year'],
      data['date'],
      data['airDate'],
      data['air_date'],
      data['time'],
      if (detail is Map) ...[detail['date'], detail['airDate']],
    ]) {
      final year = extractYear(value?.toString() ?? '');
      if (year != null) return year;
    }
    return null;
  }
}

/// 一次匹配会话的查询上下文。
///
/// 标题池指纹与查询季度在首次访问时计算并缓存，
/// 同一上下文可安全用于整批候选评分。
class SourceMatchContext {
  SourceMatchContext({
    required this.primaryTitle,
    this.manualAliases = const <String>[],
    this.automaticAliases = const <String>[],
    this.bgmEpisodeCount,
    this.bgmCompleted = false,
    this.bgmYear,
    int? querySeason,
    this.sourceReputation = const <String, double>{},
    this.currentSource,
  }) : _explicitSeason = querySeason;

  final String primaryTitle;
  final List<String> manualAliases;
  final List<String> automaticAliases;
  final int? bgmEpisodeCount;
  final bool bgmCompleted;

  /// BGM 放送年份。
  final int? bgmYear;

  /// 源信誉先验，取值 [-1, 1]，见 [SourceReputationService]。
  final Map<String, double> sourceReputation;
  final String? currentSource;

  final int? _explicitSeason;

  late final List<TitleFingerprint> queryFingerprints = [
    for (final title in [primaryTitle, ...manualAliases, ...automaticAliases])
      TitleFingerprint(title),
  ];

  late final int? querySeason = _explicitSeason ?? _seasonFromTitles();

  int? _seasonFromTitles() {
    for (final title in [
      primaryTitle,
      ...manualAliases,
      ...automaticAliases,
    ]) {
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
    required this.consensusSourceCount,
  });

  final SourceMatchCandidate candidate;

  /// 综合置信度 ∈ [0,1]，排序与阈值判断的唯一依据。
  final double confidence;
  final double titleSimilarity;
  final bool seasonConflict;
  final bool severeEpisodeConflict;
  final int consensusSourceCount;

  /// 供 UI 展示的整数分。
  int get score => (confidence * 100).round();

  bool get shouldProbeImmediately =>
      confidence >= 0.8 && !seasonConflict && !severeEpisodeConflict;
}

/// 候选源排序引擎：标题相似度打底，季度/集数/年份/类型等
/// 结构化信号做有界修正，输出单一置信度。
class SourceMatchEngine {
  const SourceMatchEngine();

  List<SourceMatchScore> rank(
    Iterable<SourceMatchCandidate> candidates,
    SourceMatchContext context,
  ) {
    final list = candidates.toList(growable: false);
    final consensus = _consensusBySourceCount(list);
    final scored = [
      for (final candidate in list)
        score(
          candidate,
          context,
          consensusSourceCount:
              consensus[candidate.fingerprint.normalized] ?? 1,
        ),
    ];

    scored.sort((a, b) {
      final byConfidence = b.confidence.compareTo(a.confidence);
      if (byConfidence != 0) return byConfidence;
      return b.titleSimilarity.compareTo(a.titleSimilarity);
    });
    return scored;
  }

  SourceMatchScore score(
    SourceMatchCandidate candidate,
    SourceMatchContext context, {
    int consensusSourceCount = 1,
  }) {
    var similarity = 0.0;
    for (final query in context.queryFingerprints) {
      final value = candidate.fingerprint.similarityTo(query);
      if (value > similarity) similarity = value;
      if (similarity >= 1) break;
    }

    final querySeason = context.querySeason;
    final candidateSeason = candidate.season;
    final seasonConflict = querySeason != null &&
        candidateSeason != null &&
        querySeason != candidateSeason;
    final severeEpisodeConflict = _isSevereEpisodeConflict(
      expected: context.bgmEpisodeCount,
      actual: candidate.episodeCount,
      completed: context.bgmCompleted,
    );

    var confidence = similarity * 0.72 + 0.10;
    confidence += _seasonSignal(querySeason, candidateSeason);
    confidence += _episodeSignal(
      expected: context.bgmEpisodeCount,
      actual: candidate.episodeCount,
      completed: context.bgmCompleted,
    );
    confidence += _yearSignal(context.bgmYear, candidate.year);
    confidence += _formatSignal(candidate, context.bgmEpisodeCount);
    confidence += _consensusSignal(consensusSourceCount);
    confidence += (context.sourceReputation[candidate.sourceType] ?? 0) * 0.03;
    if (candidate.sourceType == context.currentSource) confidence += 0.02;
    if (candidate.episodeCount != null) confidence += 0.02;

    if (seasonConflict) confidence = confidence.clamp(0.0, 0.35);
    if (severeEpisodeConflict) confidence = confidence.clamp(0.0, 0.58);

    return SourceMatchScore(
      candidate: candidate,
      confidence: confidence.clamp(0.0, 1.0),
      titleSimilarity: similarity,
      seasonConflict: seasonConflict,
      severeEpisodeConflict: severeEpisodeConflict,
      consensusSourceCount: consensusSourceCount,
    );
  }

  double _seasonSignal(int? querySeason, int? candidateSeason) {
    if (querySeason == null) return candidateSeason == null ? 0 : -0.01;
    if (candidateSeason == null) return -0.02;
    if (candidateSeason == querySeason) return 0.07;
    return -0.25; // 冲突，之后还会被硬性封顶
  }

  double _episodeSignal({
    required int? expected,
    required int? actual,
    required bool completed,
  }) {
    if (expected == null || expected <= 0 || actual == null || actual <= 0) {
      return 0;
    }
    if (actual == expected) return 0.04;
    if (actual > expected + _tolerance(expected, 0.35, min: 3)) return -0.05;
    if (completed && actual < expected - _tolerance(expected, 0.25, min: 2)) {
      return -0.03;
    }
    if ((actual - expected).abs() <= 1) return 0.02;
    return 0;
  }

  double _yearSignal(int? bgmYear, int? candidateYear) {
    if (bgmYear == null || candidateYear == null) return 0;
    final diff = (bgmYear - candidateYear).abs();
    if (diff == 0) return 0.02;
    if (diff == 1) return 0.01;
    if (diff >= 3) return -0.02;
    return 0;
  }

  double _formatSignal(SourceMatchCandidate candidate, int? bgmEpisodeCount) {
    final expected = bgmEpisodeCount ?? 0;
    if (candidate.isMovieLike) {
      if (expected >= 6 && (candidate.episodeCount ?? 1) <= 2) return -0.05;
      if (expected <= 2 && expected > 0) return 0.03;
      return 0;
    }
    if (candidate.isTvLike && expected > 0 && expected <= 2) return -0.03;
    return 0;
  }

  double _consensusSignal(int sourceCount) {
    if (sourceCount >= 3) return 0.03;
    if (sourceCount >= 2) return 0.02;
    return 0;
  }

  bool _isSevereEpisodeConflict({
    required int? expected,
    required int? actual,
    required bool completed,
  }) {
    if (expected == null || expected <= 0 || actual == null || actual <= 0) {
      return false;
    }
    if (actual > expected + _tolerance(expected, 0.5, min: 3)) return true;
    if (completed && actual < expected / 2) return true;
    return false;
  }

  int _tolerance(int expected, double ratio, {required int min}) {
    final scaled = (expected * ratio).ceil();
    return scaled > min ? scaled : min;
  }

  Map<String, int> _consensusBySourceCount(
    List<SourceMatchCandidate> candidates,
  ) {
    final sourcesByTitle = <String, Set<String>>{};
    for (final candidate in candidates) {
      final title = candidate.fingerprint.normalized;
      if (title.isEmpty) continue;
      (sourcesByTitle[title] ??= <String>{}).add(candidate.sourceType);
    }
    return {
      for (final entry in sourcesByTitle.entries) entry.key: entry.value.length,
    };
  }
}
