import 'package:flutter_test/flutter_test.dart';

import 'package:baka/services/matching/media_readiness.dart';

void main() {
  group('MediaReadiness.classify', () {
    test('detects direct media urls', () {
      expect(
        MediaReadiness.classify('https://cdn.example.com/ep1/index.m3u8'),
        MediaTokenKind.directMedia,
      );
      expect(
        MediaReadiness.classify('https://cdn.example.com/a.mp4?token=1'),
        MediaTokenKind.directMedia,
      );
    });

    test('detects torrent links', () {
      expect(
        MediaReadiness.classify('magnet:?xt=urn:btih:abcdef'),
        MediaTokenKind.torrent,
      );
    });

    test('treats episode page urls as needing resolve', () {
      expect(
        MediaReadiness.classify('https://site.example.com/play/12345.html'),
        MediaTokenKind.needsResolve,
      );
      expect(
        MediaReadiness.classify('https://site.example.com/vod/detail/id/9'),
        MediaTokenKind.needsResolve,
      );
      expect(
        MediaReadiness.classify('/bangumi/12/episode/3'),
        MediaTokenKind.needsResolve,
      );
    });

    test('treats opaque episode ids as needing resolve', () {
      expect(
        MediaReadiness.classify('ep-12-line-1'),
        MediaTokenKind.needsResolve,
      );
    });
  });

  group('MediaReadiness.isAcceptablePlaybackUrl', () {
    test('accepts playable media and rejects html pages', () {
      expect(
        MediaReadiness.isAcceptablePlaybackUrl(
          'https://cdn.example.com/hls/index.m3u8',
        ),
        isTrue,
      );
      expect(
        MediaReadiness.isAcceptablePlaybackUrl(
          'https://site.example.com/play/1.html',
        ),
        isFalse,
      );
      expect(MediaReadiness.isAcceptablePlaybackUrl(''), isFalse);
    });
  });
}
