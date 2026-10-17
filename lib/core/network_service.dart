import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:ech_http/ech_http.dart';
import 'package:ech_http/dio.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'network_settings.dart';
import 'system_proxy.dart';

/// Application HTTP policy. Existing clients snapshot settings at startup.
class NetworkService {
  NetworkService._();
  static NetworkSettings settings = const NetworkSettings();
  static DohResolver? resolver;

  static void initialize(SharedPreferences preferences) {
    close();
    settings = NetworkSettings.load(preferences);
    if (!settings.dohEnabled) return;
    // Explicitly remove the global DNS hook to avoid recursive DoH queries.
    final bootstrap = SystemProxyService.createHttpClient()
      ..connectionFactory = null
      ..badCertificateCallback = null
      ..connectionTimeout = const Duration(seconds: 8);
    resolver = DohResolver(
      client: IOClient(bootstrap),
      endpoint: settings.endpoint,
    );
    SystemProxyService.connectionFactory = _connect;
  }

  static void close() {
    SystemProxyService.connectionFactory = null;
    resolver?.close();
    resolver = null;
    settings = const NetworkSettings();
  }

  static Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) =>
      resolver?.connect(uri, proxyHost, proxyPort) ??
      Socket.startConnect(proxyHost ?? uri.host, proxyPort ?? uri.port);

  static http.Client createClient({
    bool useSystemProxy = true,
    Duration connectTimeout = const Duration(seconds: 15),
  }) => PrivacyHttpClient(
    client: IOClient(
      (useSystemProxy
            ? SystemProxyService.createHttpClient()
            : SystemProxyService.createDirectHttpClient())
        ..connectionTimeout = connectTimeout,
    ),
    resolver: settings.echEnabled ? resolver : null,
    connectTimeout: connectTimeout,
    proxyFor: useSystemProxy
        ? SystemProxyService.findProxy
        : SystemProxyService.directProxy,
  );

  static HttpClientAdapter createDioAdapter({bool useSystemProxy = true}) =>
      settings.echEnabled
      ? PrivacyDioAdapter.withFactory(
          (timeout) => createClient(
            useSystemProxy: useSystemProxy,
            connectTimeout: timeout,
          ),
        )
      : IOHttpClientAdapter(
          createHttpClient: useSystemProxy
              ? SystemProxyService.createHttpClient
              : SystemProxyService.createDirectHttpClient,
        );

  static Dio createDio([BaseOptions? options]) =>
      Dio(options)..httpClientAdapter = createDioAdapter();
}
