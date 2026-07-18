import 'package:baka/api/bgm.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:flutter/foundation.dart';

/// BGM 搜索、详情解析和首页数据转换。
class BgmService {
  static const _scoreCacheDuration = Duration(days: 7);
  static const _memoryCacheLimit = 64;

  // Map 保持插入顺序；命中时移动到末尾，形成一个轻量 LRU。
  static final Map<String, Future<BgmSubjectInfo?>> _titleCache = {};
  static final Map<String, Future<List<BgmSubjectInfo>>> _searchCache = {};
  static final Map<int, Future<BgmSubjectInfo?>> _detailCache = {};

  static final _yearPattern = RegExp(r'\b(19\d{2}|20\d{2})\b');

  static Future<BgmInfo> resolveFromData(Map data) async {
    final existing = BgmUtils.readFromData(data);
    if (existing.subjectId != null) return existing;

    final info = await _fetchScore(
      data['bgmId']?.toString() ?? '',
      data['title']?.toString() ?? '',
    );
    BgmUtils.writeToData(data, info);
    return info;
  }

  static Future<List<BgmSubjectInfo>> searchSubjects(String keyword) async {
    final query = _SearchTitle.from(keyword);
    if (query.normalized.isEmpty) return const [];
    return _search(query);
  }

  /// 按主线剧集顺序查找评论接口所需的 BGM episode id。
  static Future<({int? episodeId, String name})?> resolveEpisodeByIndex(
    int subjectId,
    int episodeIndex,
  ) async {
    if (subjectId <= 0 || episodeIndex < 0) return null;

    final detail =
        getCachedBgmAnimeFullDetail(subjectId) ??
        await getBgmAnimeFullDetail(subjectId);
    final rawEpisodes = detail?['episodes'];
    if (rawEpisodes is! List) return null;

    final episodes = <({double sort, int? id, String name})>[];
    for (final raw in rawEpisodes) {
      if (raw is! Map || (BgmUtils.toInt(raw['type']) ?? 0) != 0) continue;

      final nameCn = raw['name_cn']?.toString() ?? '';
      episodes.add((
        sort: BgmUtils.toDouble(raw['sort']) ?? 0,
        id: BgmUtils.toInt(raw['id']),
        name: nameCn.isNotEmpty ? nameCn : raw['name']?.toString() ?? '',
      ));
    }

    if (episodeIndex >= episodes.length) return null;
    episodes.sort((a, b) => a.sort.compareTo(b.sort));
    final episode = episodes[episodeIndex];
    return (episodeId: episode.id, name: episode.name);
  }

  static int? resolveAirYear(Map<String, dynamic>? detailData) {
    if (detailData == null) return null;

    for (final key in const ['date', 'air_date', 'airDate']) {
      final match = _yearPattern.firstMatch(detailData[key]?.toString() ?? '');
      if (match != null) return int.tryParse(match.group(1)!);
    }
    return null;
  }

  static Future<BgmSubjectInfo?> resolveSubject({
    String bgmId = '',
    String title = '',
    bool withDetail = false,
  }) async {
    final subjectId = int.tryParse(bgmId);
    if (subjectId != null && subjectId > 0) {
      return _detail(subjectId);
    }

    final query = _SearchTitle.from(title);
    if (query.normalized.isEmpty) return null;

    final subject = await _remember(
      _titleCache,
      query.cacheKey,
      () => _findSubject(query),
    );
    if (subject == null) {
      _titleCache.remove(query.cacheKey);
      return null;
    }
    if (!withDetail || subject.hasDetail) return subject;
    return _detail(subject.subjectId);
  }

  static Future<BgmInfo> _fetchScore(String bgmId, String title) async {
    final cacheKey = _scoreCacheKey(bgmId, title);
    if (cacheKey == null) return const BgmInfo();

    final cached = _readCachedScore(cacheKey);
    if (cached != null) return cached;

    final subject = await resolveSubject(
      bgmId: bgmId,
      title: title,
      withDetail: true,
    );
    if (subject == null) return const BgmInfo();

    final info = BgmInfo(
      score: subject.score,
      subjectId: subject.subjectId,
      imageUrl: subject.imageUrl,
    );
    await AppStorage.bgmCacheBox.put(cacheKey, {
      'score': info.score,
      'subjectId': info.subjectId,
      'imageUrl': info.imageUrl,
      'expiry':
          DateTime.now().millisecondsSinceEpoch +
          _scoreCacheDuration.inMilliseconds,
    });
    return info;
  }

