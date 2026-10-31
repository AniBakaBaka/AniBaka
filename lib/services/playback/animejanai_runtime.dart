import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:baka/core/network_service.dart';
import 'animejanai_types.dart';

class AnimeJaNaiPackage {
  const AnimeJaNaiPackage(
    this.name,
    this.url,
    this.bytes,
    this.sha256sum, {
    this.files = const {},
    this.model = false,
    this.sevenZip = false,
  });
  final String name, url, sha256sum;
  final int bytes;
  final Map<String, String> files;
  final bool model, sevenZip;
}

const _release =
    'https://github.com/the-database/mpv-AnimeJaNai/releases/download/3.7.0';
const _models =
    'https://raw.githubusercontent.com/the-database/mpv-AnimeJaNai/6361f4fe059d22984f9074860a4a227489a5d464/BuildMpvUpscale2xAnimeJaNai/mpv-upscale-2x_animejanai/animejanai/onnx';
const _balanced =
    '2x_AnimeJaNai_HD_V3.1_Balanced_SPANF3_b8f64_unshuffle_fp16.onnx';
const _performance =
    '2x_AnimeJaNai_HD_V3.1_Performance_SPANF3_b5f48_unshuffle_fp16.onnx';
const _sd =
    '2x_AnimeJaNai_SD_V1beta34_Compact_1x3xHxW_dyn-HW_strong_fp16_op21_dynamo.onnx';
const animeJaNaiRifePackage = AnimeJaNaiPackage(
  'RIFE v4.14',
  '$_release/component-rife.7z',
  462444035,
  'd41de2b56972cb3c446d9830bd5c5e7257e6e099ef0e7a2d5770ec01a9bf7251',
  sevenZip: true,
);
const animeJaNaiRifeModel = AnimeJaNaiPackage(
  'rife_v4.14.onnx',
  '',
  10778647,
  'a64b9cd0fb463d620688394437f35f02e33c0658c39ccce2b9637899fb520cbe',
  model: true,
);
const animeJaNaiRifeLiteModel = AnimeJaNaiPackage(
  'rife_v4.14_lite.onnx',
  '',
  5986311,
  '948019ffb5e7e54ac6b89a13542da8d100af9b4ade7374551c5f595ac3ff2ce7',
  model: true,
);

AnimeJaNaiPackage animeJaNaiInterpolationModel(
  AnimeJaNaiInterpolationMode mode,
) => mode == AnimeJaNaiInterpolationMode.fast
    ? animeJaNaiRifeLiteModel
    : animeJaNaiRifeModel;
const _modelPackages = [
  AnimeJaNaiPackage(
    _balanced,
    '$_models/$_balanced',
    1971970,
    'b308e93c3dda3c4f9f968295b2b7b8d1c0583a711bca53a08d51134d9d1cbd5c',
    model: true,
  ),
  AnimeJaNaiPackage(
    _performance,
    '$_models/$_performance',
    740318,
    '7b804d87320f37b7269d6e27796046fbd975e95e2aa1f65d5557f52a36282716',
    model: true,
  ),
  AnimeJaNaiPackage(
    _sd,
    '$_models/$_sd',
    1212903,
    'ded46591ddfaeb22b3daaf84ad7b36838335aa3efca66acfa36177ce4ab21eb5',
    model: true,
  ),
];
const animeJaNaiSharpPackages = [
  AnimeJaNaiPackage(
    '2x_AnimeJaNai_HD_V3.1Sharp1_Balanced_SPANF3_b8f64_unshuffle_fp16.onnx',
    '$_models/2x_AnimeJaNai_HD_V3.1Sharp1_Balanced_SPANF3_b8f64_unshuffle_fp16.onnx',
    1971970,
    'dde763c8202cfebac5ec030ea6644f3ee339ea35bbda8a76e257405399552f0f',
    model: true,
  ),
  AnimeJaNaiPackage(
    '2x_AnimeJaNai_HD_V3.1Sharp1_Performance_SPANF3_b5f48_unshuffle_fp16.onnx',
    '$_models/2x_AnimeJaNai_HD_V3.1Sharp1_Performance_SPANF3_b5f48_unshuffle_fp16.onnx',
    740318,
    '72246eded3aab52f8d1a71613c0a1d900734b358d1820b62eb36f1ed376e1cf4',
    model: true,
  ),
];
const _kernels = <int, (int, String)>{
  75: (
    90359224,
    '4bc46f2fd2e9aad1b90666e634334197a28348f24f9a1bdb0d07fadc59b3bc4f',
  ),
  80: (
    160207044,
    '5bfe7a9288e866baa8111c851634ec077572130527ebe8844a74109e6a0e5393',
  ),
  86: (
    149799926,
    'bdbdc7b92cc3143f76045263a08e506af4594e717763d118ac65404b7ba0b23a',
  ),
  89: (
    158554965,
    '34bd51be1cb1581db3e494d1b30732c926cd9ac1a340efabdf0f9148911fdc87',
  ),
  90: (
    420452077,
    'b884e983b8b0d61ecebf9990fbed6a3fa13023b5cf9b4c2920933777e5f5ceb5',
  ),
  100: (
    251528952,
    '98a4ab1a906123ba61db70cc470c13595b60cf94acde6625c53ad5556a58f447',
  ),
  120: (
    229417183,
    '954821ef65824b0c766998db7d2ae49c68041dac7f78328152ec41f674378c15',
  ),
};

