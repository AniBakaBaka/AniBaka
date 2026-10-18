import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:baka/api/bgm.dart';
import 'package:baka/core/network_service.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/source/engine/pipeline_host.dart';
import 'package:baka/source/engine/pipeline_interpreter.dart';
import 'package:baka/source/engine/recipes.dart';
import 'package:baka/source/hls/hls_ad_filter.dart';
import 'package:baka/source/hls/hls_manifest_decoder.dart';
import 'package:baka/source/hls/hls_master_playlist.dart';
import 'package:baka/source/hls/hls_proxy.dart';
import 'package:baka/source/hls/mpeg_ts_fingerprint.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:baka/source/runtime/scheduler_interceptor.dart';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/source/webview_adapter.dart';

/// Resolved media handed to the player: the URL and the headers it needs.
typedef PlaybackMedia = ({String url, Map<String, String> httpHeaders});

const PlaybackMedia _noMedia = (url: '', httpHeaders: <String, String>{});

/// 直链可达性探测的结论。
enum MediaReachability { reachable, rejected, unknown }

/// Runs one anx-rule/2 source: its HTTP session, the pipeline I/O boundary,
/// media validation and player-side preparation (HLS proxy, keep-alive).
class SourceAdapter implements PipelineHost {
  SourceAdapter(SourceRule rule) : rule = Recipes.expand(rule);

  static const String defaultUserAgent = WebViewAdapter.desktopUserAgent;
  static const Map<String, String> _defaultMediaHeaders = {
    'User-Agent': defaultUserAgent,
    'Accept': '*/*',
  };
  static const PipelineInterpreter _interpreter = PipelineInterpreter();

  static const _urlCacheTtl = Duration(minutes: 10);
  static const _reachTtl = Duration(minutes: 3);
  static const _rejectTtl = Duration(minutes: 8);
  static const _cacheLimit = 128;

  /// HLS fingerprinting only needs PAT/PMT and the first SPS.
  static const int _segmentPrefixBytes = 16 * 1024;
  static const Duration _segmentProbeTimeout = Duration(seconds: 8);

  final SourceRule rule;
  String get name => rule.name;
  String get baseUrl => rule.baseUrl;
  late final _PlayFeatures _features = _PlayFeatures(rule.play);

  final SourceOperation _lifetime = SourceOperation();
  final CookieJar _cookieJar = CookieJar();
  bool _disposed = false;
  int _activeOperations = 0;
  bool get hasActiveOperations => _activeOperations > 0;
  VoidCallback? onIdle;
  Dio? _dio;

  final _urlCache = <String, ({String url, int expiresAt})>{};
  final _pendingUrls = <String, Object>{};
  final _reachCache =
      <String, ({bool ok, int expiresAt, Map<String, String> headers})>{};

  WebViewTaskScope? _webViewScope;
  RemoteMediaRedirectResolver? _redirects;
  Future<void>? _playBarrier;
  Timer? _keepAliveTimer;
  int _keepAliveGeneration = 0;
  CancelToken? _keepAliveRequest;
  HlsProxy? _hlsProxy;
  SourceOperation? _hlsPreparation;
  int _hlsGeneration = 0;

  /// Signed media sources opt out when their token and playback requests must
  /// use the same direct network exit.
  bool get useSystemProxy => !rule.directConnection;

  @override
  bool get allowWebview => rule.useWebview;

  String get requestUserAgent {
    final ua = (rule.headers['User-Agent'] ?? rule.headers['user-agent'])
        ?.trim();
    return ua != null && ua.isNotEmpty ? ua : defaultUserAgent;
  }

