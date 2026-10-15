import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baka/models/ai_rule_authoring.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/source/ai_rule_authoring_service.dart';
import 'package:baka/services/source/rule_validation_runner.dart';
import 'package:baka/services/source/site_probe_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('site probe blocks loopback targets before making a request', () async {
    final probe = SiteProbeService();
    addTearDown(probe.dispose);
    await expectLater(
      probe.execute(
        const SiteProbeRequest(method: 'GET', url: 'http://127.0.0.1/test'),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'site probe skips redirect bodies and stops exactly at its byte limit',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      server.listen((request) async {
        try {
          if (request.uri.path == '/redirect') {
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(HttpHeaders.locationHeader, '/body');
            request.response.write('redirect body');
          } else {
            request.response.write('x' * SiteProbeService.maxResponseBytes);
          }
          await request.response.flush();
          await release.future;
          await request.response.close();
        } on SocketException {
          // The probe cancels both responses without reading the remaining body.
        } on HttpException {
          // Cancellation may race with flushing the response.
        }
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        final probe = SiteProbeService();
        addTearDown(probe.dispose);
        final result = await probe
            .execute(
              const SiteProbeRequest(
                method: 'GET',
                url: 'http://8.8.8.8/redirect',
              ),
            )
            .timeout(const Duration(seconds: 5));
        expect(result['body'], 'x' * SiteProbeService.maxResponseBytes);
        expect(result['truncated'], isTrue);
        expect(result['request'], {
          'method': 'GET',
          'url': 'http://8.8.8.8/redirect',
        });
        expect(result['finalUrl'], 'http://8.8.8.8/body');
      }, _LocalProbeOverrides(server));
      release.complete();
    },
  );

  test(
    'authoring loop probes, validates, and returns an unsaved rule',
    () async {
      final modelServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => modelServer.close(force: true));
      var calls = 0;
      modelServer.listen((request) async {
        await utf8.decoder.bind(request).join();
        calls++;
        final content = calls == 1
            ? jsonEncode({
                'action': 'abort',
                'summary': '常见地址暂时不可用。',
                'reasonZh': '站点无法访问。',
              })
            : calls == 2
            ? jsonEncode({
                'action': 'probe',
                'summary': '改用浏览器渲染检查真实页面结构。',
                'requests': [
                  {
                    'method': 'GET',
                    'url': 'https://anime.example/search',
                    'render': true,
                  },
                ],
              })
            : calls == 3
            ? jsonEncode({
                'action': 'candidate',
                'rule': {
                  'pipeline': {
                    'play': [
                      {'op': 42},
                    ],
                  },
                },
              })
            : jsonEncode({
                'action': 'candidate',
                'summary': '已找到可验证的搜索和播放流程。',
                'rule': {
                  'name': 'AI Test',
                  'baseUrl': 'https://ignored.example',
                  'pipeline': {
                    'search': <dynamic>[],
                    'detail': <dynamic>[],
                    'play': <dynamic>[],
                  },
                },
              });
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': content},
              },
            ],
          }),
        );
        await request.response.close();
      });

      final service = AiRuleAuthoringService(
        probeService: _FakeProbeService(),
        validationRunner: _SuccessfulValidationRunner(),
        uriValidator: (_) async {},
        includeBundledExamples: false,
      );
      addTearDown(service.dispose);
      final progress = <RuleAuthoringProgress>[];
      final result = await service.run(
        provider: AiProviderConfig(
          baseUrl: 'http://${modelServer.address.host}:${modelServer.port}/v1',
          model: 'fake',
        ),
        seed: const RuleAuthoringSeed(
          mode: RuleAuthoringMode.create,
          siteUrl: 'https://anime.example',
          keyword: '孤独摇滚',
        ),
        onProgress: progress.add,
      );

      expect(calls, 4);
      expect(result.config.baseUrl, 'https://anime.example');
      expect(result.config.id, startsWith('ai_anime_example_'));
      expect(
        progress.map((item) => item.stage),
        containsAll(['summary', 'probe', 'success']),
      );
    },
  );

  test(
    'validation shares cookies and stops before an ignored Range body ends',
    () async {
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final requests = <String>[];
      final config = await _validationSite((request) async {
        requests.add(request.method);
        expect(request.cookies.single.value, 'test-session');
        request.response.headers.contentType = ContentType.binary;
        request.response.add(List.filled(16 * 1024, 1));
        await request.response.flush();
        await release.future;
      });
      final runner = RuleValidationRunner();
      addTearDown(runner.dispose);
      final report = await runner
          .validate(config, keyword: 'test')
          .timeout(const Duration(seconds: 5));
      expect(report.success, isTrue, reason: report.message);
      expect(report.mediaKind, 'file');
      expect(requests, ['GET']);
      release.complete();
    },
  );

  test(
    'HLS streams split signatures and resolves redirected relative URIs',
    () async {
      final paths = <String>[];
      final config = await _validationSite((request) async {
        paths.add(request.uri.path);
        switch (request.uri.path) {
          case '/media':
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              '/cdn/master',
            );
          case '/cdn/master':
            request.response.headers.contentType = ContentType.binary;
            request.response.write('#EX');
            await request.response.flush();
            request.response.add(
              utf8.encode(
                'TM3U\n#${'注释' * 1000}\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmedia/list\n',
              ),
            );
          case '/cdn/media/list':
            request.response.write('#EXTM3U\r\n#EXTINF:5,\r\nsegment.ts\r\n');
          case '/cdn/media/segment.ts':
            expect(
              request.headers.value(HttpHeaders.rangeHeader),
              'bytes=0-1023',
            );
            request.response.add(List.filled(64, 2));
          default:
            request.response.statusCode = HttpStatus.notFound;
        }
      });
      final runner = RuleValidationRunner();
      addTearDown(runner.dispose);
      final report = await runner.validate(config, keyword: 'test');
      expect(report.success, isTrue, reason: report.message);
      expect(report.mediaKind, 'hls-segment');
      expect(paths, [
        '/media',
        '/cdn/master',
        '/cdn/media/list',
        '/cdn/media/segment.ts',
      ]);
    },
  );

  test('missing repair targets fail at their actual stage', () async {
    var mediaRequests = 0;
    final config = await _validationSite((_) async {
      mediaRequests++;
    });
    final runner = RuleValidationRunner();
    addTearDown(runner.dispose);
    final series = await runner.validate(
      config,
      keyword: 'test',
      preferredSeriesId: 'missing',
    );
    final episode = await runner.validate(
      config,
      keyword: 'test',
      preferredEpisodeId: 'missing',
    );
    expect(series.success, isFalse);
    expect(series.stage, 'search');
    expect(episode.success, isFalse);
    expect(episode.stage, 'detail');
    expect(episode.episodeCount, 1);
    expect(mediaRequests, 0);
  });

  test('disposing validation cancels a pending media read', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final config = await _validationSite((request) async {
      await request.response.flush();
      started.complete();
      await release.future;
    });
    final runner = RuleValidationRunner();
    addTearDown(runner.dispose);
    final pending = runner.validate(config, keyword: 'test');
    await started.future;
    runner.dispose();
    final report = await pending.timeout(const Duration(seconds: 5));
    expect(report.success, isFalse);
    expect(report.stage, 'media');
    release.complete();
  });

  for (final (contentType, body) in [
    ('text/html', '<html>Not a video</html>'),
    ('application/octet-stream', ''),
    ('application/vnd.apple.mpegurl', 'not a playlist'),
    ('application/vnd.apple.mpegurl', '#EXTM3U\n#EXT-X-ENDLIST\n'),
  ]) {
    test('media validation rejects $contentType: $body', () async {
      final config = await _validationSite((request) async {
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          contentType,
        );
        request.response.write(body);
      });
      final runner = RuleValidationRunner();
      addTearDown(runner.dispose);
      final report = await runner.validate(config, keyword: 'test');
      expect(report.success, isFalse);
      expect(report.stage, 'media');
    });
  }
}

