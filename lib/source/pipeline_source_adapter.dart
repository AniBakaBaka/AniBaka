import 'package:baka/source/runtime/source_operation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:cookie_jar/cookie_jar.dart';

import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/hls/hls_ad_filter.dart';
import 'package:baka/source/hls/hls_master_playlist.dart';
import 'package:baka/source/hls/hls_manifest_decoder.dart';
import 'package:baka/source/hls/hls_ts_prefix.dart';
import 'package:baka/source/hls/mpeg_ts_fingerprint.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/source/webview_adapter.dart';
import 'package:baka/source/engine/pipeline_host.dart';
import 'package:baka/source/engine/pipeline_interpreter.dart';
import 'package:baka/source/engine/recipes.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:baka/source/runtime/scheduler_interceptor.dart';
import 'package:baka/core/network_service.dart';
import 'package:baka/api/bgm.dart';

/// Connects a source rule to the adapter and pipeline host contracts.
class PipelineSourceAdapter extends AdapterBase implements PipelineHost {
  PipelineSourceAdapter(SourceRule rule)
    : rule = Recipes.expand(rule),
      super(rule.name);

  final SourceRule rule;
  static const PipelineInterpreter _interpreter = PipelineInterpreter();
  late final CookieJar _cookieJar = CookieJar();
  WebViewTaskScope? _webViewTaskScope;
  RemoteMediaRedirectResolver? _mediaRedirectResolver;
  Future<void>? _playCookieBarrier;
  Timer? _playbackKeepAliveTimer;
  int _playbackKeepAliveGeneration = 0;
  CancelToken? _playbackKeepAliveRequest;
  _HlsSession? _hlsSession;
  SourceOperation? _hlsPreparation;
  int _hlsGeneration = 0;
  late final _playFeatures = _inspectPlayFeatures(rule.play);
  static final RegExp _hlsUriAttrPattern = RegExp(r'URI="([^"]+)"');

  /// HLS 指纹探测只取分片前缀。实测 16 KB 已足够读到 PAT/PMT 与首个 SPS。
  static const int _hlsProbePrefixBytes = 16 * 1024;

  /// 单个分片指纹探测的超时；探不到按「与正片一致」处理，不阻塞播放。
  static const Duration _hlsProbeTimeout = Duration(seconds: 8);

  /// 前缀取够后主动断连的取消理由。
  static const String _hlsProbeCancelReason = 'HLS 指纹探测已取够前缀';

  @override
  String get baseUrl => rule.baseUrl;

  @override
  bool get allowWebview => rule.useWebview;

  @override
  bool get useSystemProxy => !rule.directConnection;

  @override
  Dio createDio() {
    final dio = super.createDio();
    dio.options.headers.addAll(rule.headers);
    dio.interceptors.add(CookieManager(_cookieJar));
    return dio;
  }

  @override
  String get requestUserAgent {
    final ua = (rule.headers['User-Agent'] ?? rule.headers['user-agent'])
        ?.trim();
    return ua != null && ua.isNotEmpty ? ua : super.requestUserAgent;
  }

  @override
  bool get validatesOwnUrls => _playFeatures.validatesWithCookies;

  @override
  Future<MediaReachabilityVerdict> probeMediaReachability(
    String url, {
    Duration? timeout,
    Map<String, String>? headers,
  }) {
    final minimumMs = rule.mediaValidationTimeoutMs;
    final effectiveTimeout = minimumMs > (timeout?.inMilliseconds ?? 0)
        ? Duration(milliseconds: minimumMs)
        : timeout;
    return super.probeMediaReachability(
      url,
      timeout: effectiveTimeout,
      headers: headers,
    );
  }

  @override
  void dispose() {
    _webViewTaskScope?.cancel();
    _mediaRedirectResolver?.close();
    stopPlaybackKeepAlive();
    super.dispose();
  }

  @override
  Map<String, String> get mediaValidationHeaders => _mediaValidationHeaders;

  late final Map<String, String> _mediaValidationHeaders =
      rule.headers.values.every((value) => value.isEmpty)
      ? super.mediaValidationHeaders
      : rule.headers.values.any((value) => value.isEmpty)
      ? Map.unmodifiable({
          for (final entry in rule.headers.entries)
            if (entry.value.isNotEmpty) entry.key: entry.value,
        })
      : rule.headers;

  @override
  Future<List<Series>> search(String query, {bool enhanceWithBgm = true}) =>
      runOperation(() => _search(query, enhanceWithBgm: enhanceWithBgm));

  Future<List<Series>> _search(
    String query, {
    bool enhanceWithBgm = true,
  }) async {
    final series = await _interpreter.runSearch(rule, this, query);
    if (enhanceWithBgm) {
      var next = 0;
      // Five workers keep requests bounded without waiting for each batch's slowest item.
      await Future.wait(
        List.generate(series.length.clamp(0, 5), (_) async {
          while (next < series.length) {
            final item = series[next++];
            try {
              final subject = await resolveBgmSubject(title: item.name);
              SourceOperation.check();
              item.image = subject?.imageUrl ?? item.image;
              item.description = subject?.summary ?? item.description ?? '暂无简介';
              item.bgmId = subject?.subjectId ?? item.bgmId;
              item.score = subject?.score ?? item.score;
            } catch (_) {
              SourceOperation.check();
            }
          }
        }),
      );
    }
    return series;
  }