  /// Rule headers without blank values; a blank value only suppresses a default.
  late final Map<String, String> mediaHeaders = () {
    final headers = {
      for (final entry in rule.headers.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value,
    };
    return headers.isEmpty ? _defaultMediaHeaders : headers;
  }();

  /// Signed CDN links reject the site's Referer.
  Map<String, String> mediaHeadersFor(String url) =>
      _withoutRefererForSignedCdn(url, mediaHeaders);

  static Map<String, String> _withoutRefererForSignedCdn(
    String url,
    Map<String, String> headers,
  ) => VideoUrlExtractor.isSignedCdnUrl(url)
      ? {
          for (final entry in headers.entries)
            if (entry.key.toLowerCase() != 'referer') entry.key: entry.value,
        }
      : headers;

  Dio get dio {
    if (_disposed) throw const RequestCancelledException();
    SourceOperation.check();
    final existing = _dio;
    if (existing != null) return existing;
    final dio =
        Dio(
            BaseOptions(
              headers: {
                'User-Agent': defaultUserAgent,
                'Accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
                'Connection': 'keep-alive',
                ...rule.headers,
              },
              maxRedirects: 5,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              validateStatus: (status) => status != null && status < 600,
            ),
          )
          ..httpClientAdapter = NetworkService.createDioAdapter(
            useSystemProxy: useSystemProxy,
          );
    dio.interceptors.addAll([
      SchedulerInterceptor(),
      RetryInterceptor(dio),
      CookieManager(_cookieJar),
    ]);
    return _dio = dio;
  }

  /// Scopes work to this adapter: disposing it cancels the work, and the
  /// repository keeps an adapter alive while work is active.
  Future<T> runOperation<T>(Future<T> Function() action) async {
    if (_disposed) throw const RequestCancelledException();
    final scope = SourceOperation(parent: SourceOperation.current);
    final detach = _lifetime.token.onCancel(scope.cancel);
    _activeOperations++;
    try {
      return await scope.run(action);
    } finally {
      detach();
      scope.close();
      if (--_activeOperations == 0) onIdle?.call();
    }
  }

  void dispose() {
    if (_disposed) return;
    _webViewScope?.cancel();
    _redirects?.close();
    stopPlaybackKeepAlive();
    _disposed = true;
    onIdle = null;
    _lifetime.cancel();
    _urlCache.clear();
    _pendingUrls.clear();
    _reachCache.clear();
    _dio?.close(force: true);
    _dio = null;
  }

  Future<List<Series>> search(String query, {bool enhanceWithBgm = true}) =>
      runOperation(() async {
        final series = await _interpreter.runSearch(rule, this, query);
        if (!enhanceWithBgm) return series;
        await runConcurrent(series.length, 5, (index) async {
          final item = series[index];
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
        });
        return series;
      });

  Future<PlaybackCatalog> getPlaybackCatalog(String seriesId) => runOperation(
    () async => PlaybackCatalog.fromSources(
      await _interpreter.runDetail(rule, this, seriesId),
    ),
  );

  /// Runs the play pipeline for [episodeId]. Rules without per-request media
  /// headers or cookies cache the URL; a probe drops server-rejected links.
  Future<PlaybackMedia> resolvePlaybackMedia(
    String episodeId, {
    bool forceRefresh = false,
    bool skipValidation = false,
  }) => runOperation(() async {
    final cacheable = !_features.usesDynamicMetadata;
    if (cacheable && !forceRefresh) {
      final cached = _urlCache.remove(episodeId);
      if (cached != null && cached.expiresAt > _now) {
        _urlCache[episodeId] = cached;
        return (url: cached.url, httpHeaders: mediaHeadersFor(cached.url));
      }
    }
    // Invalidating or a newer refresh must keep this run from caching a stale URL.
    final pending = _pendingUrls[episodeId] = Object();
    try {
      PlaybackMedia media;
      try {
        media = await _withPlaySession(() async {
          final result = await _interpreter.runPlayMedia(rule, this, episodeId);
          SourceOperation.check();
          return result.url.isEmpty
              ? _noMedia
              : (url: result.url, httpHeaders: await _mediaHeadersOf(result));
        });
      } on RequestCancelledException {
        rethrow;
      } catch (error) {
        SourceOperation.check();
        debugPrint('$name: 播放管线失败: $error');
        media = _noMedia;
      }
      if (media.url.isEmpty) {
        debugPrint('$name: 播放管线未得到媒体地址: $episodeId');
        return _noMedia;
      }
      if (!skipValidation &&
          await _probeMedia(media.url, media.httpHeaders) ==
              MediaReachability.rejected) {
        debugPrint('$name: 媒体被服务器拒绝，丢弃: ${media.url}');
        return _noMedia;
      }
      if (cacheable && identical(_pendingUrls[episodeId], pending)) {
        _put(_urlCache, episodeId, (
          url: media.url,
          expiresAt: _now + _urlCacheTtl.inMilliseconds,
        ));
      }
      return media;
    } finally {
      if (identical(_pendingUrls[episodeId], pending)) {
        _pendingUrls.remove(episodeId);
      }
    }
  });

  Future<String> resolveDownloadUrl(
    String episodeId, {
    bool forceRefresh = false,
  }) async =>
      (await resolvePlaybackMedia(episodeId, forceRefresh: forceRefresh)).url;

  void invalidateDownloadUrl(String episodeId) {
    _pendingUrls.remove(episodeId);
    _urlCache.remove(episodeId);
  }

  /// 探测媒体 URL 是否真正可拉取（自动匹配认领前必须通过）。
  Future<bool> isPlaybackUrlReachable(String url) => runOperation(
    () async => await _probeMedia(url) != MediaReachability.rejected,
  );

  Future<MediaReachability> _probeMedia(
    String url, [
    Map<String, String>? headers,
  ]) async {
    SourceOperation.check();
    final value = url.trim();
    final lower = value.toLowerCase();
    if (lower.startsWith('magnet:') || lower.contains('.torrent')) {
      return MediaReachability.reachable;
    }
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return MediaReachability.rejected;
    }
    if (_features.validatesWithCookies ||
        VideoUrlExtractor.isSignedCdnUrl(value)) {
      return MediaReachability.reachable;
    }
    if (VideoUrlExtractor.looksLikeNonMedia(value)) {
      return MediaReachability.rejected;
    }

    final probeHeaders = headers ?? mediaHeaders;
    final cached = _reachCache[value];
    if (cached != null &&
        cached.expiresAt > _now &&
        mapEquals(cached.headers, probeHeaders)) {
      return cached.ok
          ? MediaReachability.reachable
          : MediaReachability.rejected;
    }
    final verdict = await _probe(value, probeHeaders);
    SourceOperation.check();
    // Only definite verdicts are cached. Temporary media may appear shortly
    // after a rejection, so its rejection is never remembered.
    final ok = verdict == MediaReachability.reachable;
    if (ok ||
        (verdict == MediaReachability.rejected &&
            !VideoUrlExtractor.isOnDemandMediaPath(value))) {
      _put(_reachCache, value, (
        ok: ok,
        expiresAt: _now + (ok ? _reachTtl : _rejectTtl).inMilliseconds,
        headers: probeHeaders,
      ));
    }
    return verdict;
  }

