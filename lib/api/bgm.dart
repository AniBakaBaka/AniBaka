import 'package:baka/models/bgm.dart';
import 'package:baka/utils/json_values.dart';
import 'package:flutter/foundation.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/utils/title_matcher.dart';
import 'package:baka/api/request_cache.dart';
import 'package:baka/core/api_transport.dart';

const String _bgmApiBase = 'https://bgm.anibaka.com';
const String _bgmNextBase = 'https://p1.anibaka.com';
// Cached Maps and Lists are shared read-only; consumers own any mutable UI state.
const Duration _bgmCacheTtl = Duration(minutes: 5);

final _spaces = RegExp(r'\s+');

typedef BgmCommentPage = ({List<Map<String, dynamic>> comments, int total});

final _subjectCache = RequestCache<int, Map<String, dynamic>>(
  limit: 32,
  ttl: _bgmCacheTtl,
);
final _episodeCache = RequestCache<int, List<Map<String, dynamic>>>(
  limit: 8,
  ttl: _bgmCacheTtl,
);
final _relatedCache = RequestCache<int, List<Map<String, dynamic>>>(
  limit: 16,
  ttl: _bgmCacheTtl,
);
final _characterInfoCache = RequestCache<int, Map<String, dynamic>>(
  limit: 16,
  ttl: _bgmCacheTtl,
);
final _characterCommentsCache = RequestCache<int, List<Map<String, dynamic>>>(
  limit: 8,
  ttl: _bgmCacheTtl,
);
final _subjectCommentsCache = RequestCache<(int, int, int), BgmCommentPage>(
  limit: 4,
  ttl: _bgmCacheTtl,
);
final _episodeCommentsCache = RequestCache<int, List<Map<String, dynamic>>>(
  limit: 8,
  ttl: _bgmCacheTtl,
);
final _searchCache = RequestCache<String, List<BgmInfo>>(
  limit: 64,
  ttl: _bgmCacheTtl,
);
final _characterRequests = RequestCache<int, List<Map<String, dynamic>>>(
  limit: 0,
);

/// v0 条目原始响应（含 infobox / tags / rating.count / collection）。
Map<String, dynamic>? peekBgmSubject(int subjectId) =>
    _subjectCache.peek(subjectId);

Future<Map<String, dynamic>> getBgmSubject(
  int subjectId, {
  bool notifyOnError = true,
}) => _subjectCache.get(
  subjectId,
  () => apiTransport.getJson<Map<String, dynamic>>(
    '$_bgmApiBase/v0/subjects/$subjectId',
    notifyOnError: notifyOnError,
  ),
);

Future<Map<String, dynamic>> getBgmEpisode(int episodeId) => apiTransport
    .getJson<Map<String, dynamic>>('$_bgmApiBase/v0/episodes/$episodeId');

