import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baka/api/api_config.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/models/app_user.dart';
import 'package:baka/models/token_response.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:http/http.dart' as http;

class LoginService {
  LoginService([AccountSession? session, ApiTransport? client])
    : session = session ?? Get.find<AccountSession>(),
      client = client ?? Get.find<ApiTransport>();

  static final qqPattern = AppUser.qqPattern;
  static final emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  static final codePattern = RegExp(r'^\d{6}$');

  final AccountSession session;
  final ApiTransport client;

  static String normalizeRecoveryAddress(String value) {
    final address = value.trim().toLowerCase();
    return qqPattern.hasMatch(address) ? '$address@qq.com' : address;
  }

  static bool isValidEmail(String value) => emailPattern.hasMatch(value.trim());

  static bool isValidRecoveryAddress(String value) =>
      emailPattern.hasMatch(normalizeRecoveryAddress(value));

  static bool isValidCode(String value) => codePattern.hasMatch(value.trim());

  static String? validatePassword(
    String? value, {
    String label = '密码',
    bool requireLength = true,
  }) {
    if (value == null || value.isEmpty) return '请填写$label';
    if (requireLength && value.runes.length < 8) return '密码至少需要 8 位';
    return null;
  }

  Future<({bool success, String message})> performLogin({
    required String name,
    required String pwd,
  }) => _accountAction(
    '/user/login',
    {'name': name.trim(), 'pwd': pwd, 'platform': 'app'},
    '登录',
    onSuccess: (res) => session.login(
      TokenResponse.fromJson(res),
      AppUser.fromJson(res['user'] as Map<String, dynamic>),
    ),
    successMessage: '登录成功',
    defaultErrorMessage: '登录失败，请检查账号密码',
  );

  Future<({bool success, String message})> performRegister({
    required String name,
    required String pwd,
    String qq = '',
  }) => _accountAction('/user/register', {
    'name': name.trim(),
    'pwd': pwd,
    'qq': qq.trim(),
  }, '注册');

  Future<({bool success, String message, AppUser? user})> updateUser(
    AppUser current,
    String field,
    String value, {
    String currentPassword = '',
  }) async {
    try {
      final result = await client
          .postJson<Map<String, dynamic>>('${ApiConfig.host}/user/register', {
            'id': current.id,
            'name': field == 'name' ? value : current.name,
            'qq': field == 'qq' ? value : current.qq,
            'sign': field == 'sign' ? value : current.sign,
            'level': current.level,
            'pwd': field == 'pwd' ? value : '',
            if (currentPassword.isNotEmpty) 'current_password': currentPassword,
          }, notifyOnError: false);
      if (result['code'] != 200) {
        return (
          success: false,
          message: _responseMessage(result) ?? '更新失败',
          user: null,
        );
      }
      final updated = AppUser.fromJson({
        'email': current.email,
        'email_verified': current.emailVerified,
        ...result['data'] as Map<String, dynamic>,
      }, retainedPasswordMarker: current.passwordMarker ?? '');
      return (success: true, message: '更新成功', user: updated);
    } catch (e) {
      return (success: false, message: _failureMessage(e, '更新'), user: null);
    }
  }

  Future<({bool success, String message})> sendEmailCode({
    required String email,
    required String purpose,
    String currentPassword = '',
  }) => _accountAction('/user/email/code', {
    'email': purpose == 'reset_password'
        ? normalizeRecoveryAddress(email)
        : email.trim(),
    'purpose': purpose,
    if (purpose == 'bind_email') 'current_password': currentPassword,
  }, '发送验证码');

  Future<({bool success, String message})> resetPassword({
    required String email,
    required String code,
    required String password,
  }) => _accountAction('/user/password/reset', {
    'email': normalizeRecoveryAddress(email),
    'code': code.trim(),
    'new_password': password,
  }, '重置密码');

  Future<({bool success, String message})> sendPasswordChangeCode() {
    final account = session.user.value;
    if (!account.isLoggedIn || account.recoveryEmail.isEmpty) {
      return Future.value((success: false, message: '请先绑定找回邮箱'));
    }
    return sendEmailCode(
      email: account.recoveryEmail,
      purpose: 'reset_password',
    );
  }

  Future<({bool success, String message})> changePassword({
    required String code,
    required String password,
  }) async {
    final account = session.user.value;
    if (!account.isLoggedIn || account.recoveryEmail.isEmpty) {
      return (success: false, message: '请先绑定找回邮箱');
    }
    if (!isValidCode(code)) {
      return (success: false, message: '请输入 6 位验证码');
    }
    if (password.runes.length < 8) {
      return (success: false, message: '密码至少需要 8 位');
    }
    final result = await resetPassword(
      email: account.recoveryEmail,
      code: code,
      password: password,
    );
    if (result.success) await session.logout();
    return result;
  }

  Future<({bool success, String message})> bindEmail({
    required String email,
    required String code,
    required String currentPassword,
  }) => _accountAction(
    '/user/email/bind',
    {
      'email': email.trim(),
      'code': code.trim(),
      'current_password': currentPassword,
    },
    '绑定邮箱',
    onSuccess: (response) => session.saveUser(
      AppUser.fromJson(
        response['data'] as Map<String, dynamic>,
        retainedPasswordMarker: session.user.value.passwordMarker,
      ),
    ),
    successMessage: '邮箱已验证并绑定',
  );

  Future<({bool success, String message})> _accountAction(
    String path,
    Map<String, dynamic> body,
    String action, {
    FutureOr<void> Function(Map<String, dynamic> result)? onSuccess,
    String? successMessage,
    String? defaultErrorMessage,
  }) async {
    try {
      final result = await client.postJson<Map<String, dynamic>>(
        '${ApiConfig.host}$path',
        body,
        notifyOnError: false,
      );
      final code = result['code'];
      if (code != 200 && code != 0) {
        return (
          success: false,
          message:
              _responseMessage(result) ?? defaultErrorMessage ?? '$action失败',
        );
      }
      await onSuccess?.call(result);
      return (
        success: true,
        message: successMessage ?? _responseMessage(result) ?? '$action成功',
      );
    } catch (error) {
      return (success: false, message: _failureMessage(error, action));
    }
  }

  static String? _responseMessage(Map<String, dynamic> response) {
    for (final key in ['msg', 'message']) {
      final message = response[key];
      if (message is String && message.trim().isNotEmpty) return message.trim();
    }
    return null;
  }

  static String _failureMessage(Object error, String action) {
    if (error is ApiException) {
      final body = error.responseBody;
      if (body != null) {
        try {
          final response = jsonDecode(body);
          if (response is Map<String, dynamic>) {
            final message = _responseMessage(response);
            if (message != null) return message;
          }
        } on FormatException {
          // Non-JSON gateway response.
        }
      }
      final status = error.statusCode;
      if (status == null) return error.message;
      if (status == 429) return '请求过于频繁，请稍后重试';
      if (status >= 500) return '服务器暂时不可用（HTTP $status），请稍后重试';
      return '$action失败（HTTP $status），请稍后重试';
    }
    if (error is TimeoutException) return '$action请求超时，请稍后重试';
    if (error is SocketException || error is http.ClientException) {
      return '无法连接服务器，请检查网络或切换 APP 线路';
    }
    if (error is HandshakeException) return '无法建立安全连接，请检查网络或切换 APP 线路';
    if (error is FormatException || error is TypeError) {
      return '服务器响应异常，请稍后重试';
    }
    return '$action失败，请稍后重试';
  }
}
