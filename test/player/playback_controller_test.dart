import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_playback_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
  });

  test('reduces backend events into bounded timeline updates', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    await controller.open('https://example.test/video.mp4');

    backend.emitDuration(const Duration(seconds: 100));
    backend.emitPosition(const Duration(milliseconds: 100));
    expect(controller.timeline.value.position.inMilliseconds, 100);
    backend.emitPosition(const Duration(milliseconds: 200));
    expect(controller.timeline.value.position.inMilliseconds, 100);
    backend.emitPosition(const Duration(milliseconds: 260));
    expect(controller.timeline.value.position.inMilliseconds, 260);

    await controller.seek(const Duration(seconds: 200));
    expect(backend.lastSeek, const Duration(seconds: 100));
    await controller.dispose();
  });

  test('opening a paused replacement stops the previous media first', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);

    await controller.open('https://example.test/first.m3u8');
    await controller.pause();
    expect(backend.isPlaying, isFalse);
    expect(backend.currentMediaUri, isNotNull);

    await controller.open('https://example.test/second.m3u8');

    expect(backend.stopCount, 1);
    expect(backend.currentMediaUri, 'https://example.test/second.m3u8');
    await controller.dispose();
  });

  test(
    'skip state machine is driven by media position without periodic timer',
    () async {
      final backend = FakePlaybackBackend();
      final controller = PlaybackController(backend: backend);
      await controller.open('https://example.test/video.mp4');
      await controller.updatePreferences(
        controller.preferences.value.copyWith(
          enableSkipOpEd: true,
          skipOpWaitTime: 30,
          skipOpDuration: 60,
        ),
        persist: false,
      );

      backend.emitDuration(const Duration(seconds: 180));
      backend.emitPosition(const Duration(seconds: 1));
      expect(controller.overlay.value.skipState, SkipState.waiting);
      backend.emitPosition(const Duration(seconds: 30));
      await Future<void>.delayed(Duration.zero);
      expect(controller.overlay.value.skipState, SkipState.showingCancel);
      expect(backend.lastSeek, const Duration(seconds: 90));
      await controller.dispose();
    },
  );

  test('reduces commands, tracks, rate, subtitle and Anime4K state', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    await controller.initialize();

    await controller.play();
    expect(backend.isPlaying, isTrue);
    controller.togglePlayback();
    await Future<void>.delayed(Duration.zero);
    expect(backend.isPlaying, isFalse);

    await controller.setRate(2.5);
    expect(controller.core.value.playbackRate, 2.5);
    expect(backend.lastRate, 2.5);
    await controller.setRate(0);
    expect(backend.lastRate, 1.0);

    const subtitle = SubtitleTrack('zh', '简体中文', 'zh');
    backend.emitTracks(const Tracks(subtitle: [subtitle]));
    expect(controller.core.value.hasSubtitleTracks, isTrue);
    await controller.setSubtitleTrack(subtitle);
    expect(backend.lastSubtitleTrack, subtitle);

    await controller.updatePreferences(
      controller.preferences.value.copyWith(anime4KLevel: 'high'),
      persist: false,
    );
    expect(backend.nativeProperties['glsl-shaders'], '');
    await controller.toggleSubtitle();
    expect(backend.nativeProperties['sub-visibility'], 'no');

    final completion = expectLater(controller.completed, emits(null));
    backend.emitCompleted();
    await completion;
    await controller.dispose();
  });

  test('debounces buffering and recovers from fatal error state', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    await controller.initialize();

    backend.emitPlaying(true);
    expect(controller.core.value.buffering, isFalse);
    backend.emitBuffering(true);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(controller.core.value.buffering, isTrue);
    backend.emitBuffering(false);
    expect(controller.core.value.buffering, isFalse);

    backend.emitPlaying(false);
    backend.emitError('fatal\nmessage');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(controller.core.value.failed, isTrue);
    expect(controller.core.value.errorMessage, contains('fatal'));
    backend.emitPlaying(true);
    expect(controller.core.value.failed, isFalse);
    expect(controller.core.value.errorMessage, isEmpty);
    await controller.dispose();
  });

  test('dispose cancels backend subscriptions and backend lifetime', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    await controller.initialize();
    await controller.dispose();
    expect(backend.disposed, isTrue);
  });
}
