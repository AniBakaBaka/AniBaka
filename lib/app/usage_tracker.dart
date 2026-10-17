import 'dart:io';
import 'dart:math';
import 'package:baka/core/network_service.dart';
import 'package:baka/instance.dart';

/// 日活统计上报（fire-and-forget，失败静默）。
class DauTracker {
  static const String _baseUrl = 'https://dau.anibaka.com';
  static const String _deviceIdKey = 'device_unique_id';
  static const Duration _timeout = Duration(seconds: 10);

  static final RegExp _idRegex = RegExp(r'^install_[a-z]+_[0-9a-f]{32}$');
  static Future<String>? _initFuture;

  static Future<void> track() async {
    try {
      final userId = await (_initFuture ??= _resolveDeviceId());

      final uri = Uri.parse(
        _baseUrl,
      ).replace(path: '/track', queryParameters: {'id': userId});

      final client = NetworkService.createClient();
      try {
        await client.get(uri).timeout(_timeout);
      } finally {
        client.close();
      }
    } catch (_) {
      // 静默处理，不影响用户体验
    }
  }

  static Future<String> _resolveDeviceId() async {
    final stored = Instances.sp.getString(_deviceIdKey);
    if (stored != null && _idRegex.hasMatch(stored)) return stored;
    final random = Random.secure();
    final buffer = StringBuffer('install_${Platform.operatingSystem}_');
    for (var i = 0; i < 16; i++) {
      final byte = random.nextInt(256);
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    final deviceId = buffer.toString();
    await Instances.sp.setString(_deviceIdKey, deviceId);
    return deviceId;
  }
}
