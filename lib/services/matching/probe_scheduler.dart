import 'dart:async';
import 'dart:collection';

/// 有界并发、按键去重的探针调度器。
///
/// 自动匹配要求「先到先探、随时可停」：命中后必须立刻停止后续工作，
/// 硬截止到达时也不能留下未收尾的批次。
class ProbeScheduler<T> {
  ProbeScheduler({
    required this.concurrency,
    required this.keyOf,
    required this.run,
  });

  final int concurrency;
  final String Function(T job) keyOf;
  final Future<void> Function(T job) run;

  final ListQueue<T> _queue = ListQueue<T>();
  final Set<String> _seen = <String>{};
  int _active = 0;
  bool _closed = false;
  Completer<void>? _drained;

  /// 已停止接收新任务（命中、取消或到达硬截止）。
  bool get isClosed => _closed;
  bool get isBusy => _active > 0 || _queue.isNotEmpty;

  /// 入队；同一 key 在一次运行内只接受一次。返回是否真正入队。
  bool add(T job) {
    if (_closed || !_seen.add(keyOf(job))) return false;
    _queue.addLast(job);
    _pump();
    return true;
  }

  /// 停止接收新任务并丢弃队列；在途任务不取消，由自身超时收尾。
  void close() {
    _closed = true;
    _queue.clear();
    _settle();
  }

  /// 队列清空且在途任务全部结束后完成。
  Future<void> get drained =>
      isBusy ? (_drained ??= Completer<void>()).future : Future<void>.value();

  void _pump() {
    while (!_closed && _active < concurrency && _queue.isNotEmpty) {
      _active++;
      unawaited(
        run(_queue.removeFirst()).catchError((Object _) {}).whenComplete(() {
          _active--;
          _pump();
        }),
      );
    }
    _settle();
  }

  void _settle() {
    if (isBusy) return;
    final done = _drained;
    _drained = null;
    if (done != null && !done.isCompleted) done.complete();
  }
}