Future<CustomSourceConfig> _validationSite(
  Future<void> Function(HttpRequest) respond,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  final origin = 'http://${server.address.host}:${server.port}';
  server.listen((request) async {
    try {
      switch (request.uri.path) {
        case '/search':
          request.response.headers.contentType = ContentType.json;
          request.response.cookies.add(
            Cookie('session', 'test-session')..path = '/',
          );
          request.response.write(
            jsonEncode({
              'list': [
                {'id': '1', 'name': 'Test'},
              ],
            }),
          );
        case '/detail/1':
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': {
                'episodes': [
                  {'episodeId': '$origin/media', 'episodeLabel': '第1集'},
                ],
              },
            }),
          );
        default:
          await respond(request);
      }
      await request.response.close();
    } on SocketException {
      // Prefix reads and disposal intentionally disconnect before the body ends.
    } on HttpException {
      // The client may cancel while the response is being flushed.
    }
  });
  return CustomSourceConfig(
    id: 'validation',
    name: 'Validation',
    baseUrl: origin,
    pipeline: _pipeline(),
  );
}

Map<String, dynamic> _pipeline() => {
  'search': [
    {'op': 'fetch', 'url': '/search?wd={keyword}'},
    {
      'op': 'jsonSeries',
      'listPath': 'list',
      'detailUrlTemplate': '/detail/{id}',
    },
  ],
  'detail': [
    {'op': 'follow'},
    {
      'op': 'jsonEpisodes',
      'episodesPath': 'data.episodes',
      'episodeNameKey': 'episodeLabel',
      'episodeIdTemplate': '{episodeId:raw}',
      'sourceName': '测试线路',
    },
  ],
  'play': <dynamic>[],
};

class _FakeProbeService extends SiteProbeService {
  @override
  Future<Map<String, dynamic>> execute(SiteProbeRequest request) async => {
    'request': {'method': request.method, 'url': request.url},
    'status': 200,
    'finalUrl': request.url,
    'contentType': 'text/html',
    'headers': <String, String>{},
    'body': '<a href="/detail/1">孤独摇滚</a>',
    'truncated': false,
  };
}

class _LocalProbeOverrides extends HttpOverrides {
  _LocalProbeOverrides(this.server);
  final HttpServer server;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..connectionFactory = (_, _, _) =>
            Socket.startConnect(server.address, server.port);
}

class _SuccessfulValidationRunner extends RuleValidationRunner {
  @override
  Future<RuleValidationReport> validate(
    CustomSourceConfig config, {
    required String keyword,
    String? preferredSeriesId,
    String? preferredEpisodeId,
  }) async => const RuleValidationReport(
    success: true,
    stage: 'media',
    message: 'ok',
    seriesCount: 1,
    lineCount: 1,
    episodeCount: 1,
    mediaKind: 'file',
  );
}
