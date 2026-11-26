import 'package:baka/api/bangumi_account_api.dart';
import 'dart:async';
import 'dart:convert';

import 'package:baka/api/anibaka_api.dart';
import 'package:baka/core/app_logger.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/page.dart';
import 'package:flutter/foundation.dart';

/// 登录 AniBaka 时使用云端收藏；未登录时使用设备本地收藏。
late CollectionRepository collections;

class CollectionRepository {
  CollectionRepository(this.session, this.bangumi);
  final AccountSession session;
  final BangumiSession bangumi;

  /// 收藏数据变更计数。写入或删除后自增，页面监听它刷新列表与统计。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void _markChanged() => revision.value += 1;

  static const _localKey = 'local_anime_collections_v1';

  /// 云端模式拉到的收藏快照：服务器不可达时用它填界面。
  static const _cloudCacheKey = 'anibaka_collections_cache_v1';
  static const _cloudCacheLimit = 2000;
  List<AnimeCollection>? _cloudCacheMemory;
  String _cloudCacheOwner = '';

  /// 上次云端请求成功的时间；窗口内进页面直接请求，过期则先出快照。
  DateTime? _lastCloudOkAt;
  static const _cloudFreshWindow = Duration(minutes: 5);

  /// 后台补快照的冷却：失败后两分钟内不再试。
  static const _cloudRefreshCooldown = Duration(minutes: 2);
  DateTime? _lastCloudRefresh;
  bool _cloudRefreshing = false;
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

  /// 当前展示的是云端离线快照时置 true；页面据此在顶部提示「离线数据」。
  final ValueNotifier<bool> servingCache = ValueNotifier<bool>(false);

  /// Bangumi 直连兜底的冷却：短时间内只试一次。
  static const _bangumiFallbackCooldown = Duration(seconds: 30);
  static const _bangumiFallbackTimeout = Duration(seconds: 8);
  DateTime? _lastBangumiFallback;
  bool _bangumiFallbackBusy = false;

  /// 服务器故障冷却：这段时间内不再请求云端，直接出快照。
  static const _cloudDownCooldown = Duration(minutes: 5);

  /// 前台请求的最长等待：超过就先用快照，请求结果不再等。
  static const _cloudRequestTimeout = Duration(seconds: 6);

  Future<T> _withCloudTimeout<T>(Future<T> request) =>
      request.timeout(_cloudRequestTimeout);
  DateTime? _cloudDownUntil;

  bool get _cloudDown =>
      _cloudDownUntil != null && DateTime.now().isBefore(_cloudDownUntil!);

  /// 上次云端请求成功且还在窗口内：进页面时直接请求，用户无感。
  bool get _cloudFresh =>
      _lastCloudOkAt != null &&
      DateTime.now().difference(_lastCloudOkAt!) < _cloudFreshWindow;

  void _markCloudDown() =>
      _cloudDownUntil = DateTime.now().add(_cloudDownCooldown);

  bool get isLocalMode => session.token.isEmpty;
  bool get isBangumiMode => isLocalMode && bangumi.isConnected;

  Future<AnimeCollection> addOrUpdate(
    AnimeCollection collection, {
    bool statusOnly = false,
  }) async {
    final next = _preserveProgress(collection);
    if (!isLocalMode) {
      final saved = await AniBakaApi.saveCollection(next);
      if (bangumi.isConnected) {
        _mirrorToBangumi(saved, statusOnly: statusOnly);
      }
      // 先把这次结果并进快照，服务器随后不可用时也显示新状态。
      unawaited(_cacheCloudPage([saved]));
      _markChanged();
      return saved;
    }
    await storeAll([next]);
    if (next.bgmId case final id?) _localChangedAt[id] = DateTime.now();
    if (isBangumiMode) _mirrorToBangumi(next, statusOnly: statusOnly);
    _markChanged();
    return next;
  }

  /// 导入远端收藏，不回写 Bangumi；分批写入时传 `notify: false`，
  /// 结束后调用 [notifyChanged] 统一通知。
  Future<void> importRemote(
    Iterable<AnimeCollection> items, {
    bool notify = true,
  }) async {
    final list = items.toList();
    if (list.isEmpty) return;
    if (isLocalMode) {
      await storeAll(list);
    } else {
      for (final item in list) {
        await AniBakaApi.saveCollection(item);
      }
    }
    if (notify) _markChanged();
  }

