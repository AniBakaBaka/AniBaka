import 'dart:io';

import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:flutter_test/flutter_test.dart';

class _DirectUrlAdapter extends AdapterBase {
  _DirectUrlAdapter(this.mediaUrl, String name) : super(name);

  final String mediaUrl;

  @override
  String get baseUrl => mediaUrl;

  @override
  Future<String> getDownloadUrl(String episodeId) async => mediaUrl;

  @override
  Future<List<Source>> getSources(String seriesId) async => const [];

  @override
  Future<List<Series>> search(
    String bangumiName,
    String searchKeyword, {
    bool enhanceWithBgm = true,
  }) async => const [];
}

void main() {
  test('range GET confirms a playable URL when HEAD is rejected', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    var headRequests = 0;
    var getRequests = 0;
    server.listen((request) async {
      if (request.method == 'HEAD') {
        headRequests++;
        request.response.statusCode = HttpStatus.forbidden;
      } else {
        getRequests++;
        expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=0-0');
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.contentType = ContentType('video', 'mp4')
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/1')
          ..add([0]);
      }
      await request.response.close();
    });

    final url = 'http://${server.address.address}:${server.port}/孤独摇滚/01.mp4';
    final adapter = _DirectUrlAdapter(
      url,
      'head-fallback-${DateTime.now().microsecondsSinceEpoch}',
    );

    expect(await adapter.resolveDownloadUrl('episode'), url);
    expect(headRequests, 1);
    expect(getRequests, 1);
  });

  test('range GET rejection still blocks an invalid URL', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    server.listen((request) async {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
    });

    final url = 'http://${server.address.address}:${server.port}/missing.mp4';
    final adapter = _DirectUrlAdapter(
      url,
      'blocked-${DateTime.now().microsecondsSinceEpoch}',
    );

    expect(await adapter.resolveDownloadUrl('episode'), isEmpty);
  });
}
