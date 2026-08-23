import 'dart:convert';

import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/services/collection_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      'local_anime_collections_v1': jsonEncode([
        {'post_id': 11, 'bgm_id': 101, 'status': 1},
        {'post_id': 12, 'bgm_id': 102, 'status': 3},
      ]),
    });
    Instances.sp = await SharedPreferences.getInstance();
  });

  test('local indexes and cached stats follow mutations', () async {
    expect((await CollectionService.getByBgmId(101))?.postId, 11);
    expect((await CollectionService.getByPostId(12))?.bgmId, 102);
    var stats = await CollectionService.getStats();
    expect(stats?.wish, 1);
    expect(stats?.doing, 1);

    await CollectionService.addOrUpdate(
      AnimeCollection(postId: 11, bgmId: 101, status: 2),
    );
    stats = await CollectionService.getStats();
    expect(stats?.wish, 0);
    expect(stats?.collect, 1);
    expect((await CollectionService.getByPostId(11))?.status, 2);

    expect(await CollectionService.deleteByBgmId(102), isTrue);
    expect(await CollectionService.getByBgmId(102), isNull);
    expect((await CollectionService.getStats())?.total, 1);
  });
}
