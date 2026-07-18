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
}
