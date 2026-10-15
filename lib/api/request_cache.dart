import 'dart:async';
import 'dart:collection';

/// Bounded cache for shared asynchronous requests.
///
/// The cached value is the Future itself, so concurrent callers share one
/// request and one parse. Failed requests are removed immediately.
final class RequestCache<K, V> {
  RequestCache({required this.limit, this.ttl, this.shouldCache})
    : assert(limit >= 0);

  /// Zero shares pending requests without retaining completed values.
  final int limit;
  final Duration? ttl;
  final bool Function(V value)? shouldCache;
  final LinkedHashMap<K, _RequestEntry<V>> _entries = LinkedHashMap();
  // Capacity/TTL apply to completed values. Evicting a running request would
  // start duplicate I/O and parsing when callers outnumber cache slots.
  final Map<K, Future<V>> _pending = {};

  Future<V> get(K key, Future<V> Function() load, {bool refresh = false}) {
    final active = _pending[key];
    if (active != null) return active;
    final cached = limit == 0 ? null : _entries.remove(key);
    if (!refresh &&
        cached != null &&
        (cached.expiresAt == null ||
            DateTime.now().millisecondsSinceEpoch < cached.expiresAt!)) {
      _entries[key] = cached;
      return cached.value;
    }

    late final Future<V> request;
    // Normalize SynchronousFuture before callbacks touch the pending table.
    // The async loader also captures synchronous throws without a Completer.
    Future<V> invoke() async => load();
    void release() {
      if (identical(_pending[key], request)) _pending.remove(key);
    }

    request = limit == 0
        ? invoke().whenComplete(release)
        : invoke().then(
            (value) {
              if (identical(_pending[key], request)) {
                _pending.remove(key);
                if (shouldCache?.call(value) != false) {
                  _evictForRoom();
                  _entries[key] = _RequestEntry(
                    request,
                    value,
                    ttl == null
                        ? null
                        : DateTime.now().millisecondsSinceEpoch +
                              ttl!.inMilliseconds,
                  );
                }
              }
              return value;
            },
            onError: (Object error, StackTrace stack) {
              release();
              Error.throwWithStackTrace(error, stack);
            },
          );
    return _pending[key] = request;
  }

  /// Invalidates retained/pending references; it does not cancel the loader.
  /// Existing callers still complete, but the old result cannot repopulate us.
  void remove(K key) {
    _entries.remove(key);
    _pending.remove(key);
  }

  /// Reads a completed, unexpired value for first-frame UI initialization.
  /// Pending requests never supply a partial/default value.
  V? peek(K key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (entry.expiresAt != null &&
        DateTime.now().millisecondsSinceEpoch >= entry.expiresAt!) {
      return null;
    }
    _entries[key] = entry;
    return entry.result;
  }

  /// 直接登记一个已算好的值（例如探针已解析出的播放数据）。
  void put(K key, V value) {
    _pending.remove(key);
    _entries.remove(key);
    if (limit == 0 || shouldCache?.call(value) == false) return;
    _evictForRoom();
    _entries[key] = _RequestEntry(
      Future<V>.value(value),
      value,
      ttl == null
          ? null
          : DateTime.now().millisecondsSinceEpoch + ttl!.inMilliseconds,
    );
  }

  /// Invalidates all entries without cancelling in-flight I/O.
  void clear() {
    _entries.clear();
    _pending.clear();
  }

  void _evictForRoom() {
    while (_entries.length >= limit) {
      _entries.remove(_entries.keys.first);
    }
  }
}

final class _RequestEntry<V> {
  const _RequestEntry(this.value, this.result, this.expiresAt);

  final Future<V> value;
  final V result;
  final int? expiresAt;
}
