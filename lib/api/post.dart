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
