import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

/// Centralized Hive boxes and on-disk cache management.
///
/// 除了 Hive box 的打开与恢复，也负责图片/临时文件缓存的大小统计与清理
/// （原 CacheManagerService 的职责），让存储相关逻辑集中在一处。
class AppStorage {
  AppStorage._();

  static const String videoProgressBoxName = 'video_progress_box';
  static const String customSourcesBoxName = 'custom_sources_box';
  static const String downloadTasksBoxName = 'download_tasks_box';
  static const String playHistoryBoxName = 'play_history_box';
  static const String threadCommentsBoxName = 'thread_comments_box';
  static const String bgmCacheBoxName = 'bgm_cache_box';
  static const String homeCacheBoxName = 'home_cache_box';

  static Future<List<HiveBoxRecovery>> init({Directory? hiveDirectory}) async {
    final recoveries = <HiveBoxRecovery>[];
    // 各 box 相互独立（Hive 按名称去重、无全局锁），并行打开缩短启动耗时。
    await Future.wait([
      _openBox<Map>(videoProgressBoxName, hiveDirectory, recoveries),
      _openBox<List>(customSourcesBoxName, hiveDirectory, recoveries),
      _openBox<List>(downloadTasksBoxName, hiveDirectory, recoveries),
      _openBox<List>(playHistoryBoxName, hiveDirectory, recoveries),
      _openBox<Map>(threadCommentsBoxName, hiveDirectory, recoveries),
      _openBox<Map>(bgmCacheBoxName, hiveDirectory, recoveries),
      _openBox<Map>(homeCacheBoxName, hiveDirectory, recoveries),
    ]);
    return recoveries;
  }

  static Box<Map> get videoProgressBox => Hive.box<Map>(videoProgressBoxName);
  static Box<List> get customSourcesBox => Hive.box<List>(customSourcesBoxName);
  static Box<List> get downloadTasksBox => Hive.box<List>(downloadTasksBoxName);
  static Box<List> get playHistoryBox => Hive.box<List>(playHistoryBoxName);
  static Box<Map> get threadCommentsBox => Hive.box<Map>(threadCommentsBoxName);
  static Box<Map> get bgmCacheBox => Hive.box<Map>(bgmCacheBoxName);
  static Box<Map> get homeCacheBox => Hive.box<Map>(homeCacheBoxName);

  static Future<void> _openBox<T>(
    String name,
    Directory? hiveDirectory,
    List<HiveBoxRecovery> recoveries,
  ) async {
    try {
      await _openHiveBox<T>(name);
    } on HiveError catch (error) {
      if (!error.message.contains('Cannot read, unknown typeId:')) rethrow;

      final backupPath = await _backupBox(name, hiveDirectory);
      await _deleteBoxWithRetry(name);
      await _openHiveBox<T>(name);
      recoveries.add(HiveBoxRecovery(name, backupPath, error.message));
    }
  }

  /// Hive 2.2 also reports a failed open through its internal completer. Keep
  /// that duplicate error inside this zone and expose one catchable Future.
  static Future<void> _openHiveBox<T>(String name) {
    final result = Completer<void>();
    runZonedGuarded(
      () async {
        try {
          await Hive.openBox<T>(name);
          if (!result.isCompleted) result.complete();
        } catch (error, stackTrace) {
          if (!result.isCompleted) result.completeError(error, stackTrace);
        }
      },
      (error, stackTrace) {
        if (!result.isCompleted) result.completeError(error, stackTrace);
      },
    );
    return result.future;
  }

  static Future<String?> _backupBox(
    String name,
    Directory? hiveDirectory,
  ) async {
    if (hiveDirectory == null) return null;

    final source = File(
      '${hiveDirectory.path}${Platform.pathSeparator}$name.hive',
    );
    if (!await source.exists()) return null;

    final recoveryDirectory = Directory(
      '${hiveDirectory.path}${Platform.pathSeparator}recovery',
    );
    await recoveryDirectory.create(recursive: true);
    final timestamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final backup = await source.copy(
      '${recoveryDirectory.path}${Platform.pathSeparator}'
      '$name-$timestamp.hive',
    );
    return backup.path;
  }

