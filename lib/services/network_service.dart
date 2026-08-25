import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:baka/api/api_config.dart';
import 'package:baka/app_state.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:baka/instance.dart';

class HttpClient extends http.BaseClient {
  final http.Client _inner;

  HttpClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['baka-user-agent'] = Instances.appVersion;
    request.headers['Content-Type'] = 'application/json';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

class NetUtils {
  static HttpClient _httpClient = HttpClient(http.Client());
  static HttpClient get httpClient => _httpClient;

  @visibleForTesting
  static void resetHttpClientForTesting() {
    _httpClient.close();
    _httpClient = HttpClient(http.Client());
  }

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
        await Get.find<AppState>().saveTokenResponse(resData);
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

  static Future<String> _send(
    String method,
    String url, {
    data,
    bool isRetry = false,
    Duration? timeout,
    bool notifyOnError = true,
  }) async {
    final elapsed = Stopwatch()..start();
    if (kDebugMode) debugPrint('http start $method $url');
    final isAuthRequest =
        url.contains('/user/login') || url.contains('/user/refresh');
    if (!isRetry && !isAuthRequest && _tokenExpiresSoon()) {
      if (!await _tryRefreshToken()) {
        Get.find<AppState>().performLogout();
        return '';
      }
    }

    final token = Instances.sp.getString('usertoken') ?? '';
    final headers = token.isNotEmpty ? {'token': token} : <String, String>{};

    http.Response httpResponse;
    try {
      final uri = Uri.parse(url);
      httpResponse = await _executeRequest(
        method,
        uri,
        headers: headers,
        data: data,
        timeout: timeout,
      );
    } catch (e) {
      debugPrint(
        'http error $method $url after ${elapsed.elapsedMilliseconds}ms: $e',
      );
      if (notifyOnError) {
        showSnackBar('网络连接失败，请检查网络和线路＞︿＜', isError: true);
      }
      return '';
    }

    if (kDebugMode) {
      debugPrint(
        'http done $method $url status=${httpResponse.statusCode} '
        'after ${elapsed.elapsedMilliseconds}ms',
      );
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
      return '';
    }

    return httpResponse.body;
  }

  static Future<http.Response> _executeRequest(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    required Object? data,
    required Duration? timeout,
  }) {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      method,
      uri,
      abortTrigger: abort.future,
    )..headers.addAll(headers);
    if (data != null && method != 'GET') {
      request.body = jsonEncode(data);
    }

    final response = httpClient.send(request).then(http.Response.fromStream);
    if (timeout == null) return response;
    return response.timeout(
      timeout,
      onTimeout: () {
        if (!abort.isCompleted) abort.complete();
        throw TimeoutException(
          '$method $uri did not complete within $timeout',
          timeout,
        );
      },
    );
  }

  static Future<String> get(
    String url, {
    Duration? timeout,
    bool notifyOnError = true,
  }) {
    return _send('GET', url, timeout: timeout, notifyOnError: notifyOnError);
  }

  static Future<String> post(
    String url,
    Object? data, {
    Duration? timeout,
    bool notifyOnError = true,
  }) {
    return _send(
      'POST',
      url,
      data: data,
      timeout: timeout,
      notifyOnError: notifyOnError,
    );
  }

  static Future<String> put(String url, Object? data) {
    return _send('PUT', url, data: data);
  }

  static Future<String> delete(String url, {Object? data}) {
    return _send('DELETE', url, data: data);
  }

  static Future<T?> getJson<T>(
    String url, {
    Duration? timeout,
    bool notifyOnError = true,
  }) =>
      _decodeJson<T>(get(url, timeout: timeout, notifyOnError: notifyOnError));

  static Future<T?> postJson<T>(
    String url,
    Object? data, {
    Duration? timeout,
    bool notifyOnError = true,
  }) => _decodeJson<T>(
    post(url, data, timeout: timeout, notifyOnError: notifyOnError),
  );

  static Future<T?> putJson<T>(String url, Object? data) =>
      _decodeJson<T>(put(url, data));

  static Future<T?> deleteJson<T>(String url, {Object? data}) =>
      _decodeJson<T>(delete(url, data: data));

  static Future<T?> _decodeJson<T>(Future<String> request) async {
    final response = await request;
    return response.isEmpty ? null : jsonDecode(response) as T;
  }
}

/// Shared LAN address selection for QR login and TV log export.
final class LanAddress {
  LanAddress._();

  static Future<InternetAddress?> findIpv4() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    InternetAddress? first;
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.isLoopback || address.isLinkLocal) continue;
        first ??= address;
        if (_isPrivate(address.address)) return address;
      }
    }
    return first;
  }

  static bool _isPrivate(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return false;
    final first = int.tryParse(parts[0]);
    final second = int.tryParse(parts[1]);
    return first == 10 ||
        (first == 172 && second != null && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }
}

