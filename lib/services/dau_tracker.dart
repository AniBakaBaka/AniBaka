import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:baka/instance.dart';
import 'package:http/http.dart' as http;

class DauTracker {
  static const String _baseUrl = 'https://dau.anibaka.com';
  static const String _deviceIdKey = 'device_unique_id';
  static const String _installIdPrefix = 'install_';
  static const Duration _timeout = Duration(seconds: 10);

  static final RegExp _idRegex = RegExp(r'^install_[a-z]+_[0-9a-f]{32}$');
  static String? _cachedId;
  static Future<String>? _initFuture;

  static Future<void> track() async {
    try {
      final userId = await _getOrCreateDeviceId();
      if (userId.isEmpty) return;

      final uri = Uri.parse(
        _baseUrl,
      ).replace(path: '/track', queryParameters: {'id': userId});

      final client = http.Client();
      try {
        await client.get(uri).timeout(_timeout);
      } finally {
        client.close();
      }
    } catch (_) {
      // 静默处理，不影响用户体验
    }
  }

  // 用 Future 缓存防止并发竞态
  static Future<String> _getOrCreateDeviceId() {
    _initFuture ??= _resolveDeviceId();
    return _initFuture!;
  }

  static Future<String> _resolveDeviceId() async {
    if (_cachedId != null) return _cachedId!;

    final stored = Instances.sp.getString(_deviceIdKey);
    if (_isValidInstallId(stored)) {
      _cachedId = stored!;
      return _cachedId!;
    }

    final deviceId = _generateInstallId();
    if (deviceId.isNotEmpty) {
      await Instances.sp.setString(_deviceIdKey, deviceId);
      _cachedId = deviceId;
    }
    return deviceId;
  }

  static bool _isValidInstallId(String? value) {
    return value != null && _idRegex.hasMatch(value);
  }

  static String _generateInstallId() {
    final random = Random.secure();
    final buffer = StringBuffer('$_installIdPrefix${_platformTag()}_');
    for (var i = 0; i < 16; i++) {
      final byte = random.nextInt(256);
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static String _platformTag() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    return 'unknown';
  }
}
