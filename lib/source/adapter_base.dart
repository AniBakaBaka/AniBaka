import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/source/webview_adapter.dart';
import 'package:baka/core/network_service.dart';
import 'package:baka/instance.dart';
import 'package:baka/source/runtime/scheduler_interceptor.dart';

/// 直链可达性探测的结论。
enum MediaReachabilityVerdict { reachable, rejected, unknown }

/// Base class for all video source adapters.
abstract class AdapterBase {
  final String name;

  String get baseUrl;

  final SourceOperation _lifetime = SourceOperation();
  bool _disposed = false;
  int _activeOperations = 0;
  bool get hasActiveOperations => _activeOperations > 0;
  VoidCallback? onIdle;
  Future<T> runOperation<T>(
    Future<T> Function() action, {
    SourceOperation? operation,
  }) async {
    if (_disposed) throw const RequestCancelledException();
    final scope = SourceOperation(parent: operation ?? SourceOperation.current);
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

  Dio? _dio;
  final Map<String, Object> _pendingDownloadUrls = {};
  AdapterBase(this.name);

  /// Signed media sources can opt out when their token and playback requests
  /// must use the same direct network exit.
  bool get useSystemProxy => true;

  Dio get dio {
    if (_disposed) throw const RequestCancelledException();
    SourceOperation.check();
    return _dio ??= createDio();
  }

  Dio createDio() {
    final dio = Dio(
      BaseOptions(
        headers: {
          'User-Agent': defaultUserAgent,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          'Connection': 'keep-alive',
        },
        followRedirects: true,
        maxRedirects: 5,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (status) => status != null && status < 600,
      ),
    );
    dio.httpClientAdapter = NetworkService.createDioAdapter(
      useSystemProxy: useSystemProxy,
    );
    dio.interceptors.add(SchedulerInterceptor());
    dio.interceptors.add(RetryInterceptor(dio));
    return dio;
  }

  static const String defaultUserAgent = WebViewAdapter.desktopUserAgent;
  String get requestUserAgent => defaultUserAgent;

  /// Releases source-scoped background work when its owning service closes.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onIdle = null;
    _lifetime.cancel();
    _pendingDownloadUrls.clear();
    _cache.removeWhere((key, _) => identical(key.$1, this));
    _dio?.close(force: true);
    _dio = null;
  }

  Future<List<Series>> search(String query, {bool enhanceWithBgm = true});
  Future<PlaybackCatalog> getPlaybackCatalog(String seriesId);

  Future<String> getDownloadUrl(String episodeId);

  static const Duration _cacheTtl = Duration(minutes: 10);
  static const int _cacheLimit = 128;
  static final Map<(AdapterBase, String), ({String url, int expiresAt})>
  _cache = {};

  /// 可达性探测结果缓存（含负缓存），避免同一死链在匹配/换线时反复拖超时。
  static const Duration _reachCacheTtl = Duration(minutes: 3);
  static const Duration _reachNegCacheTtl = Duration(minutes: 8);
  static const int _reachCacheLimit = 256;
  static final Map<
    (String, bool),
    ({bool ok, int expiresAt, int timeoutMs, Map<String, String> headers})
  >
  _reachCache = {};

  bool get validatesOwnUrls => false;

  /// Shared request headers with empty values removed by the adapter.
  Map<String, String> get mediaValidationHeaders => const {
    'User-Agent': defaultUserAgent,
    'Accept': '*/*',
  };

  Future<String> resolveDownloadUrl(
    String episodeId, {
    bool forceRefresh = false,
    bool skipValidation = false,
    int maxAttempts = 2,
    Duration? reachTimeout,
    SourceOperation? operation,
  }) => runOperation(
    () => _resolveDownloadUrl(
      episodeId,
      forceRefresh: forceRefresh,
      skipValidation: skipValidation,
      maxAttempts: maxAttempts,
      reachTimeout: reachTimeout,
    ),
    operation: operation,
  );

