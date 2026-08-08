import 'package:baka/api/api_config.dart';
import 'package:baka/services/network_service.dart';
import 'package:baka/utils/bgm_utils.dart';

String get host => ApiConfig.host;

Future getPost(
  String sort,
  String tag,
  int page,
  int pageSize, {
  String status = 'public',
  Object uid = '',
  Object uv = '',
}) {
  final res = NetUtils.get(
    '$host/posts?status=$status&sort=$sort&tag=$tag&uid=$uid&uv=$uv&page=$page&pageSize=$pageSize',
  );
  return res;
}

Future getPostDetail<T>(int pid) {
  return NetUtils.get('$host/post/$pid');
}

dynamic getPlayUrl(String url) {
  return NetUtils.get('$host/play?url=$url');
}

Future getSearch(String? key) {
  return NetUtils.get('$host/search/posts?key=$key');
}

Future getRank(int day) {
  return NetUtils.get('$host/rank?day=$day');
}

Future getComments(int? pid, int pageSize, String? runame, {int page = 1}) {
  return NetUtils.get(
    '$host/comments?pid=$pid&runame=$runame&page=$page&pageSize=$pageSize',
  );
}

Future getDanmu(int bgmId, int episodeIndex, String? title) {
  final season = title == null ? null : BgmUtils.extractSeason(title);
  final uri = Uri.https('danmu.anibaka.com', '/danmu/list', {
    'gv': '$bgmId',
    'p': '$episodeIndex',
    if (title != null && title.isNotEmpty) 'title': title,
    if (season != null) 'season': '$season',
  });
  return NetUtils.get(uri.toString());
}

Future login(dynamic data) {
  return NetUtils.post('$host/user/login', data);
}

Future register(dynamic data) {
  return NetUtils.post('$host/user/register', data);
}

Future addComment(dynamic data) {
  return NetUtils.post('$host/comment/add', data);
}

Future checkAppUpdateApi() {
  return NetUtils.get('https://version.anibaka.com/');
}

Future getGonggao() {
  return NetUtils.get('$host/post/1');
}

Future updateCommentUv(dynamic cid, dynamic name) {
  return NetUtils.post('$host/comment/uv?cid=$cid&name=$name', {});
}

const _animeDetailCacheLimit = 32;
const _episodeStillsCacheLimit = 48;

final Map<int, Future<Map<String, dynamic>?>> _animeDetailRequests = {};

Future<Map<String, dynamic>?> getAnimeDetail(int bgmId) => _cachedRequest(
  _animeDetailRequests,
  bgmId,
  _animeDetailCacheLimit,
  () => _loadAnimeDetail(bgmId),
);

Future<Map<String, dynamic>?> _loadAnimeDetail(int bgmId) async {
  try {
    final response = await NetUtils.get(
      '$host/api/v1/anime/detail?bgm_id=$bgmId',
      timeout: const Duration(seconds: 8),
      notifyOnError: false,
    );
    final json = BgmUtils.parseJsonMap(response.data);
    if (json == null) return null;
    final code = BgmUtils.toInt(json['code']);
    if (code != 0) return null;
    return BgmUtils.asMap(json['data']);
  } catch (_) {
    return null;
  }
}

final Map<String, Future<Map<String, dynamic>?>> _episodeStillsRequests = {};

/// 获取单集剧照与元数据 API（支持内存缓存）
Future<Map<String, dynamic>?> getEpisodeStills({
  int? bgmId,
  int? tmdbId,
  String? tvdbId,
  int season = 1,
  int episode = 1,
}) {
  final cacheKey = 'b:${bgmId}_t:${tmdbId}_v:${tvdbId}_s:${season}_e:$episode';
  return _cachedRequest(
    _episodeStillsRequests,
    cacheKey,
    _episodeStillsCacheLimit,
    () => _loadEpisodeStills(
      bgmId: bgmId,
      tmdbId: tmdbId,
      tvdbId: tvdbId,
      season: season,
      episode: episode,
    ),
  );
}

Future<V?> _cachedRequest<K, V>(
  Map<K, Future<V?>> cache,
  K key,
  int limit,
  Future<V?> Function() load,
) {
  final cached = cache.remove(key);
  if (cached != null) {
    cache[key] = cached;
    return cached;
  }
  if (cache.length >= limit) cache.remove(cache.keys.first);

  late final Future<V?> request;
  request = load().then((value) {
    if (value == null && identical(cache[key], request)) cache.remove(key);
    return value;
  });
  cache[key] = request;
  return request;
}

Future<Map<String, dynamic>?> _loadEpisodeStills({
  int? bgmId,
  int? tmdbId,
  String? tvdbId,
  int season = 1,
  int episode = 1,
}) async {
  try {
    final queryParams = <String, String>{
      if (tmdbId != null && tmdbId > 0) 'tmdb_id': '$tmdbId',
      if (bgmId != null && bgmId > 0) 'bgm_id': '$bgmId',
      if (tvdbId != null && tvdbId.isNotEmpty) 'tvdb_id': tvdbId,
      'season': '$season',
      'ep': '$episode',
    };
    final queryString = queryParams.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');

    final response = await NetUtils.get(
      '$host/api/v1/anime/episode/stills?$queryString',
      timeout: const Duration(seconds: 6),
      notifyOnError: false,
    );
    final json = BgmUtils.parseJsonMap(response.data);
    if (json == null) return null;
    final code = BgmUtils.toInt(json['code']);
    if (code != 0) return null;
    return BgmUtils.asMap(json['data']);
  } catch (_) {
    return null;
  }
}
