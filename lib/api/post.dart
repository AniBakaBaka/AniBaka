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

Future getUser(String? name) {
  return NetUtils.get('$host/user?uname=$name');
}

Future addPost(dynamic data) {
  return NetUtils.post('$host/post/add', data);
}

Future updatePost(dynamic data) {
  return NetUtils.post('$host/post/add', data);
}

Future getUsers(String? names) {
  return NetUtils.get('$host/users?names=$names');
}

Future getUserById(int? uid) {
  return NetUtils.get('$host/user?uid=$uid');
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

Future updateUv(dynamic pid, dynamic name) {
  return NetUtils.post('$host/post/uv?pid=$pid&name=$name', {});
}

Future updateCommentUv(dynamic cid, dynamic name) {
  return NetUtils.post('$host/comment/uv?cid=$cid&name=$name', {});
}

Future deleteComment(int commentId, String token) {
  return NetUtils.get('$host/comment/delete/$commentId?token=$token');
}

final Map<int, Future<Map<String, dynamic>?>> _animeDetailRequests = {};

Future<Map<String, dynamic>?> getAnimeDetail(int bgmId) =>
    _animeDetailRequests[bgmId] ??= _loadAnimeDetail(bgmId).then((data) {
      if (data == null) _animeDetailRequests.remove(bgmId);
      return data;
    });

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
