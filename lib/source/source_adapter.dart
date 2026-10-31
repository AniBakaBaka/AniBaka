import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/core/app_logger.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/core/network_service.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/source/engine/pipeline_host.dart';
import 'package:baka/source/engine/pipeline_interpreter.dart';
import 'package:baka/source/engine/recipes.dart';
import 'package:baka/source/hls/hls_ad_filter.dart';
import 'package:baka/source/hls/hls_manifest_decoder.dart';
import 'package:baka/source/hls/hls_playlist.dart';
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
enum _Reach { reachable, rejected, unknown }

/// Runs one anx-rule/2 source: its HTTP session, the pipeline I/O boundary,
/// media validation and player-side preparation (HLS proxy, keep-alive).
class SourceAdapter implements PipelineHost {
  SourceAdapter(SourceRule rule) : rule = Recipes.expand(rule);

  static const PipelineInterpreter _interpreter = PipelineInterpreter();
  static const Map<String, String> _defaultMediaHeaders = {
    'User-Agent': WebViewAdapter.desktopUserAgent,
    'Accept': '*/*',
  };
  static const _playExtra = {
    SchedulerInterceptor.priorityKey: RequestPriority.play,
  };
  static const _playNoRetry = {
    SchedulerInterceptor.priorityKey: RequestPriority.play,
    RetryInterceptor.skipRetryKey: true,
  };
  static const _reachTtl = Duration(minutes: 3);
  static const _rejectTtl = Duration(minutes: 8);
  static const _redirectTimeout = Duration(seconds: 20);

  final SourceRule rule;
  String get name => rule.name;
  String get baseUrl => rule.baseUrl;
  late final _PlayFeatures _features = _PlayFeatures(rule.play);

  /// Rule headers without blank values; a blank value only suppresses a default.
  late final Map<String, String> _ruleMediaHeaders = _nonBlank(rule.headers);

  final SourceOperation _lifetime = SourceOperation();
  final CookieJar _cookieJar = CookieJar();
  bool _disposed = false;
  int _activeOperations = 0;
  bool get hasActiveOperations => _activeOperations > 0;
  VoidCallback? onIdle;
  Dio? _dio;
  Dio? _dioDirect;

  final _urls = RequestCache<String, String>(
    limit: 128,
    ttl: const Duration(minutes: 10),
  );
  final _reach = RequestCache<String, bool>(limit: 128);
  final _pendingUrls = <String, Object>{};

  Future<void>? _playBarrier;
  SourceOperation? _keepAlive;
  SourceOperation? _hlsPreparation;
  HlsProxy? _hlsProxy;

  /// Signed media sources opt out when their token and playback requests must
  /// use the same direct network exit.
  bool get useSystemProxy => !rule.directConnection;

  @override
  bool get allowWebview => rule.useWebview;

  String get _userAgent =>
      _ruleHeader('user-agent') ?? WebViewAdapter.desktopUserAgent;

