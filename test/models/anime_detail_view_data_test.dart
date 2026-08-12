import 'package:baka/models/anime_detail_view_data.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps the existing cover when richer detail data arrives', () {
    final detail = AnimeDetailViewData.from(
      source: const <String, dynamic>{'title': 'Example'},
      bgmInfo: const BgmInfo(imageUrl: 'https://example.test/bgm-cover.jpg'),
      anibaka: const <String, dynamic>{
        'images': {
          'posters': [
            {'url': 'https://example.test/poster.jpg'},
          ],
          'backdrops': [
            {'url': 'https://example.test/backdrop.jpg'},
            {'url': 'https://example.test/backdrop.jpg'},
            {'url': ''},
          ],
        },
      },
    );

    expect(detail.coverUrl, 'https://example.test/bgm-cover.jpg');
    expect(detail.backgroundUrl, 'https://example.test/backdrop.jpg');
    expect(detail.backdrops, hasLength(1));
  });

  test('uses the detail poster when the existing item has no cover', () {
    final detail = AnimeDetailViewData.from(
      source: const <String, dynamic>{'title': 'Example'},
      bgmInfo: const BgmInfo(),
      anibaka: const <String, dynamic>{
        'images': {
          'posters': [
            {'url': 'https://example.test/poster.jpg'},
          ],
        },
      },
    );

    expect(detail.coverUrl, 'https://example.test/poster.jpg');
  });

  test('falls back to the cover when the API has no backdrop', () {
    final detail = AnimeDetailViewData.from(
      source: const <String, dynamic>{'title': 'Example'},
      bgmInfo: const BgmInfo(imageUrl: 'https://example.test/cover.jpg'),
    );

    expect(detail.coverUrl, 'https://example.test/cover.jpg');
    expect(detail.backgroundUrl, detail.coverUrl);
  });

  test('parses bangumi 1-10 score distribution for the desktop chart', () {
    final detail = AnimeDetailViewData.from(
      source: const <String, dynamic>{'title': 'Example'},
      bgmInfo: const BgmInfo(score: 8.2),
      bgm: const <String, dynamic>{
        'rating': {
          'score': 8.2,
          'total': 100,
          'rank': 42,
          'count': {
            '1': 1,
            '2': 0,
            '3': 2,
            '4': 3,
            '5': 5,
            '6': 10,
            '7': 20,
            '8': 30,
            '9': 20,
            '10': 9,
          },
        },
      },
    );

    expect(detail.score, 8.2);
    expect(detail.rank, 42);
    expect(detail.hasScoreDistribution, isTrue);
    expect(detail.scoreDistribution, [1, 0, 2, 3, 5, 10, 20, 30, 20, 9]);
  });

  test('shares characters and keeps only image URLs in the view snapshot', () {
    final characters = <Map<String, dynamic>>[
      {'id': 1, 'name': '角色'},
    ];
    final detail = AnimeDetailViewData.from(
      source: const <String, dynamic>{'title': 'Example'},
      bgmInfo: const BgmInfo(),
      characters: characters,
      anibaka: const <String, dynamic>{
        'images': {
          'posters': [
            {
              'url': 'https://example.test/poster.jpg',
              'lang': 'zh',
              'source': 'tmdb',
            },
          ],
        },
      },
    );

    expect(identical(detail.characters, characters), isTrue);
    expect(detail.posters, ['https://example.test/poster.jpg']);
  });

  test('selects the localized logo used by the player', () {
    final logo = AnimeDetailViewData.resolveLogoUrl(const <String, dynamic>{
      'images': {
        'logos': [
          {'url': 'https://example.test/en-logo.png', 'lang': 'en'},
          {'url': 'https://example.test/zh-logo.png', 'lang': 'zh'},
        ],
      },
    });

    expect(logo, 'https://example.test/zh-logo.png');
  });
}
