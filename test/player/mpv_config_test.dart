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

  test('gpu-next changes only libmpv rendering properties', () {
    final properties = buildVideoRendererProperties('gpu-next');

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

  test('mediacodec_embed pins hwdec but never sets vo on initial load', () {
    final properties = buildPlayerProperties(
      videoRenderer: 'mediacodec_embed',
      android: true,
    );

    expect(properties['hwdec'], 'mediacodec');
    expect(properties, isNot(contains('vo')));
    expect(properties, isNot(contains('vid')));
  });

  test('effectiveHwdec forces mediacodec only for direct renderer on Android',
      () {
    expect(
      effectiveHwdec('auto-safe', 'mediacodec_embed', android: true),
      'mediacodec',
    );
    expect(effectiveHwdec('no', 'mediacodec_embed', android: true), 'mediacodec');
    expect(effectiveHwdec('no', 'mediacodec_embed', android: false), 'no');
    expect(effectiveHwdec('no', 'gpu-next', android: true), 'no');
    expect(effectiveHwdec('auto', 'gpu', android: true), 'auto');
  });

  test('switching to mediacodec_embed applies hwdec, vo, vid in order', () {
    final properties = buildRendererSwitchProperties(
      renderer: 'mediacodec_embed',
      hwdecMode: 'auto-safe',
      android: true,
    );

    expect(properties.keys.take(3).toList(), ['hwdec', 'vo', 'vid']);
    expect(properties['hwdec'], 'mediacodec');
    expect(properties['vo'], 'mediacodec_embed');
    expect(properties['vid'], 'auto');
  });

  test('switching to gpu-next applies vo and high quality scaling', () {
    final properties = buildRendererSwitchProperties(
      renderer: 'gpu-next',
      hwdecMode: 'no',
      android: true,
    );

    expect(properties['hwdec'], 'no');
    expect(properties['vo'], 'gpu-next');
    expect(properties, isNot(contains('vid')));
    expect(properties['scale'], 'ewa_lanczossharp');
  });

  test('switching to gpu keeps the user hwdec and vo=gpu', () {
    final properties = buildRendererSwitchProperties(
      renderer: 'gpu',
      hwdecMode: 'auto-safe',
      android: true,
    );

    expect(properties['hwdec'], 'auto-safe');
    expect(properties['vo'], 'gpu');
    expect(properties, isNot(contains('vid')));
  });

  test('renderer switches never touch vo or hwdec outside Android', () {
    for (final renderer in <String>['gpu', 'gpu-next', 'mediacodec_embed']) {
      final properties = buildRendererSwitchProperties(
        renderer: renderer,
        hwdecMode: 'auto',
        android: false,
      );
      expect(properties, isNot(contains('vo')), reason: renderer);
      expect(properties, isNot(contains('hwdec')), reason: renderer);
    }
  });
}
