import 'dart:async';

import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/baka_player/hls_seek_session.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_playback_backend.dart';

class _DanmakuSyncCounter implements DanmakuListener {
  int syncCount = 0;

  @override
  void onDanmakuTimeSync(Duration position) => syncCount++;
  @override
  void onDanmakuInject(List<DanmakuItem> items) {}
  @override
  void onDanmakuItemsChanged() {}
  @override
  void onDanmakuOptionChanged(DanmakuOption next, DanmakuOption previous) {}
  @override
  void onDanmakuPause() {}
  @override
  void onDanmakuPlaybackRateChanged(double rate) {}
  @override
  void onDanmakuReset() {}
  @override
  void onDanmakuResume() {}
}

class _FakeHlsSeekSession implements HlsSeekSession {
  bool disposed = false;
  Duration? target;

  @override
  ({String uri, Duration timelineOffset}) openFor(Duration target) {
    this.target = target;
    return (
      uri: 'http://127.0.0.1:1234/manifest.m3u8?start=${target.inSeconds}',
      timelineOffset: const Duration(minutes: 11, seconds: 55),
    );
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
  });

  tearDown(() {
    Instances.isTV = false;
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

  test(
    'bounds danmaku time anchors with high-frequency backend events',
    () async {
      final backend = FakePlaybackBackend();
      final controller = PlaybackController(backend: backend);
      final danmaku = DanmakuController();
      final counter = _DanmakuSyncCounter();
      danmaku.attach(counter);
      await controller.open('https://example.test/video.mp4');
      controller.attachDanmaku(danmaku);
      counter.syncCount = 0;

      for (var milliseconds = 1; milliseconds <= 100; milliseconds++) {
        backend.emitPosition(Duration(milliseconds: milliseconds));
      }

      expect(counter.syncCount, 1);
      danmaku.detach(counter);
      await controller.dispose();
    },
  );

  test('keeps hidden toast indicators idle during playback progress', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    await controller.open('https://example.test/video.mp4');

    final initialRevision = controller.toastRevision.value;
    backend.emitPosition(const Duration(seconds: 1));
    expect(controller.toastRevision.value, initialRevision);

    controller.beginSeekPreview();
    controller.updateSeekPreview(const Duration(seconds: 2));
    controller.endSeekPreview();
    expect(controller.toastRevision.value, initialRevision + 3);

    await controller.dispose();
  });

  test(
    'long press drag crosses zero into bounded 5x rewind and restores playback',
    () async {
      final backend = FakePlaybackBackend();
      final controller = PlaybackController(backend: backend);
      await controller.open('https://example.test/video.mp4');
      backend.emitDuration(const Duration(minutes: 2));
      backend.emitPosition(const Duration(minutes: 1));
      await controller.updatePreferences(
        controller.preferences.value.copyWith(longPressSpeed: 2.0),
        persist: false,
      );

      controller.setDoubleSpeed(true);
      await Future<void>.delayed(Duration.zero);
      expect(controller.overlay.value.longPressRate, 2.0);
      expect(backend.lastRate, 2.0);

      controller.updateDoubleSpeedOffset(-64);
      await Future<void>.delayed(Duration.zero);
      expect(controller.overlay.value.longPressRate, 0.0);
      expect(backend.isPlaying, isFalse);

      controller.updateDoubleSpeedOffset(-1000);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(controller.overlay.value.longPressRate, -5.0);
      expect(backend.lastSeek, isNotNull);
      expect(backend.lastSeek!.inMilliseconds, lessThan(60000));
      expect(backend.lastSeek!.inMilliseconds, greaterThanOrEqualTo(59000));

      controller.setDoubleSpeed(false);
      await Future<void>.delayed(Duration.zero);
      expect(controller.overlay.value.doubleSpeed, isFalse);
      expect(backend.lastRate, 1.0);
      expect(backend.isPlaying, isTrue);
      await controller.dispose();
    },
  );

  test('coalesces a burst of long-press rate updates', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    await controller.open('https://example.test/video.mp4');
    await controller.updatePreferences(
      controller.preferences.value.copyWith(longPressSpeed: 2.0),
      persist: false,
    );
    backend
      ..rateSetCount = 0
      ..maxRateSetInFlight = 0
      ..rateSetDelay = const Duration(milliseconds: 20);

    controller.setDoubleSpeed(true);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    for (var step = 1; step <= 30; step++) {
      controller.updateDoubleSpeedOffset(step * 3.2);
    }
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(controller.overlay.value.longPressRate, 5.0);
    expect(backend.lastRate, 5.0);
    expect(backend.rateSetCount, 2);
    expect(backend.maxRateSetInFlight, 1);

    controller.setDoubleSpeed(false);
    await Future<void>.delayed(const Duration(milliseconds: 30));
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

  test(
    'reduces commands, tracks, rate, subtitle and enhancement state',
    () async {
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
        controller.preferences.value.copyWith(
          lastVideoEnhancementMode: VideoEnhancementMode.medium,
        ),
        persist: false,
      );
      expect(backend.nativeProperties['glsl-shaders'], isNull);
      await controller.toggleSubtitle();
      expect(backend.nativeProperties['sub-visibility'], 'no');

      final completion = expectLater(controller.completed, emits(null));
      backend.emitCompleted();
      await completion;
      await controller.dispose();
    },
  );

  test('combines current media details with playback configuration', () async {
    final backend = FakePlaybackBackend()
      ..technicalInfo = const PlaybackTechnicalInfo(
        width: 1920,
        height: 1080,
        framesPerSecond: 23.976,
        videoCodec: 'h264',
        videoOutput: 'libmpv',
        hardwareDecoder: 'd3d11va',
      );
    final controller = PlaybackController(backend: backend);
    await controller.initialize();
    controller.preferences.value = controller.preferences.value.copyWith(
      videoRenderer: 'gpu-next',
      hwdecMode: 'auto-safe',
      videoEnhancementMode: VideoEnhancementMode.medium,
    );
    controller.enhancement.value = const VideoEnhancementState(
      requestedMode: VideoEnhancementMode.medium,
      appliedPipeline: VideoEnhancementPipeline.medium,
    );

    final info = await controller.loadTechnicalInfo();

    expect(info.qualityLabel, '1080p');
    expect(info.resolution, '1920 × 1080');
    expect(info.videoOutput, 'libmpv');
    expect(info.rendererProfile, 'gpu-next');
    expect(info.hardwareDecoder, 'd3d11va');
    expect(info.hardwareDecodeMode, 'auto-safe');
    expect(info.requestedEnhancementMode, VideoEnhancementMode.medium);
    expect(info.appliedEnhancementPipeline, VideoEnhancementPipeline.medium);
    expect(info.outputResolution, isNull);
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

  test(
    'retries an autoplay open error before any media progress, then fails',
    () async {
      final backend = FakePlaybackBackend();
      final controller = PlaybackController(backend: backend);
      await controller.open('https://example.test/video.mp4');

      backend.emitError('Failed to open https://example.test/video.mp4.');
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(backend.openCount, 2);
      expect(controller.core.value.failed, isFalse);

      backend.emitError('Failed to open https://example.test/video.mp4.');
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(controller.core.value.failed, isTrue);
      expect(controller.core.value.errorMessage, contains('Failed to open'));
      await controller.dispose();
    },
  );

  test(
    'keeps transient backend errors non-fatal after playback advances',
    () async {
      final backend = FakePlaybackBackend();
      final controller = PlaybackController(backend: backend);
      await controller.open('https://example.test/video.mp4');
      backend.emitPosition(const Duration(seconds: 2));

      backend.emitError('temporary network read error');
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(backend.openCount, 1);
      expect(controller.core.value.failed, isFalse);
      await controller.dispose();
    },
  );

  test('does not retry a stale error after media is replaced', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    await controller.open('https://example.test/first.mp4');

    backend.emitError('Failed to open first.mp4');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await controller.open('https://example.test/second.mp4');
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(backend.openCount, 2);
    expect(backend.currentMediaUri, 'https://example.test/second.mp4');
    expect(controller.core.value.failed, isFalse);
    await controller.dispose();
  });

  test('dispose cancels backend subscriptions and backend lifetime', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    await controller.initialize();
    await controller.dispose();
    expect(backend.disposed, isTrue);
  });

  test('renderer switch outside Android never touches vo or hwdec', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    await controller.initialize();

    await controller.updatePreferences(
      controller.preferences.value.copyWith(
        videoRenderer: 'mediacodec_embed',
        hwdecMode: 'no',
      ),
      persist: false,
    );

    expect(backend.nativeProperties, isNot(contains('vo')));
    expect(backend.nativeProperties['hwdec'], 'no');
    expect(backend.nativeProperties['scale'], 'bilinear');

    await controller.updatePreferences(
      controller.preferences.value.copyWith(
        videoRenderer: 'gpu',
        hwdecMode: 'auto-safe',
      ),
      persist: false,
    );
    expect(backend.nativeProperties['hwdec'], 'auto-safe');
    await controller.dispose();
  });

  test(
    'TV normalizes hwdec auto to mediacodec-copy on update and reset',
    () async {
      Instances.isTV = true;
      final backend = FakePlaybackBackend();
      final controller = PlaybackController(backend: backend);
      await controller.initialize();

      // TV 未配置时默认即为 mediacodec-copy。
      expect(controller.preferences.value.hwdecMode, 'mediacodec-copy');

      // 显式选择保持原样。
      await controller.updatePreferences(
        controller.preferences.value.copyWith(hwdecMode: 'no'),
      );
      expect(controller.preferences.value.hwdecMode, 'no');
      expect(backend.nativeProperties['hwdec'], 'no');

      // 选择「自动」立即归一化为 mediacodec-copy。
      await controller.updatePreferences(
        controller.preferences.value.copyWith(hwdecMode: 'auto'),
      );
      expect(controller.preferences.value.hwdecMode, 'mediacodec-copy');
      expect(backend.nativeProperties['hwdec'], 'mediacodec-copy');

      // 恢复默认同样落在 mediacodec-copy。
      await controller.resetPreferences();
      expect(controller.preferences.value.hwdecMode, 'mediacodec-copy');

      await controller.dispose();
    },
  );

  test('seek after completion resumes playback', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    await controller.open('file:///tmp/test.mp4');
    backend.emitDuration(const Duration(minutes: 24));
    backend.emitPosition(const Duration(minutes: 24));
    backend.emitPlaying(false);
    backend.emitCompleted();
    await Future<void>.delayed(Duration.zero);
    expect(controller.core.value.playing, isFalse);

    // 播完后拖动进度条：seek 落地并恢复播放（mpv keep-open 播完默认暂停）。
    await controller.seek(const Duration(minutes: 5), fromSlider: true);
    expect(backend.lastSeek, const Duration(minutes: 5));
    expect(backend.isPlaying, isTrue);
    expect(controller.core.value.playing, isTrue);

    // 非 EOF 状态下 seek 不应改变播放状态。
    backend.emitPlaying(false);
    await controller.seek(const Duration(minutes: 10), fromSlider: true);
    expect(backend.lastSeek, const Duration(minutes: 10));
    expect(backend.isPlaying, isFalse);

    await controller.dispose();
  });

  test('middle seek EOF is recovered without advancing the episode', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    var completions = 0;
    final subscription = controller.completed.listen((_) => completions++);
    await controller.open('https://example.com/video.m3u8');
    backend.emitDuration(const Duration(minutes: 24));
    backend.emitPosition(const Duration(minutes: 1));

    await controller.seek(const Duration(minutes: 12), fromSlider: true);
    backend.emitPosition(const Duration(minutes: 24));
    backend.emitCompleted();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(completions, 0);
    expect(backend.seekCount, 2);
    expect(backend.lastSeek, const Duration(minutes: 12));
    expect(backend.nativeProperties['hr-seek-demuxer-offset'], '30');
    expect(backend.playCount, 1);

    await subscription.cancel();
    await controller.dispose();
  });

  test(
    'Android HLS seek reopens a truncated manifest instead of demuxer seek',
    () async {
      final backend = FakePlaybackBackend();
      final session = _FakeHlsSeekSession();
      final controller = PlaybackController(
        backend: backend,
        hlsSeekSessionFactory: (_, _) async => session,
      );
      await controller.open('https://example.com/video.m3u8');
      backend.emitDuration(const Duration(minutes: 24));
      backend.emitPlaying(true);

      await controller.seek(const Duration(minutes: 12), fromSlider: true);

      expect(backend.seekCount, 0);
      expect(backend.openCount, 2);
      expect(session.target, const Duration(minutes: 12));
      expect(backend.currentMediaUri, startsWith('http://127.0.0.1:1234/'));
      expect(backend.nativeProperties['rebase-start-time'], 'yes');
      expect(
        backend.nativeProperties['demuxer-lavf-o'],
        'allowed_extensions=ALL',
      );
      backend.emitPosition(const Duration(seconds: 2));
      backend.emitDuration(const Duration(minutes: 12));
      expect(controller.timeline.value.position, const Duration(minutes: 12));
      expect(controller.timeline.value.duration, const Duration(minutes: 24));

      await controller.dispose();
      expect(session.disposed, isTrue);
    },
  );

  test(
    'HLS seek pauses immediately and pins progress while reopening',
    () async {
      final backend = FakePlaybackBackend();
      final session = _FakeHlsSeekSession();
      final sessionCompleter = Completer<HlsSeekSession?>();
      final controller = PlaybackController(
        backend: backend,
        hlsSeekSessionFactory: (_, _) => sessionCompleter.future,
      );
      await controller.open('https://example.com/video.m3u8');
      backend.emitDuration(const Duration(minutes: 24));
      backend.emitPosition(const Duration(minutes: 3));
      backend.emitPlaying(true);

      final seekFuture = controller.seek(
        const Duration(minutes: 12),
        fromSlider: true,
      );
      await Future<void>.delayed(Duration.zero);

      expect(backend.pauseCount, 1);
      expect(backend.isPlaying, isFalse);
      expect(controller.core.value.loading, isTrue);
      expect(controller.timeline.value.position, const Duration(minutes: 12));
      expect(
        controller.timeline.value.previewPosition,
        const Duration(minutes: 12),
      );

      // Late events from the old source must not move the slider backwards.
      backend.emitPosition(const Duration(minutes: 3, seconds: 1));
      expect(controller.timeline.value.position, const Duration(minutes: 12));

      sessionCompleter.complete(session);
      await seekFuture;

      expect(backend.lastOpenAutoplay, isFalse);
      expect(backend.playCount, 1);
      expect(backend.isPlaying, isTrue);
      expect(controller.core.value.loading, isFalse);

      // The replacement starts at a segment boundary (11:55 here). Keep the
      // requested 12:00 position pinned until media time catches up.
      backend.emitPosition(const Duration(seconds: 2));
      expect(controller.timeline.value.position, const Duration(minutes: 12));
      backend.emitPosition(const Duration(seconds: 6));
      expect(
        controller.timeline.value.position,
        const Duration(minutes: 12, seconds: 1),
      );

      await controller.dispose();
    },
  );

  test('completion near the actual end still advances normally', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    final completion = expectLater(controller.completed, emits(null));
    await controller.open('https://example.com/video.m3u8');
    backend.emitDuration(const Duration(minutes: 24));
    backend.emitPosition(const Duration(minutes: 23, seconds: 58));
    backend.emitCompleted();

    await completion;
    await controller.dispose();
  });

  test('local and opaque network media keep timestamp-based seeking', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    await controller.initialize();

    await controller.open('D:/videos/anime.mkv');
    expect(
      backend.nativeProperties['demuxer-lavf-o'],
      isNot(contains('igndts')),
      reason: '本地文件 seek 依赖索引与 DTS，不能套用网络流的忽略参数',
    );
    expect(
      backend.nativeProperties['demuxer-lavf-o'],
      isNot(contains('ignidx')),
    );
    expect(
      backend.nativeProperties['demuxer-lavf-o'],
      contains('protocol_whitelist'),
    );

    // 远程 HLS 入口可能不带 m3u8 特征，不能依赖 URL 外形决定 seek 参数。
    await controller.open('https://example.com/opaque-signed-playback');
    expect(
      backend.nativeProperties['demuxer-lavf-o'],
      isNot(contains('igndts')),
    );
    expect(
      backend.nativeProperties['demuxer-lavf-o'],
      isNot(contains('ignidx')),
    );
    expect(backend.nativeProperties['demuxer-lavf-o'], isEmpty);

    await controller.dispose();
  });
}
