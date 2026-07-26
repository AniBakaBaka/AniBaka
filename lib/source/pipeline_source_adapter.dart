import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' show parse;
import 'package:cookie_jar/cookie_jar.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/models/episode.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/source/html_parser.dart';
import 'package:baka/source/webview_adapter.dart';
import 'package:baka/source/engine/pipeline_host.dart';
import 'package:baka/source/engine/pipeline_interpreter.dart';
import 'package:baka/source/engine/recipes.dart';
import 'package:baka/source/model/source_rule.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:baka/source/runtime/scheduler_interceptor.dart';
import 'package:baka/services/remote_media_redirect_resolver.dart';

/// Connects a source rule to the adapter and pipeline host contracts.
class PipelineSourceAdapter extends AdapterBase
    implements PipelineHost, PipelineWebviewReadyHost {
  PipelineSourceAdapter(SourceRule rule)
    : rule = Recipes.expand(rule),
      super(
        rule.name,
        description: rule.description,
        useWebview: rule.useWebview,
      );

  final SourceRule rule;
  static const PipelineInterpreter _interpreter = PipelineInterpreter();
  late final CookieJar _cookieJar = CookieJar();
  WebViewTaskScope? _webViewTaskScope;
  RemoteMediaRedirectResolver? _mediaRedirectResolver;
  Future<void>? _playCookieBarrier;
  Timer? _playbackKeepAliveTimer;
  int _playbackKeepAliveGeneration = 0;
  int? _playbackKeepAliveInFlightGeneration;
  HttpServer? _hlsProxyServer;
  StreamSubscription<HttpRequest>? _hlsProxySubscription;
  Map<String, Uri> _hlsProxyTargets = const {};
  Map<String, String> _hlsProxyHeaders = const {};
  late final _playFeatures = _inspectPlayFeatures(rule.play);
  // Rule Hub rev 1 of 4kcz predates this flag. Keep installed copies working
  // while rev 2 rolls out; new rules opt in explicitly.
  late final bool _followsEmbeddedPlayer =
      rule.id == '4kcz' || _playFeatures.followsEmbeddedPlayer;

  @override
  String get baseUrl => rule.baseUrl;

  @override
  Map<String, String> get ruleHeaders => rule.headers;

  @override
  bool get allowWebview => rule.useWebview;

  @override
  bool get useSystemProxy => !rule.directConnection;

  @override
  Dio createDio({Map<String, String>? extraHeaders}) {
    final dio = super.createDio(
      extraHeaders: {...rule.headers, ...?extraHeaders},
    );
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
  bool get validateAutoMatchedUrls => rule.id == 'cycani';

  @override
  void dispose() {
    _webViewTaskScope?.cancel();
    _mediaRedirectResolver?.close();
    stopPlaybackKeepAlive();
    super.dispose();
  }

  @override
  Map<String, String> get mediaValidationHeaders {
    final headers = Map<String, String>.from(rule.headers)
      ..removeWhere((_, value) => value.isEmpty);
    return headers.isEmpty ? super.mediaValidationHeaders : headers;
  }

  @override
  Future<List<Series>> search(
    String bangumiName,
    String searchKeyword, {
    bool enhanceWithBgm = true,
  }) => performStandardSearch(
    bangumiName: bangumiName,
    searchKeyword: searchKeyword,
    searchFn: (keyword) => _interpreter.runSearch(rule, this, keyword),
    enhanceWithBgm: enhanceWithBgm,
  );

  @override
  Future<List<Source>> getSources(String seriesId) =>
      _interpreter.runDetail(rule, this, seriesId);

  @override
  Future<String> getDownloadUrl(String episodeId) {
    if (!_playFeatures.usesCookies) {
      return _interpreter.runPlay(rule, this, episodeId);
    }
    return _withPlayCookieSnapshot(
      () => _interpreter.runPlay(rule, this, episodeId),
    );
  }

  @override
  Future<({String url, Map<String, String> httpHeaders})> resolvePlaybackMedia(
    String episodeId, {
    bool skipValidation = false,
  }) async {
    if (!_playFeatures.usesDynamicMetadata) {
      return super.resolvePlaybackMedia(
        episodeId,
        skipValidation: skipValidation,
      );
    }
    return _withPlayCookieSnapshot(() async {
      final media = await _interpreter.runPlayMedia(rule, this, episodeId);
      if (media.url.isEmpty) {
        return (url: '', httpHeaders: const <String, String>{});
      }
      return (url: media.url, httpHeaders: await _resolveMediaHeaders(media));
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
        variables[entry.key.toString()] = _renderPlaybackTemplate(
          entry.value.toString(),
          variables,
        );
      }
    }

    final urlTemplate = step.str('url')?.trim() ?? '';
    final keepAliveUrl = _renderPlaybackTemplate(urlTemplate, variables);
    final keepAliveUri = Uri.tryParse(keepAliveUrl);
    if (keepAliveUri == null || !keepAliveUri.hasScheme) {
      debugPrint('${rule.id}: invalid playback keep-alive URL: $keepAliveUrl');
      return;
    }

    final headers = <String, String>{};
    final rawHeaders = step.params['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = _renderPlaybackTemplate(
          entry.value.toString(),
          variables,
        );
      }
    }

    final generation = ++_playbackKeepAliveGeneration;
    await _sendPlaybackKeepAlive(
      generation,
      keepAliveUri,
      headers,
      step.str('expectedBody')?.trim(),
    );
    if (generation != _playbackKeepAliveGeneration) return;

    final intervalSeconds = (step.intValue('intervalSeconds') ?? 10)
        .clamp(1, 300)
        .toInt();
    _playbackKeepAliveTimer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => unawaited(
        _sendPlaybackKeepAlive(
          generation,
          keepAliveUri,
          headers,
          step.str('expectedBody')?.trim(),
        ),
      ),
    );
  }

  @override
  Future<({String url, Map<String, String> httpHeaders})> preparePlaybackMedia(
    ({String url, Map<String, String> httpHeaders}) media,
  ) async {
    var prepared = media;
    if (_playFeatures.resolvesMediaRedirects) {
      final resolvedUrl =
          await (_mediaRedirectResolver ??= RemoteMediaRedirectResolver())
              .resolve(media.url, headers: media.httpHeaders);
      if (resolvedUrl != media.url) {
        prepared = (
          url: resolvedUrl,
          httpHeaders: _headersForRedirectTarget(media.httpHeaders),
        );
      }
    }

    if (!(rule.id == 'ani_pekolove' || _playFeatures.materializesHls) ||
        !prepared.url.toLowerCase().contains('.m3u8')) {
      return prepared;
    }
    final manifestUri = Uri.tryParse(prepared.url);
    if (manifestUri == null || !manifestUri.hasScheme) return prepared;

    try {
      final response = await dio.getUri<String>(
        manifestUri,
        options: Options(
          headers: prepared.httpHeaders,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      final body = response.data ?? '';
      final status = response.statusCode ?? 0;
      if (status < 200 ||
          status >= 300 ||
          !body.startsWith('#EXTM3U') ||
          !body.contains('#EXT-X-ENDLIST')) {
        debugPrint(
          '${rule.id}: unable to materialize complete HLS manifest '
          '(HTTP $status, ${body.length} chars)',
        );
        return prepared;
      }

      final proxyUrl = await _startHlsProxy(
        body,
        manifestUri,
        prepared.httpHeaders,
      );
      return (url: proxyUrl, httpHeaders: const <String, String>{});
    } catch (error) {
      debugPrint('${rule.id}: HLS manifest materialization failed: $error');
      return prepared;
    }
  }

  static Map<String, String> _headersForRedirectTarget(
    Map<String, String> headers,
  ) {
    return Map<String, String>.from(headers)..removeWhere((name, _) {
      switch (name.toLowerCase()) {
        case 'authorization':
        case 'cookie':
        case 'host':
        case 'origin':
        case 'referer':
          return true;
        default:
          return false;
      }
    });
  }

  @override
  void stopPlaybackKeepAlive() {
    _playbackKeepAliveGeneration++;
    _playbackKeepAliveTimer?.cancel();
    _playbackKeepAliveTimer = null;
    unawaited(_stopHlsProxy());
  }

  Future<String> _startHlsProxy(
    String body,
    Uri manifestUri,
    Map<String, String> headers,
  ) async {
    await _stopHlsProxy();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final secret = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final baseUrl = 'http://${server.address.address}:${server.port}/$secret';
    final targets = <String, Uri>{};
    final targetIds = <String, String>{};

    String proxyUrlFor(Uri target) {
      final targetKey = target.toString();
      final existing = targetIds[targetKey];
      if (existing != null) return '$baseUrl/media/$existing';
      final id = targets.length.toRadixString(36);
      targets[id] = target;
      targetIds[targetKey] = id;
      return '$baseUrl/media/$id';
    }

    final materialized = _materializeHlsManifest(
      body,
      manifestUri,
      proxyUrlFor,
    );
    if (!materialized.contains('#EXT-X-MEDIA-SEQUENCE:0') ||
        !materialized.contains('#EXT-X-ENDLIST')) {
      await server.close(force: true);
      throw const FormatException('incomplete VOD manifest');
    }

    _hlsProxyServer = server;
    _hlsProxyTargets = Map<String, Uri>.unmodifiable(targets);
    _hlsProxyHeaders = Map<String, String>.unmodifiable(headers);
    _hlsProxySubscription = server.listen(
      (request) =>
          unawaited(_handleHlsProxyRequest(request, secret, materialized)),
    );
    return '$baseUrl/manifest.m3u8';
  }

  Future<void> _handleHlsProxyRequest(
    HttpRequest request,
    String secret,
    String manifest,
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
      final target = _hlsProxyTargets[segments[2]];
      if (target == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final headers = Map<String, String>.from(_hlsProxyHeaders);
      for (final name in const [
        HttpHeaders.rangeHeader,
        HttpHeaders.ifRangeHeader,
        HttpHeaders.ifModifiedSinceHeader,
        HttpHeaders.ifNoneMatchHeader,
      ]) {
        final value = request.headers.value(name);
        if (value != null && value.isNotEmpty) headers[name] = value;
      }
      final remote = await dio.requestUri<ResponseBody>(
        target,
        options: Options(
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
        final value = remote.headers.value(name);
        if (value != null && value.isNotEmpty) {
          response.headers.set(name, value);
        }
      }
      final stream = remote.data?.stream;
      if (request.method != 'HEAD' && stream != null) {
        await response.addStream(stream);
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
    final subscription = _hlsProxySubscription;
    final server = _hlsProxyServer;
    _hlsProxySubscription = null;
    _hlsProxyServer = null;
    _hlsProxyTargets = const {};
    _hlsProxyHeaders = const {};
    try {
      await subscription?.cancel();
    } catch (_) {}
    try {
      await server?.close(force: true);
    } catch (_) {}
  }

  static String _materializeHlsManifest(
    String body,
    Uri manifestUri,
    String Function(Uri target) proxyUrlFor,
  ) {
    final uriAttribute = RegExp(r'URI="([^"]+)"');
    return body
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return '';
          if (!trimmed.startsWith('#')) {
            return proxyUrlFor(manifestUri.resolve(trimmed));
          }
          return line.replaceAllMapped(uriAttribute, (match) {
            final resolved = manifestUri.resolve(match.group(1)!);
            return 'URI="${proxyUrlFor(resolved)}"';
          });
        })
        .join('\n');
  }

  Future<void> _sendPlaybackKeepAlive(
    int generation,
    Uri url,
    Map<String, String> headers,
    String? expectedBody,
  ) async {
    if (generation != _playbackKeepAliveGeneration ||
        _playbackKeepAliveInFlightGeneration == generation) {
      return;
    }
    _playbackKeepAliveInFlightGeneration = generation;
    try {
      final response = await dio.getUri<String>(
        url,
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
      if (_playbackKeepAliveInFlightGeneration == generation) {
        _playbackKeepAliveInFlightGeneration = null;
      }
    }
  }

  static final RegExp _playbackTemplatePattern = RegExp(
    r'\{([a-zA-Z0-9_]+)(:raw)?\}',
  );

  static String _renderPlaybackTemplate(
    String template,
    Map<String, String> variables,
  ) {
    if (!template.contains('{')) return template;
    return template.replaceAllMapped(_playbackTemplatePattern, (match) {
      final value = variables[match.group(1)!] ?? '';
      return match.group(2) == null ? Uri.encodeComponent(value) : value;
    });
  }

  Future<T> _withPlayCookieSnapshot<T>(Future<T> Function() action) async {
    if (!_playFeatures.usesCookies) return action();
    final previous = _playCookieBarrier ?? Future<void>.value();
    final release = Completer<void>();
    _playCookieBarrier = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  Future<Map<String, String>> _resolveMediaHeaders(
    PipelinePlayResult media,
  ) async {
    final headers = media.mediaHeaders.isEmpty
        ? Map<String, String>.from(rule.headers)
        : Map<String, String>.from(media.mediaHeaders);
    headers.removeWhere((_, value) => value.isEmpty);
    if (headers.isEmpty) headers.addAll(super.mediaValidationHeaders);
    if (VideoUrlExtractor.isSignedCdnUrl(media.url)) {
      headers.removeWhere((key, _) => key.toLowerCase() == 'referer');
    }
    if (media.cookieNames.isEmpty && media.cookiePrefixes.isEmpty) {
      return headers;
    }

    try {
      final exactNames = media.cookieNames.toSet();
      final prefixes = media.cookiePrefixes.where((p) => p.isNotEmpty).toList();
      final cookies = await _cookieJar.loadForRequest(Uri.parse(media.url));
      final filtered = <String, String>{};
      for (final cookie in cookies) {
        final allowed =
            exactNames.contains(cookie.name) ||
            prefixes.any((p) => cookie.name.startsWith(p));
        if (allowed && cookie.value.isNotEmpty) {
          filtered[cookie.name] = cookie.value;
        }
      }
      final cookieHeader = filtered.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');
      if (cookieHeader.isNotEmpty) {
        final cookieKey = headers.keys.cast<String?>().firstWhere(
          (key) => key?.toLowerCase() == 'cookie',
          orElse: () => null,
        );
        if (cookieKey == null || (headers[cookieKey] ?? '').trim().isEmpty) {
          headers['Cookie'] = cookieHeader;
        } else {
          headers[cookieKey] = '${headers[cookieKey]}; $cookieHeader';
        }
      }
    } catch (_) {}
    return headers;
  }

  static ({
    bool usesDynamicMetadata,
    bool usesCookies,
    bool validatesWithCookies,
    bool materializesHls,
    bool resolvesMediaRedirects,
    bool followsEmbeddedPlayer,
    PipelineStep? keepAliveStep,
  })
  _inspectPlayFeatures(List<PipelineStep> steps) {
    var usesDynamicMetadata = false;
    var usesCookies = false;
    var validatesWithCookies = false;
    var materializesHls = false;
    var resolvesMediaRedirects = false;
    var followsEmbeddedPlayer = false;
    PipelineStep? keepAliveStep;

    void inspect(List<PipelineStep> current) {
      for (final step in current) {
        if (step.op == 'setMediaHeaders' || step.op == 'anime1Play') {
          usesDynamicMetadata = true;
        }
        if (step.op == 'anime1Play') usesCookies = true;
        validatesWithCookies |= step.flag('validateWithCookies');
        materializesHls |= step.flag('materializeHls');
        resolvesMediaRedirects |= step.flag('resolveMediaRedirects');
        followsEmbeddedPlayer |= step.flag('followEmbeddedPlayer');
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
      resolvesMediaRedirects: resolvesMediaRedirects,
      followsEmbeddedPlayer: followsEmbeddedPlayer,
      keepAliveStep: keepAliveStep,
    );
  }

  @override
  String toAbsolute(String url, String base) =>
      ensureAbsoluteUrl(url, base.isEmpty ? baseUrl : base);

  @override
  String normalizeUrl(String url, String pageUrl) =>
      VideoUrlExtractor.normalizeResolvedUrl(
        url,
        pageUrl.isEmpty ? baseUrl : pageUrl,
        preserveMagnet: true,
      );

  @override
  bool isPlayable(String url) => VideoUrlExtractor.isPlayable(url);

  @override
  Future<String> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    Object? body,
    String? referer,
    String? contentType,
    RequestPriority priority = RequestPriority.search,
    RequestCancelToken? cancelToken,
  }) async {
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
            SchedulerInterceptor.priorityKey: priority.index,
            SchedulerInterceptor.cancelKey: ?cancelToken,
          },
        ),
      );
      return resp.data?.toString() ?? '';
    } on DioException catch (e) {
      debugPrint('$name: fetch 失败 $url: ${e.message ?? e.type.name}');
      return '';
    }
  }

  @override
  List<Series> parseSearchList(
    String html, {
    required List<String> selectors,
    String? detailPattern,
  }) => HtmlParser.parseSearchResults(
    html,
    baseUrl: baseUrl,
    selectors: selectors,
    detailPattern: detailPattern,
  );

  @override
  List<Series> parseSearchListXPath(
    String html, {
    required String listXPath,
    required String nameXPath,
    required String linkXPath,
  }) {
    final results = <Series>[];
    try {
      final docEl = parse(html).documentElement;
      if (docEl == null) return results;
      final nodes = docEl.queryXPath(listXPath).nodes;
      for (final node in nodes) {
        final linkNode = linkXPath.isEmpty
            ? node
            : node.queryXPath(linkXPath).node;
        final href = linkNode?.attributes['href'] ?? '';
        if (href.isEmpty) continue;
        final name =
            (nameXPath.isEmpty
                ? node.node.text
                : node.queryXPath(nameXPath).node?.text) ??
            '';
        results.add(
          Series(
            ensureAbsoluteUrl(href, baseUrl),
            name.trim().isEmpty ? '未知标题' : name.trim(),
          ),
        );
      }
    } catch (e) {
      debugPrint('$name: XPath 搜索解析失败: $e');
    }
    return results;
  }

  @override
  List<Source> parseEpisodes(
    String html, {
    required List<String> listSelectors,
    List<String>? tabSelectors,
  }) {
    if (html.trim().isEmpty) return const [];
    return HtmlParser.parseSources(
      parse(html),
      baseUrl: baseUrl,
      listSelectors: listSelectors.isEmpty ? null : listSelectors,
      tabSelectors: tabSelectors,
    );
  }

  @override
  List<Source> parseEpisodesXPath(
    String html, {
    required String roadsXPath,
    required String itemsXPath,
  }) {
    final sources = <Source>[];
    try {
      final docEl = parse(html).documentElement;
      if (docEl == null) return sources;
      final roads = docEl.queryXPath(roadsXPath).nodes;
      var count = 1;
      for (final road in roads) {
        final items = road.queryXPath(itemsXPath).nodes;
        final episodes = <Episode>[];
        for (var i = 0; i < items.length; i++) {
          final href = items[i].attributes['href'] ?? '';
          if (href.isEmpty) continue;
          var name = items[i].node.text?.replaceAll(RegExp(r'\s+'), '') ?? '';
          if (name.isEmpty) name = '第${i + 1}集';
          episodes.add(Episode(ensureAbsoluteUrl(href, baseUrl), i, name));
        }
        if (episodes.isNotEmpty) {
          sources.add(Source(episodes, '播放列表$count'));
          count++;
        }
      }
    } catch (e) {
      debugPrint('$name: XPath 剧集解析失败: $e');
    }
    return sources;
  }

  @override
  String extractVideoUrl(String content, String pageUrl) =>
      VideoUrlExtractor.extractBest(
        content,
        pageUrl.isEmpty ? baseUrl : pageUrl,
      );

  @override
  String? selectAttr(String html, String selector, String attr) {
    try {
      final element = parse(html).querySelector(selector);
      if (element == null) return null;
      return attr == 'text' ? element.text.trim() : element.attributes[attr];
    } catch (_) {
      return null;
    }
  }

  @override
  List<String> selectAll(String html, String selector, String attr) {
    try {
      return parse(html)
          .querySelectorAll(selector)
          .map(
            (e) => attr == 'text' ? e.text.trim() : (e.attributes[attr] ?? ''),
          )
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<String> renderWithWebview(String url) => renderWithWebviewReady(url);

  @override
  Future<String> renderWithWebviewReady(
    String url, {
    bool Function(String html)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = const Duration(seconds: 1),
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
      if (cookies.isNotEmpty) await storeWebViewCookies(url, cookies);
      return html;
    } catch (e) {
      debugPrint('$name: WebView 渲染失败: $e');
      return '';
    }
  }

  @override
  Future<void> storeWebViewCookies(String url, String cookieString) async {
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
      debugPrint('$name: WebView Cookie 同步失败: $e');
    }
  }

  @override
  Future<String> sniffWithWebview(String url) async {
    try {
      return await WebViewAdapter.extractVideoUrl(
            url,
            userAgent: requestUserAgent,
            followEmbeddedPlayer: _followsEmbeddedPlayer,
            taskScope: _webViewTaskScope ??= WebViewTaskScope(),
          ) ??
          '';
    } catch (e) {
      debugPrint('$name: WebView 嗅探失败: $e');
      return '';
    }
  }
}
