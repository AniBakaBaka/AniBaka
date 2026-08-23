import 'package:baka/api/request_cache.dart';
import 'package:baka/services/network_service.dart';

const String _bgmApiBase = 'https://bgm.anibaka.com';
const String _bgmNextBase = 'https://p1.anibaka.com';
const Duration _bgmCacheTtl = Duration(minutes: 5);

final _subjectCache = RequestCache<int, Map<String, dynamic>>(
  limit: 64,
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
final _subjectCommentsCache = RequestCache<String, BgmCommentPage>(
  limit: 4,
  ttl: _bgmCacheTtl,
);
final _episodeCommentsCache = RequestCache<int, List<Map<String, dynamic>>>(
  limit: 8,
  ttl: _bgmCacheTtl,
);

typedef BgmCommentPage = ({List<Map<String, dynamic>> comments, int total});

Future<List<Map<String, dynamic>>> searchBgmAnime(String title) async {
  final response = await NetUtils.postJson<Map<String, dynamic>>(
    '$_bgmApiBase/v0/search/subjects?limit=10&offset=0',
    {
      'keyword': title,
      'sort': 'match',
      'filter': {
        'type': [2],
      },
    },
  );
  return _mapList(response!['data']);
}

Future<Map<String, dynamic>> getBgmSubject(int subjectId) {
  return _subjectCache.get(
    subjectId,
    () async => (await NetUtils.getJson<Map<String, dynamic>>(
      '$_bgmApiBase/v0/subjects/$subjectId',
    ))!,
  );
}

Future<List<Map<String, dynamic>>> getBgmEpisodes(int subjectId) {
  return _episodeCache.get(subjectId, () async {
    final response = await NetUtils.getJson<Map<String, dynamic>>(
      '$_bgmApiBase/v0/episodes?subject_id=$subjectId&type=0&limit=200',
    );
    final episodes = _mapList(response!['data']);
    episodes.sort(
      (left, right) => (left['sort'] as num).compareTo(right['sort'] as num),
    );
    return episodes;
  });
}

/// 角色响应通常远大于条目本身，只由角色页按需读取，不驻留全局缓存。
Future<List<Map<String, dynamic>>> getBgmCharacters(int subjectId) async {
  final response = await NetUtils.getJson<List<dynamic>>(
    '$_bgmApiBase/v0/subjects/$subjectId/characters',
  );
  return _mapList(response);
}

Future<List<Map<String, dynamic>>> getBgmRelatedSubjects(int subjectId) {
  return _relatedCache.get(
    subjectId,
    () async => _mapList(
      await NetUtils.getJson<List<dynamic>>(
        '$_bgmApiBase/v0/subjects/$subjectId/subjects',
      ),
    ),
  );
}

Future<List<Map<String, dynamic>>> getTrendingSubjects({
  int type = 2,
  int limit = 24,
  int offset = 0,
}) async {
  final response = await NetUtils.getJson<Map<String, dynamic>>(
    '$_bgmNextBase/p1/trending/subjects?type=$type&limit=$limit&offset=$offset',
  );
  return _mapList(response!['data']);
}

/// BGM 每日放送（一周更新表）。
///
/// 返回以星期为 key（1=周一 … 7=周日）的 Map，值为
/// `[{subject: {...}, watchers: n}]`，subject 与 trending 接口同构。
Future<Map<String, List<Map<String, dynamic>>>> getBgmCalendar() async {
  final data = (await NetUtils.getJson<Map<String, dynamic>>(
    '$_bgmNextBase/p1/calendar',
  ))!;
  return {for (final entry in data.entries) entry.key: _mapList(entry.value)};
}

Future<BgmCommentPage> getBgmSubjectComments(
  int subjectId, {
  int limit = 20,
  int offset = 0,
}) {
  final cacheKey = '$subjectId:$limit:$offset';
  return _subjectCommentsCache.get(cacheKey, () async {
    final json = (await NetUtils.getJson<Map<String, dynamic>>(
      '$_bgmNextBase/p1/subjects/$subjectId/comments?limit=$limit&offset=$offset',
    ))!;
    return (
      comments: _mapList(json['data']),
      total: (json['total'] as num).toInt(),
    );
  });
}

Future<List<Map<String, dynamic>>> getBgmEpisodeComments(int episodeId) =>
    _episodeCommentsCache.get(
      episodeId,
      () async => _mapList(
        await NetUtils.getJson<List<dynamic>>(
          '$_bgmNextBase/p1/episodes/$episodeId/comments',
        ),
      ),
    );

Future<Map<String, dynamic>> getBgmCharacterInfo(int characterId) async =>
    (await NetUtils.getJson<Map<String, dynamic>>(
      '$_bgmNextBase/p1/characters/$characterId',
    ))!;

Future<List<Map<String, dynamic>>> getBgmCharacterComments(
  int characterId,
) async => _mapList(
  await NetUtils.getJson<List<dynamic>>(
    '$_bgmNextBase/p1/characters/$characterId/comments',
  ),
);

/// 通过标签搜索 BGM 动画
///
/// 使用 BGM v0 搜索 API (POST /v0/search/subjects)
/// [tags] BGM 标签列表（AND 关系）
/// [sort] 排序：rank(排名) / heat(热度) / score(评分) / match(相关)
Future<List<Map<String, dynamic>>> searchBgmByTag(
  List<String> tags, {
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

  final response = await NetUtils.postJson<Map<String, dynamic>>(
    '$_bgmApiBase/v0/search/subjects?limit=$limit&offset=$offset',
    {
      // Bangumi now rejects an empty keyword. `*` keeps this as a filter-only
      // search, so the home "最新" feed and category filters still return data.
      'keyword': '*',
      'sort': sort,
      'filter': filter,
    },
  );
  return _mapList(response!['data']);
}

List<Map<String, dynamic>> _mapList(Object? value) =>
    (value as List<dynamic>).cast<Map<String, dynamic>>();
