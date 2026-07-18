import 'dart:async';
import 'dart:convert';
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

  test('legacy pekolove materializes a complete VOD manifest', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) {
      if (request.uri.path.endsWith('.ts')) {
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.contentType = ContentType('video', 'mp2t')
          ..add(List<int>.generate(2048, (index) => index % 256))
          ..close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
        ..write('''
#EXTM3U
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:3.0,
segment0.ts?st=session
#EXTINF:3.0,
segment1.ts?st=session
#EXT-X-ENDLIST
''')
        ..close();
    });
    final manifestUrl =
        'http://${server.address.address}:${server.port}/show/episode.m3u8';
    final adapter = PipelineSourceAdapter(
      SourceRule(
        id: 'ani_pekolove',
        name: 'materialize test',
        baseUrl: 'https://example.com',
        directConnection: true,
        play: const [],
      ),
    );

    try {
      final prepared = await adapter.preparePlaybackMedia((
        url: manifestUrl,
        httpHeaders: const <String, String>{},
      ));
      expect(prepared.url, isNot(manifestUrl));
      expect(prepared.url, startsWith('http://127.0.0.1:'));
      final client = HttpClient();
      final manifestResponse = await (await client.getUrl(
        Uri.parse(prepared.url),
      )).close();
      final body = await utf8.decoder.bind(manifestResponse).join();
      expect(body, contains('#EXT-X-MEDIA-SEQUENCE:0'));
      expect(body, contains('#EXT-X-ENDLIST'));
      final segmentUrl = const LineSplitter()
          .convert(body)
          .firstWhere((line) => line.isNotEmpty && !line.startsWith('#'));
      expect(segmentUrl, startsWith('http://127.0.0.1:'));
      final segmentRequest = await client.getUrl(Uri.parse(segmentUrl));
      segmentRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=0-2047');
      final segmentResponse = await segmentRequest.close();
      expect(segmentResponse.statusCode, HttpStatus.partialContent);
      expect(
        await segmentResponse.fold<int>(0, (sum, bytes) => sum + bytes.length),
        2048,
      );

      adapter.stopPlaybackKeepAlive();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await expectLater(
        client.getUrl(Uri.parse(prepared.url)),
        throwsA(isA<SocketException>()),
      );
      client.close(force: true);
    } finally {
      adapter.stopPlaybackKeepAlive();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
