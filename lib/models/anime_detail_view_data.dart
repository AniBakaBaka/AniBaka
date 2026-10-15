import 'package:baka/core/content_filter.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/utils/json_values.dart';
import 'package:baka/utils/bgm_utils.dart';

class AnimeDetailViewData {
  const AnimeDetailViewData._({
    required this.title,
    required this.nsfw,
    required this.bgmTitle,
    required this.alias,
    required this.summary,
    required this.coverUrl,
    required this.logoUrl,
    required this.tags,
    required this.genres,
    required this.infobox,
    required this.scoreCount,
    required this.scoreDistribution,
    required this.backdrops,
    required this.posters,
    required this.status,
    required this.collectCount,
    required this.doingCount,
    required this.wishCount,
    this.score,
    this.rank,
    this.airDate,
    this.episodeCount,
    this.imdbId,
    this.tmdbId,
    this.tvdbId,
    this.bgmId,
  });

  final bool nsfw;
  final String title;
  final String bgmTitle;
  final String alias;
  final String summary;
  final String coverUrl;
  final String logoUrl;
  final List<String> tags;
  final List<String> genres;
  final List<Map<String, dynamic>> infobox;
  final double? score;
  final int scoreCount;

  /// Bangumi 1–10 分人数分布，下标 0 = 1 分。全 0 表示无数据。
  final List<int> scoreDistribution;
  final int? rank;
  final List<String> backdrops;
  final List<String> posters;
  final String status;
  final String? airDate;
  final int? episodeCount;
  final int collectCount;
  final int doingCount;
  final int wishCount;
  final String? imdbId;
  final String? tmdbId;
  final String? tvdbId;
  final int? bgmId;

  String get backgroundUrl => backdrops.isEmpty ? coverUrl : backdrops.first;

  bool get hasScoreDistribution => scoreDistribution.any((count) => count > 0);

  static final _tagSeparator = RegExp(r'\s+');

