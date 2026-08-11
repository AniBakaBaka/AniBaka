import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/source/webview_adapter.dart';
import 'package:baka/services/system_proxy_service.dart';
import 'package:baka/instance.dart';
import 'package:baka/source/runtime/scheduler_interceptor.dart';

/// Base class for all video source adapters.
abstract class AdapterBase {
  final String name;

  String get baseUrl;

  Dio? _dio;
  AdapterBase(this.name);

  /// Signed media sources can opt out when their token and playback requests
  /// must use the same direct network exit.
  bool get useSystemProxy => true;

  Dio get dio => _dio ??= createDio();

  Dio createDio({Map<String, String>? extraHeaders}) {
    final dio = Dio(
      BaseOptions(
        headers: {
          'User-Agent': defaultUserAgent,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          'Connection': 'keep-alive',
          ...?extraHeaders,
        },
        followRedirects: true,
        maxRedirects: 5,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (status) => status != null && status < 600,
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: useSystemProxy
          ? SystemProxyService.createHttpClient
          : SystemProxyService.createDirectHttpClient,
    );
    dio.interceptors.add(SchedulerInterceptor());
    dio.interceptors.add(RetryInterceptor(dio));
    return dio;
  }

  static const String defaultUserAgent = WebViewAdapter.desktopUserAgent;
  String get requestUserAgent => defaultUserAgent;

  /// Releases source-scoped background work when its owning service closes.
  void dispose() {
    _dio?.close(force: true);
    _dio = null;
  }

  Future<List<Series>> search(String query, {bool enhanceWithBgm = true});
  Future<PlaybackCatalog> getPlaybackCatalog(String seriesId);

  Future<String> getDownloadUrl(String episodeId);

  static const Duration _cacheTtl = Duration(minutes: 10);
  static const int _cacheLimit = 128;
  static final Map<String, ({String url, int expiresAt})> _cache = {};

  /// 可达性探测结果缓存（含负缓存），避免同一死链在匹配/换线时反复拖超时。
  static const Duration _reachCacheTtl = Duration(minutes: 3);
  static const Duration _reachNegCacheTtl = Duration(minutes: 8);
  static const int _reachCacheLimit = 256;
  static final Map<String, ({bool ok, int expiresAt, int timeoutMs})>
  _reachCache = {};

  bool get validatesOwnUrls => false;

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
  }) async {
    final key = '$name|$episodeId';
    if (!forceRefresh) {
      final cached = _cache[key];
      if (cached != null) {
        if (cached.expiresAt > DateTime.now().millisecondsSinceEpoch) {
          return cached.url;
        }
        _cache.remove(key);
      }
    }

    final url = await _getDownloadUrlWithRetry(
      episodeId,
      maxAttempts: maxAttempts,
    );
    if (url.isEmpty) {
      debugPrint('$name: resolveDownloadUrl 解析结果为空');
      return '';
    }

    debugPrint(
      '$name: resolveDownloadUrl 得到URL: $url, isSignedCdn=${VideoUrlExtractor.isSignedCdnUrl(url)}, validatesOwnUrls=$validatesOwnUrls',
    );
    if (!skipValidation &&
        !validatesOwnUrls &&
        !await isPlaybackUrlReachable(url, timeout: reachTimeout)) {
      debugPrint('$name: 直链不可达/不可播，丢弃: $url');
      return '';
    }

    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    _cache[key] = (
      url: url,
      expiresAt:
          DateTime.now().millisecondsSinceEpoch + _cacheTtl.inMilliseconds,
    );
    return url;
  }

  /// 探测媒体 URL 是否真正可拉取（自动匹配认领前必须通过）。
  ///
  /// 与「URL 形态像 m3u8」不同：很多源会吐出 403/空壳 CDN 地址，
  /// 形态合法但播放器打不开——此类必须判为不可达。
  Future<bool> isPlaybackUrlReachable(String url, {Duration? timeout}) async {
    final value = url.trim();
    if (value.isEmpty) return false;
    final lower = value.toLowerCase();
    if (lower.startsWith('magnet:') || lower.contains('.torrent')) {
      return true;
    }
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      return false;
    }
    if (validatesOwnUrls) return true;

    final probeTimeoutMs = timeout?.inMilliseconds ?? 0;
    final cached = _reachCache[value];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (cached != null) {
      if (cached.expiresAt > now &&
          (cached.ok || probeTimeoutMs <= cached.timeoutMs)) {
        return cached.ok;
      }
      _reachCache.remove(value);
    }

    final blocked = await _isDirectUrlBlocked(value, timeout: timeout);
    _putReachCache(value, !blocked, probeTimeoutMs);
    return !blocked;
  }

  static void _putReachCache(String url, bool ok, int timeoutMs) {
    if (_reachCache.length >= _reachCacheLimit) {
      _reachCache.remove(_reachCache.keys.first);
    }
    final ttl = ok ? _reachCacheTtl : _reachNegCacheTtl;
    _reachCache[url] = (
      ok: ok,
      expiresAt: DateTime.now().millisecondsSinceEpoch + ttl.inMilliseconds,
      timeoutMs: timeoutMs,
    );
  }

  Future<String> _getDownloadUrlWithRetry(
    String episodeId, {
    int maxAttempts = 2,
  }) async {
    final attempts = maxAttempts < 1 ? 1 : maxAttempts;
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        return await getDownloadUrl(episodeId);
      } catch (e) {
        lastError = e;
        if (attempt + 1 < attempts) {
          await Future.delayed(const Duration(milliseconds: 250));
        }
      }
    }
    debugPrint('$name: 直链解析失败: $lastError');
    return '';
  }

  static final Dio _validationDio = Dio(
    BaseOptions(
      followRedirects: true,
      maxRedirects: 3,
      // The whole request is bounded by each probe's effective timeout below.
      // Leaving connectTimeout unset lets slow-source rules extend that bound.
      receiveTimeout: const Duration(milliseconds: 2200),
      sendTimeout: const Duration(milliseconds: 1800),
      validateStatus: (_) => true,
    ),
  );

  static Future<Response<dynamic>> _runValidationProbe(
    Future<Response<dynamic>> Function(CancelToken cancelToken) send,
    Duration timeout,
  ) {
    final cancelToken = CancelToken();
    return send(cancelToken).timeout(
      timeout,
      onTimeout: () {
        cancelToken.cancel('media reachability probe timed out');
        throw TimeoutException('media reachability probe timed out', timeout);
      },
    );
  }

  Future<bool> _isDirectUrlBlocked(String url, {Duration? timeout}) async {
    if (!url.startsWith('http')) return true;
    // 非视频形态（HTML 页等）直接视为不可播，避免误当直链。
    if (!VideoUrlExtractor.isVideoUrl(url) &&
        !VideoUrlExtractor.isPlayable(url)) {
      return true;
    }
    if (VideoUrlExtractor.isSignedCdnUrl(url)) return false;

    // 竞速默认更狠：手机 ~1.8s，TV ~2.2s；调用方可再收紧。
    final probeTimeout =
        timeout ??
        (Instances.isTV
            ? const Duration(milliseconds: 2200)
            : const Duration(milliseconds: 1800));

    try {
      final headers = mediaValidationHeaders;
      final isHls = url.toLowerCase().contains('.m3u8');

      // m3u8：Range 小 GET，很多 CDN 对 HEAD 一律 403，对列表片段才如实。
      if (isHls) {
        final resp = await _runValidationProbe(
          (cancelToken) => _validationDio.get(
            url,
            cancelToken: cancelToken,
            options: Options(
              headers: {
                ...headers,
                'Range': 'bytes=0-2047',
                'Accept':
                    'application/vnd.apple.mpegurl,application/x-mpegURL,*/*',
              },
              responseType: ResponseType.plain,
              receiveTimeout: probeTimeout,
              sendTimeout: probeTimeout,
              // 覆盖 BaseOptions，避免慢网拖满默认值。
              extra: const {'__reach_probe': true},
            ),
          ),
          probeTimeout,
        );
        return !_playlistLooksAlive(resp.statusCode, resp.data?.toString());
      }

      // 非 HLS：先 HEAD（快失败），再必要时 Range GET 一轮。
      var resp = await _runValidationProbe(
        (cancelToken) => _validationDio.head(
          url,
          cancelToken: cancelToken,
          options: Options(
            headers: headers,
            receiveTimeout: probeTimeout,
            sendTimeout: probeTimeout,
          ),
        ),
        probeTimeout,
      );

      final status = resp.statusCode ?? 0;
      if (status == 200 || status == 206) return false;
      if (status == 401 ||
          status == 403 ||
          status == 404 ||
          status == 405 ||
          status == 500 ||
          status == 502 ||
          status == 503 ||
          status == 504) {
        // HEAD 被拒时只补一轮短 GET，不再拖第二长超时。
        final getTimeout = Duration(
          milliseconds: (probeTimeout.inMilliseconds * 0.85).round(),
        );
        resp = await _runValidationProbe(
          (cancelToken) => _validationDio.get(
            url,
            cancelToken: cancelToken,
            options: Options(
              headers: {...headers, 'Range': 'bytes=0-0'},
              responseType: ResponseType.bytes,
              receiveTimeout: getTimeout,
              sendTimeout: getTimeout,
            ),
          ),
          getTimeout,
        );
      }

      final code = resp.statusCode ?? 0;
      if (code == 200 || code == 206) return false;
      return code == 401 ||
          code == 403 ||
          code == 404 ||
          code == 500 ||
          code == 502 ||
          code == 503 ||
          code == 504 ||
          code == 0;
    } on DioException catch (_) {
      return true;
    } catch (_) {
      return true;
    }
  }

  /// HLS 播放列表是否像真可播（2xx + `#EXT` 头），否则视为死链/防盗链页。
  static bool _playlistLooksAlive(int? statusCode, String? body) {
    final code = statusCode ?? 0;
    if (code != 200 && code != 206) return false;
    final text = body?.trimLeft() ?? '';
    if (text.isEmpty) return false;
    // 防盗链常返回 HTML/JSON 错误页。
    final head = text.length > 64 ? text.substring(0, 64) : text;
    final upper = head.toUpperCase();
    if (upper.startsWith('#EXT')) return true;
    if (upper.startsWith('<!DOCTYPE') ||
        upper.startsWith('<HTML') ||
        upper.startsWith('{') ||
        upper.contains('<HTML')) {
      return false;
    }
    // 少数网关先吐 BOM/空白再给标签，宽松一点。
    return text.contains('#EXT');
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
    final headers = Map<String, String>.from(mediaValidationHeaders)
      ..removeWhere((_, value) => value.isEmpty);
    if (url.isNotEmpty && VideoUrlExtractor.isSignedCdnUrl(url)) {
      headers.removeWhere((key, _) => key.toLowerCase() == 'referer');
    }
    return (url: url, httpHeaders: headers);
  }

  /// Starts any source-specific authorization refresh required while the
  /// resolved media is actively playing.
  Future<void> startPlaybackKeepAlive(String mediaUrl) async {}

  /// Allows adapters to prepare a stable player-facing representation of a
  /// resolved media URL, for example by materializing a remote HLS manifest.
  Future<({String url, Map<String, String> httpHeaders})> preparePlaybackMedia(
    ({String url, Map<String, String> httpHeaders}) media,
  ) async => media;

  /// Stops the active playback authorization refresh, if any.
  void stopPlaybackKeepAlive() {}

  @override
  String toString() => name;
}

/// GET request retry interceptor for transient network errors.
class RetryInterceptor extends Interceptor {
  final Dio dio;
  static const int _maxRetries = 2;

  RetryInterceptor(this.dio);

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final opts = err.requestOptions;
    final retries = (opts.extra['__retry_count'] as int?) ?? 0;
    if (retries >= _maxRetries || !_shouldRetry(err)) {
      return handler.next(err);
    }
    opts.extra['__retry_count'] = retries + 1;
    await Future.delayed(Duration(milliseconds: 300 * (retries + 1)));
    try {
      handler.resolve(await dio.fetch(opts));
    } on DioException catch (e) {
      handler.next(e);
    } catch (_) {
      handler.next(err);
    }
  }

  bool _shouldRetry(DioException e) {
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
