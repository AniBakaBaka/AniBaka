import 'dart:convert';

import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/html_parser.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:html/parser.dart' as html;
import 'package:test/test.dart';

const _baseUrl = 'https://example.com/detail/show';

void main() {
  test('CSS fields read only the declared nodes and attributes', () {
    final document = html.parse('''
      <div class="item">
        <a class="cover" href="/wrong" title="Wrong" data-bg="/cover.jpg"></a>
        <a class="title" href="/v/71.html">海贼王</a>
        <img src="/placeholder.jpg" alt="Wrong image title">
      </div>
    ''');
    final series = HtmlParser.parseSearchResults(
      document,
      baseUrl: _baseUrl,
      selectors: ['div.item'],
      linkSelector: 'a.title',
      titleSelector: 'a.title',
      imageSelector: 'a.cover',
      imageAttr: 'data-bg',
    ).single;
    expect(series.seriesId, 'https://example.com/v/71.html');
    expect(series.name, '海贼王');
    expect(series.image, 'https://example.com/cover.jpg');
    expect(
      HtmlParser.parseSearchResults(
        document,
        baseUrl: _baseUrl,
        selectors: ['div.item'],
        linkSelector: 'a.title',
        titleSelector: '.missing',
      ),
      isEmpty,
    );
    final noImage = HtmlParser.parseSearchResults(
      document,
      baseUrl: _baseUrl,
      selectors: ['div.item'],
      linkSelector: 'a.title',
      imageSelector: 'img',
      imageAttr: 'data-original',
    ).single;
    expect(noImage.image, isNull);
  });

  test('an anchor row can explicitly read its image title', () {
    final series = HtmlParser.parseSearchResults(
      html.parse(
        '<a class="video-wrapper" href="/voddetail/1.html">'
        '<img class="videoimg" src="/cover.jpg" alt="海"></a>',
      ),
      baseUrl: _baseUrl,
      selectors: ['a.video-wrapper'],
      linkSelector: '',
      titleSelector: 'img.videoimg',
      titleAttr: 'alt',
      imageSelector: 'img.videoimg',
    ).single;
    expect(series.name, '海');
    expect(series.image, 'https://example.com/cover.jpg');
  });

  test('line names use the declared text or attribute without guessing', () {
    final document = html.parse(
      '<nav><a alt="实际线路">次元番W1'
      '<span class="badge">1180</span></a></nav>'
      '<section><a href="/play/1">One</a></section>',
    );
    for (final (attr, expected) in [('ownText', '次元番W1'), ('alt', '实际线路')]) {
      expect(
        HtmlParser.parseSources(
          document,
          baseUrl: _baseUrl,
          listSelectors: ['section'],
          tabSelectors: ['nav a'],
          tabAttr: attr,
        ).single.sourceName,
        expected,
      );
    }
  });

  test('HTML lists and line titles use only declared selectors', () {
    final document = html.parse('''
      <div class="module-items"><div class="module-item">
        <a href="/detail/wrong" title="Wrong">Wrong</a>
      </div></div>
      <nav class="module-tab-item">线路 1080</nav>
      <section class="module-play-list"><a href="/play/1">One</a></section>
    ''');
    expect(HtmlParser.parseSearchResults(document, baseUrl: _baseUrl), isEmpty);
    expect(HtmlParser.parseSources(document, baseUrl: _baseUrl), isEmpty);
    final unnamed = HtmlParser.parseSources(
      document,
      baseUrl: _baseUrl,
      listSelectors: ['section'],
    );
    expect(unnamed.single.sourceName, '播放源 1');
    final named = HtmlParser.parseSources(
      document,
      baseUrl: _baseUrl,
      listSelectors: ['section'],
      tabSelectors: ['nav'],
    );
    expect(named.single.sourceName, '线路 1080');
  });

  test('declared episode numbers preserve sparse slots in CSS and XPath', () {
    final document = html.parse('''
      <section>
        <a href="/play?ep=2">Two</a><a href="/play?ep=5">Five</a>
        <a href="/play?ep=0">Zero</a><a href="/extras">Extras</a>
      </section>
    ''');
    for (final useXPath in [false, true]) {
      final sources = HtmlParser.parseSources(
        document,
        baseUrl: _baseUrl,
        listSelectors: useXPath ? [] : ['section'],
        roadsXPath: useXPath ? '//section' : null,
        itemsXPath: './/a',
        episodeNumberPattern: RegExp(r'[?&]ep=(\d+)'),
      );
      expect(sources.single.episodes.map((e) => e.episode), [1, 4]);
      expect(sources.single.episodes.map((e) => e.name), ['Two', 'Five']);
    }
  });

  test('rule validation rejects missing HTML selection declarations', () {
    RuleValidation validate(PipelineStep step) => RuleValidator.validate(
      SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 'test',
        'name': 'Test',
        'baseUrl': _baseUrl,
        'search': [step.toJson()],
        'detail': [],
        'play': [],
      }),
    );
    for (final step in const [
      PipelineStep('searchList', {}),
      PipelineStep('searchList', {
        'selectors': [42],
      }),
      PipelineStep('searchList', {
        'selectors': ['  '],
        'listXPath': '',
      }),
      PipelineStep('episodes', {}),
      PipelineStep('episodes', {'roadsXPath': '//section'}),
      PipelineStep('episodes', {
        'listSelectors': ['section'],
        'episodeNumberPattern': '[',
      }),
    ]) {
      expect(validate(step).isValid, isFalse, reason: '${step.toJson()}');
    }
    expect(
      validate(
        const PipelineStep('searchList', {'selectors': 'article'}),
      ).isValid,
      isTrue,
    );
    expect(
      validate(
        const PipelineStep('episodes', {
          'roadsXPath': '//section',
          'itemsXPath': './/a',
        }),
      ).isValid,
      isTrue,
    );
  });

  test('literal extraction prefers HLS and respects quote boundaries', () {
    const content = r'''
      <img src="https://example.com/poster.jpg">
      <script>
        const file = 'https://media.test/first.mp4';
        const url = "https:\/\/media.test\/playlist.M3U8?sign=A%2FB&amp;x=1";
      </script>
    ''';
    expect(
      VideoUrlExtractor.extractBest(content, _baseUrl),
      'https://media.test/playlist.M3U8?sign=A%2FB&x=1',
    );
    expect(
      VideoUrlExtractor.extractBest("file='//media.test/first.mp4';", _baseUrl),
      'https://media.test/first.mp4',
    );
  });

  test('encoded payloads require a decoding step in the rule', () {
    const media = 'https://media.test/playlist.m3u8';
    for (final encoded in [
      base64.encode(utf8.encode(media)),
      Uri.encodeComponent(media),
      Uri.encodeComponent(Uri.encodeComponent(media)),
    ]) {
      expect(
        VideoUrlExtractor.extractBest(jsonEncode({'url': encoded}), _baseUrl),
        isEmpty,
      );
    }
  });

  test('normalization preserves endpoints, signed queries and path bytes', () {
    for (final url in [
      'https://media.test/api?url=https%3A%2F%2Fother.test%2F1.m3u8&sign=A%2FB',
      'https://media.test/api?path=episodes%2F1.m3u8&verify=1800000000-abcd',
      'https://media.test/file.mp4?file=https%3A%2F%2Fother.test%2F2.mp4',
      'https://media.test/file.mp4?sign=A%2FB;',
      'https://media.test/file.mp4?sign=A%252FB',
    ]) {
      expect(VideoUrlExtractor.normalizeResolvedUrl(url, _baseUrl), url);
    }
    expect(
      VideoUrlExtractor.normalizeResolvedUrl('../media/a%252Fb.mp4', _baseUrl),
      'https://example.com/media/a%252Fb.mp4',
    );
    expect(VideoUrlExtractor.toAbsolute('http://[', _baseUrl), isEmpty);
    expect(VideoUrlExtractor.toAbsolute('/file.mp4', 'http://['), isEmpty);
  });
}