  static int get _now => DateTime.now().millisecondsSinceEpoch;

  static void _put<V>(Map<String, V> cache, String key, V value) {
    cache.remove(key);
    if (cache.length >= _cacheLimit) cache.remove(cache.keys.first);
    cache[key] = value;
  }

  static Dio _createProbeDio(bool useSystemProxy) =>
      Dio(BaseOptions(maxRedirects: 3, validateStatus: (_) => true))
        ..httpClientAdapter = NetworkService.createDioAdapter(
          useSystemProxy: useSystemProxy,
        );

  /// Probes use the rule's network exit; a direct-only source probed through
  /// the proxy would look dead.
  static final Dio _probeDio = _createProbeDio(true);
  static final Dio _probeDirectDio = _createProbeDio(false);

  /// Statuses where the server says the media is absent or forbidden.
  static const Set<int> _rejectedStatuses = {
    HttpStatus.unauthorized,
    HttpStatus.forbidden,
    HttpStatus.notFound,
    HttpStatus.gone,
    HttpStatus.unavailableForLegalReasons,
    HttpStatus.internalServerError,
    HttpStatus.badGateway,
    HttpStatus.serviceUnavailable,
    HttpStatus.gatewayTimeout,
  };

  static final RegExp _nonMediaContentType = RegExp(
    r'^\s*(?:text/html|application/xhtml|text/xml|application/xml|'
    r'application/json|image/)',
    caseSensitive: false,
  );

  static bool _isOk(int status) =>
      status == HttpStatus.ok || status == HttpStatus.partialContent;

  static bool _isNonMedia(String? contentType) =>
      contentType != null && _nonMediaContentType.hasMatch(contentType);

  Future<MediaReachability> _probe(
    String url,
    Map<String, String> headers,
  ) async {
    final timeout = Duration(
      milliseconds: rule.mediaValidationTimeoutMs > 0
          ? rule.mediaValidationTimeoutMs
          : Instances.isTV
          ? 2200
          : 1800,
    );
    try {
      if (VideoUrlExtractor.isHlsUrl(url)) {
        final response = await _probeRequest(url, timeout, {
          ...headers,
          'Range': 'bytes=0-2047',
          'Accept': 'application/vnd.apple.mpegurl,application/x-mpegURL,*/*',
        }, readPlaylist: true);
        final verdict = _playlistVerdict(response.body);
        if (verdict != MediaReachability.unknown || response.truncated) {
          return verdict;
        }
        return _rejection(url, response.status, response.contentType);
      }
      // HEAD fails fast; servers that refuse it get one ranged GET.
      var response = await _probeRequest(url, timeout, headers, method: 'HEAD');
      if (!_isOk(response.status) &&
          (response.status == HttpStatus.methodNotAllowed ||
              _rejectedStatuses.contains(response.status))) {
        response = await _probeRequest(url, timeout, {
          ...headers,
          'Range': 'bytes=0-0',
        });
      }
      if (_isOk(response.status)) {
        return _isNonMedia(response.contentType)
            ? MediaReachability.rejected
            : MediaReachability.reachable;
      }
      // 416/429/3xx are neither success nor a definite rejection.
      return _rejectedStatuses.contains(response.status)
          ? _rejection(url, response.status, response.contentType)
          : MediaReachability.unknown;
    } catch (_) {
      SourceOperation.check();
      // A timeout or transport failure does not establish a dead URL.
      return MediaReachability.unknown;
    }
  }

  /// Temporary media may not exist yet; only an HTML/JSON auth page or a
  /// permanent status rejects it.
  static MediaReachability _rejection(
    String url,
    int status,
    String? contentType,
  ) {
    final keep =
        VideoUrlExtractor.isOnDemandMediaPath(url) &&
        switch (status) {
          HttpStatus.unauthorized ||
          HttpStatus.forbidden => !_isNonMedia(contentType),
          HttpStatus.notFound ||
          HttpStatus.gone ||
          HttpStatus.internalServerError ||
          HttpStatus.badGateway ||
          HttpStatus.serviceUnavailable ||
          HttpStatus.gatewayTimeout => true,
          _ => false,
        };
    return keep ? MediaReachability.unknown : MediaReachability.rejected;
  }