List<AnimeJaNaiPackage> animeJaNaiPackages(AnimeJaNaiBackend backend, int? sm) {
  final isTrt = backend == AnimeJaNaiBackend.tensorRT;
  final kernel = _kernels[sm];
  final kernelName = kernel == null ? 'ptx' : 'sm$sm';
  return [
    AnimeJaNaiPackage(
      'AJI v0.11.1',
      'https://github.com/the-database/animejanai-inference/releases/download/v0.11.1/aji-windows-x64.zip',
      711145,
      'b51fba253126288f7dc2aca980b93e7191cfd216513513c6e8022be8316afb62',
      files: {
        'aji.dll': 'aji.dll',
        'aji_${isTrt ? 'trt' : 'dml'}.dll': 'aji_${isTrt ? 'trt' : 'dml'}.dll',
      },
    ),
    ..._modelPackages,
    if (isTrt) ...[
      const AnimeJaNaiPackage(
        'TensorRT 11.3',
        '$_release/component-trt-runtime.7z',
        186822775,
        '282cb9b178db241f61f7aedf1ef214af56c2a342428253d04a8d8916d6729373',
        sevenZip: true,
      ),
      AnimeJaNaiPackage(
        'TensorRT $kernelName',
        '$_release/component-trt-$kernelName.7z',
        kernel?.$1 ?? 208391718,
        kernel?.$2 ??
            '7bd93d7f610ec31124b4ed677395e86337a0fbe9279d6315d7005d64f6dd398e',
        sevenZip: true,
      ),
    ] else ...[
      const AnimeJaNaiPackage(
        'ONNX Runtime 1.24.4',
        'https://www.nuget.org/api/v2/package/Microsoft.ML.OnnxRuntime.DirectML/1.24.4',
        12458649,
        '57e9f11b73437bef7a309496135d4c1f96b1a8e9ddba60013fa27bfc1d788681',
        files: {
          'runtimes/win-x64/native/onnxruntime.dll': 'onnxruntime.dll',
          'runtimes/win-x64/native/onnxruntime_providers_shared.dll':
              'onnxruntime_providers_shared.dll',
          'LICENSE': 'ONNXRuntime_LICENSE.txt',
          'ThirdPartyNotices.txt': 'ONNXRuntime_THIRD_PARTY_NOTICES.txt',
        },
      ),
      const AnimeJaNaiPackage(
        'DirectML 1.15.4',
        'https://www.nuget.org/api/v2/package/Microsoft.AI.DirectML/1.15.4',
        202292617,
        '4e7cb7ddce8cf837a7a75dc029209b520ca0101470fcdf275c1f49736a3615b9',
        files: {
          'bin/x64-win/DirectML.dll': 'DirectML.dll',
          'LICENSE.txt': 'DirectML_LICENSE.txt',
          'LICENSE-CODE.txt': 'DirectML_LICENSE-CODE.txt',
        },
      ),
    ],
  ];
}

