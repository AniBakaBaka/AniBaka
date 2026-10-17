import 'package:baka/core/network_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Runtime DLL directory. Older installations remain usable without their tools.
class DlssRuntime {
  const DlssRuntime(this.directory);
  static const _settingsKey = 'dlss5_runtime_directory';
  final String directory;

  static DlssRuntime load(SharedPreferences preferences) {
    final directory = preferences.getString(_settingsKey);
    if (directory != null && directory.isNotEmpty) {
      return DlssRuntime(directory);
    }
    String? executable;
    try {
      final saved = preferences.getString('dlss5_toolchain');
      if (saved != null) {
        executable =
            (jsonDecode(saved) as Map<String, dynamic>)['executable']
                as String?;
      }
    } on FormatException {
      // Fall back to the original manual configuration.
    } on TypeError {
      // Ignore incomplete settings from an interrupted migration.
    }
    executable ??= preferences.getString('dlss5_tool_path');
    return DlssRuntime(
      executable == null || executable.isEmpty
          ? ''
          : File(executable).parent.path,
    );
  }

  Future<void> save(SharedPreferences preferences) async {
    if (!await preferences.setString(_settingsKey, directory)) {
      throw StateError('运行库已下载，但路径保存失败，请重试');
    }
  }

  Future<bool> isAvailable() async {
    if (!Platform.isWindows || directory.isEmpty) return false;
    for (final name in [
      'nvngx_dlssnr.dll',
      'nvngx_dlss.dll',
      'nvngx.dll_dlssnr.dll',
    ]) {
      if (!await File('$directory${Platform.pathSeparator}$name').exists()) {
        return false;
      }
    }
    return true;
  }
}

class _ToolPackage {
  const _ToolPackage(this.name, this.url, this.bytes, this.digest);
  final String name;
  final String url;
  final int bytes;
  final String digest;
}

/// Installs fixed upstream releases without invoking installers or changing PATH.
class DlssRuntimeInstaller extends ChangeNotifier {
  static const _packages = [
    _ToolPackage(
      'DLSS 运行库',
      'https://github.com/DaniilSokolyuk/video2dlssnr/releases/download/v1.4.1/video2dlssnr_release.zip',
      247433416,
      'cf1e01b3715b5ee75708744a5d5e6a4f2a96b5504834dd854b4c06388f230ccf',
    ),
  ];

  bool running = false;
  String status = '首次使用需下载并配置增强环境';
  String? error;
  double? progress;
  bool _cancelled = false;
  bool _disposed = false;
  CancelToken? _cancelToken;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _checkCancelled() {
    if (_cancelled) throw const _InstallCancelled();
  }

  void cancel() {
    if (!running) return;
    _cancelled = true;
    _cancelToken?.cancel('用户取消');
    status = '正在取消；当前解压结束后清理临时文件…';
    _notify();
  }

