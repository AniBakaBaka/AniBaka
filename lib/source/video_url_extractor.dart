import 'dart:convert';

/// Video URL extraction and validation utilities.
///
/// Replaces the 404-line VideoUrlMixin with ~120 lines of stateless functions.
/// Key simplifications:
/// - 3 overlapping regex patterns → 2 complementary patterns (single pass)
/// - 8 boolean classifiers (isPosterUrl, isAdUrl, isPlayableVideoUrl, …) → 1 `isPlayable`
/// - No dual content-variant scan; normalize once, scan once
/// - No candidate Set + sort; first m3u8 wins, else first playable
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
    r'(?:/video/tos/|/tos-cn-v-|sign\.bytetos|sign\.byteimg|bytefcdn|bot-workflow-sign\.byteimg\.com|xhscdn\.com|douyinvod\.com|bytedance|byteimg\.com/(?:tos-|x-signature)|r\d+\.31dm\.com/.*[?&]verify=|x-amz-signature=|x-amz-algorithm=|x-amz-credential=|groupvideo\.photo\.qq\.com|photo\.qq\.com|dis_k=|dis_t=)',
    caseSensitive: false,
  );

  static final _expiringSignRegex = RegExp(r'^.+:\d{9,}$');

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
        lower.contains('/hls/') ||
        lower.contains('/video/tos/') ||
        lower.contains('mime_type=video') ||
        lower.contains('mime=video');
  }

  static bool isSignedCdnUrl(String url) {
    final lower = url.toLowerCase();
    return _cdnSignedRegex.hasMatch(lower) || _hasExpiringSign(url, lower);
  }

  /// query 中是否带过期型 sign 参数（`sign=xxx:时间戳`）。
  static bool _hasExpiringSign(String url, String lower) {
    if (!lower.contains('sign=')) return false;
    try {
      final uri = Uri.parse(url);
      for (final entry in uri.queryParameters.entries) {
        if (entry.key.toLowerCase() == 'sign' &&
            _expiringSignRegex.hasMatch(entry.value)) {
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

  static String normalizeUrlText(String text) {
    if (!text.contains(r'\') && !text.contains('&')) return text;
    return text.replaceAllMapped(_escapePattern, (m) => _escapeMap[m[0]]!);
  }

  static String? tryBase64Decode(String value) {
    try {
      return utf8.decode(base64.decode(base64.normalize(value)));
    } catch (_) {
      return null;
    }
  }

  static String? decodeEncodedVideoUrl(String encoded) {
    try {
      var text = encoded;
      if (text.contains('%')) text = Uri.decodeComponent(text);
      final decoded = tryBase64Decode(text);
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
    final searchSpace = normalizeUrlText(content);

    for (final match in _encodedPattern.allMatches(searchSpace)) {
      final decoded = decodeEncodedVideoUrl(match.group(1) ?? '');
      if (decoded != null && isPlayable(decoded)) {
        return toAbsolute(decoded, pageUrl);
      }
    }

    for (final match in _kvPattern.allMatches(searchSpace)) {
      final url = match.group(1) ?? '';
      if (isPlayable(url)) {
        final abs = toAbsolute(url, pageUrl);
        if (abs.contains('.m3u8')) return abs;
        // Continue scanning for m3u8 but keep first as fallback
        final best = _scanDirect(searchSpace, pageUrl);
        return best.isNotEmpty ? best : abs;
      }
    }

    return _scanDirect(searchSpace, pageUrl);
  }

  static String _scanDirect(String searchSpace, String pageUrl) {
    String? fallback;
    for (final match in _directPattern.allMatches(searchSpace)) {
      final raw = match.group(0) ?? '';
      // Check nested URL in query params (e.g. `/player?url=...m3u8`)
      final nested = _extractNestedUrl(raw);
      if (nested == null && !isPlayable(raw)) continue;
      final url = nested ?? raw;
      final abs = toAbsolute(url, pageUrl);
      if (abs.contains('.m3u8')) return abs;
      fallback ??= abs;
    }
    return fallback ?? '';
  }

  static String? _extractNestedUrl(String playerUrl) {
    if (!playerUrl.contains('?')) return null;
    try {
      final uri = Uri.parse(playerUrl);
      for (final key in _queryParamKeys) {
        final value = uri.queryParameters[key];
        if (value == null || value.isEmpty) continue;
        var decoded = value;
        if (decoded.contains('%')) {
          try {
            decoded = Uri.decodeComponent(decoded);
          } catch (_) {}
        }
        if (isPlayable(decoded)) return decoded;
        final nested = decodeEncodedVideoUrl(decoded);
        if (nested != null && isPlayable(nested)) return nested;
      }
    } catch (_) {}
    return null;
  }

  static String toAbsolute(String url, String baseUrl) {
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
    var text = normalizeUrlText(url).trim();
    if (text.isEmpty || text.startsWith('blob:')) return '';
    if (preserveMagnet && text.startsWith('magnet:')) return text;
    if (text.startsWith('url=')) text = text.substring(4);

    if ((text.startsWith('"') && text.endsWith('"')) ||
        (text.startsWith("'") && text.endsWith("'"))) {
      text = text.substring(1, text.length - 1);
    }

    if (!isSignedCdnUrl(text)) {
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
