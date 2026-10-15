import 'dart:async';

import 'package:baka/source/runtime/request_scheduler.dart';

/// One caller's work. Async descendants inherit the context, never the adapter's
/// other concurrent callers. A UI soft timeout does not cancel this context.
class SourceOperation {
  SourceOperation({SourceOperation? parent, Duration? timeout}) {
    _detachParent = parent?.token.onCancel(cancel);
    if (timeout != null) {
      _timer = Timer(timeout, () {
        timedOut = true;
        cancel();
      });
    }
  }

  static final Object _zoneKey = Object();
  static SourceOperation? get current =>
      Zone.current[_zoneKey] as SourceOperation?;
  static void check() => current?.token.throwIfCancelled();

  final RequestCancelToken token = RequestCancelToken();
  Timer? _timer;
  void Function()? _detachParent;
  bool timedOut = false;
  bool get isCancelled => token.isCancelled;
  void cancel() => token.cancel();
  void close() {
    _timer?.cancel();
    _timer = null;
    _detachParent?.call();
    _detachParent = null;
  }

  Future<T> run<T>(Future<T> Function() action) async {
    token.throwIfCancelled();
    return runZoned(
      () => wait(Future<T>.sync(action)),
      zoneValues: {_zoneKey: this},
    );
  }

  Future<T> wait<T>(Future<T> work) async {
    final cancelled = Completer<T>();
    final detach = token.onCancel(
      () => cancelled.completeError(const RequestCancelledException()),
    );
    try {
      final result = await Future.any([work, cancelled.future]);
      token.throwIfCancelled();
      return result;
    } finally {
      detach();
    }
  }

  static Future<void> delay(Duration duration) async {
    check();
    final done = Completer<void>();
    final timer = Timer(duration, done.complete);
    try {
      final operation = current;
      if (operation == null) {
        await done.future;
      } else {
        await operation.wait(done.future);
      }
    } finally {
      timer.cancel();
    }
  }
}