  /// 批量写入结束后通知页面刷新。
  void notifyChanged() => _markChanged();

  /// 写入前保留已有的已看集数，并补齐本次没带的字段。
  /// 0 分、空标签、非私密一律视为未填写，沿用原记录。
  AnimeCollection _preserveProgress(AnimeCollection next) {
    final bgmId = next.bgmId;
    if (!isLocalMode || bgmId == null) return next;
    final items = _readLocal();
    final index = _localByBgmId[bgmId];
    if (index == null) return next;
    final previous = items[index];
    final previousWatched = previous.epWatched ?? 0;
    final nextWatched = next.epWatched ?? 0;
    return AnimeCollection(
      postId: next.postId ?? previous.postId,
      bgmId: bgmId,
      status: next.status,
      rating: next.rating > 0 ? next.rating : previous.rating,
      comment: next.comment ?? previous.comment,
      epTotal: next.epTotal ?? previous.epTotal,
      epWatched: nextWatched > previousWatched ? nextWatched : previousWatched,
      tags: next.tags.isNotEmpty ? next.tags : previous.tags,
      isPrivate: next.isPrivate || previous.isPrivate,
      nsfw: next.nsfw || previous.nsfw,
      postTitle: next.postTitle ?? previous.postTitle,
      postCover: next.postCover ?? previous.postCover,
      bgmRating: next.bgmRating ?? previous.bgmRating,
      bgmImage: next.bgmImage ?? previous.bgmImage,
      bgmTitle: next.bgmTitle ?? previous.bgmTitle,
      bgmSynced: next.bgmSynced || previous.bgmSynced,
    );
  }

  /// 把收藏镜像到 Bangumi；传上去之前先记入待补传队列，成功后再划掉。
  /// [statusOnly] 只提交状态。
  void _mirrorToBangumi(AnimeCollection collection, {bool statusOnly = false}) {
    final bgmId = collection.bgmId;
    if (bgmId == null || bgmId <= 0) return;
    unawaited(() async {
      // 还在路上时也算待补传。
      _addPending(bgmId);
      _mirroring.add(bgmId);
      var synced = false;
      try {
        await bangumi.updateCollection(collection, statusOnly: statusOnly);
        synced = true;
      } catch (error) {
        Log.w('Collection', 'Bangumi 收藏同步失败', error);
      } finally {
        if (synced) await markSynced(bgmId);
        _mirroring.remove(bgmId);
        // 同一部番还有更晚的改动在路上时，等它回来再划掉。
        if (synced && !_mirroring.contains(bgmId)) _removePending(bgmId);
      }
    }());
  }

  /// 这一条已经写入过 Bangumi；之后远端没有它即视为被删掉。
  Future<void> markSynced(int bgmId) async {
    final items = _readLocal();
    final index = _localByBgmId[bgmId];
    if (index == null) return;
    if (items[index].bgmSynced) return;
    items[index] = items[index].asBgmSynced();
    await _writeLocal(items);
  }

  static const _pendingSyncKey = 'bangumi_pending_collection_sync_v1';
  bool _syncingPending = false;
  final _mirroring = <int>{};

  /// 本机最后一次改这条收藏的时间，用来判断刷新返回的数据是不是比它旧。
  final Map<int, DateTime> _localChangedAt = {};

  /// 这一条是否还没同步到 Bangumi。
  bool hasPendingSync(int bgmId) => _pendingIds().contains(bgmId);

  /// 全量同步已经处理过这一条，划掉待补传标记。
  void clearPendingSync(int bgmId) => _removePending(bgmId);

  /// 记下一条还没同步到 Bangumi 的收藏。
  void markPendingSync(int bgmId) => _addPending(bgmId);