class AnimeJaNaiRuntime {
  const AnimeJaNaiRuntime(this.root, this.backend);
  static const version = 'aji-v0.11.1-trt11.3-dml1.24.4-models6361f4f';
  final Directory root;
  final AnimeJaNaiBackend backend;
  String get inference => '${root.path}/animejanai/inference';
  String get models => '${root.path}/animejanai/onnx';
  String get conf => '${root.path}/animejanai.conf';
  // Shared by TensorRT and DirectML, including automatic backend fallback.
  String get rifeModels => '${root.parent.path}/rife-3.7.0-v4.14';

  String filter(
    String stats,
    AnimeJaNaiProfile profile, {
    bool softwareDecoded = false,
    String? configPath,
    bool interpolation = false,
    AnimeJaNaiFrameMultiplier multiplier = AnimeJaNaiFrameMultiplier.x2,
    AnimeJaNaiInterpolationMode mode = AnimeJaNaiInterpolationMode.full,
  }) =>
      // ANGLE only advertises D3D11 upload devices. After NVDEC falls back to
      // software (notably H.264 High 10), automatic upload would hand D3D11
      // texture pointers to TensorRT. Upload explicitly, retaining 10-bit input.
      '${backend == AnimeJaNaiBackend.tensorRT && softwareDecoded ? '@anibaka_aji_input:lavfi=[format=pix_fmts=nv12|p010le,hwupload_cuda],' : ''}'
      '@anibaka_aji:animejanai:lib=${animeJaNaiMpvValue('$inference/aji.dll')}'
      ':conf=${animeJaNaiMpvValue(configPath ?? conf)}'
      ':model-dir=${animeJaNaiMpvValue(models)}'
      ':rife-model-dir=${animeJaNaiMpvValue(rifeModels)}'
      ':trtexec=${animeJaNaiMpvValue('$inference/trtexec.exe')}'
      ':stats=${animeJaNaiMpvValue(stats)}'
      ':slot=${interpolation ? multiplier.slot(profile, mode: mode) : profile.slot}:output-444=no';

  String configuration(AnimeJaNaiLook look, {int inputHeight = 0}) {
    final config = StringBuffer(
      '[global]\nconfig_version=2\nbackend=${backend.label}\nlogging=yes\n'
      'quality_preset=${look.name}\nbalanced_preset=${look.name}\nperformance_preset=${look.name}\n',
    );
    String model(String name) => name
        .replaceFirst('.onnx', '')
        .replaceFirst(
          '_HD_V3.1_',
          look == AnimeJaNaiLook.sharp ? '_HD_V3.1Sharp1_' : '_HD_V3.1_',
        );
    // Separate slots let on/off, multiplier and profile changes use AJI's
    // runtime command without rebuilding the decoder or renderer.
    for (final mode in AnimeJaNaiInterpolationMode.values) {
      for (final multiplier in AnimeJaNaiFrameMultiplier.values) {
        for (final profile in AnimeJaNaiProfile.values) {
          config.writeln('\n[slot_${multiplier.slot(profile, mode: mode)}]');
          void chain(int index, String min, String max, int fps, String? name) {
            final prefix = 'chain_$index';
            config
              ..writeln('${prefix}_min_resolution=$min')
              ..writeln('${prefix}_max_resolution=$max')
              ..writeln('${prefix}_max_fps=$fps');
            if (name != null) {
              config.writeln('${prefix}_model_1_name=${model(name)}');
              // Hoisted by AJI before RIFE, so both networks process fewer pixels.
              // Never enlarge a small source just to use the fast preset.
              if (mode == AnimeJaNaiInterpolationMode.fast &&
                  inputHeight > 540) {
                config.writeln(
                  '${prefix}_model_1_resize_height_before_upscale=540',
                );
              }
            }
            config
              ..writeln('${prefix}_rife=yes')
              ..writeln('${prefix}_rife_factor_numerator=${multiplier.factor}')
              ..writeln('${prefix}_rife_factor_denominator=1')
              ..writeln(
                '${prefix}_rife_model=${mode == AnimeJaNaiInterpolationMode.fast ? 4141 : 414}',
              )
              ..writeln('${prefix}_rife_ensemble=no')
              ..writeln('${prefix}_rife_scene_detect_threshold=0.150')
              ..writeln('${prefix}_rife_before_upscale=yes');
          }

          chain(
            1,
            '1280x720',
            '1920x1080',
            31,
            profile == AnimeJaNaiProfile.performance ? _performance : _balanced,
          );
          chain(2, '0x0', '1280x720', 31, _sd);
          // Keep the built-in upscale limits. For 32–61 fps, balanced and
          // performance interpolate alone; quality also retains its HD chain.
          chain(
            3,
            '0x0',
            '1920x1080',
            61,
            mode == AnimeJaNaiInterpolationMode.fast
                ? (profile == AnimeJaNaiProfile.performance
                      ? _performance
                      : _balanced)
                : profile == AnimeJaNaiProfile.quality
                ? _balanced
                : null,
          );
        }
      }
    }
    return config.toString();
  }

