import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:baka/source/engine/pipeline_host.dart';
import 'package:baka/source/engine/pipeline_interpreter.dart';
import 'package:baka/source/model/source_rule.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:baka/source/video_url_extractor.dart';

const _searchEndpoint =
    'https://rzmsnqblptbceicadbyd.supabase.co/rest/v1/rpc/search_animes';
const _playbackEndpoint =
    'https://rzmsnqblptbceicadbyd.supabase.co/functions/v1/'
    'issue-web-playback';
const _live = bool.fromEnvironment('LIVE');

SourceRule _loadRule() => SourceRule.fromJson(
  Map<String, dynamic>.from(
    jsonDecode(File('assets/rules/xifanacg.json').readAsStringSync()) as Map,
  ),
);

class _Request {
  const _Request({
    required this.url,
    required this.method,
    required this.headers,
    required this.body,
    required this.contentType,
  });

  final String url;
  final String method;
  final Map<String, String>? headers;
  final Object? body;
  final String? contentType;
}

class _XifanHost implements PipelineHost {
  _XifanHost({this.hlsReady = true});

  final bool hlsReady;
  final requests = <_Request>[];

  @override
  String get baseUrl => 'https://next.xifanacg.com';

  @override
  Map<String, String> get ruleHeaders => const {};

  @override
  bool get allowWebview => false;

  @override
  String toAbsolute(String url, String base) => url.startsWith('http')
      ? url
      : 'https://next.xifanacg.com${url.startsWith('/') ? '' : '/'}$url';

  @override
  String normalizeUrl(String url, String pageUrl) => url;

  @override
  bool isPlayable(String url) =>
      url.contains('.m3u8') ||
      url.contains('.mp4') ||
      url.contains('mode=playlist');

  @override
  Future<String> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    Object? body,
    String? referer,
    String? contentType,
    RequestPriority priority = RequestPriority.search,
  }) async {
    requests.add(
      _Request(
        url: url,
        method: method,
        headers: headers,
        body: body,
        contentType: contentType,
      ),
    );
    if (url == _searchEndpoint) {
      return jsonEncode([
        {
          'id': 360,
          'title': '命运石之门',
          'cover_url': 'https://img.example/steins-gate.jpg',
          'description': '时间旅行题材动画',
        },
      ]);
    }
    if (url == _playbackEndpoint) {
      final payload = jsonDecode(body! as String) as Map<String, dynamic>;
      if (payload['action'] == 'hls') {
        return hlsReady
            ? jsonEncode({
                'ok': true,
                'url': 'https://media.example/master.m3u8?mode=playlist',
              })
            : jsonEncode({'ok': false, 'error': 'hls_not_ready'});
      }
      return jsonEncode({
        'ok': true,
        'url': 'https://media.example/episode-5411.mp4',
      });
    }
    return '';
  }

  @override
  List<Series> parseSearchList(
    String html, {
    required List<String> selectors,
    String? detailPattern,
  }) => const [];

  @override
  List<Series> parseSearchListXPath(
    String html, {
    required String listXPath,
    required String nameXPath,
    required String linkXPath,
  }) => const [];

  @override
  List<Source> parseEpisodes(
    String html, {
    required List<String> listSelectors,
    List<String>? tabSelectors,
  }) => const [];

  @override
  List<Source> parseEpisodesXPath(
    String html, {
    required String roadsXPath,
    required String itemsXPath,
  }) => const [];

  @override
  String extractVideoUrl(String content, String pageUrl) => content;

  @override
  String? selectAttr(String html, String selector, String attr) => null;

  @override
  List<String> selectAll(String html, String selector, String attr) => const [];

  @override
  Future<String> renderWithWebview(
    String url, {
    bool Function(String html)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = const Duration(seconds: 1),
  }) async => '';

  @override
  Future<String> sniffWithWebview(String url) async => '';
}

void main() {
  const interpreter = PipelineInterpreter();

  test('search uses the Next Supabase RPC and maps anime records', () async {
    final rule = _loadRule();
    final host = _XifanHost();

    final results = await interpreter.runSearch(rule, host, '命运石之门');

    expect(results, hasLength(1));
    expect(results.single.seriesId, 'https://next.xifanacg.com/anime/360');
    expect(results.single.name, '命运石之门');
    expect(results.single.image, 'https://img.example/steins-gate.jpg');

    final request = host.requests.single;
    expect(request.url, _searchEndpoint);
    expect(request.method, 'POST');
    expect(request.contentType, 'application/json');
    expect(request.body, {'search_term': '命运石之门'});
    expect(request.headers?['Origin'], 'https://next.xifanacg.com');
    expect(
      request.headers?['Authorization'],
      'Bearer ${request.headers?['apikey']}',
    );
  });

  test('detail XPath groups the Next episode links into one source', () {
    final rule = _loadRule();
    final step = rule.detail.last;
    final adapter = PipelineSourceAdapter(rule);
    addTearDown(adapter.dispose);

    final sources = adapter.parseEpisodesXPath(
      '''
      <section class="mx-auto max-w-6xl px-4">
        <h2>剧集列表</h2>
        <div>
          <ul>
            <li><a href="/anime/360/play/5411?source=xfy2">第 01 集</a></li>
            <li><a href="/anime/360/play/5412?source=xfy2">第 02 集</a></li>
          </ul>
        </div>
      </section>
      ''',
      roadsXPath: step.str('roadsXPath')!,
      itemsXPath: step.str('itemsXPath')!,
    );

    expect(sources, hasLength(1));
    expect(sources.single.episodes, hasLength(2));
    expect(
      sources.single.episodes.first.episodeId,
      'https://next.xifanacg.com/anime/360/play/5411?source=xfy2',
    );
  });

  test('play requests HLS with a numeric episode id', () async {
    final host = _XifanHost();

    final url = await interpreter.runPlay(
      _loadRule(),
      host,
      'https://next.xifanacg.com/anime/360/play/5411?source=xfy2',
    );

    expect(url, 'https://media.example/master.m3u8?mode=playlist');
    expect(host.requests, hasLength(1));
    expect(jsonDecode(host.requests.single.body! as String), {
      'action': 'hls',
      'episode_id': 5411,
    });
  });

  test('play falls back to MP4 when HLS is not ready', () async {
    final host = _XifanHost(hlsReady: false);

    final url = await interpreter.runPlay(
      _loadRule(),
      host,
      'https://next.xifanacg.com/anime/360/play/5411?source=xfy2',
    );

    expect(url, 'https://media.example/episode-5411.mp4');
    expect(
      host.requests.map((request) {
        final body = jsonDecode(request.body! as String) as Map;
        return body['action'];
      }),
      ['hls', 'fallback'],
    );
  });

  test(
    'live search, detail, and media resolution stay playable',
    () async {
      final adapter = PipelineSourceAdapter(_loadRule());
      addTearDown(adapter.dispose);

      final results = await adapter.search('命运石之门', enhanceWithBgm: false);
      final series = results.firstWhere((item) => item.name == '命运石之门');
      final catalog = await adapter.getPlaybackCatalog(series.seriesId);
      expect(catalog.episodes, isNotEmpty);

      final episodeId = catalog.episodes.first.lineAt(1);
      expect(episodeId, isNotNull);
      final media = await adapter.resolvePlaybackMedia(episodeId!);

      expect(media.url, isNotEmpty);
      expect(VideoUrlExtractor.isHlsUrl(media.url), isTrue);
    },
    skip: !_live,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
