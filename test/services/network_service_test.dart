import 'package:baka/core/account_session.dart';
import 'dart:async';
import 'package:baka/api/api_config.dart';
import 'package:baka/api/auth_api.dart';
import 'package:baka/api/anibaka_api.dart';
import 'package:baka/api/bangumi_account_api.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/api/post.dart';
import 'package:baka/core/http_request.dart';
import 'package:baka/app/app_runtime.dart' show MonitoredImageCache;
import 'package:baka/services/account/login_service.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/api/playback.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/play_history.dart';
import 'package:baka/models/app_user.dart';
import 'package:baka/pages/login/login_page.dart';
import 'package:baka/pages/login/account_security_page.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/core/api_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:file/memory.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final testHttpOverrides = HttpOverrides.current;

  setUpAll(() {
    HttpOverrides.global = null;
  });
  tearDownAll(() {
    HttpOverrides.global = testHttpOverrides;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    apiTransport = ApiTransport(
      session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
      client: MockClient(
        (request) async =>
            throw StateError('Unexpected request: ${request.url}'),
      ),
      version: 'test',
      credentialOrigin: () => Uri.parse('https://www.anibaka.com'),
    );
    addTearDown(apiTransport.close);
  });

  void useClient(http.Client client, {void Function(Object)? onError}) {
    apiTransport = ApiTransport(
      session: apiTransport.session,
      client: client,
      version: 'test',
      credentialOrigin: () => Uri.parse(ApiConfig.host),
      onError: onError,
    );
    addTearDown(client.close);
  }

  test('network notices throttle bursts while requests still fail', () async {
    var now = DateTime.utc(2026);
    var notices = 0;
    final policy = NetworkNotices(
      onNetworkError: () => notices++,
      onImageFailures: () => fail('No images were requested'),
      now: () => now,
    );
    addTearDown(policy.dispose);
    for (final error in <Object>[
      const ApiException('denied', statusCode: 403),
      const ApiException('missing', statusCode: 404),
      const FormatException('invalid JSON'),
      StateError('account changed'),
      http.RequestAbortedException(),
    ]) {
      policy.reportNetworkError(error);
    }
    expect(notices, 0);
    final offline = http.ClientException('offline');
    useClient(
      MockClient((_) async => throw offline),
      onError: policy.reportNetworkError,
    );
    await Future.wait(
      List.generate(
        20,
        (_) => expectLater(
          apiTransport.getJson<Object>('$host/offline'),
          throwsA(same(offline)),
        ),
      ),
    );
    expect(notices, 1);
    now = now.add(const Duration(seconds: 59));
    policy.reportNetworkError(TimeoutException('timeout'));
    expect(notices, 1);
    now = now.add(const Duration(seconds: 1));
    policy.reportNetworkError(
      const ApiException('unavailable', statusCode: 503),
    );
    expect(notices, 2);
  });

  testWidgets(
    'image hints require distinct failures and a high failure ratio',
    (tester) async {
      var imageNotices = 0;
      var networkNotices = 0;
      final policy = NetworkNotices(
        onNetworkError: () => networkNotices++,
        onImageFailures: () => imageNotices++,
      );
      addTearDown(policy.dispose);
      for (var i = 0; i < 20; i++) {
        policy.reportImageResult('', succeeded: false);
        policy.reportImageResult('file:///cover$i.jpg', succeeded: false);
        policy.reportImageResult('https://images.test/0.jpg', succeeded: false);
      }
      for (var i = 1; i < 7; i++) {
        policy.reportImageResult(
          'https://images.test/$i.jpg',
          succeeded: false,
        );
      }
      await tester.pump(const Duration(seconds: 2));
      expect(imageNotices, 0, reason: 'Seven unique failures are insufficient');
      policy.reportImageResult('https://images.test/7.jpg', succeeded: false);
      for (var i = 0; i < 4; i++) {
        policy.reportImageStarted('https://images.test/ok$i.jpg');
      }
      await tester.pump(const Duration(seconds: 2));
      expect(
        imageNotices,
        0,
        reason: 'Pending loads are included before judging the failure ratio',
      );
      for (var i = 0; i < 4; i++) {
        policy.reportImageResult(
          'https://images.test/ok$i.jpg',
          succeeded: true,
        );
      }
      for (var i = 8; i < 12; i++) {
        policy.reportImageResult(
          'https://images.test/$i.jpg',
          succeeded: false,
        );
      }
      await tester.pump(const Duration(seconds: 2));
      expect(imageNotices, 1);
      policy.reportNetworkError(http.ClientException('offline'));
      expect(
        networkNotices,
        0,
        reason: 'The image hint covers network failures',
      );
    },
  );

  testWidgets(
    'image hints expire old failures, cool down and stop on disposal',
    (tester) async {
      var now = DateTime.utc(2026);
      var imageNotices = 0;
      final policy = NetworkNotices(
        onNetworkError: () {},
        onImageFailures: () => imageNotices++,
        now: () => now,
      );
      addTearDown(policy.dispose);
      void failImages(int start, int end) {
        for (var i = start; i < end; i++) {
          policy.reportImageResult(
            'https://images.test/$i.jpg',
            succeeded: false,
          );
        }
      }

      failImages(0, 4);
      now = now.add(const Duration(seconds: 61));
      failImages(4, 8);
      await tester.pump(const Duration(seconds: 2));
      expect(
        imageNotices,
        0,
        reason: 'Old isolated failures do not accumulate',
      );
      failImages(8, 12);
      policy.reportImageResult('https://images.test/8.jpg', succeeded: true);
      await tester.pump(const Duration(seconds: 2));
      expect(imageNotices, 0, reason: 'A successful retry cancels the hint');
      failImages(8, 9);
      await tester.pump(const Duration(seconds: 2));
      expect(imageNotices, 1);
      now = now.add(const Duration(minutes: 9, seconds: 59));
      failImages(12, 24);
      await tester.pump(const Duration(seconds: 2));
      expect(imageNotices, 1);
      now = now.add(const Duration(seconds: 1));
      failImages(24, 25);
      await tester.pump(const Duration(seconds: 2));
      expect(imageNotices, 2);
      now = now.add(const Duration(minutes: 10));
      failImages(25, 33);
      policy.dispose();
      await tester.pump(const Duration(seconds: 2));
      expect(imageNotices, 2);
    },
  );

  testWidgets('cached images survive refresh failures without a region hint', (
    tester,
  ) async {
    var imageNotices = 0;
    final policy = NetworkNotices(
      onNetworkError: () => fail('Images use the aggregate hint'),
      onImageFailures: () => imageNotices++,
    );
    addTearDown(policy.dispose);
    final file = MemoryFileSystem().file('/cover.jpg');
    final offline = http.ClientException('offline');
    final delegate = _ImageCache((url) async* {
      if (url.contains('/cached/')) {
        yield FileInfo(file, FileSource.Cache, DateTime.utc(2020), url);
      }
      throw offline;
    });
    final cache = MonitoredImageCache(delegate, policy);
    for (var i = 0; i < 8; i++) {
      await expectLater(
        cache.getImageFile('https://images.test/cached/$i.jpg', maxWidth: 300),
        emitsInOrder([isA<FileInfo>(), emitsError(same(offline)), emitsDone]),
      );
    }
    await tester.pump(const Duration(seconds: 2));
    expect(imageNotices, 0);
    for (var i = 0; i < 20; i++) {
      await expectLater(
        cache.getFileStream('https://images.test/failed/$i.jpg'),
        emitsInOrder([emitsError(same(offline)), emitsDone]),
      );
    }
    await tester.pump(const Duration(seconds: 2));
    expect(imageNotices, 1);
  });

  test(
    'HTTP, envelope, JSON and network failures retain distinct semantics',
    () async {
      var notices = 0;
      var status = 200;
      var body = '{}';
      final offline = http.ClientException('offline');
      useClient(
        MockClient((request) async {
          if (request.url.path == '/offline') throw offline;
          return http.Response(body, status);
        }),
        onError: (_) => notices++,
      );
      for (final code in [404, 500, 502, 503]) {
        status = code;
        body = '<html>upstream failure</html>';
        await expectLater(
          apiTransport.getJson<Map<String, dynamic>>(
            '$host/data',
            notifyOnError: false,
          ),
          throwsA(
            isA<ApiException>().having(
              (e) => e.statusCode,
              'HTTP status',
              code,
            ),
          ),
        );
      }
      status = 200;
      for (final invalid in ['', '<html>', 'null', '[]']) {
        body = invalid;
        await expectLater(
          apiTransport.getJson<Map<String, dynamic>>(
            '$host/data',
            notifyOnError: false,
          ),
          throwsFormatException,
        );
      }
      body = '{"code":403,"message":"denied"}';
      await expectLater(
        apiTransport.getData<Map<String, dynamic>>(
          '$host/data',
          notifyOnError: false,
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'envelope code', 403)
              .having((e) => e.statusCode, 'HTTP status', isNull),
        ),
      );
      body = '{"code":0}';
      await expectLater(
        apiTransport.getData<Map<String, dynamic>>(
          '$host/data',
          notifyOnError: false,
        ),
        throwsFormatException,
      );
      body = '{"code":0,"data":null}';
      expect(
        await apiTransport.getData<Map<String, dynamic>?>('$host/data'),
        isNull,
      );
      await expectLater(
        apiTransport.getJson<Object>('$host/offline', notifyOnError: false),
        throwsA(same(offline)),
      );
      expect(notices, 0);
      await expectLater(
        apiTransport.getJson<Object>('$host/offline'),
        throwsA(same(offline)),
      );
      expect(notices, 1);
    },
  );

  test(
    'missing post is distinct from malformed data and network failure',
    () async {
      var notices = 0;
      var body = '{"code":200,"data":null}';
      useClient(
        MockClient((request) async {
          expect(request.url.path, '/post/42');
          return http.Response(body, 200);
        }),
        onError: (_) => notices++,
      );

      await expectLater(
        getPostDetail(42),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'status', 404)
              .having((error) => error.message, 'message', '条目不存在或已删除'),
        ),
      );
      expect(notices, 0);
      for (final malformed in [
        '{"code":200}',
        '{"code":200,"data":[]}',
        '{"code":200,"data":"invalid"}',
      ]) {
        body = malformed;
        await expectLater(getPostDetail(42), throwsFormatException);
      }
      expect(notices, 3);
      body = '{"code":200,"data":{"id":42,"title":"Available"}}';
      expect((await getPostDetail(42))['id'], 42);
    },
  );

  test('post queries preserve signed URLs and omit null parameters', () async {
    final requests = <Uri>[];
    useClient(
      MockClient((request) async {
        requests.add(request.url);
        final body = switch (request.url.path) {
          '/play' => '{"code":200,"data":{"url":"https://media.test/video"}}',
          '/comment/uv' => '{"code":200,"msg":"liked"}',
          _ => '{"code":200,"data":[]}',
        };
        return http.Response(body, 200);
      }),
    );
    const signed = 'https://media.test/a.m3u8?x=1&sig=a%2Bb=c#part';
    expect(await getPlayUrl(signed), 'https://media.test/video');
    expect(requests.last.queryParameters, {'url': signed});
    await getSearch('中文 & x=y#z');
    expect(requests.last.queryParameters, {'key': '中文 & x=y#z'});
    await getSearch(null);
    expect(requests.last.queryParameters.containsKey('key'), isFalse);
    await getComments(null, 20);
    expect(requests.last.queryParameters, {'page': '1', 'pageSize': '20'});
    await getPost('动画&', '#tag', 1, 20);
    expect(requests.last.queryParameters['sort'], '动画&');
    expect(requests.last.queryParameters.containsKey('uid'), isFalse);
    expect(await updateCommentUv('a&b', null), 'liked');
    expect(requests.last.queryParameters, {'cid': 'a&b'});
    useClient(MockClient((_) async => http.Response('{"code":200}', 200)));
    await expectLater(updateCommentUv(1, 'name'), throwsFormatException);
  });

  test(
    'required AniBaka results cannot become optional collection absence',
    () async {
      var body = '{"code":200,"data":null}';
      useClient(MockClient((_) async => http.Response(body, 200)));
      const collection = AnimeCollection(bgmId: 42, status: 3);
      await expectLater(
        AniBakaApi.saveCollection(collection),
        throwsFormatException,
      );
      await expectLater(AniBakaApi.getCollections(), throwsFormatException);
      await expectLater(AniBakaApi.getCollectionStats(), throwsFormatException);
      await expectLater(AniBakaApi.getPlayHistory(), throwsFormatException);
      expect(await AniBakaApi.getCollectionByBgmId(42), isNull);
      expect(await AniBakaApi.getCollectionByPostId(42), isNull);

      body =
          '{"code":200,"data":{"list":[],"total":0,"page":1,"page_size":20}}';
      expect((await AniBakaApi.getCollections()).list, isEmpty);
      expect(await AniBakaApi.getPlayHistory(), isEmpty);
      body = '{"code":200,"data":{"status":3,"bgm_id":42}}';
      expect((await AniBakaApi.saveCollection(collection)).bgmId, 42);

      body = '{"code":500,"msg":"save failed"}';
      await expectLater(
        AniBakaApi.saveCollection(collection),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test(
    'history upload sends its contract without rebuilding the ignored response',
    () async {
      const history = PlayHistory(
        videoId: 42,
        videoTitle: 'Example',
        videoDuration: 120,
        playProgress: 60,
      );
      useClient(
        MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/v1/play-history');
          expect(jsonDecode(request.body), history.toJson());
          return http.Response(
            jsonEncode({'code': 200, 'data': history.toJson()}),
            200,
          );
        }),
      );
      await AniBakaApi.savePlayHistory(history);
    },
  );

  test('danmu follows the sidecar data envelope', () async {
    var body = '{"success":true,"data":[{"c":"1,1,25,16777215","m":"hello"}]}';
    useClient(
      MockClient((request) async {
        expect(request.url.path, '/danmu/list');
        expect(request.url.queryParameters['gv'], '42');
        expect(request.url.queryParameters['p'], '1');
        return http.Response(body, 200);
      }),
    );
    expect(await getDanmu(42, 1, 'Example'), [
      {'c': '1,1,25,16777215', 'm': 'hello'},
    ]);
    body = '{"success":false,"data":[]}';
    expect(await getDanmu(42, 1, 'Example'), isEmpty);
    body = '[]';
    await expectLater(getDanmu(42, 1, 'Example'), throwsFormatException);
  });

  test(
    'login and refresh share JSON/status handling without recursive auth',
    () async {
      useClient(
        MockClient((request) async {
          expect(request.headers['token'], isNull);
          expect(request.followRedirects, isFalse);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path == '/user/refresh') {
            expect(body, {'refresh_token': 'refresh'});
          } else {
            expect(body['name'], 'name');
          }
          return http.Response(
            jsonEncode({
              'code': 200,
              'token': 'new',
              'refresh_token': 'next',
              'user': {
                'id': 1,
                'name': 'name',
                'qq': '',
                'sign': '',
                'level': 0,
              },
            }),
            200,
          );
        }),
      );
      final result = await LoginService(
        apiTransport.session,
        apiTransport,
      ).performLogin(name: ' name ', pwd: 'password');
      expect(result.success, isTrue);
      expect(apiTransport.session.token, 'new');
      final auth = AuthApi(apiTransport.client, () => ApiConfig.host);
      expect((await auth.refresh('refresh'))?.token, 'new');
      useClient(MockClient((_) async => http.Response('rejected', 401)));
      expect(
        await AuthApi(apiTransport.client, () => ApiConfig.host).refresh('r'),
        isNull,
      );
      useClient(MockClient((_) async => http.Response('broken', 503)));
      await expectLater(
        AuthApi(apiTransport.client, () => ApiConfig.host).refresh('r'),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test(
    'account forms preserve HTTP rejection reasons without a network toast',
    () async {
      var notices = 0;
      var status = 400;
      var body = <String, dynamic>{'code': 400, 'msg': 'QQ已存在'};
      useClient(
        MockClient(
          (_) async => http.Response(
            jsonEncode(body),
            status,
            headers: {'content-type': 'text/plain; charset=utf-8'},
          ),
        ),
        onError: (_) => notices++,
      );
      final service = LoginService(apiTransport.session, apiTransport);
      for (final reason in ['QQ已存在', '用户名已存在']) {
        body = {'code': 400, 'msg': reason};
        final result = await service.performRegister(
          name: 'name',
          pwd: 'password',
          qq: '12345',
        );
        expect(result, (success: false, message: reason));
      }
      status = 429;
      body = {'code': 429, 'message': '请求限速'};
      expect(
        (await service.performRegister(
          name: 'name',
          pwd: 'pwd',
          qq: '12345',
        )).message,
        '请求限速',
      );
      status = 400;
      body = {'code': 400, 'msg': '用户名或密码错误'};
      expect(
        (await service.performLogin(name: 'name', pwd: 'wrong')).message,
        '用户名或密码错误',
      );
      body = {'code': 400, 'msg': 'QQ已存在'};
      expect(
        (await service.updateUser(
          const AppUser(id: 1, name: 'name', qq: '12345', sign: '', level: 1),
          'qq',
          '23456',
        )).message,
        'QQ已存在',
      );
      // Older servers can return an error envelope with HTTP 200.
      status = 200;
      expect(
        await service.performRegister(name: 'name', pwd: 'pwd', qq: '12345'),
        (success: false, message: 'QQ已存在'),
      );
      expect(notices, 0);
    },
  );

  test(
    'registration distinguishes connection, timeout and server failures',
    () async {
      var notices = 0;
      for (final scenario in [
        (
          error: http.ClientException('offline'),
          body: '',
          status: 200,
          message: '无法连接服务器，请检查网络或切换 APP 线路',
        ),
        (
          error: TimeoutException('timeout'),
          body: '',
          status: 200,
          message: '注册请求超时，请稍后重试',
        ),
        (
          error: null,
          body: '<html>upstream failure</html>',
          status: 503,
          message: '服务器暂时不可用（HTTP 503），请稍后重试',
        ),
        (
          error: null,
          body: 'rate limited',
          status: 429,
          message: '请求过于频繁，请稍后重试',
        ),
        (
          error: null,
          body: '<html>unexpected response</html>',
          status: 200,
          message: '服务器响应异常，请稍后重试',
        ),
      ]) {
        useClient(
          MockClient((_) async {
            if (scenario.error != null) throw scenario.error!;
            return http.Response(scenario.body, scenario.status);
          }),
          onError: (_) => notices++,
        );
        expect(
          await LoginService(
            apiTransport.session,
            apiTransport,
          ).performRegister(name: 'name', pwd: 'password', qq: '12345'),
          (success: false, message: scenario.message),
        );
      }
      expect(notices, 0);
    },
  );

  testWidgets('registration can retry a rejection then switch to login', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(Get.reset);
    var requests = 0;
    var notices = 0;
    useClient(
      MockClient((request) async {
        requests++;
        expect(request.method, 'POST');
        expect(request.url.path, '/user/register');
        expect(jsonDecode(request.body), {
          'name': 'new-user',
          'pwd': ' password ',
          'qq': '12345',
        });
        return http.Response(
          jsonEncode(
            requests == 1
                ? {'code': 400, 'msg': 'QQ已存在'}
                : {'code': 200, 'msg': '注册成功啦'},
          ),
          requests == 1 ? 400 : 200,
          headers: {'content-type': 'text/plain; charset=utf-8'},
        );
      }),
      onError: (_) => notices++,
    );
    Get.put<AccountSession>(apiTransport.session);
    Get.put<ApiTransport>(apiTransport);
    bangumiSession = BangumiSession(
      Instances.sp,
      apiTransport.session,
      BangumiApi(client: apiTransport.client),
      const BangumiOAuthBroker(),
    );
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: scaffoldMessengerKey,
        home: const Login(),
      ),
    );
    await tester.tap(find.text('注册'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), ' 12345 ');
    await tester.enterText(find.byType(TextFormField).at(1), ' new-user ');
    await tester.enterText(find.byType(TextFormField).at(2), ' password ');
    await tester.enterText(find.byType(TextFormField).at(3), ' password ');
    expect(find.byType(TextFormField), findsNWidgets(4));
    expect(find.byType(EmailVerificationFields), findsNothing);
    await tester.ensureVisible(find.text('注 册'));
    await tester.tap(find.text('注 册'));
    await tester.pumpAndSettle();
    expect(find.text('QQ已存在'), findsOneWidget);
    expect(find.text('注 册'), findsOneWidget);
    await tester.tap(find.text('注 册'));
    await tester.pumpAndSettle();
    expect(find.text('登 录'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(requests, 2);
    expect(notices, 0);
    expect(apiTransport.session.isLoggedIn, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('registration accepts no QQ or email without sending an OTP', () async {
    var requests = 0;
    useClient(
      MockClient((request) async {
        requests++;
        expect(request.url.path, '/user/register');
        expect(jsonDecode(request.body), {
          'name': 'no-contact',
          'pwd': 'password',
          'qq': '',
        });
        return http.Response('{"code":200}', 200);
      }),
    );
    final result = await LoginService(
      apiTransport.session,
      apiTransport,
    ).performRegister(name: 'no-contact', pwd: 'password');
    expect(result.success, isTrue);
    expect(requests, 1);
  });

  test('QQ recovery sends and resets with the same QQ mailbox', () async {
    final paths = <String>[];
    useClient(
      MockClient((request) async {
        paths.add(request.url.path);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['email'], '123456@qq.com');
        if (request.url.path.endsWith('/code')) {
          expect(body['purpose'], 'reset_password');
        } else {
          expect(body['code'], '123456');
          expect(body['new_password'], 'new-password');
        }
        return http.Response('{"code":200}', 200);
      }),
    );
    final service = LoginService(apiTransport.session, apiTransport);
    expect(
      (await service.sendEmailCode(
        email: ' 123456 ',
        purpose: 'reset_password',
      )).success,
      isTrue,
    );
    expect(
      (await service.resetPassword(
        email: '123456',
        code: '123456',
        password: 'new-password',
      )).success,
      isTrue,
    );
    expect(paths, ['/user/email/code', '/user/password/reset']);
  });

  test('changing QQ submits current password with the profile', () async {
    const user = AppUser(id: 1, name: 'user', qq: '123456', sign: '', level: 1);
    await apiTransport.session.saveLoginInfo('access', user);
    useClient(
      MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['qq'], '654321');
        expect(body['current_password'], 'current-password');
        return http.Response(
          jsonEncode({
            'code': 200,
            'data': {
              'id': 1,
              'name': 'user',
              'qq': '654321',
              'sign': '',
              'level': 1,
            },
          }),
          200,
        );
      }),
    );
    final result = await LoginService(
      apiTransport.session,
      apiTransport,
    ).updateUser(user, 'qq', '654321', currentPassword: 'current-password');
    expect(result.success, isTrue);
    expect(result.user?.recoveryEmail, '654321@qq.com');
  });

  test(
    'email recovery omits stale credentials and preserves rejection reasons',
    () async {
      await apiTransport.session.saveLoginInfo(
        'stale-access',
        const AppUser(id: 1, name: 'old', qq: '12345', sign: '', level: 1),
        tokenExpiresAt: '2000-01-01T00:00:00Z',
      );
      final paths = <String>[];
      useClient(
        MockClient((request) async {
          paths.add(request.url.path);
          expect(request.headers.containsKey('token'), isFalse);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['email'], 'new@example.com');
          if (request.url.path == '/user/email/code') {
            expect(body['purpose'], 'reset_password');
            return http.Response(
              jsonEncode({'code': 200, 'msg': '若该邮箱可用于本次操作，验证码已发送'}),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          expect(body['code'], '042815');
          expect(body['new_password'], ' new-password ');
          return http.Response(
            jsonEncode({'code': 400, 'msg': '验证码已过期'}),
            400,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final service = LoginService(apiTransport.session, apiTransport);
      expect(
        (await service.sendEmailCode(
          email: ' new@example.com ',
          purpose: 'reset_password',
        )).success,
        isTrue,
      );
      expect(
        await service.resetPassword(
          email: ' new@example.com ',
          code: '042815',
          password: ' new-password ',
        ),
        (success: false, message: '验证码已过期'),
      );
      expect(paths, ['/user/email/code', '/user/password/reset']);
      expect(apiTransport.session.token, 'stale-access');
    },
  );

  test(
    'email binding retains authenticated identity and updated mailbox',
    () async {
      await apiTransport.session.saveLoginInfo(
        'access',
        const AppUser(id: 1, name: 'user', qq: '12345', sign: '', level: 1),
      );
      useClient(
        MockClient((request) async {
          expect(request.headers['token'], 'access');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['current_password'], 'current-password');
          expect(body['email'], 'bound@example.com');
          expect(body['code'], '042815');
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'id': 1,
                'name': 'user',
                'qq': '12345',
                'sign': '',
                'level': 1,
                'email': 'bound@example.com',
                'email_verified': true,
              },
            }),
            200,
          );
        }),
      );
      final service = LoginService(apiTransport.session, apiTransport);
      final result = await service.bindEmail(
        email: 'bound@example.com',
        code: '042815',
        currentPassword: 'current-password',
      );
      expect(result.success, isTrue);
      expect(apiTransport.session.user.value.email, 'bound@example.com');
      expect(apiTransport.session.user.value.emailVerified, isTrue);
      expect(
        AppUser.fromJson(
          apiTransport.session.user.value.toJson(),
        ).emailVerified,
        isTrue,
      );
    },
  );

  testWidgets('email code fields prevent repeat sends during cooldown', (
    tester,
  ) async {
    addTearDown(Get.reset);
    var sends = 0;
    useClient(
      MockClient((request) async {
        sends++;
        expect(request.url.path, '/user/email/code');
        expect(jsonDecode(request.body)['purpose'], 'register');
        return http.Response(
          jsonEncode({'code': 200, 'msg': '验证码已发送，请检查收件箱'}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    Get.put<AccountSession>(apiTransport.session);
    Get.put<ApiTransport>(apiTransport);
    final email = TextEditingController(text: 'new@example.com');
    final code = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Form(
            child: EmailVerificationFields(
              email: email,
              code: code,
              purpose: 'register',
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();
    expect(sends, 1);
    expect(find.text('60s 后重发'), findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    expect(find.text('验证码已发送，请检查收件箱'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    email.dispose();
    code.dispose();
  });

  test(
    'credential requests refuse redirects and server changes invalidate detail cache',
    () async {
      var calls = 0;
      useClient(
        MockClient((request) async {
          calls++;
          expect(request.followRedirects, isFalse);
          if (request.url.path == '/redirect') {
            return http.Response(
              '',
              302,
              headers: {'location': 'https://outside.test'},
            );
          }
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'server': request.url.host},
            }),
            200,
          );
        }),
      );
      await expectLater(
        apiTransport.getJson<Object>('$host/redirect'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 302)),
      );
      final first = await AniBakaApi.getAnimeDetail(543210);
      expect(await AniBakaApi.getAnimeDetail(543210), same(first));
      await Instances.sp.setString('host', 'other.test');
      final next = await AniBakaApi.getAnimeDetail(543210);
      expect(next?['server'], 'other.test');
      expect(calls, 3);
    },
  );

  test(
    'shared sender aborts a timeout while reading the response body',
    () async {
      final aborted = Completer<void>();
      final stream = StreamController<List<int>>();
      addTearDown(stream.close);
      final client = _StreamingClient((request) async {
        final abortable = request as http.AbortableRequest;
        abortable.abortTrigger!.then((_) {
          aborted.complete();
          stream.addError(http.RequestAbortedException(request.url));
          stream.close();
        });
        return http.StreamedResponse(stream.stream, 200);
      });
      await expectLater(
        sendHttp(
          client,
          'GET',
          Uri.parse('https://example.test/slow'),
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await aborted.future;
    },
  );

  for (final readingBody in [false, true]) {
    test(
      'request cancellation is silent (reading body: $readingBody)',
      () async {
        var notices = 0;
        final started = Completer<void>();
        final abort = Completer<void>();
        useClient(
          _StreamingClient((request) async {
            final trigger = (request as http.AbortableRequest).abortTrigger!;
            started.complete();
            if (!readingBody) {
              await trigger;
              throw http.RequestAbortedException(request.url);
            }
            final body = StreamController<List<int>>();
            trigger.then((_) {
              body.addError(http.RequestAbortedException(request.url));
              unawaited(body.close());
            });
            return http.StreamedResponse(body.stream, 200);
          }),
          onError: (_) => notices++,
        );
        final result = apiTransport.getJson<Object>(
          '$host/cancelled',
          abortTrigger: abort.future,
        );
        final assertion = expectLater(
          result,
          throwsA(isA<http.RequestAbortedException>()),
        );
        await started.future;
        abort.complete();
        await assertion;
        expect(notices, 0);
      },
    );
  }

  test('request timeout still notifies when the sender aborts HTTP', () async {
    final notices = <Object>[];
    final aborted = Completer<void>();
    useClient(
      _StreamingClient((request) async {
        await (request as http.AbortableRequest).abortTrigger;
        aborted.complete();
        throw http.RequestAbortedException(request.url);
      }),
      onError: notices.add,
    );
    await expectLater(
      apiTransport.getJson<Object>(
        '$host/timeout',
        timeout: const Duration(milliseconds: 10),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await aborted.future;
    expect(notices, [isA<TimeoutException>()]);
  });

  test(
    'Bangumi keeps its own credentials and preserves 404/204 semantics',
    () async {
      final api = BangumiApi(
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer bgm-token');
          expect(request.headers['token'], isNull);
          expect(
            request.headers['user-agent'],
            contains('AniBakaBaka/AniBaka/'),
          );
          if (request.url.path == '/v0/me') {
            return http.Response('{"username":"bgm","nickname":"name"}', 200);
          }
          if (request.method == 'GET') {
            return http.Response('{"title":"missing"}', 404);
          }
          return http.Response('', 204);
        }),
      );
      addTearDown(api.close);
      expect((await api.getMe('bgm-token')).username, 'bgm');
      expect(await api.getCollection('bgm-token', 1), isNull);
      await api.putCollection(
        'bgm-token',
        const AnimeCollection(bgmId: 1, status: 3),
      );
    },
  );

  test('OAuth stops on completion, cancellation and deadline', () async {
    var requests = 0;
    useClient(
      MockClient((_) async {
        requests++;
        return http.Response(
          '{"code":0,"data":{"status":"complete","access_token":"bgm"}}',
          200,
        );
      }),
    );
    const broker = BangumiOAuthBroker();
    expect((await broker.waitForCompletion('state')).accessToken, 'bgm');
    expect(requests, 1);

    for (final timeout in [false, true]) {
      final started = Completer<void>();
      useClient(
        _StreamingClient((request) async {
          started.complete();
          await (request as http.AbortableRequest).abortTrigger;
          throw http.RequestAbortedException(request.url);
        }),
      );
      final abort = Completer<void>();
      final result = broker.waitForCompletion(
        'state',
        abortTrigger: abort.future,
        timeout: timeout
            ? const Duration(milliseconds: 10)
            : const Duration(minutes: 10),
      );
      final assertion = expectLater(
        result,
        throwsA(
          timeout
              ? isA<TimeoutException>()
              : isA<http.RequestAbortedException>(),
        ),
      );
      await started.future;
      if (!timeout) abort.complete();
      await assertion;
    }
  });

  test(
    'leaving OAuth login aborts its request without connecting Bangumi',
    () async {
      final pollStarted = Completer<void>();
      useClient(
        _StreamingClient((request) async {
          if (request.url.path.endsWith('/start')) {
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  '{"code":0,"data":{"authorization_url":"https://bgm.tv/oauth","state":"state"}}',
                ),
              ),
              200,
            );
          }
          pollStarted.complete();
          await (request as http.AbortableRequest).abortTrigger;
          throw http.RequestAbortedException(request.url);
        }),
      );
      final api = BangumiApi(
        client: MockClient(
          (_) async => throw StateError('must not fetch account'),
        ),
      );
      addTearDown(api.close);
      final session = BangumiSession(
        Instances.sp,
        apiTransport.session,
        api,
        const BangumiOAuthBroker(),
      );
      final login = await session.beginOAuthLogin();
      final complete = session.completeOAuthLogin(login.state);
      final assertion = expectLater(
        complete,
        throwsA(isA<http.RequestAbortedException>()),
      );
      await pollStarted.future;
      session.cancelOAuthLogin();
      await assertion;
      expect(session.isConnected, isFalse);
    },
  );

  test(
    'BGM lookup does not mutate input and failed searches can be retried',
    () async {
      final data = Map<String, dynamic>.unmodifiable({
        'title': '',
        'content': '<img src="https://image.test/cover.jpg">',
      });
      expect((await resolveBgmFromData(data)).subjectId, isNull);
      var attempts = 0;
      useClient(
        MockClient(
          (_) async => ++attempts == 1
              ? http.Response('offline', 503)
              : http.Response('{"data":[]}', 200),
        ),
      );
      await expectLater(
        searchBgmSubjects('retry-regression'),
        throwsA(isA<ApiException>()),
      );
      expect(await searchBgmSubjects('retry-regression'), isEmpty);
      expect(attempts, 2);
    },
  );

  test('character consumers share only pending requests by subject', () async {
    var calls = 0;
    useClient(
      MockClient((request) async {
        calls++;
        return http.Response('[]', 200);
      }),
    );
    final results = await Future.wait([
      getBgmCharacters(99801),
      getBgmCharacters(99801),
      getBgmCharacters(99802),
    ]);
    expect(calls, 2);
    expect(results[0], same(results[1]));
    await getBgmCharacters(99801);
    expect(calls, 3, reason: 'Large character responses are not retained');
  });
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.handle);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handle;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handle(request);
}

class _ImageCache extends Fake implements BaseCacheManager, ImageCacheManager {
  _ImageCache(this.responses);
  final Stream<FileResponse> Function(String url) responses;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => responses(url);

  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) => responses(url);
}
