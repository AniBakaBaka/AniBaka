import 'package:test/test.dart';

import 'package:baka/source/engine/torrent_records.dart';

Map<String, dynamic> _dmhyParams(String mode) => {
  'mode': mode,
  'rowSelector': '#topic_list tbody tr',
  'titleSelector': 'td.title a[target="_blank"]',
  'titleAttr': 'text',
  'idSelector': 'a[href^="magnet:"]',
  'idAttr': 'href',
  'sourceNameSelector': 'td.title span.tag a',
  'sourceNameAttr': 'text',
  'sizeSelector': 'td:nth-child(5)',
  'sizeAttr': 'text',
  'fansubPattern': {'pattern': r'^[\[【]([^\]】]+)[\]】]', 'group': 1},
  'episodePatterns': [
    {
      'pattern': r'[-–—]\s*(\d+(?:\.\d+)?)\s*(?:v\d+)?\s*(?:END|FIN|FINAL)?',
      'group': 1,
    },
    {'pattern': r'第\s*(\d+(?:\.\d+)?)[話话集]', 'group': 1},
    {'pattern': r'EP\.?\s*(\d+(?:\.\d+)?)', 'group': 1},
    {'pattern': r'S\d+E(\d+(?:\.\d+)?)', 'group': 1},
  ],
  'titleStripPatterns': [r'[\[【][^\]】]*[\]】]', r'[\(（][^\)）]*[\)）]'],
  'animeCleanupPatterns': [r'[-–—：:]\s*$', r'^\s*[-–—：:]'],
  'animeNameSeparators': [' / '],
  if (mode == 'series') ...{
    'seriesIdTemplate': '{baseUrl:raw}/topics/list?keyword={animeName}',
    'descriptionTemplate': '{count:raw}个资源 · {fansubs:raw}',
  } else ...{
    'expectedAnimeNameQuery': 'keyword',
    'unknownSourceName': '未知字幕组',
    'episodeIndexMode': 'sequence',
    'episodeNameTemplate': '第{episode:raw}话{sizeSuffix:raw}',
  },
};

final Map<String, dynamic> _mikanParams = {
  'mode': 'episodes',
  'sourceContainerSelector': '.episode-table',
  'sourceLabelSelector': '.subgroup-text > a:first-child',
  'sourceLabelAttr': 'text',
  'rowSelector': 'tbody tr',
  'titleSelector': '.magnet-link-wrap',
  'titleAttr': 'text',
  'idSelectors': [
    'input[data-magnet]',
    'a[data-clipboard-text^="magnet:"]',
    'a[href^="magnet:"]',
    'a[href*=".torrent"]',
  ],
  'idAttrs': ['data-magnet', 'data-clipboard-text', 'href'],
  'exactSourceSelector': 'a[href*=".torrent"]',
  'exactSourceAttr': 'href',
  'sizeSelector': 'td:nth-child(3)',
  'sizeAttr': 'text',
  'episodePatterns': [
    {'pattern': r'S\d+E(\d+(?:\.\d+)?)', 'group': 1},
    {'pattern': r'\[(\d{1,3}(?:\.\d+)?)\](?!\s*[x×]\s*\d)', 'group': 1},
    {'pattern': r'[-–—]\s*(\d+(?:\.\d+)?)\s*(?:v\d+)?', 'group': 1},
    {'pattern': r'第\s*(\d+(?:\.\d+)?)[話话集]', 'group': 1},
    {'pattern': r'EP\.?\s*(\d+(?:\.\d+)?)', 'group': 1},
  ],
  'excludePatterns': [
    r'\b(?:batch|complete)\b',
    '合集|全集|一括',
    r'(?:^|[\[\(\s-])\d{1,3}\s*(?:-|~|～|至)\s*'
        r'\d{1,3}(?:[話话集\]\)\s]|$)',
  ],
  'requireEpisodeNumber': true,
  'episodeIndexMode': 'number',
  'dedupeByEpisode': true,
  'episodeNameTemplate': '{title:raw}',
  'unknownSourceName': '未知字幕组',
  'sourceNameBonus': 1,
  'scoreRules': [
    {'pattern': '1080', 'score': 40},
    {'pattern': '2160|4k', 'score': 35},
    {'pattern': '720', 'score': 20},
    {'pattern': 'chs|简', 'score': 12},
    {'pattern': r'\bgb\b', 'score': 6},
    {'pattern': 'cht|繁', 'score': 4},
    {'pattern': 'mp4', 'score': 5},
    {'pattern': 'mkv', 'score': 3},
    {'pattern': r'hevc|h\.?265', 'score': 2},
  ],
};

