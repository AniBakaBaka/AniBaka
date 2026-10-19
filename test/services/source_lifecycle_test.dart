import 'dart:async';
import 'dart:io';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/source_adapter.dart';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/ts_prefix_fixtures.dart';

const _manifest =
    '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n';
SourceAdapter _adapter(
  String base, {
  bool redirects = false,
  bool proxyMedia = false,
}) => SourceAdapter(
  SourceRule(
    id: 'lifecycle',
    name: 'Lifecycle',
    baseUrl: base,
    directConnection: true,
    play: [
      PipelineStep('template', {
        'value': '{episodeId:raw}',
        'materializeHls': !proxyMedia,
        'proxyMedia': proxyMedia,
        'resolveMediaRedirects': redirects,
      }),
    ],
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
  });

  test(
    'proxied files stream on demand and retain Range, HEAD and headers',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      final requests = <({String method, String? range, String? referer})>[];
      server.listen((request) async {
        requests.add((
          method: request.method,
          range: request.headers.value('range'),
          referer: request.headers.value('referer'),
        ));
        final response = request.response;
        response.headers
          ..contentType = ContentType('video', 'mp4')
          ..set('accept-ranges', 'bytes');
        if (request.headers.value('range') == 'bytes=2-5') {
          response.statusCode = 206;
          response.headers.set('content-range', 'bytes 2-5/10');
          response.contentLength = 4;
          response.add([2, 3, 4, 5]);
        } else {
          response.contentLength = 10;
          if (request.method != 'HEAD') {
            response.add(List.generate(10, (i) => i));
          }
        }
        await response.close();
      });
      final adapter = _adapter(base, proxyMedia: true);
      final dio = Dio();
      addTearDown(() async {
        adapter.dispose();
        dio.close(force: true);
        await server.close(force: true);
      });
      final media = await adapter.preparePlaybackMedia((
        url: '$base/episode.mp4',
        httpHeaders: {'Referer': '$base/player/'},
      ));
      expect(requests, isEmpty);
      expect(media.httpHeaders, isEmpty);

      final head = await dio.head<void>(media.url);
      expect(head.headers.value('content-length'), '10');
      final part = await dio.get<List<int>>(
        media.url,
        options: Options(
          headers: {'Range': 'bytes=2-5'},
          responseType: ResponseType.bytes,
        ),
      );
      expect(part.statusCode, 206);
      expect(part.headers.value('content-range'), 'bytes 2-5/10');
      expect(part.headers.value('content-type'), 'video/mp4');
      expect(part.data, [2, 3, 4, 5]);
      expect(requests.map((r) => r.method), ['HEAD', 'GET']);
      expect(requests.last.range, 'bytes=2-5');
      expect(requests.every((r) => r.referer == '$base/player/'), isTrue);

      final next = await adapter.preparePlaybackMedia((
        url: '$base/next.mp4',
        httpHeaders: const {},
      ));
      await expectLater(
        dio.head<void>(media.url),
        throwsA(isA<DioException>()),
      );
      adapter.dispose();
      await expectLater(dio.head<void>(next.url), throwsA(isA<DioException>()));
    },
  );

  test('late A cannot replace B proxy or its media headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    final aStarted = Completer<void>();
    final releaseA = Completer<void>();
    server.listen((request) async {
      if (request.uri.path == '/a.m3u8') {
        aStarted.complete();
        await releaseA.future;
      }
      try {
        request.response.write(
          request.uri.path.endsWith('.m3u8')
              ? _manifest
              : request.headers.value('X-Episode'),
        );
        await request.response.close();
      } catch (_) {}
    });
    final adapter = _adapter(base, proxyMedia: true);
    final dio = Dio();
    addTearDown(() async {
      adapter.dispose();
      dio.close(force: true);
      await server.close(force: true);
    });
    final a = adapter.preparePlaybackMedia((
      url: '$base/a.m3u8',
      httpHeaders: const {'X-Episode': 'A'},
    ), filterHlsAds: false);
    final rejected = expectLater(a, throwsA(isA<RequestCancelledException>()));
    await aStarted.future;
    final b = await adapter.preparePlaybackMedia((
      url: '$base/b.m3u8',
      httpHeaders: const {'X-Episode': 'B'},
    ), filterHlsAds: false);
    releaseA.complete();
    await rejected;
    final text = (await dio.get<String>(b.url)).data!;
    final segment = text
        .split('\n')
        .firstWhere((line) => line.startsWith('http'));
    expect((await dio.get<String>(segment)).data, 'B');
    adapter.dispose();
    await expectLater(dio.get<String>(b.url), throwsA(isA<DioException>()));
  });

  test(
    'disposing during preparation cancels HTTP and cannot install a server',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      final release = Completer<void>();
      server.listen((request) async {
        started.complete();
        await release.future;
        try {
          request.response.write(_manifest);
          await request.response.close();
        } catch (_) {}
      });
      final adapter = _adapter('http://127.0.0.1:${server.port}');
      addTearDown(() => server.close(force: true));
      final work = adapter.preparePlaybackMedia((
        url: '${adapter.baseUrl}/slow.m3u8',
        httpHeaders: const {},
      ), filterHlsAds: false);
      final failure = expectLater(
        work,
        throwsA(isA<RequestCancelledException>()),
      );
      await started.future;
      adapter.dispose();
      release.complete();
      await failure;
      await expectLater(
        adapter.preparePlaybackMedia((
          url: '${adapter.baseUrl}/next.m3u8',
          httpHeaders: const {},
        )),
        throwsA(isA<RequestCancelledException>()),
      );
    },
  );

  test('same-origin redirect keeps credentials for player GET', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    final methods = <String>[];
    server.listen((request) async {
      if (request.uri.path == '/entry') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/video.mp4');
      } else {
        methods.add(request.method);
        request.response.statusCode =
            request.headers.value('Cookie') == 'token=1' ? 200 : 403;
        if (request.method != 'HEAD') request.response.write('video');
      }
      await request.response.close();
    });
    final adapter = _adapter(base, redirects: true);
    final dio = Dio();
    addTearDown(() async {
      adapter.dispose();
      dio.close(force: true);
      await server.close(force: true);
    });
    final media = await adapter.preparePlaybackMedia((
      url: '$base/entry',
      httpHeaders: const {'Cookie': 'token=1'},
    ), filterHlsAds: false);
    expect(media.url, '$base/video.mp4');
    expect(
      (await dio.get<String>(
        media.url,
        options: Options(headers: media.httpHeaders),
      )).statusCode,
      200,
    );
    expect(methods, ['HEAD', 'GET']);
  });

  test(
    'explicit cancellation stops an in-flight fetch without a retry',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      var requests = 0;
      server.listen((request) {
        requests++;
        if (!started.isCompleted) started.complete();
      });
      final adapter = _adapter('http://127.0.0.1:${server.port}');
      final operation = SourceOperation();
      addTearDown(() async {
        operation.close();
        adapter.dispose();
        await server.close(force: true);
      });
      final work = operation.run(
        () => adapter.fetch('${adapter.baseUrl}/slow'),
      );
      final failure = expectLater(
        work,
        throwsA(isA<RequestCancelledException>()),
      );
      await started.future;
      operation.cancel();
      await failure;
      expect(requests, 1);
    },
  );

  test(
    'image-named HLS serves clean TS and preserves key byte ranges',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      final wrapped = [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        ...List.filled(459, 0),
        ...contentPrefixBytes,
      ];
      final requests = <({String path, String? range, String? referer})>[];
      server.listen((request) async {
        requests.add((
          path: request.uri.path,
          range: request.headers.value('range'),
          referer: request.headers.value('referer'),
        ));
        final response = request.response;
        response.headers.contentType = ContentType('image', 'webp');
        if (request.uri.path.startsWith('/index/listres/')) {
          response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:4\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="$base/key.bin"\n'
            '#EXTINF:4,\n$base/segment.webp\n#EXT-X-ENDLIST\n',
          );
        } else if (request.uri.path == '/key.bin') {
          response.statusCode = 206;
          response.headers.set('content-range', 'bytes 2-5/16');
          response.add([2, 3, 4, 5]);
        } else {
          response.contentLength = wrapped.length;
          response.headers.set('etag', 'original-image');
          response.add(wrapped);
        }
        await response.close();
      });
      final adapter = SourceAdapter(
        SourceRule(
          id: 'wrapped-ts',
          name: 'Wrapped TS',
          baseUrl: base,
          directConnection: true,
          play: [
            const PipelineStep('template', {
              'value': '{episodeId:raw}',
              'stripHlsTsPrefix': true,
            }),
          ],
        ),
      );
      final dio = Dio();
      addTearDown(() async {
        adapter.dispose();
        dio.close(force: true);
        await server.close(force: true);
      });
      final media = await adapter.preparePlaybackMedia((
        url: '$base/index/listres/sample.webp?user=guest',
        httpHeaders: {'Referer': '$base/player/'},
      ), filterHlsAds: false);
      expect(media.url, endsWith('/manifest.m3u8'));
      final manifest = (await dio.get<String>(media.url)).data!;
      final segment = manifest
          .split('\n')
          .firstWhere((s) => s.startsWith('http'));
      final key = RegExp(r'URI="([^"]+)"').firstMatch(manifest)!.group(1)!;
      final segmentResponse = await dio.get<List<int>>(
        segment,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Range': 'bytes=10-', 'If-Range': 'original-image'},
        ),
      );
      expect(segmentResponse.statusCode, 200);
      expect(segmentResponse.headers.value('content-type'), 'video/mp2t');
      expect(segmentResponse.headers.value('content-length'), isNull);
      expect(segmentResponse.headers.value('content-range'), isNull);
      expect(segmentResponse.headers.value('etag'), isNull);
      expect(segmentResponse.data, contentPrefixBytes);
      final keyResponse = await dio.get<List<int>>(
        key,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Range': 'bytes=2-5'},
        ),
      );
      expect(keyResponse.statusCode, 206);
      expect(keyResponse.headers.value('content-range'), 'bytes 2-5/16');
      expect(keyResponse.data, [2, 3, 4, 5]);
      expect(
        requests.firstWhere((r) => r.path == '/segment.webp').range,
        isNull,
      );
      expect(
        requests.firstWhere((r) => r.path == '/key.bin').range,
        'bytes=2-5',
      );
      expect(requests.every((r) => r.referer == '$base/player/'), isTrue);
    },
  );
}
