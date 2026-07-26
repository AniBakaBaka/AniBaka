import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// TV 端扫码登录服务
///
/// 在 TV 端启动一个本地 HTTP 服务器，生成包含服务器地址的二维码。
/// 手机端扫码后，将已登录的 token 和 userinfo 发送到该服务器，
/// TV 端接收后完成登录。
class QrLoginServer {
  HttpServer? _server;
  String? _sessionId;
  final _completer = Completer<Map<String, dynamic>>();

  /// 服务器监听的端口
  int _port = 0;
  int get port => _port;

  /// 本机局域网 IP
  String? _localIp;
  String? get localIp => _localIp;

  /// 二维码内容（手机扫码后访问的 URL）
  String get qrContent {
    final ip = _localIp ?? '127.0.0.1';
    return 'http://$ip:$_port/auth?session=$_sessionId';
  }

  /// 登录结果 Future，手机端发送 token 后完成
  Future<Map<String, dynamic>> get loginResult => _completer.future;

  /// 启动服务器
  Future<void> start() async {
    _sessionId = _generateSessionId();
    _localIp = await _getLocalIp();

    _server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      0, // 自动分配端口
    );
    _port = _server!.port;

    _server!.listen(_handleRequest);
  }

  void _handleRequest(HttpRequest request) {
    final uri = request.uri;

    if (uri.path == '/auth' && request.method == 'POST') {
      _handleAuth(request);
    } else if (uri.path == '/ping' && request.method == 'GET') {
      request.response
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode({'status': 'ok'}))
        ..close();
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    }
  }

  Future<void> _handleAuth(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final session = request.uri.queryParameters['session'];
      if (session != _sessionId) {
        request.response
          ..statusCode = HttpStatus.forbidden
          ..write(jsonEncode({'msg': 'session mismatch'}))
          ..close();
        return;
      }

      final token = data['token'] as String?;
      final refreshToken = data['refresh_token'] as String?;
      final tokenExpiresAt = data['token_expires_at'] as String?;
      final user = data['user'];

      if (token == null || user == null) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write(jsonEncode({'msg': 'missing token or user'}))
          ..close();
        return;
      }

      request.response
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode({'msg': 'ok'}))
        ..close();

      if (!_completer.isCompleted) {
        _completer.complete({
          'token': token,
          'refresh_token': ?refreshToken,
          'token_expires_at': ?tokenExpiresAt,
          'user': user,
        });
      }
    } catch (e) {
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write(jsonEncode({'msg': 'server error: $e'}))
        ..close();
    }
  }

  /// 停止服务器
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// 获取本机局域网 IPv4 地址
  Future<String?> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  String _generateSessionId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final random = DateTime.now().microsecondsSinceEpoch % 100000;
    return '$now$random';
  }
}
