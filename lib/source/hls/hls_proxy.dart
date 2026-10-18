import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:baka/source/hls/hls_ts_prefix.dart';
import 'package:baka/source/runtime/source_operation.dart';

typedef HlsTargetFetch =
    Future<Response<ResponseBody>> Function(
      Uri uri,
      String method,
      Map<String, String> headers,
    );

/// Loopback server for one materialized VOD manifest. Segments, keys and init
/// maps are forwarded through [HlsTargetFetch], so playback keeps the rule's
/// headers, cookies and proxy policy.
class HlsProxy {
  HlsProxy._(
    this._server,
    this._secret,
    this._manifest,
    this._targets,
    this._headers,
    this._fetch,
    this._stripTsPrefix,
  ) {
    // Requests inherit the proxy scope, not the completed preparation budget.
    _subscription = _server.listen(
      (request) => unawaited(
        _operation.run(() => _serve(request)).catchError((Object _) {}),
      ),
    );
  }

  static final RegExp _uriAttribute = RegExp(r'URI="([^"]+)"');

  static const _forwardedRequestHeaders = [
    HttpHeaders.rangeHeader,
    HttpHeaders.ifRangeHeader,
    HttpHeaders.ifModifiedSinceHeader,
    HttpHeaders.ifNoneMatchHeader,
  ];

  static const _forwardedResponseHeaders = [
    HttpHeaders.contentTypeHeader,
    HttpHeaders.contentLengthHeader,
    HttpHeaders.contentRangeHeader,
    HttpHeaders.acceptRangesHeader,
    HttpHeaders.cacheControlHeader,
    HttpHeaders.etagHeader,
    HttpHeaders.lastModifiedHeader,
  ];

  /// Byte-offset headers that no longer describe a body with its prefix removed.
  static const _offsetHeaders = {
    HttpHeaders.contentLengthHeader,
    HttpHeaders.contentRangeHeader,
    HttpHeaders.acceptRangesHeader,
    HttpHeaders.etagHeader,
    HttpHeaders.lastModifiedHeader,
  };

  final HttpServer _server;
  final String _secret;
  final String _manifest;
  final List<({Uri uri, bool isSegment})> _targets;
  final Map<String, String> _headers;
  final HlsTargetFetch _fetch;
  final bool _stripTsPrefix;
  final SourceOperation _operation = SourceOperation();
  late final StreamSubscription<HttpRequest> _subscription;
  Future<void>? _closing;

  String get url =>
      'http://${_server.address.address}:${_server.port}/$_secret/manifest.m3u8';

  static Future<HlsProxy> start(
    String body,
    Uri manifestUri, {
    required Map<String, String> headers,
    required bool stripTsPrefix,
    required HlsTargetFetch fetch,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final secret = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final base =
          'http://${server.address.address}:${server.port}/$secret/media/';
      final targets = <({Uri uri, bool isSegment}), int>{};
      String proxied(Uri uri, {required bool isSegment}) =>
          '$base${targets.putIfAbsent((uri: uri, isSegment: isSegment), () => targets.length).toRadixString(36)}';

      final manifest = StringBuffer();
      var first = true;
      for (final line in LineSplitter.split(body)) {
        if (!first) manifest.write('\n');
        first = false;
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        manifest.write(
          trimmed.startsWith('#')
              ? line.replaceAllMapped(
                  _uriAttribute,
                  (m) =>
                      'URI="${proxied(manifestUri.resolve(m.group(1)!), isSegment: false)}"',
                )
              : proxied(manifestUri.resolve(trimmed), isSegment: true),
        );
      }
      if (body.endsWith('\n') || body.endsWith('\r')) manifest.write('\n');
      final text = manifest.toString();
      if (!text.contains('#EXTM3U') || !text.contains('#EXT-X-ENDLIST')) {
        throw const FormatException('incomplete VOD manifest');
      }
      return HlsProxy._(
        server,
        secret,
        text,
        targets.keys.toList(growable: false),
        headers,
        fetch,
        stripTsPrefix,
      );
    } catch (_) {
      await server.close(force: true);
      rethrow;
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _operation.cancel();
    try {
      await _subscription.cancel();
    } finally {
      try {
        await _server.close(force: true);
      } finally {
        _operation.close();
      }
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      final path = request.uri.pathSegments;
      if (path.length == 2 &&
          path[0] == _secret &&
          path[1] == 'manifest.m3u8') {
        response.headers
          ..contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
            charset: 'utf-8',
          )
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        response.write(_manifest);
        await response.close();
        return;
      }
      final id = path.length == 3 && path[0] == _secret && path[1] == 'media'
          ? int.tryParse(path[2], radix: 36)
          : null;
      if (id == null || id < 0 || id >= _targets.length) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final target = _targets[id];
      final strip = _stripTsPrefix && target.isSegment;
      final headers = Map<String, String>.of(_headers);
      for (final name in _forwardedRequestHeaders) {
        // Prefix removal changes byte offsets and validators. A full 200 body
        // is valid for a Range request; keys and init maps keep normal ranges.
        if (strip) {
          headers.removeWhere((key, _) => key.toLowerCase() == name);
          continue;
        }
        final value = request.headers.value(name);
        if (value != null && value.isNotEmpty) headers[name] = value;
      }
      final isHead = request.method == 'HEAD';
      final remote = await _fetch(target.uri, isHead ? 'HEAD' : 'GET', headers);
      response.statusCode = remote.statusCode ?? HttpStatus.badGateway;
      for (final name in _forwardedResponseHeaders) {
        if (strip && _offsetHeaders.contains(name)) continue;
        final value = remote.headers.value(name);
        if (value != null && value.isNotEmpty) {
          response.headers.set(name, value);
        }
      }
      final stream = remote.data?.stream;
      if (stream != null) {
        if (isHead) {
          await stream.listen(null, onError: (Object _) {}).cancel();
        } else if (strip && remote.statusCode == HttpStatus.ok) {
          await _addStrippedSegment(response, stream);
        } else {
          await response.addStream(stream);
        }
      }
      await response.close();
    } catch (error) {
      try {
        response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
      debugPrint('HLS proxy request failed: $error');
    }
  }

  static Future<void> _addStrippedSegment(
    HttpResponse response,
    Stream<Uint8List> stream,
  ) async {
    final chunks = StreamIterator(
      HlsTsPrefix.strip(
        stream,
        onTransportStream: (_) =>
            response.headers.contentType = ContentType('video', 'mp2t'),
      ),
    );
    try {
      // addStream freezes response headers, so inspect the prefix first.
      if (!await chunks.moveNext()) return;
      Stream<Uint8List> remaining() async* {
        yield chunks.current;
        while (await chunks.moveNext()) {
          yield chunks.current;
        }
      }

      await response.addStream(remaining());
    } finally {
      await chunks.cancel();
    }
  }
}
