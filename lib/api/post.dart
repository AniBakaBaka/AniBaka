import 'package:baka/api/api_config.dart';
import 'package:baka/core/api_transport.dart';

String get host => ApiConfig.host;

Future<List<Map<String, dynamic>>> getPost(
  String sort,
  String tag,
  int page,
  int pageSize, {
  String status = 'public',
  Object? uid,
  Object? uv,
}) async => (await apiTransport.getData<List<dynamic>>(
  Uri.parse('$host/posts')
      .replace(
        queryParameters: {
          'status': status,
          'sort': sort,
          'tag': tag,
          if (uid != null) 'uid': '$uid',
          if (uv != null) 'uv': '$uv',
          'page': '$page',
          'pageSize': '$pageSize',
        },
      )
      .toString(),
)).cast<Map<String, dynamic>>();

Future<Map<String, dynamic>> getPostDetail(
  int pid, {
  Future<void>? abortTrigger,
}) async {
  // The post endpoint returns a successful envelope with data:null when the
  // post does not exist. Keep malformed/missing data as a protocol error.
  final detail = await apiTransport.getData<Map<String, dynamic>?>(
    '$host/post/$pid',
    abortTrigger: abortTrigger,
  );
  if (detail == null) {
    throw const ApiException('条目不存在或已删除', statusCode: 404);
  }
  return detail;
}

Future<List<Map<String, dynamic>>> getSearch(String? key) async =>
    (await apiTransport.getData<List<dynamic>>(
      Uri.parse(
        '$host/search/posts',
      ).replace(queryParameters: {'key': ?key}).toString(),
    )).cast<Map<String, dynamic>>();

Future<List<Map>> getComments(
  int? pid,
  int pageSize, {
  int page = 1,
  Future<void>? abortTrigger,
  bool notifyOnError = true,
}) async => (await apiTransport.getData<List<dynamic>>(
  Uri.parse('$host/comments')
      .replace(
        queryParameters: {
          if (pid != null) 'pid': '$pid',
          'page': '$page',
          'pageSize': '$pageSize',
        },
      )
      .toString(),
  abortTrigger: abortTrigger,
  notifyOnError: notifyOnError,
)).cast<Map>();

Future<bool> addComment(Map<String, Object?> data) async =>
    ApiTransport.accepted(
      await apiTransport.postJson<Map<String, dynamic>>(
        '$host/comment/add',
        data,
      ),
    );

Future<String> updateCommentUv(Object cid, Object? name) async {
  final response = await apiTransport.postJson<Map<String, dynamic>>(
    Uri.parse('$host/comment/uv')
        .replace(
          queryParameters: {'cid': '$cid', if (name != null) 'name': '$name'},
        )
        .toString(),
    const {},
  );
  ApiTransport.accepted(response);
  final message = response['msg'];
  if (message is! String) throw const FormatException('评论点赞响应缺少 msg');
  return message;
}
