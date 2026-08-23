import 'dart:convert';

import 'package:baka/api/anibaka_api.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/services/bangumi_sync_service.dart';

/// 登录 AniBaka 时使用云端收藏；未登录时使用设备本地收藏。
class CollectionService {
  const CollectionService._();

  static const _localKey = 'local_anime_collections_v1';
  static Future<List<AnimeCollection>>? _bangumiCollectionRequest;
  static List<AnimeCollection>? _localCache;
  static Map<int, AnimeCollection> _localByBgmId = const {};
  static Map<int, AnimeCollection> _localByPostId = const {};
  static CollectionStats _localStats = CollectionStats();

  static bool get isLocalMode => Instances.userToken.isEmpty;
  static bool get isBangumiMode =>
      isLocalMode && BangumiSyncService.instance.isConnected;

  static Future<AnimeCollection?> addOrUpdate(
    AnimeCollection collection, {
    bool syncBangumi = true,
  }) async {
    if (!isLocalMode) {
      final saved = await AniBakaApi.saveCollection(collection);
      if (saved != null &&
          syncBangumi &&
          BangumiSyncService.instance.isConnected) {
        await BangumiSyncService.instance.updateCollection(saved);
      }
      return saved;
    }
    if (syncBangumi && isBangumiMode) {
      await BangumiSyncService.instance.updateCollection(collection);
    }
    final items = _readLocal();
    final index = items.indexWhere((item) => _sameIdentity(item, collection));
    if (index < 0) {
      items.add(collection);
    } else {
      items[index] = collection;
    }
    await _writeLocal(items);
    return collection;
  }

  static Future<CollectionListResponse?> getList({
    int page = 1,
    int pageSize = 20,
    int? status,
    int? bgmId,
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
    return CollectionListResponse(
      list: list,
      total: total,
      page: safePage,
      pageSize: safePageSize,
    );
  }

  static Future<List<AnimeCollection>> getAll({
    bool refreshBangumi = true,
  }) async {
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
      if (response == null) return result;
      total = response.total;
      result.addAll(response.list);
      if (response.list.isEmpty) break;
      page++;
    }
    return result;
  }

  static Future<CollectionStats?> getStats() async {
    if (!isLocalMode) return AniBakaApi.getCollectionStats();
    if (isBangumiMode) await _refreshBangumiCollections();
    _readLocal();
    return _localStats;
  }

  static Future<AnimeCollection?> getByPostId(int postId) async {
    if (!isLocalMode) return AniBakaApi.getCollectionByPostId(postId);
    _readLocal();
    return _localByPostId[postId];
  }

  static Future<AnimeCollection?> getByBgmId(
    int bgmId, {
    bool refreshBangumi = true,
  }) async {
    if (!isLocalMode) return AniBakaApi.getCollectionByBgmId(bgmId);
    if (refreshBangumi && isBangumiMode) {
      final remote = await BangumiSyncService.instance.getCollection(bgmId);
      if (remote == null) return null;
      final local = _firstWhereOrNull(
        _readLocal(),
        (item) => item.bgmId == bgmId,
      );
      final merged = _mergeRemote(remote, local);
      await _upsertLocal(merged);
      return merged;
    }
    _readLocal();
    return _localByBgmId[bgmId];
  }

  static Future<bool> delete(int postId) async {
    if (!isLocalMode) return AniBakaApi.deleteCollection(postId);
    if (isBangumiMode) {
      throw const BangumiSyncException(
        'Bangumi 官方 API 暂不支持取消收藏，请到 Bangumi 页面操作',
      );
    }
    return _deleteLocal((item) => item.postId == postId);
  }

  static Future<bool> deleteByBgmId(int bgmId) async {
    if (!isLocalMode) return AniBakaApi.deleteCollectionByBgmId(bgmId);
    if (isBangumiMode) {
      throw const BangumiSyncException(
        'Bangumi 官方 API 暂不支持取消收藏，请到 Bangumi 页面操作',
      );
    }
    return _deleteLocal((item) => item.bgmId == bgmId);
  }

