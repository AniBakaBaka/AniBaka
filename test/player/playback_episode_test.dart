import 'package:baka/models/playback_episode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a legacy episode once and selects one-based lines', () {
    final episode = PlaybackEpisode.parse('第1话\$line-a\$line-b')!;
    expect(episode.title, '第1话');
    expect(episode.lineCount, 2);
    expect(episode.lineAt(1), 'line-a');
    expect(episode.lineAt(2), 'line-b');
    expect(episode.lineAt(0), isNull);
    expect(episode.serialize(), '第1话\$line-a\$line-b');
  });

  test('merges duplicate legacy titles while preserving line order', () {
    final episodes = PlaybackEpisodeCatalog.parse([
      '01. 正片\$a',
      '02. 下一话\$b',
      '1 正片\$c',
    ], mergeDuplicateTitles: true);
    expect(episodes, hasLength(2));
    expect(episodes.first.title, '01. 正片');
    expect(episodes.first.lines, ['a', 'c']);
  });

  test('filters typed episodes without reparsing serialized strings', () {
    final episodes = PlaybackEpisodeCatalog.parse([
      '第一话\$a',
      '第二话\$b',
      '特别篇\$c',
    ]);
    expect(
      PlaybackEpisodeCatalog.filterIndexes(
        episodes,
        ascending: true,
        searchQuery: '二',
      ),
      [1],
    );
    expect(PlaybackEpisodeCatalog.filterIndexes(episodes, ascending: false), [
      2,
      1,
      0,
    ]);
  });
}
