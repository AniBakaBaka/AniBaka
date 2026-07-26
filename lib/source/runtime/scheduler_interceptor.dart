import 'package:dio/dio.dart';

import 'package:baka/source/runtime/request_scheduler.dart';

/// 把 Dio 请求接入 [RequestScheduler] 的拦截器。
///
/// 挂到适配器共享的 Dio 上后，**所有源**（内置源、v1 规则源、v2 管线源）的
/// HTTP 请求自动获得全局优先级调度与 per-host 限流，无需各适配器自行改造。
///
/// 调用方可通过 request options 的 extra 传递调度参数：
/// - [priorityKey]: [RequestPriority]
class SchedulerInterceptor extends Interceptor {
  static const String priorityKey = 'anx.priority';

  final RequestScheduler scheduler = RequestScheduler.instance;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final host = options.uri.host;
    final p = options.extra[priorityKey];
    final priority = p is RequestPriority ? p : RequestPriority.search;
    await scheduler.acquire(host, priority: priority);
    options.extra['anx.acquired'] = host;
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _release(response.requestOptions);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _release(err.requestOptions);
    handler.next(err);
  }

  void _release(RequestOptions options) {
    final host = options.extra.remove('anx.acquired');
    if (host is String) scheduler.release(host);
  }
}