  @override
  Future<PlaybackCatalog> getPlaybackCatalog(String seriesId) => runOperation(
    () => _interpreter
        .runDetail(rule, this, seriesId)
        .then(PlaybackCatalog.fromSources),
  );

  @override
  Future<String> getDownloadUrl(String episodeId) => runOperation(
    () => _withPlayCookieSnapshot(
      () => _interpreter.runPlay(rule, this, episodeId),
    ),
  );

  @override
  Future<({String url, Map<String, String> httpHeaders})> resolvePlaybackMedia(
    String episodeId, {
    bool skipValidation = false,
    int maxAttempts = 2,
    Duration? reachTimeout,
  }) => runOperation(
    () => _resolvePlaybackMedia(
      episodeId,
      skipValidation: skipValidation,
      maxAttempts: maxAttempts,
      reachTimeout: reachTimeout,
    ),
  );

  Future<({String url, Map<String, String> httpHeaders})> _resolvePlaybackMedia(
    String episodeId, {
    bool skipValidation = false,
    int maxAttempts = 2,
    Duration? reachTimeout,
  }) async {
    if (!_playFeatures.usesDynamicMetadata) {
      return super.resolvePlaybackMedia(
        episodeId,
        skipValidation: skipValidation,
        maxAttempts: maxAttempts,
        reachTimeout: reachTimeout,
      );
    }
    final attempts = maxAttempts < 1 ? 1 : maxAttempts;
    return _withPlayCookieSnapshot(() async {
      for (var attempt = 0; attempt < attempts; attempt++) {
        SourceOperation.check();
        final media = await _interpreter.runPlayMedia(rule, this, episodeId);
        SourceOperation.check();
        if (media.url.isEmpty) {
          debugPrint('$name: 播放管线第 ${attempt + 1}/$attempts 次未得到媒体地址');
          continue;
        }
        final headers = await _resolveMediaHeaders(media);
        SourceOperation.check();
        if (skipValidation) {
          return (url: media.url, httpHeaders: headers);
        }
        final verdict = await probeMediaReachability(
          media.url,
          timeout: reachTimeout,
          headers: headers,
        );
        SourceOperation.check();
        if (verdict == MediaReachabilityVerdict.unknown) {
          debugPrint(
            '$name: 动态媒体结论不确定（超时/临时缺失/网络异常），保留待播放器验证: '
            '${media.url}',
          );
        }
        if (verdict != MediaReachabilityVerdict.rejected) {
          return (url: media.url, httpHeaders: headers);
        }
        debugPrint('$name: 动态媒体被服务器拒绝，丢弃: ${media.url}');
      }
      return (url: '', httpHeaders: const <String, String>{});
    });
  }

