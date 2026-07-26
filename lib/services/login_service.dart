import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import 'package:baka/api/post.dart';
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/network_service.dart';

/// 登录 / 注册业务服务
class LoginService {
  AppState get _appState => Get.find<AppState>();

  /// 执行登录流程
  Future<({bool success, String message})> performLogin({
    required String name,
    required String pwd,
  }) async {
    try {
      final response = await login({
        'name': name.trim(),
        'pwd': pwd,
        'platform': 'app',
      });

      final res = jsonDecode(response.data);
      if (res['code'] != 200) {
        return (
          success: false,
          message: res['msg']?.toString() ?? '登录失败，请检查账号密码',
        );
      }

      await NetUtils.saveTokenResponse(Map<String, dynamic>.from(res));
      await Instances.sp.setString('userinfo', jsonEncode(res['user']));
      _appState.triggerLoginRefresh();

      return (success: true, message: '登录成功');
    } catch (e) {
      debugPrint('登录错误: $e');
      return (success: false, message: '登录失败，请检查网络');
    }
  }

  /// 执行注册流程
  Future<({bool success, String message})> performRegister({
    required String name,
    required String pwd,
    required String qq,
  }) async {
    try {
      final response = await register({
        'name': name.trim(),
        'pwd': pwd,
        'qq': qq.trim(),
      });

      final res = jsonDecode(response.data);
      final bool ok = res['code'] == 200;
      final String msg = res['msg']?.toString() ?? (ok ? '注册成功' : '注册失败');

      return (success: ok, message: msg);
    } catch (e) {
      debugPrint('注册错误: $e');
      return (success: false, message: '注册失败，请检查网络');
    }
  }
}
