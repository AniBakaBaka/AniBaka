import 'package:dio/dio.dart';

import 'package:baka/source/runtime/request_scheduler.dart';

/// 把 Dio 请求接入 [RequestScheduler] 的拦截器。
///
/// 挂到适配器共享的 Dio 上后，**所有源**（内置源、v1 规则源、v2 管线源）的
/// HTTP 请求自动获得全局优先级调度、per-host 限流与取消能力，无需各适配器
/// 自行改造。
///
/// 调用方可通过 request options 的 extra 传递调度参数：
/// - [priorityKey]: [RequestPriority] 的 index（int）
/// - [cancelKey]:   [RequestCancelToken]
class SchedulerInterceptor extends Interceptor {
  static const String priorityKey = 'anx.priority';
  static const String cancelKey = 'anx.cancelToken';

  final RequestScheduler scheduler;

  SchedulerInterceptor([RequestScheduler? scheduler])
      : scheduler = scheduler ?? RequestScheduler.instance;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final host = options.uri.host;
    final priorityIndex = options.extra[priorityKey];
    final priority = priorityIndex is int &&
            priorityIndex >= 0 &&
            priorityIndex < RequestPriority.values.length
        ? RequestPriority.values[priorityIndex]
        : RequestPriority.search;
    final cancelToken = options.extra[cancelKey];

    try {
      await scheduler.acquire(
        host,
        priority: priority,
        cancelToken: cancelToken is RequestCancelToken ? cancelToken : null,
      );
    } on RequestCancelledException {
      return handler.reject(
        DioException.requestCancelled(
          requestOptions: options,
          reason: 'cancelled by RequestCancelToken',
        ),
      );
    }
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
