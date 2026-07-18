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
}
