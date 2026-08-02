import 'dart:convert';

import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/pages/login/login_page.dart';
import 'package:baka/pages/setting/bangumi_sync_page.dart';
import 'package:baka/services/bangumi_sync_service.dart';
import 'package:baka/services/collection_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'usertoken': 'anibaka-token'});
    Instances.sp = await SharedPreferences.getInstance();
    Instances.appVersion = 'test';
  });

  test('connect validates, normalizes and stores the Bangumi token', () async {
    final api = _FakeBangumiApi();
    final service = BangumiSyncService(
      api: api,
      collections: _FakeCollectionStore([]),
    );

    final account = await service.connect('  Bearer bgm-token  ');

    expect(api.lastToken, 'bgm-token');
    expect(account.username, 'sai');
    expect(service.isConnected, isTrue);
    expect(service.account?.nickname, 'Sai');
  });

  testWidgets('settings prioritizes a concealed Access Token input', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: BangumiSyncPage()));
    await tester.pump();

    expect(find.text('使用 Access Token（推荐）'), findsOneWidget);
    expect(find.text('粘贴 Access Token'), findsOneWidget);
    expect(find.text('去 Bangumi 获取 Access Token'), findsOneWidget);
    expect(find.text('账号授权登录（经过 AniBaka 服务器）'), findsOneWidget);
    expect(find.byType(SvgPicture), findsNWidgets(2));
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('粘贴 Access Token'));
    await tester.pumpAndSettle();

    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.obscureText, isTrue);
  });

  testWidgets('login page presents Bangumi as a secondary identity', (
    tester,
  ) async {
    await Instances.sp.remove('usertoken');
    await tester.pumpWidget(const MaterialApp(home: Login()));
    await tester.pump();

    expect(find.text('Bangumi 登录'), findsOneWidget);
    expect(find.text('使用 Access Token 登录'), findsOneWidget);
    expect(find.text('前往 Bangumi 官方页面获取 Access Token'), findsOneWidget);

    await tester.ensureVisible(find.text('使用 Access Token 登录'));
    await tester.tap(find.text('使用 Access Token 登录'));
    await tester.pumpAndSettle();
    expect(find.text('使用 Bangumi 身份'), findsOneWidget);
    expect(find.textContaining('可能需要先开启代理软件'), findsOneWidget);
    expect(find.textContaining('推荐同时登录 AniBaka'), findsOneWidget);
  });

  testWidgets('account OAuth shows server and token risks before continuing', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: BangumiSyncPage()));
    await tester.pump();

    final oauthButton = find.text('账号授权登录（经过 AniBaka 服务器）');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(oauthButton);
    await tester.pumpAndSettle();

    expect(find.text('账号授权会经过 AniBaka 服务器'), findsOneWidget);
    expect(find.textContaining('接收 Bangumi 返回的授权码'), findsOneWidget);
    expect(find.textContaining('Access Token 与 Refresh Token'), findsOneWidget);
    expect(find.textContaining('IP、时间和 Bangumi 授权行为'), findsOneWidget);
    expect(find.textContaining('不要把该令牌理解成仅能同步追番'), findsOneWidget);
    expect(find.text('了解风险，继续登录'), findsOneWidget);
    expect(find.text('改用 Access Token'), findsOneWidget);
  });

  test(
    'OAuth login opens an authorization session and stores returned tokens',
    () async {
      final api = _FakeBangumiApi();
      final broker = _FakeBangumiOAuthBroker();
      final service = BangumiSyncService(
        api: api,
        oauthBroker: broker,
        collections: _FakeCollectionStore([]),
      );

      final login = await service.beginOAuthLogin();
      final account = await service.completeOAuthLogin(login.state);

      expect(login.authorizationUrl, 'https://bgm.tv/oauth/authorize?test=1');
      expect(broker.completedState, 'oauth-state');
      expect(account.username, 'sai');
      expect(api.lastToken, 'oauth-access');
      expect(Instances.sp.getString('bangumi_access_token'), 'oauth-access');
      expect(Instances.sp.getString('bangumi_refresh_token'), 'oauth-refresh');
      expect(Instances.sp.getString('bangumi_token_expires_at'), isNotEmpty);
    },
  );

  test('expired OAuth access tokens are refreshed through AniBaka', () async {
    final api = _FakeBangumiApi();
    final broker = _FakeBangumiOAuthBroker();
    final service = BangumiSyncService(
      api: api,
      oauthBroker: broker,
      collections: _FakeCollectionStore([]),
    );
    await service.completeOAuthLogin('oauth-state');
    await Instances.sp.setString(
      'bangumi_token_expires_at',
      DateTime.now()
          .subtract(const Duration(minutes: 1))
          .toUtc()
          .toIso8601String(),
    );

    await service.sync();

    expect(broker.refreshedToken, 'oauth-refresh');
    expect(api.lastToken, 'refreshed-access');
    expect(
      Instances.sp.getString('bangumi_refresh_token'),
      'refreshed-refresh',
    );
  });

  test(
    'first sync imports remote conflicts and uploads local-only records',
    () async {
      final remote = BangumiCollectionRecord(
        subjectId: 1,
        status: CollectionStatus.doing.value,
        rating: 8,
        episodeWatched: 4,
        tags: const ['TV', '治愈'],
        isPrivate: true,
        title: '远端番剧',
        comment: '远端短评',
        episodeTotal: 12,
        subjectScore: 7.9,
      );
      final api = _FakeBangumiApi(records: [remote]);
      final store = _FakeCollectionStore([
        AnimeCollection(
          bgmId: 1,
          status: CollectionStatus.wish.value,
          epWatched: 0,
          bgmTitle: '本地旧记录',
        ),
        AnimeCollection(
          bgmId: 2,
          status: CollectionStatus.doing.value,
          rating: 9,
          epWatched: 3,
          tags: '科幻,TV',
          bgmTitle: '本地新记录',
        ),
      ]);
      final service = BangumiSyncService(api: api, collections: store);
      await service.connect('bgm-token');

      final report = await service.sync();

      expect(report.imported, 1);
      expect(report.exported, 1);
      expect(report.failed, 0);
      expect(store.items[1]?.status, CollectionStatus.doing.value);
      expect(store.items[1]?.rating, 8);
      expect(store.items[1]?.epWatched, 4);
      expect(store.items[1]?.tags, 'TV,治愈');
      expect(api.uploaded.map((item) => item.bgmId), contains(2));
      expect(api.progress, contains((2, 3)));
    },
  );

  test('later local changes are uploaded when Bangumi is unchanged', () async {
    final remote = BangumiCollectionRecord(
      subjectId: 1,
      status: CollectionStatus.doing.value,
      rating: 0,
      episodeWatched: 2,
      tags: const [],
      isPrivate: false,
      title: '同步番剧',
      episodeTotal: 12,
    );
    final api = _FakeBangumiApi(records: [remote]);
    final store = _FakeCollectionStore([remote.toAnimeCollection()]);
    final service = BangumiSyncService(api: api, collections: store);
    await service.connect('bgm-token');

    final baseline = await service.sync();
    expect(baseline.unchanged, 1);

    store.items[1] = AnimeCollection(
      bgmId: 1,
      status: CollectionStatus.onHold.value,
      rating: 7,
      epWatched: 5,
      bgmTitle: '同步番剧',
    );
    final report = await service.sync();

    expect(report.exported, 1);
    expect(report.imported, 0);
    expect(api.uploaded.last.status, CollectionStatus.onHold.value);
    expect(api.progress.last, (1, 5));
  });

  test(
    'completed playback creates doing status and advances only once',
    () async {
      final api = _FakeBangumiApi();
      final service = BangumiSyncService(
        api: api,
        collections: _FakeCollectionStore([]),
      );
      await service.connect('bgm-token');

      await service.markEpisodeWatched(subjectId: 99, watched: 3);
      await service.markEpisodeWatched(subjectId: 99, watched: 3);

      expect(api.uploaded, hasLength(1));
      expect(api.uploaded.single.status, CollectionStatus.doing.value);
      expect(api.progress, [(99, 3)]);
    },
  );

  test('completed playback never moves Bangumi progress backwards', () async {
    final api = _FakeBangumiApi(
      records: [
        BangumiCollectionRecord(
          subjectId: 99,
          status: CollectionStatus.doing.value,
          rating: 0,
          episodeWatched: 6,
          tags: const [],
          isPrivate: false,
          title: '已有进度',
        ),
      ],
    );
    final service = BangumiSyncService(
      api: api,
      collections: _FakeCollectionStore([]),
    );
    await service.connect('bgm-token');

    await service.markEpisodeWatched(subjectId: 99, watched: 3);

    expect(api.uploaded, isEmpty);
    expect(api.progress, isEmpty);
  });

  test('a one-sided deletion is not immediately recreated', () async {
    final remote = BangumiCollectionRecord(
      subjectId: 1,
      status: CollectionStatus.doing.value,
      rating: 0,
      episodeWatched: 2,
      tags: const [],
      isPrivate: false,
      title: '同步番剧',
    );
    final api = _FakeBangumiApi(records: [remote]);
    final store = _FakeCollectionStore([remote.toAnimeCollection()]);
    final service = BangumiSyncService(api: api, collections: store);
    await service.connect('bgm-token');
    await service.sync();

    store.items.remove(1);
    final report = await service.sync();

    expect(report.skippedDeletions, 1);
    expect(store.items, isNot(contains(1)));
    expect(api.uploaded, isEmpty);
  });

  test('sync imports into device storage without an AniBaka login', () async {
    await Instances.sp.remove('usertoken');
    final remote = BangumiCollectionRecord(
      subjectId: 42,
      status: CollectionStatus.doing.value,
      rating: 9,
      episodeWatched: 6,
      tags: const ['本地同步'],
      isPrivate: false,
      title: '本地番剧',
      comment: '无需 AniBaka 登录',
      episodeTotal: 12,
      subjectScore: 8.2,
    );
    final service = BangumiSyncService(api: _FakeBangumiApi(records: [remote]));
    await service.connect('bgm-token');

    final report = await service.sync();
    final saved = await CollectionService.getByBgmId(42, refreshBangumi: false);

    expect(service.isLocalMode, isTrue);
    expect(report.imported, 1);
    expect(saved?.displayTitle, '本地番剧');
    expect(saved?.epWatched, 6);
    expect(saved?.bgmRating, 8.2);
    expect(Instances.sp.getString('bangumi_local_sync_snapshot'), isNotEmpty);
    expect(Instances.sp.getString('bangumi_local_last_sync_at'), isNotEmpty);
    expect(Instances.sp.getString('bangumi_sync_snapshot'), isNull);
  });

  test('device collection storage supports filtering and deletion', () async {
    await Instances.sp.remove('usertoken');
    await CollectionService.addOrUpdate(
      AnimeCollection(
        bgmId: 10,
        status: CollectionStatus.doing.value,
        bgmTitle: '在看番剧',
      ),
    );
    await CollectionService.addOrUpdate(
      AnimeCollection(
        bgmId: 20,
        status: CollectionStatus.collect.value,
        bgmTitle: '看过番剧',
      ),
    );

    final doing = await CollectionService.getList(
      status: CollectionStatus.doing.value,
    );
    final stats = await CollectionService.getStats();

    expect(doing?.list.single.bgmId, 10);
    expect(stats?.doing, 1);
    expect(stats?.collect, 1);
    expect(stats?.total, 2);
    expect(await CollectionService.deleteByBgmId(10), isTrue);
    expect(await CollectionService.getByBgmId(10), isNull);
  });

  testWidgets('local sync stays enabled without an AniBaka login', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'bangumi_access_token': 'bgm-token',
      'bangumi_account': jsonEncode({'username': 'sai', 'nickname': 'Sai'}),
    });
    Instances.sp = await SharedPreferences.getInstance();

    await tester.pumpWidget(const MaterialApp(home: BangumiSyncPage()));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('立即同步'),
      250,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.textContaining('本地模式：与这台设备'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('立即同步'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      ),
    );
    expect(button.onPressed, isNotNull);
  });

  test('API client uses collection and batch episode v0 contracts', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET' && request.url.path.endsWith('/episodes')) {
        return http.Response(
          jsonEncode({
            'data': [
              {
                'type': 0,
                'episode': {'id': 11, 'sort': 1},
              },
              {
                'type': 2,
                'episode': {'id': 12, 'sort': 2},
              },
              {
                'type': 2,
                'episode': {'id': 13, 'sort': 3},
              },
            ],
          }),
          200,
        );
      }
      return http.Response('', 204);
    });
    final api = BangumiApiClient(client: client);
    final collection = AnimeCollection(
      bgmId: 42,
      status: CollectionStatus.doing.value,
      rating: 8,
      comment: '短评',
      epWatched: 1,
      tags: 'TV,治愈',
      isPrivate: true,
    );

    await api.putCollection('token', collection);
    await api.putEpisodeProgress('token', 42, 1);

    final collectionRequest = requests.first;
    expect(collectionRequest.method, 'POST');
    expect(collectionRequest.url.path, '/v0/users/-/collections/42');
    expect(collectionRequest.headers['authorization'], 'Bearer token');
    expect(collectionRequest.headers['user-agent'], contains('AniBaka'));
    final collectionBody = jsonDecode(collectionRequest.body) as Map;
    expect(collectionBody['type'], CollectionStatus.doing.value);
    expect(collectionBody['tags'], ['TV', '治愈']);
    expect(collectionBody, isNot(contains('ep_status')));

    final episodeGet = requests[1];
    expect(episodeGet.method, 'GET');
    expect(episodeGet.url.queryParameters['episode_type'], '0');
    final episodePatches = requests.skip(2).toList();
    expect(episodePatches, hasLength(2));
    expect(jsonDecode(episodePatches[0].body), {
      'episode_id': [11],
      'type': 2,
    });
    expect(jsonDecode(episodePatches[1].body), {
      'episode_id': [12, 13],
      'type': 0,
    });
  });
}

