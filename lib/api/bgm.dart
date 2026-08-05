import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/services/network_service.dart';

const String _bgmApiBase = 'https://bgm.anibaka.com';
const String _bgmNextBase = 'https://p1.anibaka.com';
const Duration _bgmSessionCacheTtl = Duration(minutes: 15);

final Map<int, _CachedBgmResponse<Map<String, dynamic>>> _fullDetailCache =
    <int, _CachedBgmResponse<Map<String, dynamic>>>{};
final Map<int, Future<Map<String, dynamic>?>> _fullDetailInFlight =
    <int, Future<Map<String, dynamic>?>>{};
final Map<int, Future<Map<String, dynamic>?>> _pageDetailCache = {};
final Map<String, _CachedBgmResponse<String>> _subjectCommentsCache =
    <String, _CachedBgmResponse<String>>{};
final Map<String, _CachedBgmResponse<String>> _episodeCommentsCache =
    <String, _CachedBgmResponse<String>>{};

Future<Response> searchBgmAnime(String title) {
  return _post('$_bgmApiBase/v0/search/subjects?limit=10&offset=0', {
    'keyword': title,
    'sort': 'match',
    'filter': {
      'type': [2],
    },
  });
}

Map<String, dynamic>? getCachedBgmAnimeFullDetail(int subjectId) {
  final cached = _fullDetailCache[subjectId];
  if (cached != null && !cached.isExpired) {
    return cached.data;
  }
  return null;
}

Future<Map<String, dynamic>?> getBgmAnimeFullDetail(int subjectId) async {
  final cached = _fullDetailCache[subjectId];
  if (cached != null && !cached.isExpired) {
    return cached.data;
  }

  final inFlight = _fullDetailInFlight[subjectId];
  if (inFlight != null) {
    return inFlight;
  }

  final future = _loadBgmAnimeFullDetail(subjectId);
  _fullDetailInFlight[subjectId] = future;
  try {
    return await future;
  } finally {
    _fullDetailInFlight.remove(subjectId);
  }
}

/// 详情页的轻量补充数据：不下载已不展示的剧集列表。
Future<Map<String, dynamic>?> getBgmAnimePageDetail(int subjectId) async {
  final future = _pageDetailCache[subjectId] ??= _loadBgmAnimePageDetail(
    subjectId,
  );
  try {
    final data = await future;
    if (data == null) _pageDetailCache.remove(subjectId);
    return data;
  } catch (_) {
    _pageDetailCache.remove(subjectId);
    return null;
  }
}

Future<Map<String, dynamic>?> _loadBgmAnimePageDetail(int subjectId) async {
  final responses = await Future.wait([
    _get('$_bgmApiBase/v0/subjects/$subjectId?responseGroup=large'),
    _get('$_bgmApiBase/v0/subjects/$subjectId/characters'),
  ]);
  final data = BgmUtils.parseJsonMap(responses[0].data);
  if (data == null) return null;
  data['characters'] = BgmUtils.parseJsonList(responses[1].data);
  return data;
}

Future<Map<String, dynamic>?> _loadBgmAnimeFullDetail(int subjectId) async {
  final baseResponse = await _get(
    '$_bgmApiBase/v0/subjects/$subjectId?responseGroup=large',
  );
  final baseData = BgmUtils.parseJsonMap(baseResponse.data);
  if (baseData == null) return null;

  final tags = baseData['tags'];
  if (tags is List) {
    tags.sort((a, b) {
      final aCount = (a is Map ? a['count'] : null);
      final bCount = (b is Map ? b['count'] : null);
      return ((bCount is num ? bCount.toInt() : 0)).compareTo(
        aCount is num ? aCount.toInt() : 0,
      );
    });
  }

  final responses = await Future.wait([
    _get('$_bgmApiBase/v0/subjects/$subjectId/characters'),
    _get('$_bgmApiBase/v0/episodes?subject_id=$subjectId'),
  ]);

  baseData['characters'] = BgmUtils.parseJsonList(responses[0].data);
  baseData['episodes'] = BgmUtils.parseJsonList(responses[1].data);

  _fullDetailCache[subjectId] = _CachedBgmResponse(baseData);
  return baseData;
}

