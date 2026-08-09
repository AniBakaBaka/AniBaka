import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/models/download_task.dart';
import 'package:baka/pages/player/download_page.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/services/danmaku_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/hls_offline_remux.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saver_gallery/saver_gallery.dart';

class DownloadService {
  static const String _storageKey = 'download_tasks';
  static final DownloadService instance = DownloadService._();
  DownloadService._();

  static final _bandwidthRe = RegExp(r'BANDWIDTH=(\d+)');
  static final _illegalPathCharsRe = RegExp(r'[\\/:*?"<>|\r\n]+');
  static final _whitespaceRe = RegExp(r'\s+');

  final _DownloadTasksNotifier _tasks = _DownloadTasksNotifier();
  ValueListenable<List<DownloadTask>> get tasksListenable => _tasks;
  List<DownloadTask> get tasks => _tasks.value;

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
  bool _saveScheduled = false;

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
        _tasks.value = _restoreTasks(storedTasks);
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
      added++;
    }
    if (added == 0) return 0;
    _notifyAndSave();
    _processQueue();
    return added;
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
    // 分片下完后合并为单一视频，播放时走普通文件 seek，不再依赖 m3u8。
    task.progress = 0.99;
    _notifyAndSave();
    final remuxed = await HlsOfflineRemux.remuxManifest(manifestPath);
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

  /// 取码率最高的变体。单趟扫描直接留最大值，不再物化整张变体表再排序。
  Uri? _selectBestVariant(String content, Uri playlistUrl) {
    final lines = const LineSplitter().convert(content);
    Uri? best;
    var bestBandwidth = -1;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;

      final bandwidth =
          int.tryParse(_bandwidthRe.firstMatch(line)?.group(1) ?? '') ?? 0;
      if (bandwidth <= bestBandwidth) continue;

      for (var j = i + 1; j < lines.length; j++) {
        final next = lines[j].trim();
        if (next.isEmpty) continue;
        if (next.startsWith('#')) break;
        best = playlistUrl.resolve(next);
        bestBandwidth = bandwidth;
        break;
      }
    }
    return best;
  }

  Future<_HlsCacheResult> _cacheMediaPlaylist({
    required DownloadTask task,
    required _M3u8Playlist playlist,
    required Directory cacheDir,
    required CancelToken cancelToken,
  }) async {
    // LineSplitter 本身按 CR / LF / CRLF 切分，无需先把整份清单重建两遍。
    final lines = const LineSplitter().convert(playlist.content);
    final rewritten = <String>[];
    final assets = <_HlsAsset>[];
    // 同一 URL 不同 BYTERANGE 必须落成不同本地文件。
    final localNameByKey = <String, String>{};
    var segmentIndex = 0;
    var keyIndex = 0;
    var mapIndex = 0;
    HlsByteRange? pendingByteRange;

    String addAsset(
      String rawUrl,
      String localName, {
      HlsByteRange? byteRange,
    }) {
      final absoluteUrl = playlist.url.resolve(rawUrl).toString();
      final key = byteRange == null
          ? absoluteUrl
          : '$absoluteUrl#${byteRange.offset}:${byteRange.length}';
      return localNameByKey.putIfAbsent(key, () {
        assets.add(
          _HlsAsset(
            url: absoluteUrl,
            localName: localName,
            byteRange: byteRange,
          ),
        );
        return localName;
      });
    }

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.toUpperCase().startsWith('#EXT-X-BYTERANGE:')) {
        pendingByteRange = HlsByteRange.tryParse(
          trimmed.substring('#EXT-X-BYTERANGE:'.length),
        );
        // 离线文件是完整分片，清单里不再保留 BYTERANGE。
        continue;
      }

      final isKey = trimmed.startsWith('#EXT-X-KEY');
      if (isKey || trimmed.startsWith('#EXT-X-MAP')) {
        final uri = _m3u8Attribute(line, 'URI');
        if (uri == null || uri.value.isEmpty) {
          rewritten.add(line);
          continue;
        }
        final mapRange = HlsByteRange.tryParse(
          _m3u8Attribute(line, 'BYTERANGE')?.value,
        );
        final localName = addAsset(
          uri.value,
          isKey
              ? 'key_${(keyIndex++).toString().padLeft(3, '0')}'
                    '${_extensionFromUrl(uri.value, '.key')}'
              : 'map_${(mapIndex++).toString().padLeft(3, '0')}'
                    '${_extensionFromUrl(uri.value, '.mp4')}',
          byteRange: mapRange,
        );
        // 去掉 MAP 上的 BYTERANGE，URI 换成本地名。
        var mapped = line.replaceRange(uri.start, uri.end, 'URI="$localName"');
        mapped = mapped.replaceAll(
          RegExp(r',?\s*BYTERANGE=(?:"[^"]+"|[^\s,]+)', caseSensitive: false),
          '',
        );
        rewritten.add(mapped);
        pendingByteRange = null;
      } else if (trimmed.isEmpty || trimmed.startsWith('#')) {
        rewritten.add(line);
      } else {
        final range = pendingByteRange;
        pendingByteRange = null;
        final localName = addAsset(
          trimmed,
          'segment_${(segmentIndex++).toString().padLeft(5, '0')}${_extensionFromUrl(trimmed, '.ts')}',
          byteRange: range,
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

    // 清单仅作 remux 中间产物；分片已按 BYTERANGE 裁好，URI 为本地文件名。
    var localContent = '${rewritten.join('\n')}\n';
    if (!localContent.contains('#EXT-X-ENDLIST')) {
      localContent = '$localContent#EXT-X-ENDLIST\n';
    }
    return _HlsCacheResult(
      localContent: localContent,
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
    final range = asset.byteRange;
    if (await target.exists()) {
      final length = await target.length();
      // 已按 BYTERANGE 裁好，或无无完整文件可直接用。
      if (length > 0 && (range == null || length == range.length)) {
        return length;
      }
      if (range != null && length >= range.offset + range.length) {
        await HlsOfflineRemux.sliceFileToByteRange(target, range);
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

    await _dio.download(
      asset.url,
      partial.path,
      cancelToken: cancelToken,
      deleteOnError: false,
      options: headers.isEmpty ? null : Options(headers: headers),
      onReceiveProgress: onProgress,
    );

    if (await target.exists()) await target.delete();
    await partial.rename(target.path);

    if (range != null) {
      final length = await target.length();
      if (length != range.length && length >= range.offset + range.length) {
        await HlsOfflineRemux.sliceFileToByteRange(target, range);
      }
    }
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
        final danmuList = await DanmakuService.fetch(
          subjectId: task.bgmId!,
          episodeIndex: task.episodeIndex!,
          titles: BgmUtils.buildSearchTitles([task.title]),
        );
        if (danmuList.isNotEmpty) {
          final dir = await _downloadDirectory();
          final path = '${dir.path}/${task.filename}_danmaku.json';
          await File(path).writeAsString(DanmakuService.encode(danmuList));
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

  /// 定位 `NAME=` 属性并同时给出值与可替换区间。
  ///
  /// 取代原先「按属性名现编正则、读一次、再编一次同样的正则写回」的两趟写法：
  /// 属性语法只有「引号包裹」和「读到逗号为止」两种，单趟扫描即可，且每行零正则编译。
  static ({int start, int end, String value})? _m3u8Attribute(
    String line,
    String name,
  ) {
    final at = line.indexOf('$name=');
    if (at < 0) return null;

    final valueStart = at + name.length + 1;
    if (valueStart < line.length) {
      final quote = line.codeUnitAt(valueStart);
      if (quote == 0x22 || quote == 0x27) {
        final close = line.indexOf(String.fromCharCode(quote), valueStart + 1);
        if (close > 0) {
          return (
            start: at,
            end: close + 1,
            value: line.substring(valueStart + 1, close),
          );
        }
      }
    }

    var end = line.indexOf(',', valueStart);
    if (end < 0) end = line.length;
    return (start: at, end: end, value: line.substring(valueStart, end).trim());
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

  void _throwIfCancelled(CancelToken token, String url) {
    if (!token.isCancelled) return;
    throw DioException(
      requestOptions: RequestOptions(path: url),
      type: DioExceptionType.cancel,
    );
  }
}

class _DownloadTasksNotifier extends ValueNotifier<List<DownloadTask>> {
  _DownloadTasksNotifier() : super(<DownloadTask>[]);

  void changed() => notifyListeners();
}

class _M3u8Playlist {
  final Uri url;
  final String content;

  const _M3u8Playlist({required this.url, required this.content});
}

class _HlsAsset {
  final String url;
  final String localName;
  final HlsByteRange? byteRange;

  const _HlsAsset({required this.url, required this.localName, this.byteRange});
}

class _HlsCacheResult {
  final String localContent;
  final int totalBytes;

  const _HlsCacheResult({required this.localContent, required this.totalBytes});
}