  static Future<BgmSubjectInfo?> _findSubject(_SearchTitle original) async {
    BgmSubjectInfo? best;
    BgmSubjectInfo? fallback;
    var bestMatch = 0;
    var bestRating = -1.0;

    for (final title in BgmUtils.buildSearchTitles([original.original])) {
      final query = _SearchTitle.from(title);
      if (query.normalized.isEmpty) continue;

      final subjects = await _search(query);
      if (subjects.isNotEmpty) fallback ??= subjects.first;

      for (final subject in subjects) {
        final match = _matchScore(query, subject);
        final rating = subject.score ?? -1;
        if (match > bestMatch ||
            (match == bestMatch && match > 0 && rating > bestRating)) {
          best = subject;
          bestMatch = match;
          bestRating = rating;
        }
      }
      if (bestMatch >= 100) break;
    }

    return best ?? fallback;
  }

  static Future<List<BgmSubjectInfo>> _search(_SearchTitle query) async {
    final key = query.cacheKey;
    try {
      return await _remember(_searchCache, key, () async {
        final response = await searchBgmAnime(query.original);
        return _parseSearchResults(response.data);
      });
    } catch (error) {
      _searchCache.remove(key);
      debugPrint('BGM search failed: $error');
      return const [];
    }
  }

  static int _matchScore(_SearchTitle query, BgmSubjectInfo subject) {
    final subjectSeason = query.season == null ? null : _subjectSeason(subject);
    var best = 0;

    for (final title in subject.searchTitles) {
      final candidate = _SearchTitle.from(title);
      int score;
      if (query.normalized == candidate.normalized) {
        score = 100;
      } else if (query.chinese.isNotEmpty &&
          query.chinese == candidate.chinese) {
        score = 95;
      } else if (candidate.normalized.contains(query.normalized) ||
          query.normalized.contains(candidate.normalized)) {
        score = 85;
      } else {
        continue;
      }

      if (query.season != null) {
        final candidateSeason = candidate.season ?? subjectSeason;
        if (candidateSeason != null && candidateSeason != query.season) {
          continue;
        }
        if (candidateSeason == query.season) score += 40;
      }

      if (score > best) best = score;
    }
    return best;
  }

  static int? _subjectSeason(BgmSubjectInfo subject) {
    for (final title in subject.lookupTitles) {
      final season = BgmUtils.extractSeason(title);
      if (season != null) return season;
    }
    return null;
  }

  static Future<BgmSubjectInfo?> _detail(int subjectId) async {
    try {
      final subject = await _remember(_detailCache, subjectId, () async {
        final detail =
            getCachedBgmAnimeFullDetail(subjectId) ??
            await getBgmAnimeFullDetail(subjectId);
        return detail == null
            ? null
            : _subjectFromMap(detail, id: subjectId, hasDetail: true);
      });
      if (subject == null) _detailCache.remove(subjectId);
      return subject;
    } catch (error) {
      _detailCache.remove(subjectId);
      debugPrint('BGM detail failed: $error');
      return null;
    }
  }

  static List<BgmSubjectInfo> _parseSearchResults(dynamic responseData) {
    final data = BgmUtils.parseJsonMap(responseData);
    final items = data?['data'] ?? data?['items'] ?? data?['list'];
    if (items is! List) return const [];

    final subjects = <BgmSubjectInfo>[];
    for (final item in items) {
      if (item is! Map) continue;
      final subject = _subjectFromMap(item);
      if (subject != null) subjects.add(subject);
    }
    return subjects;
  }

  static BgmSubjectInfo? _subjectFromMap(
    Map data, {
    int? id,
    bool hasDetail = false,
  }) {
    final subjectId = id ?? BgmUtils.toInt(data['id']);
    if (subjectId == null || subjectId <= 0) return null;

    return BgmSubjectInfo(
      subjectId: subjectId,
      name: BgmUtils.trimmed(data['name']),
      nameCn: BgmUtils.trimmed(data['name_cn']),
      summary: BgmUtils.trimmed(data['summary']),
      imageUrl: BgmUtils.pickImageUrl(data['images']),
      score: BgmUtils.extractScore(data['rating']),
      aliases: _aliases(data['alias']),
      hasDetail: hasDetail,
    );
  }

  static List<String> _aliases(dynamic rawAliases) {
    if (rawAliases is! List) return const [];

    final aliases = <String>[];
    for (final raw in rawAliases) {
      final alias = BgmUtils.trimmed(raw);
      if (alias != null) aliases.add(alias);
    }
    return aliases;
  }