class _FakeCollectionStore implements CollectionSyncStore {
  _FakeCollectionStore(List<AnimeCollection> initial)
    : items = {
        for (final item in initial)
          if (item.bgmId != null) item.bgmId!: item,
      };

  final Map<int, AnimeCollection> items;

  @override
  Future<List<AnimeCollection>> getAll() async => items.values.toList();

  @override
  Future<bool> save(AnimeCollection collection) async {
    items[collection.bgmId!] = collection;
    return true;
  }
}

class _FakeBangumiApi implements BangumiApi {
  _FakeBangumiApi({List<BangumiCollectionRecord> records = const []})
    : records = [...records];

  final List<BangumiCollectionRecord> records;
  final List<AnimeCollection> uploaded = [];
  final List<(int, int)> progress = [];
  String? lastToken;

  @override
  Future<BangumiAccount> getMe(String token) async {
    lastToken = token;
    return const BangumiAccount(username: 'sai', nickname: 'Sai');
  }

  @override
  Future<BangumiCollectionRecord?> getCollection(
    String token,
    int subjectId,
  ) async {
    lastToken = token;
    for (final record in records) {
      if (record.subjectId == subjectId) return record;
    }
    return null;
  }

  @override
  Future<List<BangumiCollectionRecord>> getAnimeCollections(
    String token,
    String username,
  ) async {
    lastToken = token;
    return [...records];
  }

