import 'package:test/test.dart';

import 'package:baka/source/video_url_extractor.dart';

void main() {
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
