import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Saved atomically; changes take effect on the next application start.
class NetworkSettings {
  const NetworkSettings({
    this.dohEnabled = false,
    this.echEnabled = false,
    this.dohEndpoint = defaultEndpoint,
  });

  static const storageKey = 'network_privacy_v1';
  // The IP endpoint avoids an unencrypted bootstrap DNS lookup.
  static const defaultEndpoint = 'https://1.1.1.1/dns-query';
  final bool dohEnabled;
  final bool echEnabled;
  final String dohEndpoint;

  Uri get endpoint => validateEndpoint(dohEndpoint);

  static Uri validateEndpoint(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.queryParameters.containsKey('dns')) {
      throw const FormatException('请输入有效的 HTTPS DoH 地址，不能包含账号、片段或 dns 参数');
    }
    return uri;
  }

  static NetworkSettings load(SharedPreferences preferences) {
    try {
      final data = jsonDecode(preferences.getString(storageKey) ?? '{}');
      final endpoint = data['endpoint'] as String? ?? defaultEndpoint;
      validateEndpoint(endpoint);
      return NetworkSettings(
        dohEnabled: data['doh'] == true,
        echEnabled: data['ech'] == true,
        dohEndpoint: endpoint,
      );
    } catch (_) {
      return const NetworkSettings();
    }
  }

  Future<void> save(SharedPreferences preferences) async {
    final uri = endpoint;
    final saved = await preferences.setString(
      storageKey,
      jsonEncode({
        'doh': dohEnabled,
        'ech': echEnabled,
        'endpoint': uri.toString(),
      }),
    );
    if (!saved) throw StateError('无法保存网络设置');
  }
}
