import 'dart:io';

import 'package:baka/services/playback/dlss_frame_generation_runtime.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const version = '310.9.1-37495948-';
  final fixture = Platform.environment['ANIBAKA_DLSS_RUNTIME_FIXTURE'];
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('baka-dlss-test-');
  });
  tearDown(() async => root.delete(recursive: true));

  Future<Directory> ensure(Directory directory, {CancelToken? cancel}) =>
      DlssFrameGenerationRuntime.ensure(
        directory: directory,
        cancel: cancel ?? CancelToken(),
        allowDownload: false,
        onProgress: (_) {},
      );

  test(
    'cancelled checks do not create installation directories',
    () async {
      final target = Directory('${root.path}/missing');
      await expectLater(
        ensure(target, cancel: CancelToken()..cancel('test')),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(await target.exists(), isFalse);
    },
    skip: !Platform.isWindows,
  );

  test(
    'offline checks neither install nor accept incomplete runtimes',
    () async {
      final missing = Directory('${root.path}/missing');
      await expectLater(ensure(missing), throwsStateError);
      expect(await missing.exists(), isFalse);
      final candidate = await Directory(
        '${root.path}/${version}incomplete',
      ).create();
      await File('${candidate.path}/nvngx_dlssg.dll').writeAsBytes([1, 2, 3]);
      await expectLater(ensure(root), throwsStateError);
      expect(await candidate.exists(), isTrue);
    },
    skip: !Platform.isWindows,
  );

  test(
    'cached runtimes still verify file changes and switch installations',
    () async {
      Future<Directory> install(String suffix) async {
        final target = await Directory('${root.path}/$version$suffix').create();
        for (final name in ['nvngx_dlssg.dll', 'LICENSE.txt']) {
          await File('$fixture/$name').copy('${target.path}/$name');
        }
        return target;
      }

      final first = await install('first');
      expect((await ensure(root)).uri, first.uri);
      expect((await ensure(root)).uri, first.uri);
      final dll = File('${first.path}/nvngx_dlssg.dll');
      final handle = await dll.open(mode: FileMode.append);
      await handle.setPosition(0);
      await handle.writeByte(0);
      await handle.close();
      expect(await dll.length(), 7460976);
      await dll.setLastModified(DateTime.utc(2020));
      await expectLater(ensure(root), throwsStateError);
      final second = await install('second');
      expect((await ensure(root)).uri, second.uri);
      await File('${second.path}/LICENSE.txt').delete();
      await expectLater(ensure(root), throwsStateError);
    },
    skip: !Platform.isWindows || fixture == null,
  );
}
