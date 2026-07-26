import 'package:baka/widgets/baka_player/mpv_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('embedded renderer profiles never replace media_kit vo', () {
    for (final renderer in <String>['auto', 'compatibility', 'quality']) {
      final properties = buildPlayerProperties(videoRenderer: renderer);
      expect(properties, isNot(contains('vo')), reason: renderer);
    }
  });

  test('quality mode changes only libmpv rendering properties', () {
    final properties = buildVideoRendererProperties('quality');

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
}