  Future<String> _resolveDownloadUrl(
    String episodeId, {
    bool forceRefresh = false,
    bool skipValidation = false,
    int maxAttempts = 2,
    Duration? reachTimeout,
  }) async {
    if (_disposed) throw const RequestCancelledException();
    SourceOperation.check();
    final key = (this, episodeId);
    if (!forceRefresh) {
      final cached = _cache[key];
      if (cached != null) {
        if (cached.expiresAt > DateTime.now().millisecondsSinceEpoch) {
          return cached.url;
        }
        _cache.remove(key);
      }
    }

    // Invalidating or starting a newer refresh must prevent this parse from
    // restoring a stale URL after its asynchronous work finishes.
    final pending = Object();
    _pendingDownloadUrls[episodeId] = pending;
    try {
      final url = await _getDownloadUrlWithRetry(
        episodeId,
        maxAttempts: maxAttempts,
      );
      SourceOperation.check();
      if (url.isEmpty) {
        debugPrint('$name: resolveDownloadUrl(episodeId: $episodeId) 解析结果为空');
        return '';
      }

      debugPrint('$name: resolveDownloadUrl 得到URL: $url');
      if (!skipValidation && !validatesOwnUrls) {
        final verdict = await probeMediaReachability(
          url,
          timeout: reachTimeout,
        );
        if (verdict == MediaReachabilityVerdict.rejected) {
          debugPrint('$name: 直链被服务器拒绝，丢弃: $url');
          return '';
        }
        if (verdict == MediaReachabilityVerdict.unknown) {
          debugPrint('$name: 直链结论不确定（超时/临时缺失/网络异常），保留待播放器验证: $url');
        }
      }

      SourceOperation.check();
      if (_disposed) throw const RequestCancelledException();
      if (identical(_pendingDownloadUrls[episodeId], pending)) {
        if (_cache.length >= _cacheLimit && !_cache.containsKey(key)) {
          _cache.remove(_cache.keys.first);
        }
        _cache[key] = (
          url: url,
          expiresAt:
              DateTime.now().millisecondsSinceEpoch + _cacheTtl.inMilliseconds,
        );
      }
      return url;
    } finally {
      if (identical(_pendingDownloadUrls[episodeId], pending)) {
        _pendingDownloadUrls.remove(episodeId);
      }
    }
  }

  void invalidateDownloadUrl(String episodeId) {
    _pendingDownloadUrls.remove(episodeId);
    _cache.remove((this, episodeId));
  }

  /// 探测媒体 URL 是否真正可拉取（自动匹配认领前必须通过）。
  Future<bool> isPlaybackUrlReachable(String url, {Duration? timeout}) =>
      runOperation(
        () async =>
            await probeMediaReachability(url, timeout: timeout) !=
            MediaReachabilityVerdict.rejected,
      );

  /// 探测结论版的可达性检查，供需要区分「被拒」与「未知」的调用方使用。
  @protected
  Future<MediaReachabilityVerdict> probeMediaReachability(
    String url, {
    Duration? timeout,
    Map<String, String>? headers,
  }) async {
    SourceOperation.check();
    if (_disposed) throw const RequestCancelledException();
    final value = url.trim();
    if (value.isEmpty) return MediaReachabilityVerdict.rejected;
    final lower = value.toLowerCase();
    if (lower.startsWith('magnet:') || lower.contains('.torrent')) {
      return MediaReachabilityVerdict.reachable;
    }
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      return MediaReachabilityVerdict.rejected;
    }
    if (validatesOwnUrls) return MediaReachabilityVerdict.reachable;

    final probeTimeoutMs = timeout?.inMilliseconds ?? 0;
    final effectiveHeaders = headers ?? mediaValidationHeaders;
    final key = (value, useSystemProxy);
    final cached = _reachCache[key];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (cached != null) {
      if (cached.expiresAt > now &&
          mapEquals(cached.headers, effectiveHeaders) &&
          (cached.ok || probeTimeoutMs <= cached.timeoutMs)) {
        return cached.ok
            ? MediaReachabilityVerdict.reachable
            : MediaReachabilityVerdict.rejected;
      }
      _reachCache.remove(key);
    }

