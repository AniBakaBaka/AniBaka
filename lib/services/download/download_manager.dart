import 'package:baka/utils/title_matcher.dart';
import 'dart:async';
import 'dart:io';
import 'package:baka/core/network_service.dart';

import 'package:baka/instance.dart';
import 'package:baka/models/download_task.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/services/download/hls_offline_remux.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saver_gallery/saver_gallery.dart';

late DownloadService downloads;

/// 控制同时下载的分片数量。
///
/// 限制同时下载的分片数，避免界面卡顿。
class _Semaphore {
  _Semaphore(this.max);
  final int max;
  int _held = 0;
  final _waiters = <void Function()>[];

  Future<void> acquire() {
    if (_held < max) {
      _held++;
      return Future<void>.value();
    }
    final c = Completer<void>();
    _waiters.add(c.complete);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0)();
    } else if (_held > 0) {
      _held--;
    }
  }
}

class DownloadService {
  static const String _storageKey = 'download_tasks';
  DownloadService();

  static final _illegalPathCharsRe = RegExp(r'[\\/:*?"<>|\r\n]+');
  static final _whitespaceRe = RegExp(r'\s+');

  final _DownloadTasksNotifier _tasks = _DownloadTasksNotifier();
  ValueListenable<List<DownloadTask>> get tasksListenable => _tasks;
  List<DownloadTask> get tasks => _tasks.value;

  /// 下载过程中的非致命告警（磁盘满 / 只读 / 音视频分离等），供 UI 以 SnackBar 展示。
  final ValueNotifier<String?> warning = ValueNotifier(null);

  void _warn(String message) {
    warning.value = message;
    // 8 秒后自动清除，避免提示一直挂着。
    Future.delayed(const Duration(seconds: 8), () {
      if (warning.value == message) warning.value = null;
    });
  }

  /// 判断是不是磁盘写不进去。
  bool _isDiskFull(Object? error) {
    if (error is FileSystemException) {
      final code = error.osError?.errorCode;
      if (code == 112 || code == 19) return true;
      final msg = '${error.message}${error.osError}'.toLowerCase();
      if (msg.contains('disk') ||
          msg.contains('space') ||
          msg.contains('enospc') ||
          msg.contains('no space')) {
        return true;
      }
    }
    if (error is DioException) {
      final msg = (error.message ?? '').toLowerCase();
      if (msg.contains('disk') ||
          msg.contains('space') ||
          msg.contains('enospc')) {
        return true;
      }
    }
    return false;
  }

  bool _audioWarned = false;
  void _warnAudioSeparated() {
    if (_audioWarned) return;
    _audioWarned = true;
    _warn('该视频使用独立音轨（音视频分离），离线文件可能不含声音');
  }

  Future<void>? _initialization;
  Future<void>? _running;
  bool _closed = false;
  void Function(DownloadTask task)? onCompleted;

