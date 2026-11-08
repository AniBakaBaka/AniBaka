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

  /// Installed by NetworkService after persisted privacy settings are loaded.
  static Future<ConnectionTask<Socket>> Function(Uri, String?, int?)?
  connectionFactory;

  static const String _internetSettings =
      r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static final RegExp _schemePrefix = RegExp(r'^[a-z][a-z0-9+.-]*://');

  /// Single-server form (`host:port`) or per-scheme map (`http=...;https=...`).
  static String? _defaultProxy;
  static Map<String, String> _proxyByScheme = const {};
  static Set<String> _exactBypass = const {};
  static List<String> _suffixBypass = const [];
  static List<String> _prefixBypass = const [];
  static List<RegExp> _fallbackRegexBypass = const [];
  static bool _bypassLocal = false;

  /// 代理设置只在启动时读一次，之后不再重复判断。
  static bool _envProxyPresent = false;

  /// 电脑上的本机代理工具不再接管软件联网，远程代理照常使用。
  static const bool bypassLoopbackProxy = true;
  static bool _envProxyLoopback = false;
  static bool _registryProxyLoopback = false;

  static const _envProxyKeys = <String>[
    'http_proxy',
    'HTTP_PROXY',
    'https_proxy',
    'HTTPS_PROXY',
    'all_proxy',
    'ALL_PROXY',
  ];

  static void initialize() {
    _defaultProxy = null;
    _proxyByScheme = const {};
    _exactBypass = const {};
    _suffixBypass = const [];
    _prefixBypass = const [];
    _fallbackRegexBypass = const [];
    _bypassLocal = false;
    _envProxyLoopback = false;
    _registryProxyLoopback = false;
    _envProxyPresent = _envProxyKeys.any(Platform.environment.containsKey);
    _envProxyLoopback = _envProxyKeys.any(
      (key) => _isLoopbackServer(Platform.environment[key]),
    );
    if (Platform.isWindows) {
      RegistryKey? key;
      try {
        key = Registry.openPath(
          RegistryHive.currentUser,
          path: _internetSettings,
        );
        if (key.getIntValue('ProxyEnable') == 1) {
          final server = key.getStringValue('ProxyServer')?.trim();
          if (server != null && server.isNotEmpty) {
            _parseProxyServer(server);
            _parseBypass(key.getStringValue('ProxyOverride') ?? '');
            _registryProxyLoopback =
                _isLoopbackServer(_defaultProxy) ||
                _proxyByScheme.values.any((v) => _isLoopbackServer(v));
          }
        }
      } catch (_) {
        _defaultProxy = null;
        _proxyByScheme = const {};
        _exactBypass = const {};
        _suffixBypass = const [];
        _prefixBypass = const [];
        _fallbackRegexBypass = const [];
        _bypassLocal = false;
        _envProxyLoopback = false;
        _registryProxyLoopback = false;
      } finally {
        key?.close();
      }
    }

    try {
      HttpOverrides.global = SystemProxyHttpOverrides();
    } catch (_) {}
  }

  static HttpClient createHttpClient() {
    final client = HttpClient();
    client.findProxy = findProxy;
    if (connectionFactory != null) client.connectionFactory = connectionFactory;
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }

  static HttpClient createDirectHttpClient() {
    final client = HttpClient();
    client.findProxy = directProxy;
    if (connectionFactory != null) client.connectionFactory = connectionFactory;
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }

  static String directProxy(Uri _) => 'DIRECT';

  static String findProxy(Uri uri) {
    // 本机代理一律直连，远程代理照常跟随。
    final bool skipEnv = bypassLoopbackProxy && _envProxyLoopback;
    final bool skipReg = bypassLoopbackProxy && _registryProxyLoopback;
    if (_envProxyPresent && !skipEnv) {
      final environmentProxy = HttpClient.findProxyFromEnvironment(uri);
      if (environmentProxy != 'DIRECT') return environmentProxy;
    }
    if (skipReg) return 'DIRECT';

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
      if (host != null) {
        byScheme[part.substring(0, eq).trim().toLowerCase()] = host;
      }
    }
    _proxyByScheme = byScheme;
  }

  static void _parseBypass(String raw) {
    if (raw.isEmpty) return;
    final exact = <String>{};
    final suffix = <String>[];
    final prefix = <String>[];
    final regex = <RegExp>[];
    var local = false;

    for (final part in raw.split(';')) {
      final pattern = part.trim().toLowerCase();
      if (pattern.isEmpty) continue;
      if (pattern == '<local>') {
        local = true;
        continue;
      }
      final hostPattern = pattern.split(':').first;
      if (hostPattern.startsWith('*.') && hostPattern.indexOf('*', 2) == -1) {
        // e.g. *.example.com -> matches .example.com or exact example.com
        final base = hostPattern.substring(1); // .example.com
        suffix.add(base);
        exact.add(hostPattern.substring(2)); // example.com
      } else if (hostPattern.endsWith('*') &&
          hostPattern.indexOf('*') == hostPattern.length - 1) {
        // e.g. 192.168.* -> prefix 192.168.
        prefix.add(hostPattern.substring(0, hostPattern.length - 1));
      } else if (!hostPattern.contains('*')) {
        exact.add(hostPattern);
      } else {
        final regexPattern = RegExp.escape(hostPattern).replaceAll(r'\*', '.*');
        regex.add(RegExp('^$regexPattern\$'));
      }
    }
    _bypassLocal = local;
    _exactBypass = exact;
    _suffixBypass = suffix;
    _prefixBypass = prefix;
    _fallbackRegexBypass = regex;
  }

  static String? _proxyForScheme(String scheme) {
    if (_defaultProxy != null) return _defaultProxy;
    if (_proxyByScheme.isEmpty) return null;
    final lower = scheme.toLowerCase();
    return _proxyByScheme[lower] ??
        _proxyByScheme['https'] ??
        _proxyByScheme['http'];
  }

  /// 判断代理是不是在本机。
  static bool _isLoopbackServer(String? value) {
    if (value == null) return false;
    var result = value.trim().toLowerCase();
    if (result.isEmpty) return false;
    final scheme = result.indexOf('://');
    if (scheme >= 0) result = result.substring(scheme + 3);
    final at = result.lastIndexOf('@');
    if (at >= 0) result = result.substring(at + 1);
    final slash = result.indexOf('/');
    if (slash >= 0) result = result.substring(0, slash);
    if (result.startsWith('[::1]')) return true;
    final host = result.split(':').first.trim();
    return host == 'localhost' ||
        host == '::1' ||
        host == '127.0.0.1' ||
        host.startsWith('127.');
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
    if (_exactBypass.contains(lower)) return true;
    for (var i = 0; i < _suffixBypass.length; i++) {
      if (lower.endsWith(_suffixBypass[i])) return true;
    }
    for (var i = 0; i < _prefixBypass.length; i++) {
      if (lower.startsWith(_prefixBypass[i])) return true;
    }
    for (var i = 0; i < _fallbackRegexBypass.length; i++) {
      if (_fallbackRegexBypass[i].hasMatch(lower)) return true;
    }
    return false;
  }
}

/// 让所有网络请求都按系统代理走。
class SystemProxyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = SystemProxyService.findProxy;
    if (SystemProxyService.connectionFactory != null) {
      client.connectionFactory = SystemProxyService.connectionFactory;
    }
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }
}
