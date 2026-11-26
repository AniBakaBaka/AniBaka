import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:baka/api/bangumi_account_api.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/page.dart';
import 'package:baka/pages/library/library_page.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/services/collection/bangumi_sync.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CollectionsApi extends BangumiApi {
  @override
  Future<List<AnimeCollection>> getAnimeCollections(
    String token,
    String username,
  ) async => [
    for (var i = 1; i <= 100; i++)
      AnimeCollection.fromBangumi({
        'subject_id': i,
        'type': 3,
        'rate': 0,
        'ep_status': 0,
        'tags': <String>[],
        'private': false,
        'subject': {'id': i, 'name': 'Show $i'},
      }),
  ];
}

class _OfflinePutApi extends BangumiApi {
  _OfflinePutApi(this.remote);

  final AnimeCollection remote;
  int puts = 0;

  @override
  Future<List<AnimeCollection>> getAnimeCollections(
    String token,
    String username,
  ) async => [remote];

  @override
  Future<AnimeCollection?> getCollection(String token, int subjectId) async =>
      remote;

  @override
  Future<void> putCollection(
    String token,
    AnimeCollection collection, {
    bool statusOnly = false,
  }) async {
    puts++;
    throw StateError('bangumi offline');
  }
}

class _LoadingCollections extends CollectionRepository {
  _LoadingCollections(super.session, super.bangumi);

  final response = Completer<PageData<AnimeCollection>>();

  @override
  Future<PageData<AnimeCollection>> getList({
    int page = 1,
    int pageSize = 20,
    int? status,
    int? bgmId,
  }) => response.future;
}

/// Bangumi 上一个收藏都没有，用来验证本机条目是否会被清掉。
class _EmptyCollectionsApi extends BangumiApi {
  @override
  Future<List<AnimeCollection>> getAnimeCollections(
    String token,
    String username,
  ) async => const [];

  @override
  Future<AnimeCollection?> getCollection(String token, int subjectId) async =>
      null;

  @override
  Future<void> putCollection(
    String token,
    AnimeCollection collection, {
    bool statusOnly = false,
  }) async {}
}

/// Bangumi 上没有这条收藏；[unreachable] 为 true 时连读取都失败。
class _MissingApi extends BangumiApi {
  _MissingApi({required this.unreachable});
  final bool unreachable;

  @override
  Future<AnimeCollection?> getCollection(String token, int subjectId) async {
    if (unreachable) throw const BangumiSyncException('offline');
    return null;
  }

  @override
  Future<void> putCollection(
    String token,
    AnimeCollection collection, {
    bool statusOnly = false,
  }) async {}
}

/// 远端永远不返回，用来确认页面不会等它。
/// 云端挂掉时，Bangumi 直连仍然能返回收藏。
class _StaticCollectionsApi extends BangumiApi {
  _StaticCollectionsApi(this.items);

  final List<AnimeCollection> items;

  @override
  Future<List<AnimeCollection>> getAnimeCollections(
    String token,
    String username,
  ) async => items;

  @override
  Future<void> putCollection(
    String token,
    AnimeCollection collection, {
    bool statusOnly = false,
  }) async {}
}

class _HangingApi extends BangumiApi {
  @override
  Future<List<AnimeCollection>> getAnimeCollections(
    String token,
    String username,
  ) => Completer<List<AnimeCollection>>().future;

  @override
  Future<void> putCollection(
    String token,
    AnimeCollection collection, {
    bool statusOnly = false,
  }) async {}
}

/// 远端列表可以手动放行，用来复现「刷新在途时改了状态」。
class _SlowCollectionsApi extends BangumiApi {
  final requested = Completer<void>();
  final response = Completer<List<AnimeCollection>>();

  @override
  Future<List<AnimeCollection>> getAnimeCollections(
    String token,
    String username,
  ) {
    if (!requested.isCompleted) requested.complete();
    return response.future;
  }

  @override
  Future<AnimeCollection?> getCollection(String token, int subjectId) async =>
      null;

  @override
  Future<void> putCollection(
    String token,
    AnimeCollection collection, {
    bool statusOnly = false,
  }) async {}
}

/// 写入行为可以切换：断网、被拒收、正常。
class _FlakyApi extends BangumiApi {
  bool offline = true;
  final rejected = <int>{};
  final pushed = <int>[];

  @override
  Future<List<AnimeCollection>> getAnimeCollections(
    String token,
    String username,
  ) async => const [];

  @override
  Future<AnimeCollection?> getCollection(String token, int subjectId) async =>
      null;

