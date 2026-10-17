import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baka/core/network_service.dart';
import 'package:http/http.dart' as http;
import 'package:baka/source/webview_adapter.dart';

class SiteProbeRequest {
  const SiteProbeRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
    this.render = false,
  });

  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;
  final bool render;

  factory SiteProbeRequest.fromJson(Map<String, dynamic> json) {
    return SiteProbeRequest(
      method: json['method'] as String,
      url: json['url'] as String,
      headers:
          (json['headers'] as Map<String, dynamic>?)?.cast<String, String>() ??
          const {},
      body: json['body'] as String?,
      render: json['render'] as bool? ?? false,
    );
  }
}

class SiteProbeService {
  SiteProbeService()
    : _client = NetworkService.createClient(
        connectTimeout: const Duration(seconds: 8),
      );

  static const int maxResponseBytes = 16 * 1024;
  static const int maxRequestBodyBytes = 32 * 1024;

  static final RegExp _sensitivePattern = RegExp(
    r'token|auth|sign|key|password|cookie',
    caseSensitive: false,
  );
  static final RegExp _exceptionPrefixPattern = RegExp(
    r'^\w+(?:Exception)?:\s*',
  );
  static final RegExp _bearerPattern = RegExp(
    r'Bearer\s+\S+',
    caseSensitive: false,
  );
  static final RegExp _urlPattern = RegExp(r'https?://[^\s]+');

  static const _sensitiveHeaders = {
    'authorization',
    'cookie',
    'host',
    'content-length',
    'connection',
    'proxy-authorization',
    'x-api-key',
  };

  final http.Client _client;
  final WebViewTaskScope _webViewScope = WebViewTaskScope();
  final Map<String, List<Cookie>> _cookies = {};
  bool _cancelled = false;

  void dispose() {
    if (_cancelled) return;
    _cancelled = true;
    _webViewScope.cancel();
    _client.close();
    _cookies.clear();
  }

  Future<Map<String, dynamic>> execute(SiteProbeRequest request) async {
    _throwIfCancelled();
    final method = request.method;
    if (method != 'GET' && method != 'HEAD' && method != 'POST') {
      throw FormatException('不允许的探测方法：$method');
    }
    final originalUri = Uri.parse(request.url);
    var uri = originalUri;
    final body = method == 'POST' && request.body != null
        ? utf8.encode(request.body!)
        : null;
    if (body != null && body.length > maxRequestBodyBytes) {
      throw const FormatException('探测请求体过大');
    }

    if (request.render) {
      if (method != 'GET') throw const FormatException('WebView 探测只允许 GET');
      await validatePublicUri(uri);
      _throwIfCancelled();
      final (html, _) = await WebViewAdapter.getPageContentWithCookies(
        uri.toString(),
        timeout: const Duration(seconds: 30),
        userAgent:
            request.headers['User-Agent'] ?? WebViewAdapter.desktopUserAgent,
        taskScope: _webViewScope,
      );
      _throwIfCancelled();
      final bytes = utf8.encoder.convert(
        html,
        0,
        html.length > maxResponseBytes ? maxResponseBytes : html.length,
      );
      final truncated =
          html.length > maxResponseBytes || bytes.length > maxResponseBytes;
      return {
        'request': {'method': method, 'url': safeUrl(uri), 'render': true},
        'status': html.isEmpty ? 0 : 200,
        'finalUrl': safeUrl(uri),
        'contentType': 'text/html; rendered=webview',
        'headers': <String, String>{},
        'body': truncated
            ? utf8.decode(
                Uint8List.sublistView(bytes, 0, maxResponseBytes),
                allowMalformed: true,
              )
            : html,
        'truncated': truncated,
      };
    }

    for (var redirect = 0; ; redirect++) {
      await validatePublicUri(uri);
      _throwIfCancelled();
      final abort = Completer<void>();
      void cancel() {
        if (!abort.isCompleted) abort.complete();
      }

      final req = http.AbortableRequest(
        method,
        uri,
        abortTrigger: abort.future,
      );
      final timer = Timer(const Duration(seconds: 12), cancel);
      try {
        req.followRedirects = false;
        req.headers[HttpHeaders.userAgentHeader] = 'AniBaka-AI-Rule-Probe/1.0';
        req.headers[HttpHeaders.acceptHeader] = '*/*';
        for (final entry in request.headers.entries) {
          if (_sensitiveHeaders.contains(entry.key.toLowerCase())) continue;
          req.headers[entry.key] = entry.value;
        }
        final cookies = _cookies[uri.host];
        if (cookies != null && cookies.isNotEmpty) {
          req.headers[HttpHeaders.cookieHeader] = cookies
              .map((cookie) => '${cookie.name}=${cookie.value}')
              .join('; ');
        }
        if (body != null) req.bodyBytes = body;

        final response = await _client
            .send(req)
            .timeout(const Duration(seconds: 12));
        final receivedCookies =
            response.headersSplitValues[HttpHeaders.setCookieHeader];
        if (receivedCookies != null && receivedCookies.isNotEmpty) {
          _cookies[uri.host] = receivedCookies
              .map(Cookie.fromSetCookieValue)
              .toList();
        }
        final location = response.headers[HttpHeaders.locationHeader];
        if (response.isRedirect && location != null) {
          if (redirect == 3) throw StateError('探测重定向次数过多');
          uri = uri.resolve(location);
          await response.stream.listen(null).cancel();
          continue;
        }

        final bytes = BytesBuilder(copy: false);
        var truncated = false;
        await for (final chunk in response.stream) {
          final remaining = maxResponseBytes - bytes.length;
          if (chunk.length < remaining) {
            bytes.add(chunk);
            continue;
          }
          bytes.add(
            chunk is Uint8List
                ? Uint8List.sublistView(chunk, 0, remaining)
                : chunk.sublist(0, remaining),
          );
          truncated =
              chunk.length > remaining ||
              response.contentLength != maxResponseBytes ||
              response.headers[HttpHeaders.contentEncodingHeader] == 'gzip';
          break;
        }

        return {
          'request': {'method': method, 'url': safeUrl(originalUri)},
          'status': response.statusCode,
          'finalUrl': safeUrl(uri),
          'contentType': response.headers[HttpHeaders.contentTypeHeader] ?? '',
          'headers': {
            for (final name in const ['content-type', 'location', 'server'])
              if (response.headers[name] != null) name: response.headers[name],
          },
          'body': utf8.decode(bytes.takeBytes(), allowMalformed: true),
          'truncated': truncated,
        };
      } finally {
        timer.cancel();
        cancel();
      }
    }
  }

