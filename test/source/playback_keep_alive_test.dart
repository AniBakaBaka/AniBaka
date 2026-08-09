import 'dart:async';
import 'dart:io';

import 'package:baka/source/model/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:test/test.dart';

void main() {
  test(
    'pipeline playback keep-alive repeats templates and stops cleanly',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <({Uri uri, String referer})>[];
      final subscription = server.listen((request) {
        requests.add((
          uri: request.uri,
          referer: request.headers.value(HttpHeaders.refererHeader) ?? '',
        ));
        request.response
          ..statusCode = HttpStatus.ok
          ..write('ok')
          ..close();
      });

      final pulseUrl =
          'http://${server.address.address}:${server.port}/pulse'
          '?st={st}&token={token}';
      final rule = SourceRule(
        id: 'keep_alive_test',
        name: 'keep alive test',
        baseUrl: 'https://example.com',
        directConnection: true,
        play: [
          PipelineStep.fromJson({
            'op': 'fetch',
            'url': pulseUrl,
            'playbackKeepAlive': true,
            'intervalSeconds': 1,
            'expectedBody': 'ok',
            'variables': {
              'playerUrl':
                  'https://video.example/player/?url={mediaUrl}&st={st}',
            },
            'headers': {'Referer': '{playerUrl:raw}'},
          }),
        ],
      );
      final adapter = PipelineSourceAdapter(rule);
      const mediaUrl =
          'https://video.example/show/episode.m3u8'
          '?st=session-value&e=123&token=token-value';

      try {
        await adapter.startPlaybackKeepAlive(mediaUrl);
        for (var i = 0; i < 30 && requests.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }

        expect(requests.length, greaterThanOrEqualTo(2));
        expect(requests.first.uri.queryParameters['st'], 'session-value');
        expect(requests.first.uri.queryParameters['token'], 'token-value');
        expect(
          requests.first.referer,
          'https://video.example/player/'
          '?url=${Uri.encodeComponent(mediaUrl)}&st=session-value',
        );

        adapter.stopPlaybackKeepAlive();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final stoppedAt = requests.length;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(requests, hasLength(stoppedAt));
      } finally {
        adapter.stopPlaybackKeepAlive();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
}