  Future<bool> available() async {
    try {
      if (await File('${root.path}/ready').readAsString() != version) {
        return false;
      }
      for (final name in [
        'aji.dll',
        if (backend == AnimeJaNaiBackend.tensorRT) ...[
          'aji_trt.dll',
          'nvinfer_11.dll',
          'nvonnxparser_11.dll',
          'cudart64_13.dll',
          'trtexec.exe',
        ] else ...[
          'aji_dml.dll',
          'onnxruntime.dll',
          'DirectML.dll',
        ],
      ]) {
        if (await File('$inference/$name').length() == 0) return false;
      }
      for (final p in _modelPackages) {
        if (await File('$models/${p.name}').length() != p.bytes) return false;
      }
      if (!await File(conf).exists()) return false;
      if (backend == AnimeJaNaiBackend.tensorRT &&
          !await Directory(
            inference,
          ).list().any((f) => f.path.contains('builder_resource_'))) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

class AnimeJaNaiInstallCancelled implements Exception {
  const AnimeJaNaiInstallCancelled();
  @override
  String toString() => '已取消 AnimeJaNai 安装';
}

/// Downloads never target a live runtime. A complete, verified staging tree is
/// renamed into place, so an interruption cannot make an installation "ready".
class AnimeJaNaiInstaller extends ChangeNotifier {
  AnimeJaNaiInstaller({Dio? dio, this.unpacker})
    : _dio =
          dio ??
          NetworkService.createDio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
              headers: {'User-Agent': 'AniBaka-AnimeJaNai-Setup'},
            ),
          );
  final Dio _dio;
  final String? unpacker;
  bool busy = false;
  double? progress;
  String status = '首次开启时下载模型和推理运行库';
  CancelToken? _cancel;
  Process? _process;
  bool _cancelled = false, _closed = false;

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void cancel() {
    _cancelled = true;
    _cancel?.cancel();
    _process?.kill();
  }

  void _check() {
    if (_cancelled || _closed) throw const AnimeJaNaiInstallCancelled();
  }

  Future<void> ensureInterpolation(
    AnimeJaNaiRuntime runtime, {
    bool allowInstall = true,
    AnimeJaNaiPackage package = animeJaNaiRifePackage,
    AnimeJaNaiPackage model = animeJaNaiRifeModel,
  }) async {
    final target = Directory(runtime.rifeModels);
    try {
      await verifyAnimeJaNaiDownload(
        File('${target.path}/${model.name}'),
        model,
      );
      return;
    } catch (_) {
      if (!allowInstall) throw StateError('RIFE 补帧模型尚未安装，请重新开启补帧以下载');
    }
    if (busy) throw StateError('另一项 AnimeJaNai 安装尚未完成');
    busy = true;
    _cancelled = false;
    _cancel = CancelToken();
    Directory? staging;
    try {
      staging = await runtime.root.parent.createTemp('.rife-');
      final archive = File('${staging.path}/component');
      status = '下载 RIFE 补帧模型（约 441 MiB）';
      progress = 0;
      _notify();
      var lastNotify = 0;
      await _dio.download(
        package.url,
        archive.path,
        cancelToken: _cancel,
        onReceiveProgress: (received, total) {
          if (received > package.bytes) _cancel?.cancel('模型大小不符');
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastNotify > 150 || received == total) {
            lastNotify = now;
            progress = (received / package.bytes).clamp(0, 1);
            _notify();
          }
        },
      );
      _check();
      status = '校验并解压 RIFE 补帧模型';
      progress = null;
      _notify();
      await verifyAnimeJaNaiDownload(archive, package);
      final payload = await Directory('${staging.path}/payload').create();
      // Both models share one verified upstream archive. Keep them together on
      // new installs so selecting another mode does not redownload 441 MiB.
      final models = identical(package, animeJaNaiRifePackage)
          ? [animeJaNaiRifeModel, animeJaNaiRifeLiteModel]
          : [model];
      final entries = {
        for (final m in models) 'animejanai/rife/${m.name}': m.name,
      };
      if (package.sevenZip) {
        await _extract7z(
          archive,
          payload,
          directory: 'animejanai/rife',
          files: entries.keys.toList(),
        );
        for (final entry in entries.entries) {
          await File(
            '${payload.path}/${entry.key}',
          ).rename('${payload.path}/${entry.value}');
        }
        await Directory('${payload.path}/animejanai').delete(recursive: true);
      } else {
        await compute(extractAnimeJaNaiZip, (
          archive.path,
          payload.path,
          entries,
        ));
      }
      for (final m in models) {
        await verifyAnimeJaNaiDownload(File('${payload.path}/${m.name}'), m);
      }
      await File('${payload.path}/RIFE_LICENSE.txt').writeAsString(
        'RIFE: https://github.com/hzwer/ECCV2022-RIFE\n'
        'ONNX model distributed by mpv-AnimeJaNai 3.7.0, unmodified.\n\n'
        'MIT License\n\nCopyright (c) Megvii Inc.\n\n'
        'Permission is hereby granted, free of charge, to any person obtaining a copy '
        'of this software and associated documentation files (the "Software"), to deal '
        'in the Software without restriction, including without limitation the rights '
        'to use, copy, modify, merge, publish, distribute, sublicense, and/or sell '
        'copies of the Software, and to permit persons to whom the Software is '
        'furnished to do so, subject to the following conditions:\n\n'
        'The above copyright notice and this permission notice shall be included in '
        'all copies or substantial portions of the Software.\n\n'
        'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR '
        'IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, '
        'FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE '
        'AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER '
        'LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING '
        'FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER '
        'DEALINGS IN THE SOFTWARE.\n',
      );
      _check();
      await target.create(recursive: true);
      // Add verified models in place, retaining the other mode and all compiled
      // engines. No live directory is swapped while a player uses its cache.
      for (final m in models) {
        await File(
          '${payload.path}/${m.name}',
        ).rename('${target.path}/${m.name}');
      }
      await File(
        '${payload.path}/RIFE_LICENSE.txt',
      ).rename('${target.path}/RIFE_LICENSE.txt');
      status = 'RIFE 补帧模型已就绪';
    } catch (_) {
      if (_cancelled || _closed) throw const AnimeJaNaiInstallCancelled();
      rethrow;
    } finally {
      busy = false;
      progress = null;
      _cancel = null;
      _process = null;
      if (staging != null && await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {
          /* An antivirus scanner may still hold a temporary file. */
        }
      }
      _notify();
    }
  }

