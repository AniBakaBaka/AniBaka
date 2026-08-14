import 'package:baka/widgets/baka_player/mpv_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('embedded renderer profiles never replace media_kit vo', () {
    for (final renderer in <String>['gpu', 'gpu-next', 'mediacodec_embed']) {
      final properties = buildPlayerProperties(
        videoRenderer: renderer,
        android: true,
      );
      expect(properties, isNot(contains('vo')), reason: renderer);
    }
  });

  test('gpu-next changes only libmpv rendering properties on desktop', () {
    final properties = buildVideoRendererProperties('gpu-next', android: false);

    expect(properties['scale'], 'ewa_lanczossharp');
    expect(properties['correct-downscaling'], 'yes');
    expect(properties, isNot(contains('vo')));
  });

  test('low memory mode reduces the bounded demuxer cache', () {
    final normal = buildPlayerProperties();
    final lowMemory = buildPlayerProperties(lowMemoryMode: true);

    expect(normal['demuxer-max-bytes'], '16777216');
    expect(normal['demuxer-max-back-bytes'], '4194304');
    expect(lowMemory['demuxer-max-bytes'], '8388608');
    expect(lowMemory['demuxer-max-back-bytes'], '2097152');
    expect(lowMemory['cache-secs'], '5');
  });

  test('network streams use reconnect and timestamp recovery options', () {
    final properties = buildPlayerProperties(
      mediaUri: 'https://example.com/stream.m3u8',
    );
    final options = properties['demuxer-lavf-o']!;

    expect(options, contains('reconnect=1'));
    expect(options, contains('igndts'));
    expect(options, contains('ignidx'));
    expect(properties, isNot(contains('rebase-start-time')));
    expect(properties, isNot(contains('hr-seek')));
    expect(properties, isNot(contains('hr-seek-demuxer-offset')));
  });

  test('Android gpu profile pins rgba8 and disables heavy GPU features', () {
    final properties = buildPlayerProperties(
      videoRenderer: 'gpu',
      android: true,
    );

    expect(properties['gpu-context'], 'android');
    expect(properties['profile'], 'fast');
    expect(properties['fbo-format'], 'rgba8');
    expect(properties['deband'], 'no');
    expect(properties['interpolation'], 'no');
    expect(properties['scale'], 'bilinear');
    expect(properties['cscale'], 'bilinear');
    expect(properties['dscale'], 'bilinear');
    expect(properties['correct-downscaling'], 'no');
    expect(properties, isNot(contains('vo')));
  });

  test('Android falls gpu-next back to the conservative gpu profile', () {
    final properties = buildPlayerProperties(
      videoRenderer: 'gpu-next',
      android: true,
    );

    expect(properties['fbo-format'], 'rgba8');
    expect(properties['scale'], 'bilinear');
    expect(properties, isNot(contains('vo')));
  });

  test('mediacodec_embed pins hwdec but never sets vo on initial load', () {
    final properties = buildPlayerProperties(
      videoRenderer: 'mediacodec_embed',
      android: true,
    );

    expect(properties['hwdec'], 'mediacodec');
    expect(properties, isNot(contains('vo')));
    expect(properties, isNot(contains('vid')));
  });

  test(
    'effectiveHwdec forces mediacodec only for direct renderer on Android',
    () {
      expect(
        effectiveHwdec('auto-safe', 'mediacodec_embed', android: true),
        'mediacodec',
      );
      expect(
        effectiveHwdec('no', 'mediacodec_embed', android: true),
        'mediacodec',
      );
      expect(effectiveHwdec('no', 'mediacodec_embed', android: false), 'no');
      expect(effectiveHwdec('no', 'gpu-next', android: true), 'no');
      expect(effectiveHwdec('auto', 'gpu', android: true), 'auto-safe');
      expect(effectiveHwdec('auto', 'gpu', android: false), 'auto');
      expect(
        effectiveHwdec('mediacodec-copy', 'gpu', android: true),
        'mediacodec-copy',
      );
    },
  );

  test('codec open failures are fatal even when audio is still playing', () {
    expect(isFatalPlaybackError('Could not open codec.'), isTrue);
    expect(isFatalPlaybackError('Failed to open codec: h264'), isTrue);
    expect(isFatalPlaybackError('temporary network read error'), isFalse);
  });

  test('Android never hot-swaps vo or hwdec on the running player', () {
    for (final renderer in <String>['gpu', 'gpu-next', 'mediacodec_embed']) {
      final properties = buildRendererSwitchProperties(
        renderer: renderer,
        hwdecMode: 'no',
        android: true,
      );
      expect(properties, isEmpty, reason: renderer);
    }
  });

  test('renderer switches outside Android only apply scaling properties', () {
    final properties = buildRendererSwitchProperties(
      renderer: 'gpu',
      hwdecMode: 'auto-safe',
      android: false,
    );

    expect(properties, isNot(contains('vo')));
    expect(properties, isNot(contains('hwdec')));
    expect(properties['scale'], 'bilinear');

    final highQuality = buildRendererSwitchProperties(
      renderer: 'gpu-next',
      hwdecMode: 'auto',
      android: false,
    );
    expect(highQuality['scale'], 'ewa_lanczossharp');
    expect(highQuality, isNot(contains('vo')));
    expect(highQuality, isNot(contains('hwdec')));
  });
}