    // Snapshot before awaiting so mutable caller headers cannot change the
    // request or make its cached verdict describe another credential set.
    final probeHeaders = Map<String, String>.of(effectiveHeaders);
    final verdict = await _probeDirectUrl(
      value,
      timeout: timeout,
      headers: probeHeaders,
    );
    SourceOperation.check();
    if (_disposed) throw const RequestCancelledException();
    // 只缓存明确结论。「未知」一旦被负缓存，同一个可用地址会在之后数分钟
    // 里持续被误杀（负缓存 TTL 是 8 分钟）；临时媒体地址随时可能被重新
    // 生成，同样不做负缓存。
    final cacheable = switch (verdict) {
      MediaReachabilityVerdict.reachable => true,
      MediaReachabilityVerdict.unknown => false,
      MediaReachabilityVerdict.rejected =>
        !VideoUrlExtractor.isOnDemandMediaPath(value),
    };
    if (cacheable) {
      if (_reachCache.length >= _reachCacheLimit &&
          !_reachCache.containsKey(key)) {
        _reachCache.remove(_reachCache.keys.first);
      }
      final ok = verdict == MediaReachabilityVerdict.reachable;
      _reachCache[key] = (
        ok: ok,
        expiresAt:
            DateTime.now().millisecondsSinceEpoch +
            (ok ? _reachCacheTtl : _reachNegCacheTtl).inMilliseconds,
        timeoutMs: probeTimeoutMs,
        headers: probeHeaders,
      );
    }
    return verdict;
  }

  Future<String> _getDownloadUrlWithRetry(
    String episodeId, {
    int maxAttempts = 2,
  }) async {
    final attempts = maxAttempts < 1 ? 1 : maxAttempts;
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      SourceOperation.check();
      try {
        return await getDownloadUrl(episodeId);
      } on RequestCancelledException {
        rethrow;
      } catch (e) {
        SourceOperation.check();
        lastError = e;
      }
    }
    debugPrint('$name: 直链解析失败: $lastError');
    return '';
  }

  static Dio _createValidationDio(bool useSystemProxy) =>
      Dio(
          BaseOptions(
            followRedirects: true,
            maxRedirects: 3,
            receiveTimeout: const Duration(milliseconds: 2500),
            sendTimeout: const Duration(milliseconds: 2000),
            validateStatus: (_) => true,
          ),
        )
        ..httpClientAdapter = NetworkService.createDioAdapter(
          useSystemProxy: useSystemProxy,
        );

  /// 探测用的共享客户端。路由必须和规则本身一致：声明 `directConnection`
  /// 的源若被拿去做代理探测，会因出口不同被判成死链。
  static final Dio _validationDio = _createValidationDio(true);
  static final Dio _validationDirectDio = _createValidationDio(false);

  Dio get _probeDio => useSystemProxy ? _validationDio : _validationDirectDio;

  /// 服务器明确表示「没有/不许」的状态，可直接判死链。
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

  // Temporary media may not exist yet; an HTML/JSON auth rejection is definitive.
  static bool _shouldKeepEphemeralOnReject(int status, String? contentType) =>
      switch (status) {
        HttpStatus.unauthorized || HttpStatus.forbidden =>
          contentType == null || !_htmlLikeContentType.hasMatch(contentType),
        HttpStatus.notFound ||
        HttpStatus.gone ||
        HttpStatus.internalServerError ||
        HttpStatus.badGateway ||
        HttpStatus.serviceUnavailable ||
        HttpStatus.gatewayTimeout => true,
        _ => false,
      };

  static final RegExp _htmlLikeContentType = RegExp(
    r'^\s*(?:text/html|application/xhtml|text/xml|application/xml|'
    r'application/json|image/)',
    caseSensitive: false,
  );

  Future<Response<dynamic>> _requestProbe(
    String url,
    Duration timeout, {
    required Map<String, String> headers,
    String method = 'GET',
    bool readPlaylist = false,
  }) {
    SourceOperation.check();
    final cancelToken = CancelToken();
    final detach = SourceOperation.current?.token.onCancel(
      () => cancelToken.cancel('source cancelled'),
    );
    return _probeDio
        .request(
          url,
          cancelToken: cancelToken,
          options: Options(
            method: method,
            headers: headers,
            responseType: ResponseType.stream,
            receiveTimeout: timeout,
            sendTimeout: timeout,
          ),
        )
        .then((response) async {
          if (response.data case final ResponseBody body) {
            if (readPlaylist &&
                (response.statusCode == 200 || response.statusCode == 206)) {
              response.data = await _readPlaylistPrefix(body, cancelToken);
            } else {
              await body.stream.listen(null, onError: (Object _) {}).cancel();
              if (readPlaylist) response.data = (text: '', truncated: false);
            }
          }
          return response;
        })
        .timeout(timeout)
        .whenComplete(() {
          detach?.call();
          cancelToken.cancel('media probe complete');
        });
  }

  static Future<({String text, bool truncated})> _readPlaylistPrefix(
    ResponseBody body,
    CancelToken cancelToken,
  ) async {
    const limit = 2048;
    final bytes = Uint8List(limit);
    var length = 0;
    var text = '';
    await for (final chunk in body.stream) {
      if (chunk.isEmpty) continue;
      final remaining = limit - length;
      final count = chunk.length < remaining ? chunk.length : remaining;
      bytes.setRange(length, length + count, chunk);
      length += count;
      text = utf8.decode(
        Uint8List.sublistView(bytes, 0, length),
        allowMalformed: true,
      );
      if (_playlistPrefixVerdict(text) != MediaReachabilityVerdict.unknown) {
        cancelToken.cancel('playlist prefix complete');
        return (text: text, truncated: false);
      }
      if (length == limit) {
        cancelToken.cancel('playlist prefix limit');
        return (text: text, truncated: true);
      }
    }
    return (text: text, truncated: false);
  }

  static MediaReachabilityVerdict _playlistPrefixVerdict(String text) {
    final value = text.trimLeft();
    final upper = (value.length > 128 ? value.substring(0, 128) : value)
        .toUpperCase();
    if (upper.startsWith('<!DOCTYPE') ||
        upper.contains('<HTML') ||
        upper.startsWith('{') ||
        upper.startsWith('[')) {
      return MediaReachabilityVerdict.rejected;
    }
    if (upper.contains('#EXT') || value.contains('#EXT')) {
      return MediaReachabilityVerdict.reachable;
    }
    return MediaReachabilityVerdict.unknown;
  }

  Future<MediaReachabilityVerdict> _probeDirectUrl(
    String url, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    if (VideoUrlExtractor.looksLikeNonMedia(url)) {
      return MediaReachabilityVerdict.rejected;
    }
    if (VideoUrlExtractor.isSignedCdnUrl(url)) {
      return MediaReachabilityVerdict.reachable;
    }

    // 竞速默认更狠：手机 ~1.8s，TV ~2.2s；调用方可再收紧。
    final probeTimeout =
        timeout ??
        (Instances.isTV
            ? const Duration(milliseconds: 2200)
            : const Duration(milliseconds: 1800));

    try {
      final isHls = VideoUrlExtractor.isHlsUrl(url);

      if (isHls) {
        final resp = await _requestProbe(
          url,
          probeTimeout,
          headers: {
            ...headers,
            'Range': 'bytes=0-2047',
            'Accept': 'application/vnd.apple.mpegurl,application/x-mpegURL,*/*',
          },
          readPlaylist: true,
        );
        final prefix = resp.data as ({String text, bool truncated});
        final verdict = _playlistPrefixVerdict(prefix.text);
        if (verdict != MediaReachabilityVerdict.unknown) return verdict;
        if (prefix.truncated) return MediaReachabilityVerdict.unknown;
        // 临时媒体上的播放列表同样可能尚未生成或本次未放行：保留待播放器验证。
        if (VideoUrlExtractor.isOnDemandMediaPath(url) &&
            _shouldKeepEphemeralOnReject(
              resp.statusCode ?? 0,
              resp.headers.value(HttpHeaders.contentTypeHeader),
            )) {
          return MediaReachabilityVerdict.unknown;
        }
        return MediaReachabilityVerdict.rejected;
      }

      // 非 HLS：先 HEAD（快失败），再必要时 Range GET 一轮。
      var resp = await _requestProbe(
        url,
        probeTimeout,
        method: 'HEAD',
        headers: headers,
      );

      var code = resp.statusCode ?? 0;
      var contentType = resp.headers.value(HttpHeaders.contentTypeHeader);
      if (code != HttpStatus.ok && code != HttpStatus.partialContent) {
        if (code != HttpStatus.methodNotAllowed &&
            !_rejectedStatuses.contains(code)) {
          // 405/416/429/3xx 之类既非成功也非拒绝，不足以判死链。
          return MediaReachabilityVerdict.unknown;
        }
        // HEAD 被拒时只补一轮短 GET，不再拖第二长超时。
        final getTimeout = Duration(
          milliseconds: (probeTimeout.inMilliseconds * 0.85).round(),
        );
        resp = await _requestProbe(
          url,
          getTimeout,
          headers: {...headers, 'Range': 'bytes=0-0'},
        );
        code = resp.statusCode ?? 0;
        contentType = resp.headers.value(HttpHeaders.contentTypeHeader);
      }

      if (code == HttpStatus.ok || code == HttpStatus.partialContent) {
        if (contentType != null && _htmlLikeContentType.hasMatch(contentType)) {
          return MediaReachabilityVerdict.rejected;
        }
        return MediaReachabilityVerdict.reachable;
      }
      if (_rejectedStatuses.contains(code)) {
        if (VideoUrlExtractor.isOnDemandMediaPath(url) &&
            _shouldKeepEphemeralOnReject(code, contentType)) {
          return MediaReachabilityVerdict.unknown;
        }
        return MediaReachabilityVerdict.rejected;
      }
      return MediaReachabilityVerdict.unknown;
    } catch (_) {
      SourceOperation.check();
      // A timeout or transport failure does not establish a dead URL.
      return MediaReachabilityVerdict.unknown;
    }
  }

  Future<({String url, Map<String, String> httpHeaders})> resolvePlaybackMedia(
    String episodeId, {
    bool skipValidation = false,
    int maxAttempts = 2,
    Duration? reachTimeout,
  }) async {
    final url = await resolveDownloadUrl(
      episodeId,
      skipValidation: skipValidation,
      maxAttempts: maxAttempts,
      reachTimeout: reachTimeout,
    );
    final headers = mediaValidationHeaders;
    return (
      url: url,
      httpHeaders:
          url.isNotEmpty &&
              VideoUrlExtractor.isSignedCdnUrl(url) &&
              headers.keys.any((key) => key.toLowerCase() == 'referer')
          ? {
              for (final entry in headers.entries)
                if (entry.key.toLowerCase() != 'referer')
                  entry.key: entry.value,
            }
          : headers,
    );
  }

  /// Starts any source-specific authorization refresh required while the
  /// resolved media is actively playing.
  Future<void> startPlaybackKeepAlive(String mediaUrl) =>
      SynchronousFuture(null);

  /// Allows adapters to prepare a stable player-facing representation of a
  /// resolved media URL, for example by materializing a remote HLS manifest.
  Future<({String url, Map<String, String> httpHeaders})> preparePlaybackMedia(
    ({String url, Map<String, String> httpHeaders}) media, {
    bool? filterHlsAds,
    void Function(String message)? onHlsAdFilterStatus,
    void Function(String key)? onTimelinePrepared,
  }) => SynchronousFuture(media);

  /// Stops the active playback authorization refresh, if any.
  void stopPlaybackKeepAlive() {}

  @override
  String toString() => name;
}

/// GET request retry interceptor for transient network errors.
class RetryInterceptor extends Interceptor {
  final Dio dio;
  static const int _maxRetries = 2;
  // A playback pipeline with its own browser fallback owns recovery instead.
  static const skipRetryKey = 'anx.skipNetworkRetry';

  RetryInterceptor(this.dio);

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final opts = err.requestOptions;
    final retries = (opts.extra['__retry_count'] as int?) ?? 0;
    if (retries >= _maxRetries || !_shouldRetry(err)) {
      return handler.next(err);
    }
    opts.extra['__retry_count'] = retries + 1;
    try {
      handler.resolve(await dio.fetch(opts));
    } on DioException catch (e) {
      handler.next(e);
    } catch (_) {
      handler.next(err);
    }
  }

  bool _shouldRetry(DioException e) {
    if (e.requestOptions.extra[skipRetryKey] == true) return false;
    if (e.requestOptions.cancelToken?.isCancelled ?? false) return false;
    if (e.requestOptions.method.toUpperCase() != 'GET') return false;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        return code == 429 || code == 502 || code == 503 || code == 504;
      default:
        return false;
    }
  }
}
