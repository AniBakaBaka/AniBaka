import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:baka/core/app_logger.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

/// Hive boxes and the on-disk image/temporary cache.
abstract final class AppStorage {
  static const videoProgressBoxName = 'video_progress_box';
  static const customSourcesBoxName = 'custom_sources_box';
  static const downloadTasksBoxName = 'download_tasks_box';
  static const playHistoryBoxName = 'play_history_box';
  static const threadCommentsBoxName = 'thread_comments_box';
  static const bgmCacheBoxName = 'bgm_cache_box';
  static const homeCacheBoxName = 'home_cache_box';

  static const boxNames = [
    videoProgressBoxName,
    customSourcesBoxName,
    downloadTasksBoxName,
    playHistoryBoxName,
    threadCommentsBoxName,
    bgmCacheBoxName,
    homeCacheBoxName,
  ];

  /// Opened before the first frame; feature boxes open on first use.
  static const startupBoxes = {
    homeCacheBoxName,
    bgmCacheBoxName,
    playHistoryBoxName,
    videoProgressBoxName,
  };
  static const _listBoxes = {
    customSourcesBoxName,
    downloadTasksBoxName,
    playHistoryBoxName,
  };

  static Directory? _directory;
  static final _opening = <String, Future<void>>{};

  static Box<Map> get videoProgressBox => Hive.box<Map>(videoProgressBoxName);
  static Box<List> get customSourcesBox => Hive.box<List>(customSourcesBoxName);
  static Box<List> get downloadTasksBox => Hive.box<List>(downloadTasksBoxName);
  static Box<List> get playHistoryBox => Hive.box<List>(playHistoryBoxName);
  static Box<Map> get threadCommentsBox => Hive.box<Map>(threadCommentsBoxName);
  static Box<Map> get bgmCacheBox => Hive.box<Map>(bgmCacheBoxName);
  static Box<Map> get homeCacheBox => Hive.box<Map>(homeCacheBoxName);

  /// [hiveDirectory] enables backups of boxes rebuilt during recovery.
  static Future<void> init({
    Directory? hiveDirectory,
    Iterable<String> boxes = boxNames,
  }) async {
    _directory = hiveDirectory;
    await Future.wait(boxes.map(open));
  }

  /// Concurrent callers share one open.
  static Future<void> open(String name) {
    if (Hive.isBoxOpen(name)) return Future.value();
    return _opening.putIfAbsent(
      name,
      () => (_listBoxes.contains(name) ? _open<List>(name) : _open<Map>(name))
          .whenComplete(() {
            _opening.remove(name);
          }),
    );
  }

  /// A box written with a since-removed adapter cannot be read; it is backed
  /// up and rebuilt empty rather than blocking startup.
  static Future<void> _open<T>(String name) async {
    try {
      await _openHiveBox<T>(name);
    } on HiveError catch (error) {
      if (!error.message.contains('Cannot read, unknown typeId:')) rethrow;
      final backup = await _backup(name);
      await Hive.deleteBoxFromDisk(name);
      await _openHiveBox<T>(name);
      Log.w('Storage', 'Rebuilt box $name; backup: $backup', error.message);
    }
  }

  /// Hive 2.2 also fails its internal completer when an open fails. Keep that
  /// duplicate error inside this zone and expose one catchable Future.
  static Future<void> _openHiveBox<T>(String name) {
    final result = Completer<void>();
    runZonedGuarded(
      () => Hive.openBox<T>(name).then(
        (_) {
          if (!result.isCompleted) result.complete();
        },
        onError: (Object e, StackTrace s) {
          if (!result.isCompleted) result.completeError(e, s);
        },
      ),
      (error, stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future;
  }

  static Future<String?> _backup(String name) async {
    final directory = _directory;
    if (directory == null) return null;
    final separator = Platform.pathSeparator;
    final source = File('${directory.path}$separator$name.hive');
    if (!await source.exists()) return null;
    final recovery = await Directory(
      '${directory.path}${separator}recovery',
    ).create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp('[:.]'),
      '-',
    );
    return (await source.copy(
      '${recovery.path}$separator$name-$stamp.hive',
    )).path;
  }

  static Future<int>? _sizing;

  /// Bytes in the image and application caches, scanned off the UI isolate.
  static Future<int> getCacheSize() => _sizing ??= _cacheDirectories()
      .then((paths) => Isolate.run(() => _sizeOf(paths)))
      .whenComplete(() => _sizing = null);

  static Future<bool> clearAllCache() async {
    try {
      await DefaultCacheManager().emptyCache();
      final paths = await _cacheDirectories();
      await Isolate.run(() => _clear(paths));
      Log.i('Storage', 'Cache cleared');
      return true;
    } catch (error, stack) {
      Log.w('Storage', 'Cache clear failed', error, stack);
      return false;
    }
  }

  static Future<List<String>> _cacheDirectories() async {
    final temp = (await getTemporaryDirectory()).path;
    final images = '$temp${Platform.pathSeparator}${DefaultCacheManager.key}';
    final app = (await getApplicationCacheDirectory()).path;
    // The Windows temporary directory is shared system-wide; never scan or
    // clear it as a whole.
    return [images, if (!_samePath(app, temp) && !_samePath(app, images)) app];
  }

  static bool _samePath(String a, String b) {
    String normalize(String path) {
      var value = path.replaceAll('\\', '/');
      while (value.endsWith('/')) {
        value = value.substring(0, value.length - 1);
      }
      return Platform.isWindows ? value.toLowerCase() : value;
    }

    return normalize(a) == normalize(b);
  }

  static int _sizeOf(List<String> paths) {
    var total = 0;
    for (final path in paths) {
      try {
        for (final entity in Directory(
          path,
        ).listSync(recursive: true, followLinks: false)) {
          if (entity is File) {
            final size = entity.statSync().size;
            if (size > 0) total += size;
          }
        }
      } on FileSystemException {
        // Missing or unreadable directory.
      }
    }
    return total;
  }

  static void _clear(List<String> paths) {
    for (final path in paths) {
      final directory = Directory(path);
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync(followLinks: false)) {
        try {
          entity.deleteSync(recursive: true);
        } on FileSystemException {
          // In use by another process; cleared next time.
        }
      }
    }
  }
}

