import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:baka/instance.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

enum LogLevel {
  debug('DEBUG', 500),
  info('INFO', 800),
  warning('WARN', 900),
  error('ERROR', 1000);

  const LogLevel(this.label, this.developerLevel);

  final String label;
  final int developerLevel;
}

class AppLogger {
  AppLogger._();

  static const int _maxLogFileBytes = 2 * 1024 * 1024;
  static const int _maxLogFiles = 5;
  static const String _activeLogFileName = 'app.log';
  static const LogLevel _minimumPersistedLevel = LogLevel.info;

  static final AppLogger instance = AppLogger._();

  static final _redactKeyValueRe = RegExp(
    r'''((?:['"]?)(?:token|refresh_token|authorization|password|cookie|set-cookie|usertoken)(?:['"]?)\s*[:=]\s*(?:['"]?))([^,'"}\s\]]+)''',
    caseSensitive: false,
  );
  static final _redactAuthHeaderRe = RegExp(
    r'((?:Bearer|Basic)\s+)[A-Za-z0-9._~+/=-]+',
    caseSensitive: false,
  );

  Directory? _logDirectory;
  File? _logFile;
  int _currentLogFileBytes = 0;
  bool _initialized = false;
  bool _errorHandlersInstalled = false;
  Future<void> _writeQueue = Future<void>.value();

