import 'dart:async';
import 'dart:collection';

/// 请求优先级：用户直接触发的播放解析优先于搜索。
enum RequestPriority { search, play }

/// 取消令牌。切页 / 换关键词时取消整棵请求树，避免慢源继续占用配额。
class RequestCancelToken {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
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
  RequestScheduler({this.maxConcurrent = 6, this.maxPerHost = 2});

  static final RequestScheduler instance = RequestScheduler();

  /// 全局最大并发数。
  final int maxConcurrent;

  /// 单域名最大并发数。
  final int maxPerHost;

  int _active = 0;
  final Map<String, int> _hostActive = <String, int>{};
  final _PriorityQueue _queue = _PriorityQueue();

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

    final completer = Completer<void>();
    void Function()? unregisterCancel;
    final scheduled = _ScheduledTask(
      host: host,
      priority: priority,
      seq: _seq++,
      start: () {
        unregisterCancel?.call();
        if (!completer.isCompleted) completer.complete();
      },
    );

    unregisterCancel = cancelToken?.onCancel(() {
      if (_queue.remove(scheduled) && !completer.isCompleted) {
        completer.completeError(const RequestCancelledException());
      }
    });

    _queue.add(scheduled);
    _pump();
    return completer.future;
  }

  /// 归还 [host] 的一个槽位，并调度下一批排队任务。
  void release(String host) {
    _active--;
    final remaining = (_hostActive[host] ?? 1) - 1;
    if (remaining <= 0) {
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
      return await task();
    } finally {
      release(host);
    }
  }

  int _seq = 0;

  void _pump() {
    while (_queue.isNotEmpty && _active < maxConcurrent) {
      final next = _queue.peekWithHostBudget(_hostActive, maxPerHost);
      if (next == null) break; // 队首都受 host 限流阻塞
      _queue.remove(next);
      _active++;
      _hostActive.update(next.host, (v) => v + 1, ifAbsent: () => 1);
      next.start();
    }
  }
}

class _ScheduledTask {
  final String host;
  final RequestPriority priority;
  final int seq;
  final void Function() start;

  _ScheduledTask({
    required this.host,
    required this.priority,
    required this.seq,
    required this.start,
  });
}

/// 按 (priority desc, seq asc) 排序，并支持 host 预算感知出队。
class _PriorityQueue {
  final SplayTreeSet<_ScheduledTask> _items = SplayTreeSet<_ScheduledTask>(
    _compare,
  );

  bool get isNotEmpty => _items.isNotEmpty;

  void add(_ScheduledTask item) => _items.add(item);

  bool remove(_ScheduledTask item) => _items.remove(item);

  /// 返回优先级最高、且其 host 未超预算的任务；没有则返回 null。
  _ScheduledTask? peekWithHostBudget(
    Map<String, int> hostActive,
    int maxPerHost,
  ) {
    _ScheduledTask? best;
    for (final item in _items) {
      if ((hostActive[item.host] ?? 0) >= maxPerHost) continue;
      best = item;
      break;
    }
    return best;
  }

  static int _compare(_ScheduledTask a, _ScheduledTask b) {
    if (a.priority.index != b.priority.index) {
      return b.priority.index.compareTo(a.priority.index);
    }
    return a.seq.compareTo(b.seq);
  }
}
