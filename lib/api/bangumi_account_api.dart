import 'package:baka/utils/json_values.dart';
import 'dart:async';
import 'dart:io';

import 'package:baka/api/api_config.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/core/http_request.dart';
import 'package:baka/core/system_proxy.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

const _bangumiApiBase = 'https://api.bgm.tv';

/// OAuth can span browser/app switches. A failed request must not discard the
/// whole login, while cancellation and terminal authentication errors still do.
Future<T> _waitForOAuth<T>(
  Uri uri,
  Future<T?> Function(Future<void> abort) read, {
  required Duration timeout,
  required String timeoutMessage,
  Future<void>? abortTrigger,
}) async {
  final abort = Completer<void>();
  var timedOut = false;
  void stop() {
    if (!abort.isCompleted) abort.complete();
  }

  final timer = Timer(timeout, () {
    timedOut = true;
    stop();
  });
  abortTrigger?.then((_) => stop());
  final cancelled = abort.future.then<T?>(
    (_) => throw http.RequestAbortedException(uri),
  );
  try {
    while (!abort.isCompleted) {
      try {
        final result = await Future.any([read(abort.future), cancelled]);
        if (abort.isCompleted) break;
        if (result != null) return result;
      } catch (error) {
        if (error is http.RequestAbortedException) rethrow;
        final status = switch (error) {
          ApiException() => error.statusCode,
          BangumiSyncException() => error.statusCode,
          _ => null,
        };
        if (error is! TimeoutException &&
            error is! SocketException &&
            error is! http.ClientException &&
            status != 408 &&
            status != 429 &&
            !(status != null && status >= 500 && status <= 599)) {
          rethrow;
        }
      }
      await Future.any([
        Future<void>.delayed(const Duration(seconds: 2)),
        abort.future,
      ]);
    }
    throw http.RequestAbortedException(uri);
  } on http.RequestAbortedException {
    if (timedOut) throw TimeoutException(timeoutMessage, timeout);
    rethrow;
  } finally {
    timer.cancel();
  }
}

class BangumiSyncException implements Exception {
  const BangumiSyncException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class BangumiAccount {
  const BangumiAccount({
    required this.username,
    required this.nickname,
    this.avatarUrl,
  });

  final String username;
  final String nickname;
  final String? avatarUrl;

  factory BangumiAccount.fromJson(Map<String, dynamic> json) {
    final avatar = json['avatar'];
    String? avatarUrl;
    if (avatar is Map) {
      avatarUrl = avatar['large']?.toString();
    } else {
      avatarUrl = json['avatar_url']?.toString();
    }
    return BangumiAccount(
      username: json['username']?.toString() ?? '',
      nickname: json['nickname']?.toString() ?? '',
      avatarUrl: avatarUrl,
    );
  }

  Map<String, dynamic> toJson() => {
    'username': username,
    'nickname': nickname,
    if (avatarUrl != null) 'avatar_url': avatarUrl,
  };
}

class BangumiOAuthStart {
  const BangumiOAuthStart({
    required this.authorizationUrl,
    required this.state,
  });

  final String authorizationUrl;
  final String state;
}

class BangumiOAuthToken {
  const BangumiOAuthToken({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
  });

  final String accessToken;
  final String refreshToken;
  final int expiresIn;
}

class BangumiOAuthBroker {
  const BangumiOAuthBroker();

  Future<BangumiOAuthStart> begin({Future<void>? abortTrigger}) async {
    final data = await _post(
      '/api/v1/bangumi/oauth/start',
      const {},
      abortTrigger: abortTrigger,
    );
    final authorizationUrl = data['authorization_url']?.toString() ?? '';
    final state = data['state']?.toString() ?? '';
    if (authorizationUrl.isEmpty || state.isEmpty) {
      throw const BangumiSyncException('AniBaka 未返回有效的 Bangumi 登录地址');
    }
    return BangumiOAuthStart(authorizationUrl: authorizationUrl, state: state);
  }

