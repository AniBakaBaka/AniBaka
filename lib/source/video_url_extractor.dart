import 'dart:convert';

/// Video URL extraction and validation utilities.
class VideoUrlExtractor {
  VideoUrlExtractor._();

  /// Key-value pattern: `"url":"https://.../index.m3u8"` etc.
  static final _kvPattern = RegExp(
    r'''["']?(?:url|source|file|video|src|play_url|videoUrl)["']?\s*[:=]\s*["']([^"'\s]+\.(?:m3u8|mp4|flv|mkv|avi|ts|mknvideo)[^"'\s]*)["']''',
    caseSensitive: false,
  );

  /// Direct URL pattern: bare `https://.../play.m3u8` or CDN signed URLs.
  static final _directPattern = RegExp(
    r'https?://[^\s"<>]+?(?:\.(?:m3u8|mp4|flv|mkv|avi|ts|mknvideo)(?:[?#/&][^\s"<>]*)?|/video/tos/|sign\.bytetos|sign\.byteimg|bytefcdn|bot-workflow-sign\.byteimg\.com|mime_type=video|/hls/)[^\s"<>]*',
    caseSensitive: false,
  );

  /// Encoded URL pattern: base64 or URL-encoded video URLs in JSON values.
  static final _encodedPattern = RegExp(
    r'"(?:url|file|src|video|videoUrl|play_url)"\s*:\s*"((?:aHR0|JT|https?%3A%2F%2F)[A-Za-z0-9%+/_=-]{12,})"',
    caseSensitive: false,
  );

  static final _videoExtRegex = RegExp(
    r'\.(?:m3u8|mp4|flv|mkv|avi|ts|mknvideo)(?:[?#/&]|$)',
    caseSensitive: false,
  );

  static final _nonVideoRegex = RegExp(
    r'(?:adposter|advertisement|/ads?/|ad\.m[3p][48u]|poster|thumbnail|tplv-|~tplv|byteimg\.com/(?!tos-|x-signature)|loading\.|ploading|(?:pre|mid|post)roll|commercial|promo\.|banner|\.(?:jpe?g|png|webp|gif|bmp|svg|ico)(?:[?#/&]|$))',
    caseSensitive: false,
  );

  static final _cdnSignedRegex = RegExp(
    r'(?:/video/tos/|/tos-cn-v-|sign\.bytetos|sign\.byteimg|bytefcdn|bot-workflow-sign\.byteimg\.com|xhscdn\.com|douyinvod\.com|bytedance|byteimg\.com/(?:tos-|x-signature)|[?&]verify=\d{9,}|x-amz-signature=|x-amz-algorithm=|x-amz-credential=|groupvideo\.photo\.qq\.com|photo\.qq\.com|dis_k=|dis_t=|ctyunxs\.cn|AWSAccessKeyId=)',
    caseSensitive: false,
  );

  /// `sign=<签名>:<时间戳>` 形式。
  static final _expiringSignRegex = RegExp(r'^.+:\d{9,}$');

  /// `verify=<unix 时间戳>-<签名>` 形式（如 31dm CDN）。
  static final _verifyParamRegex = RegExp(r'^\d{9,}');

  static final _trailingJunkPattern = RegExp(r'[,;.\s]+$');

  static const _queryParamKeys = [
    'url',
    'u',
    'src',
    'file',
    'video',
    'videoUrl',
    'play_url',
    'path',
  ];

  static bool isVideoUrl(String url) {
    if (url.isEmpty) return false;
    final lower = url.toLowerCase();
    return _isVideoUrlLower(lower) || _cdnSignedRegex.hasMatch(lower);
  }

  static bool _isVideoUrlLower(String lower) {
    return _videoExtRegex.hasMatch(lower) ||
        lower.contains('type=m3u8') ||
        lower.contains('mode=playlist') ||
        lower.contains('/hls/') ||
        lower.contains('/index/listres/') ||
        lower.contains('/video/tos/') ||
        lower.contains('mime_type=video') ||
        lower.contains('mime=video');
  }

