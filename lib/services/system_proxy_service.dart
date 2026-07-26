import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

/// Makes Dart HTTP clients honor the active Windows/WinInet proxy.
///
/// Browsers automatically use this setting, while `dart:io` defaults to a
/// direct connection unless an environment proxy is present. Source rules and
/// torrent metadata downloads share this resolver so browser verification and
/// in-app execution use the same network route.
///
/// Proxy server map and bypass matchers are parsed once at [initialize], so
/// per-request work is O(bypass rules) with precompiled patterns — not
/// re-splitting / recompiling RegExp on every request.
class SystemProxyService {
  SystemProxyService._();

  static const String _internetSettings =
      r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static final RegExp _schemePrefix = RegExp(r'^[a-z][a-z0-9+.-]*://');

  /// Single-server form (`host:port`) or per-scheme map (`http=...;https=...`).
  static String? _defaultProxy;
  static Map<String, String> _proxyByScheme = const {};
  static List<_BypassRule> _bypassRules = const [];
  static bool _bypassLocal = false;

  static void initialize() {
    _defaultProxy = null;
    _proxyByScheme = const {};
    _bypassRules = const [];
    _bypassLocal = false;
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
      _parseProxyServer(server);
      _parseBypass(key.getStringValue('ProxyOverride') ?? '');
    } catch (_) {
      _defaultProxy = null;
      _proxyByScheme = const {};
      _bypassRules = const [];
      _bypassLocal = false;
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

  static void _parseProxyServer(String raw) {
    if (!raw.contains('=')) {
      _defaultProxy = _normalizeServer(raw);
      return;
    }
    final byScheme = <String, String>{};
    for (final part in raw.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final host = _normalizeServer(part.substring(eq + 1));
      if (host == null) continue;
      byScheme[part.substring(0, eq).trim().toLowerCase()] = host;
    }
    _proxyByScheme = byScheme;
  }

  static void _parseBypass(String raw) {
    if (raw.isEmpty) return;
    final rules = <_BypassRule>[];
    var local = false;
    for (final part in raw.split(';')) {
      final pattern = part.trim().toLowerCase();
      if (pattern.isEmpty) continue;
      if (pattern == '<local>') {
        local = true;
        continue;
      }
      final hostPattern = pattern.split(':').first;
      final regexPattern = RegExp.escape(hostPattern).replaceAll(r'\*', '.*');
      rules.add(_BypassRule(RegExp('^$regexPattern\$')));
    }
    _bypassLocal = local;
    _bypassRules = rules;
  }

  static String? _proxyForScheme(String scheme) {
    if (_defaultProxy != null) return _defaultProxy;
    if (_proxyByScheme.isEmpty) return null;
    final lower = scheme.toLowerCase();
    return _proxyByScheme[lower] ??
        _proxyByScheme['https'] ??
        _proxyByScheme['http'];
  }

  static String? _normalizeServer(String value) {
    var result = value.trim();
    if (result.isEmpty) return null;
    result = result.replaceFirst(_schemePrefix, '');
    final slash = result.indexOf('/');
    if (slash >= 0) result = result.substring(0, slash);
    return result.isEmpty ? null : result;
  }

  static bool _shouldBypass(String host) {
    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower == '::1' || lower.startsWith('127.')) {
      return true;
    }
    if (_bypassLocal && !lower.contains('.')) return true;
    for (final rule in _bypassRules) {
      if (rule.matches(lower)) return true;
    }
    return false;
  }
}

class _BypassRule {
  const _BypassRule(this._pattern);
  final RegExp _pattern;
  bool matches(String host) => _pattern.hasMatch(host);
}