  Future<BangumiOAuthToken> waitForCompletion(
    String state, {
    Future<void>? abortTrigger,
    Duration timeout = const Duration(minutes: 10),
  }) {
    final uri = Uri.parse(
      '${ApiConfig.host}/api/v1/bangumi/oauth/status',
    ).replace(queryParameters: {'state': state});
    return _waitForOAuth(
      uri,
      (abort) async {
        final root = await apiTransport.getJson<Map<String, dynamic>>(
          uri.toString(),
          notifyOnError: false,
          abortTrigger: abort,
        );
        final data = _parseBrokerResponse(root);
        return data['status'] == 'complete' ? _tokenFromJson(data) : null;
      },
      abortTrigger: abortTrigger,
      timeout: timeout,
      timeoutMessage: '等待 AniBaka 授权结果超时，请检查网络后重试',
    );
  }

  Future<void> acknowledge(String state) async {
    await _post('/api/v1/bangumi/oauth/ack', {'state': state});
  }

  Future<BangumiOAuthToken> refresh(String refreshToken) async {
    final data = await _post('/api/v1/bangumi/oauth/refresh', {
      'refresh_token': refreshToken,
    });
    return _tokenFromJson(data);
  }

  static Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    Future<void>? abortTrigger,
  }) async {
    return _parseBrokerResponse(
      await apiTransport.postJson<Map<String, dynamic>>(
        '${ApiConfig.host}$path',
        body,
        notifyOnError: false,
        abortTrigger: abortTrigger,
      ),
    );
  }

  static Map<String, dynamic> _parseBrokerResponse(Map<String, dynamic> root) {
    try {
      return ApiTransport.unwrap<Map<String, dynamic>>(root);
    } on ApiException catch (error) {
      if (error.message.contains('未配置')) {
        throw const BangumiSyncException(
          '服务端未配置 Bangumi 授权应用，请使用 Access Token 方式连接',
        );
      }
      rethrow;
    }
  }

  static BangumiOAuthToken _tokenFromJson(Map<String, dynamic> json) {
    final accessToken = json['access_token']?.toString() ?? '';
    if (accessToken.isEmpty) {
      throw const BangumiSyncException('Bangumi 登录未返回有效令牌');
    }
    return BangumiOAuthToken(
      accessToken: accessToken,
      refreshToken: json['refresh_token']?.toString() ?? '',
      expiresIn: toInt(json['expires_in']) ?? 604800,
    );
  }
}

class _BangumiEpisodeRecord {
  const _BangumiEpisodeRecord({
    required this.id,
    required this.collectionType,
    required this.sort,
  });

  final int id;
  final int collectionType;
  final double sort;

  factory _BangumiEpisodeRecord.fromJson(Map<String, dynamic> json) {
    final episode = json['episode'] as Map<String, dynamic>;
    return _BangumiEpisodeRecord(
      id: episode['id'] as int,
      collectionType: json['type'] as int,
      sort: (episode['sort'] as num).toDouble(),
    );
  }
}

class BangumiApi {
  BangumiApi({http.Client? client})
    : _client = client ?? IOClient(SystemProxyService.createHttpClient());

  final http.Client _client;
  final String _userAgent =
      'AniBakaBaka/AniBaka/${Instances.appVersion} '
      '(${Platform.operatingSystem}) (https://github.com/AniBakaBaka/AniBaka)';
  void close() => _client.close();

  Future<BangumiAccount> getMe(
    String token, {
    Future<void>? abortTrigger,
    bool retryForOAuth = false,
  }) async {
    if (retryForOAuth) {
      return _waitForOAuth(
        Uri.parse('$_bangumiApiBase/v0/me'),
        (abort) => getMe(token, abortTrigger: abort),
        abortTrigger: abortTrigger,
        timeout: const Duration(minutes: 2),
        timeoutMessage: '读取 Bangumi 账号超时，请检查网络后重试',
      );
    }
    final json = await _request<Map<String, dynamic>>(
      'GET',
      '/v0/me',
      token: token,
      abortTrigger: abortTrigger,
    );
    return BangumiAccount.fromJson(json);
  }