  Future<({int status, String? contentType, String body, bool truncated})>
  _probeRequest(
    String url,
    Duration timeout,
    Map<String, String> headers, {
    String method = 'GET',
    bool readPlaylist = false,
  }) async {
    SourceOperation.check();
    final cancel = CancelToken();
    final detach = SourceOperation.current?.token.onCancel(
      () => cancel.cancel('source cancelled'),
    );
    try {
      return await () async {
        final response = await (useSystemProxy ? _probeDio : _probeDirectDio)
            .request<ResponseBody>(
              url,
              cancelToken: cancel,
              options: Options(
                method: method,
                headers: headers,
                responseType: ResponseType.stream,
                receiveTimeout: timeout,
                sendTimeout: timeout,
              ),
            );
        final status = response.statusCode ?? 0;
        final stream = response.data!.stream;
        var body = '';
        var truncated = false;
        if (readPlaylist && _isOk(status)) {
          (body, truncated) = await _readPlaylistPrefix(stream);
        } else {
          await stream.listen(null, onError: (Object _) {}).cancel();
        }
        return (
          status: status,
          contentType: response.headers.value(HttpHeaders.contentTypeHeader),
          body: body,
          truncated: truncated,
        );
      }().timeout(timeout);
    } finally {
      detach?.call();
      cancel.cancel('media probe complete');
    }
  }

  static Future<(String, bool)> _readPlaylistPrefix(
    Stream<Uint8List> stream,
  ) async {
    const limit = 2048;
    final bytes = Uint8List(limit);
    var length = 0;
    var text = '';
    await for (final chunk in stream) {
      final count = chunk.length < limit - length
          ? chunk.length
          : limit - length;
      bytes.setRange(length, length + count, chunk);
      length += count;
      text = utf8.decode(
        Uint8List.sublistView(bytes, 0, length),
        allowMalformed: true,
      );
      if (_playlistVerdict(text) != MediaReachability.unknown) break;
      if (length == limit) return (text, true);
    }
    return (text, false);
  }

  static MediaReachability _playlistVerdict(String text) {
    final value = text.trimLeft();
    final head = (value.length > 128 ? value.substring(0, 128) : value)
        .toUpperCase();
    if (head.startsWith('<!DOCTYPE') ||
        head.contains('<HTML') ||
        head.startsWith('{') ||
        head.startsWith('[')) {
      return MediaReachability.rejected;
    }
    return head.contains('#EXT') || value.contains('#EXT')
        ? MediaReachability.reachable
        : MediaReachability.unknown;
  }

  /// Media headers from the play result (or the rule), plus the cookies the
  /// pipeline declared for the media request.
  Future<Map<String, String>> _mediaHeadersOf(PipelinePlayResult media) async {
    final headers = <String, String>{
      for (final entry
          in (media.mediaHeaders.isEmpty ? rule.headers : media.mediaHeaders)
              .entries)
        if (entry.value.isNotEmpty) entry.key: entry.value,
    };
    if (headers.isEmpty) headers.addAll(_defaultMediaHeaders);
    if (VideoUrlExtractor.isSignedCdnUrl(media.url)) {
      headers.removeWhere((key, _) => key.toLowerCase() == 'referer');
    }
    if (media.cookieNames.isEmpty && media.cookiePrefixes.isEmpty) {
      return headers;
    }
    try {
      final cookies = await _cookieJar.loadForRequest(Uri.parse(media.url));
      SourceOperation.check();
      final cookie = cookies
          .where(
            (c) =>
                c.value.isNotEmpty &&
                (media.cookieNames.contains(c.name) ||
                    media.cookiePrefixes.any(
                      (p) => p.isNotEmpty && c.name.startsWith(p),
                    )),
          )
          .map((c) => '${c.name}=${c.value}')
          .join('; ');
      if (cookie.isNotEmpty) {
        final key = headers.keys.firstWhere(
          (key) => key.toLowerCase() == 'cookie',
          orElse: () => 'Cookie',
        );
        final existing = headers[key]?.trim() ?? '';
        headers[key] = existing.isEmpty ? cookie : '$existing; $cookie';
      }
    } catch (_) {
      SourceOperation.check();
    }
    return headers;
  }

  /// Play pages that issue a single-use credential must resolve one at a time.
  Future<T> _withPlaySession<T>(Future<T> Function() action) {
    if (!_features.usesCookies) return action();
    final next =
        _playBarrier?.then((_) {
          SourceOperation.check();
          return action();
        }) ??
        Future<T>.sync(action);
    // Keep the barrier ordered even if a queued caller stops waiting early.
    _playBarrier = next.then<void>((_) {}, onError: (Object _) {});
    return SourceOperation.current?.wait(next) ?? next;
  }