  static Future<List<AnimeCollection>> _refreshBangumiCollections() {
    final active = _bangumiCollectionRequest;
    if (active != null) return active;
    final request = _fetchAndStoreBangumiCollections();
    _bangumiCollectionRequest = request;
    return request.whenComplete(() {
      if (identical(_bangumiCollectionRequest, request)) {
        _bangumiCollectionRequest = null;
      }
    });
  }

  static Future<List<AnimeCollection>>
  _fetchAndStoreBangumiCollections() async {
    final remote = await BangumiSyncService.instance.getCollections();
    final localById = {
      for (final item in _readLocal())
        if (item.bgmId != null) item.bgmId!: item,
    };
    final remoteIds = {for (final item in remote) item.bgmId};
    final merged = [
      for (final item in remote) _mergeRemote(item, localById[item.bgmId]),
      for (final entry in localById.entries)
        if (!remoteIds.contains(entry.key)) entry.value,
    ];
    await _writeLocal(merged);
    return merged;
  }

  static Future<void> _upsertLocal(AnimeCollection collection) async {
    final items = _readLocal();
    final index = items.indexWhere((item) => _sameIdentity(item, collection));
    if (index < 0) {
      items.add(collection);
    } else {
      items[index] = collection;
    }
    await _writeLocal(items);
  }

  static AnimeCollection _mergeRemote(
    AnimeCollection remote,
    AnimeCollection? local,
  ) {
    if (local == null) return remote;
    return AnimeCollection(
      id: local.id,
      userId: local.userId,
      postId: local.postId,
      bgmId: remote.bgmId,
      status: remote.status,
      statusText: CollectionStatus.fromValue(remote.status)?.label,
      rating: remote.rating,
      comment: remote.comment,
      epTotal: remote.epTotal ?? local.epTotal,
      epWatched: remote.epWatched,
      tags: remote.tags,
      isPrivate: remote.isPrivate,
      postTitle: local.postTitle,
      postCover: local.postCover,
      bgmRating: remote.bgmRating ?? local.bgmRating,
      bgmImage: remote.bgmImage ?? local.bgmImage,
      bgmTitle: remote.bgmTitle?.isNotEmpty == true
          ? remote.bgmTitle
          : local.bgmTitle,
    );
  }

  static Future<bool> _deleteLocal(
    bool Function(AnimeCollection item) matches,
  ) async {
    final items = _readLocal();
    final before = items.length;
    items.removeWhere(matches);
    if (items.length == before) return false;
    await _writeLocal(items);
    return true;
  }

  static List<AnimeCollection> _readLocal() {
    final cached = _localCache;
    if (cached != null) return cached;
    final raw = Instances.sp.getString(_localKey);
    if (raw == null || raw.isEmpty) return _replaceLocal(<AnimeCollection>[]);
    final decoded = jsonDecode(raw) as List<dynamic>;
    return _replaceLocal(
      decoded
          .cast<Map<String, dynamic>>()
          .map(AnimeCollection.fromJson)
          .toList(growable: true),
    );
  }

  static Future<void> _writeLocal(List<AnimeCollection> items) {
    _replaceLocal(items);
    final json = StringBuffer('[');
    for (var i = 0; i < items.length; i++) {
      if (i > 0) json.write(',');
      json.write(jsonEncode(items[i].toJson(includeLocalFields: true)));
    }
    json.write(']');
    return Instances.sp.setString(_localKey, json.toString());
  }

  static List<AnimeCollection> _replaceLocal(List<AnimeCollection> items) {
    final byBgmId = <int, AnimeCollection>{};
    final byPostId = <int, AnimeCollection>{};
    final counts = List<int>.filled(CollectionStatus.values.length, 0);
    for (final item in items) {
      final bgmId = item.bgmId;
      if (bgmId != null) byBgmId.putIfAbsent(bgmId, () => item);
      final postId = item.postId;
      if (postId != null) byPostId.putIfAbsent(postId, () => item);
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

  static bool _sameIdentity(AnimeCollection a, AnimeCollection b) {
    if (a.bgmId != null && b.bgmId != null) return a.bgmId == b.bgmId;
    return a.postId != null && b.postId != null && a.postId == b.postId;
  }

  static AnimeCollection? _firstWhereOrNull(
    List<AnimeCollection> items,
    bool Function(AnimeCollection item) matches,
  ) {
    for (final item in items) {
      if (matches(item)) return item;
    }
    return null;
  }
}
