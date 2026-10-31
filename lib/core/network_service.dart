import 'dart:convert';
import 'dart:io';

import 'package:baka/core/app_logger.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:ech_http/dio.dart';
import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32_registry/win32_registry.dart';

/// Persisted privacy options; saved atomically, applied on the next start.
class NetworkSettings {
  const NetworkSettings({
    this.dohEnabled = false,
    this.echEnabled = false,
    this.dohEndpoint = defaultEndpoint,
  });

  static const _key = 'network_privacy_v1';
  // The IP endpoint avoids an unencrypted bootstrap DNS lookup.
  static const defaultEndpoint = 'https://1.1.1.1/dns-query';
  final bool dohEnabled;
  final bool echEnabled;
  final String dohEndpoint;

  /// [save] only stores validated values.
  static NetworkSettings load(SharedPreferences preferences) {
    final raw = preferences.getString(_key);
    if (raw == null) return const NetworkSettings();
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return NetworkSettings(
      dohEnabled: data['doh'] == true,
      echEnabled: data['ech'] == true,
      dohEndpoint: data['endpoint'] as String,
    );
  }

  /// The endpoint as [DohResolver] accepts it, or a user-facing error.
  static Uri validateEndpoint(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.queryParameters.containsKey('dns')) {
      throw const FormatException(
        '请输入有效的 DoH 服务地址，例如 https://1.1.1.1/dns-query',
      );
    }
    return uri;
  }

  Future<void> save(SharedPreferences preferences) async {
    final saved = await preferences.setString(
      _key,
      jsonEncode({
        'doh': dohEnabled,
        'ech': echEnabled,
        'endpoint': validateEndpoint(dohEndpoint).toString(),
      }),
    );
    if (!saved) throw StateError('无法保存网络设置');
  }
}

/// Application HTTP policy: the Windows/WinInet or environment proxy plus
/// optional DoH/ECH. Browsers honor the system proxy while `dart:io` connects
/// directly by default, so every client is created here. Clients snapshot the
/// policy when created.
abstract final class NetworkService {
  static NetworkSettings settings = const NetworkSettings();
  static DohResolver? resolver;
  static Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? _connect;

  static bool _envProxy = false;
  static String? _httpRoute;
  static String? _httpsRoute;
  static bool _bypassPlainHosts = false;
  static RegExp? _bypass;

  static void init(SharedPreferences preferences) {
    _loadSystemProxy();
    HttpOverrides.global = _ProxyOverrides();
    settings = NetworkSettings.load(preferences);
    if (settings.dohEnabled || settings.echEnabled) {
      // The bootstrap client must validate certificates and must not resolve
      // through the DoH hook it serves.
      final bootstrap = IOClient(
        HttpClient()
          ..findProxy = findProxy
          ..connectionFactory = null
          ..badCertificateCallback = null
          ..connectionTimeout = const Duration(seconds: 8),
      );
      final endpoint = NetworkSettings.validateEndpoint(settings.dohEndpoint);
      resolver = settings.dohEnabled
          ? DohResolver(client: bootstrap, endpoint: endpoint)
          : _EchDiscoveryResolver(client: bootstrap, endpoint: endpoint);
      if (settings.dohEnabled) _connect = _connectSecure;
    }
    Log.i(
      'Network',
      'proxy=${_httpsRoute ?? (_envProxy ? 'env' : 'none')} '
          'doh=${settings.dohEnabled} ech=${settings.echEnabled}'
          '${resolver == null ? '' : ' endpoint=${settings.dohEndpoint}'}',
    );
  }

  static void close() {
    _connect = null;
    resolver?.close();
    resolver = null;
    settings = const NetworkSettings();
  }

