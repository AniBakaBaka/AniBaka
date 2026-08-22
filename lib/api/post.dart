import 'dart:convert';

import 'package:baka/api/api_config.dart';
import 'package:baka/services/network_service.dart';
import 'package:baka/utils/bgm_utils.dart';

String get host => ApiConfig.host;

Future<List<Map<String, dynamic>>> getPost(
  String sort,
  String tag,
  int page,
  int pageSize, {
  String status = 'public',
  Object uid = '',
  Object uv = '',
}) async {
  final response = await NetUtils.get(
    '$host/posts?status=$status&sort=$sort&tag=$tag&uid=$uid&uv=$uv&page=$page&pageSize=$pageSize',
  );
  return ((jsonDecode(response) as Map<String, dynamic>)['data']
          as List<dynamic>)
      .cast<Map<String, dynamic>>();
}

Future<Map<String, dynamic>> getPostDetail(int pid) async =>
    (jsonDecode(await NetUtils.get('$host/post/$pid'))
            as Map<String, dynamic>)['data']
        as Map<String, dynamic>;

Future<String> getPlayUrl(String url) {
  return NetUtils.get('$host/play?url=$url');
}

Future<List<Map<String, dynamic>>> getSearch(String? key) async =>
    ((jsonDecode(await NetUtils.get('$host/search/posts?key=$key'))
                as Map<String, dynamic>)['data']
            as List<dynamic>)
        .cast<Map<String, dynamic>>();

Future<List<dynamic>> getComments(
  int? pid,
  int pageSize,
  String? runame, {
  int page = 1,
}) async {
  final response = await NetUtils.get(
    '$host/comments?pid=$pid&runame=$runame&page=$page&pageSize=$pageSize',
  );
  return (jsonDecode(response) as Map<String, dynamic>)['data']
      as List<dynamic>;
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

Future<bool> addComment(Map<String, Object?> data) async =>
    (jsonDecode(await NetUtils.post('$host/comment/add', data))
        as Map<String, dynamic>)['code'] ==
    200;

Future<String> checkAppUpdateApi() {
  return NetUtils.get('https://version.anibaka.com/');
}

Future<String> updateCommentUv(Object cid, Object? name) async =>
    (jsonDecode(await NetUtils.post('$host/comment/uv?cid=$cid&name=$name', {}))
            as Map<String, dynamic>)['msg']
        as String;
