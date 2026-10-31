import 'dart:async';
import 'dart:convert';

import 'package:baka/core/account_session.dart';
import 'package:baka/core/app_logger.dart';
import 'package:http/http.dart' as http;

/// HTTP status and AniBaka envelope errors are distinct from network/JSON errors.
class ApiException implements Exception {
  const ApiException(
    this.message, {
    this.statusCode,
    this.code,
    this.responseBody,
  });

  final String message;
  final int? statusCode;
  final int? code;
  final String? responseBody;

  /// The explanation in a JSON error body (AniBaka `msg`/`message`, Bangumi
  /// `description`/`title`); null for gateway pages and empty bodies.
  String? get serverMessage {
    final body = responseBody;
    if (body == null || !body.trimLeft().startsWith('{')) return null;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      for (final key in const ['msg', 'message', 'description', 'title']) {
        if (json[key] case final String text when text.trim().isNotEmpty) {
          return text.trim();
        }
      }
    } on FormatException {
      // Truncated or non-JSON body.
    }
    return null;
  }

  @override
  String toString() => message;
}

/// Sends one request, without session handling or retries. [timeout] covers
/// the response body too, and aborts the underlying request.
Future<http.Response> sendHttp(
  http.Client client,
  String method,
  Uri uri, {
  Map<String, String> headers = const {},
  Object? data,
  Duration timeout = const Duration(seconds: 20),
  Future<void>? abortTrigger,
  bool followRedirects = false,
}) async {
  final abort = Completer<void>();
  final request =
      http.AbortableRequest(
          method,
          uri,
          abortTrigger: abortTrigger == null
              ? abort.future
              : Future.any([abort.future, abortTrigger]),
        )
        ..followRedirects = followRedirects
        ..headers.addAll(headers);
  if (data != null) {
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode(data);
  }
  final response = await client
      .send(request)
      .then(http.Response.fromStream)
      .timeout(
        timeout,
        onTimeout: () {
          abort.complete();
          throw TimeoutException('$method ${uri.origin}${uri.path}', timeout);
        },
      );
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw ApiException(
      'HTTP ${response.statusCode}: $method ${uri.origin}${uri.path}',
      statusCode: response.statusCode,
      responseBody: response.body,
    );
  }
  return response;
}

T decodeJson<T>(String body) {
  if (body.trim().isEmpty) throw const FormatException('空 JSON 响应');
  final value = jsonDecode(body);
  if (value is! T) throw FormatException('JSON 响应类型错误，预期 $T');
  return value;
}

/// Installed by the composition root; stateless API functions share this pool.
late ApiTransport apiTransport;

/// AniBaka and public JSON APIs. Requests to the account server carry the
/// session token, refresh it once on 401, and are discarded when the account
/// or server changes while they run.
class ApiTransport {
  ApiTransport({
    required this.session,
    required this.client,
    required this.version,
    required this.credentialOrigin,
    this.onError,
  });

  final AccountSession session;
  final http.Client client;
  final String version;

  /// Read on each request so changing servers takes effect immediately.
  final Uri Function() credentialOrigin;
  final void Function(Object error)? onError;

  /// Endpoints that establish credentials; they never carry or refresh them.
  static const _credentialPaths = {
    '/user/login',
    '/user/refresh',
    '/user/password/reset',
  };

  Future<http.Response> _send(
    String method,
    Uri uri,
    Object? data,
    Duration? timeout,
    Future<void>? abortTrigger,
  ) async {
    if (session.closed) throw StateError('Account session is closed');
    final revision = session.generation;
    final origin = credentialOrigin().origin;
    final accountRequest = uri.origin == origin;
    final establishing =
        _credentialPaths.contains(uri.path) ||
        (uri.path == '/user/register' && data is Map && data['id'] == null) ||
        (uri.path == '/user/email/code' &&
            data is Map &&
            data['purpose'] != 'bind_email');
    // Broker 401 can describe upstream Bangumi credentials, not our session.
    final upstreamAuth = uri.path.startsWith('/api/v1/bangumi/oauth/');
    final carriesCredentials =
        accountRequest && !establishing && session.token.isNotEmpty;

    void ensureCurrent() {
      if (accountRequest &&
          (origin != credentialOrigin().origin ||
              revision != session.generation)) {
        throw StateError('账号或服务器已变更，请重试');
      }
    }

    Future<Never> expired() async {
      ensureCurrent();
      Log.w('Account', 'Session rejected by ${uri.path}; signing out');
      await session.logout();
      throw const ApiException('登录已过期，请重新登录', statusCode: 401);
    }

    if (carriesCredentials && session.expiresSoon && !await session.refresh()) {
      await expired();
    }
    for (var attempt = 0; ; attempt++) {
      ensureCurrent();
      final token = carriesCredentials ? session.token : '';
      try {
        final response = await sendHttp(
          client,
          method,
          uri,
          headers: {
            'baka-user-agent': version,
            'Content-Type': 'application/json',
            if (token.isNotEmpty) 'token': token,
          },
          data: data,
          timeout: timeout ?? const Duration(seconds: 20),
          abortTrigger: abortTrigger,
          // Custom token headers must never follow a redirect to another origin.
          followRedirects: !accountRequest,
        );
        ensureCurrent();
        return response;
      } on ApiException catch (error) {
        ensureCurrent();
        if (error.statusCode != 401 || !carriesCredentials || upstreamAuth) {
          rethrow;
        }
        if (attempt == 0 &&
            (token != session.token || await session.refresh())) {
          continue;
        }
        await expired();
      }
    }
  }

