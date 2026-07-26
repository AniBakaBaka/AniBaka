import 'dart:convert';
import 'package:baka/api/api_config.dart';
import 'package:baka/services/network_service.dart';
import 'package:baka/models/play_history.dart';

/// 播放历史 API 服务
class PlayHistoryApi {
  static String get _baseUrl => '${ApiConfig.host}/api/v1';

  /// 统一处理 API 请求与响应解析，消除冗余的防御性代码
  static Future<T?> _request<T>(
    Future<dynamic> requestFuture, [
    T Function(dynamic)? parser,
  ]) async {
    try {
      final response = await requestFuture;
      if (response?.data == null || response.data.isEmpty) return null;

      final res = jsonDecode(response.data);
      if (res['code'] == 0) {
        if (parser != null) {
          return res['data'] != null ? parser(res['data']) : null;
        }
        if (T == bool) return true as T;
      }
    } catch (_) {}
    return null;
  }

  /// 添加或更新播放历史
  static Future<PlayHistory?> addOrUpdatePlayHistory(PlayHistory history) =>
      _request(
        NetUtils.post('$_baseUrl/play-history', history.toJson()),
        (data) => PlayHistory.fromJson(data),
      );

  /// 获取播放历史列表
  static Future<PlayHistoryListResponse?> getPlayHistoryList({
    int pageSize = 20,
    int? videoType,
  }) {
    final uri = Uri.parse('$_baseUrl/play-history').replace(
      queryParameters: {
        'page_size': '$pageSize',
        if (videoType != null) 'video_type': '$videoType',
      },
    );
    return _request(
      NetUtils.get(uri.toString()),
      (data) => PlayHistoryListResponse.fromJson(data),
    );
  }

  /// 清空播放历史
  static Future<bool> clearPlayHistory() async =>
      await _request<bool>(NetUtils.delete('$_baseUrl/play-history-clear')) ??
      false;
}
