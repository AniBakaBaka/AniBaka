import 'package:baka/utils/bgm_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'builds a cached BGM cover URL without exposing the blocked image host',
    () {
      final url = Uri.parse(BgmUtils.bgmCoverProxyUrl(400602));

      expect(url.host, 'wsrv.nl');
      expect(url.queryParameters['w'], '360');
      expect(url.queryParameters['output'], 'webp');
      expect(
        url.queryParameters['url'],
        'https://api.bgm.tv/v0/subjects/400602/image?type=large',
      );
    },
  );

  group('pickAniBakaTmdbPoster', () {
    test('prefers the Chinese TMDB poster over BGM and other languages', () {
      final detail = <String, dynamic>{
        'images': {
          'posters': [
            {
              'source': 'bgm',
              'lang': 'zh',
              'url': 'https://example.test/bgm.jpg',
            },
            {
              'source': 'tmdb',
              'lang': 'ja',
              'url': 'https://example.test/tmdb-ja.jpg',
            },
            {
              'source': 'tmdb',
              'lang': 'zh',
              'url': 'https://example.test/tmdb-zh.jpg',
            },
          ],
        },
      };

      expect(
        BgmUtils.pickAniBakaTmdbPoster(detail),
        'https://example.test/tmdb-zh.jpg',
      );
    });

    test('uses another TMDB poster when no Chinese variant exists', () {
      final detail = <String, dynamic>{
        'images': {
          'posters': [
            {
              'source': 'tmdb',
              'lang': 'ja',
              'thumbnail': 'https://example.test/tmdb-ja-thumb.jpg',
            },
          ],
        },
      };

      expect(
        BgmUtils.pickAniBakaTmdbPoster(detail),
        'https://example.test/tmdb-ja-thumb.jpg',
      );
    });

    test('does not treat a BGM poster as a TMDB poster', () {
      final detail = <String, dynamic>{
        'images': {
          'posters': [
            {'source': 'bgm', 'url': 'https://example.test/bgm.jpg'},
          ],
        },
      };

      expect(BgmUtils.pickAniBakaTmdbPoster(detail), isNull);
    });
  });

  test('picks the TMDB backdrop independently from posters', () {
    final detail = <String, dynamic>{
      'images': {
        'posters': [
          {'source': 'tmdb', 'url': 'https://example.test/poster.jpg'},
        ],
        'backdrops': [
          {'source': 'bgm', 'url': 'https://example.test/bgm-backdrop.jpg'},
          {'source': 'tmdb', 'url': 'https://example.test/tmdb-backdrop.jpg'},
        ],
      },
    };

    expect(
      BgmUtils.pickAniBakaTmdbBackdrop(detail),
      'https://example.test/tmdb-backdrop.jpg',
    );
  });
}