  @override
  Future<void> startPlaybackKeepAlive(String mediaUrl) async {
    stopPlaybackKeepAlive();
    final step = _playFeatures.keepAliveStep;
    final mediaUri = Uri.tryParse(mediaUrl);
    if (step == null || mediaUri == null || !mediaUri.hasScheme) return;

    final variables = <String, String>{
      'mediaUrl': mediaUrl,
      ...mediaUri.queryParameters,
    };
    final declaredVariables = step.params['variables'];
    if (declaredVariables is Map) {
      for (final entry in declaredVariables.entries) {
        variables[entry.key.toString()] = PipelineInterpreter.renderTemplate(
          entry.value.toString(),
          (name) => variables[name],
        );
      }
    }

    final urlTemplate = step.str('url')?.trim() ?? '';
    final keepAliveUrl = PipelineInterpreter.renderTemplate(
      urlTemplate,
      (name) => variables[name],
    );
    final keepAliveUri = Uri.tryParse(keepAliveUrl);
    if (keepAliveUri == null || !keepAliveUri.hasScheme) {
      debugPrint('${rule.id}: invalid playback keep-alive URL: $keepAliveUrl');
      return;
    }

    final headers = <String, String>{};
    final rawHeaders = step.params['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = PipelineInterpreter.renderTemplate(
          entry.value.toString(),
          (name) => variables[name],
        );
      }
    }

    final generation = ++_playbackKeepAliveGeneration;
    final expectedBody = step.str('expectedBody')?.trim();
    await _sendPlaybackKeepAlive(
      generation,
      keepAliveUri,
      headers,
      expectedBody,
    );
    if (generation != _playbackKeepAliveGeneration) return;

    final intervalSeconds = (step.intValue('intervalSeconds') ?? 10).clamp(
      1,
      300,
    );
    _playbackKeepAliveTimer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => unawaited(
        _sendPlaybackKeepAlive(generation, keepAliveUri, headers, expectedBody),
      ),
    );
  }

  @override
  Future<({String url, Map<String, String> httpHeaders})> preparePlaybackMedia(
    ({String url, Map<String, String> httpHeaders}) media, {
    bool? filterHlsAds,
    void Function(String message)? onHlsAdFilterStatus,
    void Function(String key)? onTimelinePrepared,
  }) => runOperation(() async {
    final preparation = SourceOperation.current!;
    try {
      return await _preparePlaybackMedia(
        media,
        filterHlsAds: filterHlsAds,
        onHlsAdFilterStatus: onHlsAdFilterStatus,
        onTimelinePrepared: onTimelinePrepared,
      );
    } finally {
      if (identical(_hlsPreparation, preparation)) _hlsPreparation = null;
    }
  });

  Future<({String url, Map<String, String> httpHeaders})> _preparePlaybackMedia(
    ({String url, Map<String, String> httpHeaders}) media, {
    bool? filterHlsAds,
    void Function(String message)? onHlsAdFilterStatus,
    void Function(String key)? onTimelinePrepared,
  }) async {
    final generation = ++_hlsGeneration;
    _hlsPreparation?.cancel();
    final preparation = SourceOperation.current!;
    _hlsPreparation = preparation;
    var prepared = media;
    if (_playFeatures.resolvesMediaRedirects) {
      final resolved =
          await (_mediaRedirectResolver ??= RemoteMediaRedirectResolver(
            useSystemProxy: useSystemProxy,
          )).resolveMedia(media.url, headers: media.httpHeaders);
      SourceOperation.check();
      prepared = resolved;
    }
    if (!VideoUrlExtractor.isHlsUrl(prepared.url)) return prepared;

    final filtersAds =
        filterHlsAds ??
        PlaybackSettingsService.getFilterHlsAdsOverride() ??
        _playFeatures.filtersHlsAds;
    if (!_playFeatures.materializesHls && !filtersAds) {
      return prepared;
    }
    final manifestUri = Uri.tryParse(prepared.url);
    if (manifestUri == null || !manifestUri.hasScheme) return prepared;

    final budget = SourceOperation(
      parent: preparation,
      timeout: filtersAds ? const Duration(seconds: 15) : null,
    );
    try {
      return await budget.run(() async {
        var playlist = await _fetchHlsPlaylist(
          manifestUri,
          prepared.httpHeaders,
        );
        if (!_playlistLooksFetchable(playlist)) {
          debugPrint(
            '${rule.id}: unable to materialize complete HLS manifest '
            '(HTTP ${playlist.status}, ${playlist.body.length} chars)',
          );
          if (filtersAds) {
            onHlsAdFilterStatus?.call(
              'HLS 去广告未生效：清单读取失败（HTTP ${playlist.status}）',
            );
          }
          return prepared;
        }

        // Encrypted masters also need a decoded, materialized media variant.
        if (HlsMasterPlaylist.isMaster(playlist.body)) {
          if (!filtersAds && _playFeatures.hlsManifestDecode == null) {
            debugPrint('${rule.id}: HLS 主清单不做物化（未开启 filterHlsAds）');
            return prepared;
          }
          final variant = HlsMasterPlaylist.selectVariant(
            playlist.body,
            playlist.uri,
          );
          if (variant == null) {
            debugPrint('${rule.id}: HLS 主清单无法选定单一变体，放弃去广告');
            onHlsAdFilterStatus?.call('HLS 去广告未生效：不支持此多码率清单');
            return prepared;
          }
          playlist = await _fetchHlsPlaylist(variant.uri, prepared.httpHeaders);
          if (!_playlistLooksFetchable(playlist)) {
            debugPrint(
              '${rule.id}: unable to materialize HLS variant '
              '(HTTP ${playlist.status}, ${playlist.body.length} chars)',
            );
            onHlsAdFilterStatus?.call(
              'HLS 去广告未生效：分片清单读取失败（HTTP ${playlist.status}）',
            );
            return prepared;
          }
          debugPrint('${rule.id}: HLS 主清单选定变体 ${variant.label}');
        }

        if (!playlist.body.contains('#EXT-X-ENDLIST')) {
          debugPrint(
            '${rule.id}: unable to materialize complete HLS manifest '
            '(直播清单无 #EXT-X-ENDLIST, ${playlist.body.length} chars)',
          );
          if (filtersAds) onHlsAdFilterStatus?.call('HLS 去广告未生效：仅支持完整点播清单');
          return prepared;
        }

        var body = playlist.body;
        HlsAdFilterOutcome? filterOutcome;
        if (filtersAds) {
          final outcome = await HlsAdFilter.apply(
            manifest: body,
            manifestUri: playlist.uri,
            probe: (segmentUri) =>
                _readHlsSegmentFingerprint(segmentUri, prepared.httpHeaders),
          );
          debugPrint('${rule.id}: HLS 去广告 ${outcome.detail}');
          body = outcome.manifest;
          filterOutcome = outcome;
        }

        final proxyUrl = await _startHlsProxy(
          body,
          playlist.uri,
          prepared.httpHeaders,
          generation,
        );
        if (filterOutcome != null) {
          onHlsAdFilterStatus?.call(
            filterOutcome.changed
                ? '已过滤 ${filterOutcome.removedSegments} 个广告分片，'
                      '共 ${filterOutcome.removedSeconds.toStringAsFixed(1)} 秒'
                : 'HLS 去广告：${filterOutcome.detail}',
          );
        }
        onTimelinePrepared?.call(filterOutcome?.timelineKey ?? 'original');
        return (url: proxyUrl, httpHeaders: const <String, String>{});
      });
    } catch (error) {
      preparation.token.throwIfCancelled();
      debugPrint('${rule.id}: HLS manifest materialization failed: $error');
      if (filtersAds) {
        onHlsAdFilterStatus?.call(
          budget.timedOut
              ? 'HLS 去广告超过15秒，已保留原视频'
              : 'HLS 去广告未生效：网络或分片处理失败，已保留原视频',
        );
      }
      return prepared;
    } finally {
      budget.close();
    }
  }

  /// 抓一份 HLS 清单正文。清单地址本身可能 302，分片相对地址要按跳转后的
  /// 地址解析，所以同时返回 [Uri realUri]。
  Future<({String body, Uri uri, int status})> _fetchHlsPlaylist(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final decoder = _playFeatures.hlsManifestDecode;
    if (decoder != null) {
      final response = await dio.getUri<List<int>>(
        uri,
        options: Options(
          headers: headers,
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
          extra: const {SchedulerInterceptor.priorityKey: RequestPriority.play},
        ),
      );
      return (
        body: HlsManifestDecoder.decode(response.data ?? const [], decoder),
        uri: response.realUri,
        status: response.statusCode ?? 0,
      );
    }
    final response = await dio.getUri<String>(
      uri,
      options: Options(
        headers: headers,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
        extra: const {SchedulerInterceptor.priorityKey: RequestPriority.play},
      ),
    );
    return (
      body: response.data ?? '',
      uri: response.realUri,
      status: response.statusCode ?? 0,
    );
  }

  static bool _playlistLooksFetchable(
    ({String body, Uri uri, int status}) playlist,
  ) {
    return playlist.status >= 200 &&
        playlist.status < 300 &&
        playlist.body.startsWith('#EXTM3U');
  }

  /// 只取分片前缀（默认 16 KB）读取编码指纹，供 [HlsAdFilter] 判断某个分片
  /// 是否与正片同一次编码。任何失败都返回 null，调用方按「与正片一致」处理。
  Future<HlsVideoFingerprint?> _readHlsSegmentFingerprint(
    Uri segmentUri,
    Map<String, String> headers,
  ) {
    final cancelToken = CancelToken();
    Future<HlsVideoFingerprint?> read() async {
      final response = await dio.requestUri<ResponseBody>(
        segmentUri,
        cancelToken: cancelToken,
        options: Options(
          headers: {
            ...headers,
            HttpHeaders.rangeHeader: 'bytes=0-${_hlsProbePrefixBytes - 1}',
          },
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          extra: const {SchedulerInterceptor.priorityKey: RequestPriority.play},
        ),
      );
      final status = response.statusCode ?? 0;
      if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
        return null;
      }
      final stream = response.data?.stream;
      if (stream == null) return null;

      final prefix = Uint8List(_hlsProbePrefixBytes);
      var length = 0;
      try {
        await for (final chunk in stream) {
          final remaining = prefix.length - length;
          final count = chunk.length > remaining ? remaining : chunk.length;
          prefix.setRange(length, length + count, chunk);
          length += count;
          // 服务器忽略 Range 时不必把整片读进内存。
          if (length == prefix.length) break;
        }
      } catch (_) {
        // 主动断连可能让流以错误收尾；已经攒到的前缀仍然可用。
      }
      SourceOperation.check();
      return MpegTsFingerprint.read(Uint8List.sublistView(prefix, 0, length));
    }

    return read()
        .timeout(_hlsProbeTimeout, onTimeout: () => null)
        .whenComplete(() {
          // 取够前缀或超时后都断掉连接。取消理由取同一个常量，避免重复取消
          // 触发 CancelToken 的断言。
          cancelToken.cancel(_hlsProbeCancelReason);
        })
        .catchError((Object _) => null);
  }

  @override
  void stopPlaybackKeepAlive() {
    _playbackKeepAliveGeneration++;
    _playbackKeepAliveTimer?.cancel();
    _playbackKeepAliveTimer = null;
    _playbackKeepAliveRequest?.cancel('playback keep-alive stopped');
    _playbackKeepAliveRequest = null;
    _hlsGeneration++;
    _hlsPreparation?.cancel();
    _hlsPreparation = null;
    unawaited(_stopHlsProxy());
  }

  Future<String> _startHlsProxy(
    String body,
    Uri manifestUri,
    Map<String, String> headers,
    int generation,
  ) async {
    SourceOperation.check();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      if (generation != _hlsGeneration ||
          SourceOperation.current!.isCancelled) {
        throw const RequestCancelledException();
      }
      final secret = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final baseUrl = 'http://${server.address.address}:${server.port}/$secret';
      final targetIds = <({Uri uri, bool isSegment}), int>{};

      String proxyUrlFor(Uri uri, {required bool isSegment}) {
        final target = (uri: uri, isSegment: isSegment);
        final id = targetIds.putIfAbsent(target, () => targetIds.length);
        return '$baseUrl/media/${id.toRadixString(36)}';
      }

      final manifest = StringBuffer();
      var firstLine = true;
      for (final line in LineSplitter.split(body)) {
        if (!firstLine) manifest.write('\n');
        firstLine = false;
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (!trimmed.startsWith('#')) {
          manifest.write(
            proxyUrlFor(manifestUri.resolve(trimmed), isSegment: true),
          );
        } else {
          manifest.write(
            line.replaceAllMapped(_hlsUriAttrPattern, (match) {
              final resolved = manifestUri.resolve(match.group(1)!);
              return 'URI="${proxyUrlFor(resolved, isSegment: false)}"';
            }),
          );
        }
      }
      if (body.endsWith('\n') || body.endsWith('\r')) manifest.write('\n');
      final materialized = manifest.toString();
      if (!materialized.contains('#EXTM3U') ||
          !materialized.contains('#EXT-X-ENDLIST')) {
        throw const FormatException('incomplete VOD manifest');
      }

      final session = _HlsSession(
        server,
        targetIds.keys.toList(growable: false),
        Map<String, String>.unmodifiable(headers),
      );
      final previous = _hlsSession;
      _hlsSession = session;
      // Requests inherit the session scope, not the completed preparation budget.
      session.subscription = server.listen((request) {
        unawaited(
          session.operation
              .run(
                () => _handleHlsProxyRequest(
                  request,
                  secret,
                  materialized,
                  session,
                ),
              )
              .catchError((Object _) {}),
        );
      });
      unawaited(previous?.close());
      return '$baseUrl/manifest.m3u8';
    } catch (_) {
      await server.close(force: true);
      rethrow;
    }
  }

  Future<void> _handleHlsProxyRequest(
    HttpRequest request,
    String secret,
    String manifest,
    _HlsSession session,
  ) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      if (segments.length == 2 &&
          segments[0] == secret &&
          segments[1] == 'manifest.m3u8') {
        response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
          charset: 'utf-8',
        );
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.write(manifest);
        await response.close();
        return;
      }

      if (segments.length != 3 ||
          segments[0] != secret ||
          segments[1] != 'media') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final id = int.tryParse(segments[2], radix: 36);
      if (id == null || id < 0 || id >= session.targets.length) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final target = session.targets[id];
      final stripTsPrefix = _playFeatures.stripsHlsTsPrefix && target.isSegment;
      final headers = Map<String, String>.from(session.headers);
      for (final name in const [
        HttpHeaders.rangeHeader,
        HttpHeaders.ifRangeHeader,
        HttpHeaders.ifModifiedSinceHeader,
        HttpHeaders.ifNoneMatchHeader,
      ]) {
        // Prefix removal changes byte offsets and validators. A full 200 body
        // is valid for a Range request; keys and init maps keep normal ranges.
        if (stripTsPrefix) {
          headers.removeWhere((key, _) => key.toLowerCase() == name);
          continue;
        }
        final value = request.headers.value(name);
        if (value != null && value.isNotEmpty) headers[name] = value;
      }
      final remote = await dio.requestUri<ResponseBody>(
        target.uri,
        options: Options(
          extra: const {SchedulerInterceptor.priorityKey: RequestPriority.play},
          method: request.method == 'HEAD' ? 'HEAD' : 'GET',
          headers: headers,
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
        ),
      );
      response.statusCode = remote.statusCode ?? HttpStatus.badGateway;
      for (final name in const [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.cacheControlHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        if (stripTsPrefix &&
            const {
              HttpHeaders.contentLengthHeader,
              HttpHeaders.contentRangeHeader,
              HttpHeaders.acceptRangesHeader,
              HttpHeaders.etagHeader,
              HttpHeaders.lastModifiedHeader,
            }.contains(name)) {
          continue;
        }
        final value = remote.headers.value(name);
        if (value != null && value.isNotEmpty) {
          response.headers.set(name, value);
        }
      }
      final stream = remote.data?.stream;
      if (request.method != 'HEAD' && stream != null) {
        if (stripTsPrefix && remote.statusCode == HttpStatus.ok) {
          final chunks = StreamIterator(
            HlsTsPrefix.strip(
              stream,
              onTransportStream: (_) {
                response.headers.contentType = ContentType('video', 'mp2t');
              },
            ),
          );
          try {
            // addStream freezes response headers, so inspect the prefix first.
            if (await chunks.moveNext()) {
              Stream<Uint8List> remaining() async* {
                yield chunks.current;
                while (await chunks.moveNext()) {
                  yield chunks.current;
                }
              }

              await response.addStream(remaining());
            }
          } finally {
            await chunks.cancel();
          }
        } else {
          await response.addStream(stream);
        }
      }
      if (stream != null && request.method == 'HEAD') {
        await stream.listen(null, onError: (Object _) {}).cancel();
      }
      await response.close();
    } catch (error) {
      try {
        response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
      debugPrint('${rule.id}: HLS proxy request failed: $error');
    }
  }

  Future<void> _stopHlsProxy() async {
    final session = _hlsSession;
    _hlsSession = null;
    await session?.close();
  }

  Future<void> _sendPlaybackKeepAlive(
    int generation,
    Uri url,
    Map<String, String> headers,
    String? expectedBody,
  ) async {
    if (generation != _playbackKeepAliveGeneration ||
        _playbackKeepAliveRequest != null) {
      return;
    }
    final cancelToken = CancelToken();
    _playbackKeepAliveRequest = cancelToken;
    try {
      final response = await dio.getUri<String>(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: headers,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      if (generation != _playbackKeepAliveGeneration) return;
      final status = response.statusCode ?? 0;
      final body = response.data?.trim() ?? '';
      final validBody =
          expectedBody == null || expectedBody.isEmpty || body == expectedBody;
      if (status < 200 || status >= 300 || !validBody) {
        debugPrint(
          '${rule.id}: playback keep-alive rejected '
          '(HTTP $status, body: $body)',
        );
      }
    } catch (error) {
      if (generation == _playbackKeepAliveGeneration) {
        debugPrint('${rule.id}: playback keep-alive failed: $error');
      }
    } finally {
      if (identical(_playbackKeepAliveRequest, cancelToken)) {
        _playbackKeepAliveRequest = null;
      }
    }
  }

  Future<T> _withPlayCookieSnapshot<T>(Future<T> Function() action) async {
    if (!_playFeatures.usesCookies) return action();
    SourceOperation.check();
    final next =
        _playCookieBarrier?.then((_) {
          SourceOperation.check();
          return action();
        }) ??
        Future<T>.sync(action);
    // Keep the barrier ordered even if a queued caller stops waiting early.
    _playCookieBarrier = next.then<void>((_) {}, onError: (Object _) {});
    return SourceOperation.current?.wait(next) ?? next;
  }

  Future<Map<String, String>> _resolveMediaHeaders(
    PipelinePlayResult media,
  ) async {
    final headers = <String, String>{
      for (final entry
          in (media.mediaHeaders.isEmpty ? rule.headers : media.mediaHeaders)
              .entries)
        if (entry.value.isNotEmpty) entry.key: entry.value,
    };
    if (headers.isEmpty) headers.addAll(super.mediaValidationHeaders);
    if (VideoUrlExtractor.isSignedCdnUrl(media.url)) {
      headers.removeWhere((key, _) => key.toLowerCase() == 'referer');
    }
    if (media.cookieNames.isEmpty && media.cookiePrefixes.isEmpty) {
      return headers;
    }

    try {
      final exactNames = media.cookieNames.toSet();
      final cookies = await _cookieJar.loadForRequest(Uri.parse(media.url));
      SourceOperation.check();
      final filtered = <String, String>{};
      for (final cookie in cookies) {
        final allowed =
            exactNames.contains(cookie.name) ||
            media.cookiePrefixes.any(
              (prefix) => prefix.isNotEmpty && cookie.name.startsWith(prefix),
            );
        if (allowed && cookie.value.isNotEmpty) {
          filtered[cookie.name] = cookie.value;
        }
      }
      final cookieHeader = filtered.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');
      if (cookieHeader.isNotEmpty) {
        var cookieKey = 'Cookie';
        for (final key in headers.keys) {
          if (key.toLowerCase() == 'cookie') {
            cookieKey = key;
            break;
          }
        }
        final existing = headers[cookieKey];
        if (existing == null || existing.trim().isEmpty) {
          headers[cookieKey] = cookieHeader;
        } else {
          headers[cookieKey] = '$existing; $cookieHeader';
        }
      }
    } catch (_) {
      SourceOperation.check();
    }
    return headers;
  }

  static ({
    bool usesDynamicMetadata,
    bool usesCookies,
    bool validatesWithCookies,
    bool materializesHls,
    bool stripsHlsTsPrefix,
    bool filtersHlsAds,
    bool resolvesMediaRedirects,
    bool followsEmbeddedPlayer,
    bool usesWebview,
    Map<String, dynamic>? hlsManifestDecode,
    PipelineStep? keepAliveStep,
  })
  _inspectPlayFeatures(List<PipelineStep> steps) {
    var usesDynamicMetadata = false;
    var usesCookies = false;
    var validatesWithCookies = false;
    var materializesHls = false;
    var stripsHlsTsPrefix = false;
    var filtersHlsAds = false;
    var resolvesMediaRedirects = false;
    var followsEmbeddedPlayer = false;
    var usesWebview = false;
    Map<String, dynamic>? hlsManifestDecode;
    PipelineStep? keepAliveStep;

    void inspect(List<PipelineStep> current) {
      for (final step in current) {
        if (step.op == 'setMediaHeaders' || step.op == 'anime1Play') {
          usesDynamicMetadata = true;
        }
        if (step.op == 'anime1Play') usesCookies = true;
        // 播放页会下发一次性播放凭证（cookie/会话）的源，整条 play 管线必须
        // 独占运行：并发解析会互相顶掉凭证（tvtfun 的 tvt-pt 即属此类）。
        usesCookies |= step.flag('cookieSession');
        validatesWithCookies |= step.flag('validateWithCookies');
        materializesHls |= step.flag('materializeHls');
        stripsHlsTsPrefix |= step.flag('stripHlsTsPrefix');
        materializesHls |= stripsHlsTsPrefix;
        final decoder = step.params['hlsManifestDecode'];
        if (hlsManifestDecode == null && decoder is Map) {
          hlsManifestDecode = Map<String, dynamic>.from(decoder);
          materializesHls = true;
        }
        filtersHlsAds |= step.flag('filterHlsAds');
        resolvesMediaRedirects |= step.flag('resolveMediaRedirects');
        followsEmbeddedPlayer |= step.flag('followEmbeddedPlayer');
        usesWebview |= step.op == 'sniff';
        if (keepAliveStep == null && step.flag('playbackKeepAlive')) {
          keepAliveStep = step;
        }
        for (final branch in step.branches) {
          inspect(branch);
        }
      }
    }

    inspect(steps);
    return (
      usesDynamicMetadata: usesDynamicMetadata,
      usesCookies: usesCookies,
      validatesWithCookies: validatesWithCookies,
      materializesHls: materializesHls,
      stripsHlsTsPrefix: stripsHlsTsPrefix,
      filtersHlsAds: filtersHlsAds,
      resolvesMediaRedirects: resolvesMediaRedirects,
      followsEmbeddedPlayer: followsEmbeddedPlayer,
      usesWebview: usesWebview,
      hlsManifestDecode: hlsManifestDecode,
      keepAliveStep: keepAliveStep,
    );
  }

  @override
  Future<String> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    Object? body,
    String? referer,
    String? contentType,
    SourceOperation? operation,
    RequestPriority priority = RequestPriority.search,
  }) async {
    if (operation != null) {
      return runOperation(
        () => fetch(
          url,
          method: method,
          headers: headers,
          body: body,
          referer: referer,
          contentType: contentType,
          priority: priority,
        ),
        operation: operation,
      );
    }
    SourceOperation.check();
    try {
      final resp = await dio.request(
        url,
        data: body,
        options: Options(
          method: method,
          responseType: ResponseType.plain,
          contentType: contentType == 'form'
              ? Headers.formUrlEncodedContentType
              : contentType,
          headers: {
            if (referer != null && referer.isNotEmpty) 'Referer': referer,
            ...?headers,
          },
          extra: {
            SchedulerInterceptor.priorityKey: priority,
            // Do not spend three network timeouts before trying the rule's
            // browser fallback. Playback's outer attempts still own recovery.
            if (priority == RequestPriority.play &&
                allowWebview &&
                _playFeatures.usesWebview)
              RetryInterceptor.skipRetryKey: true,
          },
        ),
      );
      return resp.data?.toString() ?? '';
    } on DioException catch (e) {
      SourceOperation.check();
      debugPrint(
        '$name: fetch 失败 $url: ${e.message ?? e.type.name}, error: ${e.error}, resp: ${e.response?.statusCode}',
      );
      return '';
    }
  }

  @override
  Future<String> renderWithWebview(
    String url, {
    bool Function(String html)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = Duration.zero,
  }) async {
    if (!allowWebview) return '';
    try {
      final (html, cookies) = await WebViewAdapter.getPageContentWithCookies(
        url,
        isReady: isReady,
        timeout: timeout,
        settleDelay: settleDelay,
        userAgent: requestUserAgent,
        taskScope: _webViewTaskScope ??= WebViewTaskScope(),
      );
      SourceOperation.check();
      if (cookies.isNotEmpty) await _storeWebViewCookies(url, cookies);
      SourceOperation.check();
      return html;
    } catch (e) {
      SourceOperation.check();
      debugPrint('$name: WebView 渲染失败: $e');
      return '';
    }
  }

  Future<void> _storeWebViewCookies(String url, String cookieString) async {
    final raw = cookieString.trim();
    if (raw.isEmpty) return;
    try {
      final uri = Uri.parse(url);
      final cookies = <Cookie>[];
      for (final part in raw.split(';')) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        final name = part.substring(0, eq).trim();
        final value = part.substring(eq + 1).trim();
        if (name.isEmpty) continue;
        cookies.add(Cookie(name, value));
      }
      if (cookies.isNotEmpty) await _cookieJar.saveFromResponse(uri, cookies);
    } catch (e) {
      SourceOperation.check();
      debugPrint('$name: WebView Cookie 同步失败: $e');
    }
  }

  @override
  Future<String> sniffWithWebview(String url) async {
    if (!allowWebview) return '';
    try {
      final cookieHeader = rule.headers.entries
          .where((entry) => entry.key.toLowerCase() == 'cookie')
          .map((entry) => entry.value.trim())
          .firstWhere((value) => value.isNotEmpty, orElse: () => '');
      return await WebViewAdapter.extractVideoUrl(
            url,
            userAgent: requestUserAgent,
            cookieHeader: cookieHeader.isEmpty ? null : cookieHeader,
            followEmbeddedPlayer: _playFeatures.followsEmbeddedPlayer,
            taskScope: _webViewTaskScope ??= WebViewTaskScope(),
          ) ??
          '';
    } catch (e) {
      SourceOperation.check();
      debugPrint('$name: WebView 嗅探失败: $e');
      return '';
    }
  }
}

