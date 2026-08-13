import 'package:test/test.dart';

import 'package:baka/source/video_url_extractor.dart';

void main() {
  test('recognizes E站 listres endpoint as disguised HLS', () {
    const url =
        'https://player.ezdmw.com/index/listres/resource_name/demo/'
        'key/demo/sign/abc.webp?lineOne=true';

    expect(VideoUrlExtractor.isVideoUrl(url), isTrue);
    expect(VideoUrlExtractor.isPlayable(url), isTrue);
  });

  test('recognizes query-marked playlist endpoint as disguised HLS', () {
    const url =
        'https://api.example.com/functions/v1/issue-hls-playback'
        '?mode=playlist&resource=episode-1';

    expect(VideoUrlExtractor.isHlsUrl(url), isTrue);
    expect(VideoUrlExtractor.isVideoUrl(url), isTrue);
    expect(VideoUrlExtractor.isPlayable(url), isTrue);
  });

  test('keeps a signed media endpoint instead of unwrapping its path', () {
    const url =
        'https://api.example.com/functions/v1/issue-hls-playback'
        '?mode=playlist&aud=web&path=episodes%2F360%2F5411%2Fmaster.m3u8'
        '&pt=opaque-token';

    expect(
      VideoUrlExtractor.normalizeResolvedUrl(
        url,
        'https://api.example.com/functions/v1/issue-web-playback',
      ),
      url,
    );
  });

  test('31dm signed MP4 keeps encoded path and signature bytes', () {
    const url =
        'https://r2.31dm.com/2024%2F%E7%95%AA%E5%89%A7%2F%E7%AC%AC01%E9%9B%86.mp4'
        '?verify=1784300231-abc%2Bdef%2Fghi%3D';

    expect(VideoUrlExtractor.isSignedCdnUrl(url), isTrue);
    expect(
      VideoUrlExtractor.normalizeResolvedUrl(
        url,
        'https://www.2kdm.com/vodplay/2513-1-1.html',
      ),
      url,
    );
  });

  test('expiring sign parameter is treated as a signed CDN URL', () {
    const url =
        'https://signed.example/video/episode-01.mp4'
        '?sign=xhbzK4c0ulTC0VIrc70DFxB5AghRrwM6Hdp7XI8lEKA=:1784510743';

    expect(VideoUrlExtractor.isSignedCdnUrl(url), isTrue);
    expect(
      VideoUrlExtractor.normalizeResolvedUrl(
        url,
        'https://anime.example/play/1-1.html',
      ),
      url,
    );
  });
}
