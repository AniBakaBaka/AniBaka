import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:baka/utils/app_logger.dart';

class TvLogExportSession {
  TvLogExportSession({
    Future<LogArchive> Function()? createArchive,
    Future<InternetAddress?> Function()? findLanAddress,
  }) : _createArchive = createArchive ?? AppLogger.instance.createLogArchive,
       _findAddress = findLanAddress;

  final Future<LogArchive> Function() _createArchive;
  final Future<InternetAddress?> Function()? _findAddress;
  HttpServer? _server;
  LogArchive? _archive;
  String? _token;

  final _downloadCount = StreamController<int>.broadcast();
  Stream<int> get downloadCount => _downloadCount.stream;
  int _downloads = 0;

  Future<TvLogExportInfo> start() async {
    if (_server != null) {
      throw StateError('日志导出服务已启动');
    }

    final archive = await _createArchive();
    final address = await (_findAddress?.call() ?? _findLanAddress());
    if (address == null) {
      throw StateError('未找到可用的局域网地址，请检查电视网络连接');
    }

    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final token = _createToken();
    _archive = archive;
    _server = server;
    _token = token;
    server.listen(_handleRequest);

    final encodedName = Uri.encodeComponent(archive.fileName);
    return TvLogExportInfo(
      url: 'http://${address.address}:${server.port}/logs/$token/$encodedName',
      archive: archive,
    );
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    if (!_downloadCount.isClosed) await _downloadCount.close();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final archive = _archive;
    final token = _token;
    final expectedPath = archive == null || token == null
        ? null
        : '/logs/$token/${Uri.encodeComponent(archive.fileName)}';

    if (request.method != 'GET' || request.uri.path != expectedPath) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..headers.contentType = ContentType.text
        ..write('Not found');
      await request.response.close();
      return;
    }

    try {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType(
          'application',
          'zip',
          parameters: const {'charset': 'binary'},
        )
        ..headers.set(
          'content-disposition',
          'attachment; filename="${archive!.fileName}"',
        )
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..contentLength = archive.sizeBytes;
      await request.response.addStream(archive.file.openRead());
      await request.response.close();
      _downloads++;
      if (!_downloadCount.isClosed) _downloadCount.add(_downloads);
      AppLogger.instance.info(
        'TV logs downloaded ($_downloads)',
        tag: 'TvLogExport',
      );
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'TV log download failed',
        tag: 'TvLogExport',
        error: error,
        stackTrace: stackTrace,
      );
      await request.response.close();
    }
  }

  Future<InternetAddress?> _findLanAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final addresses = [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (!address.isLoopback && !address.isLinkLocal) address,
    ];
    if (addresses.isEmpty) return null;
    return addresses.cast<InternetAddress?>().firstWhere(
      (address) => _isPrivateAddress(address!.address),
      orElse: () => addresses.first,
    );
  }

  bool _isPrivateAddress(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return false;
    final first = int.tryParse(parts[0]);
    final second = int.tryParse(parts[1]);
    return first == 10 ||
        (first == 172 && second != null && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }

  String _createToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

class TvLogExportInfo {
  const TvLogExportInfo({required this.url, required this.archive});

  final String url;
  final LogArchive archive;
}
