import 'package:baka/instance.dart';

/// API 层集中配置
///
/// 所有 API 文件通过此类获取 host 等配置，
/// 避免各 API 文件直接读取 [Instances.sp] 全局状态。
class ApiConfig {
  ApiConfig._();

  static const String defaultHost = 'www.anibaka.com';

  /// 获取当前服务器地址（含协议），每次调用实时读取。
  static String get host {
    final server = Instances.sp.getString('host') ?? defaultHost;
    return 'https://$server';
  }

  /// Bangumi 官方 API。中国大陆网络常常无法直连，允许换成自建反代。
  static const String defaultBgmApiBase = 'https://api.bgm.tv';
  static const String bgmApiBaseKey = 'bangumi_api_base';

  /// 当前 Bangumi API 地址（含协议，无尾斜杠），每次调用实时读取。
  static String get bgmApiBase =>
      normalizeBgmApiBase(Instances.sp.getString(bgmApiBaseKey)) ??
      defaultBgmApiBase;

  /// 校验并规范化用户填写的地址；空值表示使用默认地址，非法时返回 null。
  static String? normalizeBgmApiBase(String? raw) {
    final value = raw?.trim().replaceAll(RegExp(r'/+$'), '') ?? '';
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return null;
    if (!uri.isScheme('http') && !uri.isScheme('https')) return null;
    return value;
  }

  static Future<void> setBgmApiBase(String? raw) {
    final normalized = normalizeBgmApiBase(raw);
    return normalized == null
        ? Instances.sp.remove(bgmApiBaseKey)
        : Instances.sp.setString(bgmApiBaseKey, normalized);
  }
}