  Future<AnimeCollection?> getCollection(String token, int subjectId) async {
    try {
      final json = await _request<Map<String, dynamic>>(
        'GET',
        '/v0/users/-/collections/$subjectId',
        token: token,
      );
      return AnimeCollection.fromBangumi(json);
    } on BangumiSyncException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<List<AnimeCollection>> getAnimeCollections(
    String token,
    String username,
  ) async {
    const limit = 100;
    var offset = 0;
    var total = 1;
    final result = <AnimeCollection>[];

    while (offset < total) {
      final path = Uri(
        path: '/v0/users/$username/collections',
        queryParameters: {
          'subject_type': '2',
          'limit': '$limit',
          'offset': '$offset',
        },
      ).toString();
      final page = await _request<Map<String, dynamic>>(
        'GET',
        path,
        token: token,
      );
      total = page['total'] as int;
      final items = page['data'] as List? ?? const [];
      for (final item in items) {
        final record = AnimeCollection.fromBangumi(
          item as Map<String, dynamic>,
        );
        if ((record.bgmId ?? 0) > 0) result.add(record);
      }
      if (items.isEmpty) break;
      offset += items.length;
    }
    return result;
  }

  Future<void> putCollection(String token, AnimeCollection collection) async {
    final subjectId = collection.bgmId;
    if (subjectId == null || subjectId <= 0) return;
    await _request<void>(
      'POST',
      '/v0/users/-/collections/$subjectId',
      token: token,
      body: {
        'type': collection.status,
        'rate': collection.rating,
        'comment': collection.comment ?? '',
        'private': collection.isPrivate,
        'tags': collection.tags,
      },
    );
  }

  Future<void> putEpisodeProgress(
    String token,
    int subjectId,
    int watched,
  ) async {
    final path = Uri(
      path: '/v0/users/-/collections/$subjectId/episodes',
      queryParameters: const {'episode_type': '0', 'limit': '1000'},
    ).toString();
    final page = await _request<Map<String, dynamic>>(
      'GET',
      path,
      token: token,
    );
    final episodes = <_BangumiEpisodeRecord>[];
    for (final item in page['data'] as List? ?? const []) {
      final episode = _BangumiEpisodeRecord.fromJson(
        item as Map<String, dynamic>,
      );
      if (episode.id > 0) episodes.add(episode);
    }
    episodes.sort((a, b) => a.sort.compareTo(b.sort));

    final watchedCount = watched.clamp(0, episodes.length);
    final doneIds = <int>[];
    final resetIds = <int>[];
    for (var index = 0; index < episodes.length; index++) {
      final episode = episodes[index];
      if (index < watchedCount) {
        if (episode.collectionType != 2) doneIds.add(episode.id);
      } else if (episode.collectionType == 2) {
        resetIds.add(episode.id);
      }
    }
    if (doneIds.isNotEmpty) {
      await _putEpisodes(token, subjectId, doneIds, 2);
    }
    if (resetIds.isNotEmpty) {
      await _putEpisodes(token, subjectId, resetIds, 0);
    }
  }

  Future<void> _putEpisodes(
    String token,
    int subjectId,
    List<int> episodeIds,
    int type,
  ) {
    return _request<void>(
      'PATCH',
      '/v0/users/-/collections/$subjectId/episodes',
      token: token,
      body: {'episode_id': episodeIds, 'type': type},
    );
  }

  Future<T> _request<T>(
    String method,
    String path, {
    required String token,
    Map<String, dynamic>? body,
    Future<void>? abortTrigger,
  }) async {
    try {
      final response = await sendHttp(
        _client,
        method,
        Uri.parse('$_bangumiApiBase$path'),
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer $token',
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.userAgentHeader: _userAgent,
        },
        data: body,
        abortTrigger: abortTrigger,
      );
      // Bangumi mutation endpoints may successfully return 204 with no body.
      if (response.body.isEmpty && null is T) return null as T;
      return decodeJson<T>(response.body);
    } on ApiException catch (error) {
      final status = error.statusCode;
      if (status == 401 || status == 403) {
        throw BangumiSyncException(
          'Bangumi Access Token 无效、已过期或权限不足',
          statusCode: status,
        );
      }
      var message = 'Bangumi 请求失败（$status）';
      try {
        final json = decodeJson<Map<String, dynamic>>(error.responseBody ?? '');
        final detail = json['description'] ?? json['title'];
        if (detail is String && detail.isNotEmpty) message = detail;
      } on FormatException {
        /* Non-JSON error bodies keep the HTTP status. */
      }
      throw BangumiSyncException(message, statusCode: status);
    }
  }
}

String localCollectionFingerprint(AnimeCollection collection) {
  final tags = collection.tags;
  final tagStr = tags.length < 2
      ? tags.join()
      : (List<String>.of(tags)..sort()).join(',');
  return '${collection.status}|${collection.rating}|${collection.comment?.trim() ?? ''}|${collection.epWatched ?? 0}|$tagStr|${collection.isPrivate ? 1 : 0}';
}
