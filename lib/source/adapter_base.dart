import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/source/webview_adapter.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/services/system_proxy_service.dart';
import 'package:baka/source/runtime/scheduler_interceptor.dart';

/// Base class for all video source adapters.
abstract class AdapterBase {
  final String name;
  final String? description;
  final bool useWebview;

  String get baseUrl;

  Dio? _dio;
  AdapterBase(this.name, {this.description, this.useWebview = false});

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

  Future<void> storeWebViewCookies(String url, String cookieString) async {}

  /// Releases source-scoped background work when its owning service closes.
  void dispose() {
    _dio?.close(force: true);
    _dio = null;
  }

  // ── Abstract contract ───────────────────────────────────────────────

  Future<List<Series>> search(
    String bangumiName,
    String searchKeyword, {
    bool enhanceWithBgm = true,
  });
  Future<List<Source>> getSources(String seriesId);

  Future<List<Source>> getSourcesWithContext(
    String seriesId,
    Map<String, dynamic> context,
  ) => getSources(seriesId);

  Future<String> getDownloadUrl(String episodeId);

  // ── Direct-link resolution with cache + validation ──────────────────

  static const Duration _cacheTtl = Duration(minutes: 10);
  static const int _cacheLimit = 128;
  static final Map<String, ({String url, DateTime expiry})> _cache = {};

  bool get validatesOwnUrls => false;

  Map<String, String> get mediaValidationHeaders => const {
    'User-Agent': defaultUserAgent,
    'Accept': '*/*',
  };

  Future<String> resolveDownloadUrl(
    String episodeId, {
    bool forceRefresh = false,
  }) async {
    final key = '$name|$episodeId';
    if (!forceRefresh) {
      final cached = _cache[key];
      if (cached != null) {
        if (cached.expiry.isAfter(DateTime.now())) return cached.url;
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
    if (!validatesOwnUrls && await _isDirectUrlBlocked(url)) {
      debugPrint('$name: 直链校验未通过: $url');
      return '';
    }

    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    _cache[key] = (url: url, expiry: DateTime.now().add(_cacheTtl));
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
    try {
      final headers = mediaValidationHeaders;
      var resp = await _validationDio
          .head(url, options: Options(headers: headers))
          .timeout(const Duration(seconds: 7));

      final status = resp.statusCode ?? 0;
      if (status == 401 ||
          status == 403 ||
          status == 404 ||
          status == 405 ||
          status == 501 ||
          status == 503) {
        resp = await _validationDio
            .get(
              url,
              options: Options(
                headers: {...headers, 'Range': 'bytes=0-0'},
                responseType: ResponseType.bytes,
              ),
            )
            .timeout(const Duration(seconds: 7));
      }

      final code = resp.statusCode ?? 0;
      return code == 401 || code == 403 || code == 404 || code == 503;
    } catch (_) {
      return false;
    }
  }

  // ── Playback ────────────────────────────────────────────────────────

  bool get requiresCustomPlayback => false;

  Future<({String url, Map<String, String> httpHeaders})> resolvePlaybackMedia(
    String episodeId,
  ) async {
    final url = await resolveDownloadUrl(episodeId);
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

  Future<void> play(String episodeId, VideoController controller) async {
    final url = await resolveDownloadUrl(episodeId);
    if (url.isEmpty) throw Exception('未能解析出播放链接');
    final headers = Map<String, String>.from(mediaValidationHeaders)
      ..removeWhere((_, value) => value.isEmpty);
    if (VideoUrlExtractor.isSignedCdnUrl(url)) {
      headers.removeWhere((key, _) => key.toLowerCase() == 'referer');
    }
    await controller.player.open(
      Media(url, httpHeaders: headers.isNotEmpty ? headers : null),
    );
  }

  // ── Search helpers ──────────────────────────────────────────────────

  Future<List<Series>> performStandardSearch({
    required String bangumiName,
    required String searchKeyword,
    required Future<List<Series>> Function(String keyword) searchFn,
    bool enhanceWithBgm = true,
  }) async {
    final results = <Series>[];
    try {
      if (bangumiName.isNotEmpty) results.addAll(await searchFn(bangumiName));
      if (searchKeyword.isNotEmpty && searchKeyword != bangumiName) {
        results.addAll(await searchFn(searchKeyword));
      }
      final unique = {for (final s in results) s.seriesId: s}.values.toList();
      if (!enhanceWithBgm) return unique;
      try {
        return await _enhanceWithBgmInfo(unique);
      } catch (e) {
        debugPrint('$name BGM enhancement failed: $e');
        return unique;
      }
    } catch (e) {
      debugPrint('$name 搜索失败: $e');
      return [];
    }
  }

  Future<List<Series>> _enhanceWithBgmInfo(
    List<Series> seriesList, {
    int concurrency = 5,
  }) async {
    final results = <Series>[];
    for (var i = 0; i < seriesList.length; i += concurrency) {
      final end = (i + concurrency).clamp(0, seriesList.length);
      final batch = seriesList.sublist(i, end);
      final enhanced = await Future.wait(
        batch.map((series) async {
          try {
            final subject = await BgmService.resolveSubject(title: series.name);
            return Series(
              series.seriesId,
              series.name,
              image: subject?.imageUrl ?? series.image,
              description: subject?.summary ?? series.description ?? '暂无简介',
              bgmId: subject?.subjectId ?? series.bgmId,
              score: subject?.score ?? series.score,
            );
          } catch (_) {
            return series;
          }
        }),
      );
      results.addAll(enhanced);
    }
    return results;
  }

  // ── URL utilities ───────────────────────────────────────────────────

  String ensureAbsoluteUrl(String url, String baseUrl) {
    if (url.isEmpty) return url;
    final trimmed = url.trim();
    if (trimmed.startsWith('http')) return trimmed;
    if (trimmed.startsWith('//')) {
      final scheme = Uri.parse(baseUrl).scheme;
      return '$scheme:$trimmed';
    }
    try {
      return Uri.parse(baseUrl).resolve(trimmed).toString();
    } catch (_) {
      final sep = trimmed.startsWith('/') || baseUrl.endsWith('/') ? '' : '/';
      return '$baseUrl$sep$trimmed';
    }
  }

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