/// Resolves redirect-only media entry points before handing them to libmpv.
class RemoteMediaRedirectResolver {
  static const _maxRedirects = 5;
  static const _requestTimeout = Duration(seconds: 20);
  static const _hopByHop = {
    'connection',
    'content-length',
    'host',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  };
  static const _originHeaders = {
    'authorization',
    'cookie',
    'host',
    'origin',
    'referer',
  };

  RemoteMediaRedirectResolver({bool useSystemProxy = true})
    : _client = NetworkService.createClient(
        useSystemProxy: useSystemProxy,
        connectTimeout: _requestTimeout,
      );

  final http.Client _client;

  Future<String> resolve(
    String remoteUrl, {
    Map<String, String> headers = const {},
  }) async => (await resolveMedia(remoteUrl, headers: headers)).url;

  Future<({String url, Map<String, String> httpHeaders})> resolveMedia(
    String remoteUrl, {
    Map<String, String> headers = const {},
  }) async {
    final original = Uri.tryParse(remoteUrl);
    if (original == null ||
        (original.scheme != 'http' && original.scheme != 'https')) {
      return (
        url: remoteUrl,
        httpHeaders: original != null
            ? headers
            : {
                for (final entry in headers.entries)
                  if (!_originHeaders.contains(entry.key.toLowerCase()))
                    entry.key: entry.value,
              },
      );
    }

    Map<String, String>? safeHeaders;
    if (headers.isNotEmpty) {
      safeHeaders = <String, String>{};
      for (final entry in headers.entries) {
        if (!_hopByHop.contains(entry.key.toLowerCase())) {
          safeHeaders[entry.key] = entry.value;
        }
      }
    }

    var current = original;
    try {
      for (var hop = 0; hop <= _maxRedirects; hop++) {
        SourceOperation.check();
        final abort = Completer<void>();
        void cancel() {
          if (!abort.isCompleted) abort.complete();
        }

        final request = http.AbortableRequest(
          'HEAD',
          current,
          abortTrigger: abort.future,
        );
        final timer = Timer(_requestTimeout, cancel);
        final detach = SourceOperation.current?.token.onCancel(cancel);
        try {
          SourceOperation.check();
          request.followRedirects = false;
          request.headers[HttpHeaders.acceptEncodingHeader] = 'identity';
          request.headers[HttpHeaders.userAgentHeader] = 'Baka Media Resolver';

          if (safeHeaders != null && _sameAuthority(current, original)) {
            request.headers.addAll(safeHeaders);
          }

          final response = await _client.send(request).timeout(_requestTimeout);
          final location = response.headers[HttpHeaders.locationHeader];
          final status = response.statusCode;
          await response.stream.drain<void>().timeout(_requestTimeout);

          if (location != null &&
              location.isNotEmpty &&
              _isRedirectStatus(status)) {
            current = current.resolve(location);
            continue;
          }

          if (status >= 200 && status < 400) {
            if (current != original) {
              debugPrint(
                '[RemoteMediaResolver] ${original.host} -> '
                '${current.host}:${current.port}',
              );
            }
            return (
              url: current.toString(),
              httpHeaders: _sameAuthority(current, original)
                  ? headers
                  : {
                      for (final entry in headers.entries)
                        if (!_originHeaders.contains(entry.key.toLowerCase()))
                          entry.key: entry.value,
                    },
            );
          }
          debugPrint('[RemoteMediaResolver] HTTP $status for ${current.host}');
          return (url: remoteUrl, httpHeaders: headers);
        } finally {
          detach?.call();
          timer.cancel();
          cancel();
        }
      }
      debugPrint(
        '[RemoteMediaResolver] too many redirects for ${original.host}',
      );
    } catch (error) {
      SourceOperation.check();
      debugPrint('[RemoteMediaResolver] ${original.host} failed: $error');
    }
    return (url: remoteUrl, httpHeaders: headers);
  }

  static bool _isRedirectStatus(int status) =>
      status == HttpStatus.movedPermanently ||
      status == HttpStatus.found ||
      status == HttpStatus.seeOther ||
      status == HttpStatus.temporaryRedirect ||
      status == HttpStatus.permanentRedirect;

  static bool _sameAuthority(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  void close() => _client.close();
}

class _HlsSession {
  _HlsSession(this.server, this.targets, this.headers);
  final HttpServer server;
  final List<({Uri uri, bool isSegment})> targets;
  final Map<String, String> headers;
  final SourceOperation operation = SourceOperation();
  StreamSubscription<HttpRequest>? subscription;
  Future<void>? _closing;
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    operation.cancel();
    try {
      await subscription?.cancel();
    } finally {
      try {
        await server.close(force: true);
      } finally {
        operation.close();
      }
    }
  }
}
