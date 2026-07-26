import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Resolves redirect-only media entry points before handing them to libmpv.
///
/// Some Android vendor networks can resolve the entry host in Dart but libmpv
/// fails while following the redirect itself. Passing the final HTTPS URL keeps
/// playback native: mpv still owns Range requests, seeking, buffering and
/// reconnects, while Dart only performs a small HEAD redirect lookup.
class RemoteMediaRedirectResolver {
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

  final HttpClient _client = HttpClient()
    ..connectionTimeout = _requestTimeout
    ..idleTimeout = const Duration(seconds: 15)
    ..userAgent = 'Baka Media Resolver';

  Future<String> resolve(
    String remoteUrl, {
    Map<String, String> headers = const {},
  }) async {
    final original = Uri.tryParse(remoteUrl);
    if (original == null ||
        (original.scheme != 'http' && original.scheme != 'https')) {
      return remoteUrl;
    }

    var current = original;
    try {
      for (var hop = 0; hop <= _maxRedirects; hop++) {
        final request = await _client.headUrl(current).timeout(_requestTimeout);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        // Source-site credentials belong only to the entry authority. The
        // download CDN rejects this media when xifanacg's Referer is leaked
        // across the redirect.
        if (_sameAuthority(current, original)) {
          for (final header in headers.entries) {
            if (!_hopByHop.contains(header.key.toLowerCase())) {
              request.headers.set(header.key, header.value);
            }
          }
        }

        final response = await request.close().timeout(_requestTimeout);
        final location = response.headers.value(HttpHeaders.locationHeader);
        final status = response.statusCode;
        await response.drain<void>().timeout(_requestTimeout);

        if (location != null &&
            location.isNotEmpty &&
            _isRedirectStatus(status)) {
          current = current.resolve(location);
          continue;
        }

        if (status >= 200 && status < 400) {
          if (current != original) {
            debugPrint(
              '[RemoteMediaResolver] ${original.host} -> '
              '${current.host}:${current.port}',
            );
          }
          return current.toString();
        }
        debugPrint('[RemoteMediaResolver] HTTP $status for ${current.host}');
        return remoteUrl;
      }
      debugPrint(
        '[RemoteMediaResolver] too many redirects for ${original.host}',
      );
    } catch (error) {
      debugPrint('[RemoteMediaResolver] ${original.host} failed: $error');
    }
    return remoteUrl;
  }

  static bool _isRedirectStatus(int status) =>
      status == HttpStatus.movedPermanently ||
      status == HttpStatus.found ||
      status == HttpStatus.seeOther ||
      status == HttpStatus.temporaryRedirect ||
      status == HttpStatus.permanentRedirect;

  static bool _sameAuthority(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  void close() => _client.close(force: true);
}