  /// Starts the rule's authorization refresh while the media is playing.
  Future<void> startPlaybackKeepAlive(String mediaUrl) async {
    stopPlaybackKeepAlive();
    final step = _features.keepAliveStep;
    final mediaUri = Uri.tryParse(mediaUrl);
    if (step == null || mediaUri == null || !mediaUri.hasScheme) return;

    final variables = <String, String>{
      'mediaUrl': mediaUrl,
      ...mediaUri.queryParameters,
    };
    String render(Object? template) => PipelineInterpreter.renderTemplate(
      template.toString(),
      (name) => variables[name],
    );
    if (step.params['variables'] case final Map declared) {
      for (final entry in declared.entries) {
        variables[entry.key.toString()] = render(entry.value);
      }
    }
    final url = Uri.tryParse(render(step.str('url')?.trim() ?? ''));
    if (url == null || !url.hasScheme) {
      debugPrint('${rule.id}: invalid playback keep-alive URL: $url');
      return;
    }
    final headers = <String, String>{
      if (step.params['headers'] case final Map raw)
        for (final entry in raw.entries)
          entry.key.toString(): render(entry.value),
    };
    final expectedBody = step.str('expectedBody')?.trim() ?? '';

    final generation = ++_keepAliveGeneration;
    Future<void> send() =>
        _sendKeepAlive(generation, url, headers, expectedBody);
    await send();
    if (generation != _keepAliveGeneration) return;
    _keepAliveTimer = Timer.periodic(
      Duration(seconds: (step.intValue('intervalSeconds') ?? 10).clamp(1, 300)),
      (_) => unawaited(send()),
    );
  }

