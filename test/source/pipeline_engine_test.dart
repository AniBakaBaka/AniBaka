import 'dart:convert';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:test/test.dart';

import 'package:baka/models/custom_source_config.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/engine/pipeline_host.dart';
import 'package:baka/source/engine/pipeline_interpreter.dart';
import 'package:baka/source/engine/recipes.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/model/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:baka/source/store/rule_migrator.dart';

/// 可控的宿主替身：fetch 从预置表返回，解析类方法给出可预测的最小实现。
class FakeHost implements PipelineHost {
  FakeHost(this.responses);
  final Map<String, String> responses;
  final List<String> fetched = [];

  @override
  String get baseUrl => 'https://example.com';
  @override
  Map<String, String> get ruleHeaders => const {};
  @override
  bool get allowWebview => false;

  @override
  String toAbsolute(String url, String base) {
    if (url.startsWith('http')) return url;
    return 'https://example.com${url.startsWith('/') ? '' : '/'}$url';
  }

  @override
  String normalizeUrl(String url, String pageUrl) => url;

  @override
  bool isPlayable(String url) => url.contains('.m3u8') || url.contains('.mp4');

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
    fetched.add(url);
    return responses[url] ?? '';
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
  String extractVideoUrl(String content, String pageUrl) {
    final m = RegExp(
      r'https?://[^\s"'
      "'"
      r']+\.(?:m3u8|mp4)',
    ).firstMatch(content);
    return m?.group(0) ?? '';
  }

  @override
  String? selectAttr(String html, String selector, String attr) => null;
  @override
  List<String> selectAll(String html, String selector, String attr) => const [];

  @override
  Future<String> renderWithWebview(String url) async => '';
  @override
  Future<String> sniffWithWebview(String url) async => '';
}

class VerifyCheckHost extends FakeHost {
  VerifyCheckHost() : super(const {});

  var pageFetches = 0;
  String? verifyMethod;
  Object? verifyBody;
  String? verifyContentType;

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
    fetched.add(url);
    if (url == 'https://example.com/index.php/ajax/verify_check?type=search') {
      verifyMethod = method;
      verifyBody = body;
      verifyContentType = contentType;
      return '{"code":1,"msg":"ok"}';
    }
    if (url == 'https://example.com/search/x') {
      pageFetches++;
      if (pageFetches == 1) {
        return '''
          <script>
            const key = new Uint8Array([0x4e, 0x3f, 0xa9, 0xc2]);
            MAC.Ajax('/index.php/ajax/verify_check?type=search', 'post');
          </script>
        ''';
      }
      return '<html>verified</html>';
    }
    return '';
  }

  @override
  List<Series> parseSearchList(
    String html, {
    required List<String> selectors,
    String? detailPattern,
  }) {
    if (!html.contains('verified')) return const [];
    return [Series('https://example.com/detail/1', 'verified')];
  }
}

class AltchaWebviewHost extends FakeHost implements PipelineWebviewReadyHost {
  AltchaWebviewHost()
    : super(const {
        'https://example.com/blocked':
            '<html><altcha-widget></altcha-widget><script src="/aegis_altcha_object/altcha.min.js"></script></html>',
      });

  final rendered = <String>[];
  var rejectedChallenge = false;
  var acceptedResult = false;

  @override
  bool get allowWebview => true;

  @override
  Future<String> renderWithWebviewReady(
    String url, {
    bool Function(String html)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = const Duration(seconds: 1),
  }) async {
    rendered.add(url);
    rejectedChallenge =
        isReady?.call('<html><altcha-widget></altcha-widget></html>') == false;
    const html =
        '<html><body><pre>{"list":[{"id":30,"name":"鬼灭之刃"}]}</pre></body></html>';
    acceptedResult = isReady?.call(html) == true;
    return html;
  }

  @override
  String? selectAttr(String html, String selector, String attr) {
    if (selector == 'pre' && attr == 'text') {
      return '{"list":[{"id":30,"name":"鬼灭之刃"}]}';
    }
    return null;
  }
}

