import 'package:baka/core/network_service.dart';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

/// A pinned, official NVIDIA runtime; never replaces the NR/SR toolchain.
class DlssFrameGenerationRuntime {
  // Keep only the current installation, including after its staging rename.
  static (Directory, List<(int, DateTime, DateTime)>)? _verified;
  static const _revision = '374959484e79a640feaba44c93ac8cfb0a03f5b5';
  static const _version = '310.9.1-37495948-';
  static const _files = [
    (
      name: 'nvngx_dlssg.dll',
      remote: 'lib/Windows_x86_64/rel/nvngx_dlssg.dll',
      bytes: 7460976,
      digest:
          'ff6e90eb78b827927dff5b4ecc6b1c870c2e9bca29ed9f48c7d348cc9e170b82',
    ),
    (
      name: 'LICENSE.txt',
      remote: 'LICENSE.txt',
      bytes: 26620,
      digest:
          'd4216e39ebef5f9b50a6712ebb37beeb5379862a67733a9999c651f21592aaf0',
    ),
  ];

  static void _check(CancelToken cancel) {
    if (cancel.isCancelled) throw cancel.cancelError!;
  }

  static Future<bool> _valid(Directory directory, CancelToken cancel) async {
    final cached = _verified;
    final stamps = <(int, DateTime, DateTime)>[];
    for (var index = 0; index < _files.length; index++) {
      final entry = _files[index];
      _check(cancel);
      final file = File('${directory.path}/${entry.name}');
      final stat = await file.stat();
      final stamp = (stat.size, stat.modified, stat.changed);
      if (stat.type != FileSystemEntityType.file || stat.size != entry.bytes) {
        return false;
      }
      if (cached?.$1.path != directory.path || cached!.$2[index] != stamp) {
        final digest = await sha256.bind(file.openRead()).first;
        _check(cancel);
        if (digest.toString() != entry.digest) return false;
        final after = await file.stat();
        if ((after.size, after.modified, after.changed) != stamp) return false;
      }
      stamps.add(stamp);
    }
    _check(cancel);
    _verified = (directory, stamps);
    return true;
  }

  static Future<Directory> ensure({
    required Directory directory,
    required CancelToken cancel,
    required void Function(String) onProgress,
    bool allowDownload = true,
  }) async {
    if (!Platform.isWindows) throw StateError('NVIDIA 帧生成仅支持 Windows');
    _check(cancel);
    directory = directory.absolute;
    onProgress('正在校验 NVIDIA 帧生成运行库…');
    final cached = _verified?.$1;
    if (cached?.parent.uri == directory.uri && await _valid(cached!, cancel)) {
      return cached;
    }
    if (await directory.exists()) {
      await for (final entry in directory.list(followLinks: false)) {
        _check(cancel);
        if (entry is Directory &&
            entry.uri != cached?.uri &&
            entry.uri.pathSegments
                .where((name) => name.isNotEmpty)
                .last
                .startsWith(_version) &&
            await _valid(entry, cancel)) {
          return entry;
        }
      }
    }
    _check(cancel);
    if (!allowDownload) throw StateError('帧生成运行库缺失或校验失败，请在实验室重新开启并配置');
    await directory.create(recursive: true);
    Directory? staging;
    final dio = NetworkService.createDio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
        headers: {'User-Agent': 'AniBaka-DLSS-Setup'},
      ),
    );
    try {
      staging = await directory.createTemp('.fg-');
      for (final entry in _files) {
        _check(cancel);
        var lastPercent = -1;
        await dio.download(
          'https://raw.githubusercontent.com/NVIDIA/DLSS/$_revision/${entry.remote}',
          '${staging.path}/${entry.name}',
          cancelToken: cancel,
          options: Options(followRedirects: true, maxRedirects: 3),
          onReceiveProgress: (received, _) {
            if (received > entry.bytes) {
              cancel.cancel('NVIDIA 运行库大小与固定版本不符');
              return;
            }
            final percent = received * 100 ~/ entry.bytes;
            if (!cancel.isCancelled && percent != lastPercent) {
              lastPercent = percent;
              onProgress(
                '下载 NVIDIA 帧生成 ${entry.name}：$percent% '
                '${(received / 1048576).toStringAsFixed(1)} / '
                '${(entry.bytes / 1048576).toStringAsFixed(1)} MB',
              );
            }
          },
        );
      }
      onProgress('正在校验 NVIDIA 帧生成运行库…');
      if (!await _valid(staging, cancel)) {
        throw StateError('NVIDIA 帧生成运行库校验失败，请重新开始播放以重试');
      }
      _check(cancel);
      final suffix = staging.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final installed = await staging.rename(
        '${directory.path}/$_version$suffix',
      );
      if (_verified?.$1.path == staging.path) {
        _verified = (installed, _verified!.$2);
      }
      staging = null;
      return installed;
    } finally {
      dio.close(force: true);
      // Only this operation's two known files and its empty temporary directory.
      // Completed installations and an existing player's libraries stay intact.
      if (staging != null) {
        for (final entry in _files) {
          final file = File('${staging.path}/${entry.name}');
          try {
            if (await file.exists()) await file.delete();
          } on FileSystemException {
            /* Retry on next install. */
          }
        }
        try {
          await staging.delete();
        } on FileSystemException {
          /* Preserve unknown contents. */
        }
      }
    }
  }
}
