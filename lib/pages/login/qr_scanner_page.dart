import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:baka/instance.dart';
import 'package:baka/services/watch_party_link_service.dart';
import 'package:baka/utils/toast_utils.dart';

/// AniBaka 通用扫码页。
///
/// TV 登录二维码会把当前登录信息发送到 TV；一起看邀请二维码会关闭
/// 扫码页并直接加入房间。
class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _isSending = false;
  bool _hasScanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_hasScanned || _isSending) return;

    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final rawValue = barcodes.first.rawValue;
    if (rawValue == null || rawValue.isEmpty) {
      // rawValue 为空时尝试 displayValue
      final displayValue = barcodes.first.displayValue;
      if (displayValue == null || displayValue.isEmpty) return;
      await _processScannedValue(displayValue);
      return;
    }

    await _processScannedValue(rawValue);
  }

  Future<void> _processScannedValue(String value) async {
    final inviteCode = WatchPartyLinkService.inviteCodeFromValue(value);
    if (inviteCode != null) {
      _hasScanned = true;
      if (mounted) setState(() => _isSending = true);
      await _controller.stop();
      await HapticFeedback.mediumImpact();
      if (mounted) Navigator.of(context).pop();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await WatchPartyLinkService.joinInvite(inviteCode);
      return;
    }

    if (!value.contains('/auth?session=')) {
      showSnackBar('不是有效的 TV 登录或一起看二维码');
      return;
    }

    _hasScanned = true;
    _sendTokenToTv(value);
  }

  Future<void> _sendTokenToTv(String url) async {
    setState(() => _isSending = true);

    final token = Instances.sp.getString('usertoken');
    final refreshToken = Instances.sp.getString('refresh_token');
    final storedExpiry = Instances.sp.getString('token_expires_at');
    final tokenExpiresAt = storedExpiry == null
        ? null
        : DateTime.tryParse(storedExpiry)?.toUtc().toIso8601String();
    final userInfoStr = Instances.sp.getString('userinfo');

    if (token == null || token.isEmpty || userInfoStr == null) {
      if (mounted) {
        showSnackBar('请先在手机端登录');
        Navigator.of(context).pop();
      }
      return;
    }

    try {
      final user = jsonDecode(userInfoStr);
      final uri = Uri.parse(url);
      final request = await HttpClient()
          .postUrl(uri)
          .timeout(const Duration(seconds: 10));
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'token': token,
          if (refreshToken?.isNotEmpty == true) 'refresh_token': refreshToken,
          'token_expires_at': ?tokenExpiresAt,
          'user': user,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        if (mounted) {
          showSnackBar('TV 端登录成功');
          Navigator.of(context).pop();
        }
      } else {
        if (mounted) {
          showSnackBar('登录失败: $body');
          setState(() {
            _hasScanned = false;
            _isSending = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        showSnackBar('连接 TV 失败，请确保在同一局域网');
        setState(() {
          _hasScanned = false;
          _isSending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // mobile_scanner 没有 Windows/Linux 实现，直接渲染会抛出
    // MissingPluginException。
    final supported = Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
    final scanner = !supported
        ? const Center(child: Text('当前平台不支持扫码，请在手机端使用此功能'))
        : MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            onDetectError: (error, stackTrace) {
              if (mounted && !_hasScanned) {
                showSnackBar('扫码异常: $error');
              }
            },
          );
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫一扫'),
        iconTheme: IconThemeData(color: Theme.of(context).colorScheme.primary),
      ),
      body: Stack(
        children: [
          scanner,

          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.5),
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),

          Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _isSending ? '正在处理...' : '扫描 TV 登录或 AniBaka 一起看二维码',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),

          if (_isSending)
            Container(
              color: Colors.black54,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
