import 'package:test/test.dart';

import 'package:baka/services/matching/source_match_engine.dart';

void main() {
  const engine = SourceMatchEngine();

  SourceMatchCandidate candidate(
    String key,
    String title, {
    required String source,
    required int episodes,
  }) {
    return SourceMatchCandidate(
      key: key,
      title: title,
      sourceType: source,
      data: {'title': title, 'episodeCount': episodes},
    );
  }

  test('prefers the matching season with the expected episode count', () {
    final context = SourceMatchContext(
      primaryTitle: 'Example 第二季',
      bgmEpisodeCount: 24,
      bgmCompleted: true,
      querySeason: 2,
    );

    final ranked = engine.rank([
      candidate('a', 'Example', source: 'source_a', episodes: 12),
      candidate('b', 'Example 第二季', source: 'source_b', episodes: 24),
    ], context);

    expect(ranked.first.candidate.key, 'b');
    expect(ranked.first.confidence, greaterThanOrEqualTo(0.8));
    expect(ranked.last.seasonConflict, isFalse);
    expect(ranked.first.score, greaterThan(ranked.last.score));
  });

  test('penalizes movie candidates when BGM expects a TV season', () {
    final context = SourceMatchContext(
      primaryTitle: 'Example',
      bgmEpisodeCount: 12,
      bgmCompleted: true,
    );

    final ranked = engine.rank([
      candidate('movie', 'Example 剧场版', source: 'source_a', episodes: 1),
      candidate('tv', 'Example TV', source: 'source_b', episodes: 12),
    ], context);

    expect(ranked.first.candidate.key, 'tv');
    expect(
      ranked.first.score,
      greaterThan(ranked.firstWhere((s) => s.candidate.key == 'movie').score),
    );
  });

  test('penalizes package resources that greatly exceed BGM episode count', () {
    final context = SourceMatchContext(
      primaryTitle: 'Example',
      bgmEpisodeCount: 12,
      bgmCompleted: true,
    );

    final ranked = engine.rank([
      candidate('pack', 'Example 合集', source: 'source_a', episodes: 48),
      candidate('single', 'Example', source: 'source_b', episodes: 12),
    ], context);

    final pack = ranked.firstWhere((s) => s.candidate.key == 'pack');
    expect(ranked.first.candidate.key, 'single');
    expect(pack.severeEpisodeConflict, isTrue);
    expect(pack.confidence, lessThan(0.8));
  });

  test('counts video rows without allocating split substrings', () {
    final item = SourceMatchCandidate(
      key: 'videos',
      title: 'Example',
      sourceType: 'source',
      data: const {'videos': '  \r\n第1集\$ep-1\r\n\t\n第2集\$ep-2\n第3集\$ep-3'},
    );

    expect(item.episodeCount, 3);
  });
}