  /// 补传上次没同步到 Bangumi 的收藏。登录本站时从云端取那一条，
  /// 未登录时取本机那条；两种模式都会重试。
  Future<void> syncPending() async {
    if (!bangumi.isConnected || _syncingPending) return;
    final ids = _pendingIds();
    if (ids.isEmpty) return;
    _syncingPending = true;
    try {
      for (final bgmId in ids.toList()) {
        if (_mirroring.contains(bgmId)) continue;
        final AnimeCollection? item;
        if (isLocalMode) {
          final index = _localByBgmId[bgmId];
          item = index == null ? null : _readLocal()[index];
        } else {
          try {
            item = await AniBakaApi.getCollectionByBgmId(bgmId);
          } catch (error) {
            Log.w('Collection', '读取本站收藏失败，稍后补传', error);
            break;
          }
        }
        if (item == null) {
          _removePending(bgmId);
          continue;
        }
        _mirroring.add(bgmId);
        try {
          // 本机待补传只记了状态；本站那条是完整记录，可以整条写回。
          await bangumi.updateCollection(item, statusOnly: isLocalMode);
          await markSynced(bgmId);
          _removePending(bgmId);
        } catch (error) {
          Log.w('Collection', 'Bangumi 收藏补传失败', error);
          if (_isRejectedByBangumi(error)) {
            // Bangumi 拒收时丢掉这一条待补传。
            _removePending(bgmId);
            continue;
          }
          // 网络或登录问题：保留待补传，下次再试。
          break;
        } finally {
          _mirroring.remove(bgmId);
        }
      }
    } finally {
      _syncingPending = false;
    }
  }

  /// 400 / 404 表示 Bangumi 拒收，直接丢弃。
  static bool _isRejectedByBangumi(Object error) {
    final status = error is BangumiSyncException ? error.statusCode : null;
    return status == 400 || status == 404;
  }

  Set<int>? _pendingCache;
  String _pendingOwner = '';
  Future<void> _pendingWrite = Future<void>.value();

  /// 每个 Bangumi 账号一份待补传清单。
  static String _pendingKey(String owner) =>
      owner.isEmpty ? _pendingSyncKey : '$_pendingSyncKey:$owner';

  /// 当前 Bangumi 账号待补传的 bgmId。
  Set<int> _pendingIds() {
    final owner = bangumi.account?.username ?? '';
    final cached = _pendingCache;
    if (cached != null && _pendingOwner == owner) return cached;
    _pendingOwner = owner;
    return _pendingCache = _readPending(owner);
  }

  static Set<int> _decodeIds(String? raw) {
    if (raw == null || raw.isEmpty) return <int>{};
    try {
      final json = jsonDecode(raw);
      final list = switch (json) {
        List() => json,
        Map() => json['ids'],
        _ => null,
      };
      if (list is! List) return <int>{};
      return list
          .map((value) => value is int ? value : int.tryParse('$value'))
          .whereType<int>()
          .toSet();
    } catch (_) {
      return <int>{};
    }
  }

  Set<int> _readPending(String owner) {
    final prefs = session.preferences;
    final raw = prefs.getString(_pendingKey(owner));
    if (raw != null || owner.isEmpty) return _decodeIds(raw);
    // 旧版本的清单按账号迁移。
    final legacyRaw = prefs.getString(_pendingSyncKey);
    final ids = _decodeIds(legacyRaw);
    if (legacyRaw == null || ids.isEmpty) return <int>{};
    var legacyOwner = '';
    try {
      final json = jsonDecode(legacyRaw);
      final ownerValue = json is Map ? json['owner'] : null;
      if (ownerValue is String) legacyOwner = ownerValue;
    } catch (_) {}
    if (legacyOwner != owner) return <int>{};
    unawaited(
      Future.wait<void>([
        prefs.setString(_pendingKey(owner), jsonEncode(ids.toList())),
        prefs.remove(_pendingSyncKey),
      ]),
    );
    return ids;
  }

  void _writePending(Set<int> ids) {
    _pendingCache = ids;
    final key = _pendingKey(_pendingOwner);
    final raw = jsonEncode(ids.toList()..sort());
    _pendingWrite = _pendingWrite
        .then((_) async {
          await session.preferences.setString(key, raw);
        })
        .catchError((Object _) {});
  }

  void _addPending(int? bgmId) {
    if (bgmId == null || bgmId <= 0) return;
    final ids = _pendingIds();
    if (!ids.add(bgmId)) return;
    _writePending(ids);
  }

