import 'package:baka/api/bgm.dart';
import 'package:baka/api/request_cache.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:flutter/foundation.dart';

/// BGM 搜索、详情解析和首页数据转换。
class BgmService {
  static const _scoreCacheDuration = Duration(days: 7);
  static const _memoryCacheLimit = 64;

  /// 分数缓存在 Hive 中持久化 7 天（写时间 TTL 改为读时间 TTL，
  /// 旧格式条目缺少 timestamp 会被视为未命中后自动重写）。
  static final TtlCache _scoreCache = TtlCache(
    AppStorage.bgmCacheBox,
    ttl: _scoreCacheDuration,
  );

  // Map 保持插入顺序；命中时移动到末尾，形成一个轻量 LRU。
  static final _titleCache = RequestCache<String, BgmSubjectInfo?>(
    limit: _memoryCacheLimit,
    shouldCache: (value) => value != null,
  );
  static final _searchCache = RequestCache<String, List<BgmSubjectInfo>>(
    limit: _memoryCacheLimit,
  );
  static final _detailCache = RequestCache<int, BgmSubjectInfo?>(
    limit: _memoryCacheLimit,
    shouldCache: (value) => value != null,
  );

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

    final rawEpisodes = await getBgmEpisodes(subjectId);

    if (episodeIndex >= rawEpisodes.length) return null;
    final episode = rawEpisodes[episodeIndex];
    final nameCn = episode['name_cn'] as String;
    return (
      episodeId: BgmUtils.toInt(episode['id']),
      name: nameCn.isNotEmpty ? nameCn : episode['name'] as String,
    );
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

    final subject = await _titleCache.get(
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
    await _scoreCache.write(cacheKey, {
      'score': info.score,
      'subjectId': info.subjectId,
      'imageUrl': info.imageUrl,
    });
    return info;
  }

  static Future<BgmSubjectInfo?> _findSubject(_SearchTitle original) async {
    BgmSubjectInfo? best;
    BgmSubjectInfo? fallback;
    final candidatesBySubject = <int, List<_SearchTitle>>{};
    var bestMatch = 0;
    var bestRating = -1.0;

    for (final title in BgmUtils.buildSearchTitles([original.original])) {
      final query = _SearchTitle.from(title);
      if (query.normalized.isEmpty) continue;

      final subjects = await _search(query);
      if (subjects.isNotEmpty) fallback ??= subjects.first;

      for (final subject in subjects) {
        final candidates = candidatesBySubject.putIfAbsent(
          subject.subjectId,
          () => [
            for (final title in subject.searchTitles) _SearchTitle.from(title),
          ],
        );
        final match = _matchScore(query, candidates);
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
      return await _searchCache.get(key, () async {
        return _parseSearchResults(await searchBgmAnime(query.original));
      });
    } catch (error) {
      _searchCache.remove(key);
      debugPrint('BGM search failed: $error');
      return const [];
    }
  }

  static int _matchScore(_SearchTitle query, List<_SearchTitle> candidates) {
    int? subjectSeason;
    if (query.season != null) {
      for (final candidate in candidates) {
        if (candidate.season != null) {
          subjectSeason = candidate.season;
          break;
        }
      }
    }
    var best = 0;

    for (final candidate in candidates) {
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

  static Future<BgmSubjectInfo?> _detail(int subjectId) async {
    try {
      return await _detailCache.get(subjectId, () async {
        final detail = await getBgmSubject(subjectId);
        return _subjectFromMap(detail, id: subjectId, hasDetail: true);
      });
    } catch (error) {
      _detailCache.remove(subjectId);
      debugPrint('BGM detail failed: $error');
      return null;
    }
  }

  static List<BgmSubjectInfo> _parseSearchResults(
    List<Map<String, dynamic>> items,
  ) {
    final subjects = <BgmSubjectInfo>[];
    for (final item in items) {
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
    final data = _scoreCache.read(cacheKey);
    if (data is! Map) return null;
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

  static List<Map<String, dynamic>> convertTrendingToAppFormat(
    List<Map<String, dynamic>> bgmData,
  ) => _convertSubjects(bgmData, trending: true);

  static List<Map<String, dynamic>> convertSearchToAppFormat(
    List<Map<String, dynamic>> subjects,
  ) => _convertSubjects(subjects, trending: false);

  static List<Map<String, dynamic>> _convertSubjects(
    List<Map<String, dynamic>> items, {
    required bool trending,
  }) {
    final result = <Map<String, dynamic>>[];
    for (final item in items) {
      final subject = trending ? item['subject'] as Map<String, dynamic> : item;

      final id = BgmUtils.toInt(subject['id']);
      if (id == null || id <= 0) continue;
      final nameCn = BgmUtils.trimmed(subject[trending ? 'nameCN' : 'name_cn']);
      final name = BgmUtils.trimmed(subject['name']);
      final title = nameCn ?? name;
      if (title == null) continue;

      final imageUrl = BgmUtils.pickImageUrl(subject['images']) ?? '';
      final rating = subject['rating'];
      final converted = <String, dynamic>{
        'id': id,
        'title': title,
        'subtitle': nameCn != null && name != null && name != nameCn
            ? name
            : '',
        'content': imageUrl,
        'bgmImageUrl': imageUrl,
        'tag': '动画',
        'sort': trending ? '推荐' : '',
        'status': 'public',
        'time': BgmUtils.trimmed(subject['date']) ?? '',
        'bgmId': id,
        'score': BgmUtils.extractScore(rating) ?? 0.0,
        'rank': trending
            ? BgmUtils.toInt(rating is Map ? rating['rank'] : null) ?? 0
            : BgmUtils.toInt(subject['rank']) ?? 0,
        'summary': BgmUtils.trimmed(subject['summary']) ?? '',
        'eps': subject['eps'] ?? subject['total_episodes'] ?? 0,
        'source': 'bgm',
      };
      if (trending) {
        converted['info'] = BgmUtils.trimmed(subject['info']) ?? '';
        converted['videos'] = '';
      }
      result.add(converted);
    }
    return result;
  }
}

class _SearchTitle {
  static final _spaces = RegExp(r'\s+');

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
      chinese: BgmUtils.chineseOnly(clean),
      season: BgmUtils.extractSeason(clean),
    );
  }

  String get cacheKey =>
      season == null ? normalized : '$normalized#season:$season';
}
