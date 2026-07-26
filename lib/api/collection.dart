import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:baka/api/api_config.dart';
import 'package:baka/services/network_service.dart';
import 'package:baka/models/collection.dart';

/// 追番收藏 API 服务
class CollectionApi {
  static String get _host => ApiConfig.host;

  static Future<T> _request<T>(
    Future<dynamic> Function() apiCall, {
    required T fallback,
    T Function(dynamic data)? parser,
  }) async {
    try {
      final response = await apiCall();
      final data = response.data;
      if (data == null || (data is String && data.isEmpty)) return fallback;

      // 智能解析：支持直接返回 Map 或 String 类型 JSON
      final json = data is String ? jsonDecode(data) : data;
      if (json['code'] == 0) {
        if (parser != null && json['data'] != null) return parser(json['data']);
        if (fallback is bool) return true as T; // bool 类型快速返回
        return (json['data'] as T?) ?? fallback;
      }
      debugPrint('[CollectionApi] 接口业务异常: ${json['message']}');
    } catch (e) {
      debugPrint('[CollectionApi] 请求或解析失败: $e');
    }
    return fallback;
  }

  /// 添加或更新追番收藏
  static Future<AnimeCollection?> addOrUpdate(AnimeCollection collection) =>
      _request(
        () => NetUtils.post('$_host/api/v1/collection', collection.toJson()),
        parser: (data) => AnimeCollection.fromJson(data),
        fallback: null,
      );

  /// 获取追番收藏列表
  static Future<CollectionListResponse?> getList({
    int page = 1,
    int pageSize = 20,
    int? status,
    int? bgmId,
  }) {
    final params = ['page=$page', 'page_size=$pageSize'];
    if (status != null) params.add('status=$status');
    if (bgmId != null) params.add('bgm_id=$bgmId');

    return _request(
      () => NetUtils.get('$_host/api/v1/collection?${params.join('&')}'),
      parser: (data) => CollectionListResponse.fromJson(data),
      fallback: null,
    );
  }

  /// 获取收藏统计
  static Future<CollectionStats?> getStats() => _request(
    () => NetUtils.get('$_host/api/v1/collection/stats'),
    parser: (data) => CollectionStats.fromJson(data),
    fallback: null,
  );

  /// 查询某番剧的收藏信息（通过 post_id）
  static Future<AnimeCollection?> getByPostId(int postId) => _request(
    () => NetUtils.get('$_host/api/v1/collection/post/$postId'),
    parser: (data) => AnimeCollection.fromJson(data),
    fallback: null,
  );

  /// 通过 BGM ID 查询收藏信息
  static Future<AnimeCollection?> getByBgmId(int bgmId) => _request(
    () => NetUtils.get('$_host/api/v1/bgm-collection/$bgmId'),
    parser: (data) => AnimeCollection.fromJson(data),
    fallback: null,
  );

  /// 删除追番收藏（通过 post_id）
  static Future<bool> delete(int postId) => _request(
    () => NetUtils.delete('$_host/api/v1/collection/$postId'),
    fallback: false,
  );

  /// 删除追番收藏（通过 bgm_id）
  static Future<bool> deleteByBgmId(int bgmId) => _request(
    () => NetUtils.delete('$_host/api/v1/bgm-collection/$bgmId'),
    fallback: false,
  );
}
