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
        'https://al.huazidm02.top/d/tycc/tv/2022/10/孤独摇滚/01.mp4'
        '?sign=xhbzK4c0ulTC0VIrc70DFxB5AghRrwM6Hdp7XI8lEKA=:1784510743';

    expect(VideoUrlExtractor.isSignedCdnUrl(url), isTrue);
    expect(
      VideoUrlExtractor.normalizeResolvedUrl(
        url,
        'https://www.huazidm.com/play/1-1.html',
      ),
      url,
    );
  });

  test('Cycani verify-signed MP4 is treated as a signed CDN URL', () {
    const url =
        'https://r2n2kf6ygw.cycmedia.net:8080/cache/'
        'VEhFIFdPUkxEIElTIERBTkNJTkcg5LiW55WM5Zyo6LW36IieMDF6bS5tcDQ=.mp4'
        '?verify=1785679788-mvrwhrqUe+2Wsg90sCSsfZ/VbzfLfW98BcU8eTbikmI=';

    expect(VideoUrlExtractor.isSignedCdnUrl(url), isTrue);
    expect(
      VideoUrlExtractor.normalizeResolvedUrl(
        url,
        'https://www.cycani.org/bangumi/1.html',
      ),
      url,
    );
  });

  test('Cycani verify-signed MP4 with %2F %2B %3D is recognized as signed CDN URL', () {
    const url =
        'https://kthykjrlaz.cycmedia.net:8080/cache/5bm85aWz5oiY6K6wIOesrOS6jOWtozAxem0ubXA0.mp4'
        '?verify=1785926861-MMK7CCrDRGp7wu8giCs71Xhh%2FTi9%2BnZZevJ5Gb2scgQ%3D';

    expect(VideoUrlExtractor.isSignedCdnUrl(url), isTrue);
    expect(
      VideoUrlExtractor.normalizeResolvedUrl(
        url,
        'https://www.cycani.org/bangumi/1.html',
      ),
      url,
    );
  });
}
