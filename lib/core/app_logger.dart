import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:baka/core/network_service.dart';
import 'package:baka/instance.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Application log. Debug/profile builds echo every line to the console;
/// info and above are appended to a rotating file in batches through one open
/// handle. Errors are written immediately. Lines logged before [init] are kept
/// and written once the file is open.
abstract final class Log {
  static const _maxFileBytes = 2 << 20;
  static const _maxFiles = 5;
  static const _maxStackLines = 24;
  static const _batchDelay = Duration(seconds: 2);
  static const _maxBufferedChars = 1 << 20;
  static const _console = kDebugMode || kProfileMode;

  /// Credentials in `key=value`, JSON and Authorization header forms.
  static final _secret = RegExp(
    r'''((?:token|authorization|password|pwd|cookie|secret)['"]?\s*[:=]\s*['"]?(?:(?:Bearer|Basic)\s+)?)[^,'"}&;\s\]]+|((?:Bearer|Basic)\s+)[\w.~+/=-]+''',
    caseSensitive: false,
  );

  static String? _dir;
  static RandomAccessFile? _file;
  static int _size = 0;
  static bool _ready = false;
  static final _pending = StringBuffer();
  static Timer? _timer;
  static Future<void> _io = Future.value();
  static Future<void>? _initializing;

  /// Console only; never persisted.
  static void d(String tag, Object? message) {
    if (_console) debugPrint('D/$tag: $message');
  }

  static void i(String tag, Object? message) => _log('I', tag, message);

  static void w(
    String tag,
    Object? message, [
    Object? error,
    StackTrace? stack,
  ]) => _log('W', tag, message, error, stack);

  static void e(
    String tag,
    Object? message, [
    Object? error,
    StackTrace? stack,
  ]) => _log('E', tag, message, error, stack);

  /// Runs [body] with uncaught errors logged; release builds silence `print`.
  static Future<void> runZoned(Future<void> Function() body) async {
    await runZonedGuarded(
      body,
      (error, stack) => e('Zone', 'Uncaught error', error, stack),
      zoneSpecification: _console
          ? null
          : ZoneSpecification(print: (_, _, _, _) {}),
    );
  }

  static Future<void> init() => _initializing ??= _open();