/// Hive entries stored as `{data, timestamp}` and read back within [ttl].
class TtlCache {
  TtlCache(this._box, {required this.ttl});

  final Box<Map> _box;
  final Duration ttl;

  /// Unexpired data, or any data when [allowExpired] (stale-first display).
  dynamic read(String key, {bool allowExpired = false}) {
    if (_box.get(key) case {'timestamp': final int at, 'data': final data}
        when allowExpired ||
            DateTime.now().millisecondsSinceEpoch - at < ttl.inMilliseconds) {
      return data;
    }
    return null;
  }

  Future<void> write(String key, dynamic data) => _box.put(key, {
    'data': data,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  });
}

/// Bounded in-memory LRU for shared asynchronous requests.
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
  final LinkedHashMap<K, _CacheEntry<V>> _entries = LinkedHashMap();
  // Capacity/TTL apply to completed values. Evicting a running request would
  // start duplicate I/O and parsing when callers outnumber cache slots.
  final Map<K, Future<V>> _pending = {};

  static int get _now => DateTime.now().millisecondsSinceEpoch;

  Future<V> get(K key, Future<V> Function() load, {bool refresh = false}) {
    final active = _pending[key];
    if (active != null) return active;
    final cached = refresh ? null : _fresh(key);
    if (cached != null) return cached.future;

    late final Future<V> request;
    // The async wrapper normalizes SynchronousFuture and synchronous throws.
    Future<V> invoke() async => load();
    request = invoke().then(
      (value) {
        if (identical(_pending[key], request)) {
          _pending.remove(key);
          _store(key, value, request, ttl);
        }
        return value;
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_pending[key], request)) _pending.remove(key);
        Error.throwWithStackTrace(error, stack);
      },
    );
    return _pending[key] = request;
  }

  /// A completed, unexpired value for first-frame UI initialization.
  V? peek(K key) => _fresh(key)?.value;

  /// Stores a value computed elsewhere; [ttl] overrides the cache default.
  void put(K key, V value, {Duration? ttl}) {
    _pending.remove(key);
    _store(key, value, Future.value(value), ttl ?? this.ttl);
  }

  /// Invalidates retained/pending references; it does not cancel the loader.
  /// Existing callers still complete, but the old result cannot repopulate us.
  void remove(K key) {
    _entries.remove(key);
    _pending.remove(key);
  }

  void clear() {
    _entries.clear();
    _pending.clear();
  }

  _CacheEntry<V>? _fresh(K key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (entry.expiresAt != null && _now >= entry.expiresAt!) return null;
    _entries[key] = entry;
    return entry;
  }

  void _store(K key, V value, Future<V> future, Duration? ttl) {
    _entries.remove(key);
    if (limit == 0 || shouldCache?.call(value) == false) return;
    while (_entries.length >= limit) {
      _entries.remove(_entries.keys.first);
    }
    _entries[key] = _CacheEntry(
      future,
      value,
      ttl == null ? null : _now + ttl.inMilliseconds,
    );
  }
}

final class _CacheEntry<V> {
  const _CacheEntry(this.future, this.value, this.expiresAt);

  final Future<V> future;
  final V value;
  final int? expiresAt;
}
