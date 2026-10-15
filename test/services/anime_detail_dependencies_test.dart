import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baka/api/bangumi_account_api.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/playback/playback_content.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory storage;
  late AccountSession session;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) respond;

  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp('baka-detail-dependencies-');
    Hive.init(storage.path);
    await AppStorage.init(
      hiveDirectory: storage,
      boxes: {AppStorage.bgmCacheBoxName},
    );
  });

  tearDownAll(() async {
    await Hive.close();
    await storage.delete(recursive: true);
  });

  setUp(() async {
    await AppStorage.bgmCacheBox.clear();
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    session = AccountSession(Instances.sp, refreshTokens: (_) async => null);
    requests = [];
    respond = (request) async =>
        throw StateError('Unexpected request: ${request.method} ${request.url}');
    apiTransport = ApiTransport(
      session: session,
      client: MockClient((request) {
        requests.add(request);
        return respond(request);
      }),
      version: 'test',
      credentialOrigin: () => Uri.parse('https://www.anibaka.com'),
    );
    addTearDown(apiTransport.close);
    addTearDown(session.close);
  });

  test('known Bangumi identity needs no title search or metadata request', () async {
    final data = Map<String, dynamic>.unmodifiable({
      'bgmId': 991201,
      'title': 'Already identified',
      'score': 8.5,
      'bgmImageUrl': 'https://fixture.test/known.jpg',
    });
    final info = await resolveBgmFromData(data);
    expect(info.subjectId, 991201);
    expect(info.score, 8.5);
    expect(info.imageUrl, 'https://fixture.test/known.jpg');
    expect(requests, isEmpty);
    expect(AppStorage.bgmCacheBox.isEmpty, isTrue);
  });

  test('collection post IDs belong only to internal sources', () {
    expect(AnimeCollection.postIdFrom(const {'id': 54}), 54);
    expect(AnimeCollection.postIdFrom(const {'id': 54, 'source': ''}), 54);
    expect(
      AnimeCollection.postIdFrom(const {'id': 54, 'source': 'internal'}),
      54,
    );
    for (final source in ['bgm', 'history', 'akianime', 'custom_fixture', '_local']) {
      expect(AnimeCollection.postIdFrom({'id': 54, 'source': source}), isNull);
      expect(
        AnimeCollection.postIdFrom(const {'id': 54}, source: source),
        isNull,
      );
    }
    expect(
      AnimeCollection.postIdFrom(
        const {'id': 54, 'source': 'internal'},
        source: 'akianime',
      ),
      isNull,
    );
    expect(
      AnimeCollection.postIdFrom(
        const {'id': 54, 'source': 'bgm'},
        source: 'internal',
      ),
      54,
    );
    expect(AnimeCollection.postIdFrom(const {'id': 0}), isNull);
  });

  test('title resolution rejects candidates from the wrong season', () async {
    respond = (request) async {
      expect(request.url.path, '/v0/search/subjects');
      return _json({
        'data': [
          {
            'id': 991205,
            'name': 'Season Conflict Fixture Season 1',
            'name_cn': '',
            'summary': '',
            'images': {'large': 'https://fixture.test/season-one.jpg'},
            'rating': {'score': 8.0},
          },
        ],
      });
    };
    expect(
      await resolveBgmSubject(title: 'Season Conflict Fixture Season 2'),
      isNull,
    );
    expect(requests, isNotEmpty);
  });

  test('title resolution writes and reuses the persistent score cache', () async {
    const title = 'Durable Cache Fixture';
    respond = (request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/v0/search/subjects');
      return _json({
        'data': [
          {
            'id': 991202,
            'name': title,
            'name_cn': '',
            'summary': '',
            'images': {'large': 'https://fixture.test/resolved.jpg'},
            'rating': {'score': 8.25},
          },
        ],
      });
    };
    final info = await resolveBgmFromData(const {'title': title});
    expect(info.subjectId, 991202);
    expect(info.score, 8.25);
    expect(requests, isNotEmpty);
    final count = requests.length;

    final box = AppStorage.bgmCacheBox;
    expect(box.length, 1);
    final key = box.keys.single;
    final stored = box.get(key)!;
    expect(stored['data'], {
      'subjectId': 991202,
      'score': 8.25,
      'imageUrl': 'https://fixture.test/resolved.jpg',
    });
    // Distinguish a persistent-cache hit from a hit in the raw search cache.
    await box.put(key, {
      'timestamp': stored['timestamp'],
      'data': {
        'subjectId': 991202,
        'score': 9.25,
        'imageUrl': 'https://fixture.test/cached.jpg',
      },
    });
    await box.flush();
    final cached = await resolveBgmFromData(const {'title': title});
    expect(cached.subjectId, 991202);
    expect(cached.score, 9.25);
    expect(cached.imageUrl, 'https://fixture.test/cached.jpg');
    expect(requests.length, count);
  });

  test('Bangumi collection lookups share pending work without blocking local reads', () async {
    await Instances.sp.setString('bangumi_access_token', 'fixture-token');
    final started = Completer<void>();
    final remote = Completer<http.Response>();
    var remoteCalls = 0;
    final api = BangumiApi(
      client: MockClient((request) {
        expect(request.url.path, '/v0/users/-/collections/991203');
        remoteCalls++;
        if (!started.isCompleted) started.complete();
        return remote.future;
      }),
    );
    addTearDown(api.close);
    final bangumi = BangumiSession(
      Instances.sp,
      session,
      api,
      const BangumiOAuthBroker(),
    );
    final repository = CollectionRepository(session, bangumi);
    const local = AnimeCollection(
      postId: 53,
      bgmId: 991203,
      status: 1,
      postTitle: 'Local title',
    );
    await repository.storeAll([local]);

    final first = repository.getByBgmId(991203);
    final second = repository.getByBgmId(991203);
    await started.future;
    expect(
      await repository.getByBgmId(991203, refreshBangumi: false),
      same(local),
    );
    expect(remote.isCompleted, isFalse);
    expect(remoteCalls, 1);

    remote.complete(_json({
      'subject_id': 991203,
      'type': 3,
      'rate': 0,
      'ep_status': 2,
      'tags': <String>[],
      'private': false,
      'subject': {'name': 'Remote title', 'name_cn': '', 'eps': 12},
    }));
    final results = await Future.wait([first, second]);
    expect(results.first, same(results.last));
    expect(results.first!.postId, 53);
    expect(results.first!.status, 3);
    expect(
      await repository.getByBgmId(991203, refreshBangumi: false),
      same(results.first),
    );
    await repository.getByBgmId(991203);
    expect(remoteCalls, 2, reason: 'Completed remote state must be refreshed');
  });

  test('follow reads current collection state without loading anime metadata', () async {
    session.token = 'cloud-fixture-token';
    var status = 1;
    respond = (request) async {
      if (request.method == 'GET' &&
          request.url.path == '/api/v1/bgm-collection/991204') {
        return _json({
          'code': 0,
          'data': {'post_id': 54, 'bgm_id': 991204, 'status': status},
        });
      }
      if (request.method == 'POST' &&
          request.url.path == '/api/v1/collection') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['bgm_id'], 991204);
        expect(body['post_id'], 54);
        expect(body['status'], 3);
        status = body['status'] as int;
        return _json({'code': 0, 'data': body});
      }
      if (request.method == 'DELETE' &&
          request.url.path == '/api/v1/bgm-collection/991204') {
        status = 0;
        return _json({'code': 0, 'data': null});
      }
      throw StateError('Unexpected dependency: ${request.method} ${request.url}');
    };
    final bangumiApi = BangumiApi(client: MockClient((request) async {
      throw StateError('Bangumi account is disconnected: ${request.url}');
    }));
    addTearDown(bangumiApi.close);
    final bangumi = BangumiSession(
      Instances.sp,
      session,
      bangumiApi,
      const BangumiOAuthBroker(),
    );
    final catalog = SourceCatalog(Instances.sp);
    final sources = SourceAdapterService(catalog);
    addTearDown(catalog.dispose);
    addTearDown(sources.dispose);
    final content = PlaybackContent(
      request: PlaybackRequest(
        source: 'internal',
        metadata: const {'id': 54, 'bgmId': 991204, 'title': 'Follow fixture'},
      ),
      sources: sources,
      collections: CollectionRepository(session, bangumi),
      history: HistoryRepository(session, bangumi),
    );
    addTearDown(content.dispose);

    await content.toggleFollow();
    expect(status, 3);
    status = 1; // Another client changed the server state after the first write.
    await content.toggleFollow();
    expect(status, 3);
    await content.toggleFollow();
    expect(status, 0);
    expect(requests.map((request) => request.method), [
      'GET', 'POST', 'GET', 'POST', 'GET', 'DELETE',
    ]);
    expect(content.isFollow(), isFalse);
  });
}

http.Response _json(Map<String, dynamic> data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json'},
);
