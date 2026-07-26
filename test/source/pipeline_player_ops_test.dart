import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:test/test.dart';

import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/engine/pipeline_host.dart';
import 'package:baka/source/engine/pipeline_interpreter.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/model/source_rule.dart';
import 'package:baka/source/runtime/request_scheduler.dart';

class _PlayerOpsHost implements PipelineHost {
  _PlayerOpsHost([this.responses = const {}]);

  final Map<String, String> responses;
  bool challengeRejected = false;
  bool readyAccepted = false;
  Duration? receivedTimeout;
  Duration? receivedSettleDelay;

  @override
  String get baseUrl => 'https://example.com';

  @override
  Map<String, String> get ruleHeaders => const {};

  @override
  bool get allowWebview => true;

  @override
  String toAbsolute(String url, String base) {
    if (url.startsWith('http')) return url;
    return Uri.parse(base.isEmpty ? baseUrl : base).resolve(url).toString();
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
    return RegExp(
          r'''https?://[^\s"']+\.(?:m3u8|mp4)''',
        ).firstMatch(content)?.group(0) ??
        '';
  }

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
  }) async {
    receivedTimeout = timeout;
    receivedSettleDelay = settleDelay;
    challengeRejected =
        !(isReady?.call(
              '<title>DokiDoki CDN</title><script>var player_aaaa={};</script>',
            ) ??
            true);
    readyAccepted =
        isReady?.call(
          '<script>var player_aaaa={};</script>'
          'https://cdn.example.com/ready.mp4',
        ) ??
        true;
    return '<script>var player_aaaa={};</script>'
        'https://cdn.example.com/ready.mp4';
  }

  @override
  Future<String> sniffWithWebview(String url) async => '';
}

SourceRule _rule(List<Map<String, dynamic>> play) => SourceRule.fromJson({
  'format': kSourceRuleFormatV2,
  'id': 'test',
  'name': 'Test',
  'baseUrl': 'https://example.com',
  'search': const [],
  'detail': const [],
  'play': play,
  'useWebview': true,
});

void main() {
  const interpreter = PipelineInterpreter();

  test('replace normalizes escaped parser URL', () async {
    final result = await interpreter.runPlay(
      _rule([
        {'op': 'template', 'value': r'https:\/\/player.example.com\/parse'},
        {'op': 'replace', 'pattern': r'\/', 'replacement': '/'},
      ]),
      _PlayerOpsHost(),
      '/unused',
    );

    expect(result, 'https://player.example.com/parse');
  });

  test('playerDecrypt decrypts dynamic meta-id AES-CBC URL', () async {
    const charsetId = '2031';
    const viewportId = 'ABCD';
    const salt = 'test-salt';
    const direct = 'https://cdn.example.com/video.mp4';
    const secret = 'BDAC';
    final hash = md5.convert(utf8.encode('$secret$salt')).toString();
    final cipher = encrypt.Encrypter(
      encrypt.AES(
        encrypt.Key.fromUtf8(hash.substring(16)),
        mode: encrypt.AESMode.cbc,
        padding: 'PKCS7',
      ),
    ).encrypt(direct, iv: encrypt.IV.fromUtf8(hash.substring(0, 16))).base64;
    final html =
        '<meta charset="UTF-8" id="now_$charsetId">'
        '<meta name="viewport" id="now_$viewportId">'
        '<script>var config = {"url":"$cipher"};</script>';
    final host = _PlayerOpsHost({'https://example.com/player': html});

    for (final decryptStep in <Map<String, dynamic>>[
      {'op': 'playerDecrypt', 'salt': salt},
      {
        'op': 'playerDecrypt',
        'salt': salt,
        'viewportSelector': 'meta[name="viewport"]',
        'charsetSelector': 'meta[charset]',
      },
    ]) {
      final result = await interpreter.runPlay(
        _rule([
          {'op': 'follow'},
          decryptStep,
        ]),
        host,
        '/player',
      );
      expect(result, direct);
    }

    final unquotedHost = _PlayerOpsHost({
      'https://example.com/player':
          '<meta charset=UTF-8 id=now_$charsetId>'
          '<meta name=viewport id=now_$viewportId>'
          '<script>var config = {"url":"$cipher"};</script>',
    });
    final unquotedResult = await interpreter.runPlay(
      _rule([
        {'op': 'follow'},
        {'op': 'playerDecrypt', 'salt': salt},
      ]),
      unquotedHost,
      '/player',
    );
    expect(unquotedResult, direct);
  });

  test('sniff html forwards rule readiness and timing', () async {
    final host = _PlayerOpsHost();
    final result = await interpreter.runPlay(
      _rule([
        {'op': 'template', 'value': 'https://example.com/rendered'},
        {
          'op': 'sniff',
          'goal': 'html',
          'readyRegex': 'player_aaaa',
          'readyIgnoreCase': true,
          'rejectContains': ['DokiDoki CDN'],
          'timeoutMs': 35000,
          'settleMs': 6000,
        },
        {'op': 'videoUrl'},
      ]),
      host,
      '/unused',
    );

    expect(host.challengeRejected, isTrue);
    expect(host.readyAccepted, isTrue);
    expect(host.receivedTimeout, const Duration(seconds: 35));
    expect(host.receivedSettleDelay, const Duration(seconds: 6));
    expect(result, 'https://cdn.example.com/ready.mp4');
  });

  test('validator accepts the new generic ops', () {
    final validation = RuleValidator.validate(
      _rule([
        {'op': 'replace', 'pattern': r'\/', 'replacement': '/'},
        {'op': 'playerDecrypt', 'salt': 'site-salt'},
        {
          'op': 'sniff',
          'goal': 'html',
          'readyRegex': r'player_aaaa|<video',
          'rejectContains': ['DokiDoki CDN'],
        },
      ]),
    );

    expect(validation.errors, isEmpty);
  });
}