  Future<void> _sendKeepAlive(
    int generation,
    Uri url,
    Map<String, String> headers,
    String expectedBody,
  ) async {
    if (generation != _keepAliveGeneration || _keepAliveRequest != null) return;
    final cancelToken = _keepAliveRequest = CancelToken();
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
      if (generation != _keepAliveGeneration) return;
      final status = response.statusCode ?? 0;
      final body = response.data?.trim() ?? '';
      if (status < 200 ||
          status >= 300 ||
          (expectedBody.isNotEmpty && body != expectedBody)) {
        debugPrint(
          '${rule.id}: playback keep-alive rejected (HTTP $status, body: $body)',
        );
      }
    } catch (error) {
      if (generation == _keepAliveGeneration) {
        debugPrint('${rule.id}: playback keep-alive failed: $error');
      }
    } finally {
      if (identical(_keepAliveRequest, cancelToken)) _keepAliveRequest = null;
    }
  }

  /// Stops the keep-alive and releases the HLS proxy of the previous media.
  void stopPlaybackKeepAlive() {
    _keepAliveGeneration++;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _keepAliveRequest?.cancel('playback keep-alive stopped');
    _keepAliveRequest = null;
    _hlsGeneration++;
    _hlsPreparation?.cancel();
    _hlsPreparation = null;
    final proxy = _hlsProxy;
    _hlsProxy = null;
    unawaited(proxy?.close());
  }

  /// Prepares a stable player-facing URL: follows redirect-only entries and,
  /// when the rule asks for it, serves the HLS manifest through a local proxy.
  Future<PlaybackMedia> preparePlaybackMedia(
    PlaybackMedia media, {
    bool? filterHlsAds,
    void Function(String message)? onHlsAdFilterStatus,
    void Function(String key)? onTimelinePrepared,
  }) => runOperation(() async {
    final generation = ++_hlsGeneration;
    _hlsPreparation?.cancel();
    final preparation = _hlsPreparation = SourceOperation.current!;
    try {
      return await _preparePlaybackMedia(
        media,
        generation,
        preparation,
        filterHlsAds: filterHlsAds,
        onStatus: onHlsAdFilterStatus,
        onTimelinePrepared: onTimelinePrepared,
      );
    } finally {
      if (identical(_hlsPreparation, preparation)) _hlsPreparation = null;
    }
  });

  Future<PlaybackMedia> _preparePlaybackMedia(
    PlaybackMedia media,
    int generation,
    SourceOperation preparation, {
    bool? filterHlsAds,
    void Function(String message)? onStatus,
    void Function(String key)? onTimelinePrepared,
  }) async {
    var prepared = media;
    if (_features.resolvesMediaRedirects) {
      prepared = await (_redirects ??= RemoteMediaRedirectResolver(
        useSystemProxy: useSystemProxy,
      )).resolveMedia(media.url, headers: media.httpHeaders);
      SourceOperation.check();
    }
    if (!VideoUrlExtractor.isHlsUrl(prepared.url)) return prepared;

    final filtersAds =
        filterHlsAds ??
        PlaybackSettingsService.getFilterHlsAdsOverride() ??
        _features.filtersHlsAds;
    final manifestUri = Uri.tryParse(prepared.url);
    if ((!_features.materializesHls && !filtersAds) ||
        manifestUri == null ||
        !manifestUri.hasScheme) {
      return prepared;
    }

    PlaybackMedia skip(String log, [String? status]) {
      debugPrint('${rule.id}: $log');
      if (filtersAds && status != null) onStatus?.call(status);
      return prepared;
    }

    final headers = prepared.httpHeaders;
    final budget = SourceOperation(
      parent: preparation,
      timeout: filtersAds ? const Duration(seconds: 15) : null,
    );
    try {
      return await budget.run(() async {
        var playlist = await _fetchPlaylist(manifestUri, headers);
        if (!playlist.fetchable) {
          return skip(
            'HLS 清单不完整 (HTTP ${playlist.status}, ${playlist.body.length} chars)',
            'HLS 去广告未生效：清单读取失败（HTTP ${playlist.status}）',
          );
        }
        // Encrypted masters also need a decoded, materialized media variant.
        if (HlsMasterPlaylist.isMaster(playlist.body)) {
          if (!filtersAds && _features.hlsManifestDecode == null) {
            return skip('HLS 主清单不做物化（未开启 filterHlsAds）');
          }
          final variant = HlsMasterPlaylist.selectVariant(
            playlist.body,
            playlist.uri,
          );
          if (variant == null) {
            return skip('HLS 主清单无法选定单一变体', 'HLS 去广告未生效：不支持此多码率清单');
          }
          playlist = await _fetchPlaylist(variant.uri, headers);
          if (!playlist.fetchable) {
            onStatus?.call('HLS 去广告未生效：分片清单读取失败（HTTP ${playlist.status}）');
            return skip('HLS 变体清单不完整 (HTTP ${playlist.status})');
          }
          debugPrint('${rule.id}: HLS 主清单选定变体 ${variant.label}');
        }
        if (!playlist.body.contains('#EXT-X-ENDLIST')) {
          return skip('直播清单无 #EXT-X-ENDLIST', 'HLS 去广告未生效：仅支持完整点播清单');
        }

        var body = playlist.body;
        HlsAdFilterOutcome? outcome;
        if (filtersAds) {
          outcome = await HlsAdFilter.apply(
            manifest: body,
            manifestUri: playlist.uri,
            probe: (segment) => _readSegmentFingerprint(segment, headers),
          );
          debugPrint('${rule.id}: HLS 去广告 ${outcome.detail}');
          body = outcome.manifest;
        }

        final proxy = await HlsProxy.start(
          body,
          playlist.uri,
          headers: headers,
          stripTsPrefix: _features.stripsHlsTsPrefix,
          fetch: (uri, method, headers) => dio.requestUri<ResponseBody>(
            uri,
            options: Options(
              method: method,
              headers: headers,
              responseType: ResponseType.stream,
              validateStatus: (_) => true,
              extra: const {
                SchedulerInterceptor.priorityKey: RequestPriority.play,
              },
            ),
          ),
        );
        if (generation != _hlsGeneration ||
            SourceOperation.current!.isCancelled) {
          await proxy.close();
          throw const RequestCancelledException();
        }
        final previous = _hlsProxy;
        _hlsProxy = proxy;
        unawaited(previous?.close());

        if (outcome != null) {
          onStatus?.call(
            outcome.changed
                ? '已过滤 ${outcome.removedSegments} 个广告分片，'
                      '共 ${outcome.removedSeconds.toStringAsFixed(1)} 秒'
                : 'HLS 去广告：${outcome.detail}',
          );
        }
        onTimelinePrepared?.call(outcome?.timelineKey ?? 'original');
        return (url: proxy.url, httpHeaders: const <String, String>{});
      });
    } catch (error) {
      preparation.token.throwIfCancelled();
      return skip(
        'HLS manifest materialization failed: $error',
        budget.timedOut ? 'HLS 去广告超过15秒，已保留原视频' : 'HLS 去广告未生效：网络或分片处理失败，已保留原视频',
      );
    } finally {
      budget.close();
    }
  }

  /// The manifest may redirect; segments resolve against the final URI.
  Future<({String body, Uri uri, int status, bool fetchable})> _fetchPlaylist(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final decoder = _features.hlsManifestDecode;
    final response = await dio.getUri<Object>(
      uri,
      options: Options(
        headers: headers,
        responseType: decoder == null ? ResponseType.plain : ResponseType.bytes,
        validateStatus: (_) => true,
        extra: const {SchedulerInterceptor.priorityKey: RequestPriority.play},
      ),
    );
    final data = response.data;
    final body = decoder == null
        ? data as String? ?? ''
        : HlsManifestDecoder.decode(data as List<int>? ?? const [], decoder);
    final status = response.statusCode ?? 0;
    return (
      body: body,
      uri: response.realUri,
      status: status,
      fetchable: status >= 200 && status < 300 && body.startsWith('#EXTM3U'),
    );
  }

  /// Reads only a segment prefix for [HlsAdFilter]; any failure is `null`,
  /// which the filter treats as matching the main content.
  Future<HlsVideoFingerprint?> _readSegmentFingerprint(
    Uri segment,
    Map<String, String> headers,
  ) async {
    final cancel = CancelToken();
    try {
      return await () async {
        final response = await dio.requestUri<ResponseBody>(
          segment,
          cancelToken: cancel,
          options: Options(
            headers: {
              ...headers,
              HttpHeaders.rangeHeader: 'bytes=0-${_segmentPrefixBytes - 1}',
            },
            responseType: ResponseType.stream,
            validateStatus: (_) => true,
            extra: const {
              SchedulerInterceptor.priorityKey: RequestPriority.play,
            },
          ),
        );
        final stream = response.data?.stream;
        if (!_isOk(response.statusCode ?? 0) || stream == null) return null;
        final prefix = Uint8List(_segmentPrefixBytes);
        var length = 0;
        try {
          await for (final chunk in stream) {
            final count = chunk.length < prefix.length - length
                ? chunk.length
                : prefix.length - length;
            prefix.setRange(length, length + count, chunk);
            length += count;
            // Servers that ignore Range must not load the whole segment.
            if (length == prefix.length) break;
          }
        } catch (_) {
          // An aborted stream still leaves a usable prefix.
        }
        SourceOperation.check();
        return MpegTsFingerprint.read(Uint8List.sublistView(prefix, 0, length));
      }().timeout(_segmentProbeTimeout, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      cancel.cancel('HLS 指纹探测结束');
    }
  }

  @override
  Future<String> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    Object? body,
    String? referer,
    String? contentType,
    RequestPriority priority = RequestPriority.search,
  }) async {
    try {
      final response = await dio.request<String>(
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
            // A play pipeline with a browser fallback owns recovery itself.
            if (priority == RequestPriority.play &&
                allowWebview &&
                _features.usesWebview)
              RetryInterceptor.skipRetryKey: true,
          },
        ),
      );
      return response.data ?? '';
    } on DioException catch (e) {
      SourceOperation.check();
      debugPrint(
        '$name: fetch 失败 $url: ${e.message ?? e.type.name}, '
        'status: ${e.response?.statusCode}',
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
        taskScope: _webViewScope ??= WebViewTaskScope(),
      );
      SourceOperation.check();
      if (cookies.isNotEmpty) await _storeWebViewCookies(url, cookies);
      return html;
    } catch (e) {
      SourceOperation.check();
      debugPrint('$name: WebView 渲染失败: $e');
      return '';
    }
  }

  /// Continues the browser session over Dio; a malformed cookie keeps the HTML.
  Future<void> _storeWebViewCookies(String url, String cookies) async {
    try {
      final jar = [
        for (final part in cookies.split(';'))
          if (part.indexOf('=') case final eq when eq > 0)
            if (part.substring(0, eq).trim() case final name
                when name.isNotEmpty)
              Cookie(name, part.substring(eq + 1).trim()),
      ];
      if (jar.isNotEmpty) {
        await _cookieJar.saveFromResponse(Uri.parse(url), jar);
      }
    } catch (e) {
      debugPrint('$name: WebView Cookie 同步失败: $e');
    }
    SourceOperation.check();
  }

  @override
  Future<String> sniffWithWebview(String url) async {
    if (!allowWebview) return '';
    try {
      final cookie = rule.headers.entries
          .where((e) => e.key.toLowerCase() == 'cookie')
          .map((e) => e.value.trim())
          .firstWhere((v) => v.isNotEmpty, orElse: () => '');
      return await WebViewAdapter.extractVideoUrl(
            url,
            userAgent: requestUserAgent,
            cookieHeader: cookie.isEmpty ? null : cookie,
            followEmbeddedPlayer: _features.followsEmbeddedPlayer,
            taskScope: _webViewScope ??= WebViewTaskScope(),
          ) ??
          '';
    } catch (e) {
      SourceOperation.check();
      debugPrint('$name: WebView 嗅探失败: $e');
      return '';
    }
  }

  @override
  String toString() => name;
}

