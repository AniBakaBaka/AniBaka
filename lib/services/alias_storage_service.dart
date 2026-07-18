import 'dart:convert';

import 'package:baka/instance.dart';

/// 封装视频源搜索别名的持久化存储逻辑。
class AliasStorageService {
  AliasStorageService._();

  static const String _storeKey = 'video_source_search_aliases';
  static Map<String, dynamic>? _cache;

  static Map<String, dynamic> readStore() {
    if (_cache != null) return _cache!;
    final raw = Instances.sp.getString(_storeKey);
    if (raw == null || raw.isEmpty) return _cache = {};
    try {
      final decoded = jsonDecode(raw);
      return _cache = (decoded is Map<String, dynamic> ? decoded : {});
    } catch (_) {
      return _cache = {};
    }
  }

  static List<String> readAliases(String aliasKey) {
    final raw = readStore()[aliasKey];
    if (raw is List) {
      return raw.map((e) => e.toString()).toList();
    }
    return [];
  }

  static Future<void> saveAliases(String aliasKey, List<String> aliases) async {
    final store = readStore();
    if (aliases.isEmpty) {
      store.remove(aliasKey);
    } else {
      store[aliasKey] = aliases;
    }
    await Instances.sp.setString(_storeKey, jsonEncode(store));
  }
}
