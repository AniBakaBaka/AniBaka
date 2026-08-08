import 'package:baka/utils/bgm_utils.dart';

class AnimeDetailViewData {
  static final _whitespaceRe = RegExp(r'\s+');

  const AnimeDetailViewData({
    required this.title,
    required this.bgmTitle,
    required this.alias,
    required this.summary,
    required this.coverUrl,
    required this.backgroundUrl,
    required this.logoUrl,
    required this.tags,
    required this.genres,
    required this.infobox,
    required this.characters,
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

  final String title;
  final String bgmTitle;
  final String alias;
  final String summary;
  final String coverUrl;
  final String backgroundUrl;
  final String logoUrl;
  final List<String> tags;
  final List<String> genres;
  final List<Map<String, dynamic>> infobox;
  final List<Map<String, dynamic>> characters;
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

  bool get hasScoreDistribution =>
      scoreDistribution.length == 10 && scoreDistribution.any((c) => c > 0);

  factory AnimeDetailViewData.from({
    required Map source,
    required BgmInfo bgmInfo,
    Map<String, dynamic>? anibaka,
    Map<String, dynamic>? bgm,
    List<Map<String, dynamic>> characters = const [],
  }) {
    final titles = anibaka?['title'] as Map<String, dynamic>?;
    final nativeTitle = BgmUtils.trimmed(titles?['native']);
    final cnTitle = BgmUtils.trimmed(titles?['cn']);
    final enTitle = BgmUtils.trimmed(titles?['en']);
    final fallbackTitle =
        BgmUtils.trimmed(bgm?['name_cn']) ??
        BgmUtils.trimmed(bgm?['name']) ??
        BgmUtils.trimmed(source['title']) ??
        '番剧详情';
    final title = cnTitle ?? nativeTitle ?? enTitle ?? fallbackTitle;
    final alias =
        <String?>[nativeTitle, enTitle, BgmUtils.trimmed(bgm?['name'])]
            .whereType<String>()
            .firstWhere((value) => value != title, orElse: () => '');

    final images = anibaka?['images'] as Map<String, dynamic>?;
    final posters = _imageUrls(images?['posters']);
    final backdrops = _imageUrls(images?['backdrops']);
    final logos = _imageUrls(images?['logos'] ?? images?['logo']);
    final logoUrl =
        _first(logos) ??
        BgmUtils.trimmed(anibaka?['logoUrl']) ??
        BgmUtils.trimmed(anibaka?['logo']) ??
        '';
    final anibakaPoster = _first(posters);
    final cover =
        BgmUtils.resolveCoverImage(source, bgmInfo: bgmInfo) ??
        anibakaPoster ??
        '';

    final genres = (anibaka?['genres'] as List<dynamic>? ?? const [])
        .cast<String>();
    // 完整标签列表（分类 + BGM tags + 源 tag），桌面端展示不再截断。
    final tags = _unique(
      genres
          .cast<String?>()
          .followedBy(
            (bgm?['tags'] as List<dynamic>? ?? const [])
                .cast<Map<String, dynamic>>()
                .map((tag) => BgmUtils.trimmed(tag['name'])),
          )
          .followedBy(
            source['tag']?.toString().split(_whitespaceRe) ?? const <String>[],
          ),
    ).toList(growable: false);

    final ratings = anibaka?['ratings'] as Map<String, dynamic>?;
    final anibakaRating = ratings?['bgm'] as Map<String, dynamic>?;
    final bgmRating = bgm?['rating'] as Map<String, dynamic>?;
    final score =
        BgmUtils.toDouble(anibakaRating?['score']) ??
        BgmUtils.extractScore(bgm?['rating']) ??
        bgmInfo.score;
    final scoreCount =
        BgmUtils.toInt(anibakaRating?['total']) ??
        BgmUtils.toInt(bgmRating?['total']) ??
        0;
    final rank =
        BgmUtils.toInt(anibakaRating?['rank']) ??
        BgmUtils.toInt(bgmRating?['rank']);
    final scoreDistribution = _scoreDistribution(
      (bgmRating?['count'] ?? anibakaRating?['count']) as Map<String, dynamic>?,
    );

    final ids = anibaka?['ids'] as Map<String, dynamic>?;
    final imdbId =
        BgmUtils.trimmed(ids?['imdb_id']) ??
        BgmUtils.trimmed(anibaka?['imdb_id']);
    final tmdbId =
        BgmUtils.trimmed(ids?['tmdb_id']) ??
        BgmUtils.trimmed(anibaka?['tmdb_id']);
    final tvdbId =
        BgmUtils.trimmed(ids?['tvdb_id']) ??
        BgmUtils.trimmed(anibaka?['tvdb_id']);
    final bgmId =
        BgmUtils.toInt(anibaka?['bgm_id']) ??
        BgmUtils.toInt(bgm?['id']) ??
        BgmUtils.toInt(source['bgmId']) ??
        BgmUtils.toInt(source['id']);
    final bgmTitle =
        BgmUtils.trimmed(bgm?['name_cn']) ??
        BgmUtils.trimmed(bgm?['name']) ??
        title;
    final collection = bgm?['collection'] as Map<String, dynamic>?;

    return AnimeDetailViewData(
      title: title,
      bgmTitle: bgmTitle,
      alias: alias,
      summary:
          BgmUtils.trimmed(anibaka?['overview']) ??
          BgmUtils.trimmed(bgm?['summary']) ??
          BgmUtils.trimmed(source['content']) ??
          '暂无简介',
      coverUrl: cover,
      backgroundUrl: _first(backdrops) ?? cover,
      logoUrl: logoUrl,
      tags: tags,
      genres: genres,
      infobox: _mergeInfobox(anibaka, bgm, enTitle, title),
      characters: characters,
      score: score,
      scoreCount: scoreCount,
      scoreDistribution: scoreDistribution,
      rank: rank,
      backdrops: backdrops,
      posters: posters,
      status: BgmUtils.trimmed(anibaka?['status']) ?? '',
      airDate:
          BgmUtils.trimmed(bgm?['date']) ?? BgmUtils.trimmed(anibaka?['date']),
      episodeCount:
          BgmUtils.toInt(anibaka?['episodes']) ??
          BgmUtils.toInt(bgm?['total_episodes']) ??
          BgmUtils.toInt(bgm?['eps']),
      collectCount: BgmUtils.toInt(collection?['collect']) ?? 0,
      doingCount: BgmUtils.toInt(collection?['doing']) ?? 0,
      wishCount: BgmUtils.toInt(collection?['wish']) ?? 0,
      imdbId: imdbId,
      tmdbId: tmdbId,
      tvdbId: tvdbId,
      bgmId: bgmId,
    );
  }

  /// 解析 Bangumi `rating.count` → 长度 10 的人数列表。
  static List<int> _scoreDistribution(Map<String, dynamic>? countMap) {
    if (countMap == null || countMap.isEmpty) {
      return const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    }
    return List<int>.generate(10, (i) {
      final key = '${i + 1}';
      return BgmUtils.toInt(countMap[key]) ?? 0;
    }, growable: false);
  }

  static String? _first(List<String> images) =>
      images.isEmpty ? null : images.first;

  static List<String> _imageUrls(dynamic value) {
    if (value is! List) return const [];
    final seen = <String>{};
    final ranked = <({String url, int score})>[];
    for (final item in value.cast<Map<String, dynamic>>()) {
      final url =
          BgmUtils.trimmed(item['url']) ?? BgmUtils.trimmed(item['thumbnail']);
      if (url != null && seen.add(url)) {
        final lang = (item['lang'] ?? item['language'] ?? '')
            .toString()
            .toLowerCase();
        ranked.add((url: url, score: _imageLanguageScore(lang, url)));
      }
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    return [for (final image in ranked) image.url];
  }

  static int _imageLanguageScore(String lang, String url) {
    if (lang == 'zh' ||
        lang == 'cn' ||
        lang == 'zh-cn' ||
        lang == 'zh-tw' ||
        lang == 'zh-hk') {
      return 100;
    }
    if (url.contains('/zh/') ||
        url.contains('/cn/') ||
        url.contains('_zh.') ||
        url.contains('_cn.')) {
      return 90;
    }
    if (lang == 'ja' || lang == 'jp' || lang == 'native') return 80;
    if (url.contains('/ja/') || url.contains('/jp/') || url.contains('_ja.')) {
      return 70;
    }
    if (lang == 'en' || url.contains('/en/') || url.contains('_en.')) return 10;
    return 50;
  }

  static Iterable<String> _unique(Iterable<String?> values) sync* {
    final seen = <String>{};
    for (final value in values) {
      final text = value?.trim() ?? '';
      if (text.isNotEmpty && seen.add(text)) yield text;
    }
  }

  static List<Map<String, dynamic>> _mergeInfobox(
    Map<String, dynamic>? anibaka,
    Map<String, dynamic>? bgm,
    String? englishTitle,
    String title,
  ) {
    final result = <Map<String, dynamic>>[];
    final keys = <String>{};

    void add(String key, dynamic value) {
      final text = BgmUtils.trimmed(value);
      if (text != null && keys.add(key)) {
        result.add({'key': key, 'value': text});
      }
    }

    add('状态', anibaka?['status']);
    add('播出日期', anibaka?['date']);
    final episodeCount = BgmUtils.toInt(anibaka?['episodes']);
    if (episodeCount != null && episodeCount > 0) add('集数', '$episodeCount 话');
    final ratings = anibaka?['ratings'] as Map<String, dynamic>?;
    final rating = ratings?['bgm'] as Map<String, dynamic>?;
    final rank = BgmUtils.toInt(rating?['rank']);
    if (rank != null && rank > 0) add('排名', '#$rank');
    if (englishTitle != title) add('英文名', englishTitle);

    const filteredKeys = {
      'imdb',
      'imdb_id',
      'tmdb',
      'tmdb_id',
      'tvdb',
      'tvdb_id',
      'bangumi',
      'bgm',
    };

    for (final item
        in (bgm?['infobox'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()) {
      final key = BgmUtils.trimmed(item['key']);
      if (key != null) {
        final lowerKey = key.toLowerCase();
        if (!filteredKeys.contains(lowerKey) && keys.add(key)) {
          result.add(item);
        }
      }
    }
    return result;
  }
}
