import 'dart:async';
import 'dart:io';

import 'package:hive/hive.dart';

/// Centralized Hive boxes for structured app data.
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
    await _openBox<Map>(videoProgressBoxName, hiveDirectory, recoveries);
    await _openBox<List>(customSourcesBoxName, hiveDirectory, recoveries);
    await _openBox<List>(downloadTasksBoxName, hiveDirectory, recoveries);
    await _openBox<List>(playHistoryBoxName, hiveDirectory, recoveries);
    await _openBox<Map>(threadCommentsBoxName, hiveDirectory, recoveries);
    await _openBox<Map>(bgmCacheBoxName, hiveDirectory, recoveries);
    await _openBox<Map>(homeCacheBoxName, hiveDirectory, recoveries);
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
}

class HiveBoxRecovery {
  const HiveBoxRecovery(this.boxName, this.backupPath, this.reason);

  final String boxName;
  final String? backupPath;
  final String reason;
}
