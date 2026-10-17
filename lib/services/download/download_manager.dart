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
  _DownloadRun? _active;
  bool _saveScheduled = false;

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
    _active?.token.cancel();
    try {
      await _initialization;
      await _running;
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
        _tasks.value = _restoreTasks(storedTasks);
        for (final task in tasks) {
          if (task.status == DownloadStatus.waiting) _waiting[task.id] = task;
        }
      }
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
    if (identical(_active?.task, task)) _active!.token.cancel();
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
    final active = _active;
    if (active != null && identical(active.task, task)) {
      active.deleteOnFinish = true;
      active.token.cancel();
    } else {
      _deleteTaskFiles(task).ignore();
    }
    tasks.remove(task);
    if (!identical(active?.task, task)) task.dispose();
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
    _active?.token.cancel();
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

  void clearCompleted() {
    tasks.removeWhere((task) {
      if (task.status != DownloadStatus.completed) return false;
      task.dispose();
      return true;
    });
    _notifyAndSave();
  }

  void _processQueue() {
    if (_closed || _active != null || _waiting.isEmpty) return;
    final task = _waiting.remove(_waiting.keys.first)!;
    _running = _downloadFile(task);
  }

  Future<Directory> _downloadDirectory() async {
    if (Instances.isDesktopPlatform) {
      return Instances.desktopDataDirectory('downloads');
    }
    return getApplicationDocumentsDirectory();
  }

  Future<String> _resolveDownloadFilePath(DownloadTask task) async {
    final dir = await _downloadDirectory();
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

    final dir = await _downloadDirectory();
    final baseName = _stripExtension(task.filename);
    final folderName =
        '${_sanitizePathPart(baseName)}_${_sanitizePathPart(task.id)}.hls';
    return _joinPath(_joinPath(dir.path, folderName), 'index.m3u8');
  }

  Future<void> _downloadFile(DownloadTask task) async {
    // Hold the slot through permission, cancellation, remux and final cleanup.
    final run = _active = _DownloadRun(task);
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
          ? await _downloadHls(task, cancelToken)
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
      _active = null;
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
    var lastProgress = -150;
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
        if (received != total && now - lastProgress < 150) return;
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
    final remuxed = await HlsOfflineRemux.remuxManifest(
      manifestPath,
      checkCancelled: () => _throwIfCancelled(cancelToken),
    );
    _throwIfCancelled(cancelToken);
    final playablePath = remuxed ?? manifestPath;
    task.filePath = playablePath;
    if (remuxed != null) {
      final length = await File(remuxed).length();
      task.downloadedBytes = length;
      task.totalBytes = length;
    }
    task.progress = 1;
    return playablePath;
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
    const concurrency = 4;
    final received = List.filled(concurrency, 0);
    final fractions = List.filled(concurrency, 0.0);
    final clock = Stopwatch()..start();
    var lastPublish = -150;
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

    if (task.bgmId != null && task.episodeIndex != null) {
      try {
        final danmuList = await DanmakuController.fetchDanmaku(
          subjectId: task.bgmId!,
          episodeIndex: task.episodeIndex!,
          titles: buildSearchTitles([task.title]),
          abortTrigger: token.whenCancel.then((_) {}),
        );
        _throwIfCancelled(token);
        if (danmuList.isNotEmpty) {
          final dir = await _downloadDirectory();
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
}

class _DownloadTasksNotifier extends ValueNotifier<List<DownloadTask>> {
  _DownloadTasksNotifier() : super(<DownloadTask>[]);

  void changed() => notifyListeners();
}

typedef _M3u8Playlist = ({Uri url, String content});
typedef _HlsCacheResult = ({String localContent, int totalBytes});
