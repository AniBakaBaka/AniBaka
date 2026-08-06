import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:baka/app_state.dart';
import 'package:baka/services/qr_login_server.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/widgets/platform/tv/tv_theme_util.dart';

enum _QrLoginState { loading, waiting, success, error }

class TvQrLoginPage extends StatefulWidget {
  const TvQrLoginPage({super.key});

  @override
  State<TvQrLoginPage> createState() => _TvQrLoginPageState();
}

class _TvQrLoginPageState extends State<TvQrLoginPage> {
  final QrLoginServer _server = QrLoginServer();
  _QrLoginState _state = _QrLoginState.loading;
  String? _qrContent;
  String? _errorMsg;
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  Future<void> _startServer() async {
    try {
      await _server.start();
      final qrContent = _server.qrContent;
      if (_server.localIp == null) {
        setState(() {
          _state = _QrLoginState.error;
          _errorMsg = '无法获取本机 IP 地址，请检查网络连接';
        });
        return;
      }
      setState(() {
        _qrContent = qrContent;
        _state = _QrLoginState.waiting;
      });

      _timeoutTimer = Timer(const Duration(minutes: 5), () {
        if (mounted && _state == _QrLoginState.waiting) {
          setState(() {
            _state = _QrLoginState.error;
            _errorMsg = '二维码已过期，请重新打开页面';
          });
        }
      });

      final result = await _server.loginResult;
      _timeoutTimer?.cancel();

      if (!mounted || _state != _QrLoginState.waiting) return;

      await Get.find<AppState>().saveLoginInfo(
        result['token'] as String,
        Map<String, dynamic>.from(result['user'] as Map),
        refreshToken: result['refresh_token'] as String?,
        tokenExpiresAt: result['token_expires_at'] as String?,
      );

      setState(() => _state = _QrLoginState.success);

      showSnackBar('登录成功');

      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _QrLoginState.error;
          _errorMsg = '启动服务失败: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _server.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.tvBgColor,
      body: Focus(
        canRequestFocus: false,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.escape ||
                  event.logicalKey == LogicalKeyboardKey.goBack)) {
            Navigator.of(context).maybePop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: SafeArea(
          child: Stack(
            children: [
              Positioned(
                top: 32,
                left: 32,
                child: TvFocusable(
                  autofocus: true,
                  onPressed: () => Navigator.of(context).maybePop(),
                  borderRadius: BorderRadius.circular(24),
                  enableScale: false,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: context.tvHighlightColor(0.1),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.arrow_back,
                          color: context.tvTextSecondaryColor,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '返回',
                          style: TextStyle(
                            color: context.tvTextSecondaryColor,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              Center(child: _buildContent(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_state == _QrLoginState.loading) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text(
            '正在准备二维码...',
            style: TextStyle(fontSize: 18, color: context.tvTextSecondaryColor),
          ),
        ],
      );
    }

    if (_state == _QrLoginState.error) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: Colors.red.withValues(alpha: 0.7),
          ),
          const SizedBox(height: 24),
          Text(
            _errorMsg ?? '登录服务不可用',
            style: TextStyle(fontSize: 18, color: context.tvTextSecondaryColor),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          TvFocusable(
            onPressed: () => Navigator.of(context).maybePop(),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '返回',
                style: TextStyle(fontSize: 16, color: context.tvTextColor),
              ),
            ),
          ),
        ],
      );
    }

    if (_state == _QrLoginState.waiting && _qrContent != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '扫码登录',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: context.tvTextColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '使用手机端 App 扫描下方二维码完成登录',
            style: TextStyle(fontSize: 16, color: context.tvTextSecondaryColor),
          ),
          const SizedBox(height: 40),

          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(
              data: _qrContent!,
              version: QrVersions.auto,
              size: 280,
              gapless: true,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Colors.black,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Colors.black,
              ),
            ),
          ),
          const SizedBox(height: 40),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(
                '等待手机扫码...',
                style: TextStyle(
                  fontSize: 14,
                  color: context.tvTextSecondaryColor,
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          Text(
            '请确保手机和 TV 处于同一局域网',
            style: TextStyle(fontSize: 12, color: context.tvTextHintColor),
          ),
        ],
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.check_circle_outline,
          size: 72,
          color: Colors.green.withValues(alpha: 0.8),
        ),
        const SizedBox(height: 24),
        Text(
          '登录成功',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: context.tvTextColor,
          ),
        ),
      ],
    );
  }
}
