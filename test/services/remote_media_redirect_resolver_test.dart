import 'dart:io';

import 'package:baka/services/remote_media_redirect_resolver.dart';
import 'package:baka/source/model/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolves redirects without proxying the media body', () async {
    final entry = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final resolver = RemoteMediaRedirectResolver();
    var finalRequests = 0;
    final entrySubscription = entry.listen((request) async {
      expect(request.method, 'HEAD');
      expect(
        request.headers.value(HttpHeaders.refererHeader),
        'https://source/',
      );
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${target.port}/video.mp4',
        );
      await request.response.close();
    });
    final targetSubscription = target.listen((request) async {
      expect(request.method, 'HEAD');
      expect(request.headers.value(HttpHeaders.refererHeader), isNull);
      finalRequests++;
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = 1024;
      await request.response.close();
    });

    try {
      final finalUrl = await resolver.resolve(
        'http://127.0.0.1:${entry.port}/redirect',
        headers: const {HttpHeaders.refererHeader: 'https://source/'},
      );

      expect(finalUrl, 'http://127.0.0.1:${target.port}/video.mp4');
      expect(finalRequests, 1);
    } finally {
      resolver.close();
      await entrySubscription.cancel();
      await targetSubscription.cancel();
      await entry.close(force: true);
      await target.close(force: true);
    }
  });

  test('leaves non-http media untouched', () async {
    final resolver = RemoteMediaRedirectResolver();
    addTearDown(resolver.close);

    expect(
      await resolver.resolve('magnet:?xt=urn:btih:test'),
      startsWith('magnet:'),
    );
  });

  test('pipeline redirect flag prepares the final player URL', () async {
    final entry = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final entrySubscription = entry.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.refererHeader),
        'https://source/',
      );
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${target.port}/video.mp4',
        );
      await request.response.close();
    });
    final targetSubscription = target.listen((request) async {
      expect(request.headers.value(HttpHeaders.refererHeader), isNull);
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = 1024;
      await request.response.close();
    });
    final adapter = PipelineSourceAdapter(
      SourceRule(
        id: 'redirect-test',
        name: 'Redirect test',
        baseUrl: 'http://127.0.0.1:${entry.port}',
        play: const [
          PipelineStep('noop', {'resolveMediaRedirects': true}),
        ],
      ),
    );

    try {
      final prepared = await adapter.preparePlaybackMedia((
        url: 'http://127.0.0.1:${entry.port}/redirect',
        httpHeaders: const {HttpHeaders.refererHeader: 'https://source/'},
      ));

      expect(prepared.url, 'http://127.0.0.1:${target.port}/video.mp4');
      expect(prepared.httpHeaders, isNot(contains(HttpHeaders.refererHeader)));
    } finally {
      adapter.dispose();
      await entrySubscription.cancel();
      await targetSubscription.cancel();
      await entry.close(force: true);
      await target.close(force: true);
    }
  });

  test('xifanacg legacy rule without the flag still resolves redirects',
      () async {
    final entry = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final entrySubscription = entry.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.refererHeader),
        'https://source/',
      );
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${target.port}/video.mp4',
        );
      await request.response.close();
    });
    final targetSubscription = target.listen((request) async {
      expect(request.headers.value(HttpHeaders.refererHeader), isNull);
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = 1024;
      await request.response.close();
    });
    // 早期已安装副本的 play 步骤没有 resolveMediaRedirects flag，按 id 兜底。
    final adapter = PipelineSourceAdapter(
      SourceRule(
        id: 'xifanacg',
        name: 'Xifanacg',
        baseUrl: 'http://127.0.0.1:${entry.port}',
        play: const [
          PipelineStep('noop', <String, dynamic>{}),
        ],
      ),
    );

    try {
      final prepared = await adapter.preparePlaybackMedia((
        url: 'http://127.0.0.1:${entry.port}/redirect',
        httpHeaders: const {HttpHeaders.refererHeader: 'https://source/'},
      ));

      expect(prepared.url, 'http://127.0.0.1:${target.port}/video.mp4');
      expect(prepared.httpHeaders, isNot(contains(HttpHeaders.refererHeader)));
    } finally {
      adapter.dispose();
      await entrySubscription.cancel();
      await targetSubscription.cancel();
      await entry.close(force: true);
      await target.close(force: true);
    }
  });
}