  @override
  Future<void> putCollection(String token, AnimeCollection collection) async {
    lastToken = token;
    uploaded.add(collection);
    final id = collection.bgmId!;
    records.removeWhere((record) => record.subjectId == id);
    records.add(
      BangumiCollectionRecord(
        subjectId: id,
        status: collection.status,
        rating: collection.rating,
        episodeWatched: collection.epWatched ?? 0,
        tags: collection.tags?.split(',') ?? const [],
        isPrivate: collection.isPrivate,
        title: collection.displayTitle,
        comment: collection.comment,
        episodeTotal: collection.epTotal,
      ),
    );
  }

  @override
  Future<void> putEpisodeProgress(
    String token,
    int subjectId,
    int watched,
  ) async {
    lastToken = token;
    progress.add((subjectId, watched));
  }
}

class _FakeBangumiOAuthBroker implements BangumiOAuthBroker {
  String? completedState;
  String? refreshedToken;

  @override
  Future<BangumiOAuthStart> begin() async {
    return const BangumiOAuthStart(
      authorizationUrl: 'https://bgm.tv/oauth/authorize?test=1',
      state: 'oauth-state',
    );
  }

  @override
  Future<BangumiOAuthToken> waitForCompletion(String state) async {
    completedState = state;
    return const BangumiOAuthToken(
      accessToken: 'oauth-access',
      refreshToken: 'oauth-refresh',
      expiresIn: 604800,
    );
  }

  @override
  Future<BangumiOAuthToken> refresh(String refreshToken) async {
    refreshedToken = refreshToken;
    return const BangumiOAuthToken(
      accessToken: 'refreshed-access',
      refreshToken: 'refreshed-refresh',
      expiresIn: 604800,
    );
  }
}