  static BgmInfo? _readCachedScore(String cacheKey) {
    final data = AppStorage.bgmCacheBox.get(cacheKey);
    if (data is! Map) return null;

    final expiry = BgmUtils.toInt(data['expiry']) ?? 0;
    if (expiry <= DateTime.now().millisecondsSinceEpoch) {
      AppStorage.bgmCacheBox.delete(cacheKey);
      return null;
    }
    return BgmInfo(
      score: BgmUtils.toDouble(data['score']),
      subjectId: BgmUtils.toInt(data['subjectId']),
      imageUrl: data['imageUrl']?.toString(),
    );
  }

  static String? _scoreCacheKey(String bgmId, String title) {
    final subjectId = int.tryParse(bgmId);
    if (subjectId != null && subjectId > 0) return 'bgm_score_$subjectId';

    final query = _SearchTitle.from(title);
    return query.normalized.isEmpty ? null : 'bgm_score_${query.cacheKey}';
  }

  static Future<T> _remember<K, T>(
    Map<K, Future<T>> cache,
    K key,
    Future<T> Function() load,
  ) {
    final cached = cache.remove(key);
    if (cached != null) {
      cache[key] = cached;
      return cached;
    }

    if (cache.length >= _memoryCacheLimit) cache.remove(cache.keys.first);
    final future = load();
    cache[key] = future;
    return future;
  }

  static List<Map<String, dynamic>> convertTrendingToAppFormat(
    List<dynamic> bgmData,
  ) => _convertSubjects(bgmData, trending: true);

  static List<Map<String, dynamic>> convertSearchResponseToAppFormat(
    dynamic responseData,
  ) {
    final data = BgmUtils.parseJsonMap(responseData);
    final items = data?['data'] ?? data?['items'];
    return items is List ? _convertSubjects(items, trending: false) : const [];
  }

  static List<Map<String, dynamic>> _convertSubjects(
    List items, {
    required bool trending,
  }) {
    final result = <Map<String, dynamic>>[];
    for (final item in items) {
      final raw = trending && item is Map ? item['subject'] ?? item : item;
      if (raw is! Map) continue;

      final converted = _convertSubject(raw, trending: trending);
      if (converted != null) result.add(converted);
    }
    return result;
  }

  static Map<String, dynamic>? _convertSubject(
    Map subject, {
    required bool trending,
  }) {
    final id = BgmUtils.toInt(subject['id']);
    if (id == null || id <= 0) return null;

    final nameCn = BgmUtils.trimmed(subject[trending ? 'nameCN' : 'name_cn']);
    final name = BgmUtils.trimmed(subject['name']);
    final title = nameCn ?? name;
    if (title == null) return null;

    final imageUrl = BgmUtils.pickImageUrl(subject['images']) ?? '';
    final rating = subject['rating'];
    final rank = trending
        ? BgmUtils.toInt(rating is Map ? rating['rank'] : null) ?? 0
        : BgmUtils.toInt(subject['rank']) ?? 0;

    final converted = <String, dynamic>{
      'id': id,
      'title': title,
      'subtitle': nameCn != null && name != null && name != nameCn ? name : '',
      'content': imageUrl,
      'bgmImageUrl': imageUrl,
      'tag': '动画',
      'sort': trending ? '推荐' : '',
      'status': 'public',
      'time': BgmUtils.trimmed(subject['date']) ?? '',
      'bgmId': id,
      'score': BgmUtils.extractScore(rating) ?? 0.0,
      'rank': rank,
      'summary': BgmUtils.trimmed(subject['summary']) ?? '',
      'eps': subject['eps'] ?? subject['total_episodes'] ?? 0,
      'source': 'bgm',
    };
    if (trending) {
      converted['info'] = BgmUtils.trimmed(subject['info']) ?? '';
      converted['videos'] = '';
    }
    return converted;
  }
}

class _SearchTitle {
  static final _spaces = RegExp(r'\s+');
  static final _chinese = RegExp(r'[\u4e00-\u9fa5]+');

  final String original;
  final String normalized;
  final String chinese;
  final int? season;

  const _SearchTitle({
    required this.original,
    required this.normalized,
    required this.chinese,
    required this.season,
  });

  factory _SearchTitle.from(String title) {
    final clean = title.replaceAll(_spaces, ' ').trim();
    return _SearchTitle(
      original: clean,
      normalized: BgmUtils.normalizeTitle(clean),
      chinese: _chinese.allMatches(clean).map((match) => match[0]!).join(),
      season: BgmUtils.extractSeason(clean),
    );
  }

  String get cacheKey =>
      season == null ? normalized : '$normalized#season:$season';
}
