import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

typedef HlsSeekSessionFactory =
    Future<HlsSeekSession?> Function(String uri, Map<String, String> headers);

abstract interface class HlsSeekSession {
  ({String uri, Duration timelineOffset}) openFor(Duration target);

  Future<void> dispose();
}

/// Reopens a VOD HLS stream at a segment boundary instead of asking FFmpeg's
/// HLS demuxer to seek in-place. This avoids an FFmpeg 6 fMP4 seek failure
/// where the target segment plays but the following segment is reported as
/// EOF.
class LoopbackHlsSeekSession implements HlsSeekSession {
  LoopbackHlsSeekSession._(
    this._server,
    this._subscription,
    this._secret,
    this._vodManifest,
    this._segmentStarts,
  );

  static final RegExp _uriAttribute = RegExp(r'URI="([^"]+)"');

  final HttpServer _server;
  final StreamSubscription<HttpRequest> _subscription;
  final String _secret;
  final String _vodManifest;
  final List<Duration> _segmentStarts;
  int _generation = 0;

  static Future<HlsSeekSession?> start(
    String uri,
    Map<String, String> headers,
  ) async {
    final manifestUri = Uri.tryParse(uri);
    if (manifestUri == null || !manifestUri.hasScheme) return null;

    final dio = Dio();
    try {
      final response = await dio.getUri<String>(
        manifestUri,
        options: Options(
          headers: headers,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      final body = response.data ?? '';
      final status = response.statusCode ?? 0;
      if (status < 200 ||
          status >= 300 ||
          !body.trimLeft().startsWith('#EXTM3U') ||
          !body.contains('#EXT-X-ENDLIST') ||
          !body.contains('#EXTINF:')) {
        return null;
      }

      final vodManifest = absolutizeManifest(body, manifestUri);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final secret = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      late final LoopbackHlsSeekSession session;
      final subscription = server.listen(
        (request) => unawaited(session._handle(request)),
      );
      session = LoopbackHlsSeekSession._(
        server,
        subscription,
        secret,
        vodManifest,
        segmentStarts(body),
      );
      return session;
    } catch (error) {
      debugPrint('Unable to prepare HLS seek session: $error');
      return null;
    } finally {
      dio.close(force: true);
    }
  }

  @override
  ({String uri, Duration timelineOffset}) openFor(Duration target) {
    final generation = (++_generation).toRadixString(36);
    var segmentIndex = 0;
    var offset = Duration.zero;
    for (var i = 0; i < _segmentStarts.length; i++) {
      final start = _segmentStarts[i];
      if (start > target) break;
      segmentIndex = i;
      offset = start;
    }
    return (
      uri:
          'http://${_server.address.address}:${_server.port}/$_secret/'
          'manifest.m3u8?segment=$segmentIndex&g=$generation',
      timelineOffset: offset,
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      if (segments.length != 2 ||
          segments[0] != _secret ||
          segments[1] != 'manifest.m3u8') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final segmentIndex =
          int.tryParse(request.uri.queryParameters['segment'] ?? '') ?? 0;
      final manifest = buildTruncatedManifest(_vodManifest, segmentIndex);

      final bytes = utf8.encode(manifest);
      response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
        charset: 'utf-8',
      );
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.contentLength = bytes.length;
      if (request.method != 'HEAD') response.add(bytes);
      await response.close();
    } catch (error) {
      debugPrint('HLS seek manifest request failed: $error');
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    }
  }

  @visibleForTesting
  static String absolutizeManifest(String body, Uri manifestUri) {
    return body
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return '';
          if (!trimmed.startsWith('#')) {
            return manifestUri.resolve(trimmed).toString();
          }
          return line.replaceAllMapped(_uriAttribute, (match) {
            return 'URI="${manifestUri.resolve(match.group(1)!).toString()}"';
          });
        })
        .join('\n');
  }

  @visibleForTesting
  static String buildTruncatedManifest(String vodManifest, int segmentIndex) {
    final lines = vodManifest.replaceAll('\r\n', '\n').split('\n');
    final segmentLines = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXTINF:')) segmentLines.add(i);
    }
    if (segmentLines.isEmpty) return vodManifest;

    final index = segmentIndex.clamp(0, segmentLines.length - 1);
    final firstSegmentLine = segmentLines.first;
    final targetLine = segmentLines[index];
    final header = lines
        .sublist(0, firstSegmentLine)
        .where((line) => !line.startsWith('#EXT-X-START:'))
        .toList();

    var hasMediaSequence = false;
    for (var i = 0; i < header.length; i++) {
      if (!header[i].startsWith('#EXT-X-MEDIA-SEQUENCE:')) continue;
      hasMediaSequence = true;
      final original = int.tryParse(header[i].split(':').last) ?? 0;
      header[i] = '#EXT-X-MEDIA-SEQUENCE:${original + index}';
    }
    if (!hasMediaSequence) {
      header.add('#EXT-X-MEDIA-SEQUENCE:$index');
    }

    // Preserve the latest encryption/init declarations when a playlist
    // changes them between segments.
    final activeTags = <String, String>{};
    for (final line in lines.sublist(firstSegmentLine, targetLine)) {
      if (line.startsWith('#EXT-X-KEY:')) activeTags['key'] = line;
      if (line.startsWith('#EXT-X-MAP:')) activeTags['map'] = line;
    }
    header.addAll(activeTags.values);
    return '${[...header, ...lines.sublist(targetLine)].join('\n')}\n';
  }

  @visibleForTesting
  static List<Duration> segmentStarts(String manifest) {
    final result = <Duration>[];
    var elapsedMicroseconds = 0;
    for (final line in manifest.replaceAll('\r\n', '\n').split('\n')) {
      if (!line.startsWith('#EXTINF:')) continue;
      result.add(Duration(microseconds: elapsedMicroseconds));
      final end = line.indexOf(',', '#EXTINF:'.length);
      final value = line.substring(
        '#EXTINF:'.length,
        end < 0 ? line.length : end,
      );
      final seconds = double.tryParse(value) ?? 0;
      elapsedMicroseconds += (seconds * Duration.microsecondsPerSecond).round();
    }
    return List<Duration>.unmodifiable(result);
  }

  @override
  Future<void> dispose() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }
}
