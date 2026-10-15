import 'dart:async';

/// 请求优先级：用户直接触发的播放解析优先于搜索。
enum RequestPriority { search, play }

/// 取消令牌。切页 / 换关键词时取消整棵请求树，避免慢源继续占用配额。
class RequestCancelToken {
  Set<void Function()>? _listeners;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners;
    _listeners = null;
    if (listeners == null) return;
    for (final listener in listeners) {
      listener();
    }
  }

  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    (_listeners ??= {}).add(listener);
    return () => _listeners?.remove(listener);
  }

  void throwIfCancelled() {
    if (_cancelled) throw const RequestCancelledException();
  }
}

class RequestCancelledException implements Exception {
  const RequestCancelledException();
  @override
  String toString() => 'RequestCancelledException';
}

/// 全局请求调度器。
///
/// 所有源的网络请求都经过这里，统一实现：
/// - **优先级**：play > search，高优先级任务先出队。
/// - **per-host 限流**：同一域名并发上限，避免请求风暴触发反爬。
/// - **全局并发上限**：控制多源聚合搜索时的整体压力。
/// - **取消**：通过 [RequestCancelToken] 取消尚未开始的排队任务。
///
/// 单例，进程内共享一份配额。
class RequestScheduler {
  RequestScheduler({this.maxConcurrent = 12, this.maxPerHost = 4});

  static final RequestScheduler instance = RequestScheduler();

  /// 全局最大并发数。
  final int maxConcurrent;

  /// 单域名最大并发数。
  final int maxPerHost;

  int _active = 0;
  final Map<String, int> _hostActive = <String, int>{};
  final _queues = <String, List<Map<int, _ScheduledTask>>>{};

  /// 申请一个请求槽位。返回的 Future 在槽位可用时完成；
  /// 调用方**必须**在请求结束后调用 [release] 归还槽位。
  Future<void> acquire(
    String host, {
    RequestPriority priority = RequestPriority.search,
    RequestCancelToken? cancelToken,
  }) {
    if (cancelToken?.isCancelled ?? false) {
      return Future.error(const RequestCancelledException());
    }

    final hostActive = _hostActive[host] ?? 0;
    // Any existing queue is blocked: _pump fills every available slot.
    if (_active < maxConcurrent && hostActive < maxPerHost) {
      _active++;
      _hostActive[host] = hostActive + 1;
      return Future.value();
    }

    final completer = Completer<void>();
    final queues = _queues.putIfAbsent(host, () => [{}, {}]);
    final queue = queues[priority.index];
    void Function()? unregisterCancel;
    final scheduled = (
      host: host,
      priority: priority,
      seq: _seq++,
      start: () {
        unregisterCancel?.call();
        completer.complete();
      },
    );

    unregisterCancel = cancelToken?.onCancel(() {
      if (queue.remove(scheduled.seq) != null) {
        if (queues.every((q) => q.isEmpty)) _queues.remove(host);
        completer.completeError(const RequestCancelledException());
      }
    });

    queue[scheduled.seq] = scheduled;
    _pump();
    return completer.future;
  }

  /// 归还 [host] 的一个槽位，并调度下一批排队任务。
  void release(String host) {
    _active--;
    final remaining = _hostActive[host]! - 1;
    if (remaining == 0) {
      _hostActive.remove(host);
    } else {
      _hostActive[host] = remaining;
    }
    _pump();
  }

  /// 提交一个受调度的异步任务（acquire → task → release 的便捷封装）。
  Future<T> run<T>(
    Future<T> Function() task, {
    required String host,
    RequestPriority priority = RequestPriority.search,
    RequestCancelToken? cancelToken,
  }) async {
    await acquire(host, priority: priority, cancelToken: cancelToken);
    try {
      cancelToken?.throwIfCancelled();
      return await task();
    } finally {
      release(host);
    }
  }

  int _seq = 0;

  void _pump() {
    while (_active < maxConcurrent) {
      _ScheduledTask? next;
      for (final entry in _queues.entries) {
        if ((_hostActive[entry.key] ?? 0) >= maxPerHost) continue;
        final queues = entry.value;
        final head =
            (queues[1].isNotEmpty ? queues[1] : queues[0]).values.first;
        if (next == null ||
            head.priority.index > next.priority.index ||
            (head.priority == next.priority && head.seq < next.seq)) {
          next = head;
        }
      }
      if (next == null) return;
      final queues = _queues[next.host]!;
      queues[next.priority.index].remove(next.seq);
      if (queues.every((q) => q.isEmpty)) _queues.remove(next.host);
      _active++;
      _hostActive.update(next.host, (v) => v + 1, ifAbsent: () => 1);
      next.start();
    }
  }
}

typedef _ScheduledTask = ({
  String host,
  RequestPriority priority,
  int seq,
  void Function() start,
});