Future<List<Map<String, dynamic>>> getBgmEpisodes(
  int subjectId, {
  bool refresh = false,
}) {
  return _episodeCache.get(subjectId, () async {
    final episodes = <Map<String, dynamic>>[];
    while (true) {
      final response = await apiTransport.getJson<Map<String, dynamic>>(
        '$_bgmApiBase/v0/episodes?subject_id=$subjectId&type=0&limit=200&offset=${episodes.length}',
        notifyOnError: false,
      );
      final page = (response['data'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      episodes.addAll(page);
      if (page.isEmpty || episodes.length >= (response['total'] as num)) break;
    }
    episodes.sort(
      (left, right) => (left['sort'] as num).compareTo(right['sort'] as num),
    );
    return episodes;
  }, refresh: refresh);
}

/// 角色响应通常远大于条目本身，只由角色页按需读取，不驻留全局缓存。
Future<List<Map<String, dynamic>>> getBgmCharacters(int subjectId) =>
    _characterRequests.get(
      subjectId,
      () async => (await apiTransport.getJson<List<dynamic>>(
        '$_bgmApiBase/v0/subjects/$subjectId/characters',
      )).cast<Map<String, dynamic>>(),
    );

Future<List<Map<String, dynamic>>> getBgmRelatedSubjects(int subjectId) =>
    _relatedCache.get(
      subjectId,
      () async => (await apiTransport.getJson<List<dynamic>>(
        '$_bgmApiBase/v0/subjects/$subjectId/subjects',
      )).cast<Map<String, dynamic>>(),
    );

Future<List<Map<String, dynamic>>> getTrendingSubjects({
  int type = 2,
  int limit = 24,
  int offset = 0,
}) async {
  final response = await apiTransport.getJson<Map<String, dynamic>>(
    '$_bgmNextBase/p1/trending/subjects?type=$type&limit=$limit&offset=$offset',
  );
  return (response['data'] as List<dynamic>).cast<Map<String, dynamic>>();
}

const _calendarKey = 'home_xinfan_bgm_v3';
final _calendarCache = TtlCache(
  AppStorage.homeCacheBox,
  ttl: const Duration(hours: 24),
);
final _calendarRequests = RequestCache<int, List<List<Map>>>(limit: 0);

/// 首页与排期页共用日历条目；Hive 恢复后只创建类型视图，不复制条目。
List<List<Map>>? peekBgmCalendar({bool allowExpired = false}) {
  final days =
      _calendarCache.read(_calendarKey, allowExpired: allowExpired) as List?;
  return days == null
      ? null
      : List.generate(
          7,
          (day) => (days[day] as List).cast<Map>(),
          growable: false,
        );
}

Future<List<List<Map>>> getBgmCalendar({bool force = false}) {
  final cached = force ? null : peekBgmCalendar();
  if (cached != null) return Future.value(cached);
  return _calendarRequests.get(0, () async {
    final data = await apiTransport.getJson<Map<String, dynamic>>(
      '$_bgmNextBase/p1/calendar',
      notifyOnError: false,
    );
    final days = List.generate(7, (_) => <Map>[], growable: false);
    for (final entry in data.entries) {
      days[int.parse(entry.key) - 1] = convertBgmSubjectsToAppFormat(
        (entry.value as List).cast<Map<String, dynamic>>(),
        trending: true,
      );
    }
    await _calendarCache.write(_calendarKey, days);
    return days;
  });
}

Future<BgmCommentPage> getBgmSubjectComments(
  int subjectId, {
  int limit = 20,
  int offset = 0,
}) {
  final cacheKey = (subjectId, limit, offset);
  return _subjectCommentsCache.get(cacheKey, () async {
    final json = await apiTransport.getJson<Map<String, dynamic>>(
      '$_bgmNextBase/p1/subjects/$subjectId/comments?limit=$limit&offset=$offset',
    );
    return (
      comments: (json['data'] as List<dynamic>).cast<Map<String, dynamic>>(),
      total: (json['total'] as num).toInt(),
    );
  });
}

Future<List<Map<String, dynamic>>> getBgmEpisodeComments(int episodeId) =>
    _episodeCommentsCache.get(
      episodeId,
      () async => (await apiTransport.getJson<List<dynamic>>(
        '$_bgmNextBase/p1/episodes/$episodeId/comments',
      )).cast<Map<String, dynamic>>(),
    );

Future<Map<String, dynamic>> getBgmCharacterInfo(int characterId) =>
    _characterInfoCache.get(
      characterId,
      () => apiTransport.getJson<Map<String, dynamic>>(
        '$_bgmNextBase/p1/characters/$characterId',
      ),
    );

Future<List<Map<String, dynamic>>> getBgmCharacterComments(int characterId) =>
    _characterCommentsCache.get(
      characterId,
      () async => (await apiTransport.getJson<List<dynamic>>(
        '$_bgmNextBase/p1/characters/$characterId/comments',
      )).cast<Map<String, dynamic>>(),
    );

/// Bangumi v0 动画搜索。标签、日期条件均为 AND；分页放在 query 中。
Future<List<Map<String, dynamic>>> searchBgm({
  String keyword = '*',
  List<String> tags = const [],
  int limit = 25,
  int offset = 0,
  String sort = 'rank',
  List<String>? airDate,
}) async {
  final filter = <String, dynamic>{
    'type': [2],
  };
  if (tags.isNotEmpty) filter['tag'] = tags;
  if (airDate != null && airDate.isNotEmpty) filter['air_date'] = airDate;

  final response = await apiTransport.postJson<Map<String, dynamic>>(
    '$_bgmApiBase/v0/search/subjects?limit=$limit&offset=$offset',
    {
      // Bangumi rejects an empty keyword. `*` keeps this a filter-only search.
      'keyword': keyword,
      'sort': sort,
      'filter': filter,
    },
  );
  return (response['data'] as List<dynamic>).cast<Map<String, dynamic>>();
}

const _scoreCacheDuration = Duration(days: 7);

/// 分数在 Hive 中持久化 7 天（读时间 TTL），避免列表反复按标题回源搜索。
final TtlCache _scoreCache = TtlCache(
  AppStorage.bgmCacheBox,
  ttl: _scoreCacheDuration,
);

Future<BgmInfo> resolveBgmFromData(Map data) async {
  final existing = BgmInfo.fromData(data);
  if (existing.subjectId != null) return existing;
  return await resolveBgmSubject(title: data['title'] as String? ?? '') ??
      const BgmInfo();
}

Future<List<BgmInfo>> searchBgmSubjects(String keyword) {
  final clean = keyword.replaceAll(_spaces, ' ').trim();
  if (keepTitleUnits(clean).isEmpty) {
    return SynchronousFuture(const []);
  }
  return _searchCache.get(clean, () async {
    final items = await searchBgm(keyword: clean, limit: 10, sort: 'match');
    return List<BgmInfo>.generate(
      items.length,
      (index) => BgmInfo.fromJson(items[index]),
      growable: false,
    );
  });
}

/// 按标题搜索条目标识；已知 ID 的调用方直接读取 getBgmSubject。
///
/// 搜索结果本身已含 `score / id / images`，无需再回源拉取整个条目。
Future<BgmInfo?> resolveBgmSubject({required String title}) async {
  final clean = title.replaceAll(_spaces, ' ').trim();
  final normalized = keepTitleUnits(extractBaseTitle(clean));
  if (normalized.isEmpty) return null;

  final querySeason = extractSeason(clean);
  final cacheKey = querySeason == null
      ? 'bgm_score_$normalized'
      : 'bgm_score_$normalized#season:$querySeason';
  if (_scoreCache.read(cacheKey) case final Map cached) {
    return BgmInfo(
      score: toDouble(cached['score']),
      subjectId: toInt(cached['subjectId']),
      imageUrl: cached['imageUrl'] as String?,
      summary: cached['summary'] as String?,
    );
  }

  final batches = await Future.wait(
    buildSearchTitles([clean]).map(searchBgmSubjects),
  );

  final query = TitleFingerprint(clean);
  final seen = <int>{};
  BgmInfo? best;
  var bestScore = 0.0;

  for (final subjects in batches) {
    for (final subject in subjects) {
      final id = subject.subjectId;
      if (id == null || !seen.add(id)) continue;
      var score = _titleSimilarity(query, subject.nameCn);
      final nameScore = _titleSimilarity(query, subject.name);
      if (nameScore > score) score = nameScore;

      if (querySeason != null) {
        final season = extractSeason(subject.displayTitle);
        if (season != null && season != querySeason) continue;
        if (season == querySeason) score += 0.4;
      }
      if (score > bestScore) {
        bestScore = score;
        best = subject;
      }
    }
  }
  if (best != null) {
    await _scoreCache.write(cacheKey, {
      'score': best.score,
      'subjectId': best.subjectId,
      'imageUrl': best.imageUrl,
      'summary': best.summary,
    });
  }
  return best;
}

double _titleSimilarity(TitleFingerprint query, String? candidate) {
  if (candidate == null || candidate.isEmpty) return 0;
  final score = TitleFingerprint(candidate).similarityTo(query);
  final base = extractBaseTitle(candidate);
  if (base == candidate) return score;
  final baseScore = TitleFingerprint(base).similarityTo(query);
  return baseScore > score ? baseScore : score;
}
