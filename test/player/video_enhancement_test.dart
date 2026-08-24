import 'dart:io';

import 'package:baka/models/playback_state.dart';
import 'package:baka/widgets/baka_player/anime4k.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps AniBaka as an auxiliary shader for every level', () {
    for (final pipeline in VideoEnhancementPipeline.values) {
      final files = Anime4K.pipelineFiles(pipeline, mobile: false);
      if (pipeline == VideoEnhancementPipeline.off) {
        expect(files, isEmpty);
      } else {
        expect(files, contains('AniBaka_Clear_v1.glsl'));
        expect(files.length, greaterThan(1));
      }
    }
  });

  test('uses the recommended desktop medium, high and ultra pipelines', () {
    expect(
      Anime4K.pipelineFiles(VideoEnhancementPipeline.medium, mobile: false),
      [
        'Anime4K_Clamp_Highlights.glsl',
        'AniBaka_Clear_v1.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
        'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ],
    );
    expect(
      Anime4K.pipelineFiles(VideoEnhancementPipeline.high, mobile: false),
      containsAll(<String>[
        'Anime4K_Restore_CNN_Soft_VL.glsl',
        'Anime4K_Upscale_CNN_x2_VL.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ]),
    );
    expect(
      Anime4K.pipelineFiles(VideoEnhancementPipeline.ultra, mobile: false),
      containsAll(<String>[
        'Anime4K_Restore_CNN_VL.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_VL.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ]),
    );
  });

  test('keeps mobile levels on the lighter M/S variants', () {
    final low = Anime4K.pipelineFiles(
      VideoEnhancementPipeline.low,
      mobile: true,
    );
    final high = Anime4K.pipelineFiles(
      VideoEnhancementPipeline.high,
      mobile: true,
    );
    final ultra = Anime4K.pipelineFiles(
      VideoEnhancementPipeline.ultra,
      mobile: true,
    );

    // 移动端低档优先性能，但仍保留常规 Restore 让效果可见（Soft 太含蓄）。
    expect(low, [
      'Anime4K_Clamp_Highlights.glsl',
      'AniBaka_Clear_v1.glsl',
      'Anime4K_Restore_CNN_M.glsl',
      'Anime4K_Upscale_CNN_x2_S.glsl',
    ]);
    expect(low, isNot(contains('Anime4K_Restore_CNN_Soft_M.glsl')));
    expect(high, isNot(contains('Anime4K_Restore_CNN_VL.glsl')));
    expect(high, isNot(contains('Anime4K_Upscale_CNN_x2_VL.glsl')));
    expect(ultra, contains('Anime4K_Restore_CNN_M.glsl'));
    expect(ultra, contains('Anime4K_Upscale_CNN_x2_S.glsl'));
  });

  test('CNN shaders use GLES-compatible vector activation bounds', () {
    final shaders = Directory(
      'assets/anime4k',
    ).listSync().whereType<File>().where((file) => file.path.contains('_CNN_'));
    var vectorBounds = 0;

    for (final shader in shaders) {
      final source = shader.readAsStringSync();
      expect(
        source,
        isNot(contains('), 0.0))')),
        reason: '${shader.path} still compares a vec4 texture with a scalar',
      );
      vectorBounds += 'vec4(0.0)'.allMatches(source).length;
    }

    expect(vectorBounds, 384);
  });

  test('maps exactly to the four user-facing levels', () {
    expect(
      selectEnhancementPipeline(VideoEnhancementMode.off),
      VideoEnhancementPipeline.off,
    );
    expect(
      selectEnhancementPipeline(VideoEnhancementMode.low),
      VideoEnhancementPipeline.low,
    );
    expect(
      selectEnhancementPipeline(VideoEnhancementMode.medium),
      VideoEnhancementPipeline.medium,
    );
    expect(
      selectEnhancementPipeline(VideoEnhancementMode.high),
      VideoEnhancementPipeline.high,
    );
    expect(
      selectEnhancementPipeline(VideoEnhancementMode.ultra),
      VideoEnhancementPipeline.ultra,
    );
  });

  test(
    'shader staging replaces stale bytes and verifies the final file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'anibaka-shader-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final target = File(
        '${directory.path}${Platform.pathSeparator}shader.glsl',
      );
      await target.writeAsBytes([1, 2, 3]);

      final staged = await Anime4K.stageBytesForTest(directory, 'shader.glsl', [
        4,
        5,
        6,
        7,
      ]);

      expect(staged.path, target.path);
      expect(await staged.readAsBytes(), [4, 5, 6, 7]);
      expect(directory.listSync().whereType<File>().map((file) => file.path), [
        target.path,
      ]);
    },
  );

  test('shader staging throws instead of returning an invalid path', () async {
    final directory = await Directory.systemTemp.createTemp('anibaka-shader-');
    addTearDown(() => directory.delete(recursive: true));
    final notDirectory = File(
      '${directory.path}${Platform.pathSeparator}blocked',
    );
    await notDirectory.writeAsString('file');

    expect(
      () => Anime4K.stageBytesForTest(
        Directory(notDirectory.path),
        'shader.glsl',
        [1],
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