  static Future<void> runZoned(Future<void> Function() body) async {
    await runZonedGuarded(
      body,
      (Object error, StackTrace stackTrace) {
        AppLogger.instance.error(
          'Uncaught zone error',
          tag: 'Zone',
          error: error,
          stackTrace: stackTrace,
        );
      },
      zoneSpecification: ZoneSpecification(
        // release 模式下静默 print，debug/profile 下原样输出。
        print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
          if (kDebugMode || kProfileMode) parent.print(zone, line);
        },
      ),
    );
  }

  Future<void> init() async {
    if (_initialized) return;

    _logDirectory = await _resolveLogDirectory();
    if (!await _logDirectory!.exists()) {
      await _logDirectory!.create(recursive: true);
    }

    _logFile = File(_joinPath(_logDirectory!.path, _activeLogFileName));
    if (await _logFile!.exists()) {
      _currentLogFileBytes = await _logFile!.length();
      if (_currentLogFileBytes >= _maxLogFileBytes) {
        await _rotateLogs();
      }
    } else {
      await _logFile!.create(recursive: true);
      _currentLogFileBytes = 0;
    }

    _initialized = true;
    _installGlobalErrorHandlers();
    info('Logger initialized (${_logFile?.path})', tag: 'Logger');
  }

  void debug(Object? message, {String? tag, Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.debug, message, tag: tag, error: error, stackTrace: stackTrace);

  void info(Object? message, {String? tag, Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.info, message, tag: tag, error: error, stackTrace: stackTrace);

  void warning(Object? message, {String? tag, Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.warning, message, tag: tag, error: error, stackTrace: stackTrace);

  void error(Object? message, {String? tag, Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.error, message, tag: tag, error: error, stackTrace: stackTrace);

  Future<void> flush() => _writeQueue;

  Future<List<File>> logFiles() async {
    await flush();
    final directory = _logDirectory;
    if (directory == null || !await directory.exists()) {
      return <File>[];
    }

    final entries = <(File, DateTime)>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.log')) {
        continue;
      }
      entries.add((entity, (await entity.stat()).modified));
    }

    entries.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final entry in entries) entry.$1];
  }

  Future<LogArchive> createLogArchive() async {
    final files = await logFiles();
    final archive = Archive();
    for (final file in files) {
      if (!await file.exists()) continue;

      final bytes = await file.readAsBytes();
      archive.addFile(ArchiveFile(_fileName(file.path), bytes.length, bytes));
    }

    if (archive.files.isEmpty) {
      final message = utf8.encode('No log files were found.');
      archive.addFile(ArchiveFile('empty.log', message.length, message));
    }

    final archiveBytes = ZipEncoder().encode(archive);

    final archiveFileName = _logArchiveFileName();
    final archiveFile = File(
      _joinPath(await _temporaryDirectoryPath(), archiveFileName),
    );
    await archiveFile.writeAsBytes(archiveBytes, flush: true);

    return LogArchive(
      file: archiveFile,
      fileName: archiveFileName,
      logFileCount: files.length,
      sizeBytes: archiveBytes.length,
    );
  }

  Future<LogArchive?> exportLogs() async {
    final archive = await createLogArchive();

    final bytes = Instances.isDesktopPlatform
        ? null
        : await archive.file.readAsBytes();

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Baka logs',
      fileName: archive.fileName,
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      lockParentWindow: true,
      bytes: bytes,
    );

    if (savePath == null) return null;

    final savedFile = Instances.isDesktopPlatform
        ? await archive.file.copy(_ensureZipExtension(savePath))
        : File(savePath);

    return LogArchive(
      file: savedFile,
      fileName: _fileName(savedFile.path),
      logFileCount: archive.logFileCount,
      sizeBytes: archive.sizeBytes,
    );
  }

  Future<ShareResult> shareLogs() async {
    final archive = await createLogArchive();
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
        text: 'Baka logs ${DateTime.now().toIso8601String()}',
      ),
    );
  }

  void _installGlobalErrorHandlers() {
    if (_errorHandlersInstalled) return;
    _errorHandlersInstalled = true;

    final previousFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      error(
        'Flutter framework error',
        tag: 'Flutter',
        error: details.exception,
        stackTrace: details.stack,
      );
      previousFlutterErrorHandler?.call(details);
    };

    final previousPlatformErrorHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError =
        (Object error, StackTrace stackTrace) {
          this.error(
            'Uncaught platform error',
            tag: 'Platform',
            error: error,
            stackTrace: stackTrace,
          );
          return previousPlatformErrorHandler?.call(error, stackTrace) ?? true;
        };
  }

  void _log(
    LogLevel level,
    Object? message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    const shouldEmitConsole = kDebugMode || kProfileMode;
    final shouldPersist = level.index >= _minimumPersistedLevel.index;
    if (!shouldEmitConsole && !shouldPersist) return;

    final timestamp = DateTime.now();
    final safeMessage = _redact(message?.toString() ?? '');
    final safeError = error == null ? null : _redact(error.toString());
    final safeStackTrace = stackTrace == null
        ? null
        : _redact(stackTrace.toString());

    if (shouldEmitConsole) {
      developer.log(
        safeMessage,
        time: timestamp,
        level: level.developerLevel,
        name: tag == null ? 'Baka' : 'Baka.$tag',
        error: safeError,
        stackTrace: safeStackTrace == null
            ? null
            : StackTrace.fromString(safeStackTrace),
      );
    }

    if (!shouldPersist || !_initialized || _logFile == null) return;

    final entry = _formatEntry(
      timestamp: timestamp,
      level: level,
      message: safeMessage,
      tag: tag,
      error: safeError,
      stackTrace: safeStackTrace,
    );
    _writeQueue = _writeQueue
        .then((_) => _writeEntry(entry, level: level))
        .catchError((_) {});
  }

  String _formatEntry({
    required DateTime timestamp,
    required LogLevel level,
    required String message,
    required String? tag,
    required String? error,
    required String? stackTrace,
  }) {
    final buffer = StringBuffer()
      ..write(timestamp.toIso8601String())
      ..write(' [')
      ..write(level.label)
      ..write(']');

    if (tag != null && tag.isNotEmpty) {
      buffer
        ..write(' [')
        ..write(tag)
        ..write(']');
    }

    buffer
      ..write(' ')
      ..write(message);

    if (error != null && error.isNotEmpty) {
      buffer
        ..write('\nerror: ')
        ..write(error);
    }

    if (stackTrace != null && stackTrace.isNotEmpty) {
      buffer
        ..write('\n')
        ..write(stackTrace);
    }

    return buffer.toString();
  }

  Future<void> _writeEntry(String entry, {required LogLevel level}) async {
    final payload = '$entry\n';
    final payloadBytes = utf8.encode(payload).length;
    if (_currentLogFileBytes + payloadBytes >= _maxLogFileBytes) {
      await _rotateLogs();
    }

    await _logFile!.writeAsString(
      payload,
      mode: FileMode.append,
      flush: level.index >= LogLevel.error.index,
    );
    _currentLogFileBytes += payloadBytes;
  }

  Future<void> _rotateLogs() async {
    final directory = _logDirectory;
    final activeFile = _logFile;
    if (directory == null || activeFile == null) return;

    try {
      final oldest = File(
        _joinPath(directory.path, 'app.${_maxLogFiles - 1}.log'),
      );
      if (await oldest.exists()) {
        await oldest.delete();
      }

      for (var index = _maxLogFiles - 2; index >= 1; index--) {
        final source = File(_joinPath(directory.path, 'app.$index.log'));
        if (!await source.exists()) continue;

        final target = File(_joinPath(directory.path, 'app.${index + 1}.log'));
        await source.rename(target.path);
      }

      if (await activeFile.exists()) {
        await activeFile.rename(_joinPath(directory.path, 'app.1.log'));
      }

      _logFile = File(_joinPath(directory.path, _activeLogFileName));
      await _logFile!.create(recursive: true);
      _currentLogFileBytes = 0;
    } catch (error, stackTrace) {
      if (kDebugMode || kProfileMode) {
        developer.log(
          'Failed to rotate logs',
          name: 'Baka.Logger',
          level: LogLevel.warning.developerLevel,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Future<Directory> _resolveLogDirectory() async {
    if (Instances.isDesktopPlatform) {
      return Instances.desktopDataDirectory('logs');
    }

    final supportDirectory = await getApplicationSupportDirectory();
    return Directory(_joinPath(supportDirectory.path, 'logs'));
  }

  Future<String> _temporaryDirectoryPath() async {
    final directory = await getTemporaryDirectory();
    final logExportDirectory = Directory(
      _joinPath(directory.path, 'baka_logs'),
    );
    if (!await logExportDirectory.exists()) {
      await logExportDirectory.create(recursive: true);
    }
    return logExportDirectory.path;
  }

  String _logArchiveFileName() {
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return 'baka-logs-$timestamp.zip';
  }

  /// 脱敏 token / 密码 / cookie 等敏感字段。
  String _redact(String input) => input
      .replaceAllMapped(
        _redactKeyValueRe,
        (Match match) => '${match.group(1)}[REDACTED]',
      )
      .replaceAllMapped(
        _redactAuthHeaderRe,
        (Match match) => '${match.group(1)}[REDACTED]',
      );

  static final _pathSeparatorRe = RegExp(r'[\\/]');

  String _joinPath(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';

  String _fileName(String path) => path.split(_pathSeparatorRe).last;

  String _ensureZipExtension(String path) =>
      path.toLowerCase().endsWith('.zip') ? path : '$path.zip';
}

class LogArchive {
  const LogArchive({
    required this.file,
    required this.fileName,
    required this.logFileCount,
    required this.sizeBytes,
  });

  final File file;
  final String fileName;
  final int logFileCount;
  final int sizeBytes;
}
