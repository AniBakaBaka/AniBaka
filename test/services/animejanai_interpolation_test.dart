import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/playback/animejanai_playback.dart';
import 'package:baka/services/playback/animejanai_runtime.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Download implements HttpClientAdapter {
  _Download(this.bytes);
  final List<int> bytes;
  int requests = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentLengthHeader: ['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AnimeJaNaiRuntime runtime;
  late AnimeJaNaiInstaller installer;
  late AnimeJaNaiPackage package, model;
  late _Download download;
  const bytes = [1, 2, 3, 4, 5];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('baka-rife-test-');
    runtime = AnimeJaNaiRuntime(
      await Directory('${root.path}/runtime').create(),
      AnimeJaNaiBackend.tensorRT,
    );
    final archive = Archive()
      ..addFile(
        ArchiveFile('animejanai/rife/rife_v4.14.onnx', bytes.length, bytes),
      );
    final encoded = ZipEncoder().encode(archive);
    download = _Download(encoded);
    installer = AnimeJaNaiInstaller(dio: Dio()..httpClientAdapter = download);
    package = AnimeJaNaiPackage(
      'fixture',
      'https://fixture.invalid/rife.zip',
      encoded.length,
      sha256.convert(encoded).toString(),
    );
    model = AnimeJaNaiPackage(
      'rife_v4.14.onnx',
      '',
      bytes.length,
      sha256.convert(bytes).toString(),
    );
  });
  tearDown(() async {
    installer.dispose();
    await root.delete(recursive: true);
  });

  Future<void> install({bool allowInstall = true}) =>
      installer.ensureInterpolation(
        runtime,
        allowInstall: allowInstall,
        package: package,
        model: model,
      );

  test(
    'verified RIFE component is shared across backends and checked offline',
    () async {
      await install();
      final dml = AnimeJaNaiRuntime(
        Directory('${root.path}/dml'),
        AnimeJaNaiBackend.directML,
      );
      expect(dml.rifeModels, runtime.rifeModels);
      await installer.ensureInterpolation(
        dml,
        allowInstall: false,
        model: model,
      );
      expect(download.requests, 1);
      await File(
        '${runtime.rifeModels}/${model.name}',
      ).writeAsBytes([5, 4, 3, 2, 1]);
      await expectLater(install(allowInstall: false), throwsStateError);
      expect(download.requests, 1);
      expect(installer.busy, isFalse);
    },
  );

  test(
    'adding a model preserves the existing mode and compiled engines',
    () async {
      await install();
      final target = Directory(runtime.rifeModels);
      final cached = await File(
        '${target.path}/keep.engine',
      ).writeAsString('keep');
      final other = AnimeJaNaiPackage(
        'rife_v4.14_lite.onnx',
        '',
        bytes.length,
        sha256.convert(bytes).toString(),
      );
      final archive = Archive()
        ..addFile(
          ArchiveFile('animejanai/rife/${other.name}', bytes.length, bytes),
        );
      final encoded = ZipEncoder().encode(archive);
      final added = AnimeJaNaiInstaller(
        dio: Dio()..httpClientAdapter = _Download(encoded),
      );
      try {
        await added.ensureInterpolation(
          runtime,
          model: other,
          package: AnimeJaNaiPackage(
            'lite',
            package.url,
            encoded.length,
            sha256.convert(encoded).toString(),
          ),
        );
        expect(await cached.readAsString(), 'keep');
        expect(await File('${target.path}/${model.name}').readAsBytes(), bytes);
        expect(await File('${target.path}/${other.name}').readAsBytes(), bytes);
      } finally {
        added.dispose();
      }
    },
  );

  test(
    'archive integrity failure preserves existing models and engine cache',
    () async {
      final target = await Directory(runtime.rifeModels).create();
      final cached = await File(
        '${target.path}/cached.engine',
      ).writeAsString('keep');
      package = AnimeJaNaiPackage(
        'corrupt',
        package.url,
        package.bytes,
        'wrong-hash',
      );
      await expectLater(install(), throwsStateError);
      expect(await cached.readAsString(), 'keep');
      expect(await File('${target.path}/${model.name}').exists(), isFalse);
      expect(await root.list().any((f) => f.path.contains('.rife-')), isFalse);
      expect(installer.busy, isFalse);
    },
  );

  test('cancelling download leaves no ready model and allows retry', () async {
    void cancel() {
      if ((installer.progress ?? 0) > 0) installer.cancel();
    }

    installer.addListener(cancel);
    await expectLater(install(), throwsA(isA<AnimeJaNaiInstallCancelled>()));
    installer.removeListener(cancel);
    expect(await Directory(runtime.rifeModels).exists(), isFalse);
    expect(installer.busy, isFalse);
    await install();
    expect(
      await File('${runtime.rifeModels}/${model.name}').readAsBytes(),
      bytes,
    );
  });

  test('RIFE extraction rejects traversal, foreign directories and links', () {
    void validate(String path) => validateAnimeJaNaiArchiveListing(
      'Path = $path\n',
      directory: 'animejanai/rife',
    );
    validate(r'animejanai\rife\rife_v4.14.onnx');
    for (final path in [
      '../outside',
      'animejanai/rife/../../outside',
      'C:/outside',
      'animejanai/inference/aji.dll',
    ]) {
      expect(() => validate(path), throwsFormatException);
    }
    expect(
      () => validateAnimeJaNaiArchiveListing(
        'Path = animejanai/rife/model\nSymbolic Link = outside',
        directory: 'animejanai/rife',
      ),
      throwsFormatException,
    );
  });

  test(
    'RIFE preferences persist while disabled and invalid multiplier defaults to 2x',
    () async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      final service = AnimeJaNaiService();
      await service.initialize();
      expect(service.interpolation, isFalse);
      await service.setFrameMultiplier(AnimeJaNaiFrameMultiplier.x4);
      await service.setInterpolationMode(AnimeJaNaiInterpolationMode.fast);
      await service.setInterpolation(true);
      await service.close();
      final restored = AnimeJaNaiService();
      await restored.initialize();
      expect(restored.interpolation, isTrue);
      expect(restored.frameMultiplier, AnimeJaNaiFrameMultiplier.x4);
      expect(restored.interpolationMode, AnimeJaNaiInterpolationMode.fast);
      expect(restored.enabled, isFalse);
      await restored.close();
      expect(
        AnimeJaNaiFrameMultiplier.fromStorage('unknown'),
        AnimeJaNaiFrameMultiplier.x2,
      );
    },
  );
}
