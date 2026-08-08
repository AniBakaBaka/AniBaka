import 'dart:convert';

import 'package:baka/services/network_service.dart';

const String _bgmApiBase = 'https://bgm.anibaka.com';
const String _bgmNextBase = 'https://p1.anibaka.com';
const Duration _bgmCacheTtl = Duration(minutes: 5);

final _subjectCache = _MemoryCache<int, Map<String, dynamic>>(64);
final _episodeCache = _MemoryCache<int, List<Map<String, dynamic>>>(8);
final _relatedCache = _MemoryCache<int, List<Map<String, dynamic>>>(16);
final _subjectCommentsCache = _MemoryCache<String, String>(16);
final _episodeCommentsCache = _MemoryCache<int, String>(16);

Future<List<Map<String, dynamic>>> searchBgmAnime(String title) async {
  final response = await _post(
    '$_bgmApiBase/v0/search/subjects?limit=10&offset=0',
    {
      'keyword': title,
      'sort': 'match',
      'filter': {
        'type': [2],
      },
    },
  );
  return _mapList(_jsonMap(response.data)['data']);
}

Future<Map<String, dynamic>> getBgmSubject(int subjectId) {
  return _subjectCache.get(
    subjectId,
    () async =>
        _jsonMap((await _get('$_bgmApiBase/v0/subjects/$subjectId')).data),
  );
}

Future<List<Map<String, dynamic>>> getBgmEpisodes(int subjectId) {
  return _episodeCache.get(subjectId, () async {
    final response = await _get(
      '$_bgmApiBase/v0/episodes?subject_id=$subjectId&type=0&limit=200',
    );
    return _mapList(_jsonMap(response.data)['data']);
  });
}

/// 角色响应通常远大于条目本身，只由角色页按需读取，不驻留全局缓存。
Future<List<Map<String, dynamic>>> getBgmCharacters(int subjectId) async {
  final response = await _get('$_bgmApiBase/v0/subjects/$subjectId/characters');
  return _mapList(jsonDecode(response.data));
}

Future<List<Map<String, dynamic>>> getBgmRelatedSubjects(int subjectId) {
  return _relatedCache.get(
    subjectId,
    () async => _mapList(
      jsonDecode(
        (await _get('$_bgmApiBase/v0/subjects/$subjectId/subjects')).data,
      ),
    ),
  );
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
  return _subjectCommentsCache
      .get(
        cacheKey,
        () async => (await _get(
          '$_bgmNextBase/p1/subjects/$subjectId/comments?limit=$limit&offset=$offset',
        )).data,
      )
      .then(Response.new);
}

Future<Response> getBgmEpisodeComments(int episodeId) {
  return _episodeCommentsCache
      .get(
        episodeId,
        () async =>
            (await _get('$_bgmNextBase/p1/episodes/$episodeId/comments')).data,
      )
      .then(Response.new);
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

Map<String, dynamic> _jsonMap(String source) =>
    jsonDecode(source) as Map<String, dynamic>;

List<Map<String, dynamic>> _mapList(Object? value) =>
    (value as List<dynamic>).cast<Map<String, dynamic>>();

class _MemoryCache<K, V> {
  _MemoryCache(this.limit);

  final int limit;
  final Map<K, ({DateTime expiresAt, Future<V> value})> _entries = {};

  Future<V> get(K key, Future<V> Function() load) {
    final now = DateTime.now();
    final cached = _entries.remove(key);
    if (cached != null && now.isBefore(cached.expiresAt)) {
      _entries[key] = cached;
      return cached.value;
    }

    if (_entries.length >= limit) _entries.remove(_entries.keys.first);
    final value = _load(key, load);
    _entries[key] = (expiresAt: now.add(_bgmCacheTtl), value: value);
    return value;
  }

  Future<V> _load(K key, Future<V> Function() load) async {
    try {
      return await load();
    } catch (_) {
      _entries.remove(key);
      rethrow;
    }
  }
}
