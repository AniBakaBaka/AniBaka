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

///  async 信号量：跨任务共享的 HLS 分片下载并发上限。
///
/// 每个任务内部有 N 个 worker，若不限流，6 任务 × 32 分片 = 192 路并发请求
/// 会把主 isolate 的事件循环塞满，导致界面明显卡顿。全局闸门把同时在飞的
/// 分片请求压回设置值。
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

  Future<void>? _initialization;
  Future<void>? _running;
  bool _closed = false;
  void Function(DownloadTask task)? onCompleted;

  /// 视频与图片下载共用连接池、系统代理和应用关闭时的资源释放。
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

  /// HLS 分片并发下载数（设置中可调，默认 16，数值越大越快）。
  int get _hlsConcurrency {
    try {
      final v = Instances.sp.getInt('download_hls_concurrency');
      return v != null && v > 0 ? v : 16;
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

  /// 跨任务共享的 HLS 分片并发闸门（首次使用时按设置值创建）。
  ///
  /// 上限压到 16：分片请求的处理（TLS 解密、分块事件）全在主 isolate，
  /// 32 路以上会挤占 UI 帧调度造成明显掉帧；16 路足以跑满常见带宽。
  _Semaphore? _hlsGate;
  _Semaphore get _gate =>
      _hlsGate ??= _Semaphore(_hlsConcurrency > 16 ? 16 : _hlsConcurrency);

  /// 分片拼接（remux）串行锁：拼接是磁盘大块读写，多个一起跑会形成
  /// 磁盘寻道风暴（系统级卡顿），串行反而总吞吐更高。
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
        // 清理无效任务：失败的任务，以及记录指向的本地文件已不存在的
        // 任务（文件被外部移动/删除）。waiting 且尚未落盘的不受影响。
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
      // Hive 是追加写：任务状态每次变化都会留下一帧死数据，文件只增不减。
      // 启动时压实一次，避免长期使用后无谓膨胀。
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
    if (active != null) {
      active.deleteOnFinish = true;
      active.token.cancel();
    } else {
      _deleteTaskFiles(task).ignore();
    }
    tasks.remove(task);
    if (active == null) task.dispose();
    _notifyAndSave();
  }

  Future<void> _deleteTaskFiles(DownloadTask task) async {
    final filePath = task.filePath;
    if (filePath == null || filePath.isEmpty) return;

    // HLS 缓存目录（index.m3u8 或 remux 后的 video.mp4 / video.ts）。
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
    for (final task in completed) {
      await _deleteTaskFiles(task);
      task.dispose();
    }
    tasks.removeWhere((task) => task.status == DownloadStatus.completed);
    _notifyAndSave();
  }

  void _processQueue() {
    if (_closed || _waiting.isEmpty) return;
    // 合并中的任务不占下载槽：只有还在跑网络下载的任务计入并发。
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

  /// 优先使用任务自定义保存目录，否则回退到默认下载目录。
  Future<Directory> _taskDirectory(DownloadTask task) async {
    final custom = task.saveDir;
    if (custom != null && custom.isNotEmpty) {
      final dir = Directory(custom);
      if (await dir.exists()) return dir;
    }
    return _downloadDirectory();
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
      // 已 remux 成 video.mp4/ts 时，清单路径固定为同目录 index.m3u8。
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
    } catch (_) {
      if (!cancelToken.isCancelled) task.status = DownloadStatus.failed;
    } finally {
      run.token.cancel();
      if (task.status == DownloadStatus.downloading) {
        task.status = DownloadStatus.paused;
      }
      if (run.deleteOnFinish) await _deleteTaskFiles(task).catchError((_) {});
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
    final filePath = await _resolveDownloadFilePath(task);
    _throwIfCancelled(cancelToken);
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
    // 分片下完后合并为单一视频，播放时走普通文件 seek，不再依赖 m3u8。
    task.progress = 0.99;
    _notifyAndSave();

    // 拼接是纯本地 IO，不再占用下载槽：立刻补位下一个等待任务，
    // 并用全局串行锁保证同一时间只有一个视频在拼接（磁盘友好）。
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
      // 无法拼接（如加密流），保留本地 m3u8 结构，行为与旧版一致。
      task.filePath = manifestPath;
      task.progress = 1;
      return manifestPath;
    }

    // 成品移出 .hls 缓存文件夹，直接放到用户选择的保存目录，
    // 文件名与任务一致（xxx.mp4 / xxx.ts），本地播放器可直接连续播放。
    final dir = await _taskDirectory(task);
    final base = _stripExtension(task.filename);
    final ext = remuxed!.toLowerCase().endsWith('.ts') ? '.ts' : '.mp4';
    final finalPath = _joinPath(dir.path, '$base$ext');
    final src = File(remuxed!);
    final dst = File(finalPath);

    // 移动必须成功：失败重试（Windows 句柄释放有延迟）。在成品安全
    // 落位之前，绝不能删除缓存文件夹——否则唯一成品会被一起删掉。
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

    // 只有成品已安全移出才清理缓存文件夹；删除失败也重试，
    // 避免留下空文件夹。
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
          // 全局闸门：多任务并行时把同时在飞的分片请求压回设置值，
          // 避免几十上百路并发请求挤爆主 isolate 的事件循环卡住界面。
          await _gate.acquire();
          try {
            final bytes = await _downloadHlsAsset(
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

  Future<int> _downloadHlsAsset(
    HlsAsset asset,
    Directory cacheDir,
    CancelToken cancelToken, {
    required void Function(int received, int total) onProgress,
  }) async {
    final target = File(_joinPath(cacheDir.path, asset.localName));
    final range = asset.byteRange;
    if (await target.exists()) {
      final length = await target.length();
      // 已按 BYTERANGE 裁好，或无无完整文件可直接用。
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
      // 优先让服务端只回传分片；若忽略 Range 则下完再裁。
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

  /// 是否位于 `*.hls/` 缓存目录（清单或 remux 后的单文件）。
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

  /// true = 已进入分片拼接阶段（纯本地 IO，不再占用网络下载槽），
  /// 让后续任务可以继续下载，避免"合并时全部排队等待"。
  bool merging = false;
  Future<void>? future;
}

class _DownloadTasksNotifier extends ValueNotifier<List<DownloadTask>> {
  _DownloadTasksNotifier() : super(<DownloadTask>[]);

  void changed() => notifyListeners();
}

typedef _M3u8Playlist = ({Uri url, String content});
typedef _HlsCacheResult = ({String localContent, int totalBytes});