  void _removePending(int? bgmId) {
    if (bgmId == null) return;
    final ids = _pendingIds();
    if (!ids.remove(bgmId)) return;
    _writePending(ids);
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
      unawaited(syncPending());
      final cached = _readCloudCache();
      // 快照可用且上次请求不在新鲜窗口内：先出快照，云端刷新放后台。
      if (cached.isNotEmpty && (_cloudDown || !_cloudFresh)) {
        servingCache.value = true;
        unawaited(_refreshCloudQuietly());
        return _pageOfCache(
          cached,
          page: page,
          pageSize: pageSize,
          status: status,
          bgmId: bgmId,
        );
      }
      try {
        final result = await _withCloudTimeout(
          AniBakaApi.getCollections(
            page: page,
            pageSize: pageSize,
            status: status,
            bgmId: bgmId,
          ),
        );
        _cloudDownUntil = null;
        _lastCloudOkAt = DateTime.now();
        unawaited(_cacheCloudPage(result.list));
        // 快照只有当前页时补一次全量。
        if (result.total > _readCloudCache().length) {
          unawaited(_refreshCloudQuietly());
        }
        servingCache.value = false;
        return result;
      } catch (error) {
        _markCloudDown();
        Log.w('Collection', '云端收藏列表读取失败', error);
        // 优先级：服务器 → 本地快照 → Bangumi 直连。
        if (cached.isNotEmpty) {
          if (bangumi.isConnected) unawaited(_refreshFromBangumiFallback());
          servingCache.value = true;
          return _pageOfCache(
            cached,
            page: page,
            pageSize: pageSize,
            status: status,
            bgmId: bgmId,
          );
        }
        final viaBangumi = await _fetchBangumiFallback();
        if (viaBangumi != null && viaBangumi.isNotEmpty) {
          unawaited(_replaceCloudCache(viaBangumi));
          servingCache.value = false;
          return _pageOfCache(
            viaBangumi,
            page: page,
            pageSize: pageSize,
            status: status,
            bgmId: bgmId,
          );
        }
        rethrow;
      }
    }
    if (isBangumiMode) {
      unawaited(syncPending());
      // 本机存过收藏就先出列表，远端刷新放后台；一台空设备才等远端。
      if (_readLocal().isEmpty) {
        await _refreshBangumiQuietly();
      } else {
        unawaited(_refreshBangumiQuietly());
      }
    }
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
        await _refreshBangumiQuietly();
      }
      return _readLocal();
    }
    final cached = _readCloudCache();
    if (cached.isNotEmpty && (_cloudDown || !_cloudFresh)) {
      servingCache.value = true;
      unawaited(_refreshCloudQuietly());
      return cached;
    }
    try {
      final result = await _fetchAllCloud();
      _cloudDownUntil = null;
      _lastCloudOkAt = DateTime.now();
      unawaited(_replaceCloudCache(result));
      servingCache.value = false;
      return result;
    } catch (error) {
      _markCloudDown();
      Log.w('Collection', '云端收藏读取失败', error);
      // 优先级：服务器 → 本地快照 → Bangumi 直连。
      if (cached.isNotEmpty) {
        if (bangumi.isConnected) unawaited(_refreshFromBangumiFallback());
        servingCache.value = true;
        return cached;
      }
      final viaBangumi = await _fetchBangumiFallback();
      if (viaBangumi != null && viaBangumi.isNotEmpty) {
        unawaited(_replaceCloudCache(viaBangumi));
        servingCache.value = false;
        return viaBangumi;
      }
      rethrow;
    }
  }

  /// 全量拉取云端收藏，用于后台补快照。
  Future<List<AnimeCollection>> _fetchAllCloud() async {
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
      unawaited(syncPending());
      final cached = _readCloudCache();
      if (cached.isNotEmpty && (_cloudDown || !_cloudFresh)) {
        servingCache.value = true;
        unawaited(_refreshCloudQuietly());
        return _statsOfCache(cached);
      }
      try {
        final stats = await _withCloudTimeout(
          _statsRequests.get((
            session.generation,
            bangumi.generation,
          ), AniBakaApi.getCollectionStats),
        );
        _cloudDownUntil = null;
        _lastCloudOkAt = DateTime.now();
        servingCache.value = false;
        return stats;
      } catch (error) {
        _markCloudDown();
        if (cached.isEmpty) rethrow;
        Log.w('Collection', '云端收藏统计失败，改用本地快照', error);
        servingCache.value = true;
        unawaited(_refreshCloudQuietly());
        return _statsOfCache(cached);
      }
    }
    final emptyDevice = isLocalMode && _readLocal().isEmpty;
    if (isBangumiMode) {
      unawaited(syncPending());
      // 本机存过收藏就先出统计，远端刷新放后台；一台空设备才等远端。
      if (emptyDevice) {
        await _refreshBangumiQuietly();
      } else {
        unawaited(_refreshBangumiQuietly());
      }
    }
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
            : _getCloudByBgmId(bgmId),
      );
    }
    return _getLocalByBgmId(bgmId, refreshBangumi: refreshBangumi);
  }

  /// 云端单条：失败或冷却期内都用快照里的那条。
  Future<AnimeCollection?> _getCloudByBgmId(int bgmId) async {
    if (_cloudDown) return _cachedByBgmId(bgmId);
    try {
      final item = await _withCloudTimeout(
        AniBakaApi.getCollectionByBgmId(bgmId),
      );
      _cloudDownUntil = null;
      _lastCloudOkAt = DateTime.now();
      if (item != null) {
        unawaited(_cacheCloudPage([item]));
      } else {
        _removeFromCloudCache(bgmId: bgmId);
      }
      return item;
    } catch (error) {
      _markCloudDown();
      Log.w('Collection', '云端追番状态读取失败，改用本地快照', error);
      return _cachedByBgmId(bgmId);
    }
  }

  AnimeCollection? _cachedByBgmId(int bgmId) {
    for (final item in _readCloudCache()) {
      if (item.bgmId == bgmId) return item;
    }
    return null;
  }

  Future<AnimeCollection?> _getLocalByBgmId(
    int bgmId, {
    required bool refreshBangumi,
  }  ) async {
    final local = _localEntry(bgmId);
    if (refreshBangumi && isBangumiMode) {
      final AnimeCollection? remote;
      try {
        // 单条读取最多等 6 秒；直连不通时用本机记录先把界面填上。
        remote = await bangumi
            .getCollection(bgmId)
            .timeout(const Duration(seconds: 6));
      } catch (error) {
        // 连不上 Bangumi 时显示本机的那条，不要当成没收藏。
        Log.w('Collection', '读取 Bangumi 收藏失败，使用本机记录', error);
        return local;
      }
      // Bangumi 上没有这条：
      // - 本机还没传上去（待补传）→ 按本机的显示；
      // - 从没传过（本机草稿）→ 也按本机显示；
      // - 以前传过又被删掉 → 跟着删掉。
      if (remote == null) {
        if (local == null) return null;
        if (_pendingIds().contains(bgmId) ||
            _mirroring.contains(bgmId) ||
            !local.bgmSynced) {
          return local;
        }
        await _deleteLocal((item) => item.bgmId == bgmId);
        return null;
      }
      final merged = _mergeRemote(
        remote,
        local,
        keepLocalState: _pendingIds().contains(bgmId),
      );
      await storeAll([merged]);
      return merged;
    }
    return _localEntry(bgmId);
  }

  AnimeCollection? _localEntry(int bgmId) {
    _readLocal();
    final index = _localByBgmId[bgmId];
    return index == null ? null : _localCache![index];
  }

  Future<bool> delete(int postId) async {
    if (!isLocalMode) {
      final deleted = await AniBakaApi.deleteCollection(postId);
      if (deleted) {
        _removeFromCloudCache(postId: postId);
        _markChanged();
      }
      return deleted;
    }
    if (isBangumiMode) {
      throw const BangumiSyncException(
        'Bangumi 官方 API 暂不支持取消收藏，请到 Bangumi 页面操作',
      );
    }
    return _deleteLocal((item) => item.postId == postId);
  }

  Future<bool> deleteByBgmId(int bgmId) async {
    if (!isLocalMode) {
      final deleted = await AniBakaApi.deleteCollectionByBgmId(bgmId);
      if (deleted) {
        _removeFromCloudCache(bgmId: bgmId);
        _markChanged();
      }
      return deleted;
    }
    if (isBangumiMode) {
      throw const BangumiSyncException(
        'Bangumi 官方 API 暂不支持取消收藏，请到 Bangumi 页面操作',
      );
    }
    _removePending(bgmId);
    return _deleteLocal((item) => item.bgmId == bgmId);
  }

  /// 取消收藏后同时从快照里去掉。
  void _removeFromCloudCache({int? postId, int? bgmId}) {
    final cached = _readCloudCache();
    if (cached.isEmpty) return;
    final next = cached
        .where(
          (item) =>
              !(postId != null && item.postId == postId) &&
              !(bgmId != null && item.bgmId == bgmId),
        )
        .toList(growable: false);
    if (next.length == cached.length) return;
    _cloudCacheMemory = next;
    unawaited(
      session.preferences.setString(
        _cloudCacheStoreKey,
        jsonEncode(next.map((item) => item.toJson()).toList()),
      ),
    );
  }

  DateTime? _lastBgmRefresh;

  /// 拉取失败时保留本地缓存，20 秒内不重复拉。
  Future<void> _refreshBangumiQuietly({bool force = false}) async {
    final last = _lastBgmRefresh;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 20)) {
      return;
    }
    try {
      await _refreshBangumiCollections();
      _lastBgmRefresh = DateTime.now();
    } catch (error) {
      Log.w('Collection', 'Bangumi 收藏刷新失败，使用本地缓存', error);
    }
  }

  /// 手动刷新：忽略冷却时间，立即向 Bangumi 拉一次。
  Future<void> refreshFromBangumi() async {
    if (!isBangumiMode) return;
    await _refreshBangumiQuietly(force: true);
  }

  Future<List<AnimeCollection>> _refreshBangumiCollections() {
    return _bangumiCollectionRequests.get((
      session.generation,
      bangumi.generation,
    ), _fetchAndStoreBangumiCollections);
  }

  /// 远端列表是唯一权威：合并远端条目，并清掉远端已经删除、且确实同步过的本地条目。
  Future<List<AnimeCollection>> _fetchAndStoreBangumiCollections() async {
    final revision = session.generation;
    final fetchStartedAt = DateTime.now();
    // 发请求前先记下待补传。
    final pendingBefore = Set<int>.of(_pendingIds());
    final remote = await bangumi.getCollections();
    if (revision != session.generation) throw StateError('账号已变更');
    final items = _readLocal();
    final statsBefore = _localStats;
    final pending = _pendingIds();
    final merged = <int, AnimeCollection>{};
    for (final item in remote) {
      final bgmId = item.bgmId;
      if (bgmId == null || bgmId <= 0) continue;
      final index = _localByBgmId[bgmId];
      merged[bgmId] = _mergeRemote(
        item,
        index == null ? null : items[index],
        keepLocalState:
            pendingBefore.contains(bgmId) ||
            pending.contains(bgmId) ||
            _changedDuringFetch(bgmId, fetchStartedAt),
      );
    }
    final result = <AnimeCollection>[];
    final seen = <int>{};
    for (final item in items) {
      final bgmId = item.bgmId;
      if (bgmId == null || bgmId <= 0) {
        result.add(item);
        continue;
      }
      final replacement = merged[bgmId];
      if (replacement != null) {
        if (seen.add(bgmId)) result.add(replacement);
        continue;
      }
      // 远端没有：待补传或本机草稿要保留，其余视为在 Bangumi 上被删掉。
      if (item.bgmSynced &&
          !pending.contains(bgmId) &&
          !pendingBefore.contains(bgmId) &&
          !_changedDuringFetch(bgmId, fetchStartedAt) &&
          !_mirroring.contains(bgmId)) {
        continue;
      }
      if (seen.add(bgmId)) result.add(item);
    }
    for (final entry in merged.entries) {
      if (seen.add(entry.key)) result.add(entry.value);
    }
    await _writeLocal(result);
    // 远端数据改动了统计时通知页面。
    if (!_sameStats(statsBefore, _localStats)) _markChanged();
    return _localCache!;
  }

  /// 这条收藏是否在本次拉取开始之后被本机改过。
  bool _changedDuringFetch(int bgmId, DateTime startedAt) {
    final changedAt = _localChangedAt[bgmId];
    return changedAt != null && changedAt.isAfter(startedAt);
  }

  bool _sameStats(CollectionStats a, CollectionStats b) =>
      a.total == b.total &&
      a.wish == b.wish &&
      a.collect == b.collect &&
      a.doing == b.doing &&
      a.onHold == b.onHold &&
      a.dropped == b.dropped;

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

  /// 远端记录合并到本地；[keepLocalState] 为 true 时保留还没同步上去的本地状态。
  AnimeCollection _mergeRemote(
    AnimeCollection remote,
    AnimeCollection? local, {
    bool keepLocalState = false,
  }) {
    if (local == null) return remote;
    final localWatched = local.epWatched ?? 0;
    final remoteWatched = remote.epWatched ?? 0;
    return AnimeCollection(
      postId: local.postId,
      bgmId: remote.bgmId,
      status: keepLocalState ? local.status : remote.status,
      rating: keepLocalState ? local.rating : remote.rating,
      comment: keepLocalState ? local.comment : remote.comment,
      epTotal: remote.epTotal ?? local.epTotal,
      epWatched: keepLocalState && localWatched > remoteWatched
          ? local.epWatched
          : remote.epWatched,
      tags: keepLocalState ? local.tags : remote.tags,
      isPrivate: remote.isPrivate,
      nsfw: remote.nsfw || local.nsfw,
      postTitle: local.postTitle,
      postCover: local.postCover,
      bgmRating: remote.bgmRating ?? local.bgmRating,
      bgmImage: remote.bgmImage ?? local.bgmImage,
      bgmTitle: remote.bgmTitle?.isNotEmpty == true
          ? remote.bgmTitle
          : local.bgmTitle,
      bgmSynced: true,
    );
  }

  Future<bool> _deleteLocal(bool Function(AnimeCollection item) matches) async {
    final items = _readLocal();
    final before = items.length;
    items.removeWhere(matches);
    if (items.length == before) return false;
    await _writeLocal(items);
    _markChanged();
    return true;
  }

  /// 云端不可用时的第二选择：直接问 Bangumi。
  /// 没登录、正在试、或者冷却中都返回 null。
  Future<List<AnimeCollection>?> _fetchBangumiFallback() async {
    if (!bangumi.isConnected || _bangumiFallbackBusy) return null;
    final last = _lastBangumiFallback;
    if (last != null &&
        DateTime.now().difference(last) < _bangumiFallbackCooldown) {
      return null;
    }
    _bangumiFallbackBusy = true;
    try {
      return await bangumi
          .getCollections()
          .timeout(_bangumiFallbackTimeout);
    } catch (error) {
      Log.w('Collection', 'Bangumi 直连也不可用', error);
      return null;
    } finally {
      _lastBangumiFallback = DateTime.now();
      _bangumiFallbackBusy = false;
    }
  }

  /// 已有快照顶着界面时，后台补一次 Bangumi；拿到了写回快照并通知页面重读。
  Future<void> _refreshFromBangumiFallback() async {
    final items = await _fetchBangumiFallback();
    if (items == null || items.isEmpty) return;
    await _replaceCloudCache(items);
    servingCache.value = false;
    _markChanged();
  }

  List<AnimeCollection> _readCloudCache() {
    final owner = session.user.value.id.toString();
    final cached = _cloudCacheMemory;
    if (cached != null && _cloudCacheOwner == owner) return cached;
    _cloudCacheOwner = owner;
    var raw = session.preferences.getString(_cloudCacheStoreKey);
    if (raw == null && _cloudCacheStoreKey != _cloudCacheKey) {
      // 旧版本的快照键做一次迁移。
      raw = session.preferences.getString(_cloudCacheKey);
      if (raw != null) {
        unawaited(session.preferences.setString(_cloudCacheStoreKey, raw));
        unawaited(session.preferences.remove(_cloudCacheKey));
      }
    }
    if (raw == null || raw.isEmpty) return _cloudCacheMemory = const [];
    try {
      return _cloudCacheMemory = (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(AnimeCollection.fromJson)
          .toList(growable: false);
    } catch (_) {
      return _cloudCacheMemory = const [];
    }
  }

  /// 快照按账号分开存。
  String get _cloudCacheStoreKey {
    final owner = session.user.value.id;
    return owner > 0 ? '$_cloudCacheKey:$owner' : _cloudCacheKey;
  }

  /// 云端拉到的单页并进快照，按 bgmId / postId 去重。
  Future<void> _cacheCloudPage(Iterable<AnimeCollection> items) async {
    if (items.isEmpty) return;
    final byKey = <String, AnimeCollection>{
      for (final item in _readCloudCache()) _cloudCacheKeyOf(item): item,
    };
    for (final item in items) {
      byKey[_cloudCacheKeyOf(item)] = item;
    }
    var merged = byKey.values.toList();
    if (merged.length > _cloudCacheLimit) {
      merged = merged.sublist(merged.length - _cloudCacheLimit);
    }
    _cloudCacheMemory = merged;
    await session.preferences.setString(
      _cloudCacheStoreKey,
      jsonEncode(merged.map((item) => item.toJson()).toList()),
    );
  }

  /// 全量结果直接替换快照，远端删掉的条目也会跟着消失。
  /// 返回快照内容是否有变化，用来决定要不要通知页面。
  Future<bool> _replaceCloudCache(Iterable<AnimeCollection> items) async {
    final list = items.toList();
    if (list.isEmpty) return false;
    final before = _cloudSignature(_readCloudCache());
    final next = list.length > _cloudCacheLimit
        ? list.sublist(list.length - _cloudCacheLimit)
        : list;
    _cloudCacheMemory = next;
    await session.preferences.setString(
      _cloudCacheStoreKey,
      jsonEncode(next.map((item) => item.toJson()).toList()),
    );
    return before != _cloudSignature(next);
  }

  /// 快照签名：条数、各状态数量与总进度，用来判断后台刷新有没有新数据。
  String _cloudSignature(List<AnimeCollection> items) {
    final stats = _statsOfCache(items);
    var watched = 0;
    for (final item in items) {
      watched += item.epWatched ?? 0;
    }
    return '${items.length}|${stats.wish}|${stats.collect}|${stats.doing}|'
        '${stats.onHold}|${stats.dropped}|$watched';
  }

  /// 后台补快照：失败不阻塞界面，两分钟内只试一次。
  Future<void> _refreshCloudQuietly() async {
    if (_cloudRefreshing) return;
    final last = _lastCloudRefresh;
    if (last != null &&
        DateTime.now().difference(last) < _cloudRefreshCooldown) {
      return;
    }
    _cloudRefreshing = true;
    try {
      final all = await _fetchAllCloud();
      final changed = await _replaceCloudCache(all);
      _cloudDownUntil = null;
      _lastCloudOkAt = DateTime.now();
      if (changed) _markChanged();
    } catch (error) {
      _markCloudDown();
      Log.w('Collection', '云端收藏后台刷新失败', error);
      if (bangumi.isConnected) unawaited(_refreshFromBangumiFallback());
    } finally {
      _cloudRefreshing = false;
      _lastCloudRefresh = DateTime.now();
    }
  }

  static String _cloudCacheKeyOf(AnimeCollection item) {
    final bgmId = item.bgmId;
    return bgmId != null && bgmId > 0 ? 'b$bgmId' : 'p${item.postId}';
  }

  /// 用快照按状态/条目过滤并分页，口径和本地模式一致。
  PageData<AnimeCollection> _pageOfCache(
    List<AnimeCollection> cached, {
    required int page,
    required int pageSize,
    required int? status,
    required int? bgmId,
  }) {
    final safePage = page < 1 ? 1 : page;
    final safePageSize = pageSize < 1 ? 20 : pageSize;
    final start = (safePage - 1) * safePageSize;
    var total = 0;
    final list = <AnimeCollection>[];
    for (final item in cached) {
      if (status != null && item.status != status) continue;
      if (bgmId != null && item.bgmId != bgmId) continue;
      if (total >= start && list.length < safePageSize) list.add(item);
      total++;
    }
    return (list: list, total: total, page: safePage, pageSize: safePageSize);
  }

  CollectionStats _statsOfCache(List<AnimeCollection> cached) {
    final counts = List<int>.filled(CollectionStatus.values.length, 0);
    for (final item in cached) {
      final status = CollectionStatus.fromValue(item.status);
      if (status != null) counts[status.index]++;
    }
    return CollectionStats(
      wish: counts[CollectionStatus.wish.index],
      collect: counts[CollectionStatus.collect.index],
      doing: counts[CollectionStatus.doing.index],
      onHold: counts[CollectionStatus.onHold.index],
      dropped: counts[CollectionStatus.dropped.index],
      total: cached.length,
    );
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