void main() {
  group('DMHY catalogue records', () {
    final seriesParams = _dmhyParams('series');
    final episodeParams = _dmhyParams('episodes');
    const html = '''
<table id="topic_list"><tbody>
  <tr>
    <td>2026-01-02</td><td>动画</td>
    <td class="title"><a target="_blank" href="/topics/view/2">[GroupA] My Anime / English - 02 [1080p]</a></td>
    <td><a href="magnet:?xt=urn:btih:2222222222222222222222222222222222222222&amp;tr=udp%3A%2F%2Ftracker.example"></a></td>
    <td>800 MB</td>
  </tr>
  <tr>
    <td>2026-01-01</td><td>动画</td>
    <td class="title"><a target="_blank" href="/topics/view/1">[GroupA] My Anime / English - 01 [720p]</a></td>
    <td><a href="magnet:?xt=urn:btih:1111111111111111111111111111111111111111"></a></td>
    <td>700 MB</td>
  </tr>
  <tr>
    <td>2026-01-01</td><td>动画</td>
    <td class="title"><a target="_blank" href="/topics/view/3">[GroupB] My Anime / English - 01 [1080p]</a></td>
    <td><a href="magnet:?xt=urn:btih:3333333333333333333333333333333333333333"></a></td>
    <td>900 MB</td>
  </tr>
  <tr>
    <td>2026-01-01</td><td>动画</td>
    <td class="title"><a target="_blank" href="/topics/view/4">[GroupC] Other Anime - 01 [1080p]</a></td>
    <td><a href="magnet:?xt=urn:btih:4444444444444444444444444444444444444444"></a></td>
    <td>1 GB</td>
  </tr>
</tbody></table>
''';

    test('groups search rows by parsed anime name', () {
      final series = TorrentRecordParser.parseSeries(
        html: html,
        params: seriesParams,
        baseUrl: 'https://share.dmhy.org',
      );

      expect(series, hasLength(2));
      final mine = series.singleWhere((item) => item.name == 'My Anime');
      expect(Uri.parse(mine.seriesId).queryParameters['keyword'], 'My Anime');
      expect(mine.description, contains('3个资源'));
      expect(mine.description, contains('GroupA'));
      expect(mine.description, contains('GroupB'));
    });

    test('filters expected anime, groups fansubs, and sorts episodes', () {
      final sources = TorrentRecordParser.parseSources(
        html: html,
        params: episodeParams,
        baseUrl: 'https://share.dmhy.org',
        contextUrl: 'https://share.dmhy.org/topics/list?keyword=My%20Anime',
      );

      expect(sources, hasLength(2));
      final groupA = sources.singleWhere(
        (source) => source.sourceName == 'GroupA',
      );
      expect(groupA.episodes, hasLength(2));
      expect(groupA.episodes[0].episode, 0);
      expect(groupA.episodes[0].name, '第1话 [700 MB]');
      expect(groupA.episodes[1].episode, 1);
      expect(groupA.episodes[1].name, '第2话 [800 MB]');
      expect(groupA.episodes[0].episodeId, startsWith('magnet:?xt='));
      expect(groupA.episodes[0].episodeId, isNot(contains('Other Anime')));
    });
  });

  group('Mikan release tables', () {
    final params = _mikanParams;
    const html = '''
<div class="subgroup-text"><a>Fansub A</a></div>
<div class="episode-table"><table><tbody>
  <tr><td><input></td><td><a class="magnet-link-wrap">Anime Season 1</a></td><td>20 GB</td><td><a href="/Download/batch.torrent"></a></td></tr>
  <tr><td><input></td><td><a class="magnet-link-wrap">Anime - 18-21 [1080p]</a></td><td>4 GB</td><td><a href="/Download/range.torrent"></a></td></tr>
  <tr><td><input></td><td><a class="magnet-link-wrap">Anime - 01 [720p][CHT][MP4]</a></td><td>300 MB</td><td><a href="/Download/low.torrent"></a></td></tr>
  <tr><td><input data-magnet="magnet:?xt=urn:btih:5555555555555555555555555555555555555555"></td><td><a class="magnet-link-wrap">Anime - 01 [1080p][CHS][HEVC][MKV]</a></td><td>500 MB</td><td><a href="/Download/high.torrent"></a></td></tr>
  <tr><td><input></td><td><a class="magnet-link-wrap">Anime EP02 [1080p][CHS][MP4]</a></td><td>480 MB</td><td><a href="/Download/ep2.torrent"></a></td></tr>
</tbody></table></div>
<div class="subgroup-text"><a>Fansub B</a></div>
<div class="episode-table"><table><tbody>
  <tr><td><input data-magnet="magnet:?xt=urn:btih:3333333333333333333333333333333333333333"></td><td><a class="magnet-link-wrap">Anime [03] [1080p]</a></td><td>600 MB</td><td></td></tr>
</tbody></table></div>
''';

    test(
      'filters batches and ranges, then keeps the best release per episode',
      () {
        final sources = TorrentRecordParser.parseSources(
          html: html,
          params: params,
          baseUrl: 'https://mikanani.me',
        );

        expect(sources, hasLength(2));
        final first = sources[0];
        expect(first.sourceName, 'Fansub A');
        expect(first.episodes.map((episode) => episode.episode), <int>[0, 1]);
        expect(
          first.episodes[0].episodeId,
          startsWith(
            'magnet:?xt=urn:btih:5555555555555555555555555555555555555555',
          ),
        );
        expect(
          Uri.parse(first.episodes[0].episodeId).queryParameters['xs'],
          'https://mikanani.me/Download/high.torrent',
        );
        expect(first.episodes[0].name, contains('[1080p][CHS]'));
        expect(
          first.episodes.map((episode) => episode.episodeId),
          isNot(contains('https://mikanani.me/Download/batch.torrent')),
        );
        expect(
          first.episodes.map((episode) => episode.episodeId),
          isNot(contains('https://mikanani.me/Download/range.torrent')),
        );

        final second = sources[1];
        expect(second.sourceName, 'Fansub B');
        expect(second.episodes.single.episode, 2);
        expect(second.episodes.single.episodeId, startsWith('magnet:?xt='));
      },
    );
  });
}