  Future<DlssRuntime?> install(Directory directory) async {
    if (running) return null;
    running = true;
    _cancelled = false;
    error = null;
    progress = null;
    status = '正在准备下载…';
    _notify();
    Directory? staging;
    String? root;
    final dio = NetworkService.createDio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
        headers: {
          'User-Agent': 'AniBaka-DLSS-Setup',
          'Accept': 'application/octet-stream',
        },
      ),
    );
    try {
      if (!Platform.isWindows) throw StateError('自动配置仅支持 Windows');
      await directory.create(recursive: true);
      root = await directory.resolveSymbolicLinks();
      staging = await Directory(root).createTemp('.install-');
      _checkCancelled();
      for (var index = 0; index < _packages.length; index++) {
        final package = _packages[index];
        final archiveFile = File(
          '${staging.path}${Platform.pathSeparator}$index.zip',
        );
        final unpacked = Directory(
          '${staging.path}${Platform.pathSeparator}package-$index',
        );
        _cancelToken = CancelToken();
        var notifiedAt = 0;
        await dio.download(
          package.url,
          archiveFile.path,
          cancelToken: _cancelToken,
          options: Options(followRedirects: true, maxRedirects: 5),
          onReceiveProgress: (received, total) {
            if (received > package.bytes) _cancelToken?.cancel('下载文件大小与固定版本不符');
            final now = DateTime.now().millisecondsSinceEpoch;
            if (!_cancelled && (now - notifiedAt >= 150 || received == total)) {
              notifiedAt = now;
              progress = (received / package.bytes).clamp(0, 1);
              status =
                  '下载 ${package.name}（${index + 1}/${_packages.length}）：'
                  '${(received / 1048576).toStringAsFixed(1)} / '
                  '${(package.bytes / 1048576).toStringAsFixed(1)} MB';
              _notify();
            }
          },
        );
        _checkCancelled();
        status = '正在校验 ${package.name}…';
        progress = null;
        _notify();
        if (await archiveFile.length() != package.bytes) {
          throw StateError('${package.name} 下载不完整，请重试');
        }
        final digest = await sha256
            .bind(
              archiveFile.openRead().map((bytes) {
                _checkCancelled();
                return bytes;
              }),
            )
            .first;
        _checkCancelled();
        if (digest.toString() != package.digest) {
          throw StateError('${package.name} SHA-256 校验失败，请重新下载');
        }
        status = '正在解压 ${package.name}…';
        _notify();
        // Only strings cross the isolate boundary. Large archives are read
        // lazily from disk, and decompression never blocks the UI isolate.
        await compute(extractDlssRuntimeArchive, (
          archiveFile.path,
          unpacked.path,
        ));
        _checkCancelled();
        await archiveFile.delete();
      }
      status = '正在配置运行库路径…';
      _notify();
      final runtime = await _findRuntimeDirectory(
        Directory('${staging.path}${Platform.pathSeparator}package-0'),
      );
      if (!await DlssRuntime(runtime.path).isAvailable()) {
        throw StateError('增强包缺少 DLSS 神经渲染、超分辨率或转接运行库，请检查下载来源');
      }
      final runtimeRelative = runtime.path.substring(staging.path.length + 1);
      await File(
        '${staging.path}${Platform.pathSeparator}installation.json',
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'installedAt': DateTime.now().toUtc().toIso8601String(),
          'packages': [
            for (final package in _packages)
              {
                'url': package.url,
                'sha256': package.digest,
                'bytes': package.bytes,
              },
          ],
          'runtime': runtimeRelative,
        }),
      );
      _checkCancelled();
      final suffix = staging.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final destination =
          '$root${Platform.pathSeparator}video2dlssnr-1.4.1-${suffix.substring(9)}';
      // A fresh directory keeps an existing installation usable during setup.
      staging = await staging.rename(destination);
      _checkCancelled();
      final result = DlssRuntime(
        '${staging.path}${Platform.pathSeparator}$runtimeRelative',
      );
      staging = null; // Ownership passes to the saved configuration.
      progress = 1;
      status = '下载和解压完成';
      return result;
    } catch (exception) {
      if (_cancelled) {
        status = '已取消配置';
      } else {
        error = exception is DioException
            ? '下载失败，请检查网络后重试：${exception.message ?? exception.type.name}'
            : exception.toString();
        status = '配置失败';
      }
      return null;
    } finally {
      dio.close(force: true);
      if (staging != null && root != null) {
        try {
          // Resolve before recursive cleanup; only this installer-created
          // direct child of the tools directory may be removed.
          final path = await staging.resolveSymbolicLinks();
          if (Directory(path).parent.path.toLowerCase() == root.toLowerCase()) {
            await Directory(path).delete(recursive: true);
          }
        } on FileSystemException {
          status += '；部分临时文件未能清理';
        }
      }
      _cancelToken = null;
      running = false;
      _notify();
    }
  }

  Future<Directory> _findRuntimeDirectory(Directory root) async {
    const name = 'nvngx_dlss.dll';
    const companion = 'nvngx.dll_dlssnr.dll';
    final matches = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      _checkCancelled();
      if (entity is! File ||
          entity.uri.pathSegments.last.toLowerCase() != name) {
        continue;
      }
      final adjacent = File(
        '${entity.parent.path}${Platform.pathSeparator}$companion',
      );
      if (await adjacent.exists()) matches.add(entity);
    }
    if (matches.length != 1) throw StateError('压缩包中未找到唯一完整的 $name');
    final file = matches.single;
    final handle = await file.open();
    try {
      final header = await handle.read(2);
      if (header.length != 2 || header[0] != 0x4d || header[1] != 0x5a) {
        throw StateError('$name 不是有效的 Windows 运行库');
      }
    } finally {
      await handle.close();
    }
    return file.parent;
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}

class _InstallCancelled implements Exception {
  const _InstallCancelled();
}

@visibleForTesting
void extractDlssRuntimeArchive((String, String) paths) {
  final input = InputFileStream(paths.$1);
  final directory = Directory(paths.$2);
  final seen = <String>{};
  var totalBytes = 0;
  try {
    directory.createSync(recursive: true);
    final archive = ZipDecoder().decodeStream(input);
    if (archive.length > 10000) throw const FormatException('压缩包文件过多');
    for (final entry in archive) {
      final relative = entry.name.replaceAll('\\', '/');
      final parts = relative.split('/');
      if (entry.isDirectory && parts.last.isEmpty) parts.removeLast();
      if (parts.isEmpty ||
          entry.isSymbolicLink ||
          parts.any(
            (part) =>
                part.isEmpty ||
                part == '.' ||
                part == '..' ||
                RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(part) ||
                part.endsWith('.') ||
                part.endsWith(' ') ||
                RegExp(
                  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
                  caseSensitive: false,
                ).hasMatch(part),
          )) {
        throw FormatException('压缩包包含无效路径：${entry.name}');
      }
      if (!seen.add(parts.join('/').toLowerCase())) {
        throw FormatException('压缩包包含重复路径：${entry.name}');
      }
      totalBytes += entry.size;
      if (entry.size < 0 || totalBytes > 2 * 1024 * 1024 * 1024) {
        throw const FormatException('压缩包解压体积超出限制');
      }
      final name = parts.last.toLowerCase();
      if (entry.isDirectory ||
          (!const {
                'nvngx_dlss.dll',
                'nvngx_dlssnr.dll',
                'nvngx.dll_dlssnr.dll',
              }.contains(name) &&
              !name.startsWith('license') &&
              !name.startsWith('notice') &&
              !name.startsWith('readme'))) {
        continue;
      }
      final target =
          '${directory.path}${Platform.pathSeparator}${parts.join(Platform.pathSeparator)}';
      File(target).parent.createSync(recursive: true);
      final output = OutputFileStream(target);
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
    }
  } finally {
    input.closeSync();
  }
}
