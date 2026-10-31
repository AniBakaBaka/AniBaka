import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

enum AnimeJaNaiBackend {
  auto('自动'),
  tensorRT('TensorRT'),
  directML('DirectML');

  const AnimeJaNaiBackend(this.label);
  final String label;

  static AnimeJaNaiBackend fromStorage(String? value) =>
      values.where((v) => v.name == value).firstOrNull ?? auto;
}

enum AnimeJaNaiProfile {
  quality(1001, '质量'),
  balanced(1002, '均衡'),
  performance(1003, '性能');

  const AnimeJaNaiProfile(this.slot, this.label);
  final int slot;
  final String label;

  static AnimeJaNaiProfile fromStorage(String? value) =>
      values.where((v) => v.name == value).firstOrNull ?? balanced;
}

enum AnimeJaNaiPhase {
  off,
  preparing,
  waiting,
  building,
  active,
  bypassed,
  failed,
}

enum AnimeJaNaiFrameMultiplier {
  x2(2),
  x3(3),
  x4(4);

  const AnimeJaNaiFrameMultiplier(this.factor);
  final int factor;
  String get label => '$factor×';
  int slot(
    AnimeJaNaiProfile profile, {
    AnimeJaNaiInterpolationMode mode = AnimeJaNaiInterpolationMode.full,
  }) =>
      profile.slot +
      (factor - 1) * 1000 +
      (mode == AnimeJaNaiInterpolationMode.fast ? 3000 : 0);
  static AnimeJaNaiFrameMultiplier fromStorage(String? value) =>
      values.where((v) => v.name == value).firstOrNull ?? x2;
}

enum AnimeJaNaiInterpolationMode {
  full('完整（原分辨率处理）'),
  fast('快速（最高 540p 处理）');

  const AnimeJaNaiInterpolationMode(this.label);
  final String label;
  static AnimeJaNaiInterpolationMode fromStorage(String? value) =>
      values.where((v) => v.name == value).firstOrNull ?? full;
}

enum AnimeJaNaiLook {
  original('原版（自然）'),
  sharp('Sharp1（清晰线条）');

  const AnimeJaNaiLook(this.label);
  final String label;
  static AnimeJaNaiLook fromStorage(String? value) =>
      values.where((v) => v.name == value).firstOrNull ?? original;
}

enum AnimeJaNaiAdjustment {
  sharpen('细节锐化', 'sharpen', 0, 1),
  brightness('亮度', 'brightness', -30, 30),
  contrast('对比度', 'contrast', -50, 50),
  saturation('饱和度', 'saturation', -50, 50),
  gamma('伽马', 'gamma', -30, 30);

  const AnimeJaNaiAdjustment(this.label, this.property, this.min, this.max);
  final String label, property;
  final double min, max;
}

class AnimeJaNaiPicture {
  AnimeJaNaiPicture()
    : _values = List<double>.filled(AnimeJaNaiAdjustment.values.length, 0);
  final List<double> _values;
  double operator [](AnimeJaNaiAdjustment key) => _values[key.index];
  void operator []=(AnimeJaNaiAdjustment key, double value) =>
      _values[key.index] = value;
  String toStorage() => jsonEncode({
    for (final key in AnimeJaNaiAdjustment.values) key.name: this[key],
  });
  static AnimeJaNaiPicture fromStorage(String? value) {
    final result = AnimeJaNaiPicture();
    if (value == null) return result;
    final map = jsonDecode(value) as Map<String, dynamic>;
    for (final key in AnimeJaNaiAdjustment.values) {
      result[key] = (map[key.name] as num?)?.toDouble() ?? 0;
    }
    return result;
  }
}

class AnimeJaNaiStatus {
  const AnimeJaNaiStatus(
    this.phase,
    this.message, {
    this.backend,
    this.details = '',
  });

  static const off = AnimeJaNaiStatus(AnimeJaNaiPhase.off, 'AnimeJaNai 已关闭');
  final AnimeJaNaiPhase phase;
  final String message;
  final AnimeJaNaiBackend? backend;
  final String details;
  bool get active => phase == AnimeJaNaiPhase.active;
  bool get failed => phase == AnimeJaNaiPhase.failed;
  bool get busy =>
      phase == AnimeJaNaiPhase.preparing || phase == AnimeJaNaiPhase.building;
}

/// Uses the same CUDA device ordinal as mpv's default NVDEC device. No CUDA
/// toolkit or nvidia-smi installation is required, only the display driver.
class AnimeJaNaiGpu {
  const AnimeJaNaiGpu(this.name, this.sm, this.driver);
  final String name;
  final int sm;
  final int driver;

  static AnimeJaNaiGpu? probe() {
    if (!Platform.isWindows) return null;
    try {
      final cuda = DynamicLibrary.open('nvcuda.dll');
      final init = cuda
          .lookupFunction<Int32 Function(Uint32), int Function(int)>('cuInit');
      if (init(0) != 0) return null;
      final getDevice = cuda
          .lookupFunction<
            Int32 Function(Pointer<Int32>, Int32),
            int Function(Pointer<Int32>, int)
          >('cuDeviceGet');
      final getCapability = cuda
          .lookupFunction<
            Int32 Function(Pointer<Int32>, Pointer<Int32>, Int32),
            int Function(Pointer<Int32>, Pointer<Int32>, int)
          >('cuDeviceComputeCapability');
      final getName = cuda
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32, Int32),
            int Function(Pointer<Utf8>, int, int)
          >('cuDeviceGetName');
      final getDriver = cuda
          .lookupFunction<
            Int32 Function(Pointer<Int32>),
            int Function(Pointer<Int32>)
          >('cuDriverGetVersion');
      final ints = calloc<Int32>(4);
      final name = calloc<Uint8>(256).cast<Utf8>();
      try {
        if (getDevice(ints, 0) != 0 ||
            getCapability(ints + 1, ints + 2, ints.value) != 0 ||
            getName(name, 256, ints.value) != 0 ||
            getDriver(ints + 3) != 0) {
          return null;
        }
        return AnimeJaNaiGpu(
          name.toDartString(),
          ints[1] * 10 + ints[2],
          ints[3],
        );
      } finally {
        calloc.free(ints);
        calloc.free(name);
      }
    } catch (_) {
      return null;
    }
  }
}

AnimeJaNaiBackend selectAnimeJaNaiBackend(
  AnimeJaNaiBackend requested,
  AnimeJaNaiGpu? gpu,
) => requested == AnimeJaNaiBackend.auto
    ? gpu != null && gpu.sm >= 75
          ? AnimeJaNaiBackend.tensorRT
          : AnimeJaNaiBackend.directML
    : requested;

/// mpv's %n% escaping counts UTF-8 bytes, not Dart UTF-16 code units.
String animeJaNaiMpvValue(String value) {
  final bytes = const Utf8Encoder().convert(value);
  return '%${bytes.length}%$value';
}
