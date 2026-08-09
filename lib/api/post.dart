import 'package:baka/api/api_config.dart';
import 'package:baka/services/network_service.dart';
import 'package:baka/utils/bgm_utils.dart';

String get host => ApiConfig.host;

Future<String> getPost(
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

Future<String> getPostDetail(int pid) {
  return NetUtils.get('$host/post/$pid');
}

Future<String> getPlayUrl(String url) {
  return NetUtils.get('$host/play?url=$url');
}

Future<String> getSearch(String? key) {
  return NetUtils.get('$host/search/posts?key=$key');
}

Future<String> getRank(int day) {
  return NetUtils.get('$host/rank?day=$day');
}

Future<String> getComments(
  int? pid,
  int pageSize,
  String? runame, {
  int page = 1,
}) {
  return NetUtils.get(
    '$host/comments?pid=$pid&runame=$runame&page=$page&pageSize=$pageSize',
  );
}

Future<String> getDanmu(int bgmId, int episodeIndex, String? title) {
  final season = title == null ? null : BgmUtils.extractSeason(title);
  final uri = Uri.https('danmu.anibaka.com', '/danmu/list', {
    'gv': '$bgmId',
    'p': '$episodeIndex',
    if (title != null && title.isNotEmpty) 'title': title,
    if (season != null) 'season': '$season',
  });
  return NetUtils.get(uri.toString());
}

Future<String> login(Map<String, Object?> data) {
  return NetUtils.post('$host/user/login', data);
}

Future<String> register(Map<String, Object?> data) {
  return NetUtils.post('$host/user/register', data);
}

Future<String> addComment(Map<String, Object?> data) {
  return NetUtils.post('$host/comment/add', data);
}

Future<String> checkAppUpdateApi() {
  return NetUtils.get('https://version.anibaka.com/');
}

Future<String> getGonggao() {
  return NetUtils.get('$host/post/1');
}

Future<String> updateCommentUv(Object cid, Object? name) {
  return NetUtils.post('$host/comment/uv?cid=$cid&name=$name', {});
}