  @override
  Future<void> putCollection(
    String token,
    AnimeCollection collection, {
    bool statusOnly = false,
  }) async {
    final bgmId = collection.bgmId!;
    if (offline) throw StateError('bangumi offline');
    if (rejected.contains(bgmId)) {
      throw const BangumiSyncException('not found', statusCode: 404);
    }
    pushed.add(bgmId);
  }
}

Future<void> _navigateAwayAndBack(WidgetTester tester) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  unawaited(
    navigator.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Next'))),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
  await tester.pump(const Duration(milliseconds: 400));
  expect(tester.takeException(), isNull);
  navigator.pop();
  await tester.pump();
  expect(tester.takeException(), isNull);
  await tester.pump(const Duration(milliseconds: 400));
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'collection tags share one list through Bangumi and local storage',
    () async {
      final tags = ['原创', 'TV', '科幻,冒险'];
      final collection = AnimeCollection.fromBangumi({
        'subject_id': 42,
        'type': 3,
        'rate': 8,
        'ep_status': 2,
        'tags': tags,
        'private': false,
      });
      final stored = collection.toJson(includeLocalFields: true);
      expect(identical(stored['tags'], collection.tags), isTrue);
      final restored = AnimeCollection.fromJson(
        jsonDecode(jsonEncode(stored)) as Map<String, dynamic>,
      );
      expect(restored.tags, tags);
      expect(
        localCollectionFingerprint(restored),
        localCollectionFingerprint(collection),
      );
      expect(collection.toJson()['tags'], '原创,TV,科幻,冒险');

      final client = MockClient((request) async {
        expect(jsonDecode(request.body)['tags'], tags);
        return http.Response('', 204);
      });
      addTearDown(client.close);
      await BangumiApi(client: client).putCollection('token', restored);
    },
  );

  test('只改状态时 Bangumi 只收到 type', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/v0/users/-/collections/42');
      expect(jsonDecode(request.body), {'type': 2});
      return http.Response('', 204);
    });
    addTearDown(client.close);
    await BangumiApi(client: client).putCollection(
      'token',
      const AnimeCollection(
        bgmId: 42,
        status: 2,
        rating: 9,
        tags: ['原创'],
        isPrivate: true,
      ),
      statusOnly: true,
    );
  });

  test('old local collection tags migrate only at the storage boundary', () {
    final collection = AnimeCollection.fromJson({
      'status': 3,
      'tags': ' 原创,TV，原创  科幻 ',
    });
    expect(collection.tags, ['原创', 'TV', '科幻']);
    expect(
      collection.toJson(includeLocalFields: true)['tags'],
      collection.tags,
    );
  });

  test('pagination accepts Go nil slices and rejects malformed entries', () {
    final empty = parsePage({
      'list': null,
      'total': 0,
      'page': 1,
      'page_size': 20,
    }, AnimeCollection.fromJson);
    expect(empty.list, isEmpty);
    expect(
      () => parseList([42], AnimeCollection.fromJson),
      throwsA(isA<TypeError>()),
    );
  });

  late CollectionRepository repo;
  late BangumiSession bangumi;
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final session = AccountSession(prefs, refreshTokens: (_) async => null);
    bangumi = BangumiSession(
      prefs,
      session,
      CollectionsApi(),
      const BangumiOAuthBroker(),
    );
    repo = CollectionRepository(session, bangumi);
    addTearDown(bangumi.api.close);
  });

  test(
    'batch replaces matching identities and retains stats and order',
    () async {
      await repo.storeAll([
        const AnimeCollection(postId: 1, status: 1),
        const AnimeCollection(bgmId: 2, status: 3),
      ]);
      await repo.storeAll([
        const AnimeCollection(postId: 1, bgmId: 10, status: 2),
        const AnimeCollection(bgmId: 2, status: 2),
        const AnimeCollection(bgmId: 3, status: 1),
      ]);
      expect((await repo.getAll()).map((x) => x.bgmId), [10, 2, 3]);
      expect((await repo.getStats()).collect, 2);
      expect((await repo.getByPostId(1))?.bgmId, 10);
      final stored =
          jsonDecode(prefs.getString('local_anime_collections_v1')!) as List;
      expect(stored.length, 3);
    },
  );

  test(
    'same post with different Bangumi identities is not incorrectly merged',
    () async {
      await repo.storeAll([
        const AnimeCollection(postId: 1, bgmId: 2, status: 1),
        const AnimeCollection(postId: 1, bgmId: 3, status: 1),
      ]);
      expect((await repo.getAll()).length, 2);
      expect((await repo.getByBgmId(3))?.bgmId, 3);
    },
  );

  test(
    'sync imports the complete batch and publishes snapshots after storage',
    () async {
      await prefs.setString('bangumi_access_token', 'token');
      await prefs.setString(
        'bangumi_account',
        '{"username":"test","nickname":"Test"}',
      );
      final sync = BangumiSyncService(bangumi, repo);
      final first = sync.sync();
      expect(identical(first, sync.sync()), isTrue);
      expect((await first).imported, 100);
      expect((await repo.getAll(refreshBangumi: false)).length, 100);
      expect(
        (jsonDecode(prefs.getString(bangumi.snapshotKey)!) as Map).length,
        100,
      );
    },
  );
  test('local indexes and cached stats follow mutations', () async {
    await prefs.setString(
      'local_anime_collections_v1',
      jsonEncode([
        {'post_id': 11, 'bgm_id': 101, 'status': 1},
        {'post_id': 12, 'bgm_id': 102, 'status': 3},
      ]),
    );
    expect((await repo.getByBgmId(101))?.postId, 11);
    expect((await repo.getByPostId(12))?.bgmId, 102);
    var stats = await repo.getStats();
    expect(stats.wish, 1);
    expect(stats.doing, 1);

    await repo.addOrUpdate(
      const AnimeCollection(postId: 11, bgmId: 101, status: 2),
    );
    stats = await repo.getStats();
    expect(stats.wish, 0);
    expect(stats.collect, 1);
    expect((await repo.getByPostId(11))?.status, 2);

    expect(await repo.deleteByBgmId(102), isTrue);
    expect(await repo.getByBgmId(102), isNull);
    expect((await repo.getStats()).total, 1);
  });

  test('改追番状态保留已看集数', () async {
    await prefs.setString(
      'local_anime_collections_v1',
      jsonEncode([
        {
          'post_id': 11,
          'bgm_id': 101,
          'status': 3,
          'ep_watched': 8,
          'ep_total': 12,
        },
      ]),
    );
    final saved = await repo.addOrUpdate(
      const AnimeCollection(postId: 11, bgmId: 101, status: 2, epWatched: 1),
    );
    expect(saved.status, 2);
    expect(saved.epWatched, 8);
    expect(saved.epTotal, 12);
  });

  test('只改状态时保留打分、标签和私密', () async {
    await prefs.setString(
      'local_anime_collections_v1',
      jsonEncode([
        {
          'bgm_id': 101,
          'status': 3,
          'rating': 9,
          'tags': '原创,TV',
          'is_private': true,
          'comment': '好看',
        },
      ]),
    );
    final saved = await repo.addOrUpdate(
      const AnimeCollection(bgmId: 101, status: 2),
    );
    expect(saved.rating, 9);
    expect(saved.tags, ['原创', 'TV']);
    expect(saved.isPrivate, isTrue);
    expect(saved.comment, '好看');
    expect(saved.status, 2);
  });

  test('进列表一次算好已看集数，标记后只重算那一部', () async {
    final dir = Directory.systemTemp.createTempSync('anibaka_watched');
    Hive.init(dir.path);
    await Hive.openBox<Map>(AppStorage.videoProgressBoxName);
    await Hive.openBox<List>(AppStorage.playHistoryBoxName);
    addTearDown(() async {
      await Hive.close();
      dir.deleteSync(recursive: true);
    });
    final progress = AppStorage.videoProgressBox;
    // 番剧 1 有两条线路：第 1 集看完，第 2 集没看完，第 3 集手动取消，第 4 集手动标记。
    await progress.put('a_0_1', {'positionMs': 950, 'durationMs': 1000});
    await progress.put('a_1_1', {'positionMs': 100, 'durationMs': 1000});
    await progress.put('b_0_1', {'positionMs': 950, 'durationMs': 1000});
    await progress.put('b_2_1', {'positionMs': 990, 'durationMs': 1000});
    await progress.put('b_2_watched', {'watched': false});
    await progress.put('a_3_watched', {'watched': true});
    // 番剧 2 的记录自带 bgmId。
    await progress.put('c_0_1', {
      'positionMs': 990,
      'durationMs': 1000,
      'bgmId': 2,
    });
    await AppStorage.playHistoryBox.put('resume', [
      {'id': 'a', 'bgmId': 1},
      {'id': 'b', 'bgmId': 1},
    ]);

    HistoryRepository.prefetchWatchedCounts([1, 2]);
    expect(HistoryRepository.watchedCountForBgm(1), 2);
    expect(HistoryRepository.watchedCountForBgm(2), 1);

    // 标记第 2 集为看过：只有番剧 1 重算。
    await progress.put('a_1_watched', {'watched': true});
    HistoryRepository.invalidateWatchedCount(1);
    expect(HistoryRepository.watchedCountForBgm(1), 3);
    expect(HistoryRepository.watchedCountForBgm(2), 1);
  });

  test('Bangumi 上没有或连不上时，按本机记录显示追番', () async {
    await prefs.setString('bangumi_access_token', 'token');
    await prefs.setString(
      'bangumi_account',
      '{"username":"test","nickname":"Test"}',
    );
    await prefs.setString(
      'local_anime_collections_v1',
      jsonEncode([
        {'bgm_id': 501, 'status': 3},
      ]),
    );
    for (final unreachable in [false, true]) {
      final session = AccountSession(prefs, refreshTokens: (_) async => null);
      final bgm = BangumiSession(
        prefs,
        session,
        _MissingApi(unreachable: unreachable),
        const BangumiOAuthBroker(),
      );
      final local = CollectionRepository(session, bgm);
      final shown = await local.getByBgmId(501);
      expect(
        shown?.status,
        3,
        reason: unreachable ? '连不上 Bangumi' : 'Bangumi 上没有这一条',
      );
    }
  });

  test('Bangumi 上删掉的收藏不会在本机复活', () async {
    await prefs.setString('bangumi_access_token', 'token');
    await prefs.setString(
      'bangumi_account',
      '{"username":"test","nickname":"Test"}',
    );
    await prefs.setString(
      'local_anime_collections_v1',
      jsonEncode([
        {'bgm_id': 501, 'status': 3, 'bgm_synced': true},
        // 本机草稿：从没传上去过，远端没有也要留着。
        {'bgm_id': 502, 'status': 3},
      ]),
    );
    final session = AccountSession(prefs, refreshTokens: (_) async => null);
    final local = CollectionRepository(
      session,
      BangumiSession(
        prefs,
        session,
        _EmptyCollectionsApi(),
        const BangumiOAuthBroker(),
      ),
    );
    await local.refreshFromBangumi();
    final list = await local.getList();
    expect(list.total, 1);
    expect(list.list.single.bgmId, 502);
    expect(await local.getByBgmId(501), isNull);
    expect((await local.getByBgmId(502))?.status, 3);
  });

  test('本机已有收藏时，统计和列表不等 Bangumi', () async {
    await prefs.setString('bangumi_access_token', 'token');
    await prefs.setString(
      'bangumi_account',
      '{"username":"test","nickname":"Test"}',
    );
    await prefs.setString(
      'local_anime_collections_v1',
      jsonEncode([
        {'bgm_id': 501, 'status': 3},
      ]),
    );
    final session = AccountSession(prefs, refreshTokens: (_) async => null);
    final local = CollectionRepository(
      session,
      BangumiSession(prefs, session, _HangingApi(), const BangumiOAuthBroker()),
    );
    final stats = await local.getStats().timeout(const Duration(seconds: 2));
    expect(stats.doing, 1);
    final page = await local.getList().timeout(const Duration(seconds: 2));
    expect(page.total, 1);
  });

  test('传上去之前就算待补传，后台刷新盖不掉', () async {
    await prefs.setString('bangumi_access_token', 'token');
    await prefs.setString(
      'bangumi_account',
      '{"username":"test","nickname":"Test"}',
    );
    final api = _FlakyApi();
    final session = AccountSession(prefs, refreshTokens: (_) async => null);
    final local = CollectionRepository(
      session,
      BangumiSession(prefs, session, api, const BangumiOAuthBroker()),
    );

    await local.addOrUpdate(
      const AnimeCollection(bgmId: 501, status: 3, epWatched: 8),
    );
    expect(local.hasPendingSync(501), isTrue, reason: '不等任何网络结果');

    await local.getList();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect((await local.getByBgmId(501))?.status, 3);
  });

  test('补传：网络断了先停，Bangumi 拒收的那条不堵住后面的', () async {
    await prefs.setString('bangumi_access_token', 'token');
    await prefs.setString(
      'bangumi_account',
      '{"username":"test","nickname":"Test"}',
    );
    final api = _FlakyApi();
    final session = AccountSession(prefs, refreshTokens: (_) async => null);
    final local = CollectionRepository(
      session,
      BangumiSession(prefs, session, api, const BangumiOAuthBroker()),
    );
    await local.addOrUpdate(const AnimeCollection(bgmId: 501, status: 3));
    await local.addOrUpdate(const AnimeCollection(bgmId: 502, status: 2));

    await local.syncPending();
    expect(api.pushed, isEmpty, reason: '断网时一条都不该划掉');
    expect(local.hasPendingSync(501), isTrue);
    expect(local.hasPendingSync(502), isTrue);

    api.offline = false;
    api.rejected.add(501);
    await local.syncPending();
    expect(api.pushed, [502]);
    expect(local.hasPendingSync(501), isFalse, reason: '拒收的划掉');
    expect(local.hasPendingSync(502), isFalse);
  });

  test('换 Bangumi 账号不覆盖上一个账号的待补传', () async {
    await prefs.setString('bangumi_access_token', 'token');
    final api = _FlakyApi();
    CollectionRepository forAccount(String name) {
      prefs.setString(
        'bangumi_account',
        jsonEncode({'username': name, 'nickname': name}),
      );
      final session = AccountSession(prefs, refreshTokens: (_) async => null);
      return CollectionRepository(
        session,
        BangumiSession(prefs, session, api, const BangumiOAuthBroker()),
      );
    }

    await forAccount('alice').addOrUpdate(
      const AnimeCollection(bgmId: 501, status: 3),
    );
    await forAccount('bob').addOrUpdate(
      const AnimeCollection(bgmId: 601, status: 2),
    );
    final back = forAccount('alice');
    expect(back.hasPendingSync(501), isTrue);
    expect(back.hasPendingSync(601), isFalse);
  });

  test('旧版本存的待补传清单按账号搬过来', () async {
    await prefs.setString('bangumi_access_token', 'token');
    await prefs.setString(
      'bangumi_pending_collection_sync_v1',
      jsonEncode({'owner': 'test', 'ids': [5]}),
    );
    await prefs.setString(
      'bangumi_account',
      '{"username":"test","nickname":"Test"}',
    );
    final session = AccountSession(prefs, refreshTokens: (_) async => null);
    final local = CollectionRepository(
      session,
      BangumiSession(prefs, session, _FlakyApi(), const BangumiOAuthBroker()),
    );
    expect(local.hasPendingSync(5), isTrue);
  });

  test('后台刷新不覆盖还没同步到 Bangumi 的状态', () async {
    await prefs.setString('bangumi_access_token', 'token');
    await prefs.setString(
      'bangumi_account',
      '{"username":"test","nickname":"Test"}',
    );
    final api = _OfflinePutApi(
      const AnimeCollection(bgmId: 501, status: 1, epWatched: 2),
    );
    final session = AccountSession(prefs, refreshTokens: (_) async => null);
    final bgm = BangumiSession(
      prefs,
      session,
      api,
      const BangumiOAuthBroker(),
    );
    final repo = CollectionRepository(session, bgm);

    await repo.addOrUpdate(
      const AnimeCollection(bgmId: 501, status: 3, epWatched: 8),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.puts, 1, reason: '镜像应该已经尝试过一次');

    await repo.getList();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final local = await repo.getByBgmId(501);
    expect(local?.status, 3);
    expect(local?.epWatched, 8);
  });

  test('刷新在途时改的状态，不会被这次刷新的旧数据盖掉', () async {
    await prefs.setString('bangumi_access_token', 'token');
    await prefs.setString(
      'bangumi_account',
      '{"username":"test","nickname":"Test"}',
    );
    await prefs.setString(
      'local_anime_collections_v1',
      jsonEncode([
        {'bgm_id': 501, 'status': 1, 'bgm_synced': true},
      ]),
    );
    final api = _SlowCollectionsApi();
    final session = AccountSession(prefs, refreshTokens: (_) async => null);
    final bgm = BangumiSession(
      prefs,
      session,
      api,
      const BangumiOAuthBroker(),
    );
    final repo = CollectionRepository(session, bgm);

    // 刷新先发出，远端数据还没回来。
    final refresh = repo.refreshFromBangumi();
    await api.requested.future;

    // 这期间用户把状态改成「在看」，镜像成功、待补传被划掉。
    await repo.addOrUpdate(
      const AnimeCollection(bgmId: 501, status: 3),
      statusOnly: true,
    );
    for (var i = 0; i < 100 && repo.hasPendingSync(501); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(repo.hasPendingSync(501), isFalse);

    // 刷新这时才带着旧状态返回。
    api.response.complete([const AnimeCollection(bgmId: 501, status: 1)]);
    await refresh;

    final list = await repo.getAll(refreshBangumi: false);
    expect(list.single.status, 3);
  });

  test('后台刷新改变统计时通知页面', () async {
    await prefs.setString('bangumi_access_token', 'token');
    await prefs.setString(
      'bangumi_account',
      '{"username":"test","nickname":"Test"}',
    );
    final api = _OfflinePutApi(const AnimeCollection(bgmId: 601, status: 1));
    final session = AccountSession(prefs, refreshTokens: (_) async => null);
    final bgm = BangumiSession(
      prefs,
      session,
      api,
      const BangumiOAuthBroker(),
    );
    final repo = CollectionRepository(session, bgm);
    var notified = 0;
    repo.revision.addListener(() => notified++);

    final stats = await repo.getStats();
    expect(stats.wish, 1);
    expect(notified, greaterThan(0));
  });

  group('library navigation', () {
    setUp(() {
      Instances.sp = prefs;
      collections = repo;
      historyRepository = HistoryRepository(repo.session, bangumi);
    });

    testWidgets('云端读不到时用本地快照并提示离线', (tester) async {
      addTearDown(() async {
        await prefs.remove('usertoken');
        await prefs.remove('anibaka_collections_cache_v1');
      });
      await prefs.setString('usertoken', 'test-token');
      final session = AccountSession(prefs, refreshTokens: (_) async => null);
      collections = CollectionRepository(session, bangumi);
      historyRepository = HistoryRepository(session, bangumi);
      var fail = false;
      apiTransport = ApiTransport(
        session: session,
        version: 'test',
        credentialOrigin: () => Uri.parse('https://www.anibaka.com'),
        client: MockClient((request) async {
          if (fail) throw TimeoutException('GET ${request.url}');
          final data = switch (request.url.path) {
            '/api/v1/collection' => {
              'list': [
                {'bgm_id': 42, 'bgm_title': 'Cached show', 'status': 3},
              ],
              'total': 1,
              'page': 1,
              'page_size': 20,
            },
            '/api/v1/collection/stats' => {
              'total': 1,
              'do': 1,
              'wish': 0,
              'collect': 0,
              'on_hold': 0,
              'dropped': 0,
            },
            '/api/v1/play-history' => {'list': []},
            _ => throw StateError('Unexpected request: ${request.url}'),
          };
          return http.Response(jsonEncode({'code': 200, 'data': data}), 200);
        }),
      );
      addTearDown(apiTransport.close);

      await tester.pumpWidget(
        const MaterialApp(home: LibraryPage(initialIndex: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Cached show'), findsOneWidget);
      expect(find.textContaining('本地缓存'), findsNothing);

      // 换一台没有内存缓存的仓库，等于重启后服务器已经挂掉。
      fail = true;
      collections = CollectionRepository(session, bangumi);
      historyRepository = HistoryRepository(session, bangumi);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        const MaterialApp(home: LibraryPage(initialIndex: 1)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Cached show'), findsOneWidget);
      expect(find.textContaining('本地缓存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('服务器挂了且没有快照时，改用 Bangumi 直连', (tester) async {
      addTearDown(() async {
        await prefs.remove('usertoken');
        await prefs.remove('bangumi_access_token');
        await prefs.remove('bangumi_account');
        await prefs.remove('anibaka_collections_cache_v1');
      });
      await prefs.setString('usertoken', 'test-token');
      await prefs.setString('bangumi_access_token', 'bgm-token');
      await prefs.setString(
        'bangumi_account',
        '{"username":"test","nickname":"Test"}',
      );
      final session = AccountSession(prefs, refreshTokens: (_) async => null);
      final bgm = BangumiSession(
        prefs,
        session,
        _StaticCollectionsApi([
          const AnimeCollection(
            bgmId: 99,
            status: 3,
            bgmTitle: 'Bangumi show',
            postTitle: 'Bangumi show',
          ),
        ]),
        const BangumiOAuthBroker(),
      );
      collections = CollectionRepository(session, bgm);
      historyRepository = HistoryRepository(session, bgm);
      apiTransport = ApiTransport(
        session: session,
        version: 'test',
        credentialOrigin: () => Uri.parse('https://www.anibaka.com'),
        client: MockClient(
          (request) async => throw TimeoutException('GET ${request.url}'),
        ),
      );
      addTearDown(apiTransport.close);

      await tester.pumpWidget(
        const MaterialApp(home: LibraryPage(initialIndex: 1)),
      );
      await tester.pumpAndSettle();

      // 第二级兜底生效：有内容，且不标「本地缓存」（数据是实时的）。
      expect(find.text('Bangumi show'), findsOneWidget);
      expect(find.textContaining('本地缓存'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    test('服务器失败后冷却期内不再重复请求', () async {
      addTearDown(() async {
        await prefs.remove('usertoken');
        await prefs.remove('anibaka_collections_cache_v1');
      });
      await prefs.setString('usertoken', 'test-token');
      final session = AccountSession(prefs, refreshTokens: (_) async => null);
      var fail = false;
      var calls = 0;
      apiTransport = ApiTransport(
        session: session,
        version: 'test',
        credentialOrigin: () => Uri.parse('https://www.anibaka.com'),
        client: MockClient((request) async {
          calls++;
          if (fail) throw TimeoutException('GET ${request.url}');
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'list': [
                  {'bgm_id': 42, 'bgm_title': 'Cached show', 'status': 3},
                ],
                'total': 1,
                'page': 1,
                'page_size': 50,
              },
            }),
            200,
          );
        }),
      );
      addTearDown(apiTransport.close);

      final cloud = CollectionRepository(session, bangumi);
      await cloud.getAll();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1);

      fail = true;
      final first = await cloud.getAll();
      expect(first.single.bgmId, 42);
      final afterFirst = calls;

      final second = await cloud.getAll();
      expect(calls, afterFirst, reason: '冷却期内不该再请求服务器');
      expect(second.single.bgmId, 42);
    });

    test('云端单条读不到时用快照里的追番状态', () async {
      addTearDown(() async {
        await prefs.remove('usertoken');
        await prefs.remove('anibaka_collections_cache_v1');
      });
      await prefs.setString('usertoken', 'test-token');
      final session = AccountSession(prefs, refreshTokens: (_) async => null);
      var fail = false;
      apiTransport = ApiTransport(
        session: session,
        version: 'test',
        credentialOrigin: () => Uri.parse('https://www.anibaka.com'),
        client: MockClient((request) async {
          if (fail) throw TimeoutException('GET ${request.url}');
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'list': [
                  {'bgm_id': 42, 'bgm_title': 'Cached show', 'status': 3},
                ],
                'total': 1,
                'page': 1,
                'page_size': 50,
              },
            }),
            200,
          );
        }),
      );
      addTearDown(apiTransport.close);

      final cloud = CollectionRepository(session, bangumi);
      await cloud.getAll();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      fail = true;
      final item = await cloud.getByBgmId(42);
      expect(item?.bgmId, 42);
      expect(item?.status, 3);
    });

    for (final failedResource in ['stats', 'list']) {
      testWidgets('initial $failedResource timeout is handled and retryable', (
        tester,
      ) async {
        await prefs.setString('usertoken', 'test-token');
        final session = AccountSession(prefs, refreshTokens: (_) async => null);
        collections = CollectionRepository(session, bangumi);
        historyRepository = HistoryRepository(session, bangumi);
        var fail = true;
        apiTransport = ApiTransport(
          session: session,
          version: 'test',
          credentialOrigin: () => Uri.parse('https://www.anibaka.com'),
          client: MockClient((request) async {
            final path = request.url.path;
            if (fail &&
                path ==
                    (failedResource == 'stats'
                        ? '/api/v1/collection/stats'
                        : '/api/v1/collection')) {
              throw TimeoutException('GET ${request.url}');
            }
            final data = switch (path) {
              '/api/v1/collection/stats' => {
                'total': 1,
                'do': 1,
                'wish': 0,
                'collect': 0,
                'on_hold': 0,
                'dropped': 0,
              },
              '/api/v1/collection' => {
                'list': [
                  {'bgm_id': 42, 'bgm_title': 'Available show', 'status': 3},
                ],
                'total': 1,
                'page': 1,
                'page_size': 20,
              },
              '/api/v1/play-history' => {'list': []},
              _ => throw StateError('Unexpected request: ${request.url}'),
            };
            return http.Response(jsonEncode({'code': 200, 'data': data}), 200);
          }),
        );
        addTearDown(apiTransport.close);

        await tester.pumpWidget(
          const MaterialApp(home: LibraryPage(initialIndex: 1)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (failedResource == 'stats') {
          expect(find.text('Available show'), findsOneWidget);
        } else {
          expect(find.widgetWithText(ChoiceChip, '在看 1'), findsOneWidget);
        }

        fail = false;
        await tester.tap(find.byIcon(Icons.refresh_rounded));
        await tester.pumpAndSettle();
        expect(find.text('Available show'), findsOneWidget);
        expect(find.widgetWithText(ChoiceChip, '在看 1'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    for (final entry in ['initial load', 'refresh', 'status filter']) {
      testWidgets('cloud collections paginate after $entry', (tester) async {
        await prefs.setString('usertoken', 'test-token');
        final session = AccountSession(prefs, refreshTokens: (_) async => null);
        collections = CollectionRepository(session, bangumi);
        historyRepository = HistoryRepository(session, bangumi);
        final requests = <(int?, int)>[];
        final items = [
          for (var id = 1; id <= 45; id++)
            {'bgm_id': id, 'bgm_title': 'Show $id', 'status': id <= 25 ? 3 : 1},
        ];
        apiTransport = ApiTransport(
          session: session,
          version: 'test',
          credentialOrigin: () => Uri.parse('https://www.anibaka.com'),
          client: MockClient((request) async {
            final Map<String, dynamic> data;
            switch (request.url.path) {
              case '/api/v1/collection':
                final query = request.url.queryParameters;
                final page = int.parse(query['page']!);
                final pageSize = int.parse(query['page_size']!);
                final status = int.tryParse(query['status'] ?? '');
                requests.add((status, page));
                final filtered = items
                    .where((item) => status == null || item['status'] == status)
                    .toList();
                data = {
                  'list': filtered
                      .skip((page - 1) * pageSize)
                      .take(pageSize)
                      .toList(),
                  'total': filtered.length,
                  'page': page,
                  'page_size': pageSize,
                };
              case '/api/v1/collection/stats':
                data = {
                  'total': 45,
                  'do': 25,
                  'wish': 20,
                  'collect': 0,
                  'on_hold': 0,
                  'dropped': 0,
                };
              case '/api/v1/play-history':
                data = {'list': []};
              default:
                throw StateError('Unexpected request: ${request.url}');
            }
            return http.Response(jsonEncode({'code': 200, 'data': data}), 200);
          }),
        );
        addTearDown(apiTransport.close);

        await tester.pumpWidget(
          const MaterialApp(home: LibraryPage(initialIndex: 1)),
        );
        await tester.pumpAndSettle();
        if (entry == 'refresh') {
          await tester.tap(find.byIcon(Icons.refresh_rounded));
          await tester.pumpAndSettle();
        } else if (entry == 'status filter') {
          await tester.tap(find.widgetWithText(ChoiceChip, '在看 25'));
          await tester.pumpAndSettle();
        }

        int itemCount() => tester
            .widget<SliverMasonryGrid>(find.byType(SliverMasonryGrid))
            .delegate
            .estimatedChildCount!;

        final status = entry == 'status filter' ? 3 : null;
        expect(itemCount(), 20);
        expect(requests.last, (status, 1));
        requests.clear();
        final scroll = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!;
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(itemCount(), status == null ? 40 : 25);
        expect(requests, [(status, 2)]);

        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(itemCount(), status == null ? 45 : 25);
        final expectedRequests = [(status, 2), if (status == null) (status, 3)];
        expect(requests, expectedRequests);

        // The final entry is reachable, and reaching the end stops pagination.
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(
          find.text(status == null ? 'Show 45' : 'Show 25'),
          findsOneWidget,
        );
        expect(requests, expectedRequests);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('collections with shared or missing ids allow push and pop', (
      tester,
    ) async {
      await prefs.setString(
        'local_anime_collections_v1',
        jsonEncode([
          {'post_id': 0, 'bgm_id': 101, 'status': 3},
          {'post_id': 0, 'bgm_id': 102, 'status': 3},
          {'post_id': 7, 'bgm_id': 103, 'status': 3},
          {'post_id': 7, 'bgm_id': 104, 'status': 3},
          {'bgm_id': 7, 'status': 3},
          {'status': 3},
        ]),
      );
      await tester.pumpWidget(
        const MaterialApp(home: LibraryPage(initialIndex: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Hero), findsNWidgets(6));
      final tags = tester
          .widgetList<Hero>(find.byType(Hero))
          .map((h) => h.tag)
          .toList();

      await _navigateAwayAndBack(tester);
      expect(
        tester.widgetList<Hero>(find.byType(Hero)).map((h) => h.tag),
        tags,
      );
    });

    testWidgets('loading placeholders allow push and pop before data arrives', (
      tester,
    ) async {
      final loading = _LoadingCollections(repo.session, bangumi);
      collections = loading;
      await tester.pumpWidget(
        const MaterialApp(home: LibraryPage(initialIndex: 1)),
      );
      expect(find.byType(Hero).evaluate().length, greaterThan(1));

      await _navigateAwayAndBack(tester);
      loading.response.complete((
        list: <AnimeCollection>[],
        total: 0,
        page: 1,
        pageSize: 20,
      ));
      await tester.pumpAndSettle();
      expect(find.text('暂无追番记录'), findsOneWidget);
    });

    testWidgets('coexisting library pages have independent cover heroes', (
      tester,
    ) async {
      await repo.storeAll([const AnimeCollection(postId: 1, status: 3)]);
      await tester.pumpWidget(
        const MaterialApp(
          home: IndexedStack(
            children: [
              LibraryPage(initialIndex: 1),
              LibraryPage(initialIndex: 1),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Hero, skipOffstage: false), findsNWidgets(2));

      await _navigateAwayAndBack(tester);
    });
  });
}