/// Play-stage flags, read once from the rule (branches included).
class _PlayFeatures {
  _PlayFeatures(List<PipelineStep> steps) {
    _inspect(steps);
  }

  bool usesDynamicMetadata = false;
  bool usesCookies = false;
  bool validatesWithCookies = false;
  bool materializesHls = false;
  bool stripsHlsTsPrefix = false;
  bool filtersHlsAds = false;
  bool resolvesMediaRedirects = false;
  bool followsEmbeddedPlayer = false;
  bool usesWebview = false;
  Map<String, dynamic>? hlsManifestDecode;
  PipelineStep? keepAliveStep;

  void _inspect(List<PipelineStep> steps) {
    for (final step in steps) {
      final anime1 = step.op == 'anime1Play';
      usesDynamicMetadata |= anime1 || step.op == 'setMediaHeaders';
      // A play page issuing a single-use credential (cookie/session) must run
      // exclusively, or concurrent episodes invalidate each other's token.
      usesCookies |= anime1 || step.flag('cookieSession');
      validatesWithCookies |= step.flag('validateWithCookies');
      stripsHlsTsPrefix |= step.flag('stripHlsTsPrefix');
      materializesHls |= stripsHlsTsPrefix || step.flag('materializeHls');
      if (step.params['hlsManifestDecode'] case final Map decoder
          when hlsManifestDecode == null) {
        hlsManifestDecode = decoder.cast<String, dynamic>();
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
        _inspect(branch);
      }
    }
  }
}