  static Future<void> validatePublicUri(Uri uri) async {
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw const FormatException('只允许公开 HTTP(S) 地址');
    }
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost')) {
      throw const FormatException('不允许访问本机地址');
    }
    final addresses =
        await (NetworkService.resolver?.lookup(host) ??
                InternetAddress.lookup(host))
            .timeout(const Duration(seconds: 5));
    if (addresses.isEmpty || addresses.any(_isPrivateAddress)) {
      throw const FormatException('不允许访问私网或保留地址');
    }
  }

  void _throwIfCancelled() {
    if (_cancelled) throw StateError('AI 规则任务已取消');
  }

  static bool _isPrivateAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return _isPrivateIpv4(bytes[0], bytes[1]);
    }
    if (bytes.length == 16) {
      var isMapped = bytes[10] == 0xff && bytes[11] == 0xff;
      if (isMapped) {
        for (var i = 0; i < 10; i++) {
          if (bytes[i] != 0) {
            isMapped = false;
            break;
          }
        }
      }
      if (isMapped) return _isPrivateIpv4(bytes[12], bytes[13]);

      var allZero = true;
      for (var i = 0; i < 16; i++) {
        if (bytes[i] != 0) {
          allZero = false;
          break;
        }
      }
      if (allZero) return true;

      final b0 = bytes[0];
      if (b0 == 0xfc || b0 == 0xfd) return true;
      return b0 == 0xfe && (bytes[1] & 0xc0) == 0x80;
    }
    return false;
  }

  static bool _isPrivateIpv4(int a, int b) =>
      a == 0 ||
      a == 10 ||
      a == 127 ||
      (a == 169 && b == 254) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      a >= 224;

  static String safeUrl(Uri uri) {
    return uri
        .replace(
          userInfo: '',
          queryParameters: uri.hasQuery
              ? {
                  for (final entry in uri.queryParameters.entries)
                    entry.key: _sensitivePattern.hasMatch(entry.key)
                        ? '<redacted>'
                        : entry.value,
                }
              : null,
        )
        .removeFragment()
        .toString();
  }

  static String safeError(Object error, {int maxLength = 500}) {
    var text = error.toString().replaceFirst(_exceptionPrefixPattern, '');
    text = text.replaceAll(_bearerPattern, 'Bearer <redacted>');
    text = text.replaceAllMapped(_urlPattern, (match) {
      final uri = Uri.tryParse(match.group(0)!);
      if (uri == null) return '<url>';
      return safeUrl(uri);
    });
    return text.length <= maxLength ? text : '${text.substring(0, maxLength)}…';
  }
}
