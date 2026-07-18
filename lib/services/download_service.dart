import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/models/download_task.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/services/danmaku_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:get/get.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/pages/player/download_page.dart';
import 'package:saver_gallery/saver_gallery.dart';

class DownloadService {
  static const String _storageKey = 'download_tasks';
  static final DownloadService instance = DownloadService._();
  DownloadService._();

  final ValueNotifier<List<DownloadTask>> tasksNotifier = ValueNotifier([]);
  List<DownloadTask> get tasks => tasksNotifier.value;

  bool _initialized = false;
  final _readyCompleter = Completer<void>();
  Future<void> get ready => _readyCompleter.future;

  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 0),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
    ),
  );

  final Map<String, CancelToken> _cancelTokens = {};
  Timer? _saveTimer;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _load();
    _readyCompleter.complete();
    _processQueue();
  }

  Future<void> _load() async {
    try {
      final storedTasks = AppStorage.downloadTasksBox.get(_storageKey);
      if (storedTasks is List) {
        tasksNotifier.value = _restoreTasks(storedTasks);
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
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    try {
      await AppStorage.downloadTasksBox.put(
        _storageKey,
        tasks.map((task) => task.toJson()).toList(),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('DownloadService save error: $e');
    }
  }

  void _notifyAndSave() {
    tasksNotifier.value = List.from(tasks);
    _scheduleSave();
  }

  int addTasks(List<DownloadTask> newTasks) {
    final existingIds = tasks.map((e) => e.id).toSet();
    final filtered = newTasks
        .where((task) => !existingIds.contains(task.id))
        .toList();
    if (filtered.isEmpty) return 0;
    tasks.addAll(filtered);
    _notifyAndSave();
    _processQueue();
    return filtered.length;
  }

  void pause(DownloadTask task) {
    _cancelAndRemoveToken(task.id);
    task.status = DownloadStatus.paused;
    _notifyAndSave();
    _processQueue();
  }

  void resume(DownloadTask task) {
    task.status = DownloadStatus.waiting;
    _notifyAndSave();
    _processQueue();
  }

  void delete(DownloadTask task) {
    _cancelAndRemoveToken(task.id);
    _deleteTaskFiles(task).ignore();
    tasks.remove(task);
    _notifyAndSave();
  }

  Future<void> _deleteTaskFiles(DownloadTask task) async {
    final filePath = task.filePath;
    if (filePath == null || filePath.isEmpty) return;

    if (task.kind == DownloadTaskKind.hls && _isHlsCacheManifest(filePath)) {
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
    for (final task in tasks) {
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.waiting) {
        _cancelAndRemoveToken(task.id);
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
      }
    }
    _notifyAndSave();
    _processQueue();
  }

  void clearCompleted() {
    tasks.removeWhere((task) => task.status == DownloadStatus.completed);
    _notifyAndSave();
  }

  void _cancelAndRemoveToken(String id) {
    _cancelTokens[id]?.cancel();
    _cancelTokens.remove(id);
  }

  void _processQueue() {
    DownloadTask? nextWaiting;
    for (final task in tasks) {
      if (task.status == DownloadStatus.downloading) return;
      if (task.status == DownloadStatus.waiting) {
        nextWaiting ??= task;
      }
    }
    if (nextWaiting != null) _downloadFile(nextWaiting);
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
    if (existing != null && _isHlsCacheManifest(existing)) return existing;

    final dir = await _downloadDirectory();
    final baseName = _stripExtension(task.filename);
    final folderName =
        '${_sanitizePathPart(baseName)}_${_sanitizePathPart(task.id)}.hls';
    return _joinPath(_joinPath(dir.path, folderName), 'index.m3u8');
  }

  Future<void> _downloadFile(DownloadTask task) async {
    if (task.kind == DownloadTaskKind.file &&
        Platform.isAndroid &&
        !await _requestStoragePermission()) {
      task.status = DownloadStatus.failed;
      _notifyAndSave();
      return;
    }

    task.status = DownloadStatus.downloading;

    final cancelToken = CancelToken();
    _cancelTokens[task.id] = cancelToken;

    try {
      final filePath = task.kind == DownloadTaskKind.hls
          ? await _downloadHls(task, cancelToken)
          : await _downloadDirectFile(task, cancelToken);

      _cancelTokens.remove(task.id);
      await _completeDownload(task, filePath);
    } on DioException catch (e) {
      _cancelTokens.remove(task.id);
      if (e.type == DioExceptionType.cancel) {
        // pause() already updated the state.
      } else if (task.kind == DownloadTaskKind.file &&
          e.response?.statusCode == 416 &&
          task.filePath != null) {
        final file = File(task.filePath!);
        await file.delete().catchError((_) => file);
        task.downloadedBytes = 0;
        task.progress = 0;
        task.totalBytes = 0;
        task.status = DownloadStatus.waiting;
      } else {
        task.status = DownloadStatus.failed;
      }
    } catch (_) {
      task.status = DownloadStatus.failed;
    } finally {
      _notifyAndSave();
      _processQueue();
    }
  }

  Future<String> _downloadDirectFile(
    DownloadTask task,
    CancelToken cancelToken,
  ) async {
    final filePath = await _resolveDownloadFilePath(task);
    task.filePath = filePath;

    final file = File(filePath);
    final resumePos = await file.exists() ? await file.length() : 0;
    task.downloadedBytes = resumePos;

    await _dio.download(
      task.url,
      filePath,
      cancelToken: cancelToken,
      deleteOnError: false,
      options: Options(
        headers: resumePos > 0 ? {'Range': 'bytes=$resumePos-'} : null,
      ),
      onReceiveProgress: (received, total) {
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

    await File(manifestPath).writeAsString(result.localContent);
    task.downloadedBytes = result.totalBytes;
    task.totalBytes = result.totalBytes;
    task.progress = 1;
    return manifestPath;
  }

  Future<_M3u8Playlist> _resolveMediaPlaylist(
    String url,
    CancelToken cancelToken,
  ) async {
    var playlistUrl = Uri.parse(url);
    var content = await _fetchPlaylistText(playlistUrl, cancelToken);

    for (var i = 0; i < 4; i++) {
      final variantUrl = _selectBestVariant(content, playlistUrl);
      if (variantUrl == null) break;
      playlistUrl = variantUrl;
      content = await _fetchPlaylistText(playlistUrl, cancelToken);
    }

    if (!content.trimLeft().startsWith('#EXTM3U')) {
      throw StateError('Invalid m3u8 playlist');
    }
    return _M3u8Playlist(url: playlistUrl, content: content);
  }

  Future<String> _fetchPlaylistText(Uri url, CancelToken cancelToken) async {
    final response = await _dio.get<String>(
      url.toString(),
      cancelToken: cancelToken,
      options: Options(responseType: ResponseType.plain),
    );
    return response.data ?? '';
  }

  Uri? _selectBestVariant(String content, Uri playlistUrl) {
    final lines = const LineSplitter().convert(_normalizeM3u8Newlines(content));
    final variants = <_M3u8Variant>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;

      final bandwidth =
          int.tryParse(
            RegExp(r'BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ?? '',
          ) ??
          0;
      for (var j = i + 1; j < lines.length; j++) {
        final next = lines[j].trim();
        if (next.isEmpty) continue;
        if (next.startsWith('#')) break;
        variants.add(
          _M3u8Variant(url: playlistUrl.resolve(next), bandwidth: bandwidth),
        );
        break;
      }
    }

    if (variants.isEmpty) return null;
    variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    return variants.first.url;
  }

  Future<_HlsCacheResult> _cacheMediaPlaylist({
    required DownloadTask task,
    required _M3u8Playlist playlist,
    required Directory cacheDir,
    required CancelToken cancelToken,
  }) async {
    final lines = const LineSplitter().convert(
      _normalizeM3u8Newlines(playlist.content),
    );
    final rewritten = <String>[];
    final assets = <_HlsAsset>[];
    final localNameByUrl = <String, String>{};
    var segmentIndex = 0;
    var keyIndex = 0;
    var mapIndex = 0;

    String addAsset(String rawUrl, String localName) {
      final absoluteUrl = playlist.url.resolve(rawUrl).toString();
      return localNameByUrl.putIfAbsent(absoluteUrl, () {
        assets.add(_HlsAsset(url: absoluteUrl, localName: localName));
        return localName;
      });
    }

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('#EXT-X-KEY')) {
        final uri = _extractM3u8Attribute(line, 'URI');
        if (uri == null || uri.isEmpty) {
          rewritten.add(line);
          continue;
        }
        final localName = addAsset(
          uri,
          'key_${(keyIndex++).toString().padLeft(3, '0')}${_extensionFromUrl(uri, '.key')}',
        );
        rewritten.add(_replaceM3u8Attribute(line, 'URI', localName));
      } else if (trimmed.startsWith('#EXT-X-MAP')) {
        final uri = _extractM3u8Attribute(line, 'URI');
        if (uri == null || uri.isEmpty) {
          rewritten.add(line);
          continue;
        }
        final localName = addAsset(
          uri,
          'map_${(mapIndex++).toString().padLeft(3, '0')}${_extensionFromUrl(uri, '.mp4')}',
        );
        rewritten.add(_replaceM3u8Attribute(line, 'URI', localName));
      } else if (trimmed.isEmpty || trimmed.startsWith('#')) {
        rewritten.add(line);
      } else {
        final localName = addAsset(
          trimmed,
          'segment_${(segmentIndex++).toString().padLeft(5, '0')}${_extensionFromUrl(trimmed, '.ts')}',
        );
        rewritten.add(localName);
      }
    }

    if (segmentIndex == 0) {
      throw StateError('m3u8 playlist has no segments');
    }

    final totalUnits = assets.length;
    var completedUnits = 0;
    var downloadedBytes = 0;

    for (final asset in assets) {
      _throwIfCancelled(cancelToken, task.url);
      final bytes = await _downloadHlsAsset(
        asset,
        cacheDir,
        cancelToken,
        onProgress: (received, total) {
          final assetProgress = total > 0
              ? (received / total).clamp(0.0, 1.0)
              : 0.5;
          task.downloadedBytes = downloadedBytes + received;
          task.progress = totalUnits == 0
              ? 0
              : ((completedUnits + assetProgress) / totalUnits).clamp(
                  0.0,
                  0.99,
                );
        },
      );
      downloadedBytes += bytes;
      completedUnits++;
      task.downloadedBytes = downloadedBytes;
      task.progress = totalUnits == 0 ? 0 : completedUnits / totalUnits;
    }

    return _HlsCacheResult(
      localContent: '${rewritten.join('\n')}\n',
      totalBytes: downloadedBytes,
    );
  }

  Future<int> _downloadHlsAsset(
    _HlsAsset asset,
    Directory cacheDir,
    CancelToken cancelToken, {
    required void Function(int received, int total) onProgress,
  }) async {
    final target = File(_joinPath(cacheDir.path, asset.localName));
    if (await target.exists()) {
      final length = await target.length();
      if (length > 0) return length;
    }

    final partial = File('${target.path}.part');
    if (await partial.exists()) await partial.delete();

    await _dio.download(
      asset.url,
      partial.path,
      cancelToken: cancelToken,
      deleteOnError: false,
      onReceiveProgress: onProgress,
    );

    if (await target.exists()) await target.delete();
    await partial.rename(target.path);
    return target.length();
  }

  Future<void> _completeDownload(DownloadTask task, String filePath) async {
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
        final danmuList = await DanmakuService.getDanmakuItems(
          bgmId: task.bgmId!,
          episodeIndex: task.episodeIndex!,
          originalTitle: task.title,
        );
        if (danmuList.isNotEmpty) {
          final dir = await _downloadDirectory();
          final path = '${dir.path}/${task.filename}_danmaku.json';
          await File(
            path,
          ).writeAsString(jsonEncode(DanmakuService.serializeItems(danmuList)));
          task.danmakuPath = path;
        }
      } catch (e) {
        if (kDebugMode) debugPrint('Danmaku fetch error: $e');
      }
    }

    task.status = DownloadStatus.completed;
    task.completedAt = DateTime.now();
    task.progress = 1.0;

    showActionSnackBar(
      '已缓存 ${task.title}',
      actionLabel: '前往缓存中心',
      onAction: () {
        Get.to(() => const DownloadManagerPage());
      },
    );
  }

  Future<bool> _requestStoragePermission() async {
    final status = await Permission.videos.status;
    if (status.isGranted) return true;
    if (status.isDenied) return (await Permission.videos.request()).isGranted;
    return false;
  }

  String _normalizeM3u8Newlines(String content) {
    return content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  String? _extractM3u8Attribute(String line, String name) {
    final match = RegExp(
      '$name=("([^"]*)"|\'([^\']*)\'|[^,]*)',
    ).firstMatch(line);
    if (match == null) return null;

    final raw = match.group(1) ?? '';
    if ((raw.startsWith('"') && raw.endsWith('"')) ||
        (raw.startsWith("'") && raw.endsWith("'"))) {
      return raw.substring(1, raw.length - 1);
    }
    return raw.trim();
  }

  String _replaceM3u8Attribute(String line, String name, String value) {
    final pattern = RegExp('$name=("([^"]*)"|\'([^\']*)\'|[^,]*)');
    return line.replaceFirstMapped(pattern, (_) => '$name="$value"');
  }

  String _extensionFromUrl(String url, String fallback) {
    final path = Uri.tryParse(url)?.path ?? url;
    final fileName = path.split('/').last;
    final dot = fileName.lastIndexOf('.');
    if (dot == -1 || dot == fileName.length - 1) return fallback;

    final extension = fileName.substring(dot);
    if (extension.length > 8) return fallback;
    return extension;
  }

  String _stripExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0) return fileName;
    return fileName.substring(0, dot);
  }

  String _sanitizePathPart(String value) {
    final sanitized = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n]+'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (sanitized.isEmpty) return 'download';
    return sanitized.length > 80 ? sanitized.substring(0, 80) : sanitized;
  }

  String _joinPath(String parent, String child) {
    final separator = Platform.pathSeparator;
    if (parent.endsWith(separator)) return '$parent$child';
    return '$parent$separator$child';
  }

  bool _isHlsCacheManifest(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.length >= 2 &&
        parts.last == 'index.m3u8' &&
        parts[parts.length - 2].endsWith('.hls');
  }

  void _throwIfCancelled(CancelToken token, String url) {
    if (!token.isCancelled) return;
    throw DioException(
      requestOptions: RequestOptions(path: url),
      type: DioExceptionType.cancel,
    );
  }
}

class _M3u8Playlist {
  final Uri url;
  final String content;

  const _M3u8Playlist({required this.url, required this.content});
}

class _M3u8Variant {
  final Uri url;
  final int bandwidth;

  const _M3u8Variant({required this.url, required this.bandwidth});
}

class _HlsAsset {
  final String url;
  final String localName;

  const _HlsAsset({required this.url, required this.localName});
}

class _HlsCacheResult {
  final String localContent;
  final int totalBytes;

  const _HlsCacheResult({required this.localContent, required this.totalBytes});
}
