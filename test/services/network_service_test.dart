import 'dart:convert';
import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/services/network_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final testHttpOverrides = HttpOverrides.current;

  setUpAll(() {
    HttpOverrides.global = null;
    NetUtils.resetHttpClientForTesting();
  });
  tearDownAll(() {
    HttpOverrides.global = testHttpOverrides;
    NetUtils.resetHttpClientForTesting();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
  });

  test('POST timeout is bounded and aborts the in-flight request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        request.response
          ..statusCode = HttpStatus.ok
          ..write('{"code":0}');
        await request.response.close();
      } catch (_) {
        // The client is expected to have aborted this response.
      }
    });

    final elapsed = Stopwatch()..start();
    final result = await NetUtils.post(
      'http://${server.address.address}:${server.port}/slow',
      const {'value': 1},
      timeout: const Duration(milliseconds: 50),
      notifyOnError: false,
    );

    expect(result, isEmpty);
    expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 500)));
  });

  test('abortable POST keeps JSON request and response behavior', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'code': 0, 'data': body}));
      await request.response.close();
    });

    final result = await NetUtils.postJson<Map<String, dynamic>>(
      'http://${server.address.address}:${server.port}/echo',
      const {'value': 7},
      timeout: const Duration(seconds: 1),
      notifyOnError: false,
    );

    expect(result?['data'], {'value': 7});
  });
}
