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
      for (var redirect = 0; redirect <= _maxRedirects; redirect++) {
        final request = await _client.headUrl(current).timeout(_requestTimeout);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        // Source-site credentials belong only to the entry authority. The
        // download CDN rejects this media when xifanacg's Referer is leaked
        // across the redirect.
        if (_sameAuthority(current, original)) {
          for (final header in headers.entries) {
            if (!_isHopByHop(header.key)) {
              request.headers.set(header.key, header.value);
            }
          }
        }

        final response = await request.close().timeout(_requestTimeout);
        final location = response.headers.value(HttpHeaders.locationHeader);
        final isRedirect =
            location != null &&
            location.isNotEmpty &&
            _isRedirectStatus(response.statusCode);
        await response.drain<void>().timeout(_requestTimeout);

        if (!isRedirect) {
          if (response.statusCode >= 200 && response.statusCode < 400) {
            if (current != original) {
              debugPrint(
                '[RemoteMediaResolver] ${original.host} -> '
                '${current.host}:${current.port}',
              );
            }
            return current.toString();
          }
          debugPrint(
            '[RemoteMediaResolver] HTTP ${response.statusCode} for '
            '${current.host}',
          );
          return remoteUrl;
        }

        current = current.resolve(location);
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

  static bool _isHopByHop(String name) {
    switch (name.toLowerCase()) {
      case 'connection':
      case 'content-length':
      case 'host':
      case 'keep-alive':
      case 'proxy-authenticate':
      case 'proxy-authorization':
      case 'te':
      case 'trailer':
      case 'transfer-encoding':
      case 'upgrade':
        return true;
      default:
        return false;
    }
  }

  void close() => _client.close(force: true);
}
