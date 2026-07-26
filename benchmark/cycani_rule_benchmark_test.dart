import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' show parse;
import 'package:test/test.dart';

import 'package:baka/source/engine/pipeline_host.dart';
import 'package:baka/source/engine/pipeline_interpreter.dart';
import 'package:baka/source/html_parser.dart';
import 'package:baka/source/model/source_rule.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/runtime/request_scheduler.dart';

void main() {
  test('Cycani controlled pipeline benchmark', () async {
    final currentJson =
        jsonDecode(await File('assets/rules/cycani.json').readAsString())
            as Map<String, dynamic>;
    final current = SourceRule.fromJson(currentJson);
    final legacy = SourceRule.fromJson(_legacyRuleJson(currentJson));
    const interpreter = PipelineInterpreter();

    final oldSearch = await _measure(
      12,
      () => interpreter.runSearch(legacy, _CycaniBenchmarkHost(), '鬼灭'),
    );
    final newSearch = await _measure(
      12,
      () => interpreter.runSearch(current, _CycaniBenchmarkHost(), '鬼灭'),
    );
    final oldDetail = await _measure(
      12,
      () => interpreter.runDetail(
        legacy,
        _CycaniBenchmarkHost(),
        'https://www.cycani.org/bangumi/3049.html',
      ),
    );
    final newDetail = await _measure(
      12,
      () => interpreter.runDetail(
        current,
        _CycaniBenchmarkHost(),
        'https://www.cycani.org/bangumi/3049.html',
      ),
    );

    // ignore: avoid_print
    print(
      'CYCANI_BENCHMARK iterations=12 '
      'legacy_search_ms=${oldSearch.inMilliseconds} '
      'current_search_ms=${newSearch.inMilliseconds} '
      'legacy_detail_ms=${oldDetail.inMilliseconds} '
      'current_detail_ms=${newDetail.inMilliseconds}',
    );

    expect(newSearch, lessThan(oldSearch));
    expect(newDetail, lessThan(oldDetail));
  });
}

Map<String, dynamic> _legacyRuleJson(Map<String, dynamic> current) {
  final legacy = jsonDecode(jsonEncode(current)) as Map<String, dynamic>;
  final search = legacy['search'] as List<dynamic>;
  final first = search.single as Map<String, dynamic>;
  final branches = first['branches'] as List<dynamic>;
  first['branches'] = [branches[1], branches[0]];
  legacy['detail'] = [
    {
      'op': 'first',
      'branches': [
        [
          {
            'op': 'follow',
            'headers': {'Referer': 'https://www.cycani.org/'},
          },
          {'op': 'maccmsVerify'},
        ],
        [
          {
            'op': 'sniff',
            'goal': 'html',
            'readyContains': ['anthology-list'],
            'rejectContains': ['altcha-widget', 'aegis_altcha'],
            'timeoutMs': 60000,
            'settleMs': 0,
          },
        ],
      ],
    },
    {
      'op': 'episodes',
      'listSelectors': ['.anthology-list-box', '.anthology-list-play'],
      'tabSelectors': ['.anthology-tab .swiper-slide', '.anthology-tab a'],
    },
  ];
  return legacy;
}

Future<Duration> _measure(
  int iterations,
  Future<Object?> Function() action,
) async {
  await action();
  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    await action();
  }
  stopwatch.stop();
  return stopwatch.elapsed;
}

class _CycaniBenchmarkHost implements PipelineHost, PipelineWebviewReadyHost {
  static const _suggest = '{"list":[{"id":"3049","name":"我心里危险的东西"}]}';
  static const _challenge =
      '<html><altcha-widget></altcha-widget><script src="aegis_altcha.js"></script></html>';
  static const _detailApi =
      r'{"list":[{"vod_play_from":"cycani","vod_play_url":"第01集$/watch/3049/1/1.html#第02集$/watch/3049/1/2.html"}]}';
  static const _detailHtml = '''
    <div class="anthology-tab"><div class="swiper-slide">次元城2</div></div>
    <div class="anthology-list">
      <ul class="anthology-list-box">
        <li><a href="/watch/3049/1/1.html">第01集</a></li>
        <li><a href="/watch/3049/1/2.html">第02集</a></li>
      </ul>
    </div>
  ''';

  @override
  String get baseUrl => 'https://www.cycani.org';

  @override
  Map<String, String> get ruleHeaders => const {};

  @override
  bool get allowWebview => true;

  @override
  String toAbsolute(String url, String base) =>
      Uri.parse(base).resolve(url).toString();

  @override
  String normalizeUrl(String url, String pageUrl) => url;

  @override
  bool isPlayable(String url) => false;

  @override
  Future<String> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    Object? body,
    String? referer,
    String? contentType,
    RequestPriority priority = RequestPriority.search,
    RequestCancelToken? cancelToken,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (url.contains('/api.php/provide/vod/')) return _detailApi;
    if (url.contains('/ajax/suggest')) return _suggest;
    if (url.contains('/bangumi/3049.html')) return _challenge;
    return '';
  }

  @override
  Future<String> renderWithWebviewReady(
    String url, {
    bool Function(String html)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = const Duration(seconds: 1),
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    final html = url.contains('/suggest')
        ? '<html><body>$_suggest</body></html>'
        : _detailHtml;
    if (isReady != null && !isReady(html)) return '';
    return html;
  }

  @override
  Future<String> renderWithWebview(String url) => renderWithWebviewReady(url);

  @override
  Future<String> sniffWithWebview(String url) async => '';

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
  }) => HtmlParser.parseSources(
    parse(html),
    baseUrl: baseUrl,
    listSelectors: listSelectors,
    tabSelectors: tabSelectors,
  );

  @override
  List<Source> parseEpisodesXPath(
    String html, {
    required String roadsXPath,
    required String itemsXPath,
  }) => const [];

  @override
  String extractVideoUrl(String content, String pageUrl) => '';

  @override
  String? selectAttr(String html, String selector, String attr) {
    final element = parse(html).querySelector(selector);
    if (element == null) return null;
    return attr == 'text' ? element.text.trim() : element.attributes[attr];
  }

  @override
  List<String> selectAll(String html, String selector, String attr) => const [];
}
