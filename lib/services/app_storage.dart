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

  static Future<void> init() async {
    await Future.wait([
      Hive.openBox<Map>(videoProgressBoxName),
      Hive.openBox<List>(customSourcesBoxName),
      Hive.openBox<List>(downloadTasksBoxName),
      Hive.openBox<List>(playHistoryBoxName),
      Hive.openBox<Map>(threadCommentsBoxName),
      Hive.openBox<Map>(bgmCacheBoxName),
      Hive.openBox<Map>(homeCacheBoxName),
    ]);
  }

  static Box<Map> get videoProgressBox => Hive.box<Map>(videoProgressBoxName);
  static Box<List> get customSourcesBox => Hive.box<List>(customSourcesBoxName);
  static Box<List> get downloadTasksBox => Hive.box<List>(downloadTasksBoxName);
  static Box<List> get playHistoryBox => Hive.box<List>(playHistoryBoxName);
  static Box<Map> get threadCommentsBox => Hive.box<Map>(threadCommentsBoxName);
  static Box<Map> get bgmCacheBox => Hive.box<Map>(bgmCacheBoxName);
  static Box<Map> get homeCacheBox => Hive.box<Map>(homeCacheBoxName);
}
