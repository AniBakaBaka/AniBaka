import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Anime4K 着色器管线，基于 Anime4K v4 着色器集合。
class Anime4K {
  Anime4K._();

  static const levelNames = {
    'low': '\u4f4e\u6863\u4f4d',
    'medium': '\u4e2d\u6863\u4f4d',
    'high': '\u9ad8\u6863\u4f4d',
    'ultra': '\u8d85\u9ad8\u6863\u4f4d',
  };

  static Future<Directory>? _directory;
  static final Set<String> _stagedFiles = {};

  static List<String> _pipeline(String level) {
    const clamp = 'Anime4K_Clamp_Highlights.glsl';
    const restoreM = 'Anime4K_Restore_CNN_M.glsl';
    const restoreVL = 'Anime4K_Restore_CNN_VL.glsl';
    const restoreSoftM = 'Anime4K_Restore_CNN_Soft_M.glsl';
    const restoreSoftVL = 'Anime4K_Restore_CNN_Soft_VL.glsl';
    const upscaleM = 'Anime4K_Upscale_CNN_x2_M.glsl';
    const upscaleVL = 'Anime4K_Upscale_CNN_x2_VL.glsl';
    const downX2 = 'Anime4K_AutoDownscalePre_x2.glsl';
    const downX4 = 'Anime4K_AutoDownscalePre_x4.glsl';

    switch (level) {
      case 'low':
        return [clamp, restoreSoftM, upscaleM];
      case 'high':
        return [
          clamp,
          restoreSoftVL,
          upscaleVL,
          downX2,
          restoreSoftM,
          upscaleM,
        ];
      case 'ultra':
        return [
          clamp,
          restoreVL,
          upscaleVL,
          downX2,
          downX4,
          restoreM,
          upscaleM,
        ];
      case 'medium':
      default:
        return [clamp, restoreM, upscaleM];
    }
  }

  /// 仅释放当前档位需要的文件，避免首次启用时复制整套着色器。
  static Future<String> shaderPath(String level) async {
    final files = _pipeline(level);
    final dir = await (_directory ??= _shaderDirectory());
    await _stageFiles(dir, files);
    final sep = Platform.pathSeparator;
    return files
        .map((file) => '${dir.path}$sep$file')
        .join(Platform.isWindows || Platform.isMacOS ? ';' : ':');
  }

  static Future<Directory> _shaderDirectory() async {
    final base = await getApplicationSupportDirectory();
    final sep = Platform.pathSeparator;
    final dir = Directory('${base.path}${sep}shaders${sep}anime4k');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<void> _stageFiles(Directory dir, List<String> files) async {
    for (final name in files) {
      if (_stagedFiles.contains(name)) continue;
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      if (await file.exists()) {
        _stagedFiles.add(name);
        continue;
      }
      try {
        final data = await rootBundle.load('assets/anime4k/$name');
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: false,
        );
        _stagedFiles.add(name);
      } catch (e) {
        debugPrint('释放着色器文件失败 $name: $e');
      }
    }
  }
}