/// GET retry for transient network errors.
class RetryInterceptor extends Interceptor {
  RetryInterceptor(this.dio);

  final Dio dio;
  static const int _maxRetries = 2;
  static const skipRetryKey = 'anx.skipNetworkRetry';
  static const _countKey = '__retry_count';

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final retries = options.extra[_countKey] as int? ?? 0;
    if (retries >= _maxRetries || !_shouldRetry(err)) return handler.next(err);
    options.extra[_countKey] = retries + 1;
    try {
      handler.resolve(await dio.fetch(options));
    } on DioException catch (e) {
      handler.next(e);
    } catch (_) {
      handler.next(err);
    }
  }

  static bool _shouldRetry(DioException e) {
    final options = e.requestOptions;
    if (options.extra[skipRetryKey] == true ||
        (options.cancelToken?.isCancelled ?? false) ||
        options.method.toUpperCase() != 'GET') {
      return false;
    }
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      DioExceptionType.badResponse => const {
        429,
        502,
        503,
        504,
      }.contains(e.response?.statusCode),
      _ => false,
    };
  }
}

/// Resolves redirect-only media entry points before handing them to libmpv.
class RemoteMediaRedirectResolver {
  RemoteMediaRedirectResolver({bool useSystemProxy = true})
    : _client = NetworkService.createClient(
        useSystemProxy: useSystemProxy,
        connectTimeout: _requestTimeout,
      );

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
  static const _redirectStatuses = {
    HttpStatus.movedPermanently,
    HttpStatus.found,
    HttpStatus.seeOther,
    HttpStatus.temporaryRedirect,
    HttpStatus.permanentRedirect,
  };

  final http.Client _client;

  Future<PlaybackMedia> resolveMedia(
    String remoteUrl, {
    Map<String, String> headers = const {},
  }) async {
    final original = Uri.tryParse(remoteUrl);
    if (original == null ||
        (original.scheme != 'http' && original.scheme != 'https')) {
      return (
        url: remoteUrl,
        httpHeaders: original == null ? _withoutOrigin(headers) : headers,
      );
    }
    final requestHeaders = {
      for (final entry in headers.entries)
        if (!_hopByHop.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };

    var current = original;
    try {
      for (var hop = 0; hop <= _maxRedirects; hop++) {
        SourceOperation.check();
        final abort = Completer<void>();
        void cancel() {
          if (!abort.isCompleted) abort.complete();
        }

        final timer = Timer(_requestTimeout, cancel);
        final detach = SourceOperation.current?.token.onCancel(cancel);
        try {
          final sameOrigin = _sameAuthority(current, original);
          final request =
              http.AbortableRequest('HEAD', current, abortTrigger: abort.future)
                ..followRedirects = false
                ..headers[HttpHeaders.acceptEncodingHeader] = 'identity'
                ..headers[HttpHeaders.userAgentHeader] = 'Baka Media Resolver';
          if (sameOrigin) request.headers.addAll(requestHeaders);

          final response = await _client.send(request).timeout(_requestTimeout);
          final location = response.headers[HttpHeaders.locationHeader];
          final status = response.statusCode;
          await response.stream.drain<void>().timeout(_requestTimeout);

          if (location != null &&
              location.isNotEmpty &&
              _redirectStatuses.contains(status)) {
            current = current.resolve(location);
            continue;
          }
          if (status >= 200 && status < 400) {
            return (
              url: current.toString(),
              httpHeaders: sameOrigin ? headers : _withoutOrigin(headers),
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
      debugPrint('[RemoteMediaResolver] too many redirects: ${original.host}');
    } catch (error) {
      SourceOperation.check();
      debugPrint('[RemoteMediaResolver] ${original.host} failed: $error');
    }
    return (url: remoteUrl, httpHeaders: headers);
  }

  static Map<String, String> _withoutOrigin(Map<String, String> headers) => {
    for (final entry in headers.entries)
      if (!_originHeaders.contains(entry.key.toLowerCase()))
        entry.key: entry.value,
  };

  static bool _sameAuthority(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  void close() => _client.close();
}