  /// Whether [url] is an HLS playlist entry, including endpoints whose path
  /// has no `.m3u8` suffix and identifies the playlist through its query.
  static bool isHlsUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') ||
        lower.contains('type=m3u8') ||
        lower.contains('mode=playlist') ||
        lower.contains('/hls/') ||
        lower.contains('/index/listres/');
  }

  static bool isSignedCdnUrl(String url) {
    return _cdnSignedRegex.hasMatch(url) ||
        _hasExpiringSign(url, url.toLowerCase());
  }

  /// 按需生成 / 临时缓存形态的媒体路径：`/temp/2607/01.mp4`、`/cache/...`、
  /// `/dlink/...` 等。
  ///
  /// 这类地址常常在首次播放时才落盘、过一段时间又被回收：首包 404 只说明
  /// 「现在还没有」，不足以判定死链——等几秒同一地址就能播。
  static final _onDemandPathRegex = RegExp(
    r'/(?:temp|tmp|cache|cached|dlink|transcode|hls_tmp|tmpfile)(?:/|$)',
    caseSensitive: false,
  );

  static bool isOnDemandMediaPath(String url) {
    if (url.isEmpty) return false;
    final path = Uri.tryParse(url)?.path;
    if (path == null || path.isEmpty) return false;
    return _onDemandPathRegex.hasMatch(path);
  }

  /// query 中是否带过期型签名参数：
  /// - `sign=<签名>:<时间戳>`
  /// - `verify=<时间戳>-<签名>`（如 31dm）
  static bool _hasExpiringSign(String url, String lower) {
    if (!lower.contains('sign=') && !lower.contains('verify=')) return false;
    try {
      final uri = Uri.parse(url);
      for (final entry in uri.queryParameters.entries) {
        final key = entry.key.toLowerCase();
        if (key == 'sign' && _expiringSignRegex.hasMatch(entry.value)) {
          return true;
        }
        if (key == 'verify' && _verifyParamRegex.hasMatch(entry.value)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  static bool isPlayable(String url) {
    if (url.isEmpty) return false;
    final lower = url.toLowerCase();
    if (lower.startsWith('blob:') || lower == 'about:blank') return false;
    if (lower.contains('mime=image') || lower.contains('image/')) return false;
    if (lower.contains('/index/listres/')) return true;
    final signed =
        _cdnSignedRegex.hasMatch(lower) || _hasExpiringSign(url, lower);
    if (!signed && _nonVideoRegex.hasMatch(lower)) return false;
    return signed ||
        _isVideoUrlLower(lower) ||
        lower.contains('.aliyuncs.com') ||
        lower.contains('.myqcloud.com') ||
        lower.contains('cloudflarestorage') ||
        lower.contains('objstorage');
  }

  /// 网页/播放页形态：`/play/`、`/vod/`、`detail`、`*.html` 等。
  static final _htmlPageRegex = RegExp(
    r'(?:/play/|/video/|/vod/|/bangumi/|/detail/|/ep/|/episode/|/watch/|'
    r'\.html?(?:[?#/&]|$)|/index\.php)',
    caseSensitive: false,
  );

  static final _htmlExtRegex = RegExp(
    r'\.(?:html?|php|aspx?|jsp)(?:[?#/&]|$)',
    caseSensitive: false,
  );

  /// 是否「明确不可能是媒体」：网页播放页、图片、广告位、纯站点根路径。
  ///
  /// 只用于**发起网络探测前**的形态否决。缺少视频扩展名不等于死链——
  /// 网盘直链、`/api/media?id=` 之类的取流地址都没有 `.mp4`，它们只能由
  /// 探测（或播放器）来验证，不能凭形态直接判死。
  static bool looksLikeNonMedia(String url) {
    if (url.isEmpty) return false;
    if (isVideoUrl(url) || isPlayable(url)) return false;
    final lower = url.toLowerCase();
    if (lower.contains('mime=image') || lower.contains('image/')) return true;
    if (_nonVideoRegex.hasMatch(lower)) return true;
    return _htmlExtRegex.hasMatch(lower) || _htmlPageRegex.hasMatch(lower);
  }

  /// 是否是「裸流」地址：绝对 http(s)、主机与非根路径齐备，且不像网页。
  ///
  /// 这类地址形态上无法确认是不是媒体，需保留给可达性探测判定。
  static bool looksLikeBareStream(String url) {
    if (url.isEmpty) return false;
    final lower = url.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    if (looksLikeNonMedia(url)) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty || uri.path.isEmpty) return false;
    return uri.path != '/' && !_htmlExtRegex.hasMatch(uri.path);
  }

  /// 单趟反转义常见的 JS/HTML 转义序列（长序列在前，双反斜杠放最后兜底）。
  static final _escapePattern = RegExp(
    r'''\\u002F|\\u0026|\\"|\\'|\\/|\\\\|&amp;|&quot;''',
  );

  static const _escapeMap = {
    r'\u002F': '/',
    r'\u0026': '&',
    r'\"': '"',
    r"\'": "'",
    r'\/': '/',
    r'\\': '',
    '&amp;': '&',
    '&quot;': '"',
  };

  static String _normalizeUrlText(String text) {
    if (!text.contains(r'\') && !text.contains('&')) return text;
    return text.replaceAllMapped(_escapePattern, (m) => _escapeMap[m[0]]!);
  }

  static String? _tryBase64Decode(String value) {
    try {
      return utf8.decode(base64.decode(base64.normalize(value)));
    } catch (_) {
      return null;
    }
  }

  static String? _decodeEncodedVideoUrl(String encoded) {
    try {
      var text = encoded;
      if (text.contains('%')) text = Uri.decodeComponent(text);
      final decoded = _tryBase64Decode(text);
      if (decoded != null) {
        return decoded.contains('%') ? Uri.decodeComponent(decoded) : decoded;
      }
      return isVideoUrl(text) ? text : null;
    } catch (_) {
      return null;
    }
  }

  /// Extract the best video direct-link from page content.
  /// m3u8 is preferred; otherwise first playable URL wins.
  static String extractBest(String content, String pageUrl) {
    final searchSpace = _normalizeUrlText(content);

    for (final match in _encodedPattern.allMatches(searchSpace)) {
      final decoded = _decodeEncodedVideoUrl(match.group(1) ?? '');
      if (decoded != null && isPlayable(decoded)) {
        return toAbsolute(decoded, pageUrl);
      }
    }

    String? keyedFallback;
    for (final match in _kvPattern.allMatches(searchSpace)) {
      final url = match.group(1) ?? '';
      if (isPlayable(url)) {
        final abs = toAbsolute(url, pageUrl);
        if (abs.contains('.m3u8')) return abs;
        keyedFallback = abs;
        break;
      }
    }

    String? directFallback;
    for (final match in _directPattern.allMatches(searchSpace)) {
      final raw = match.group(0) ?? '';
      // Check nested URL in query params (e.g. `/player?url=...m3u8`)
      final nested = _extractNestedUrl(raw);
      if (nested == null && !isPlayable(raw)) continue;
      final url = nested ?? raw;
      final abs = toAbsolute(url, pageUrl);
      if (abs.contains('.m3u8')) return abs;
      directFallback ??= abs;
    }
    return directFallback ?? keyedFallback ?? '';
  }

  static String? _extractNestedUrl(String playerUrl) {
    if (!playerUrl.contains('?')) return null;
    try {
      final parameters = Uri.parse(playerUrl).queryParameters;
      for (final key in _queryParamKeys) {
        final value = parameters[key];
        if (value == null || value.isEmpty) continue;
        var decoded = value;
        if (decoded.contains('%')) {
          try {
            decoded = Uri.decodeComponent(decoded);
          } catch (_) {}
        }
        // `path` commonly identifies a resource inside a signed media API
        // endpoint. A relative value such as `episodes/1/master.m3u8` is not
        // a nested player URL and must not replace the authenticated endpoint.
        if (key == 'path' &&
            !decoded.startsWith('http://') &&
            !decoded.startsWith('https://') &&
            !decoded.startsWith('//')) {
          continue;
        }
        if (isPlayable(decoded)) return decoded;
        final nested = _decodeEncodedVideoUrl(decoded);
        if (nested != null && isPlayable(nested)) return nested;
      }
    } catch (_) {}
    return null;
  }

  static String toAbsolute(String url, String baseUrl) {
    url = url.trim();
    if (url.isEmpty) return url;
    if (url.startsWith('http')) return url;
    if (url.startsWith('//')) {
      final scheme = Uri.tryParse(baseUrl)?.scheme ?? 'https';
      return '$scheme:$url';
    }
    try {
      return Uri.parse(baseUrl).resolve(url).toString();
    } catch (_) {
      final sep = url.startsWith('/') || baseUrl.endsWith('/') ? '' : '/';
      return '$baseUrl$sep$url';
    }
  }

  static String normalizeResolvedUrl(
    String url,
    String pageUrl, {
    bool preserveMagnet = false,
  }) {
    if (url.isEmpty) return '';
    var text = _normalizeUrlText(url).trim();
    if (text.isEmpty || text.startsWith('blob:')) return '';
    if (preserveMagnet && text.startsWith('magnet:')) return text;
    if (text.startsWith('url=')) text = text.substring(4);

    if (text.length > 1 &&
        ((text.startsWith('"') && text.endsWith('"')) ||
            (text.startsWith("'") && text.endsWith("'")))) {
      text = text.substring(1, text.length - 1);
    }

    final isAbsoluteHttp =
        text.startsWith('http://') || text.startsWith('https://');
    if (!isAbsoluteHttp && !isSignedCdnUrl(text)) {
      for (var i = 0; i < 2; i++) {
        try {
          final decoded = Uri.decodeComponent(text);
          if (decoded == text) break;
          text = decoded;
        } catch (_) {
          break;
        }
      }
    }

    text = text.replaceAll(_trailingJunkPattern, '');

    final nested = _extractNestedUrl(text);
    if (nested != null && nested.isNotEmpty) return toAbsolute(nested, pageUrl);
    return toAbsolute(text, pageUrl);
  }
}
