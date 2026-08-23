import 'package:baka/pages/anime_detail/anime_detail_page.dart';
import 'package:baka/widgets/anime_detail/anime_detail_placeholder.dart';
import 'package:baka/widgets/platform/tv/tv_anime_detail.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('detail route builds a detail-only surface for each form factor', () {
    final data = <String, dynamic>{'id': 1, 'title': 'Test'};

    expect(
      buildAnimeDetailSurface(data, isTv: false),
      isA<AnimeDetailPlaceholder>(),
    );
    expect(
      buildAnimeDetailSurface(data, isTv: true),
      isA<TvAnimeDetailPlaceholder>(),
    );
  });
}
