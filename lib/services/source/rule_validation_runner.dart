import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baka/models/ai_rule_authoring.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/source/site_probe_service.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/source_adapter.dart';
import 'package:dio/dio.dart';

class RuleValidationRunner {
  bool _disposed = false;
  final Set<SourceAdapter> _activeAdapters = {};

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final adapter in _activeAdapters) {
      adapter.dispose();
    }
    _activeAdapters.clear();
  }

  Future<RuleValidationReport> validate(
    CustomSourceConfig config, {
    required String keyword,
    String? preferredSeriesId,
    String? preferredEpisodeId,
  }) async {
    if (_disposed) throw StateError('RuleValidationRunner is disposed');
    SourceAdapter? adapter;
    var stage = 'static';
    var seriesCount = 0;
    var lineCount = 0;
    var episodeCount = 0;
    try {
      if (!config.hasPipeline) throw StateError('缺少 anx-rule/2 pipeline');
      final rule = config.rule;
      final validation = RuleValidator.validate(rule);
      if (!validation.isValid) {
        throw FormatException(validation.errors.join('；'));
      }
      adapter = SourceAdapter(rule);
      _activeAdapters.add(adapter);

      stage = 'search';
      final results = await adapter.search(keyword, enhanceWithBgm: false);
      seriesCount = results.length;
      if (results.isEmpty) throw StateError('搜索没有返回任何结果');
      final series = preferredSeriesId == null
          ? results.first
          : results.firstWhere(
              (item) => item.seriesId == preferredSeriesId,
              orElse: () => throw StateError('搜索结果不包含指定剧集'),
            );

      stage = 'detail';
      final catalog = await adapter.getPlaybackCatalog(series.seriesId);
      lineCount = catalog.sourceNames.length;
      episodeCount = catalog.episodes.length;
      if (catalog.isEmpty) throw StateError('详情页没有提取到剧集或播放线路');
      String? episodeToken;
      outer:
      for (final episode in catalog.episodes) {
        for (final token in episode.lines) {
          if (preferredEpisodeId == null
              ? token.isNotEmpty
              : token == preferredEpisodeId) {
            episodeToken = token;
            break outer;
          }
        }
      }
      if (episodeToken == null) {
        throw StateError(
          preferredEpisodeId == null
              ? '剧集列表中没有可解析的线路 token'
              : '剧集列表不包含指定线路 token',
        );
      }

      stage = 'play';
      final resolved = await adapter.resolvePlaybackMedia(
        episodeToken,
        skipValidation: true,
      );
      if (resolved.url.isEmpty) throw StateError('播放管线没有得到媒体地址');
      final prepared = await adapter.preparePlaybackMedia(resolved);

      stage = 'media';
      // Reuse the source's cookies, proxy policy and cancellation lifetime.
      final source = adapter;
      final mediaKind = await source.runOperation(
        () => _verifyMedia(source.dio, prepared.url, prepared.httpHeaders),
      );
      return RuleValidationReport(
        success: true,
        stage: stage,
        message: '搜索、详情、播放解析和实际媒体读取均通过',
        seriesCount: seriesCount,
        lineCount: lineCount,
        episodeCount: episodeCount,
        mediaKind: mediaKind,
      );
    } catch (error) {
      return RuleValidationReport(
        success: false,
        stage: stage,
        message: SiteProbeService.safeError(error),
        seriesCount: seriesCount,
        lineCount: lineCount,
        episodeCount: episodeCount,
      );
    } finally {
      _activeAdapters.remove(adapter);
      adapter?.dispose();
    }
  }

  static Future<String> _verifyMedia(
    Dio client,
    String url,
    Map<String, String> headers,
  ) async {
    var uri = Uri.parse(url);
    var segment = false;
    // RFC 8216: optional master playlist -> media playlist -> media segment.
    for (var depth = 0; ; depth++) {
      final cancel = CancelToken();
      StreamIterator<Uint8List>? chunks;
      try {
        final response = await client.getUri<ResponseBody>(
          uri,
          cancelToken: cancel,
          options: Options(
            headers: segment
                ? {...headers, HttpHeaders.rangeHeader: 'bytes=0-1023'}
                : headers,
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(seconds: 12),
            extra: const {RetryInterceptor.skipRetryKey: true},
          ),
        );
        chunks = StreamIterator(response.data!.stream);
        for (final redirect in response.redirects) {
          uri = uri.resolveUri(redirect.location);
        }
        if (response.statusCode != HttpStatus.ok &&
            response.statusCode != HttpStatus.partialContent) {
          throw StateError('媒体请求失败（HTTP ${response.statusCode}）');
        }
        final contentType = response.headers
            .value(HttpHeaders.contentTypeHeader)
            ?.split(';')
            .first
            .toLowerCase();
        if (contentType == 'text/html' || contentType == 'application/json') {
          throw StateError('媒体请求返回了 $contentType');
        }

        // Only sniff the signature; never buffer a video when Range is ignored.
        final prefix = BytesBuilder(copy: false);
        while (prefix.length < 7 && await chunks.moveNext()) {
          prefix.add(chunks.current);
        }
        if (prefix.isEmpty) throw StateError('媒体响应为空');
        if (segment) return 'hls-segment';
        final bytes = prefix.takeBytes();
        final signature = ascii.decode(
          Uint8List.sublistView(bytes, 0, bytes.length < 7 ? bytes.length : 7),
          allowInvalid: true,
        );
        if (depth == 0 &&
            signature != '#EXTM3U' &&
            !uri.path.toLowerCase().endsWith('.m3u8') &&
            !(contentType?.contains('mpegurl') ?? false)) {
          return 'file';
        }

        // Bound even a malformed, newline-free manifest. The parser stops at
        // the first URI, so long playlists don't become retained strings/lists.
        final iterator = chunks;
        Stream<List<int>> manifestBytes() async* {
          var length = 0;
          var chunk = bytes;
          do {
            length += chunk.length;
            if (length > 1024 * 1024) throw StateError('HLS 清单前缀超过 1 MiB');
            yield chunk;
            if (!await iterator.moveNext()) break;
            chunk = iterator.current;
          } while (true);
        }

        var firstLine = true;
        var master = false;
        Uri? next;
        await for (final line
            in manifestBytes()
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          if (firstLine) {
            firstLine = false;
            if (line != '#EXTM3U') throw StateError('HLS 响应不是有效清单');
          } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
            master = true;
          } else if (line.isNotEmpty && !line.startsWith('#')) {
            next = uri.resolve(line);
            break;
          }
        }
        if (next == null) throw StateError('HLS 清单没有可读取的变体或分片');
        if (master && depth != 0) throw StateError('HLS 变体必须是媒体清单');
        uri = next;
        segment = !master;
      } finally {
        cancel.cancel();
        await chunks?.cancel();
      }
    }
  }
}