  Future<void> ensureLook(
    AnimeJaNaiRuntime runtime,
    AnimeJaNaiLook look, {
    bool allowInstall = true,
    List<AnimeJaNaiPackage> packages = animeJaNaiSharpPackages,
  }) async {
    if (look == AnimeJaNaiLook.original) return;
    final missing = <AnimeJaNaiPackage>[];
    for (final package in packages) {
      try {
        await verifyAnimeJaNaiDownload(
          File('${runtime.models}/${package.name}'),
          package,
        );
      } catch (_) {
        missing.add(package);
      }
    }
    if (missing.isEmpty) return;
    if (!allowInstall) throw StateError('Sharp1 模型尚未安装，请重新选择模型风格以下载');
    if (busy) throw StateError('另一项 AnimeJaNai 安装尚未完成');
    busy = true;
    _cancelled = false;
    _cancel = CancelToken();
    Directory? staging;
    try {
      staging = await runtime.root.createTemp('.models-');
      for (final package in missing) {
        _check();
        status = '下载 Sharp1 模型';
        progress = 0;
        _notify();
        final file = File('${staging.path}/${package.name}');
        var lastNotify = 0;
        await _dio.download(
          package.url,
          file.path,
          cancelToken: _cancel,
          onReceiveProgress: (received, total) {
            if (received > package.bytes) _cancel?.cancel('模型大小不符');
            final now = DateTime.now().millisecondsSinceEpoch;
            if (now - lastNotify > 150 || received == total) {
              lastNotify = now;
              progress = (received / package.bytes).clamp(0, 1);
              _notify();
            }
          },
        );
        await verifyAnimeJaNaiDownload(file, package);
      }
      _check();
      for (final package in missing) {
        await File(
          '${staging.path}/${package.name}',
        ).rename('${runtime.models}/${package.name}');
      }
      status = 'Sharp1 模型已就绪';
    } catch (_) {
      if (_cancelled || _closed) throw const AnimeJaNaiInstallCancelled();
      rethrow;
    } finally {
      busy = false;
      progress = null;
      _cancel = null;
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      _notify();
    }
  }

