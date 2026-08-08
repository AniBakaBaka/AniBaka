import 'dart:convert';

import 'package:baka/instance.dart';
import 'package:baka/theme.dart';

/// 应用偏好设置（主题 / 幻灯 / 源搜索别名）的统一持久化入口。
///
/// 三个类都是 SharedPreferences 的薄封装，集中在一个文件里便于维护；
/// 实际存储键与历史版本保持一致，旧数据无需迁移。
class ThemeService {
  /// 下标即主题模式值。`AppState.setThemeMode` 只接受 0..2。
  static const themeModeLabels = <String>['跟随系统', '浅色模式', '深色模式'];

  static String themeModeLabel(int mode) =>
      themeModeLabels[mode.clamp(0, themeModeLabels.length - 1)];

  static const _themeModeKey = 'theme_mode';
  static const _dynamicColorKey = 'dynamic_color';
  static const _reduceVisualEffectsKey = 'reduce_visual_effects';

  static int getThemeMode() => Instances.sp.getInt(_themeModeKey) ?? 1;

  static Future<void> setThemeMode(int mode) =>
      Instances.sp.setInt(_themeModeKey, mode);

  static bool getDynamicColor() =>
      Instances.sp.getBool(_dynamicColorKey) ?? false;

  static Future<void> setDynamicColor(bool value) =>
      Instances.sp.setBool(_dynamicColorKey, value);

  static bool getReduceVisualEffects() =>
      Instances.sp.getBool(_reduceVisualEffectsKey) ?? false;

  static Future<void> setReduceVisualEffects(bool value) =>
      Instances.sp.setBool(_reduceVisualEffectsKey, value);

  static String getFontFamily() => AppFonts.getSavedFont();

  static Future<void> setFontFamily(String fontFamily) =>
      Instances.sp.setString(AppFonts.spKey, fontFamily);

  static double getFontScale() => AppFonts.getSavedFontScale();

  static Future<void> setFontScale(double scale) =>
      Instances.sp.setDouble(AppFonts.fontScaleKey, scale);

  static int getFontWeightIndex() => AppFonts.getSavedFontWeightIndex();

  static Future<void> setFontWeightIndex(int index) =>
      Instances.sp.setInt(AppFonts.fontWeightKey, index);

  static const _sidebarCollapsedKey = 'sidebarCollapsed';

  static bool getSidebarCollapsed() =>
      Instances.sp.getBool(_sidebarCollapsedKey) ?? false;

  static Future<void> setSidebarCollapsed(bool value) =>
      Instances.sp.setBool(_sidebarCollapsedKey, value);
}

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
