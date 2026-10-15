import 'package:baka/api/bangumi_account_api.dart';
import 'dart:convert';

import 'package:baka/api/anibaka_api.dart';
import 'package:baka/api/request_cache.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/page.dart';

/// 登录 AniBaka 时使用云端收藏；未登录时使用设备本地收藏。
late CollectionRepository collections;

class CollectionRepository {
  CollectionRepository(this.session, this.bangumi);
  final AccountSession session;
  final BangumiSession bangumi;

  static const _localKey = 'local_anime_collections_v1';
  final _bangumiCollectionRequests =
      RequestCache<(int, int), List<AnimeCollection>>(limit: 0);
  final _listRequests =
      RequestCache<
        ({
          int account,
          int bangumi,
          int page,
          int pageSize,
          int? status,
          int? bgmId,
        }),
        PageData<AnimeCollection>
      >(limit: 0);
  final _statsRequests =
      RequestCache<(int account, int bangumi), CollectionStats>(limit: 0);
  final _byBgmIdRequests =
      RequestCache<(int account, int bangumi, int bgmId), AnimeCollection?>(
        limit: 0,
      );
  final _byPostIdRequests =
      RequestCache<(int account, int bangumi, int postId), AnimeCollection?>(
        limit: 0,
      );
  List<AnimeCollection>? _localCache;
  Map<int, int> _localByBgmId = const {};
  Map<int, int> _localByPostId = const {};
  CollectionStats _localStats = const CollectionStats();

  bool get isLocalMode => session.token.isEmpty;
  bool get isBangumiMode => isLocalMode && bangumi.isConnected;

  Future<AnimeCollection> addOrUpdate(AnimeCollection collection) async {
    if (!isLocalMode) {
      final saved = await AniBakaApi.saveCollection(collection);
      if (bangumi.isConnected) {
        await bangumi.updateCollection(saved);
      }
      return saved;
    }
    if (isBangumiMode) {
      await bangumi.updateCollection(collection);
    }
    await storeAll([collection]);
    return collection;
  }

  Future<PageData<AnimeCollection>> getList({
    int page = 1,
    int pageSize = 20,
    int? status,
    int? bgmId,
  }) => _listRequests.get(
    (
      account: session.generation,
      bangumi: bangumi.generation,
      page: page,
      pageSize: pageSize,
      status: status,
      bgmId: bgmId,
    ),
    () =>
        _getList(page: page, pageSize: pageSize, status: status, bgmId: bgmId),
  );

  Future<PageData<AnimeCollection>> _getList({
    required int page,
    required int pageSize,
    required int? status,
    required int? bgmId,
  }) async {
    if (!isLocalMode) {
      return AniBakaApi.getCollections(
        page: page,
        pageSize: pageSize,
        status: status,
        bgmId: bgmId,
      );
    }
    if (isBangumiMode) await _refreshBangumiCollections();
    final safePage = page < 1 ? 1 : page;
    final safePageSize = pageSize < 1 ? 20 : pageSize;
    final start = (safePage - 1) * safePageSize;
    var total = 0;
    final list = <AnimeCollection>[];
    for (final item in _readLocal()) {
      if (status != null && item.status != status) continue;
      if (bgmId != null && item.bgmId != bgmId) continue;
      if (total >= start && list.length < safePageSize) list.add(item);
      total++;
    }
    return (list: list, total: total, page: safePage, pageSize: safePageSize);
  }

  Future<List<AnimeCollection>> getAll({bool refreshBangumi = true}) async {
    if (isLocalMode) {
      if (refreshBangumi && isBangumiMode) {
        await _refreshBangumiCollections();
      }
      return _readLocal();
    }
    const pageSize = 50;
    var page = 1;
    var total = 1;
    final result = <AnimeCollection>[];
    while (result.length < total) {
      final response = await AniBakaApi.getCollections(
        page: page,
        pageSize: pageSize,
      );
      total = response.total;
      result.addAll(response.list);
      if (response.list.isEmpty) break;
      page++;
    }
    return result;
  }

  Future<CollectionStats> getStats() async {
    if (!isLocalMode) {
      return _statsRequests.get((
        session.generation,
        bangumi.generation,
      ), AniBakaApi.getCollectionStats);
    }
    if (isBangumiMode) await _refreshBangumiCollections();
    _readLocal();
    return _localStats;
  }

  Future<AnimeCollection?> getByPostId(int postId) {
    if (!isLocalMode) {
      return _byPostIdRequests.get((
        session.generation,
        bangumi.generation,
        postId,
      ), () => AniBakaApi.getCollectionByPostId(postId));
    }
    _readLocal();
    final index = _localByPostId[postId];
    return Future.value(index == null ? null : _localCache![index]);
  }

  Future<AnimeCollection?> getByBgmId(int bgmId, {bool refreshBangumi = true}) {
    if (!isLocalMode || (isBangumiMode && refreshBangumi)) {
      return _byBgmIdRequests.get(
        (session.generation, bangumi.generation, bgmId),
        () => isLocalMode
            ? _getLocalByBgmId(bgmId, refreshBangumi: true)
            : AniBakaApi.getCollectionByBgmId(bgmId),
      );
    }
    return _getLocalByBgmId(bgmId, refreshBangumi: refreshBangumi);
  }

  Future<AnimeCollection?> _getLocalByBgmId(
    int bgmId, {
    required bool refreshBangumi,
  }) async {
    if (refreshBangumi && isBangumiMode) {
      final remote = await bangumi.getCollection(bgmId);
      if (remote == null) return null;
      _readLocal();
      final index = _localByBgmId[bgmId];
      final local = index == null ? null : _localCache![index];
      final merged = _mergeRemote(remote, local);
      await storeAll([merged]);
      return merged;
    }
    _readLocal();
    final index = _localByBgmId[bgmId];
    return index == null ? null : _localCache![index];
  }