  Future<AnimeJaNaiRuntime> ensure(
    Directory directory,
    AnimeJaNaiBackend backend, {
    int? sm,
    bool allowInstall = true,
    List<AnimeJaNaiPackage>? packages,
    List<String>? requiredFiles,
  }) async {
    final suffix = backend == AnimeJaNaiBackend.tensorRT
        ? '-sm${sm ?? 'ptx'}'
        : '';
    final target = Directory(
      '${directory.path}/${AnimeJaNaiRuntime.version}-${backend.name}$suffix',
    );
    final runtime = AnimeJaNaiRuntime(target, backend);
    if (await runtime.available()) return runtime;
    if (!allowInstall) throw StateError('AnimeJaNai 运行库未安装，请在实验室中重新开启以下载');
    if (busy) throw StateError('另一项 AnimeJaNai 安装尚未完成');
    busy = true;
    _cancelled = false;
    _cancel = CancelToken();
    Directory? staging;
    Directory? previous;
    try {
      await directory.create(recursive: true);
      staging = await directory.createTemp('.install-');
      final payload = Directory('${staging.path}/payload');
      final inf = Directory('${payload.path}/animejanai/inference');
      final models = Directory('${payload.path}/animejanai/onnx');
      await inf.create(recursive: true);
      await models.create(recursive: true);
      final selected = packages ?? animeJaNaiPackages(backend, sm);
      for (var i = 0; i < selected.length; i++) {
        _check();
        final p = selected[i];
        final archive = File('${staging.path}/download-$i');
        status = '下载 ${p.name}（${i + 1}/${selected.length}）';
        progress = 0;
        _notify();
        var lastNotify = 0;
        await _dio.download(
          p.url,
          archive.path,
          cancelToken: _cancel,
          onReceiveProgress: (received, total) {
            if (received > p.bytes) _cancel?.cancel('文件大小与固定版本不符');
            final now = DateTime.now().millisecondsSinceEpoch;
            if (now - lastNotify > 150 || received == total) {
              lastNotify = now;
              progress = (received / p.bytes).clamp(0, 1);
              _notify();
            }
          },
        );
        _check();
        status = '校验 ${p.name}…';
        progress = null;
        _notify();
        await verifyAnimeJaNaiDownload(archive, p);
        _check();
        status = '安装 ${p.name}…';
        _notify();
        if (p.model) {
          await archive.copy('${models.path}/${p.name}');
        } else if (p.sevenZip) {
          await _extract7z(archive, payload);
        } else {
          await compute(extractAnimeJaNaiZip, (
            archive.path,
            inf.path,
            p.files,
          ));
        }
        _check();
        await archive.delete();
      }
      await File('${payload.path}/animejanai.conf').writeAsString(
        '[global]\nconfig_version=2\nbackend=${backend.label}\nlogging=yes\n',
        flush: true,
      );
      await File('${payload.path}/THIRD_PARTY_NOTICES.txt').writeAsString(
        'AnimeJaNai models by the-database, unmodified, CC BY-NC-SA 4.0.\n'
        'https://github.com/the-database/mpv-AnimeJaNai/tree/6361f4fe059d22984f9074860a4a227489a5d464\n'
        'https://creativecommons.org/licenses/by-nc-sa/4.0/\n'
        'AJI v0.11.1: https://github.com/the-database/animejanai-inference/tree/v0.11.1\n'
        'TensorRT/CUDA: NVIDIA, distributed under the included runtime licenses.\n'
        'ONNX Runtime and DirectML: Microsoft, see licenses in animejanai/inference.\n',
      );
      await File(
        '${payload.path}/ready',
      ).writeAsString(AnimeJaNaiRuntime.version, flush: true);
      if (requiredFiles != null) {
        for (final name in requiredFiles) {
          if (!await File('${inf.path}/$name').exists()) {
            throw StateError('运行库缺少 $name');
          }
        }
      } else if (!await AnimeJaNaiRuntime(payload, backend).available()) {
        throw StateError('下载包缺少必需的 AnimeJaNai 运行文件');
      }
      _check();
      if (await target.exists()) {
        previous = await target.rename('${staging.path}/previous');
      }
      try {
        await payload.rename(target.path);
      } catch (_) {
        if (previous != null) await previous.rename(target.path);
        rethrow;
      }
      status = '${backend.label} 运行库已就绪';
      return runtime;
    } catch (_) {
      if (_cancelled || _closed) throw const AnimeJaNaiInstallCancelled();
      rethrow;
    } finally {
      busy = false;
      progress = null;
      _cancel = null;
      _process = null;
      if (staging != null && await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {
          /* A scanner may hold a temporary file. */
        }
      }
      _notify();
    }
  }