  static void _loadSystemProxy() {
    // findProxyFromEnvironment reads only these; the environment is fixed for
    // the process lifetime.
    _envProxy = const [
      'http_proxy',
      'HTTP_PROXY',
      'https_proxy',
      'HTTPS_PROXY',
    ].any(Platform.environment.containsKey);
    _httpRoute = _httpsRoute = _bypass = null;
    _bypassPlainHosts = false;
    if (!Platform.isWindows) return;
    final RegistryKey key;
    try {
      key = Registry.openPath(
        RegistryHive.currentUser,
        path: r'Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      );
    } on Exception catch (error) {
      Log.w('Network', 'System proxy settings unavailable', error);
      return;
    }
    try {
      if (key.getIntValue('ProxyEnable') != 1) return;
      final server = key.getStringValue('ProxyServer')?.trim() ?? '';
      if (server.isEmpty) return;
      // `host:port`, or per scheme: `http=host:port;https=host:port`.
      final byScheme = <String, String>{};
      if (server.contains('=')) {
        for (final part in server.split(';')) {
          final eq = part.indexOf('=');
          final host = eq > 0 ? _hostPort(part.substring(eq + 1)) : null;
          if (host != null) {
            byScheme[part.substring(0, eq).trim().toLowerCase()] = host;
          }
        }
      }
      final single = byScheme.isEmpty ? _hostPort(server) : null;
      final http = single ?? byScheme['http'] ?? byScheme['https'];
      final https = single ?? byScheme['https'] ?? byScheme['http'];
      if (http != null) _httpRoute = 'PROXY $http; DIRECT';
      if (https != null) _httpsRoute = 'PROXY $https; DIRECT';
      _parseBypass(key.getStringValue('ProxyOverride') ?? '');
    } finally {
      key.close();
    }
  }

  static String? _hostPort(String value) {
    var server = value.trim();
    final scheme = server.indexOf('://');
    if (scheme >= 0) server = server.substring(scheme + 3);
    final slash = server.indexOf('/');
    if (slash >= 0) server = server.substring(0, slash);
    return server.isEmpty ? null : server;
  }

  /// Compiles WinInet bypass entries into one anchored pattern; `*.a.com`
  /// also matches `a.com`, and `<local>` means hosts without a dot.
  static void _parseBypass(String raw) {
    final patterns = <String>[];
    for (final part in raw.split(';')) {
      final entry = part.trim().toLowerCase();
      if (entry.isEmpty) continue;
      if (entry == '<local>') {
        _bypassPlainHosts = true;
        continue;
      }
      final host = entry.split(':').first;
      final wildcardSubdomain = host.startsWith('*.');
      final pattern = RegExp.escape(
        wildcardSubdomain ? host.substring(2) : host,
      ).replaceAll(r'\*', '.*');
      patterns.add(wildcardSubdomain ? '(?:.*\\.)?$pattern' : pattern);
    }
    if (patterns.isNotEmpty) _bypass = RegExp('^(?:${patterns.join('|')})\$');
  }

  /// `dart:io` proxy directive for [uri]. Hosts are lower case in [Uri].
  static String findProxy(Uri uri) {
    if (_envProxy) {
      final proxy = HttpClient.findProxyFromEnvironment(uri);
      if (proxy != 'DIRECT') return proxy;
    }
    final route = uri.scheme == 'http' ? _httpRoute : _httpsRoute;
    if (route == null) return 'DIRECT';
    final host = uri.host;
    final bypassed =
        host == 'localhost' ||
        host == '::1' ||
        host.startsWith('127.') ||
        (_bypassPlainHosts && !host.contains('.')) ||
        (_bypass?.hasMatch(host) ?? false);
    return bypassed ? 'DIRECT' : route;
  }

  static String _direct(Uri _) => 'DIRECT';

  static bool _acceptAnyCertificate(X509Certificate _, String _, int _) => true;

  /// Keeps a connection factory installed by other overrides unless DoH owns it.
  static HttpClient _configure(HttpClient client, bool useSystemProxy) {
    client
      ..findProxy = useSystemProxy ? findProxy : _direct
      ..badCertificateCallback = _acceptAnyCertificate;
    if (_connect case final connect?) client.connectionFactory = connect;
    return client;
  }

  static HttpClient _httpClient(bool useSystemProxy) =>
      _configure(HttpClient(), useSystemProxy);

  /// A custom connection factory's socket is used as-is: direct HTTPS needs
  /// TLS here, while proxy CONNECT tunnels are secured by HttpClient.
  static Future<ConnectionTask<Socket>> _connectSecure(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    final task = await resolver!.connect(uri, proxyHost, proxyPort);
    if (uri.scheme != 'https' || proxyHost != null) return task;
    Socket? raw;
    SecureSocket? secure;
    var cancelled = false;
    Future<Socket> handshake() async {
      raw = await task.socket;
      try {
        if (cancelled) throw const SocketException('Connection cancelled');
        secure = await SecureSocket.secure(raw!, host: uri.host);
        if (cancelled) {
          secure!.destroy();
          throw const SocketException('Connection cancelled');
        }
        return secure!;
      } catch (_) {
        raw!.destroy();
        rethrow;
      }
    }

    return ConnectionTask.fromSocket(handshake(), () {
      cancelled = true;
      task.cancel();
      raw?.destroy();
      secure?.destroy();
    });
  }

  /// ECH needs [PrivacyHttpClient]; otherwise a plain [IOClient] avoids its
  /// per-request forwarding.
  static http.Client createClient({
    bool useSystemProxy = true,
    Duration connectTimeout = const Duration(seconds: 15),
  }) {
    final client = IOClient(
      _httpClient(useSystemProxy)..connectionTimeout = connectTimeout,
    );
    if (!settings.echEnabled) return client;
    return PrivacyHttpClient(
      client: client,
      resolver: resolver,
      connectTimeout: connectTimeout,
      proxyFor: useSystemProxy ? findProxy : _direct,
    );
  }

  static HttpClientAdapter createDioAdapter({bool useSystemProxy = true}) =>
      settings.echEnabled
      ? PrivacyDioAdapter.withFactory(
          (timeout) => createClient(
            useSystemProxy: useSystemProxy,
            connectTimeout: timeout,
          ),
        )
      : IOHttpClientAdapter(
          createHttpClient: () => _httpClient(useSystemProxy),
        );

  static Dio createDio([BaseOptions? options]) =>
      Dio(options)..httpClientAdapter = createDioAdapter();

  /// The first private (RFC 1918) IPv4 address, else the first usable one.
  static Future<InternetAddress?> findLanIpv4() async {
    InternetAddress? first;
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final address in interface.addresses) {
        if (address.isLinkLocal) continue;
        final bytes = address.rawAddress;
        final a = bytes[0], b = bytes[1];
        if (a == 10 ||
            (a == 172 && b >= 16 && b <= 31) ||
            (a == 192 && b == 168)) {
          return address;
        }
        first ??= address;
      }
    }
    return first;
  }
}

/// Keeps clients created without this service on the same proxy route.
class _ProxyOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      NetworkService._configure(super.createHttpClient(context), true);
}

/// ECH still needs HTTPS DNS records, but address routing stays on the system
/// resolver when DoH is off.
class _EchDiscoveryResolver extends DohResolver {
  _EchDiscoveryResolver({required super.client, required super.endpoint});

  @override
  Future<List<InternetAddress>> lookup(String host) =>
      InternetAddress.lookup(host);
}
