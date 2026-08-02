import 'dart:convert';

import 'package:baka/api/collection.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/services/bangumi_sync_service.dart';
import 'package:baka/utils/bgm_utils.dart';

/// 登录 AniBaka 时使用云端收藏；未登录时使用设备本地收藏。
class CollectionService {
  const CollectionService._();

  static const _localKey = 'local_anime_collections_v1';
  static Future<List<AnimeCollection>>? _bangumiCollectionRequest;

  static bool get isLocalMode => Instances.userToken.isEmpty;
  static bool get isBangumiMode =>
      isLocalMode && BangumiSyncService.instance.isConnected;

  static Future<AnimeCollection?> addOrUpdate(
    AnimeCollection collection, {
    bool syncBangumi = true,
  }) async {
    if (!isLocalMode) {
      final saved = await CollectionApi.addOrUpdate(collection);
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
    final normalized = _withStatusText(collection);
    if (index < 0) {
      items.add(normalized);
    } else {
      items[index] = normalized;
    }
    await _writeLocal(items);
    return normalized;
  }

  static Future<CollectionListResponse?> getList({
    int page = 1,
    int pageSize = 20,
    int? status,
    int? bgmId,
  }) async {
    if (!isLocalMode) {
      return CollectionApi.getList(
        page: page,
        pageSize: pageSize,
        status: status,
        bgmId: bgmId,
      );
    }
    if (isBangumiMode) await _refreshBangumiCollections();
    final filtered = _readLocal().where((item) {
      if (status != null && item.status != status) return false;
      if (bgmId != null && item.bgmId != bgmId) return false;
      return true;
    }).toList();
    final safePage = page < 1 ? 1 : page;
    final safePageSize = pageSize < 1 ? 20 : pageSize;
    final start = (safePage - 1) * safePageSize;
    final end = start + safePageSize < filtered.length
        ? start + safePageSize
        : filtered.length;
    final list = start >= filtered.length
        ? <AnimeCollection>[]
        : filtered.sublist(start, end);
    return CollectionListResponse(
      list: list,
      total: filtered.length,
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
      final response = await CollectionApi.getList(
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
    if (!isLocalMode) return CollectionApi.getStats();
    if (isBangumiMode) await _refreshBangumiCollections();
    final counts = <int, int>{};
    for (final item in _readLocal()) {
      counts.update(item.status, (value) => value + 1, ifAbsent: () => 1);
    }
    return CollectionStats(
      wish: counts[CollectionStatus.wish.value] ?? 0,
      collect: counts[CollectionStatus.collect.value] ?? 0,
      doing: counts[CollectionStatus.doing.value] ?? 0,
      onHold: counts[CollectionStatus.onHold.value] ?? 0,
      dropped: counts[CollectionStatus.dropped.value] ?? 0,
      total: counts.values.fold(0, (sum, value) => sum + value),
    );
  }

  static Future<AnimeCollection?> getByPostId(int postId) async {
    if (!isLocalMode) return CollectionApi.getByPostId(postId);
    return _firstWhereOrNull(_readLocal(), (item) => item.postId == postId);
  }

  static Future<AnimeCollection?> getByBgmId(
    int bgmId, {
    bool refreshBangumi = true,
  }) async {
    if (!isLocalMode) return CollectionApi.getByBgmId(bgmId);
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
    return _firstWhereOrNull(_readLocal(), (item) => item.bgmId == bgmId);
  }

  static Future<bool> delete(int postId) async {
    if (!isLocalMode) return CollectionApi.delete(postId);
    if (isBangumiMode) {
      throw const BangumiSyncException(
        'Bangumi 官方 API 暂不支持取消收藏，请到 Bangumi 页面操作',
      );
    }
    return _deleteLocal((item) => item.postId == postId);
  }

  static Future<bool> deleteByBgmId(int bgmId) async {
    if (!isLocalMode) return CollectionApi.deleteByBgmId(bgmId);
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
    if (local == null) return _withStatusText(remote);
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
    final raw = Instances.sp.getString(_localKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return BgmUtils.parseJsonList(jsonDecode(raw))
          .map(BgmUtils.parseJsonMap)
          .whereType<Map<String, dynamic>>()
          .map(AnimeCollection.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _writeLocal(List<AnimeCollection> items) {
    return Instances.sp.setString(
      _localKey,
      jsonEncode(items.map(_toLocalJson).toList()),
    );
  }

  static Map<String, dynamic> _toLocalJson(AnimeCollection item) => {
    ...item.toJson(),
    if (item.id != null) 'id': item.id,
    if (item.userId != null) 'user_id': item.userId,
    if (item.statusText != null) 'status_text': item.statusText,
    if (item.bgmRating != null) 'bgm_rating': item.bgmRating,
  };

  static AnimeCollection _withStatusText(AnimeCollection item) {
    final json = _toLocalJson(item);
    json['status_text'] =
        item.statusText ?? CollectionStatus.fromValue(item.status)?.label;
    return AnimeCollection.fromJson(json);
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
