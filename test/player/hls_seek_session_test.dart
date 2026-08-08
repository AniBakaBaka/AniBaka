import 'package:baka/widgets/baka_player/hls_seek_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('absolutizes HLS media and URI attributes', () {
    const manifest = '''
#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:10,
segment.m4s
#EXT-X-ENDLIST
''';

    final result = LoopbackHlsSeekSession.absolutizeManifest(
      manifest,
      Uri.parse('https://cdn.example.test/path/index.m3u8'),
    );

    expect(result, contains('URI="https://cdn.example.test/path/init.mp4"'));
    expect(result, contains('https://cdn.example.test/path/segment.m4s'));
  });

  test('truncated manifest removes all media before the target segment', () {
    const manifest = '''
#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MEDIA-SEQUENCE:7
#EXTINF:10,
https://cdn.example.test/0.m4s
#EXTINF:11,
https://cdn.example.test/1.m4s
#EXTINF:12,
https://cdn.example.test/2.m4s
#EXT-X-ENDLIST
''';

    final result = LoopbackHlsSeekSession.buildTruncatedManifest(manifest, 1);

    expect(result, contains('#EXT-X-PLAYLIST-TYPE:VOD'));
    expect(result, contains('#EXT-X-MEDIA-SEQUENCE:8'));
    expect(result, contains('#EXT-X-ENDLIST'));
    expect(result, isNot(contains('https://cdn.example.test/0.m4s')));
    expect(result, contains('https://cdn.example.test/1.m4s'));
    expect(result, contains('https://cdn.example.test/2.m4s'));
  });

  test('calculates original timeline offsets from EXTINF durations', () {
    const manifest = '''
#EXTM3U
#EXTINF:10.575125,
0.m4s
#EXTINF:10.427083,
1.m4s
#EXTINF:9.5,
2.m4s
''';

    expect(LoopbackHlsSeekSession.segmentStarts(manifest), <Duration>[
      Duration.zero,
      const Duration(microseconds: 10575125),
      const Duration(microseconds: 21002208),
    ]);
  });
}
