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

  Future<List<Series>> search(
    String bangumiName,
    String searchKeyword, {
    bool enhanceWithBgm = true,
  });
  Future<List<Source>> getSources(String seriesId);

  Future<String> getDownloadUrl(String episodeId);

  static const Duration _cacheTtl = Duration(minutes: 10);
  static const int _cacheLimit = 128;
  static final Map<String, ({String url, int expiresAt})> _cache = {};

  bool get validatesOwnUrls => false;

  /// Whether auto-match should perform the normal media HTTP probe before
  /// accepting and prefetching a direct URL.
  bool get validateAutoMatchedUrls => false;

  Map<String, String> get mediaValidationHeaders => const {
    'User-Agent': defaultUserAgent,
    'Accept': '*/*',
  };

  Future<String> resolveDownloadUrl(
    String episodeId, {
    bool forceRefresh = false,
    bool skipValidation = false,
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

    final url = await _getDownloadUrlWithRetry(episodeId);
    if (url.isEmpty) {
      debugPrint('$name: resolveDownloadUrl 解析结果为空');
      return '';
    }

    debugPrint(
      '$name: resolveDownloadUrl 得到URL: $url, isSignedCdn=${VideoUrlExtractor.isSignedCdnUrl(url)}, validatesOwnUrls=$validatesOwnUrls',
    );
    if (!skipValidation &&
        !validatesOwnUrls &&
        await _isDirectUrlBlocked(url)) {
      debugPrint('$name: 直链校验未通过: $url');
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

  Future<String> _getDownloadUrlWithRetry(String episodeId) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await getDownloadUrl(episodeId);
      } catch (e) {
        lastError = e;
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 400));
        }
      }
    }
    debugPrint('$name: 直链解析失败: $lastError');
    return '';
  }

  static final Dio _validationDio = Dio(
    BaseOptions(
      followRedirects: true,
      maxRedirects: 5,
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 6),
      validateStatus: (_) => true,
    ),
  );

  Future<bool> _isDirectUrlBlocked(String url) async {
    if (!url.startsWith('http') || !VideoUrlExtractor.isVideoUrl(url)) {
      return false;
    }
    if (VideoUrlExtractor.isSignedCdnUrl(url)) return false;

    // TV 环境下网络通常较差，跳过验证以加速播放并减少误判
    if (Instances.isTV) return false;

    try {
      final headers = mediaValidationHeaders;
      var resp = await _validationDio
          .head(url, options: Options(headers: headers))
          .timeout(const Duration(seconds: 4));

      final status = resp.statusCode ?? 0;
      if (status == 401 ||
          status == 403 ||
          status == 404 ||
          status == 405 ||
          status == 500 ||
          status == 502 ||
          status == 503 ||
          status == 504) {
        resp = await _validationDio
            .get(
              url,
              options: Options(
                headers: {...headers, 'Range': 'bytes=0-0'},
                responseType: ResponseType.bytes,
              ),
            )
            .timeout(const Duration(seconds: 4));
      }

      final code = resp.statusCode ?? 0;
      return code == 401 ||
          code == 403 ||
          code == 404 ||
          code == 500 ||
          code == 502 ||
          code == 503 ||
          code == 504;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.connectionError) {
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<({String url, Map<String, String> httpHeaders})> resolvePlaybackMedia(
    String episodeId, {
    bool skipValidation = false,
  }) async {
    final url = await resolveDownloadUrl(
      episodeId,
      skipValidation: skipValidation,
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