  /// 管理下载连接，退出时清理。
  final client = NetworkService.createDio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 0),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
    ),
  );

  final _waiting = <String, DownloadTask>{};
  final Set<_DownloadRun> _activeRuns = {};
  bool _saveScheduled = false;

  /// 同时进行的下载任务数（设置中可调，默认 3）。
  int get _maxConcurrent {
    try {
      final v = Instances.sp.getInt('download_max_concurrent');
      return v != null && v > 0 ? v : 3;
    } catch (_) {
      return 3;
    }
  }

  /// 同时下载的分片数，设置里可调。
  ///
  /// 分片并发上限，默认 16，最高 48。
  static const int _kMaxHlsConcurrency = 48;

  int get _hlsConcurrency {
    try {
      final v = Instances.sp.getInt('download_hls_concurrency');
      if (v == null || v <= 0) return 16;
      return v > _kMaxHlsConcurrency ? _kMaxHlsConcurrency : v;
    } catch (_) {
      return 16;
    }
  }

  /// 是否在下载完成后一并缓存弹幕（默认关闭，只下载视频）。
  bool get _downloadDanmaku {
    try {
      return Instances.sp.getBool('download_danmaku') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 是否覆盖同名下载文件（设置页「下载」可调，默认关闭）。
  ///
  /// 同名文件：默认另存一份，打开开关才覆盖。
  bool get _overwriteSameName {
    try {
      return Instances.sp.getBool('download_overwrite_same_name') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 决定下载文件存到哪里。
  Future<String> _resolveTargetPath(String path) async {
    if (_overwriteSameName || !await File(path).exists()) return path;
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf('\\');
    final sep = slash > backslash ? slash : backslash;
    final dot = path.lastIndexOf('.');
    final hasExt = dot > sep;
    final base = hasExt ? path.substring(0, dot) : path;
    final ext = hasExt ? path.substring(dot) : '';
    for (var i = 2; i < 1000; i++) {
      final candidate = '${base}_$i$ext';
      if (!await File(candidate).exists()) return candidate;
    }
    return '${base}_${DateTime.now().millisecondsSinceEpoch}$ext';
  }

  /// 全局限制同时下载的分片数。
  ///
  /// 全局限制分片并发数，防止卡顿。
  int? _hlsGateValue;
  _Semaphore? _hlsGate;
  _Semaphore get _gate {
    final c = _hlsConcurrency;
    if (_hlsGate == null || _hlsGateValue != c) {
      _hlsGate = _Semaphore(c);
      _hlsGateValue = c;
    }
    return _hlsGate!;
  }

  /// 同一时间只拼接一个视频，避免磁盘卡。
  Future<void> _enqueueRemux(Future<void> Function() action) {
    final prev = _remuxLock.catchError((_) {});
    final completer = Completer<void>();
    _remuxLock = completer.future;
    return prev.then((_) => action()).whenComplete(completer.complete);
  }

  Future<void> _remuxLock = Future<void>.value();

  Future<void> init() =>
      _initialization ??= AppStorage.open(AppStorage.downloadTasksBoxName)
          .then((_) {
            if (_closed) return;
            _load();
            _tasks.changed();
            _processQueue();
          })
          .catchError((Object error, StackTrace stack) {
            _initialization = null;
            Error.throwWithStackTrace(error, stack);
          });

  Future<void>? _disposing;
  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    if (_closed) return;
    _closed = true;
    for (final run in _activeRuns) {
      run.token.cancel();
    }
    try {
      await _initialization;
      final pending = <Future<void>>[];
      if (_running != null) pending.add(_running!);
      for (final run in _activeRuns) {
        if (run.future != null) pending.add(run.future!);
      }
      await Future.wait(pending);
      if (_initialization != null) await _save();
    } finally {
      client.close(force: true);
      for (final task in tasks) {
        task.dispose();
      }
      _waiting.clear();
      onCompleted = null;
      _tasks.dispose();
    }
  }

  void _load() {
    try {
      final storedTasks = AppStorage.downloadTasksBox.get(_storageKey);
      if (storedTasks is List) {
        var removed = 0;
        final restored = _restoreTasks(storedTasks);
        // 启动时清掉失败和文件已不存在的记录。
        final valid = <DownloadTask>[];
        for (final task in restored) {
          final path = task.filePath;
          final fileGone =
              path != null && path.isNotEmpty && !File(path).existsSync();
          if (task.status == DownloadStatus.failed || fileGone) {
            removed++;
            task.dispose();
            continue;
          }
          valid.add(task);
        }
        if (removed > 0) {
          debugPrint('DownloadService: dropped $removed stale task(s)');
        }
        _tasks.value = valid;
        for (final task in tasks) {
          if (task.status == DownloadStatus.waiting) _waiting[task.id] = task;
        }
        if (removed > 0) _scheduleSave();
      }
      // 启动时整理一次记录文件，避免越来越大。
      unawaited(
        (AppStorage.downloadTasksBox as dynamic)
            .compact()
            .catchError((_) {}),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('DownloadService load error: $e');
    }
  }

  List<DownloadTask> _restoreTasks(List rawList) {
    final loaded = <DownloadTask>[];
    for (final item in rawList.whereType<Map>()) {
      final task = DownloadTask.fromJson(Map<String, dynamic>.from(item));
      if (task.status == DownloadStatus.downloading) {
        task.status = DownloadStatus.paused;
      }
      loaded.add(task);
    }
    return loaded;
  }

  void _scheduleSave() {
    if (_saveScheduled) return;
    _saveScheduled = true;
    scheduleMicrotask(() {
      _saveScheduled = false;
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    try {
      await AppStorage.downloadTasksBox.put(
        _storageKey,
        tasks.map((task) => task.toJson()).toList(growable: false),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('DownloadService save error: $e');
    }
  }

  void _notifyAndSave() {
    _tasks.changed();
    _scheduleSave();
  }

  int addTasks(List<DownloadTask> newTasks) {
    final existingIds = tasks.map((e) => e.id).toSet();
    var added = 0;
    for (final task in newTasks) {
      if (!existingIds.add(task.id)) continue;
      tasks.add(task);
      if (task.status == DownloadStatus.waiting) _waiting[task.id] = task;
      added++;
    }
    if (added == 0) return 0;
    _notifyAndSave();
    _processQueue();
    return added;
  }

  void pause(DownloadTask task) {
    if (task.status != DownloadStatus.downloading &&
        task.status != DownloadStatus.waiting) {
      return;
    }
    _waiting.remove(task.id);
    for (final run in _activeRuns) {
      if (identical(run.task, task)) run.token.cancel();
    }
    task.status = DownloadStatus.paused;
    _notifyAndSave();
    _processQueue();
  }

  void resume(DownloadTask task) {
    if (task.status != DownloadStatus.paused &&
        task.status != DownloadStatus.failed) {
      return;
    }
    task.status = DownloadStatus.waiting;
    _waiting[task.id] = task;
    _notifyAndSave();
    _processQueue();
  }

  void delete(DownloadTask task) {
    _waiting.remove(task.id);
    _DownloadRun? active;
    for (final run in _activeRuns) {
      if (identical(run.task, task)) {
        active = run;
        break;
      }
    }
    // 先删记录再删文件，避免误删整部作品的文件夹。
    tasks.remove(task);
    if (active != null) {
      active.deleteOnFinish = true;
      active.token.cancel();
    } else {
      _deleteTaskFiles(task)
          .then((_) => _maybeRemoveSeriesDir(task))
          .catchError((_) {})
          .ignore();
    }
    if (active == null) task.dispose();
    _notifyAndSave();
  }

  /// 这部作品的下载记录全部移除后，删除它专属的文件夹。
  ///
  /// 只删没有任务占用的作品文件夹，其他内容不动。
  Future<void> _maybeRemoveSeriesDir(DownloadTask task) async {
    if (tasks.any((t) => t.id != task.id && _isSameSeries(t, task))) return;

    final dir = await _seriesRoot(task);
    if (!await dir.exists()) return;

    final names = <String>{};
    for (final t in [task, ...tasks.where((t) => _isSameSeries(t, task))]) {
      final base = _stripExtension(t.filename);
      names
        ..add(t.filename)
        ..add('${t.filename}_danmaku.json')
        ..add('$base.mp4')
        ..add('$base.ts');
    }

    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.path.replaceAll('\\', '/').split('/').last;
        if (!names.contains(name)) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
      if (await dir.list(followLinks: false).isEmpty) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // 目录被占用或已消失：按需求静默忽略。
    }
  }

  /// 取消下载后清理刚建出来、尚未写入任何内容的空作品目录。
  Future<void> _removeEmptySeriesDir(DownloadTask task) async {
    final dir = await _seriesRoot(task);
    if (!await dir.exists()) return;
    if (!await dir.list(followLinks: false).isEmpty) return;
    await dir.delete(recursive: true);
  }

  Future<void> _deleteTaskFiles(DownloadTask task) async {
    final filePath = task.filePath;
    if (filePath == null || filePath.isEmpty) return;

    // 临时缓存文件夹。
    if (task.kind == DownloadTaskKind.hls && _isHlsCachePath(filePath)) {
      final dir = File(filePath).parent;
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      return;
    }

    final file = File(filePath);
    if (await file.exists()) await file.delete();
  }

  void pauseAll() {
    _waiting.clear();
    for (final run in _activeRuns) {
      run.token.cancel();
    }
    for (final task in tasks) {
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.waiting) {
        task.status = DownloadStatus.paused;
      }
    }
    _notifyAndSave();
  }

  void resumeAll() {
    for (final task in tasks) {
      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.failed) {
        task.status = DownloadStatus.waiting;
        _waiting[task.id] = task;
      }
    }
    _notifyAndSave();
    _processQueue();
  }

  Future<void> clearCompleted() async {
    final completed = tasks
        .where((task) => task.status == DownloadStatus.completed)
        .toList();
    if (completed.isEmpty) return;
    // 只清记录，不删已下载的视频文件。
    tasks.removeWhere((task) => task.status == DownloadStatus.completed);
    _notifyAndSave();
    for (final task in completed) {
      task.dispose();
    }
  }

  void _processQueue() {
    if (_closed || _waiting.isEmpty) return;
    // 拼接视频时不占下载位置，后面的任务可以继续下。
    int activeDownloads() =>
        _activeRuns.where((run) => !run.merging).length;
    while (activeDownloads() < _maxConcurrent && _waiting.isNotEmpty) {
      final task = _waiting.remove(_waiting.keys.first)!;
      _running = _downloadFile(task);
    }
  }

  Future<Directory> _downloadDirectory() async {
    if (Instances.isDesktopPlatform) {
      return Instances.desktopDataDirectory('downloads');
    }
    return getApplicationDocumentsDirectory();
  }

  /// 基础保存目录：优先使用任务自定义保存目录，否则回退默认下载目录。
  Future<Directory> _baseDirectory(DownloadTask task) async {
    final custom = task.saveDir;
    if (custom != null && custom.isNotEmpty) {
      final dir = Directory(custom);
      if (await dir.exists()) return dir;
    }
    return _downloadDirectory();
  }

  /// 按作品名和来源给下载文件分文件夹，同名时另存一份。
  String _seriesFolderName(DownloadTask task) {
    final base = _sanitizePathPart(task.title);
    if (_overwriteSameName) return base;
    final src = task.sourceName?.trim() ?? '';
    final line = task.lineName?.trim() ?? '';
    if (src.isEmpty && line.isEmpty) return base;
    String inner;
    if (src.isEmpty) {
      inner = _sanitizePathPart(line);
    } else if (line.isEmpty) {
      inner = _sanitizePathPart(src);
    } else {
      inner = '${_sanitizePathPart(src)}（${_sanitizePathPart(line)}）';
    }
    return '$base【$inner】';
  }

  /// 算出这部作品该放哪个文件夹（不创建）。
  ///
  /// 文件夹名由任务信息算出，不写进数据库。
  Future<Directory> _seriesRoot(DownloadTask task) async {
    final base = await _baseDirectory(task);
    return Directory(_joinPath(base.path, _seriesFolderName(task)));
  }

  /// 两个任务是否属于同一部作品（同保存位置 + 同作品文件夹名）。
  bool _isSameSeries(DownloadTask a, DownloadTask b) =>
      a.saveDir == b.saveDir && _seriesFolderName(a) == _seriesFolderName(b);

  /// 下载落点目录：作品专属目录，调用时确保已创建。
  ///
  /// 真正开始下载时才建文件夹，取消不会留空目录。
  Future<Directory> _taskDirectory(DownloadTask task) async {
    final dir = await _seriesRoot(task);
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> _resolveDownloadFilePath(DownloadTask task) async {
    final dir = await _taskDirectory(task);
    final targetPath = '${dir.path}/${task.filename}';

    if (!Instances.isDesktopPlatform ||
        task.filePath == null ||
        task.filePath == targetPath) {
      return targetPath;
    }

    final legacyFile = File(task.filePath!);
    if (!await legacyFile.exists()) return targetPath;

    final targetFile = File(targetPath);
    if (!await targetFile.exists()) {
      await legacyFile.rename(targetPath).catchError((_) async {
        await legacyFile.copy(targetPath);
        await legacyFile.delete();
        return File(targetPath);
      });
    }

    return targetPath;
  }

  Future<String> _resolveHlsManifestPath(DownloadTask task) async {
    final existing = task.filePath;
    if (existing != null && _isHlsCachePath(existing)) {
      // 合并后的视频用同目录的清单文件。
      final parent = File(existing).parent.path;
      final name = existing.replaceAll('\\', '/').split('/').last.toLowerCase();
      if (name == 'index.m3u8') return existing;
      return _joinPath(parent, 'index.m3u8');
    }

    final dir = await _taskDirectory(task);
    final baseName = _stripExtension(task.filename);
    final folderName =
        '${_sanitizePathPart(baseName)}_${_sanitizePathPart(task.id)}.hls';
    return _joinPath(_joinPath(dir.path, folderName), 'index.m3u8');
  }

  Future<void> _downloadFile(DownloadTask task) async {
    // Hold a slot through permission, cancellation, remux and final cleanup.
    final run = _DownloadRun(task);
    _activeRuns.add(run);
    run.future = _runDownload(task, run);
    await run.future;
  }

  Future<void> _runDownload(DownloadTask task, _DownloadRun run) async {
    final cancelToken = run.token;
    task.status = DownloadStatus.downloading;
    try {
      if (task.kind == DownloadTaskKind.file &&
          Platform.isAndroid &&
          !await _requestStoragePermission()) {
        _throwIfCancelled(cancelToken);
        task.status = DownloadStatus.failed;
        return;
      }
      _throwIfCancelled(cancelToken);
      final filePath = task.kind == DownloadTaskKind.hls
          ? await _downloadHls(task, cancelToken, run)
          : await _downloadDirectFile(task, cancelToken);

      _throwIfCancelled(cancelToken);
      await _completeDownload(task, filePath, cancelToken);
    } on DioException catch (e) {
      if (cancelToken.isCancelled || e.type == DioExceptionType.cancel) return;
      if (_isDiskFull(e)) {
        _warn('磁盘空间不足或磁盘不可写，下载失败：${task.title}');
        task.status = DownloadStatus.failed;
        return;
      }
      if (task.kind == DownloadTaskKind.file &&
          e.response?.statusCode == 416 &&
          task.filePath != null) {
        final file = File(task.filePath!);
        await file.delete().catchError((_) => file);
        if (cancelToken.isCancelled) return;
        task.downloadedBytes = 0;
        task.progress = 0;
        task.totalBytes = 0;
        task.status = DownloadStatus.waiting;
        _waiting[task.id] = task;
      } else {
        task.status = DownloadStatus.failed;
      }
    } catch (e) {
      if (!cancelToken.isCancelled) {
        if (_isDiskFull(e)) {
          _warn('磁盘空间不足或磁盘不可写，下载失败：${task.title}');
        }
        task.status = DownloadStatus.failed;
      }
    } finally {
      run.token.cancel();
      if (task.status == DownloadStatus.downloading) {
        task.status = DownloadStatus.paused;
      }
      if (run.deleteOnFinish) {
        await _deleteTaskFiles(task).catchError((_) {});
        await _maybeRemoveSeriesDir(task).catchError((_) {});
      } else if (cancelToken.isCancelled) {
        // 刚开始下载就被取消：作品文件夹可能已建好但还没有任何内容。
        await _removeEmptySeriesDir(task).catchError((_) {});
      }
      _activeRuns.remove(run);
      if (run.deleteOnFinish) task.dispose();
      _notifyAndSave();
      _processQueue();
    }
  }

  Future<String> _downloadDirectFile(
    DownloadTask task,
    CancelToken cancelToken,
  ) async {
    final resolved = await _resolveDownloadFilePath(task);
    _throwIfCancelled(cancelToken);
    final filePath = await _resolveTargetPath(resolved);
    // 覆盖旧文件时从头重下，避免新旧内容拼在一起。
    if (_overwriteSameName) {
      final old = File(filePath);
      if (await old.exists()) await old.delete().catchError((_) => old);
    }
    task.filePath = filePath;

    final file = File(filePath);
    final resumePos = await file.exists() ? await file.length() : 0;
    _throwIfCancelled(cancelToken);
    task.downloadedBytes = resumePos;

    final progressClock = Stopwatch()..start();
    var lastProgress = -300;
    await client.download(
      task.url,
      filePath,
      cancelToken: cancelToken,
      deleteOnError: false,
      options: Options(
        headers: resumePos > 0 ? {'Range': 'bytes=$resumePos-'} : null,
      ),
      onReceiveProgress: (received, total) {
        if (cancelToken.isCancelled) return;
        final now = progressClock.elapsedMilliseconds;
        if (received != total && now - lastProgress < 300) return;
        lastProgress = now;
        final currentBytes = resumePos + received;
        task.downloadedBytes = currentBytes;
        if (total > 0) task.totalBytes = resumePos + total;
        task.progress = task.totalBytes > 0
            ? currentBytes / task.totalBytes
            : 0;
      },
    );

    return filePath;
  }

  Future<String> _downloadHls(
    DownloadTask task,
    CancelToken cancelToken,
    _DownloadRun run,
  ) async {
    final manifestPath = await _resolveHlsManifestPath(task);
    _throwIfCancelled(cancelToken);
    task.filePath = manifestPath;

    final cacheDir = File(manifestPath).parent;
    await cacheDir.create(recursive: true);

    final playlist = await _resolveMediaPlaylist(task.url, cancelToken);
    final result = await _cacheMediaPlaylist(
      task: task,
      playlist: playlist,
      cacheDir: cacheDir,
      cancelToken: cancelToken,
    );

    _throwIfCancelled(cancelToken);
    await File(manifestPath).writeAsString(result.localContent);
    _throwIfCancelled(cancelToken);
    task.downloadedBytes = result.totalBytes;
    task.totalBytes = result.totalBytes;
    // 分片下完后合成一个视频文件，方便直接播放。
    task.progress = 0.99;
    _notifyAndSave();

    // 拼接时让出下载位置，下一个任务可以开始。
    run.merging = true;
    _processQueue();
    String? remuxed;
    await _enqueueRemux(() async {
      remuxed = await HlsOfflineRemux.remuxManifest(
        manifestPath,
        checkCancelled: () => _throwIfCancelled(cancelToken),
      );
    });
    _throwIfCancelled(cancelToken);
    if (remuxed == null) {
      // 合并不了就保留原样。
      task.filePath = manifestPath;
      task.progress = 1;
      return manifestPath;
    }

    // 下好的视频移到用户选的保存目录，可直接播放。
    final dir = await _taskDirectory(task);
    final base = _stripExtension(task.filename);
    final ext = remuxed!.toLowerCase().endsWith('.ts') ? '.ts' : '.mp4';
    // 同名文件默认另存一份，打开开关才覆盖。
    final finalPath = await _resolveTargetPath(
      _joinPath(dir.path, '$base$ext'),
    );
    final src = File(remuxed!);
    final dst = File(finalPath);

    // 移好成品后才删缓存，避免把成品一起删掉。
    var moved = false;
    for (var attempt = 0; attempt < 3 && !moved; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (await dst.exists()) {
        try {
          await dst.delete();
        } catch (_) {}
      }
      try {
        await src.rename(finalPath);
        moved = true;
      } catch (_) {
        try {
          await src.copy(finalPath);
          await src.delete();
          moved = true;
        } catch (_) {}
      }
    }

    // 成品移走后清掉缓存文件夹。
    if (moved) {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await File(manifestPath).parent.delete(recursive: true);
          break;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
    }

    final usedPath = moved ? finalPath : remuxed!;
    task.filePath = usedPath;
    final length = await File(usedPath).length();
    task.downloadedBytes = length;
    task.totalBytes = length;
    task.progress = 1;
    return usedPath;
  }

  Future<_M3u8Playlist> _resolveMediaPlaylist(
    String url,
    CancelToken cancelToken,
  ) async {
    var playlistUrl = Uri.parse(url);
    var content = await _fetchPlaylistText(playlistUrl, cancelToken);

    // 视频和音频分开的源，合并后可能没声音，提示一次。
    if (content.contains('#EXT-X-MEDIA:TYPE=AUDIO')) {
      _warnAudioSeparated();
    }

    for (var i = 0; i < 4; i++) {
      final variantUrl = selectHlsVariant(content, playlistUrl);
      if (variantUrl == null) break;
      playlistUrl = variantUrl;
      content = await _fetchPlaylistText(playlistUrl, cancelToken);
    }

    if (!content.trimLeft().startsWith('#EXTM3U')) {
      throw StateError('Invalid m3u8 playlist');
    }
    return (url: playlistUrl, content: content);
  }

  Future<String> _fetchPlaylistText(Uri url, CancelToken cancelToken) async {
    final response = await client.get<String>(
      url.toString(),
      cancelToken: cancelToken,
      options: Options(responseType: ResponseType.plain),
    );
    return response.data ?? '';
  }

  Future<_HlsCacheResult> _cacheMediaPlaylist({
    required DownloadTask task,
    required _M3u8Playlist playlist,
    required Directory cacheDir,
    required CancelToken cancelToken,
  }) async {
    final plan = planHlsDownload(playlist.url, playlist.content);
    final assets = plan.assets;
    final totalUnits = assets.length;
    var next = 0, completedUnits = 0, downloadedBytes = 0;
    final concurrency = _hlsConcurrency;
    final received = List.filled(concurrency, 0);
    final fractions = List.filled(concurrency, 0.0);
    final clock = Stopwatch()..start();
    var lastPublish = -300;
    final assetToken = CancelToken();
    unawaited(cancelToken.whenCancel.then((error) => assetToken.cancel(error)));
    Object? failure;
    StackTrace? failureStack;

    void publish({bool force = false}) {
      if (cancelToken.isCancelled) return;
      final now = clock.elapsedMilliseconds;
      if (!force && now - lastPublish < 150) return;
      lastPublish = now;
      var bytes = downloadedBytes;
      var units = completedUnits.toDouble();
      for (var i = 0; i < concurrency; i++) {
        bytes += received[i];
        units += fractions[i];
      }
      task.downloadedBytes = bytes;
      task.progress = (units / totalUnits).clamp(0.0, 0.99);
    }

    Future<void> worker(int slot) async {
      try {
        while (next < totalUnits) {
          _throwIfCancelled(assetToken);
          final asset = assets[next++];
          // 控制同时下载的分片数，避免界面卡住。
          await _gate.acquire();
          try {
            final bytes = await _downloadHlsAsset(
              task,
              asset,
              cacheDir,
              assetToken,
              onProgress: (count, total) {
                if (assetToken.isCancelled) return;
                received[slot] = count;
                fractions[slot] = total > 0
                    ? (count / total).clamp(0.0, 1.0)
                    : 0.5;
                publish();
              },
            );
            _throwIfCancelled(assetToken);
            downloadedBytes += bytes;
            completedUnits++;
            received[slot] = 0;
            fractions[slot] = 0;
            publish();
          } finally {
            _gate.release();
          }
        }
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
        assetToken.cancel(error);
      }
    }

    await Future.wait([
      for (var slot = 0; slot < concurrency && slot < totalUnits; slot++)
        worker(slot),
    ]);
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
    _throwIfCancelled(cancelToken);
    publish(force: true);
    return (localContent: plan.localContent, totalBytes: downloadedBytes);
  }

  /// 分片下载失败时重新取地址再试，最多两次。
  Future<int> _downloadHlsAsset(
    DownloadTask task,
    HlsAsset asset,
    Directory cacheDir,
    CancelToken cancelToken, {
    required void Function(int received, int total) onProgress,
  }) async {
    var current = asset;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await _downloadHlsAssetOnce(
          current,
          cacheDir,
          cancelToken,
          onProgress: onProgress,
        );
      } catch (e) {
        if (cancelToken.isCancelled) rethrow;
        if (attempt == 2) rethrow;
        // 先删掉坏的分片，再重新取地址重试。
        final bad = File(_joinPath(cacheDir.path, current.localName));
        if (await bad.exists()) await bad.delete().catchError((_) {});
        final badPart = File('${bad.path}.part');
        if (await badPart.exists()) await badPart.delete().catchError((_) {});
        final fresh = await _resolveMediaPlaylist(task.url, cancelToken);
        final freshPlan = planHlsDownload(fresh.url, fresh.content);
        current = freshPlan.assets.firstWhere(
          (a) => a.localName == current.localName,
          orElse: () => current,
        );
      }
    }
    throw StateError('HLS 分片下载失败：${asset.localName}');
  }

  Future<int> _downloadHlsAssetOnce(
    HlsAsset asset,
    Directory cacheDir,
    CancelToken cancelToken, {
    required void Function(int received, int total) onProgress,
  }) async {
    final target = File(_joinPath(cacheDir.path, asset.localName));
    final range = asset.byteRange;
    if (await target.exists()) {
      final length = await target.length();
      // 分片已经裁好，可以直接用。
      if (length > 0 && (range == null || length == range.length)) {
        return length;
      }
      if (range != null && length >= range.offset + range.length) {
        await HlsOfflineRemux.sliceFileToByteRange(
          target,
          range,
          checkCancelled: () => _throwIfCancelled(cancelToken),
        );
        return target.length();
      }
    }

    final partial = File('${target.path}.part');
    if (await partial.exists()) await partial.delete();

    final headers = <String, dynamic>{};
    if (range != null) {
      // 尽量只下需要的那段。
      headers['Range'] =
          'bytes=${range.offset}-${range.offset + range.length - 1}';
    }

    await client.download(
      asset.url,
      partial.path,
      cancelToken: cancelToken,
      deleteOnError: false,
      options: headers.isEmpty ? null : Options(headers: headers),
      onReceiveProgress: onProgress,
    );

    _throwIfCancelled(cancelToken);
    if (await target.exists()) await target.delete();
    await partial.rename(target.path);

    if (range != null) {
      final length = await target.length();
      if (length != range.length && length >= range.offset + range.length) {
        await HlsOfflineRemux.sliceFileToByteRange(
          target,
          range,
          checkCancelled: () => _throwIfCancelled(cancelToken),
        );
      }
      // 分片大小不对就重下，避免拼接后花屏。
      final finalLength = await target.length();
      if (finalLength != range.length) {
        await target.delete().catchError((_) {});
        throw StateError(
          'segment ${asset.localName} size $finalLength != ${range.length}',
        );
      }
    } else if (await target.length() == 0) {
      // 无 byteRange 的分片至少要有内容。
      throw StateError('segment ${asset.localName} is empty');
    }
    return target.length();
  }

  Future<void> _completeDownload(
    DownloadTask task,
    String filePath,
    CancelToken token,
  ) async {
    if (task.kind == DownloadTaskKind.file) {
      try {
        await SaverGallery.saveFile(
          filePath: filePath,
          skipIfExists: false,
          fileName: task.filename,
          androidRelativePath: 'Movies',
        );
      } catch (e) {
        if (kDebugMode) debugPrint('SaverGallery error: $e');
      }
    }

    if (_downloadDanmaku &&
        task.bgmId != null &&
        task.episodeIndex != null) {
      try {
        final danmuList = await DanmakuController.fetchDanmaku(
          subjectId: task.bgmId!,
          episodeIndex: task.episodeIndex!,
          titles: buildSearchTitles([task.title]),
          abortTrigger: token.whenCancel.then((_) {}),
        );
        _throwIfCancelled(token);
        if (danmuList.isNotEmpty) {
          final dir = await _taskDirectory(task);
          final path = '${dir.path}/${task.filename}_danmaku.json';
          await File(
            path,
          ).writeAsString(DanmakuController.encodeDanmaku(danmuList));
          task.danmakuPath = path;
        }
      } catch (e) {
        if (kDebugMode) debugPrint('Danmaku fetch error: $e');
      }
    }

    _throwIfCancelled(token);
    task.status = DownloadStatus.completed;
    task.completedAt = DateTime.now();
    task.progress = 1.0;

    if (!_closed) onCompleted?.call(task);
  }

  Future<bool> _requestStoragePermission() async {
    final status = await Permission.videos.status;
    if (status.isGranted) return true;
    if (status.isDenied) return (await Permission.videos.request()).isGranted;
    return false;
  }

  String _stripExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0) return fileName;
    return fileName.substring(0, dot);
  }

  String _sanitizePathPart(String value) {
    final sanitized = value
        .replaceAll(_illegalPathCharsRe, '_')
        .replaceAll(_whitespaceRe, ' ')
        .trim();
    if (sanitized.isEmpty) return 'download';
    return sanitized.length > 80 ? sanitized.substring(0, 80) : sanitized;
  }

  String _joinPath(String parent, String child) {
    final separator = Platform.pathSeparator;
    if (parent.endsWith(separator)) return '$parent$child';
    return '$parent$separator$child';
  }

  /// 是不是在临时缓存文件夹里。
  bool _isHlsCachePath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.length >= 2 && parts[parts.length - 2].endsWith('.hls');
  }

  void _throwIfCancelled(CancelToken token) {
    if (token.isCancelled) throw token.cancelError!;
  }
}

class _DownloadRun {
  _DownloadRun(this.task);
  final DownloadTask task;
  final token = CancelToken();
  bool deleteOnFinish = false;

  /// 是否正在拼接视频；拼接时别的位置可以接着下载。
  bool merging = false;
  Future<void>? future;
}

class _DownloadTasksNotifier extends ValueNotifier<List<DownloadTask>> {
  _DownloadTasksNotifier() : super(<DownloadTask>[]);

  void changed() => notifyListeners();
}

typedef _M3u8Playlist = ({Uri url, String content});
typedef _HlsCacheResult = ({String localContent, int totalBytes});
