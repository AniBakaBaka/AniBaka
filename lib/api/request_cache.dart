import 'dart:collection';

/// Bounded cache for shared asynchronous requests.
///
/// The cached value is the Future itself, so concurrent callers share one
/// request and one parse. Failed requests are removed immediately.
final class RequestCache<K, V> {
  RequestCache({required this.limit, this.ttl, this.shouldCache})
    : assert(limit > 0);

  final int limit;
  final Duration? ttl;
  final bool Function(V value)? shouldCache;
  final LinkedHashMap<K, _RequestEntry<V>> _entries = LinkedHashMap();

  Future<V> get(K key, Future<V> Function() load) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _entries.remove(key);
    if (cached != null &&
        (cached.expiresAt == null || now < cached.expiresAt!)) {
      _entries[key] = cached;
      return cached.value;
    }

    while (_entries.length >= limit) {
      _entries.remove(_entries.keys.first);
    }

    late final Future<V> request;
    request = load().then(
      (value) {
        if (shouldCache?.call(value) == false &&
            identical(_entries[key]?.value, request)) {
          _entries.remove(key);
        }
        return value;
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_entries[key]?.value, request)) _entries.remove(key);
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _entries[key] = _RequestEntry(
      request,
      ttl == null ? null : now + ttl!.inMilliseconds,
    );
    return request;
  }

  void remove(K key) => _entries.remove(key);

  void clear() => _entries.clear();
}

/// Shares only an in-flight request; completed values are never retained.
final class RequestDeduplicator<K, V> {
  final Map<K, Future<V>> _requests = {};

  Future<V> run(K key, Future<V> Function() load) {
    final active = _requests[key];
    if (active != null) return active;

    late final Future<V> request;
    request = load().whenComplete(() {
      if (identical(_requests[key], request)) _requests.remove(key);
    });
    _requests[key] = request;
    return request;
  }
}

final class _RequestEntry<V> {
  const _RequestEntry(this.value, this.expiresAt);

  final Future<V> value;
  final int? expiresAt;
}
