import 'package:baka/utils/bgm_utils.dart';

class AnimeDetailViewData {
  static final _whitespaceRe = RegExp(r'\s+');

  const AnimeDetailViewData({
    required this.title,
    required this.alias,
    required this.summary,
    required this.coverUrl,
    required this.backgroundUrl,
    required this.tags,
    required this.genres,
    required this.infobox,
    required this.characters,
    required this.scoreCount,
    required this.backdrops,
    required this.posters,
    this.score,
  });

  final String title;
  final String alias;
  final String summary;
  final String coverUrl;
  final String backgroundUrl;
  final List<String> tags;
  final List<String> genres;
  final List<Map<String, dynamic>> infobox;
  final List<Map<String, dynamic>> characters;
  final double? score;
  final int scoreCount;
  final List<Map<String, dynamic>> backdrops;
  final List<Map<String, dynamic>> posters;

  factory AnimeDetailViewData.from({
    required Map source,
    required BgmInfo bgmInfo,
    Map<String, dynamic>? anibaka,
    Map<String, dynamic>? bgm,
  }) {
    final titles = BgmUtils.asMap(anibaka?['title']);
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

    final images = BgmUtils.asMap(anibaka?['images']);
    final posters = _uniqueImages(images?['posters']);
    final backdrops = _uniqueImages(images?['backdrops']);
    final anibakaPoster = _firstImage(posters);
    final cover =
        BgmUtils.resolveCoverImage(source, bgmInfo: bgmInfo) ??
        anibakaPoster ??
        '';

    final genres = (anibaka?['genres'] is List)
        ? (anibaka!['genres'] as List)
              .map(BgmUtils.trimmed)
              .whereType<String>()
              .toList(growable: false)
        : const <String>[];
    // 惰性串联：_unique 是 sync*，take(4) 一命中就停，不再为了取前 4 个
    // 而把 genres + 整张 bgm 标签表 + 拆分后的 source tag 全量展开进一个临时 List。
    final tags = _unique(
      genres
          .cast<String?>()
          .followedBy(
            BgmUtils.asMapList(
              bgm?['tags'],
            ).map((tag) => BgmUtils.trimmed(tag['name'])),
          )
          .followedBy(
            source['tag']?.toString().split(_whitespaceRe) ?? const <String>[],
          ),
    ).take(4).toList(growable: false);

    final ratings = BgmUtils.asMap(anibaka?['ratings']);
    final anibakaRating = BgmUtils.asMap(ratings?['bgm']);
    final bgmRating = BgmUtils.asMap(bgm?['rating']);
    final score =
        BgmUtils.toDouble(anibakaRating?['score']) ??
        BgmUtils.extractScore(bgm?['rating']) ??
        bgmInfo.score;
    final scoreCount =
        BgmUtils.toInt(anibakaRating?['total']) ??
        BgmUtils.toInt(bgmRating?['total']) ??
        0;

    return AnimeDetailViewData(
      title: title,
      alias: alias,
      summary:
          BgmUtils.trimmed(anibaka?['overview']) ??
          BgmUtils.trimmed(bgm?['summary']) ??
          BgmUtils.trimmed(source['content']) ??
          '暂无简介',
      coverUrl: cover,
      backgroundUrl: _firstImage(backdrops) ?? cover,
      tags: tags,
      genres: genres,
      infobox: _mergeInfobox(anibaka, bgm, enTitle, title),
      characters: BgmUtils.asMapList(bgm?['characters']),
      score: score,
      scoreCount: scoreCount,
      backdrops: backdrops,
      posters: posters,
    );
  }

  static String? _imageUrl(Map<String, dynamic>? image) =>
      BgmUtils.trimmed(image?['url']) ?? BgmUtils.trimmed(image?['thumbnail']);

  static String? _firstImage(List<Map<String, dynamic>> images) =>
      images.isEmpty ? null : _imageUrl(images.first);

  static List<Map<String, dynamic>> _uniqueImages(dynamic value) {
    final seen = <String>{};
    return BgmUtils.asMapList(value)
        .where((image) {
          final url = _imageUrl(image);
          return url != null && seen.add(url);
        })
        .toList(growable: false);
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
    final rating = BgmUtils.asMap(BgmUtils.asMap(anibaka?['ratings'])?['bgm']);
    final rank = BgmUtils.toInt(rating?['rank']);
    if (rank != null && rank > 0) add('排名', '#$rank');
    if (englishTitle != title) add('英文名', englishTitle);

    final ids = BgmUtils.asMap(anibaka?['ids']);
    add('IMDb', ids?['imdb_id']);
    add('TMDB', ids?['tmdb_id']);
    add('TVDB', ids?['tvdb_id']);

    for (final item in BgmUtils.asMapList(bgm?['infobox'])) {
      final key = BgmUtils.trimmed(item['key']);
      if (key != null && keys.add(key)) result.add(item);
    }
    return result;
  }
}