void main() {
  const interp = PipelineInterpreter();

  test(
    'timestamp template uses one millisecond value per pipeline run',
    () async {
      final host = FakeHost(const {});
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 'timestamp',
        'name': 'Timestamp',
        'baseUrl': 'https://example.com',
        'search': [
          {'op': 'fetch', 'url': '/page?_={timestamp:raw}'},
        ],
        'detail': const [],
        'play': const [],
      });

      final before = DateTime.now().millisecondsSinceEpoch;
      await interp.runSearch(rule, host, 'x');
      final after = DateTime.now().millisecondsSinceEpoch;

      expect(host.fetched, hasLength(1));
      final timestamp = int.parse(
        Uri.parse(host.fetched.single).queryParameters['_']!,
      );
      expect(timestamp, inInclusiveRange(before, after));
    },
  );

  test('jsonSeries 搜索：fetch → jsonSeries 构建 Series 列表', () async {
    final host = FakeHost({
      'https://example.com/api?wd=%E5%AD%A4%E7%8B%AC':
          '{"list":[{"id":"42","name":"孤独摇滚","pic":"/p.jpg"}]}',
    });
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [
        {'op': 'fetch', 'url': '/api?wd={keyword}'},
        {
          'op': 'jsonSeries',
          'listPath': 'list',
          'detailUrlTemplate': '/detail/{id}',
        },
      ],
      'detail': [],
      'play': [],
    });

    final results = await interp.runSearch(rule, host, '孤独');
    expect(results, hasLength(1));
    expect(results.first.name, '孤独摇滚');
    expect(results.first.seriesId, 'https://example.com/detail/42');
    expect(results.first.image, 'https://example.com/p.jpg');
  });

  test('play：follow → first 分支，regex 命中直链', () async {
    final host = FakeHost({
      'https://example.com/play/1':
          'var conf = {"u":"aHR0cHM6Ly9jZG4uZXhhbXBsZS5jb20vdi5tM3U4"};',
    });
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [],
      'detail': [],
      'play': [
        {'op': 'follow', 'url': '{episodeId:raw}'},
        {
          'op': 'first',
          'branches': [
            [
              {'op': 'regex', 'pattern': '"u":"([^"]+)"', 'group': 1},
              {'op': 'crypto', 'algo': 'base64', 'mode': 'decrypt'},
            ],
            [
              {'op': 'videoUrl'},
            ],
          ],
        },
      ],
    });

    final url = await interp.runPlay(rule, host, '/play/1');
    expect(url, 'https://cdn.example.com/v.m3u8');
  });

  test('query + pick + rendered regex choose current episode id', () async {
    final host = FakeHost({
      'https://example.com/video/1600/play?source=1&episode=2':
          'openlistPath:null,sort:0,episodes:[{id:"episodea00000000000001",url:"protected",sort:0}]},'
          'openlistPath:null,sort:0,episodes:[{id:"episodeb00000000000001",url:"protected",sort:0},{id:"episodeb00000000000002",url:"protected",sort:2}]}',
      'https://example.com/api/resolve?episodeId=episodeb00000000000002':
          '{"data":{"url":"https://cdn.example.com/current.m3u8"}}',
    });
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [],
      'detail': [],
      'play': [
        {
          'op': 'query',
          'name': 'source',
          'input': '{episodeId:raw}',
          'default': '0',
          'var': 'sourceIndex',
        },
        {
          'op': 'query',
          'name': 'episode',
          'input': '{episodeId:raw}',
          'default': '0',
          'var': 'episodeSort',
        },
        {'op': 'follow', 'url': '{episodeId:raw}'},
        {
          'op': 'regex',
          'pattern': r'episodes:\[([\s\S]*?)\]\}',
          'group': 1,
          'all': true,
        },
        {'op': 'pick', 'index': '{sourceIndex:raw}'},
        {
          'op': 'regex',
          'pattern':
              'id:"([a-z0-9]{20,})"[^{}]{0,180}url:"protected"[^{}]{0,80}sort[^0-9]{1,24}{episodeSort:raw}\\D',
          'group': 1,
        },
        {'op': 'fetch', 'url': '/api/resolve?episodeId={url}'},
        {'op': 'json', 'path': 'data.url'},
      ],
    });

    final currentUrl = await interp.runPlay(
      rule,
      host,
      '/video/1600/play?source=1&episode=2',
    );
    expect(currentUrl, 'https://cdn.example.com/current.m3u8');
  });

  test('jsonEpisodes：从 JSON 构建播放线路', () async {
    final host = FakeHost({
      'https://example.com/detail/1':
          '{"playlist":[{"id":"a","name":"线路A","eps":[{"vid":"e1","t":"第1集"},{"vid":"e2","t":"第2集"}]}]}',
    });
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [],
      'detail': [
        {'op': 'follow'},
        {
          'op': 'jsonEpisodes',
          'sourcesPath': 'playlist',
          'episodesKey': 'eps',
          'episodeNameKey': 't',
          'sourceNameKey': 'name',
          'episodeIdTemplate': '/watch/{vid}',
        },
      ],
      'play': [],
    });

    final sources = await interp.runDetail(rule, host, '/detail/1');
    expect(sources, hasLength(1));
    expect(sources.first.sourceName, '线路A');
    expect(sources.first.episodes, hasLength(2));
    expect(sources.first.episodes.first.episodeId, '/watch/e1');
    expect(sources.first.episodes[1].name, '第2集');
  });

  test('jsonEpisodes 的 id 快路径保留变量回退语义', () async {
    final host = FakeHost({
      'https://example.com/detail/1':
          '{"playlist":[{"name":"A","episodes":[{"name":"E"}]}]}',
    });
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [],
      'detail': [
        {'op': 'follow'},
        {'op': 'setVar', 'name': 'id', 'value': 'fallback/id'},
        {'op': 'jsonEpisodes', 'sourcesPath': 'playlist'},
      ],
      'play': [],
    });

    final sources = await interp.runDetail(rule, host, '/detail/1');
    expect(sources.single.episodes.single.episodeId, 'fallback%2Fid');
  });

  test('jsonEpisodes：支持单线路扁平剧集数组', () async {
    final host = FakeHost({
      'https://example.com/api/video/76':
          '{"data":{"episodes":[{"episodeId":61864,"episodeLabel":"第0001集"},{"episodeId":61865,"episodeLabel":"第0002集"}]}}',
    });
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [],
      'detail': [
        {'op': 'follow'},
        {
          'op': 'jsonEpisodes',
          'episodesPath': 'data.episodes',
          'episodeNameKey': 'episodeLabel',
          'episodeIdTemplate': '{episodeId:raw}',
          'sourceName': '青空次元',
        },
      ],
      'play': [],
    });

    final sources = await interp.runDetail(rule, host, '/api/video/76');
    expect(sources, hasLength(1));
    expect(sources.single.sourceName, '青空次元');
    expect(sources.single.episodes, hasLength(2));
    expect(sources.single.episodes.first.episodeId, '61864');
    expect(sources.single.episodes.last.name, '第0002集');
  });

  test('baseN：编码/解码往返一致（fcwdm 短码字母表）', () async {
    const alphabet =
        'CSqxIWYbLFQjsvy9RZdDu0HPait4MTU7NVenrwABXf2GK8EJOhklmp56cg13oz';
    final host = FakeHost(const {});
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [],
      'detail': [],
      'play': [
        {
          'op': 'baseN',
          'mode': 'encode',
          'alphabet': alphabet,
          'suffix': 'CCS',
        },
        {'op': 'setVar', 'name': 'code', 'value': '{url:raw}'},
        {
          'op': 'baseN',
          'mode': 'decode',
          'alphabet': alphabet,
          'suffix': 'CCS',
          'input': '{code:raw}',
        },
      ],
    });
    final out = await interp.runPlay(rule, host, '123456');
    expect(out, '123456');
  });

  test('jsonSeries：支持 baseN id 转换生成短码详情页', () async {
    const alphabet =
        'CSqxIWYbLFQjsvy9RZdDu0HPait4MTU7NVenrwABXf2GK8EJOhklmp56cg13oz';
    final host = FakeHost({
      'https://example.com/api?wd=x': '{"list":[{"id":"33930","name":"A"}]}',
    });
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [
        {'op': 'fetch', 'url': '/api?wd={keyword}'},
        {
          'op': 'jsonSeries',
          'listPath': 'list',
          'idTransform': 'baseN',
          'idAlphabet': alphabet,
          'idSuffix': 'CCS',
          'detailUrlTemplate': '/bangumi/{id}.html',
        },
      ],
      'detail': [],
      'play': [],
    });

    final results = await interp.runSearch(rule, host, 'x');
    expect(results.single.seriesId, 'https://example.com/bangumi/RlLCCS.html');
  });

  test('ecPlayer：解密 ConFig.url 为直链', () async {
    const direct = 'https://cdn.example.com/video/index.m3u8';
    const uid = 'GFIZ0b';
    const key = '2890${uid}tB959C';
    const iv = '2F131BE91247866E';
    final cipher = encrypt.Encrypter(
      encrypt.AES(
        encrypt.Key.fromUtf8(key),
        mode: encrypt.AESMode.cbc,
        padding: 'PKCS7',
      ),
    ).encrypt(direct, iv: encrypt.IV.fromUtf8(iv)).base64;
    final encoded = jsonEncode({
      'config': {'uid': uid},
      'url': cipher,
    });
    final host = FakeHost({
      'https://example.com/player':
          'let ConFig = $encoded,box = \$("#player");',
    });
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [],
      'detail': [],
      'play': [
        {'op': 'follow'},
        {'op': 'ecPlayer'},
      ],
    });

    final url = await interp.runPlay(rule, host, '/player');
    expect(url, direct);
  });

  test('crypto aes-gcm：base64 密钥 + 随机 IV 加密后可解密回明文', () async {
    final host = FakeHost(const {});
    // 16 字节密钥 "0123456789abcdef" 的 base64。
    const keyB64 = 'MDEyMzQ1Njc4OWFiY2RlZg==';
    const plain = 'https://cdn.example.com/secure/v.m3u8';
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [],
      'detail': [],
      'play': [
        {
          'op': 'crypto',
          'algo': 'aes-gcm',
          'mode': 'encrypt',
          'key': keyB64,
          'keyEncoding': 'base64',
          'ivRandom': 12,
          'ivVar': 'iv',
        },
        {'op': 'setVar', 'name': 'ct', 'value': '{url:raw}'},
        {
          'op': 'crypto',
          'algo': 'aes-gcm',
          'mode': 'decrypt',
          'key': keyB64,
          'keyEncoding': 'base64',
          'iv': '{iv:raw}',
          'ivEncoding': 'base64',
          'input': '{ct:raw}',
          'inputEncoding': 'base64',
        },
      ],
    });
    final out = await interp.runPlay(rule, host, plain);
    expect(out, plain);
  });

  test('maccmsSuggest 单次解析响应并回退备用接口', () async {
    final host = FakeHost({
      'https://example.com/index.php/ajax/suggest?mid=1&wd=x&limit=20':
          '{"list":[]}',
      'https://example.com/ajax/suggest?mid=1&wd=x&limit=20':
          '{"list":[{"id":"7","name":"fallback"}]}',
    });
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [
        {'op': 'maccmsSuggest', 'detailUrlTemplate': '/detail/{id}'},
      ],
      'detail': [],
      'play': [],
    });

    final result = await interp.runSearch(rule, host, 'x');
    expect(result.single.seriesId, 'https://example.com/detail/7');
    expect(host.fetched, hasLength(2));
  });

  test('maccmsVerify supports verify_check timestamp xor challenge', () async {
    final host = VerifyCheckHost();
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [
        {'op': 'fetch', 'url': '/search/{keyword}'},
        {'op': 'maccmsVerify'},
        {
          'op': 'searchList',
          'selectors': ['li'],
          'detailPattern': '/detail/',
        },
      ],
      'detail': [],
      'play': [],
    });

    final result = await interp.runSearch(rule, host, 'x');
    expect(result.single.name, 'verified');
    expect(host.pageFetches, 2);
    expect(host.verifyMethod, 'POST');
    expect(host.verifyContentType, 'form');

    final body = host.verifyBody as Map;
    final encrypted = base64.decode(body['i'] as String);
    const key = [0x4e, 0x3f, 0xa9, 0xc2];
    final timestamp = utf8.decode(
      List<int>.generate(
        encrypted.length,
        (index) => encrypted[index] ^ key[index % key.length],
      ),
    );
    final millis = int.parse(timestamp);
    expect(
      (DateTime.now().millisecondsSinceEpoch - millis).abs(),
      lessThan(10000),
    );
  });

  test('ALTCHA challenge falls back to ready WebView JSON', () async {
    final host = AltchaWebviewHost();
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 'altcha',
      'name': 'ALTCHA',
      'baseUrl': 'https://example.com',
      'search': [
        {
          'op': 'first',
          'branches': [
            [
              {'op': 'fetch', 'url': '/blocked'},
              {'op': 'maccmsVerify'},
            ],
            [
              {
                'op': 'sniff',
                'goal': 'html',
                'url': '/suggest',
                'readyContains': ['<pre>'],
                'rejectContains': ['altcha-widget', 'aegis_altcha'],
                'timeoutMs': 60000,
                'settleMs': 0,
              },
              {'op': 'select', 'css': 'pre', 'attr': 'text'},
              {
                'op': 'jsonSeries',
                'listPath': 'list',
                'detailUrlTemplate': '/bangumi/{id}.html',
              },
            ],
          ],
        },
      ],
      'detail': const [],
      'play': const [],
      'useWebview': true,
    });

    final results = await interp.runSearch(rule, host, '鬼灭');

    expect(host.rendered, ['https://example.com/suggest']);
    expect(host.rejectedChallenge, isTrue);
    expect(host.acceptedResult, isTrue);
    expect(results, hasLength(1));
    expect(results.single.name, '鬼灭之刃');
    expect(results.single.seriesId, 'https://example.com/bangumi/30.html');
  });

  test('anime1Play 只解析 URL，媒体头与 Cookie 规则交给宿主', () async {
    final host = FakeHost({
      'https://v.anime1.me/api': '{"s":[{"src":"media/video.mp4"}]}',
    });
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 'anime1',
      'name': 'Anime1',
      'baseUrl': 'https://anime1.me',
      'search': [],
      'detail': [],
      'play': [
        {
          'op': 'anime1Play',
          'mediaHeaders': {'Referer': 'https://anime1.me/'},
          'cookieNames': ['e'],
          'cookiePrefixes': ['cf_'],
        },
      ],
    });

    final result = await interp.runPlayMedia(rule, host, 'token');
    expect(result.url, 'https://v.anime1.me/media/video.mp4');
    expect(result.mediaHeaders['Referer'], 'https://anime1.me/');
    expect(result.cookieNames, ['e']);
    expect(result.cookiePrefixes, ['cf_']);
  });

  test('first 只提交成功分支，并按实际 sink 输出回退', () async {
    final host = FakeHost(const {});
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [
        {
          'op': 'first',
          'branches': [
            [
              {'op': 'template', 'value': '{"missing":[]}'},
              {'op': 'jsonSeries', 'listPath': 'list'},
            ],
            [
              {
                'op': 'template',
                'value': '{"list":[{"id":"1","name":"fallback"}]}',
              },
              {'op': 'jsonSeries', 'listPath': 'list'},
            ],
          ],
        },
      ],
      'detail': [],
      'play': [],
    });

    final branches = rule.search.single.branches;
    expect(identical(branches, rule.search.single.branches), isTrue);
    expect(rule.search.single.params.containsKey('branches'), isFalse);
    final result = await interp.runSearch(rule, host, 'x');
    expect(result.single.name, 'fallback');
  });

  test('嵌套 first 只统计最终采用分支实际执行的 sink', () async {
    final host = FakeHost(const {});
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [],
      'detail': [],
      'play': [
        {
          'op': 'first',
          'branches': [
            [
              {
                'op': 'first',
                'branches': [
                  [
                    {'op': 'template', 'value': '{"missing":[]}'},
                    {'op': 'jsonSeries', 'listPath': 'list'},
                  ],
                  [
                    {
                      'op': 'template',
                      'value': 'https://cdn.example.com/nested.mp4',
                    },
                  ],
                ],
              },
            ],
            [
              {'op': 'template', 'value': 'https://cdn.example.com/wrong.mp4'},
            ],
          ],
        },
      ],
    });

    expect(
      await interp.runPlay(rule, host, '/unused'),
      'https://cdn.example.com/nested.mp4',
    );
  });

  test('first 失败分支不会泄漏变量或媒体头', () async {
    final host = FakeHost(const {});
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [],
      'detail': [],
      'play': [
        {
          'op': 'first',
          'branches': [
            [
              {'op': 'setVar', 'name': 'leaked', 'value': 'leaked-'},
              {
                'op': 'setMediaHeaders',
                'headers': {'X-Leak': 'yes'},
              },
              {'op': 'template', 'value': ''},
            ],
            [
              {
                'op': 'template',
                'value': 'https://cdn.example.com/{leaked:raw}video.mp4',
              },
            ],
          ],
        },
      ],
    });

    final media = await interp.runPlayMedia(rule, host, '/unused');
    expect(media.url, 'https://cdn.example.com/video.mp4');
    expect(media.mediaHeaders, isEmpty);
  });

  test('播放结果的媒体元数据不会跨调用残留', () async {
    final host = FakeHost(const {});
    SourceRule ruleWithPlay(List<Map<String, dynamic>> play) =>
        SourceRule.fromJson({
          'format': kSourceRuleFormatV2,
          'id': 's',
          'name': 'S',
          'baseUrl': 'https://example.com',
          'search': [],
          'detail': [],
          'play': play,
        });

    final first = await interp.runPlayMedia(
      ruleWithPlay([
        {
          'op': 'setMediaHeaders',
          'headers': {'Referer': 'https://example.com/'},
        },
        {'op': 'template', 'value': 'https://cdn.example.com/video.mp4'},
      ]),
      host,
      '/first',
    );
    expect(first.mediaHeaders, isNotEmpty);

    final result = await interp.runPlayMedia(
      ruleWithPlay([
        {'op': 'template', 'value': ''},
      ]),
      host,
      '/second',
    );
    expect(result.url, isEmpty);
    expect(result.mediaHeaders, isEmpty);
  });

  test('PipelineStep 支持配方中已构造的嵌套步骤', () async {
    final host = FakeHost({
      'https://example.com/watch':
          'var player_aaaa={"url":"https://cdn.example.com/v.m3u8","encrypt":0};',
    });
    final rule = Recipes.expand(
      SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'recipes': ['player_aaaa'],
        'search': [],
        'detail': [],
        'play': [],
      }),
    );

    final recipeFirst = rule.play[1];
    expect(identical(recipeFirst.branches, recipeFirst.branches), isTrue);
    final roundTrip = SourceRule.fromJson(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(rule.toJson())) as Map),
    );
    expect(roundTrip.play[1].branches, hasLength(2));
    expect(
      await interp.runPlay(rule, host, '/watch'),
      'https://cdn.example.com/v.m3u8',
    );
  });

  test('Series 按 id 首次出现去重并保持顺序', () async {
    final host = FakeHost({
      'https://example.com/list':
          '{"list":[{"id":"1","name":"first"},'
          '{"id":"1","name":"duplicate"},'
          '{"id":"2","name":"second"}]}',
    });
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 's',
      'name': 'S',
      'baseUrl': 'https://example.com',
      'search': [
        {'op': 'fetch', 'url': '/list'},
        {'op': 'jsonSeries', 'listPath': 'list'},
      ],
      'detail': [],
      'play': [],
    });

    final result = await interp.runSearch(rule, host, 'x');
    expect(result.map((series) => series.name), ['first', 'second']);
  });

  test('校验器捕获非法正则、退役 op 与非法 baseN', () {
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 'x',
      'name': 'X',
      'baseUrl': 'https://x.com',
      'search': [
        {'op': 'regex', 'pattern': '('},
        {'op': 'bogusOp'},
        {'op': 'aowuSearch'},
      ],
      'detail': [],
      'play': [
        {'op': 'baseN', 'alphabet': 'x'},
      ],
    });
    final v = RuleValidator.validate(rule);
    expect(v.isValid, isFalse);
    expect(v.errors.any((e) => e.contains('正则')), isTrue);
    expect(v.errors.any((e) => e.contains('未知 op')), isTrue);
    expect(v.errors.any((e) => e.contains('alphabet')), isTrue);
  });

  test('调度器 per-host 限流：同域名并发不超过上限', () async {
    final scheduler = RequestScheduler(maxConcurrent: 10, maxPerHost: 2);
    var active = 0;
    var peak = 0;
    Future<void> job() => scheduler.run(() async {
      active++;
      peak = active > peak ? active : peak;
      await Future.delayed(const Duration(milliseconds: 10));
      active--;
    }, host: 'a.com');
    await Future.wait(List.generate(6, (_) => job()));
    expect(peak, lessThanOrEqualTo(2));
  });

  test('取消令牌：取消后排队任务以异常结束', () async {
    final scheduler = RequestScheduler(maxConcurrent: 1, maxPerHost: 1);
    final token = RequestCancelToken();
    // 占满唯一槽位
    final blocker = scheduler.run(
      () => Future.delayed(const Duration(milliseconds: 50)),
      host: 'b.com',
    );
    final queued = scheduler.run(
      () async => 'done',
      host: 'b.com',
      cancelToken: token,
    );
    token.cancel();
    await expectLater(queued, throwsA(isA<RequestCancelledException>()));
    await blocker;
  });

  test('directConnection is preserved and disables the system proxy', () {
    final rule = SourceRule.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 'direct-source',
      'name': 'Direct source',
      'baseUrl': 'https://example.com',
      'directConnection': true,
      'search': const [],
      'detail': const [],
      'play': const [],
    });

    expect(rule.directConnection, isTrue);
    expect(rule.copyWith().directConnection, isTrue);
    expect(rule.toJson()['directConnection'], isTrue);
    expect(PipelineSourceAdapter(rule).useSystemProxy, isFalse);
  });

  test('custom source persistence keeps directConnection', () {
    final config = CustomSourceConfig.fromJson({
      'format': kSourceRuleFormatV2,
      'id': 'direct_source',
      'name': 'Direct source',
      'baseUrl': 'https://example.com',
      'directConnection': true,
      'search': const <Object>[],
      'detail': const <Object>[],
      'play': const <Object>[],
    });

    expect(config.pipeline?['directConnection'], isTrue);
    expect(RuleMigrator.ruleForConfig(config).directConnection, isTrue);
  });

  test('legacy pekolove installs recover direct routing', () {
    final config = CustomSourceConfig(
      id: 'ani_pekolove',
      name: 'Pekolove',
      baseUrl: 'https://ani.pekolove.net',
      pipeline: const {
        'search': <Object>[],
        'detail': <Object>[],
        'play': <Object>[],
      },
    );

    expect(config.pipeline, isNot(contains('directConnection')));
    expect(RuleMigrator.ruleForConfig(config).directConnection, isTrue);
  });
}