  static Future<void> _open() async {
    final dir = Instances.isDesktopPlatform
        ? await Instances.desktopDataDirectory('logs')
        : await Directory(
            _join((await getApplicationSupportDirectory()).path, 'logs'),
          ).create(recursive: true);
    _dir = dir.path;
    final file = File(_join(dir.path, 'app.log'));
    _size = await file.exists() ? await file.length() : 0;
    if (_size >= _maxFileBytes) {
      await _rotate();
    } else {
      _file = await file.open(mode: FileMode.append);
    }
    _ready = true;
    final flutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      e(
        'Flutter',
        details.context?.toDescription() ?? 'Framework error',
        details.exception,
        details.stack,
      );
      flutterError?.call(details);
    };
    final platformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      e('Platform', 'Uncaught error', error, stack);
      return platformError?.call(error, stack) ?? true;
    };
    await flush();
  }

  static void _log(
    String level,
    String tag,
    Object? message, [
    Object? error,
    StackTrace? stack,
  ]) {
    final line = StringBuffer()
      ..write(DateTime.now().toIso8601String())
      ..write(' $level/$tag: ')
      ..write(message);
    if (error != null) line.write('\n  $error');
    if (stack != null) {
      final frames = stack.toString().trimRight().split('\n');
      for (final frame in frames.take(_maxStackLines)) {
        line.write('\n  $frame');
      }
      if (frames.length > _maxStackLines) line.write('\n  …');
    }
    final text = line.toString().replaceAllMapped(
      _secret,
      (m) => '${m[1] ?? m[2]}***',
    );
    if (_console) debugPrint(text);
    if (!_ready && _pending.length > _maxBufferedChars) _pending.clear();
    _pending.writeln(text);
    if (!_ready) return;
    if (level == 'E') {
      flush();
    } else {
      _timer ??= Timer(_batchDelay, flush);
    }
  }

  /// Writes buffered lines; completes after all earlier writes.
  static Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (!_ready || _pending.isEmpty) return _io;
    final bytes = utf8.encode(_pending.toString());
    _pending.clear();
    return _io = _io.then((_) => _append(bytes)).catchError((Object error) {
      if (_console) debugPrint('Log write failed: $error');
    });
  }

  static Future<void> _append(Uint8List bytes) async {
    if (_size + bytes.length > _maxFileBytes) await _rotate();
    await _file!.writeFrom(bytes);
    _size += bytes.length;
  }

  /// app.log → app.1.log → … → app.{_maxFiles - 1}.log (dropped).
  static Future<void> _rotate() async {
    await _file?.close();
    for (var index = _maxFiles - 1; index > 0; index--) {
      final source = File(_join(_dir!, _fileName(index - 1)));
      if (await source.exists()) {
        await source.rename(_join(_dir!, _fileName(index)));
      }
    }
    _file = await File(_join(_dir!, 'app.log')).open(mode: FileMode.write);
    _size = 0;
  }

  static String _fileName(int index) =>
      index == 0 ? 'app.log' : 'app.$index.log';

  static String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';

  static String _stamp() =>
      DateTime.now().toIso8601String().replaceAll(RegExp('[:.]'), '-');

  /// Zips the current logs, newest first, into the temporary directory.
  static Future<LogArchive> createArchive() async {
    await flush();
    final files = <File>[];
    if (_dir case final dir?) {
      for (var index = 0; index < _maxFiles; index++) {
        final file = File(_join(dir, _fileName(index)));
        if (await file.exists()) files.add(file);
      }
    }
    final temp = await Directory(
      _join((await getTemporaryDirectory()).path, 'baka_logs'),
    ).create(recursive: true);
    final name = 'baka-logs-${_stamp()}.zip';
    final file = File(_join(temp.path, name));
    final zip = ZipFileEncoder()..create(file.path);
    for (final log in files) {
      await zip.addFile(log, log.uri.pathSegments.last);
    }
    if (files.isEmpty) {
      zip.addArchiveFile(ArchiveFile.string('empty.log', 'No log files.'));
    }
    await zip.close();
    return LogArchive(file, name, files.length, await file.length());
  }

  /// Saves an archive where the user picks; null when cancelled.
  static Future<LogArchive?> exportLogs() async {
    final archive = await createArchive();
    final desktop = Instances.isDesktopPlatform;
    final path = await FilePicker.saveFile(
      dialogTitle: 'Export Baka logs',
      fileName: archive.fileName,
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      lockParentWindow: true,
      bytes: desktop ? null : await archive.file.readAsBytes(),
    );
    if (path == null) return null;
    final saved = desktop
        ? await archive.file.copy(
            path.toLowerCase().endsWith('.zip') ? path : '$path.zip',
          )
        : File(path);
    return LogArchive(
      saved,
      saved.uri.pathSegments.last,
      archive.logFileCount,
      archive.sizeBytes,
    );
  }

  static Future<ShareResult> shareLogs() async {
    final archive = await createArchive();
    return SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            archive.file.path,
            name: archive.fileName,
            mimeType: 'application/zip',
          ),
        ],
        subject: 'Baka logs',
      ),
    );
  }
}

class LogArchive {
  const LogArchive(this.file, this.fileName, this.logFileCount, this.sizeBytes);

  final File file;
  final String fileName;
  final int logFileCount;
  final int sizeBytes;
}

/// Serves one log archive on the LAN at an unguessable path, so a phone can
/// download a TV's logs by scanning a QR code.
class LogShareServer {
  HttpServer? _server;
  final downloads = ValueNotifier<int>(0);

  Future<({String url, LogArchive archive})> start() async {
    if (_server != null) throw StateError('日志导出服务已启动');
    final archive = await Log.createArchive();
    final address = await NetworkService.findLanIpv4();
    if (address == null) throw StateError('未找到可用的局域网地址，请检查电视网络连接');
    final random = Random.secure();
    final token = base64UrlEncode([
      for (var i = 0; i < 18; i++) random.nextInt(256),
    ]);
    final path = '/logs/$token/${Uri.encodeComponent(archive.fileName)}';
    final server = _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server.listen((request) => _serve(request, path, archive));
    Log.i('LogShare', 'Serving ${archive.fileName} on ${address.address}');
    return (
      url: 'http://${address.address}:${server.port}$path',
      archive: archive,
    );
  }

  Future<void> _serve(
    HttpRequest request,
    String path,
    LogArchive archive,
  ) async {
    final response = request.response;
    if (request.method != 'GET' || request.uri.path != path) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    try {
      response.headers
        ..contentType = ContentType('application', 'zip')
        ..set(
          'content-disposition',
          'attachment; filename="${archive.fileName}"',
        )
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..contentLength = archive.sizeBytes;
      await response.addStream(archive.file.openRead());
      await response.close();
      downloads.value++;
    } catch (error) {
      Log.w('LogShare', 'Download failed', error);
      await response.close();
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}
