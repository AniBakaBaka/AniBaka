import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:baka/services/torrent/piece_manager.dart';

/// 本地 HTTP 流媒体服务器 — 将正在下载的 torrent 数据以 HTTP 方式提供给播放器。
/// 支持 Range 请求；数据未就绪时通过 PieceManager.nextProgress 事件驱动等待。
class TorrentStreamServer {
  static const int _chunkSize = 64 * 1024;
  static const Duration _stallTimeout = Duration(seconds: 60);
  static final RegExp _rangeRegex = RegExp(r'^bytes=(\d*)-(\d*)$');
  static const Map<String, String> _mimeTypes = {
    '.mkv': 'video/x-matroska',
    '.mp4': 'video/mp4',
    '.avi': 'video/x-msvideo',
    '.webm': 'video/webm',
    '.flv': 'video/x-flv',
    '.ts': 'video/mp2t',
    '.wmv': 'video/x-ms-wmv',
  };

  HttpServer? _server;
  PieceManager? _pieceManager;
  int _port = 0;

  String get streamUrl => 'http://127.0.0.1:$_port/stream.video';

  Future<void> start(PieceManager pieceManager) async {
    await stop();
    _pieceManager = pieceManager;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _port = server.port;
    server.listen(
      _handleRequest,
      onError: (e) => debugPrint('[StreamServer] 错误: $e'),
    );
    debugPrint('[StreamServer] 启动于 http://127.0.0.1:$_port');
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _pieceManager = null;
    _port = 0;
    await s?.close(force: true);
  }

  void _handleRequest(HttpRequest request) async {
    final pm = _pieceManager;
    final response = request.response;
    if (pm == null) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }

    final fileSize = pm.targetFile.length;
    final range = _parseRange(
      request.method == 'GET' ? request.headers.value('range') : null,
      fileSize,
    );
    if (range == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set('Content-Range', 'bytes */$fileSize');
      response.contentLength = 0;
      await response.close();
      return;
    }
    final (rangeStart, rangeEnd, isRange) = range;
    final contentLength = rangeEnd - rangeStart + 1;

    response.headers
      ..set('Content-Type', _mimeFor(pm.targetFile.path))
      ..set('Accept-Ranges', 'bytes')
      ..set('Content-Length', contentLength.toString())
      ..set('Connection', 'keep-alive');

    if (isRange) {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        'Content-Range',
        'bytes $rangeStart-$rangeEnd/$fileSize',
      );
    }

    try {
      if (request.method != 'HEAD') {
        // addStream propagates socket backpressure to the piece reader.
        await response.addStream(_readData(pm, rangeStart, contentLength));
      }
    } catch (_) {
      // 客户端断开等正常错误
    } finally {
      await response.close().catchError((_) {});
    }
  }

  /// Unsupported/malformed ranges are ignored; null means unsatisfiable.
  static (int start, int end, bool isRange)? _parseRange(
    String? header,
    int fileSize,
  ) {
    if (header == null) return (0, fileSize - 1, false);
    final m = _rangeRegex.firstMatch(header.trim());
    if (m == null) return (0, fileSize - 1, false);

    final rawStart = m.group(1)!;
    final rawEnd = m.group(2)!;
    if (rawStart.isEmpty && rawEnd.isEmpty) return (0, fileSize - 1, false);
    if (fileSize == 0) return null;

    // Only non-negative decimals match. Overflow can be saturated at fileSize:
    // starts are unsatisfiable, while ends and suffix lengths cover the tail.
    final end = int.tryParse(rawEnd) ?? fileSize;
    if (rawStart.isEmpty) {
      if (end == 0) return null;
      return ((fileSize - end).clamp(0, fileSize), fileSize - 1, true);
    }
    final start = int.tryParse(rawStart) ?? fileSize;
    if (start >= fileSize || end < start) return null;
    return (start, end.clamp(start, fileSize - 1), true);
  }

  Stream<List<int>> _readData(
    PieceManager pm,
    int fileOffset,
    int totalBytes,
  ) async* {
    var sent = 0;
    while (sent < totalBytes && !pm.isDisposed) {
      final toSend = (totalBytes - sent).clamp(1, _chunkSize);
      var data = pm.readFileData(fileOffset + sent, toSend);
      while (data == null) {
        if (pm.isDisposed) return;
        try {
          await pm.nextProgress.timeout(_stallTimeout);
        } on TimeoutException {
          return;
        }
        data = pm.readFileData(fileOffset + sent, toSend);
      }
      yield data;
      sent += toSend;
    }
  }

  static String _mimeFor(String path) {
    final lower = path.toLowerCase();
    final dot = lower.lastIndexOf('.');
    if (dot < 0) return 'application/octet-stream';
    return _mimeTypes[lower.substring(dot)] ?? 'application/octet-stream';
  }
}