/// 登录 / 注册业务服务。
///
/// 与 [NetUtils] 同属认证与网络域；登录结果在这里解析一次并交给 [AppState]。
class LoginService {
  AppState get _appState => Get.find<AppState>();

  /// 执行登录流程
  Future<({bool success, String message})> performLogin({
    required String name,
    required String pwd,
  }) async {
    try {
      final res = await NetUtils.postJson<Map<String, dynamic>>(
        '${ApiConfig.host}/user/login',
        {'name': name.trim(), 'pwd': pwd, 'platform': 'app'},
      );
      if (res == null) {
        return (success: false, message: '登录失败，请检查网络');
      }
      if (res['code'] != 200) {
        return (
          success: false,
          message: res['msg']?.toString() ?? '登录失败，请检查账号密码',
        );
      }

      final user = AppUser.fromJson(res['user'] as Map<String, dynamic>);
      await _appState.saveTokenResponse(res);
      await _appState.saveUser(user);

      return (success: true, message: '登录成功');
    } catch (e) {
      debugPrint('登录错误: $e');
      return (success: false, message: '登录失败，请检查网络');
    }
  }

  /// 执行注册流程
  Future<({bool success, String message})> performRegister({
    required String name,
    required String pwd,
    required String qq,
  }) async {
    try {
      final res = await NetUtils.postJson<Map<String, dynamic>>(
        '${ApiConfig.host}/user/register',
        {'name': name.trim(), 'pwd': pwd, 'qq': qq.trim()},
      );
      if (res == null) {
        return (success: false, message: '注册失败，请检查网络');
      }
      final bool ok = res['code'] == 200;
      final String msg = res['msg']?.toString() ?? (ok ? '注册成功' : '注册失败');

      return (success: ok, message: msg);
    } catch (e) {
      debugPrint('注册错误: $e');
      return (success: false, message: '注册失败，请检查网络');
    }
  }

  Future<({bool success, String message, AppUser? user})> updateUser(
    AppUser current,
    String field,
    String value,
  ) async {
    try {
      final result = await NetUtils.postJson<Map<String, dynamic>>(
        '${ApiConfig.host}/user/register',
        {
          'id': current.id,
          'name': field == 'name' ? value : current.name,
          'qq': field == 'qq' ? value : current.qq,
          'sign': field == 'sign' ? value : current.sign,
          'level': current.level,
          'pwd': field == 'pwd' ? value : '',
        },
      );
      if (result == null) {
        return (success: false, message: '更新失败，请检查网络', user: null);
      }
      if (result['code'] != 200) {
        return (
          success: false,
          message: result['msg']?.toString() ?? '更新失败',
          user: null,
        );
      }
      final updated = AppUser.fromJson(
        result['data'] as Map<String, dynamic>,
        retainedPasswordMarker: current.passwordMarker ?? '',
      );
      return (success: true, message: '更新成功', user: updated);
    } catch (_) {
      return (success: false, message: '更新失败，请检查网络', user: null);
    }
  }
}

/// 日活统计上报（fire-and-forget，失败静默）。
class DauTracker {
  static const String _baseUrl = 'https://dau.anibaka.com';
  static const String _deviceIdKey = 'device_unique_id';
  static const String _installIdPrefix = 'install_';
  static const Duration _timeout = Duration(seconds: 10);

  static final RegExp _idRegex = RegExp(r'^install_[a-z]+_[0-9a-f]{32}$');
  static String? _cachedId;
  static Future<String>? _initFuture;

  static Future<void> track() async {
    try {
      final userId = await _getOrCreateDeviceId();
      if (userId.isEmpty) return;

      final uri = Uri.parse(
        _baseUrl,
      ).replace(path: '/track', queryParameters: {'id': userId});

      final client = http.Client();
      try {
        await client.get(uri).timeout(_timeout);
      } finally {
        client.close();
      }
    } catch (_) {
      // 静默处理，不影响用户体验
    }
  }

  // 用 Future 缓存防止并发竞态
  static Future<String> _getOrCreateDeviceId() {
    _initFuture ??= _resolveDeviceId();
    return _initFuture!;
  }

  static Future<String> _resolveDeviceId() async {
    if (_cachedId != null) return _cachedId!;

    final stored = Instances.sp.getString(_deviceIdKey);
    if (_isValidInstallId(stored)) {
      _cachedId = stored!;
      return _cachedId!;
    }

    final deviceId = _generateInstallId();
    if (deviceId.isNotEmpty) {
      await Instances.sp.setString(_deviceIdKey, deviceId);
      _cachedId = deviceId;
    }
    return deviceId;
  }

  static bool _isValidInstallId(String? value) {
    return value != null && _idRegex.hasMatch(value);
  }

  static String _generateInstallId() {
    final random = Random.secure();
    final buffer = StringBuffer('$_installIdPrefix${_platformTag()}_');
    for (var i = 0; i < 16; i++) {
      final byte = random.nextInt(256);
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static String _platformTag() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    return 'unknown';
  }
}
