import 'package:baka/core/network_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// TV 端扫码登录服务
///
/// 在 TV 端启动一个本地 HTTP 服务器，生成包含服务器地址的二维码。
/// 手机端扫码后，将已登录的 token 和 userinfo 发送到该服务器，
/// TV 端接收后完成登录。
class QrLoginServer {
  QrLoginServer({Future<InternetAddress?> Function()? findAddress})
    : _findAddress = findAddress ?? NetworkService.findLanIpv4;

  final Future<InternetAddress?> Function() _findAddress;
  HttpServer? _server;
  String? _sessionId;
  var _completer = Completer<Map<String, dynamic>?>();
  Future<void>? _starting;
  int _generation = 0;

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
  Future<Map<String, dynamic>?> get loginResult => _completer.future;

  /// 启动服务器
  Future<void> start() {
    if (_server != null) return Future.value();
    if (_starting != null) return _starting!;
    if (_completer.isCompleted) _completer = Completer<Map<String, dynamic>?>();
    final generation = ++_generation;
    late final Future<void> task;
    task = _start(generation).whenComplete(() {
      if (identical(_starting, task)) _starting = null;
    });
    return _starting = task;
  }

  Future<void> _start(int generation) async {
    final address = await _findAddress();
    if (generation != _generation) return;
    _localIp = address?.address;
    if (address == null) return;
    _sessionId = _generateSessionId();

    final server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      0, // 自动分配端口
    );
    if (generation != _generation) {
      await server.close(force: true);
      return;
    }
    _server = server;
    _port = server.port;
    server.listen(_handleRequest);
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
    final generation = _generation;
    try {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final session = request.uri.queryParameters['session'];
      if (generation != _generation || session != _sessionId) {
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
    _generation++;
    final starting = _starting;
    final server = _server;
    _starting = null;
    _server = null;
    _sessionId = null;
    _localIp = null;
    _port = 0;
    if (!_completer.isCompleted) _completer.complete(null);
    await server?.close(force: true);
    try {
      await starting;
    } catch (_) {
      // The start caller owns startup errors; cancellation must still finish.
    }
  }

  String _generateSessionId() {
    final random = Random.secure();
    return base64UrlEncode(
      List<int>.generate(18, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }
}
