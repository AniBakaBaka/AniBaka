import 'dart:convert';

import 'package:baka/instance.dart';

/// 首页幻灯的「隐藏 14 天」偏好。
class SwiperSettingsService {
  static const _key = 'swiper_hidden_until';

  static bool get isHidden {
    final hiddenUntilStr = Instances.sp.getString(_key);
    if (hiddenUntilStr == null) return false;
    final hideUntil = DateTime.tryParse(hiddenUntilStr);
    if (hideUntil != null && hideUntil.isAfter(DateTime.now())) {
      return true;
    }
    Instances.sp.remove(_key);
    return false;
  }

  static int get remainingDays {
    final hiddenStr = Instances.sp.getString(_key);
    return hiddenStr != null
        ? (DateTime.tryParse(hiddenStr)?.difference(DateTime.now()).inDays ?? 0)
        : 0;
  }

  static void hide() {
    Instances.sp.setString(
      _key,
      DateTime.now().add(const Duration(days: 14)).toIso8601String(),
    );
  }

  static void show() {
    Instances.sp.remove(_key);
  }
}

/// 视频源搜索别名的持久化存储（JSON 字符串，带进程内缓存）。
class AliasStorageService {
  AliasStorageService._();

  static const _storeKey = 'video_source_search_aliases';
  static Map<String, List<String>>? _cache;

  static Map<String, List<String>> _readStore() {
    if (_cache != null) return _cache!;
    final raw = Instances.sp.getString(_storeKey);
    if (raw == null || raw.isEmpty) return _cache = {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return _cache = {
      for (final entry in decoded.entries)
        entry.key: (entry.value as List<dynamic>).cast<String>(),
    };
  }

  static List<String> readAliases(String aliasKey, {String? fallbackKey}) =>
      _readStore()[aliasKey] ??
      (fallbackKey == null ? null : _readStore()[fallbackKey]) ??
      const [];

  static Future<void> saveAliases(String aliasKey, List<String> aliases) async {
    final store = _readStore();
    if (aliases.isEmpty) {
      store.remove(aliasKey);
    } else {
      store[aliasKey] = aliases;
    }
    await Instances.sp.setString(_storeKey, jsonEncode(store));
  }
}