  static Future<void> _deleteBoxWithRetry(String name) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await Hive.deleteBoxFromDisk(name);
        return;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        await Future<void>.delayed(Duration(milliseconds: 50 * (attempt + 1)));
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  // ---- 文件缓存（图片 / 临时文件）统计与清理 ----

  static const Duration _cacheSizeMemoTtl = Duration(seconds: 30);
  static ({int bytes, DateTime at})? _cacheSizeMemo;

  /// 获取缓存大小（字节）。30 秒内重复调用直接返回上次结果，
  /// 避免设置页来回切换时反复遍历整个缓存目录。
  static Future<int> getCacheSize() async {
    final memo = _cacheSizeMemo;
    if (memo != null &&
        DateTime.now().difference(memo.at) < _cacheSizeMemoTtl) {
      return memo.bytes;
    }

    var totalSize = 0;
    try {
      for (final directory in await _getCacheDirectories()) {
        totalSize += await _getDirectorySize(directory);
      }
    } catch (e) {
      debugPrint('获取缓存大小失败: $e');
    }
    _cacheSizeMemo = (bytes: totalSize, at: DateTime.now());
    return totalSize;
  }

  /// 清理所有缓存
  static Future<bool> clearAllCache() async {
    try {
      // 清理 cached_network_image 缓存
      await DefaultCacheManager().emptyCache();

      for (final directory in await _getCacheDirectories()) {
        await _clearDirectory(directory);
      }
      _cacheSizeMemo = null;
      return true;
    } catch (e) {
      debugPrint('清理缓存失败: $e');
      return false;
    }
  }

  static Future<List<Directory>> _getCacheDirectories() async {
    final tempDir = await getTemporaryDirectory();
    final imageCacheDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}${DefaultCacheManager.key}',
    );
    final appCacheDir = await getApplicationCacheDirectory();
    final directories = <Directory>[imageCacheDir];

    // Windows 的临时目录属于系统共享区域，不能整目录遍历或删除。
    if (!_samePath(appCacheDir.path, tempDir.path) &&
        !_samePath(appCacheDir.path, imageCacheDir.path)) {
      directories.add(appCacheDir);
    }
    return directories;
  }

  static bool _samePath(String left, String right) {
    final normalizedLeft = left
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    final normalizedRight = right
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    return Platform.isWindows
        ? normalizedLeft.toLowerCase() == normalizedRight.toLowerCase()
        : normalizedLeft == normalizedRight;
  }

  /// 获取目录大小
  static Future<int> _getDirectorySize(Directory dir) async {
    int size = 0;
    try {
      if (await dir.exists()) {
        await for (final entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) {
            try {
              size += await entity.length();
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('计算目录大小失败: $e');
    }
    return size;
  }

  /// 清理目录内容（保留目录本身）
  static Future<void> _clearDirectory(Directory dir) async {
    try {
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          try {
            if (entity is File) {
              await entity.delete();
            } else if (entity is Directory) {
              await entity.delete(recursive: true);
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('清理目录失败: $e');
    }
  }

  /// 格式化文件大小
  static String formatSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }
}

/// 带 TTL 的 Hive 缓存封装：统一 `{data, timestamp}` 存储格式与过期判断。
///
/// 首页、讨论区、BGM 分数等缓存都曾各自实现「map + timestamp + 过期」
/// 的读写，这里收敛成一份实现，避免三处逻辑漂移。
class TtlCache {
  TtlCache(this._box, {required this.ttl});

  final Box<Map> _box;
  final Duration ttl;

  /// 命中且未过期时返回缓存数据；未命中 / 过期 / 格式损坏返回 null。
  /// [allowExpired] 为 true 时忽略过期时间（如冷启动优先展示旧数据）。
  dynamic read(String key, {bool allowExpired = false}) {
    final cached = _box.get(key);
    if (cached is! Map || cached['timestamp'] is! int) return null;

    final age =
        DateTime.now().millisecondsSinceEpoch - (cached['timestamp'] as int);
    if (!allowExpired && age >= ttl.inMilliseconds) return null;
    return cached['data'];
  }

  Future<void> write(String key, dynamic data) => _box.put(key, {
    'data': data,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  });
}

class HiveBoxRecovery {
  const HiveBoxRecovery(this.boxName, this.backupPath, this.reason);

  final String boxName;
  final String? backupPath;
  final String reason;
}
