import 'package:baka/api/api_config.dart';
import 'package:baka/api/request_cache.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/play_history.dart';
import 'package:baka/models/watch_party.dart';
import 'package:baka/services/network_service.dart';

/// AniBaka v1 API 的唯一客户端入口。
final class AniBakaApi {
  AniBakaApi._();

  static const _animeDetailCacheLimit = 24;
  static const _episodeStillsCacheLimit = 24;

  static final _animeDetails = RequestCache<int, Map<String, dynamic>?>(
    limit: _animeDetailCacheLimit,
    shouldCache: (value) => value != null,
  );
  static final _episodeStills =
      RequestCache<
        ({int? bgmId, int? tmdbId, String? tvdbId, int season, int episode}),
        Map<String, dynamic>?
      >(limit: _episodeStillsCacheLimit, shouldCache: (value) => value != null);
  static final _collectionLists =
      RequestDeduplicator<
        ({int page, int pageSize, int? status, int? bgmId}),
        CollectionListResponse?
      >();
  static final _collectionStats = RequestDeduplicator<bool, CollectionStats?>();
  static final _collectionsByPost =
      RequestDeduplicator<int, AnimeCollection?>();
  static final _collectionsByBgm = RequestDeduplicator<int, AnimeCollection?>();
  static final _playHistoryLists =
      RequestDeduplicator<
        ({int pageSize, int? videoType}),
        PlayHistoryListResponse?
      >();

  static String get _baseUrl => '${ApiConfig.host}/api/v1';

  static Future<AnimeCollection?> saveCollection(AnimeCollection collection) =>
      _readObject(
        NetUtils.postJson('$_baseUrl/collection', collection.toJson()),
        AnimeCollection.fromJson,
      );

  static Future<CollectionListResponse?> getCollections({
    int page = 1,
    int pageSize = 20,
    int? status,
    int? bgmId,
  }) {
    final uri = Uri.parse('$_baseUrl/collection').replace(
      queryParameters: {
        'page': '$page',
        'page_size': '$pageSize',
        if (status != null) 'status': '$status',
        if (bgmId != null) 'bgm_id': '$bgmId',
      },
    );
    return _collectionLists.run(
      (page: page, pageSize: pageSize, status: status, bgmId: bgmId),
      () => _readObject(
        NetUtils.getJson(uri.toString()),
        CollectionListResponse.fromJson,
      ),
    );
  }

  static Future<CollectionStats?> getCollectionStats() => _collectionStats.run(
    true,
    () => _readObject(
      NetUtils.getJson('$_baseUrl/collection/stats'),
      CollectionStats.fromJson,
    ),
  );

  static Future<AnimeCollection?> getCollectionByPostId(int postId) =>
      _collectionsByPost.run(
        postId,
        () => _readObject(
          NetUtils.getJson('$_baseUrl/collection/post/$postId'),
          AnimeCollection.fromJson,
        ),
      );

  static Future<AnimeCollection?> getCollectionByBgmId(int bgmId) =>
      _collectionsByBgm.run(
        bgmId,
        () => _readObject(
          NetUtils.getJson('$_baseUrl/bgm-collection/$bgmId'),
          AnimeCollection.fromJson,
        ),
      );

  static Future<bool> deleteCollection(int postId) =>
      _succeeds(NetUtils.deleteJson('$_baseUrl/collection/$postId'));

  static Future<bool> deleteCollectionByBgmId(int bgmId) =>
      _succeeds(NetUtils.deleteJson('$_baseUrl/bgm-collection/$bgmId'));

  static Future<PlayHistory?> savePlayHistory(PlayHistory history) =>
      _readObject(
        NetUtils.postJson('$_baseUrl/play-history', history.toJson()),
        PlayHistory.fromJson,
      );

  static Future<PlayHistoryListResponse?> getPlayHistory({
    int pageSize = 20,
    int? videoType,
  }) {
    final uri = Uri.parse('$_baseUrl/play-history').replace(
      queryParameters: {
        'page_size': '$pageSize',
        if (videoType != null) 'video_type': '$videoType',
      },
    );
    return _playHistoryLists.run(
      (pageSize: pageSize, videoType: videoType),
      () => _readObject(
        NetUtils.getJson(uri.toString()),
        PlayHistoryListResponse.fromJson,
      ),
    );
  }

  static Future<bool> clearPlayHistory() =>
      _succeeds(NetUtils.deleteJson('$_baseUrl/play-history-clear'));

