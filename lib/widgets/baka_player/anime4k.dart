import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Anime4K 着色器管线，基于 Anime4K v4 着色器集合
class Anime4K {
  Anime4K._();

  static const _assetRoot = 'assets/anime4k';
  static Future<Directory>? _directory;

  static bool get isMobilePlatform =>
      Platform.isAndroid || Platform.isIOS || Instances.isTV;

  static const _clamp = 'Anime4K_Clamp_Highlights.glsl';
  static const _restoreM = 'Anime4K_Restore_CNN_M.glsl';
  static const _restoreVL = 'Anime4K_Restore_CNN_VL.glsl';
  static const _restoreSoftM = 'Anime4K_Restore_CNN_Soft_M.glsl';
  static const _restoreSoftVL = 'Anime4K_Restore_CNN_Soft_VL.glsl';
  static const _upscaleS = 'Anime4K_Upscale_CNN_x2_S.glsl';
  static const _upscaleM = 'Anime4K_Upscale_CNN_x2_M.glsl';
  static const _upscaleVL = 'Anime4K_Upscale_CNN_x2_VL.glsl';
  static const _downX2 = 'Anime4K_AutoDownscalePre_x2.glsl';
  static const _downX4 = 'Anime4K_AutoDownscalePre_x4.glsl';
  static const _anibakaClear = 'AniBaka_Clear_v1.glsl';

  static List<String> pipelineFiles(
    VideoEnhancementPipeline pipeline, {
    bool? mobile,
  }) {
    final useMobile = mobile ?? isMobilePlatform;
    return switch (pipeline) {
      VideoEnhancementPipeline.off => const <String>[],
      VideoEnhancementPipeline.low =>
        useMobile
            ? const [_clamp, _anibakaClear, _restoreM, _upscaleS]
            : const [
                _clamp,
                _anibakaClear,
                _restoreSoftM,
                _upscaleM,
                _downX2,
                _downX4,
                _upscaleS,
              ],
      VideoEnhancementPipeline.medium =>
        useMobile
            ? const [_clamp, _anibakaClear, _restoreM, _upscaleM]
            : const [
                _clamp,
                _anibakaClear,
                _restoreM,
                _upscaleM,
                _downX2,
                _downX4,
                _upscaleS,
              ],
      VideoEnhancementPipeline.high =>
        useMobile
            ? const [
                _clamp,
                _anibakaClear,
                _restoreM,
                _upscaleM,
                _downX2,
                _downX4,
                _upscaleS,
              ]
            : const [
                _clamp,
                _anibakaClear,
                _restoreSoftVL,
                _upscaleVL,
                _downX2,
                _downX4,
                _upscaleM,
              ],
      VideoEnhancementPipeline.ultra =>
        useMobile
            ? const [
                _clamp,
                _anibakaClear,
                _restoreM,
                _upscaleM,
                _downX2,
                _downX4,
                _restoreSoftM,
                _upscaleS,
              ]
            : const [
                _clamp,
                _anibakaClear,
                _restoreVL,
                _upscaleVL,
                _restoreM,
                _downX2,
                _downX4,
                _upscaleM,
              ],
    };
  }

  static Future<String> shaderPath(
    VideoEnhancementPipeline pipeline, {
    bool? mobile,
  }) async {
    final files = pipelineFiles(pipeline, mobile: mobile);
    if (files.isEmpty) return '';
    final dir = await (_directory ??= _shaderDirectory());
    final staged = <String>[];
    for (final name in files) {
      staged.add((await _stageFile(dir, name)).path);
    }
    return staged.join(Platform.isWindows ? ';' : ':');
  }

  static Future<Directory> _shaderDirectory() async {
    final base = await getApplicationSupportDirectory();
    final sep = Platform.pathSeparator;
    final dir = Directory('${base.path}${sep}shaders${sep}video_enhancement');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _stageFile(Directory dir, String name) async {
    final data = await rootBundle.load('$_assetRoot/$name');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return _stageBytes(dir, name, bytes);
  }

  @visibleForTesting
  static Future<File> stageBytesForTest(
    Directory dir,
    String name,
    List<int> bytes,
  ) => _stageBytes(dir, name, Uint8List.fromList(bytes));

  static Future<File> _stageBytes(
    Directory dir,
    String name,
    Uint8List bytes,
  ) async {
    final expectedHash = sha256.convert(bytes).toString();
    final target = File('${dir.path}${Platform.pathSeparator}$name');

    if (await target.exists()) {
      final currentHash = sha256.convert(await target.readAsBytes()).toString();
      if (currentHash == expectedHash) {
        return target;
      }
    }

    final temporary = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      try {
        await temporary.rename(target.path);
      } on FileSystemException {
        // Older Windows runtimes may not replace an existing file on rename.
        final backup = File('${target.path}.previous');
        if (await backup.exists()) await backup.delete();
        if (await target.exists()) await target.rename(backup.path);
        try {
          await temporary.rename(target.path);
          if (await backup.exists()) await backup.delete();
        } catch (_) {
          if (!await target.exists() && await backup.exists()) {
            await backup.rename(target.path);
          }
          rethrow;
        }
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }

    final writtenHash = sha256.convert(await target.readAsBytes()).toString();
    if (writtenHash != expectedHash) {
      throw FileSystemException(
        'Shader SHA-256 verification failed',
        target.path,
      );
    }
    return target;
  }
}

VideoEnhancementPipeline selectEnhancementPipeline(VideoEnhancementMode mode) =>
    switch (mode) {
      VideoEnhancementMode.off => VideoEnhancementPipeline.off,
      VideoEnhancementMode.low => VideoEnhancementPipeline.low,
      VideoEnhancementMode.medium => VideoEnhancementPipeline.medium,
      VideoEnhancementMode.high => VideoEnhancementPipeline.high,
      VideoEnhancementMode.ultra => VideoEnhancementPipeline.ultra,
    };
