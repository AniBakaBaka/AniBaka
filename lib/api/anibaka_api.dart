import 'dart:convert';

import 'package:baka/api/api_config.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/play_history.dart';
import 'package:baka/services/network_service.dart';

/// AniBaka v1 API 的唯一客户端入口。
final class AniBakaApi {
  AniBakaApi._();

  static const _animeDetailCacheLimit = 24;
  static const _episodeStillsCacheLimit = 24;

  static final Map<int, Future<Map<String, dynamic>?>> _animeDetails = {};
  static final Map<
    ({int? bgmId, int? tmdbId, String? tvdbId, int season, int episode}),
    Future<Map<String, dynamic>?>
  >
  _episodeStills = {};

  static String get _baseUrl => '${ApiConfig.host}/api/v1';

  static Future<AnimeCollection?> saveCollection(AnimeCollection collection) =>
      _readObject(
        NetUtils.post('$_baseUrl/collection', collection.toJson()),
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
    return _readObject(
      NetUtils.get(uri.toString()),
      CollectionListResponse.fromJson,
    );
  }

  static Future<CollectionStats?> getCollectionStats() => _readObject(
    NetUtils.get('$_baseUrl/collection/stats'),
    CollectionStats.fromJson,
  );

  static Future<AnimeCollection?> getCollectionByPostId(int postId) =>
      _readObject(
        NetUtils.get('$_baseUrl/collection/post/$postId'),
        AnimeCollection.fromJson,
      );

  static Future<AnimeCollection?> getCollectionByBgmId(int bgmId) =>
      _readObject(
        NetUtils.get('$_baseUrl/bgm-collection/$bgmId'),
        AnimeCollection.fromJson,
      );

  static Future<bool> deleteCollection(int postId) =>
      _succeeds(NetUtils.delete('$_baseUrl/collection/$postId'));

  static Future<bool> deleteCollectionByBgmId(int bgmId) =>
      _succeeds(NetUtils.delete('$_baseUrl/bgm-collection/$bgmId'));

  static Future<PlayHistory?> savePlayHistory(PlayHistory history) =>
      _readObject(
        NetUtils.post('$_baseUrl/play-history', history.toJson()),
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
    return _readObject(
      NetUtils.get(uri.toString()),
      PlayHistoryListResponse.fromJson,
    );
  }

  static Future<bool> clearPlayHistory() =>
      _succeeds(NetUtils.delete('$_baseUrl/play-history-clear'));

  static Future<Map<String, dynamic>?> getAnimeDetail(int bgmId) => _remember(
    _animeDetails,
    bgmId,
    _animeDetailCacheLimit,
    () => _readMap(
      NetUtils.get(
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
    return _remember(_episodeStills, key, _episodeStillsCacheLimit, () {
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
        NetUtils.get(
          uri.toString(),
          timeout: const Duration(seconds: 6),
          notifyOnError: false,
        ),
      );
    });
  }

  static Future<T?> _readObject<T>(
    Future<String> request,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final data = await _data(request);
    return data == null ? null : parse(data as Map<String, dynamic>);
  }

  static Future<Map<String, dynamic>?> _readMap(Future<String> request) async {
    final data = await _data(request);
    return data == null ? null : data as Map<String, dynamic>;
  }

  static Future<Object?> _data(Future<String> request) async {
    final response = await request;
    if (response.isEmpty) return null;
    final json = jsonDecode(response) as Map<String, dynamic>;
    return json['code'] == 0 ? json['data'] : null;
  }

  static Future<bool> _succeeds(Future<String> request) async {
    final response = await request;
    if (response.isEmpty) return false;
    return (jsonDecode(response) as Map<String, dynamic>)['code'] == 0;
  }

  static Future<V?> _remember<K, V>(
    Map<K, Future<V?>> cache,
    K key,
    int limit,
    Future<V?> Function() load,
  ) {
    final cached = cache.remove(key);
    if (cached != null) {
      cache[key] = cached;
      return cached;
    }
    if (cache.length >= limit) cache.remove(cache.keys.first);

    late final Future<V?> request;
    request = load().then(
      (value) {
        if (value == null && identical(cache[key], request)) cache.remove(key);
        return value;
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(cache[key], request)) cache.remove(key);
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    cache[key] = request;
    return request;
  }
}