  factory AnimeDetailViewData.from({
    required Map source,
    required BgmInfo bgmInfo,
    Map<String, dynamic>? anibaka,
    Map<String, dynamic>? bgm,
  }) {
    final titles = anibaka?['title'] as Map<String, dynamic>?;
    final cnTitle = trimmed(titles?['cn'] as String?);
    final nativeTitle = trimmed(titles?['native'] as String?);
    final enTitle = trimmed(titles?['en'] as String?);
    final bgmTitle =
        trimmed(bgm?['name_cn'] as String?) ?? trimmed(bgm?['name'] as String?);
    final title =
        cnTitle ??
        nativeTitle ??
        enTitle ??
        bgmTitle ??
        trimmed(source['title'] as String?) ??
        '番剧详情';

    final alias = nativeTitle != null && nativeTitle != title
        ? nativeTitle
        : (enTitle != null && enTitle != title ? enTitle : '');

    final images = anibaka?['images'] as Map<String, dynamic>?;
    final posters = _imageUrls(images?['posters'] as List<dynamic>?);
    final backdrops = _imageUrls(images?['backdrops'] as List<dynamic>?);
    final cover =
        resolveCoverImage(source, bgmInfo: bgmInfo) ??
        (posters.isNotEmpty ? posters.first : '');

    final genres =
        (anibaka?['genres'] as List<dynamic>?)?.cast<String>() ??
        const <String>[];

    final rawTags = <String>{...genres};
    for (final tag in bgm?['tags'] as List<dynamic>? ?? const []) {
      final name = ((tag as Map<String, dynamic>)['name'] as String).trim();
      if (name.isNotEmpty) rawTags.add(name);
    }
    for (final tag in (source['tag'] as String? ?? '').split(_tagSeparator)) {
      if (tag.isNotEmpty) rawTags.add(tag);
    }

    final ratings = anibaka?['ratings'] as Map<String, dynamic>?;
    final anibakaRating = ratings?['bgm'] as Map<String, dynamic>?;
    final bgmRating = bgm?['rating'] as Map<String, dynamic>?;
    final score =
        (anibakaRating?['score'] as num?)?.toDouble() ??
        BgmUtils.extractScore(bgmRating) ??
        bgmInfo.score;
    final rank = anibakaRating?['rank'] as int?;
    final episodeCount = anibaka?['episodes'] as int?;
    final status = trimmed(anibaka?['status'] as String?);
    final date = trimmed(anibaka?['date'] as String?);
    final ids = anibaka?['ids'] as Map<String, dynamic>?;
    final collection = bgm?['collection'] as Map<String, dynamic>?;

    final bgmInfobox =
        (bgm?['infobox'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    final extraInfo = <Map<String, dynamic>>[
      if (status != null) {'key': '状态', 'value': status},
      if (date != null) {'key': '播出日期', 'value': date},
      if (episodeCount != null && episodeCount > 0)
        {'key': '集数', 'value': '$episodeCount 话'},
      if (rank != null && rank > 0) {'key': '排名', 'value': '#$rank'},
      if (enTitle != null && enTitle != title) {'key': '英文名', 'value': enTitle},
    ];
    var infobox = bgmInfobox;
    if (extraInfo.isNotEmpty) {
      final keys = {for (final item in extraInfo) item['key'] as String};
      for (final item in bgmInfobox) {
        if (keys.add(item['key'] as String)) extraInfo.add(item);
      }
      infobox = extraInfo;
    }

    final scoreCounts = bgmRating?['count'] as Map<String, dynamic>?;
    return AnimeDetailViewData._(
      title: title,
      nsfw: bgm?['nsfw'] == true || ContentFilter.isNsfw(source),
      bgmTitle: bgmTitle ?? title,
      alias: alias,
      summary:
          trimmed(anibaka?['overview'] as String?) ??
          trimmed(bgm?['summary'] as String?) ??
          trimmed(source['content'] as String?) ??
          '暂无简介',
      coverUrl: cover,
      logoUrl: resolveLogoUrl(anibaka),
      tags: rawTags.toList(growable: false),
      genres: genres,
      infobox: infobox,
      score: score,
      scoreCount:
          anibakaRating?['total'] as int? ?? bgmRating?['total'] as int? ?? 0,
      scoreDistribution: scoreCounts == null
          ? const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
          : [
              for (var score = 1; score <= 10; score++)
                scoreCounts['$score'] as int,
            ],
      rank: rank ?? bgmRating?['rank'] as int?,
      backdrops: backdrops,
      posters: posters,
      status: status ?? '',
      airDate: trimmed(bgm?['date'] as String?) ?? date,
      episodeCount: episodeCount ?? bgm?['eps'] as int?,
      collectCount: collection?['collect'] as int? ?? 0,
      doingCount: collection?['doing'] as int? ?? 0,
      wishCount: collection?['wish'] as int? ?? 0,
      imdbId: trimmed(ids?['imdb_id'] as String?),
      tmdbId: (ids?['tmdb_id'] as int?)?.toString(),
      tvdbId: (ids?['tvdb_id'] as int?)?.toString(),
      bgmId: ids?['bgm_id'] as int? ?? bgm?['id'] as int? ?? bgmInfo.subjectId,
    );
  }

  /// 首页横幅只使用 TMDB 剧照，语言优先级与详情 Logo 一致。
  static String? pickTmdbBackdrop(Map<String, dynamic>? detail) {
    final images = detail?['images'] as Map<String, dynamic>?;
    return _preferredImage(
      images?['backdrops'] as List<dynamic>?,
      source: 'tmdb',
    );
  }

  /// 聚合图片优先中文；播放元数据沿用已选定的 logoUrl。
  static String resolveLogoUrl(Map<String, dynamic>? detail) {
    final images = detail?['images'] as Map<String, dynamic>?;
    return _preferredImage(images?['logos'] as List<dynamic>?) ??
        trimmed(detail?['logoUrl'] as String?) ??
        trimmed(detail?['logo'] as String?) ??
        '';
  }

  static String? _preferredImage(List<dynamic>? images, {String? source}) {
    String? first;
    for (final image in images ?? const []) {
      final item = image as Map<String, dynamic>;
      if (source != null && item['source'] != source) continue;
      final url = item['url'] as String;
      if (url.isEmpty) continue;
      first ??= url;
      final lang = (item['lang'] as String?)?.toLowerCase();
      if (lang != null && (lang.startsWith('zh') || lang == 'cn')) return url;
    }
    return first;
  }

  /// 后端可能把首张封面再次放入 posters；按 URL 去重并保留来源顺序。
  static List<String> _imageUrls(List<dynamic>? images) {
    if (images == null || images.isEmpty) return const [];
    final urls = <String>{};
    for (final image in images) {
      final url = (image as Map<String, dynamic>)['url'] as String;
      if (url.isNotEmpty) urls.add(url);
    }
    return urls.toList(growable: false);
  }
}
