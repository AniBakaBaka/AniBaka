import 'package:baka/core/account_session.dart';
import 'package:baka/core/http_request.dart';
import 'package:http/http.dart' as http;

export 'package:baka/core/http_request.dart' show ApiException;

/// Installed by the composition root; stateless API functions share this pool.
late ApiTransport apiTransport;

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

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Object? data,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    if (session.closed) throw StateError('Account session is closed');
    final revision = session.generation;
    final origin = credentialOrigin().origin;
    final accountRequest = uri.origin == origin;
    final auth = uri.path == '/user/login' || uri.path == '/user/refresh';
    // Broker 401 can describe upstream Bangumi credentials, not our session.
    final upstreamAuth = uri.path.startsWith('/api/v1/bangumi/oauth/');
    final carriesCredentials =
        accountRequest && !auth && session.token.isNotEmpty;

    void ensureCurrent() {
      if (accountRequest &&
          (origin != credentialOrigin().origin ||
              revision != session.generation)) {
        throw StateError('账号或服务器已变更，请重试');
      }
    }

    Future<void> expired() async {
      ensureCurrent();
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
          timeout: timeout ?? apiRequestTimeout,
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

  Future<T> _request<T>(
    String method,
    String url,
    T Function(String body) read, {
    Object? data,
    Duration? timeout,
    bool notifyOnError = true,
    Future<void>? abortTrigger,
    T Function()? onNotFound,
  }) async {
    try {
      final response = await _send(
        method,
        Uri.parse(url),
        data: data,
        timeout: timeout,
        abortTrigger: abortTrigger,
      );
      return read(response.body);
    } on http.RequestAbortedException {
      // Leaving a page or switching media intentionally cancels pending work.
      // Keep cancellation visible to the caller without a global network toast.
      rethrow;
    } catch (error) {
      if (error is ApiException &&
          error.statusCode == 404 &&
          onNotFound != null) {
        return onNotFound();
      }
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
    decodeJson<T>,
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
    decodeJson<T>,
    data: data,
    timeout: timeout,
    notifyOnError: notifyOnError,
    abortTrigger: abortTrigger,
  );
  Future<T> deleteJson<T>(String url, {Object? data}) =>
      _request('DELETE', url, decodeJson<T>, data: data);

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
    (body) => unwrap<T>(decodeJson<Map<String, dynamic>>(body)),
    notifyOnError: notifyOnError,
    timeout: timeout,
    abortTrigger: abortTrigger,
  );

  /// An optional resource may be absent (HTTP 404 or explicit null data).
  /// Other failures keep the usual exception and notification behavior.
  Future<T?> getOptionalData<T extends Object>(String url) => _request<T?>(
    'GET',
    url,
    (body) => unwrap<T?>(decodeJson<Map<String, dynamic>>(body)),
    onNotFound: () => null,
  );

  Future<T> postData<T>(
    String url,
    Object? data, {
    bool notifyOnError = true,
  }) => _request(
    'POST',
    url,
    (body) => unwrap<T>(decodeJson<Map<String, dynamic>>(body)),
    data: data,
    notifyOnError: notifyOnError,
  );

  Future<T> putData<T>(String url, Object? data, {bool notifyOnError = true}) =>
      _request(
        'PUT',
        url,
        (body) => unwrap<T>(decodeJson<Map<String, dynamic>>(body)),
        data: data,
        notifyOnError: notifyOnError,
      );

  void close() => client.close();
}
