import 'dart:io';
import 'dart:math';

import 'package:baka/core/network_service.dart';
import 'package:baka/instance.dart';

Future<void> trackDailyUsage() async {
  const key = 'device_unique_id';
  try {
    var id = Instances.sp.getString(key);
    if (id == null || !RegExp(r'^install_[a-z]+_[0-9a-f]{32}$').hasMatch(id)) {
      final random = Random.secure();
      final buffer = StringBuffer('install_${Platform.operatingSystem}_');
      for (var i = 0; i < 16; i++) {
        buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
      }
      id = buffer.toString();
      await Instances.sp.setString(key, id);
    }
    final client = NetworkService.createClient();
    try {
      await client
          .get(Uri.https('dau.anibaka.com', '/track', {'id': id}))
          .timeout(const Duration(seconds: 10));
    } finally {
      client.close();
    }
  } catch (_) {
    // Usage reporting is best effort.
  }
}
