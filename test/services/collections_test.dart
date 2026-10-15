import 'dart:async';
import 'dart:convert';
import 'package:baka/api/bangumi_account_api.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
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
        (jsonDecode(prefs.getString('bangumi_local_sync_snapshot')!) as Map)
            .length,
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

  group('library navigation', () {
    setUp(() {
      Instances.sp = prefs;
      collections = repo;
      historyRepository = HistoryRepository(repo.session, bangumi);
    });

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
