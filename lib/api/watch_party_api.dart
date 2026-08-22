import 'dart:convert';

import 'package:baka/api/api_config.dart';
import 'package:baka/models/watch_party.dart';
import 'package:baka/services/network_service.dart';

final class WatchPartyApi {
  WatchPartyApi._();

  static String get _baseUrl => '${ApiConfig.host}/api/v1/watch';

  static Future<WatchPartyInvite> createRoom(WatchPartyMedia media) async {
    final data = await _data(
      NetUtils.post('$_baseUrl/rooms', {'media': media.toJson()}),
    );
    return WatchPartyInvite.fromJson(data);
  }

  static Future<List<WatchPartyInvite>> listRooms() async {
    final data = await _data(NetUtils.get('$_baseUrl/rooms'));
    final rooms = data['rooms'] as List<dynamic>;
    return List<WatchPartyInvite>.generate(
      rooms.length,
      (index) =>
          WatchPartyInvite.fromJson(rooms[index] as Map<String, dynamic>),
      growable: false,
    );
  }

  static Future<WatchPartyInvite> getInvite(String code) async {
    final data = await _data(NetUtils.get('$_baseUrl/invites/$code'));
    return WatchPartyInvite.fromJson(data);
  }

  static Future<String> joinRoom(String code, String nickname) async {
    final data = await _data(
      NetUtils.post('$_baseUrl/invites/$code/join', {'nickname': nickname}),
    );
    return data['websocketUrl'] as String;
  }

  static Future<void> closeRoom(String roomId) async {
    final response = await NetUtils.delete('$_baseUrl/rooms/$roomId');
    if (response.isEmpty) throw StateError('无法结束房间');
    final json = jsonDecode(response) as Map<String, dynamic>;
    if (json['code'] != 0) {
      throw StateError(json['message']?.toString() ?? '无法结束房间');
    }
  }

  static Future<Map<String, dynamic>> _data(Future<String> request) async {
    final response = await request;
    if (response.isEmpty) throw StateError('一起看服务暂时不可用');
    final json = jsonDecode(response) as Map<String, dynamic>;
    if (json['code'] != 0) {
      throw StateError(json['message']?.toString() ?? '一起看请求失败');
    }
    return json['data'] as Map<String, dynamic>;
  }
}
