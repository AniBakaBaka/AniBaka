import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

class CacheManagerService {
  CacheManagerService._();

  static final CacheManagerService instance = CacheManagerService._();

  /// 获取缓存大小（字节）
  Future<int> getCacheSize() async {
    int totalSize = 0;

    try {
      // 获取临时目录缓存
      final tempDir = await getTemporaryDirectory();
      totalSize += await _getDirectorySize(tempDir);

      // 获取应用缓存目录
      final cacheDir = await getApplicationCacheDirectory();
      if (cacheDir.path != tempDir.path) {
        totalSize += await _getDirectorySize(cacheDir);
      }
    } catch (e) {
      debugPrint('获取缓存大小失败: $e');
    }

    return totalSize;
  }

  /// 获取目录大小
  Future<int> _getDirectorySize(Directory dir) async {
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

  /// 清理所有缓存
  Future<bool> clearAllCache() async {
    try {
      // 清理 cached_network_image 缓存
      await DefaultCacheManager().emptyCache();

      // 清理临时目录
      final tempDir = await getTemporaryDirectory();
      await _clearDirectory(tempDir);

      // 清理应用缓存目录
      final cacheDir = await getApplicationCacheDirectory();
      if (cacheDir.path != tempDir.path) {
        await _clearDirectory(cacheDir);
      }

      return true;
    } catch (e) {
      debugPrint('清理缓存失败: $e');
      return false;
    }
  }

  /// 清理目录内容（保留目录本身）
  Future<void> _clearDirectory(Directory dir) async {
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