  Future<void> _extract7z(
    File archive,
    Directory target, {
    String directory = 'animejanai/inference',
    List<String> files = const [],
  }) async {
    final tool =
        unpacker ??
        '${File(Platform.resolvedExecutable).parent.path}/data/animejanai/7za.exe';
    if (!await File(tool).exists()) {
      throw StateError('安装包缺少 AnimeJaNai 解压工具，请重新安装应用');
    }
    final listing = await Process.run(tool, [
      'l',
      '-slt',
      '-ba',
      '--',
      archive.path,
    ]);
    _check();
    if (listing.exitCode != 0) throw StateError('无法读取 AnimeJaNai 下载包');
    validateAnimeJaNaiArchiveListing(
      listing.stdout.toString(),
      directory: directory,
    );
    _process = await Process.start(tool, [
      'x',
      '-y',
      '-o${target.path}',
      '--',
      archive.path,
      ...files,
    ]);
    final output = _process!.stdout.drain<void>();
    final errors = _process!.stderr.drain<void>();
    final exit = await _process!.exitCode;
    await Future.wait([output, errors]);
    _process = null;
    _check();
    if (exit != 0) throw StateError('AnimeJaNai 下载包解压失败（$exit）');
  }

  @override
  void dispose() {
    _closed = true;
    cancel();
    _dio.close(force: true);
    super.dispose();
  }
}

Future<void> verifyAnimeJaNaiDownload(File file, AnimeJaNaiPackage p) async {
  if (await file.length() != p.bytes ||
      (await sha256.bind(file.openRead()).first).toString() != p.sha256sum) {
    throw StateError('${p.name} 大小或 SHA-256 校验失败，请重试');
  }
}

void validateAnimeJaNaiArchiveListing(
  String listing, {
  String directory = 'animejanai/inference',
}) {
  for (final line in const LineSplitter().convert(listing)) {
    if (line.startsWith('Symbolic Link =') ||
        line.startsWith('Hard Link =') ||
        line.startsWith('Reparse Point =')) {
      throw const FormatException('下载包包含不支持的链接');
    }
    if (!line.startsWith('Path = ')) continue;
    final path = line.substring(7).replaceAll('\\', '/');
    if (path.startsWith('/') ||
        path.contains(':') ||
        path.split('/').contains('..') ||
        !(path == 'animejanai' ||
            path == directory ||
            path.startsWith('$directory/'))) {
      throw const FormatException('下载包包含越界路径');
    }
  }
}

void extractAnimeJaNaiZip((String, String, Map<String, String>) args) {
  final input = InputFileStream(args.$1);
  try {
    final archive = ZipDecoder().decodeStream(input);
    for (final entry in args.$3.entries) {
      final file = archive.findFile(entry.key);
      if (file == null || !file.isFile || file.isSymbolicLink) {
        throw FormatException('下载包缺少 ${entry.key}');
      }
      final output = OutputFileStream('${args.$2}/${entry.value}');
      try {
        file.writeContent(output);
      } finally {
        output.closeSync();
      }
    }
  } finally {
    input.closeSync();
  }
}
