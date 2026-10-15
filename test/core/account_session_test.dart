import 'dart:async';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/models/app_user.dart';
import 'package:baka/models/token_response.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const user = AppUser(id: 1, name: 'one', qq: '', sign: '', level: 0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('session', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'usertoken': 'old',
        'refresh_token': 'refresh',
      });
      prefs = await SharedPreferences.getInstance();
    });

    test(
      'concurrent unauthorized requests refresh once and retry once',
      () async {
        var refreshes = 0, requests = 0;
        final session = AccountSession(
          prefs,
          refreshTokens: (_) async {
            refreshes++;
            return const TokenResponse('new');
          },
        );
        final client = ApiTransport(
          session: session,
          version: 'test',
          credentialOrigin: () => Uri.parse('https://example.test'),
          client: MockClient((r) async {
            requests++;
            return http.Response(
              r.headers['token'] == 'new' ? '"ok"' : '',
              r.headers['token'] == 'new' ? 200 : 401,
            );
          }),
        );
        expect(
          await Future.wait(
            List.generate(
              32,
              (_) => client.getJson<String>('https://example.test/data'),
            ),
          ),
          everyElement('ok'),
        );
        expect(refreshes, 1);
        expect(requests, 64);
      },
    );

    test('logout while refreshing cannot restore old credentials', () async {
      final pending = Completer<TokenResponse?>();
      final started = Completer<void>();
      final session = AccountSession(
        prefs,
        refreshTokens: (_) {
          started.complete();
          return pending.future;
        },
      );
      final refreshing = session.refresh();
      await started.future;
      await session.logout();
      pending.complete(const TokenResponse('stale', refreshToken: 'stale'));
      expect(await refreshing, isFalse);
      await session.flush();
      expect(session.token, isEmpty);
      expect(prefs.getString('usertoken'), isNull);
      expect(prefs.getString('refresh_token'), isNull);
    });

    test(
      'refresh starts immediately and shares pending credential work',
      () async {
        final pending = Completer<TokenResponse?>();
        var calls = 0;
        final session = AccountSession(
          prefs,
          refreshTokens: (_) {
            calls++;
            return pending.future;
          },
        );
        final first = session.refresh();
        expect(calls, 1);
        expect(session.refresh(), same(first));
        pending.complete(const TokenResponse('new'));
        expect(await first, isTrue);

        await session.logout();
        expect(await session.refresh(), isFalse);
        await session.login(
          const TokenResponse('next', refreshToken: 'next'),
          user,
        );
        expect(await session.refresh(), isTrue);
        expect(calls, 2);
      },
    );

    test(
      'external origins never receive tokens or refresh an expired session',
      () async {
        await prefs.setString('token_expires_at', '2000-01-01T00:00:00Z');
        var refreshes = 0;
        final session = AccountSession(
          prefs,
          refreshTokens: (_) async {
            refreshes++;
            return null;
          },
        );
        final client = ApiTransport(
          session: session,
          version: 'test',
          credentialOrigin: () => Uri.parse('https://www.anibaka.com'),
          client: MockClient((request) async {
            expect(request.headers.containsKey('token'), isFalse);
            return http.Response('<html>unauthorized</html>', 401);
          }),
        );
        addTearDown(client.close);
        for (final origin in [
          'https://bgm.anibaka.com',
          'https://p1.anibaka.com',
          'https://danmu.anibaka.com',
          'https://version.anibaka.com',
          'https://outside.test',
          'http://www.anibaka.com',
          'https://www.anibaka.com:444',
          'https://www.anibaka.com.outside.test',
        ]) {
          await expectLater(
            client.getJson<String>('$origin/data', notifyOnError: false),
            throwsA(
              isA<ApiException>().having(
                (e) => e.statusCode,
                'HTTP status',
                401,
              ),
            ),
          );
        }
        expect(refreshes, 0);
        expect(session.token, 'old');
        expect(session.generation, 0);
        expect(prefs.getString('usertoken'), 'old');
      },
    );

    test(
      'server changes move the credential boundary and discard old responses',
      () async {
        var origin = 'https://first.test';
        final pending = Completer<http.Response>();
        final started = Completer<void>();
        final session = AccountSession(prefs, refreshTokens: (_) async => null);
        final client = ApiTransport(
          session: session,
          version: 'test',
          credentialOrigin: () => Uri.parse(origin),
          client: MockClient((request) async {
            expect(
              request.headers['token'],
              request.url.origin == origin ? 'old' : null,
            );
            if (request.url.path == '/pending') {
              started.complete();
              return pending.future;
            }
            return http.Response('"ok"', 200);
          }),
        );
        addTearDown(client.close);
        final request = client.getJson<String>('$origin/pending');
        await started.future;
        origin = 'https://second.test';
        pending.complete(http.Response('stale', 200));
        await expectLater(request, throwsStateError);
        expect(await client.getJson<String>('https://first.test/data'), 'ok');
        expect(await client.getJson<String>('$origin/data'), 'ok');
      },
    );

    test('refresh network failure is preserved without logging out', () async {
      final failure = TimeoutException('refresh offline');
      final session = AccountSession(
        prefs,
        refreshTokens: (_) async => throw failure,
      );
      final client = ApiTransport(
        session: session,
        version: 'test',
        credentialOrigin: () => Uri.parse('https://example.test'),
        client: MockClient((_) async => http.Response('', 401)),
      );
      addTearDown(client.close);
      await expectLater(
        client.getJson<String>(
          'https://example.test/data',
          notifyOnError: false,
        ),
        throwsA(same(failure)),
      );
      expect(session.token, 'old');
      expect(session.generation, 0);
    });

    test(
      'only definitive account rejection logs out; auth and broker 401 do not',
      () async {
        var refreshes = 0;
        final session = AccountSession(
          prefs,
          refreshTokens: (_) async {
            refreshes++;
            return null;
          },
        );
        final client = ApiTransport(
          session: session,
          version: 'test',
          credentialOrigin: () => Uri.parse('https://example.test'),
          client: MockClient((request) async {
            if (request.url.path.startsWith('/user/')) {
              expect(request.headers['token'], isNull);
            }
            return http.Response('', 401);
          }),
        );
        addTearDown(client.close);
        for (final path in [
          '/user/login',
          '/user/refresh',
          '/api/v1/bangumi/oauth/refresh',
        ]) {
          await expectLater(
            client.postJson<Object>(
              'https://example.test$path',
              {},
              notifyOnError: false,
            ),
            throwsA(isA<ApiException>()),
          );
        }
        expect(refreshes, 0);
        expect(session.token, 'old');
        await expectLater(
          client.getJson<String>(
            'https://example.test/private',
            notifyOnError: false,
          ),
          throwsA(isA<ApiException>()),
        );
        expect(refreshes, 1);
        expect(session.token, isEmpty);
        expect(prefs.getString('usertoken'), isNull);
      },
    );

    test('response from the previous account is discarded', () async {
      final response = Completer<http.Response>();
      final session = AccountSession(prefs, refreshTokens: (_) async => null);
      final client = ApiTransport(
        session: session,
        version: 'test',
        credentialOrigin: () => Uri.parse('https://example.test'),
        client: MockClient((_) => response.future),
      );
      final request = client.getJson<String>('https://example.test/private');
      await session.login(const TokenResponse('other'), user);
      response.complete(http.Response('old account data', 200));
      await expectLater(request, throwsStateError);
      expect(session.token, 'other');
    });

    test('credential writes finish in account transition order', () async {
      final session = AccountSession(prefs, refreshTokens: (_) async => null);
      final first = session.login(
        const TokenResponse('one', refreshToken: 'r'),
        user,
      );
      final second = session.logout();
      final third = session.login(const TokenResponse('three'), user);
      await Future.wait([first, second, third]);
      expect(prefs.getString('usertoken'), 'three');
      expect(prefs.getString('refresh_token'), isNull);
    });

    test(
      'missing or failing refresh can be tried again without a stuck future',
      () async {
        var calls = 0;
        final session = AccountSession(
          prefs,
          refreshTokens: (_) async {
            if (++calls == 1) throw StateError('offline');
            return const TokenResponse('new');
          },
        );
        await expectLater(session.refresh(), throwsStateError);
        expect(await session.refresh(), isTrue);
        expect(calls, 2);
      },
    );
  });
}
