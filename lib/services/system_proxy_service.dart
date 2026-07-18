import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

/// Makes Dart HTTP clients honor the active Windows/WinInet proxy.
///
/// Browsers automatically use this setting, while `dart:io` defaults to a
/// direct connection unless an environment proxy is present. Source rules and
/// torrent metadata downloads share this resolver so browser verification and
/// in-app execution use the same network route.
class SystemProxyService {
  SystemProxyService._();

  static const String _internetSettings =
      r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  static String? _proxyServer;
  static List<String> _bypassPatterns = const <String>[];

  static void initialize() {
    _proxyServer = null;
    _bypassPatterns = const <String>[];
    if (!Platform.isWindows) return;

    RegistryKey? key;
    try {
      key = Registry.openPath(
        RegistryHive.currentUser,
        path: _internetSettings,
      );
      if (key.getIntValue('ProxyEnable') != 1) return;
      final server = key.getStringValue('ProxyServer')?.trim();
      if (server == null || server.isEmpty) return;
      _proxyServer = server;
      _bypassPatterns = (key.getStringValue('ProxyOverride') ?? '')
          .split(';')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      _proxyServer = null;
      _bypassPatterns = const <String>[];
    } finally {
      key?.close();
    }
  }

  static HttpClient createHttpClient() {
    final client = HttpClient();
    client.findProxy = findProxy;
    return client;
  }

  static HttpClient createDirectHttpClient() {
    final client = HttpClient();
    client.findProxy = directProxy;
    return client;
  }

  static String directProxy(Uri _) => 'DIRECT';

  static String findProxy(Uri uri) {
    final environmentProxy = HttpClient.findProxyFromEnvironment(uri);
    if (environmentProxy != 'DIRECT') return environmentProxy;

    final server = _proxyForScheme(uri.scheme);
    if (server == null || _shouldBypass(uri.host)) return 'DIRECT';
    return 'PROXY $server; DIRECT';
  }

  static String? _proxyForScheme(String scheme) {
    final raw = _proxyServer;
    if (raw == null || raw.isEmpty) return null;

    if (!raw.contains('=')) return _normalizeServer(raw);
    final byScheme = <String, String>{};
    for (final part in raw.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      byScheme[part.substring(0, eq).trim().toLowerCase()] = part
          .substring(eq + 1)
          .trim();
    }
    final selected =
        byScheme[scheme.toLowerCase()] ?? byScheme['https'] ?? byScheme['http'];
    return selected == null ? null : _normalizeServer(selected);
  }

  static String? _normalizeServer(String value) {
    var result = value.trim();
    if (result.isEmpty) return null;
    result = result.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), '');
    final slash = result.indexOf('/');
    if (slash >= 0) result = result.substring(0, slash);
    return result.isEmpty ? null : result;
  }

  static bool _shouldBypass(String host) {
    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower == '::1' || lower.startsWith('127.')) {
      return true;
    }

    for (final rawPattern in _bypassPatterns) {
      final pattern = rawPattern.toLowerCase();
      if (pattern == '<local>') {
        if (!lower.contains('.')) return true;
        continue;
      }
      final hostPattern = pattern.split(':').first;
      final regexPattern = RegExp.escape(hostPattern).replaceAll(r'\*', '.*');
      if (RegExp('^$regexPattern\$').hasMatch(lower)) return true;
    }
    return false;
  }
}