  Future<bool> delete(int postId) async {
    if (!isLocalMode) return AniBakaApi.deleteCollection(postId);
    if (isBangumiMode) {
      throw const BangumiSyncException(
        'Bangumi 官方 API 暂不支持取消收藏，请到 Bangumi 页面操作',
      );
    }
    return _deleteLocal((item) => item.postId == postId);
  }

  Future<bool> deleteByBgmId(int bgmId) async {
    if (!isLocalMode) return AniBakaApi.deleteCollectionByBgmId(bgmId);
    if (isBangumiMode) {
      throw const BangumiSyncException(
        'Bangumi 官方 API 暂不支持取消收藏，请到 Bangumi 页面操作',
      );
    }
    return _deleteLocal((item) => item.bgmId == bgmId);
  }

  Future<List<AnimeCollection>> _refreshBangumiCollections() {
    return _bangumiCollectionRequests.get((
      session.generation,
      bangumi.generation,
    ), _fetchAndStoreBangumiCollections);
  }

  Future<List<AnimeCollection>> _fetchAndStoreBangumiCollections() async {
    final revision = session.generation;
    final remote = await bangumi.getCollections();
    if (revision != session.generation) throw StateError('账号已变更');
    _readLocal();
    await storeAll(
      remote.map((item) {
        final index = _localByBgmId[item.bgmId];
        return _mergeRemote(item, index == null ? null : _localCache![index]);
      }),
    );
    return _localCache!;
  }

  /// One identity index and one persistence operation for a complete import.
  Future<void> storeAll(Iterable<AnimeCollection> changes) async {
    final items = _readLocal();
    final byBgm = _localByBgmId;
    final byPost = _localByPostId;
    for (final item in changes) {
      var index = item.bgmId == null ? null : byBgm[item.bgmId];
      final postIndex = item.postId == null ? null : byPost[item.postId];
      if (index == null &&
          postIndex != null &&
          (item.bgmId == null || items[postIndex].bgmId == null)) {
        index = postIndex;
      }
      if (index == null) {
        index = items.length;
        items.add(item);
      } else {
        final previous = items[index];
        if (previous.bgmId != item.bgmId) byBgm.remove(previous.bgmId);
        if (previous.postId != item.postId) byPost.remove(previous.postId);
        items[index] = item;
      }
      if (item.bgmId case final id?) byBgm[id] = index;
      if (item.postId case final id?) byPost[id] = index;
    }
    await _writeLocal(items);
  }

  AnimeCollection _mergeRemote(AnimeCollection remote, AnimeCollection? local) {
    if (local == null) return remote;
    return AnimeCollection(
      postId: local.postId,
      bgmId: remote.bgmId,
      status: remote.status,
      rating: remote.rating,
      comment: remote.comment,
      epTotal: remote.epTotal ?? local.epTotal,
      epWatched: remote.epWatched,
      tags: remote.tags,
      isPrivate: remote.isPrivate,
      nsfw: remote.nsfw || local.nsfw,
      postTitle: local.postTitle,
      postCover: local.postCover,
      bgmRating: remote.bgmRating ?? local.bgmRating,
      bgmImage: remote.bgmImage ?? local.bgmImage,
      bgmTitle: remote.bgmTitle?.isNotEmpty == true
          ? remote.bgmTitle
          : local.bgmTitle,
    );
  }

  Future<bool> _deleteLocal(bool Function(AnimeCollection item) matches) async {
    final items = _readLocal();
    final before = items.length;
    items.removeWhere(matches);
    if (items.length == before) return false;
    await _writeLocal(items);
    return true;
  }

  List<AnimeCollection> _readLocal() {
    final cached = _localCache;
    if (cached != null) return cached;
    final raw = session.preferences.getString(_localKey);
    if (raw == null || raw.isEmpty) return _replaceLocal(<AnimeCollection>[]);
    final decoded = jsonDecode(raw) as List<dynamic>;
    return _replaceLocal(
      decoded
          .cast<Map<String, dynamic>>()
          .map(AnimeCollection.fromJson)
          .toList(growable: true),
    );
  }

  Future<void> _writeLocal(List<AnimeCollection> items) {
    _replaceLocal(items);
    final json = StringBuffer('[');
    for (var i = 0; i < items.length; i++) {
      if (i > 0) json.write(',');
      json.write(jsonEncode(items[i].toJson(includeLocalFields: true)));
    }
    json.write(']');
    return session.preferences.setString(_localKey, json.toString());
  }

  List<AnimeCollection> _replaceLocal(List<AnimeCollection> items) {
    final byBgmId = <int, int>{};
    final byPostId = <int, int>{};
    final counts = List<int>.filled(CollectionStatus.values.length, 0);
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      final bgmId = item.bgmId;
      if (bgmId != null) byBgmId.putIfAbsent(bgmId, () => index);
      final postId = item.postId;
      if (postId != null) byPostId.putIfAbsent(postId, () => index);
      final status = CollectionStatus.fromValue(item.status);
      if (status != null) counts[status.index]++;
    }
    _localCache = items;
    _localByBgmId = byBgmId;
    _localByPostId = byPostId;
    _localStats = CollectionStats(
      wish: counts[CollectionStatus.wish.index],
      collect: counts[CollectionStatus.collect.index],
      doing: counts[CollectionStatus.doing.index],
      onHold: counts[CollectionStatus.onHold.index],
      dropped: counts[CollectionStatus.dropped.index],
      total: items.length,
    );
    return items;
  }
}
