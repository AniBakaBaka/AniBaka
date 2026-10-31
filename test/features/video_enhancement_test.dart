import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/services/playback/animejanai_playback.dart';
import 'package:baka/services/playback/animejanai_runtime.dart';
import 'package:baka/services/playback/dlss_global_playback.dart';
import 'package:baka/services/playback/video_enhancement_bridge.dart';
import 'package:baka/widgets/settings/video_enhancement_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReadyRifeInstaller extends AnimeJaNaiInstaller {
  @override
  Future<void> ensureInterpolation(
    AnimeJaNaiRuntime runtime, {
    bool allowInstall = true,
    AnimeJaNaiPackage package = animeJaNaiRifePackage,
    AnimeJaNaiPackage model = animeJaNaiRifeModel,
  }) async {}
}

class _Player extends AnimeJaNaiPlayer {
  _Player(this.directory);
  final Directory directory;
  @override
  bool playing = true;
  @override
  final values = <String, String>{
    'vf': '@user:format',
    'hwdec-current': 'nvdec',
    'video-params/pixelformat': 'cuda',
    'video-params/w': '1920',
    'video-params/h': '1080',
    'video-out-params/w': '1920',
    'video-out-params/h': '1080',
    'seeking': 'no',
    'time-pos': '12.5',
    'playback-restart': '0',
    for (final a in AnimeJaNaiAdjustment.values) a.property: '0',
  };
  final commands = <List<String>>[];
  int reads = 0, pauses = 0, resumes = 0;
  bool building = false;
  bool rifeReady = true;
  bool outputReady = true;
  int slot = 1002;
  bool get fast => slot >= 5000;
  int get factor => slot ~/ 1000 - (fast ? 3 : 0);
  String get outWidth => slot == 0 || fast ? '1920' : '3840';
  String get outHeight => slot == 0 || fast ? '1080' : '2160';
  Completer<void>? adjustmentGate;
  Completer<void>? adjustmentStarted;
  File? stats;

  Future<void> completeBuild() async {
    building = false;
    await _writeStats();
    values['video-out-params/w'] = outWidth;
    values['video-out-params/h'] = outHeight;
    notifyListeners();
  }

  Future<void> _writeStats() => stats!.writeAsString(
    building
        ? 'Building TensorRT engine'
        : 'Applied Model: fixture.onnx; New Video Resolution: ${outWidth}x$outHeight\n${slot >= 2000 && rifeReady ? 'Applied RIFE v${fast ? 4141 : 414} Interpolation $factor.000x; New Video FPS: ${30 * factor}.000' : ''}',
  );

  @override
  Future<void> command(List<String> args) async {
    commands.add(args);
    if (args[0] == 'vf' && args[1] == 'add') {
      final config = await directory.list().firstWhere(
        (f) =>
            f.path.endsWith('.log.conf') &&
            args[2]
                .replaceAll('\\', '/')
                .contains(f.path.replaceAll('\\', '/')),
      );
      slot = int.parse(RegExp(r':slot=(\d+)').firstMatch(args[2])!.group(1)!);
      stats = File(config.path.substring(0, config.path.length - 5));
      values['vf'] = '@user:format,@anibaka_aji:animejanai';
      await _writeStats();
      if (!building && outputReady) {
        values['video-out-params/w'] = outWidth;
        values['video-out-params/h'] = outHeight;
      }
    } else if (args[0] == 'vf' && args[1] == 'remove') {
      values['vf'] = '@user:format';
    } else if (args[0] == 'vf-command' && args[2] == 'slot') {
      slot = int.parse(args[3]);
      await _writeStats();
      values['video-out-params/w'] = outWidth;
      values['video-out-params/h'] = outHeight;
    } else if (args[0] == 'set') {
      if (args[1] == 'brightness') {
        if (adjustmentStarted?.isCompleted == false) {
          adjustmentStarted!.complete();
        }
        await adjustmentGate?.future;
      }
      values[args[1]] = args[2];
    } else if (args[0] == 'seek') {
      values['playback-restart'] =
          '${int.parse(values['playback-restart']!) + 1}';
    } else {
      return;
    }
    notifyListeners();
  }