  String? _ruleHeader(String lowerName) {
    for (final entry in rule.headers.entries) {
      final value = entry.value.trim();
      if (entry.key.toLowerCase() == lowerName && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  Dio get dio => _dio ??= _buildDio(useSystemProxy);
  Dio get _directDio => _dioDirect ??= _buildDio(false);

  Dio _buildDio(bool viaProxy) {
    if (_disposed) throw const RequestCancelledException();
    final dio = Dio(
      BaseOptions(
        headers: {
          'User-Agent': WebViewAdapter.desktopUserAgent,
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
    )..httpClientAdapter = NetworkService.createDioAdapter(useSystemProxy: viaProxy);
    dio.interceptors.addAll([
      SchedulerInterceptor(),
      RetryInterceptor(dio),
      CookieManager(_cookieJar),
    ]);
    return dio;
  }

  /// Cookie-less clients for probes and redirect resolution: the server sees
  /// only the headers the player will send. Shared by all adapters.
  static final Dio _bareDio = _bareClient(true);
  static final Dio _bareDirectDio = _bareClient(false);

  static Dio _bareClient(bool viaProxy) =>
      Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            validateStatus: (_) => true,
          ),
        )
        ..httpClientAdapter = NetworkService.createDioAdapter(
          useSystemProxy: viaProxy,
        )
        ..interceptors.add(SchedulerInterceptor());

  /// Whether [uri] leaves through a configured proxy for this rule.
  bool _proxied(Uri uri) =>
      useSystemProxy && NetworkService.findProxy(uri) != 'DIRECT';

  /// A configured proxy's exit may be refused by the CDN (e.g. region-blocked)
  /// while the media is reachable directly, so proxied media requests get one
  /// direct retry. [bare] requests use the shared cookie-less client.
  Future<Response<T>> _mediaRequest<T>(
    Uri uri,
    Future<Response<T>> Function(Dio client) send, {
    bool bare = false,
  }) async {
    final client = bare ? (useSystemProxy ? _bareDio : _bareDirectDio) : dio;
    if (!_proxied(uri)) return send(client);
    try {
      final response = await send(client);
      if ((response.statusCode ?? 0) < 400) return response;
      // Drop the refused body before retrying so its slot is released.
      if (response.data case final ResponseBody body) {
        await body.stream.listen(null, onError: (Object _) {}).cancel();
      }
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) rethrow;
    }
    return send(bare ? _bareDirectDio : _directDio);
  }

  /// Bounds a request; cancelling its token also aborts the response stream.
  static Future<T> _bounded<T>(
    Duration timeout,
    Future<T> Function(CancelToken cancel) request,
  ) async {
    final cancel = CancelToken();
    try {
      return await request(cancel).timeout(timeout);
    } finally {
      cancel.cancel();
    }
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
    stopPlaybackKeepAlive();
    _disposed = true;
    onIdle = null;
    _lifetime.cancel();
    _urls.clear();
    _reach.clear();
    _pendingUrls.clear();
    _dio?.close(force: true);
    _dio = null;
    _dioDirect?.close(force: true);
    _dioDirect = null;
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
    if (_urls.peek(episodeId) case final url? when cacheable && !forceRefresh) {
      return (url: url, httpHeaders: _mediaHeaders(url));
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
              : (url: result.url, httpHeaders: await _playHeaders(result));
        });
      } catch (error) {
        SourceOperation.check();
        Log.w('Source', '$name: 播放管线失败', error);
        media = _noMedia;
      }
      if (media.url.isEmpty) {
        Log.w('Source', '$name: 播放管线未得到媒体地址: $episodeId');
        return _noMedia;
      }
      if (!skipValidation && !await _reachable(media.url, media.httpHeaders)) {
        Log.w('Source', '$name: 媒体被服务器拒绝，丢弃: ${media.url}');
        return _noMedia;
      }
      if (cacheable && identical(_pendingUrls[episodeId], pending)) {
        _urls.put(episodeId, media.url);
      }
      return media;
    } finally {
      if (identical(_pendingUrls[episodeId], pending)) {
        _pendingUrls.remove(episodeId);
      }
    }
  });

  void invalidatePlaybackMedia(String episodeId) {
    _pendingUrls.remove(episodeId);
    _urls.remove(episodeId);
  }

  /// A direct media link with the rule's media headers; no media when the
  /// server rejects it (自动匹配认领前必须通过).
  Future<PlaybackMedia> resolveDirectMedia(String url) =>
      runOperation(() async {
        final headers = _mediaHeaders(url);
        return await _reachable(url, headers)
            ? (url: url, httpHeaders: headers)
            : _noMedia;
      });

  static Map<String, String> _nonBlank(Map<String, String> declared) {
    final headers = {
      for (final entry in declared.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value,
    };
    return headers.isEmpty ? _defaultMediaHeaders : headers;
  }

  /// The player's headers for [url]: the play result's (else the rule's)
  /// non-blank headers. Signed CDN links reject the site's Referer.
  Map<String, String> _mediaHeaders(
    String url, [
    Map<String, String> declared = const {},
  ]) {
    final headers = declared.isEmpty ? _ruleMediaHeaders : _nonBlank(declared);
    return VideoUrlExtractor.isSignedCdnUrl(url)
        ? {
            for (final entry in headers.entries)
              if (entry.key.toLowerCase() != 'referer') entry.key: entry.value,
          }
        : headers;
  }

  /// Media headers of a play result plus the session cookies it selected.
  Future<Map<String, String>> _playHeaders(PipelinePlayResult media) async {
    final headers = _mediaHeaders(media.url, media.mediaHeaders);
    if (media.cookieNames.isEmpty && media.cookiePrefixes.isEmpty) {
      return headers;
    }
    final selected = [
      for (final cookie in await _cookieJar.loadForRequest(
        Uri.parse(media.url),
      ))
        if (cookie.value.isNotEmpty &&
            (media.cookieNames.contains(cookie.name) ||
                media.cookiePrefixes.any(
                  (prefix) =>
                      prefix.isNotEmpty && cookie.name.startsWith(prefix),
                )))
          '${cookie.name}=${cookie.value}',
    ].join('; ');
    if (selected.isEmpty) return headers;
    final key = headers.keys.firstWhere(
      (key) => key.toLowerCase() == 'cookie',
      orElse: () => 'Cookie',
    );
    final existing = headers[key]?.trim() ?? '';
    return {
      ...headers,
      key: existing.isEmpty ? selected : '$existing; $selected',
    };
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

  /// Whether the media may play; only a definite server rejection says no.
  Future<bool> _reachable(String url, Map<String, String> headers) async {
    final lower = url.toLowerCase();
    if (lower.startsWith('magnet:') || lower.contains('.torrent')) return true;
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    if (_features.validatesWithCookies ||
        VideoUrlExtractor.isSignedCdnUrl(url)) {
      return true;
    }
    if (VideoUrlExtractor.looksLikeNonMedia(url)) return false;
    final cacheable = !_features.usesDynamicMetadata;
    if (_reach.peek(url) case final ok? when cacheable) return ok;
    final verdict = await _probe(url, headers);
    SourceOperation.check();
    // Only definite verdicts are cached. Temporary media may appear shortly
    // after a rejection, so its rejection is never remembered.
    if (cacheable &&
        (verdict == _Reach.reachable ||
            verdict == _Reach.rejected &&
                !VideoUrlExtractor.isOnDemandMediaPath(url))) {
      final ok = verdict == _Reach.reachable;
      _reach.put(url, ok, ttl: ok ? _reachTtl : _rejectTtl);
    }
    return verdict != _Reach.rejected;
  }

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

  static bool _isOk(int? status) =>
      status == HttpStatus.ok || status == HttpStatus.partialContent;

  static bool _isNonMedia(String? contentType) =>
      contentType != null && _nonMediaContentType.hasMatch(contentType);

  /// One ranged GET with the player's headers: the status and the first bytes
  /// tell playable media from an error page.
  Future<_Reach> _probe(String url, Map<String, String> headers) async {
    final timeout = Duration(
      milliseconds: rule.mediaValidationTimeoutMs > 0
          ? rule.mediaValidationTimeoutMs
          : 2000,
    );
    try {
      final uri = Uri.parse(url);
      return await _bounded(timeout, (cancel) async {
        final response = await _mediaRequest(
          uri,
          (client) => client.getUri<ResponseBody>(
            uri,
            cancelToken: cancel,
            options: Options(
              headers: {...headers, HttpHeaders.rangeHeader: 'bytes=0-1023'},
              responseType: ResponseType.stream,
              extra: _playExtra,
            ),
          ),
          bare: true,
        );
        final status = response.statusCode;
        final contentType = response.headers.value(
          HttpHeaders.contentTypeHeader,
        );
        if (!_isOk(status)) {
          // 3xx/405/416/429 are neither success nor a definite rejection.
          return _rejectedStatuses.contains(status)
              ? _rejection(url, status!, contentType)
              : _Reach.unknown;
        }
        final head = Uint8List(64);
        final length = await _readPrefix(response.data!.stream, head);
        final text = utf8
            .decode(
              Uint8List.sublistView(head, 0, length),
              allowMalformed: true,
            )
            .trimLeft();
        // RFC 8216: #EXTM3U is the first line of every playlist.
        if (text.startsWith('#EXTM3U')) return _Reach.reachable;
        if (text.startsWith('<') ||
            text.startsWith('{') ||
            text.startsWith('[')) {
          return _Reach.rejected;
        }
        // Encrypted playlists are opaque; other media is judged by its type.
        if (VideoUrlExtractor.isHlsUrl(url)) return _Reach.unknown;
        return _isNonMedia(contentType) ? _Reach.rejected : _Reach.reachable;
      });
    } catch (_) {
      SourceOperation.check();
      // A timeout or transport failure does not establish a dead URL.
      return _Reach.unknown;
    }
  }

  /// Temporary media may not exist yet; only an HTML/JSON auth page or a
  /// permanent status rejects it.
  static _Reach _rejection(String url, int status, String? contentType) {
    final temporary =
        VideoUrlExtractor.isOnDemandMediaPath(url) &&
        switch (status) {
          HttpStatus.unauthorized ||
          HttpStatus.forbidden => !_isNonMedia(contentType),
          HttpStatus.unavailableForLegalReasons => false,
          _ => true,
        };
    return temporary ? _Reach.unknown : _Reach.rejected;
  }

  /// Copies the stream's first bytes into [buffer] until it is full or
  /// [enough] accepts the prefix; leaving the loop cancels the response.
  static Future<int> _readPrefix(
    Stream<Uint8List> stream,
    Uint8List buffer, [
    bool Function(Uint8List prefix)? enough,
  ]) async {
    var length = 0;
    await for (final chunk in stream) {
      final count = chunk.length < buffer.length - length
          ? chunk.length
          : buffer.length - length;
      buffer.setRange(length, length + count, chunk);
      length += count;
      if ((enough?.call(Uint8List.sublistView(buffer, 0, length)) ?? false) ||
          length == buffer.length) {
        break;
      }
    }
    return length;
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
      Log.w('Source', '${rule.id}: invalid playback keep-alive URL: $url');
      return;
    }
    final headers = <String, String>{
      if (step.params['headers'] case final Map raw)
        for (final entry in raw.entries)
          entry.key.toString(): render(entry.value),
    };
    final expectedBody = step.str('expectedBody')?.trim() ?? '';

    // Cancelling the scope stops the timer and any request in flight.
    final scope = _keepAlive = SourceOperation();
    var sending = false;
    Future<void> send() async {
      if (sending) return;
      sending = true;
      try {
        final response = await scope.run(
          () => dio.getUri<String>(
            url,
            options: Options(
              headers: headers,
              responseType: ResponseType.plain,
              validateStatus: (_) => true,
            ),
          ),
        );
        final status = response.statusCode ?? 0;
        final body = response.data?.trim() ?? '';
        if (status < 200 ||
            status >= 300 ||
            (expectedBody.isNotEmpty && body != expectedBody)) {
          Log.w(
            'Source',
            '${rule.id}: playback keep-alive rejected (HTTP $status, body: $body)',
          );
        }
      } catch (error) {
        if (!scope.isCancelled) {
          Log.w('Source', '${rule.id}: playback keep-alive failed', error);
        }
      } finally {
        sending = false;
      }
    }

    await send();
    if (scope.isCancelled) return;
    final timer = Timer.periodic(
      Duration(seconds: (step.intValue('intervalSeconds') ?? 10).clamp(1, 300)),
      (_) => unawaited(send()),
    );
    scope.token.onCancel(timer.cancel);
  }

  /// Stops the keep-alive and releases the HLS proxy of the previous media.
  void stopPlaybackKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = null;
    _hlsPreparation?.cancel();
    _hlsPreparation = null;
    unawaited(_hlsProxy?.close());
    _hlsProxy = null;
  }

  /// Prepares a stable player-facing URL: follows redirect-only entries and,
  /// when the rule asks for it, serves the HLS manifest through a local proxy.
  /// A newer preparation cancels this one.
  Future<PlaybackMedia> preparePlaybackMedia(
    PlaybackMedia media, {
    bool? filterHlsAds,
    void Function(String message)? onHlsAdFilterStatus,
    void Function(String key)? onTimelinePrepared,
  }) => runOperation(() async {
    _hlsPreparation?.cancel();
    final preparation = _hlsPreparation = SourceOperation.current!;
    try {
      final prepared = _features.resolvesMediaRedirects
          ? await _followRedirects(media)
          : media;
      final uri = Uri.tryParse(prepared.url);
      if (uri == null || !uri.isScheme('http') && !uri.isScheme('https')) {
        return prepared;
      }
      final headers = prepared.httpHeaders;
      if (!VideoUrlExtractor.isHlsUrl(prepared.url)) {
        return _features.proxiesMedia
            ? _installProxy(
                await HlsProxy.startMedia(
                  uri,
                  headers: headers,
                  fetch: _fetchTarget,
                ),
              )
            : prepared;
      }

      final filtersAds =
          filterHlsAds ??
          PlaybackSettingsService.getFilterHlsAdsOverride() ??
          _features.filtersHlsAds;
      if (!_features.materializesHls && !filtersAds) return prepared;

      PlaybackMedia skip(String log, [String? status]) {
        Log.i('Source', '${rule.id}: $log');
        if (filtersAds && status != null) onHlsAdFilterStatus?.call(status);
        return prepared;
      }

      final budget = SourceOperation(
        parent: preparation,
        timeout: filtersAds ? const Duration(seconds: 15) : null,
      );
      try {
        return await budget.run(() async {
          var playlist = await _fetchPlaylist(uri, headers);
          // Encrypted masters also need a decoded, materialized media variant.
          if (playlist.isMaster) {
            if (!filtersAds && _features.hlsManifestDecode == null) {
              return skip('HLS 主清单不做物化（未开启 filterHlsAds）');
            }
            final variant = playlist.variant;
            if (variant == null) {
              return skip('HLS 主清单无法选定单一变体', 'HLS 去广告未生效：不支持此多码率清单');
            }
            playlist = await _fetchPlaylist(variant.uri, headers);
            Log.i(
              'Source',
              '${rule.id}: HLS 主清单选定变体 ${variant.resolution}@${variant.bandwidth ~/ 1000}kbps',
            );
          }
          if (!playlist.isVod) {
            return skip('直播清单无 #EXT-X-ENDLIST', 'HLS 去广告未生效：仅支持完整点播清单');
          }

          final outcome = filtersAds
              ? await HlsAdFilter.apply(
                  playlist,
                  probe: (segment) => _fingerprint(segment, headers),
                )
              : null;
          final proxied = _installProxy(
            await HlsProxy.start(
              playlist,
              headers: headers,
              stripTsPrefix: _features.stripsHlsTsPrefix,
              fetch: _fetchTarget,
            ),
          );
          if (outcome != null) {
            Log.i('Source', '${rule.id}: HLS 去广告 ${outcome.detail}');
            onHlsAdFilterStatus?.call(
              outcome.changed
                  ? '已过滤 ${outcome.removedSegments} 个广告分片，'
                        '共 ${outcome.removedSeconds.toStringAsFixed(1)} 秒'
                  : 'HLS 去广告：${outcome.detail}',
            );
          }
          onTimelinePrepared?.call(outcome?.timelineKey ?? 'original');
          return proxied;
        });
      } on Exception catch (error) {
        preparation.token.throwIfCancelled();
        return skip(
          'HLS manifest materialization failed: $error',
          budget.timedOut
              ? 'HLS 去广告超过15秒，已保留原视频'
              : 'HLS 去广告未生效：网络或分片处理失败，已保留原视频',
        );
      } finally {
        budget.close();
      }
    } finally {
      if (identical(_hlsPreparation, preparation)) _hlsPreparation = null;
    }
  });

  /// A cancelled (superseded or disposed) preparation never installs its proxy.
  PlaybackMedia _installProxy(HlsProxy proxy) {
    if (SourceOperation.current!.isCancelled) {
      unawaited(proxy.close());
      throw const RequestCancelledException();
    }
    unawaited(_hlsProxy?.close());
    _hlsProxy = proxy;
    return (url: proxy.url, httpHeaders: const <String, String>{});
  }

  static const _originHeaders = {
    'authorization',
    'cookie',
    'host',
    'origin',
    'referer',
  };

  /// Follows redirect-only entry points with HEAD before handing them to
  /// libmpv; origin credentials stay on the original authority.
  Future<PlaybackMedia> _followRedirects(PlaybackMedia media) async {
    final origin = Uri.tryParse(media.url);
    if (origin == null ||
        !origin.isScheme('http') && !origin.isScheme('https')) {
      return media;
    }
    final foreign = {
      for (final entry in media.httpHeaders.entries)
        if (!_originHeaders.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
    final client = useSystemProxy ? _bareDio : _bareDirectDio;
    var current = origin;
    try {
      for (var hop = 0; hop <= 5; hop++) {
        final target = current;
        final headers = target.origin == origin.origin
            ? media.httpHeaders
            : foreign;
        final response = await _bounded(
          _redirectTimeout,
          (cancel) => client.headUri<void>(
            target,
            cancelToken: cancel,
            options: Options(headers: headers, followRedirects: false),
          ),
        );
        final status = response.statusCode ?? 0;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location != null &&
            const {301, 302, 303, 307, 308}.contains(status)) {
          current = target.resolve(location);
          continue;
        }
        if (status >= 200 && status < 400) {
          return (url: '$target', httpHeaders: headers);
        }
        Log.w('Source', '$name: 媒体重定向 HTTP $status: ${target.host}');
        return media;
      }
      Log.w('Source', '$name: 媒体重定向次数过多: ${origin.host}');
    } catch (error) {
      SourceOperation.check();
      Log.w('Source', '$name: 媒体重定向解析失败', error);
    }
    return media;
  }

  Future<Response<ResponseBody>> _fetchTarget(
    Uri uri,
    String method,
    Map<String, String> headers,
  ) => _mediaRequest(
    uri,
    (client) => client.requestUri<ResponseBody>(
      uri,
      options: Options(
        method: method,
        headers: headers,
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
        extra: _playExtra,
      ),
    ),
  );

  /// The manifest may redirect; segments resolve against the final URI.
  Future<HlsPlaylist> _fetchPlaylist(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final decoder = _features.hlsManifestDecode;
    final response = await _mediaRequest(
      uri,
      (client) => client.getUri<Object>(
        uri,
        options: Options(
          headers: headers,
          responseType: decoder == null
              ? ResponseType.plain
              : ResponseType.bytes,
          validateStatus: _isOk,
          extra: _playNoRetry,
        ),
      ),
    );
    final data = response.data!;
    return HlsPlaylist.parse(
      decoder == null
          ? data as String
          : HlsManifestDecoder.decode(data as List<int>, decoder),
      response.realUri,
    );
  }

  /// Stops the request as soon as PAT/PMT and SPS identify the video.
  Future<HlsVideoFingerprint?> _fingerprint(
    Uri segment,
    Map<String, String> headers,
  ) async {
    final cancel = CancelToken();
    try {
      final response = await _mediaRequest(
        segment,
        (client) => client.requestUri<ResponseBody>(
          segment,
          cancelToken: cancel,
          options: Options(
            headers: {
              ...headers,
              HttpHeaders.rangeHeader:
                  'bytes=0-${MpegTsFingerprint.probeBytes - 1}',
            },
            responseType: ResponseType.stream,
            validateStatus: _isOk,
            extra: _playNoRetry,
          ),
        ),
      );
      final reader = MpegTsFingerprint();
      HlsVideoFingerprint? fingerprint;
      await _readPrefix(
        response.data!.stream,
        Uint8List(MpegTsFingerprint.probeBytes),
        (prefix) => (fingerprint = reader.read(prefix)) != null,
      );
      return fingerprint;
    } on DioException {
      SourceOperation.check();
      return null;
    } finally {
      cancel.cancel();
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
      Log.w(
        'Source',
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
      final (html, cookies) = await WebViewAdapter.render(
        url,
        userAgent: _userAgent,
        isReady: isReady,
        timeout: timeout,
        settleDelay: settleDelay,
      );
      SourceOperation.check();
      // Continue the browser session over Dio. document.cookie may hold
      // values that dart:io's Cookie rejects; those are skipped.
      final jar = <Cookie>[];
      for (final (name, value) in WebViewAdapter.cookiePairs(cookies)) {
        try {
          jar.add(Cookie(name, value));
        } on FormatException catch (_) {}
      }
      if (jar.isNotEmpty) {
        await _cookieJar.saveFromResponse(Uri.parse(url), jar);
      }
      return html;
    } catch (e) {
      SourceOperation.check();
      Log.w('Source', '$name: WebView 渲染失败', e);
      return '';
    }
  }

  @override
  Future<String> sniffWithWebview(String url) async {
    if (!allowWebview) return '';
    try {
      return await WebViewAdapter.sniff(
        url,
        userAgent: _userAgent,
        cookieHeader: _ruleHeader('cookie'),
        followEmbeddedPlayer: _features.followsEmbeddedPlayer,
      );
    } catch (e) {
      SourceOperation.check();
      Log.w('Source', '$name: WebView 嗅探失败', e);
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
  bool proxiesMedia = false;
  bool stripsHlsTsPrefix = false;
  bool filtersHlsAds = false;
  bool resolvesMediaRedirects = false;
  bool followsEmbeddedPlayer = false;
  bool usesWebview = false;
  Map<String, dynamic>? hlsManifestDecode;
  PipelineStep? keepAliveStep;

  void _inspect(List<PipelineStep> steps) {
    for (final step in steps) {
      usesDynamicMetadata |= step.op == 'setMediaHeaders';
      // A play page issuing a single-use credential (cookie/session) must run
      // exclusively, or concurrent episodes invalidate each other's token.
      usesCookies |= step.flag('cookieSession');
      validatesWithCookies |= step.flag('validateWithCookies');
      stripsHlsTsPrefix |= step.flag('stripHlsTsPrefix');
      proxiesMedia |= step.flag('proxyMedia');
      materializesHls |=
          proxiesMedia || stripsHlsTsPrefix || step.flag('materializeHls');
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

/// Retries GETs after transient transport failures. Rule requests accept
/// every status below 600, so HTTP errors are left to the pipeline.
class RetryInterceptor extends Interceptor {
  RetryInterceptor(this._dio);

  final Dio _dio;
  static const int _maxRetries = 2;
  static const skipRetryKey = 'anx.skipNetworkRetry';
  static const _countKey = 'anx.retryCount';

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final retries = options.extra[_countKey] as int? ?? 0;
    final transient = switch (err.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      _ => false,
    };
    if (!transient ||
        retries >= _maxRetries ||
        options.method != 'GET' ||
        options.extra[skipRetryKey] == true ||
        (options.cancelToken?.isCancelled ?? false)) {
      return handler.next(err);
    }
    options.extra[_countKey] = retries + 1;
    try {
      handler.resolve(await _dio.fetch(options));
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}
