import 'dart:convert';

import 'package:baka/api/api_config.dart';
import 'package:baka/app_state.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:baka/instance.dart';

class Response {
  Response(this.data);

  String data;
}

class HttpClient extends http.BaseClient {
  final http.Client _inner;

  HttpClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['baka-user-agent'] = Instances.appVersion;
    request.headers['Content-Type'] = 'application/json';
    return _inner.send(request);
  }
}

class NetUtils {
  static final httpClient = HttpClient(http.Client());
  static const _refreshAdvance = Duration(seconds: 30);

  /// 并发刷新锁：多个请求同时 401 时只发起一次 refresh
  static Future<bool>? _refreshFuture;

  static Future<bool> _tryRefreshToken() {
    _refreshFuture ??= _doRefreshToken();
    return _refreshFuture!;
  }

  static bool _tokenExpiresSoon() {
    final value = Instances.sp.getString('token_expires_at');
    final expiresAt = value == null ? null : DateTime.tryParse(value);
    return expiresAt != null &&
        !expiresAt.isAfter(DateTime.now().add(_refreshAdvance));
  }

  static Future<void> saveTokenResponse(Map<String, dynamic> data) async {
    final token = data['token'] as String?;
    if (token == null || token.isEmpty) return;

    await Instances.sp.setString('usertoken', token);
    final refreshToken = data['refresh_token'] as String?;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await Instances.sp.setString('refresh_token', refreshToken);
    }
    final expiresIn = (data['expires_in'] as num?)?.toInt();
    if (expiresIn != null) {
      await Instances.sp.setString(
        'token_expires_at',
        DateTime.now()
            .add(Duration(seconds: expiresIn))
            .toUtc()
            .toIso8601String(),
      );
    }
  }

  static Future<bool> _doRefreshToken() async {
    try {
      final refreshToken = Instances.sp.getString('refresh_token');
      if (refreshToken == null || refreshToken.isEmpty) return false;

      final hostUrl = ApiConfig.host;

      debugPrint('[NetUtils] 正在刷新Token...');
      final res = await httpClient.post(
        Uri.parse('$hostUrl/user/refresh'),
        body: jsonEncode({'refresh_token': refreshToken}),
      );

      final resData = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200 &&
          resData['code'] == 200 &&
          resData['token'] != null) {
        await saveTokenResponse(resData);
        debugPrint('[NetUtils] Token刷新成功');
        return true;
      } else {
        debugPrint('[NetUtils] Token刷新失败: ${resData['msg']}');
        return false;
      }
    } catch (e) {
      debugPrint('[NetUtils] Token刷新异常: $e');
      return false;
    } finally {
      _refreshFuture = null;
    }
  }

  static Future<Response> _send(
    String method,
    String url, {
    data,
    bool isRetry = false,
    Duration? timeout,
    bool notifyOnError = true,
  }) async {
    if (kDebugMode) debugPrint('http $method $url');
    final isAuthRequest =
        url.contains('/user/login') || url.contains('/user/refresh');
    if (!isRetry && !isAuthRequest && _tokenExpiresSoon()) {
      if (!await _tryRefreshToken()) {
        Get.find<AppState>().performLogout();
        return Response('');
      }
    }

    final token = Instances.sp.getString('usertoken') ?? '';
    final headers = token.isNotEmpty ? {'token': token} : <String, String>{};

    http.Response httpResponse;
    try {
      final uri = Uri.parse(url);
      switch (method) {
        case 'GET':
          final request = httpClient.get(uri, headers: headers);
          httpResponse = timeout == null
              ? await request
              : await request.timeout(timeout);
        case 'PUT':
          httpResponse = await httpClient.put(
            uri,
            body: jsonEncode(data),
            headers: headers,
          );
        case 'DELETE':
          httpResponse = await httpClient.delete(
            uri,
            body: data != null ? jsonEncode(data) : null,
            headers: headers,
          );
        default:
          httpResponse = await httpClient.post(
            uri,
            body: jsonEncode(data),
            headers: headers,
          );
      }
    } catch (e) {
      debugPrint('http error $e');
      if (notifyOnError) {
        showSnackBar('网络连接失败，请检查网络和线路＞︿＜', isError: true);
      }
      return Response('');
    }

    if (httpResponse.statusCode == 401 && !isAuthRequest) {
      if (!isRetry) {
        debugPrint('[NetUtils] 收到401，尝试刷新Token...');
        if (await _tryRefreshToken()) {
          return _send(
            method,
            url,
            data: data,
            isRetry: true,
            timeout: timeout,
            notifyOnError: notifyOnError,
          );
        }
      }
      debugPrint('[NetUtils] Token无效，需要重新登录');
      Get.find<AppState>().performLogout();
      return Response('');
    }

    return Response(httpResponse.body);
  }

  static Future get(
    String url, {
    Duration? timeout,
    bool notifyOnError = true,
  }) {
    return _send('GET', url, timeout: timeout, notifyOnError: notifyOnError);
  }

  static Future post(String url, data) {
    return _send('POST', url, data: data);
  }

  static Future put(String url, data) {
    return _send('PUT', url, data: data);
  }

  static Future delete(String url, {data}) {
    return _send('DELETE', url, data: data);
  }
}

dynamic getUserInfo() {
  final u = Instances.sp.getString('userinfo');
  return u != null ? jsonDecode(u) : {'id': 0};
}