  @override
  Future<String> property(String name, {bool fresh = false}) async {
    reads++;
    return values[name] ?? '';
  }

  @override
  Future<void> pause() async {
    playing = false;
    pauses++;
  }

  @override
  Future<void> play() async {
    playing = true;
    resumes++;
  }

  @override
  Future<void> renderFrame() async {}
}

Future<void> _until(Listenable source, bool Function() ready) async {
  if (ready()) return;
  final completed = Completer<void>();
  void check() {
    if (ready() && !completed.isCompleted) completed.complete();
  }

  source.addListener(check);
  try {
    await completed.future.timeout(const Duration(seconds: 5));
  } finally {
    source.removeListener(check);
  }
}

Future<void> _send(String method, dynamic value) async {
  final reply = Completer<void>();
  ServicesBinding.instance.channelBuffers.push(
    VideoEnhancementBridge.channel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, value)),
    (_) => reply.complete(),
  );
  await reply.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
  });

  test(
    'native deltas share one map, isolate players and suppress duplicates',
    () async {
      final bridge = VideoEnhancementBridge.instance;
      final first = bridge.attach(11), second = bridge.attach(22);
      final values = first.values;
      var updates = 0;
      first.addListener(() => updates++);
      await _send('Video.Property', [11, 'video-out-params/w', '3840']);
      await _send('Video.Property', [11, 'video-out-params/w', '3840']);
      expect(identical(first.values, values), isTrue);
      expect(updates, 1);
      expect(second.values, isEmpty);
      bridge.detach(11);
      await _send('Video.Property', [11, 'video-out-params/w', '1920']);
      expect(updates, 1);
      bridge.detach(22);
    },
  );

  test(
    'old disabled playback switches remain disabled after two launches',
    () async {
      for (final prefix in ['animejanai', 'dlss5']) {
        final key = prefix == 'dlss5'
            ? 'dlss5_global_playback_enabled'
            : 'animejanai_enabled';
        final legacy = prefix == 'dlss5'
            ? 'dlss5_playback_enabled'
            : 'animejanai_playback';
        await Instances.sp.setBool(key, true);
        await Instances.sp.setBool(legacy, false);
        for (var launch = 0; launch < 2; launch++) {
          if (prefix == 'dlss5') {
            final service = DlssGlobalPlayback();
            await service.initialize();
            expect(service.enabled, isFalse);
            service.close();
          } else {
            final service = AnimeJaNaiService();
            await service.initialize();
            expect(service.enabled, isFalse);
            await service.close();
          }
        }
        expect(Instances.sp.containsKey(legacy), isFalse);
      }
    },
  );

  test('custom effects persist without copying the editable state', () async {
    final service = DlssGlobalPlayback();
    final effects = service.effects;
    effects.intensity = 1.4;
    effects.sharpness = .8;
    effects.maxHeight = 720;
    effects.neuralRendering = true;
    effects.superResolution = false;
    effects.frameGeneration = false;
    effects.comparison = true;
    await service.saveEffects();
    expect(identical(service.effects, effects), isTrue);
    final saved = jsonDecode(
      Instances.sp.getString('dlss5_global_playback_effects')!,
    );
    expect(saved, effects.toJson());
    final picture = AnimeJaNaiPicture();
    picture[AnimeJaNaiAdjustment.gamma] = 2;
    expect(
      AnimeJaNaiPicture.fromStorage(
        picture.toStorage(),
      )[AnimeJaNaiAdjustment.gamma],
      2,
    );
  });

  group('event-driven playback', () {
    late Directory directory;
    late AnimeJaNaiService service;
    late AnimeJaNaiPlayback playback;
    late _Player player;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('baka-enhancement-');
      service = AnimeJaNaiService(installer: _ReadyRifeInstaller())
        ..enabled = true
        ..backend = AnimeJaNaiBackend.tensorRT
        ..runtime = AnimeJaNaiRuntime(directory, AnimeJaNaiBackend.tensorRT);
      player = _Player(directory);
      playback = AnimeJaNaiPlayback(
        service: service,
        logDirectory: () async => directory,
      )..attach(player);
    });
    tearDown(() async {
      playback.dispose();
      await service.close();
      // Windows releases directory-watch handles asynchronously after cancel.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await directory.delete(recursive: true);
    });

    Future<void> start() async {
      await playback.configure();
      playback.opened();
      await _until(playback, () => playback.status.active);
    }

    testWidgets('steady playback performs no timed reads or commands', (
      tester,
    ) async {
      await tester.runAsync(start);
      final reads = player.reads, commands = player.commands.length;
      await tester.pump(const Duration(seconds: 20));
      expect(player.reads, reads);
      expect(player.commands.length, commands);
    });

    test(
      'rapid adjustments coalesce and off restores only owned effects',
      () async {
        await start();
        player.adjustmentGate = Completer<void>();
        player.adjustmentStarted = Completer<void>();
        service.adjustPicture(AnimeJaNaiAdjustment.brightness, 1);
        await player.adjustmentStarted!.future;
        for (var value = 2; value <= 20; value++) {
          service.adjustPicture(
            AnimeJaNaiAdjustment.brightness,
            value.toDouble(),
          );
        }
        player.adjustmentGate!.complete();
        await _until(player, () => player.values['brightness'] == '20.0');
        expect(
          player.commands
              .where((c) => c[0] == 'set' && c[1] == 'brightness')
              .length,
          lessThanOrEqualTo(2),
        );
        await service.setEnabled(false);
        await _until(
          playback,
          () => playback.status.phase == AnimeJaNaiPhase.off,
        );
        expect(player.values['brightness'], '0');
        expect(player.values['vf'], '@user:format,@anibaka_aji:animejanai');
        expect(player.values['video-out-params/w'], '1920');
        await service.setEnabled(true);
        await _until(playback, () => playback.status.active);
        expect(player.values['brightness'], '20.0');
        expect(
          player.commands.where((c) => c[0] == 'vf' && c[1] == 'add'),
          hasLength(1),
        );
        expect(
          player.commands.where((c) => c[0] == 'set' && c[1] == 'hwdec'),
          isEmpty,
        );
      },
    );

    test(
      'RIFE switches factor, bypasses and restores without rebuilding playback',
      () async {
        await start();
        await service.setInterpolation(true);
        await _until(
          playback,
          () => playback.status.message.contains('RIFE 2×'),
        );
        expect(playback.status.message, contains('60.000 fps'));
        await service.setFrameMultiplier(AnimeJaNaiFrameMultiplier.x3);
        await _until(
          playback,
          () => playback.status.message.contains('RIFE 3×'),
        );
        expect(player.slot, 3002);
        await player.pause();
        final comparison = await playback.captureComparison(
          captureFrame: () async => Uint8List.fromList([1]),
        );
        expect(player.slot, 3002);
        await comparison.close();
        expect(player.playing, isFalse);
        await service.setEnabled(false);
        await _until(
          playback,
          () => playback.status.phase == AnimeJaNaiPhase.off,
        );
        expect(player.slot, 0);
        await service.setEnabled(true);
        await _until(playback, () => playback.status.active);
        expect(player.slot, 3002);
        await service.setInterpolation(false);
        await _until(
          playback,
          () => playback.status.active && player.slot == 1002,
        );
        expect(playback.status.message, isNot(contains('RIFE')));
        expect(
          player.commands.where((c) => c[0] == 'vf' && c[1] == 'add'),
          hasLength(1),
        );
        expect(
          player.commands.where((c) => c[0] == 'set' && c[1] == 'hwdec'),
          isEmpty,
        );
      },
    );

    test(
      'upscaling alone cannot report requested interpolation as active',
      () async {
        service.interpolation = true;
        player.rifeReady = false;
        await playback.configure();
        playback.opened();
        await _until(playback, () => playback.status.message == '等待 RIFE 补帧生效');
        expect(playback.status.active, isFalse);
        player.rifeReady = true;
        await player.completeBuild();
        await _until(playback, () => playback.status.active);
        expect(playback.status.message, contains('RIFE 2×'));
      },
    );

    test(
      'RIFE model readiness still waits for the configured output dimensions',
      () async {
        service.interpolation = true;
        player.outputReady = false;
        await playback.configure();
        playback.opened();
        await _until(playback, () => playback.status.message == '等待超分画面');
        expect(playback.status.active, isFalse);
        await player.completeBuild();
        await _until(playback, () => playback.status.active);
        expect(playback.status.message, contains('1920×1080 → 3840×2160'));
      },
    );

    test(
      'fast mode is explicit and changes slots without changing multiplier or backend',
      () async {
        service.interpolation = true;
        await start();
        expect(player.slot, 2002);
        await service.setInterpolationMode(AnimeJaNaiInterpolationMode.fast);
        await _until(
          playback,
          () =>
              playback.status.active && playback.status.message.contains('快速'),
        );
        expect(player.slot, 5002);
        expect(playback.status.message, contains('1920×1080 → 1920×1080'));
        expect(service.frameMultiplier, AnimeJaNaiFrameMultiplier.x2);
        expect(service.backend, AnimeJaNaiBackend.tensorRT);
        await service.setInterpolationMode(AnimeJaNaiInterpolationMode.full);
        await _until(
          playback,
          () => playback.status.active && player.slot == 2002,
        );
        expect(
          player.commands.where((c) => c[0] == 'vf' && c[1] == 'add'),
          hasLength(1),
        );
      },
    );

    test(
      'an inference error pauses without removing effects or changing backend',
      () async {
        service.backend = AnimeJaNaiBackend.auto;
        service.interpolation = true;
        await start();
        final runtime = service.runtime;
        final count = player.commands.length;
        playback.nativeLog('animejanai', 'error', 'fixture inference failed');
        await _until(playback, () => playback.status.failed);
        expect(player.playing, isFalse);
        expect(service.runtime, same(runtime));
        expect(service.interpolation, isTrue);
        expect(player.slot, 2002);
        expect(player.commands.skip(count), isEmpty);
        expect(player.values['vf'], contains('anibaka_aji'));
        await playback.retry();
        await _until(playback, () => playback.status.active);
        expect(player.playing, isFalse);
        expect(service.runtime, same(runtime));
      },
    );

    test(
      'compilation respects a manual pause and stops its polling afterwards',
      () async {
        player.building = true;
        await playback.configure();
        playback.opened();
        await _until(
          playback,
          () => playback.status.phase == AnimeJaNaiPhase.building,
        );
        playback.userPaused();
        await player.completeBuild();
        await _until(playback, () => playback.status.active);
        expect(player.playing, isFalse);
        expect(player.resumes, 0);
      },
    );

    test(
      'comparison waits for seek completion and preserves a preexisting pause',
      () async {
        await start();
        await player.pause();
        var captured = 0;
        final images = await playback.captureComparison(
          captureFrame: () async {
            captured++;
            return Uint8List.fromList([captured]);
          },
        );
        expect(captured, 2);
        expect(
          player.commands
              .where((c) => c[0] == 'seek' && c[2] == 'absolute+exact')
              .map((c) => c[1]),
          ['12.5', '12.5', '12.5'],
        );
        expect(player.values['video-out-params/w'], '3840');
        await images.close();
        expect(player.playing, isFalse);
      },
    );

    test('comparison serializes an in-flight custom adjustment', () async {
      await start();
      player.adjustmentGate = Completer<void>();
      player.adjustmentStarted = Completer<void>();
      service.adjustPicture(AnimeJaNaiAdjustment.brightness, 8);
      await player.adjustmentStarted!.future;
      final captured = <String>[];
      final pending = playback.captureComparison(
        captureFrame: () async {
          captured.add(player.values['brightness']!);
          return Uint8List.fromList([1]);
        },
      );
      player.adjustmentGate!.complete();
      final comparison = await pending;
      expect(captured, ['8.0', '0']);
      expect(player.values['brightness'], '8.0');
      await comparison.close();
    });
  });

  testWidgets('one settings panel retains all custom effect controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: VideoEnhancementSettings()),
        ),
      ),
    );
    for (final label in [
      'AnimeJaNai',
      'DLSS',
      '神经改绘',
      '改绘强度',
      '输出锐化',
      '帧生成',
      '画质对比',
      '亮度',
      '对比度',
      '饱和度',
      '伽马',
      'RIFE 补帧',
      '补帧倍率',
      '补帧方案',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('启用'), findsNWidgets(2));
    expect(find.text('播放时启用'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
