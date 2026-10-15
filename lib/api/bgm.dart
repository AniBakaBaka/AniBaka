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
final _searchCache = RequestCache<String, List<BgmSubjectInfo>>(
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

/// Pagination is needed for schedules of long-running series beyond episode 200.
Future<Map<String, dynamic>> getBgmEpisodePage(
  int subjectId, {
  int offset = 0,
}) => apiTransport.getJson<Map<String, dynamic>>(
  '$_bgmApiBase/v0/episodes?subject_id=$subjectId&type=0&limit=200&offset=$offset',
  notifyOnError: false,
);

Future<Map<String, dynamic>> getBgmEpisode(int episodeId) => apiTransport
    .getJson<Map<String, dynamic>>('$_bgmApiBase/v0/episodes/$episodeId');

Future<List<Map<String, dynamic>>> getBgmEpisodes(int subjectId) {
  return _episodeCache.get(subjectId, () async {
    final episodes = <Map<String, dynamic>>[];
    while (true) {
      final response = await getBgmEpisodePage(
        subjectId,
        offset: episodes.length,
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
  });
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

/// BGM 每日放送（一周更新表）。
///
/// 返回以星期为 key（1=周一 … 7=周日）的 Map，值为
/// `[{subject: {...}, watchers: n}]`，subject 与 trending 接口同构。
Future<Map<String, List<Map<String, dynamic>>>> getBgmCalendar() async {
  final data = await apiTransport.getJson<Map<String, dynamic>>(
    '$_bgmNextBase/p1/calendar',
  );
  return {
    for (final entry in data.entries)
      entry.key: (entry.value as List<dynamic>).cast<Map<String, dynamic>>(),
  };
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

  final title = (data['title'] as String? ?? '')
      .replaceAll(_spaces, ' ')
      .trim();
  final normalized = keepTitleUnits(extractBaseTitle(title));
  if (normalized.isEmpty) return const BgmInfo();
  final season = extractSeason(title);
  final cacheKey = season == null
      ? 'bgm_score_$normalized'
      : 'bgm_score_$normalized#season:$season';
  final cached = _scoreCache.read(cacheKey) as Map?;
  if (cached != null) {
    return BgmInfo(
      score: toDouble(cached['score']),
      subjectId: toInt(cached['subjectId']),
      imageUrl: cached['imageUrl'] as String?,
    );
  }

  final subject = await resolveBgmSubject(title: title);
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

Future<List<BgmSubjectInfo>> searchBgmSubjects(String keyword) {
  final clean = keyword.replaceAll(_spaces, ' ').trim();
  if (keepTitleUnits(clean).isEmpty) {
    return SynchronousFuture(const []);
  }
  return _searchCache.get(clean, () async {
    final items = await searchBgm(keyword: clean, limit: 10, sort: 'match');
    return List<BgmSubjectInfo>.generate(
      items.length,
      (index) => BgmSubjectInfo.fromJson(items[index]),
      growable: false,
    );
  });
}

/// 按主线剧集顺序查找评论接口所需的 BGM episode id。
Future<({int? episodeId, String name})?> resolveBgmEpisodeByIndex(
  int subjectId,
  int episodeIndex,
) async {
  if (subjectId <= 0 || episodeIndex < 0) return null;

  final rawEpisodes = await getBgmEpisodes(subjectId);
  if (episodeIndex >= rawEpisodes.length) return null;

  final episode = rawEpisodes[episodeIndex];
  return (
    episodeId: toInt(episode['id']),
    name: trimmed(episode['name_cn']) ?? trimmed(episode['name']) ?? '',
  );
}

/// 按标题搜索条目标识；已知 ID 的调用方直接读取 getBgmSubject。
///
/// 搜索结果本身已含 `score / id / images`，无需再回源拉取整个条目。
Future<BgmSubjectInfo?> resolveBgmSubject({required String title}) async {
  final clean = title.replaceAll(_spaces, ' ').trim();
  if (clean.isEmpty) return null;

  // 标题变体彼此独立，并发发出后再统一打分，省掉串行往返。
  final batches = await Future.wait(
    buildSearchTitles([clean]).map(searchBgmSubjects),
  );

  final query = TitleFingerprint(clean);
  final querySeason = extractSeason(clean);
  BgmSubjectInfo? best;
  var bestScore = 0.0;

  for (final subjects in batches) {
    for (final subject in subjects) {
      var score = 0.0;
      for (final candidate in subject.searchTitles) {
        final similarity = TitleFingerprint(candidate).similarityTo(query);
        if (similarity > score) score = similarity;
      }
      if (querySeason != null) {
        final season = extractSeason(subject.nameCn ?? subject.name ?? '');
        if (season != null && season != querySeason) continue;
        if (season == querySeason) score += 0.4;
      }
      if (score > bestScore) {
        bestScore = score;
        best = subject;
      }
    }
  }
  return best;
}