Future<Response> getBgmRelatedSubjects(int subjectId) {
  return _get('$_bgmApiBase/v0/subjects/$subjectId/subjects');
}

Future<Response> getTrendingSubjects({
  int type = 2,
  int limit = 24,
  int offset = 0,
}) {
  return _get(
    '$_bgmNextBase/p1/trending/subjects?type=$type&limit=$limit&offset=$offset',
  );
}

/// BGM 每日放送（一周更新表）。
///
/// 返回以星期为 key（1=周一 … 7=周日）的 Map，值为
/// `[{subject: {...}, watchers: n}]`，subject 与 trending 接口同构。
Future<Response> getBgmCalendar() {
  return _get('$_bgmNextBase/p1/calendar');
}

Future<Response> getBgmSubjectComments(
  int subjectId, {
  int limit = 20,
  int offset = 0,
}) {
  final cacheKey = '$subjectId:$limit:$offset';
  final cached = _subjectCommentsCache[cacheKey];
  if (cached != null && !cached.isExpired) {
    return Future.value(Response(cached.data));
  }

  return _get(
    '$_bgmNextBase/p1/subjects/$subjectId/comments?limit=$limit&offset=$offset',
  ).then((response) {
    _subjectCommentsCache[cacheKey] = _CachedBgmResponse(response.data);
    return response;
  });
}

Future<Response> getBgmEpisodeComments(int episodeId) {
  final cacheKey = episodeId.toString();
  final cached = _episodeCommentsCache[cacheKey];
  if (cached != null && !cached.isExpired) {
    return Future.value(Response(cached.data));
  }

  return _get('$_bgmNextBase/p1/episodes/$episodeId/comments').then((response) {
    _episodeCommentsCache[cacheKey] = _CachedBgmResponse(response.data);
    return response;
  });
}

Future<Response> getBgmCharacterInfo(int characterId) {
  return _get('$_bgmNextBase/p1/characters/$characterId');
}

Future<Response> getBgmCharacterComments(int characterId) {
  return _get('$_bgmNextBase/p1/characters/$characterId/comments');
}

/// 通过标签搜索 BGM 动画
///
/// 使用 BGM v0 搜索 API (POST /v0/search/subjects)
/// [tags] BGM 标签列表（AND 关系）
/// [sort] 排序：rank(排名) / heat(热度) / score(评分) / match(相关)
Future<Response> searchBgmByTag(
  List<String> tags, {
  int limit = 25,
  int offset = 0,
  String sort = 'rank',
  List<String>? airDate,
}) {
  final filter = <String, dynamic>{
    'type': [2],
  };
  if (tags.isNotEmpty) filter['tag'] = tags;
  if (airDate != null && airDate.isNotEmpty) filter['air_date'] = airDate;

  return _post('$_bgmApiBase/v0/search/subjects?limit=$limit&offset=$offset', {
    // Bangumi now rejects an empty keyword. `*` keeps this as a filter-only
    // search, so the home "最新" feed and category filters still return data.
    'keyword': '*',
    'sort': sort,
    'filter': filter,
  });
}

Future<Response> _get(String url) async {
  return await NetUtils.get(url) as Response;
}

Future<Response> _post(String url, Map<String, dynamic> body) async {
  return await NetUtils.post(url, body) as Response;
}

class _CachedBgmResponse<T> {
  final T data;
  final DateTime cachedAt;

  _CachedBgmResponse(this.data) : cachedAt = DateTime.now();

  bool get isExpired =>
      DateTime.now().difference(cachedAt) > _bgmSessionCacheTtl;
}