  /// [envelope] unwraps `{code, data}`; [optional] turns HTTP 404 into null.
  Future<T> _request<T>(
    String method,
    String url, {
    Object? data,
    bool envelope = false,
    bool optional = false,
    bool notifyOnError = true,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    final uri = Uri.parse(url);
    try {
      final body = (await _send(method, uri, data, timeout, abortTrigger)).body;
      return envelope
          ? unwrap<T>(decodeJson<Map<String, dynamic>>(body))
          : decodeJson<T>(body);
    } on http.RequestAbortedException {
      // Leaving a page or switching media intentionally cancels pending work.
      rethrow;
    } catch (error) {
      if (optional && error is ApiException && error.statusCode == 404) {
        return null as T;
      }
      final detail = error is ApiException ? error.serverMessage : null;
      Log.w(
        'Api',
        '$method ${uri.host}${uri.path}${detail == null ? '' : ' ($detail)'}',
        error,
      );
      if (notifyOnError) onError?.call(error);
      rethrow;
    }
  }

  Future<T> getJson<T>(
    String url, {
    Duration? timeout,
    bool notifyOnError = true,
    Future<void>? abortTrigger,
  }) => _request(
    'GET',
    url,
    timeout: timeout,
    notifyOnError: notifyOnError,
    abortTrigger: abortTrigger,
  );

  Future<T> postJson<T>(
    String url,
    Object? data, {
    Duration? timeout,
    bool notifyOnError = true,
    Future<void>? abortTrigger,
  }) => _request(
    'POST',
    url,
    data: data,
    timeout: timeout,
    notifyOnError: notifyOnError,
    abortTrigger: abortTrigger,
  );

  Future<T> deleteJson<T>(String url, {Object? data}) =>
      _request('DELETE', url, data: data);

  /// Only the envelope handles application codes; HTTP failures never reach it.
  static bool accepted(Map<String, dynamic> json) {
    final code = json['code'];
    if (code is! int) throw const FormatException('响应缺少有效 code');
    if (code != 0 && code != 200) {
      throw ApiException(
        (json['message'] ?? json['msg'])?.toString() ?? '接口请求失败（$code）',
        code: code,
      );
    }
    return true;
  }

  /// Missing data is a protocol error. Explicit null is allowed only for T?.
  static T unwrap<T>(Map<String, dynamic> json) {
    accepted(json);
    final data = json['data'];
    if (!json.containsKey('data') || data is! T) {
      throw FormatException('响应 data 缺失或类型错误，预期 $T');
    }
    return data;
  }

  Future<T> getData<T>(
    String url, {
    bool notifyOnError = true,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) => _request(
    'GET',
    url,
    envelope: true,
    notifyOnError: notifyOnError,
    timeout: timeout,
    abortTrigger: abortTrigger,
  );

  /// An optional resource may be absent (HTTP 404 or explicit null data).
  Future<T?> getOptionalData<T extends Object>(String url) =>
      _request<T?>('GET', url, envelope: true, optional: true);

  Future<T> postData<T>(
    String url,
    Object? data, {
    bool notifyOnError = true,
  }) => _request(
    'POST',
    url,
    data: data,
    envelope: true,
    notifyOnError: notifyOnError,
  );

  Future<T> putData<T>(String url, Object? data, {bool notifyOnError = true}) =>
      _request(
        'PUT',
        url,
        data: data,
        envelope: true,
        notifyOnError: notifyOnError,
      );

  void close() => client.close();
}