  static Future<Map<String, dynamic>?> getAnimeDetail(int bgmId) =>
      _animeDetails.get(
        bgmId,
        () => _readMap(
          NetUtils.getJson(
            '$_baseUrl/anime/detail?bgm_id=$bgmId',
            timeout: const Duration(seconds: 8),
            notifyOnError: false,
          ),
        ),
      );

  static Future<Map<String, dynamic>?> getEpisodeStills({
    int? bgmId,
    int? tmdbId,
    String? tvdbId,
    int season = 1,
    int episode = 1,
  }) {
    final key = (
      bgmId: bgmId,
      tmdbId: tmdbId,
      tvdbId: tvdbId,
      season: season,
      episode: episode,
    );
    return _episodeStills.get(key, () {
      final uri = Uri.parse('$_baseUrl/anime/episode/stills').replace(
        queryParameters: {
          if (tmdbId != null && tmdbId > 0) 'tmdb_id': '$tmdbId',
          if (bgmId != null && bgmId > 0) 'bgm_id': '$bgmId',
          if (tvdbId != null && tvdbId.isNotEmpty) 'tvdb_id': tvdbId,
          'season': '$season',
          'ep': '$episode',
        },
      );
      return _readMap(
        NetUtils.getJson(
          uri.toString(),
          timeout: const Duration(seconds: 6),
          notifyOnError: false,
        ),
      );
    });
  }

  static Future<T?> _readObject<T>(
    Future<Map<String, dynamic>?> request,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final data = await _data(request);
    return data == null ? null : parse(data as Map<String, dynamic>);
  }

  static Future<Map<String, dynamic>?> _readMap(
    Future<Map<String, dynamic>?> request,
  ) async {
    final data = await _data(request);
    return data == null ? null : data as Map<String, dynamic>;
  }

  static Future<Object?> _data(Future<Map<String, dynamic>?> request) async {
    final json = await request;
    if (json == null) return null;
    return json['code'] == 0 ? json['data'] : null;
  }

  static Future<bool> _succeeds(Future<Map<String, dynamic>?> request) async {
    final json = await request;
    return json?['code'] == 0;
  }

  static String get _watchBaseUrl => '$_baseUrl/watch';

  static Future<WatchPartyInvite> createWatchRoom(WatchPartyMedia media) async {
    final data = await _requiredData(
      NetUtils.postJson('$_watchBaseUrl/rooms', {'media': media.toJson()}),
      unavailable: '一起看服务暂时不可用',
      failed: '创建一起看房间失败',
    );
    return WatchPartyInvite.fromJson(data);
  }

  static Future<List<WatchPartyInvite>> listWatchRooms() async {
    final data = await _requiredData(
      NetUtils.getJson('$_watchBaseUrl/rooms'),
      unavailable: '一起看服务暂时不可用',
      failed: '获取一起看房间失败',
    );
    final rooms = data['rooms'] as List<dynamic>;
    return List<WatchPartyInvite>.generate(
      rooms.length,
      (index) =>
          WatchPartyInvite.fromJson(rooms[index] as Map<String, dynamic>),
      growable: false,
    );
  }

  static Future<WatchPartyInvite> getWatchInvite(String code) async {
    final data = await _requiredData(
      NetUtils.getJson('$_watchBaseUrl/invites/$code'),
      unavailable: '一起看服务暂时不可用',
      failed: '获取邀请失败',
    );
    return WatchPartyInvite.fromJson(data);
  }

  static Future<String> joinWatchRoom(String code, String nickname) async {
    final data = await _requiredData(
      NetUtils.postJson('$_watchBaseUrl/invites/$code/join', {
        'nickname': nickname,
      }),
      unavailable: '一起看服务暂时不可用',
      failed: '加入一起看房间失败',
    );
    return data['websocketUrl'] as String;
  }

  static Future<void> closeWatchRoom(String roomId) async {
    await _requiredData(
      NetUtils.deleteJson('$_watchBaseUrl/rooms/$roomId'),
      unavailable: '无法结束房间',
      failed: '无法结束房间',
    );
  }

  static Future<Map<String, dynamic>> _requiredData(
    Future<Map<String, dynamic>?> request, {
    required String unavailable,
    required String failed,
  }) async {
    final json = await request;
    if (json == null) throw StateError(unavailable);
    if (json['code'] != 0) {
      throw StateError(json['message']?.toString() ?? failed);
    }
    return json['data'] as Map<String, dynamic>;
  }
}
