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
}
