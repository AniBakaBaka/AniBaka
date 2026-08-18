import 'dart:convert';
import 'dart:io';

import 'package:baka/api/api_config.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/services/collection_service.dart';
import 'package:baka/services/network_service.dart';
import 'package:baka/services/system_proxy_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

const _bangumiApiBase = 'https://api.bgm.tv';

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

class _BangumiOAuthToken {
  const _BangumiOAuthToken({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
  });

  final String accessToken;
  final String refreshToken;
  final int expiresIn;
}

class _BangumiOAuthBroker {
  const _BangumiOAuthBroker();

  Future<BangumiOAuthStart> begin() async {
    final data = await _post('/api/v1/bangumi/oauth/start', const {});
    final authorizationUrl = data['authorization_url']?.toString() ?? '';
    final state = data['state']?.toString() ?? '';
    if (authorizationUrl.isEmpty || state.isEmpty) {
      throw const BangumiSyncException('AniBaka 未返回有效的 Bangumi 登录地址');
    }
    return BangumiOAuthStart(authorizationUrl: authorizationUrl, state: state);
  }

  Future<_BangumiOAuthToken> waitForCompletion(String state) async {
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    while (DateTime.now().isBefore(deadline)) {
      final uri = Uri.parse(
        '${ApiConfig.host}/api/v1/bangumi/oauth/status',
      ).replace(queryParameters: {'state': state});
      final response = await NetUtils.get(
        uri.toString(),
        timeout: const Duration(seconds: 20),
        notifyOnError: false,
      );
      final data = _parseBrokerResponse(response);
      if (data?['status'] == 'complete') return _tokenFromJson(data!);
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw const BangumiSyncException('Bangumi 登录超时，请重试');
  }

  Future<_BangumiOAuthToken> refresh(String refreshToken) async {
    final data = await _post('/api/v1/bangumi/oauth/refresh', {
      'refresh_token': refreshToken,
    });
    return _tokenFromJson(data);
  }

  static Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await NetUtils.post('${ApiConfig.host}$path', body);
    final data = _parseBrokerResponse(response);
    if (data == null) {
      throw const BangumiSyncException('AniBaka账号未登录');
    }
    return data;
  }

  static Map<String, dynamic>? _parseBrokerResponse(String response) {
    final root = BgmUtils.parseJsonMap(response);
    if (root == null) return null;
    if (BgmUtils.toInt(root['code']) != 0) {
      final msg = root['message']?.toString() ?? 'Bangumi 登录失败';
      if (msg.contains('未配置')) {
        throw const BangumiSyncException('服务端未配置 Bangumi 授权应用，请使用 Access Token 方式连接');
      }
      throw BangumiSyncException(msg);
    }
    return BgmUtils.asMap(root['data']);
  }

  static _BangumiOAuthToken _tokenFromJson(Map<String, dynamic> json) {
    final accessToken = json['access_token']?.toString() ?? '';
    if (accessToken.isEmpty) {
      throw const BangumiSyncException('Bangumi 登录未返回有效令牌');
    }
    return _BangumiOAuthToken(
      accessToken: accessToken,
      refreshToken: json['refresh_token']?.toString() ?? '',
      expiresIn: BgmUtils.toInt(json['expires_in']) ?? 604800,
    );
  }
}

class _BangumiCollectionRecord {
  const _BangumiCollectionRecord({
    required this.subjectId,
    required this.status,
    required this.rating,
    required this.episodeWatched,
    required this.tags,
    required this.isPrivate,
    required this.title,
    this.comment,
    this.episodeTotal,
    this.subjectScore,
  });

  final int subjectId;
  final int status;
  final int rating;
  final int episodeWatched;
  final List<String> tags;
  final bool isPrivate;
  final String title;
  final String? comment;
  final int? episodeTotal;
  final double? subjectScore;

  factory _BangumiCollectionRecord.fromJson(Map<String, dynamic> json) {
    final subject = BgmUtils.asMap(json['subject']);
    final nameCn = subject?['name_cn']?.toString().trim() ?? '';
    final name = subject?['name']?.toString().trim() ?? '';
    final rawTags = json['tags'];
    final tags = rawTags is List
        ? rawTags.map((e) => e.toString()).toList()
        : const <String>[];
    return _BangumiCollectionRecord(
      subjectId: BgmUtils.toInt(json['subject_id']) ?? 0,
      status: BgmUtils.toInt(json['type']) ?? CollectionStatus.wish.value,
      rating: BgmUtils.toInt(json['rate']) ?? 0,
      episodeWatched: BgmUtils.toInt(json['ep_status']) ?? 0,
      tags: tags,
      isPrivate: json['private'] == true,
      title: nameCn.isNotEmpty ? nameCn : name,
      comment: json['comment']?.toString().trim().isNotEmpty == true
          ? json['comment'].toString().trim()
          : null,
      episodeTotal: BgmUtils.toInt(subject?['eps']),
      subjectScore: BgmUtils.toDouble(subject?['score']),
    );
  }

  AnimeCollection toAnimeCollection() => AnimeCollection(
    bgmId: subjectId,
    status: status,
    rating: rating,
    comment: comment,
    epTotal: episodeTotal,
    epWatched: episodeWatched,
    tags: tags.isEmpty ? null : tags.join(','),
    isPrivate: isPrivate,
    bgmRating: subjectScore,
    bgmImage: BgmUtils.bgmCoverProxyUrl(subjectId),
    bgmTitle: title,
  );

  String get fingerprint => _fingerprint(
    status: status,
    rating: rating,
    comment: comment,
    episodeWatched: episodeWatched,
    tags: tags,
    isPrivate: isPrivate,
  );
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
    final episode = BgmUtils.asMap(json['episode']);
    return _BangumiEpisodeRecord(
      id: BgmUtils.toInt(episode?['id']) ?? 0,
      collectionType: BgmUtils.toInt(json['type']) ?? 0,
      sort: BgmUtils.toDouble(episode?['sort']) ?? 0,
    );
  }
}

class _BangumiApi {
  _BangumiApi() : _client = IOClient(SystemProxyService.createHttpClient());

  final http.Client _client;

  Future<BangumiAccount> getMe(String token) async {
    final json = await _request('GET', '/v0/me', token: token);
    return BangumiAccount.fromJson(BgmUtils.parseJsonMap(json) ?? const {});
  }

  Future<_BangumiCollectionRecord?> getCollection(
    String token,
    int subjectId,
  ) async {
    try {
      final json = await _request(
        'GET',
        '/v0/users/-/collections/$subjectId',
        token: token,
      );
      final map = BgmUtils.parseJsonMap(json);
      return map == null ? null : _BangumiCollectionRecord.fromJson(map);
    } on BangumiSyncException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<List<_BangumiCollectionRecord>> getAnimeCollections(
    String token,
    String username,
  ) async {
    const limit = 100;
    var offset = 0;
    var total = 1;
    final result = <_BangumiCollectionRecord>[];

    while (offset < total) {
      final path = Uri(
        path: '/v0/users/$username/collections',
        queryParameters: {
          'subject_type': '2',
          'limit': '$limit',
          'offset': '$offset',
        },
      ).toString();
      final page =
          BgmUtils.parseJsonMap(await _request('GET', path, token: token)) ??
          const <String, dynamic>{};
      total = BgmUtils.toInt(page['total']) ?? 0;
      final items = BgmUtils.parseJsonList(page['data']);
      for (final item in items) {
        final map = BgmUtils.asMap(item);
        if (map == null) continue;
        final record = _BangumiCollectionRecord.fromJson(map);
        if (record.subjectId > 0) result.add(record);
      }
      if (items.isEmpty) break;
      offset += items.length;
    }
    return result;
  }

  Future<void> putCollection(String token, AnimeCollection collection) async {
    final subjectId = collection.bgmId;
    if (subjectId == null || subjectId <= 0) return;
    await _request(
      'POST',
      '/v0/users/-/collections/$subjectId',
      token: token,
      body: {
        'type': collection.status,
        'rate': collection.rating,
        'comment': collection.comment ?? '',
        'private': collection.isPrivate,
        'tags': _parseTags(collection.tags),
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
    final page =
        BgmUtils.parseJsonMap(await _request('GET', path, token: token)) ??
        const <String, dynamic>{};
    final episodes = <_BangumiEpisodeRecord>[];
    for (final item in BgmUtils.parseJsonList(page['data'])) {
      final map = BgmUtils.asMap(item);
      if (map == null) continue;
      final episode = _BangumiEpisodeRecord.fromJson(map);
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
    return _request(
      'PATCH',
      '/v0/users/-/collections/$subjectId/episodes',
      token: token,
      body: {'episode_id': episodeIds, 'type': type},
    ).then((_) {});
  }

  Future<dynamic> _request(
    String method,
    String path, {
    required String token,
    Map<String, dynamic>? body,
  }) async {
    final request = http.Request(method, Uri.parse('$_bangumiApiBase$path'));
    request.headers.addAll({
      HttpHeaders.authorizationHeader: 'Bearer $token',
      HttpHeaders.acceptHeader: 'application/json',
      HttpHeaders.userAgentHeader:
          'AniBakaBaka/AniBaka/${Instances.appVersion} '
          '(${Platform.operatingSystem}) '
          '(https://github.com/AniBakaBaka/AniBaka)',
      if (body != null) HttpHeaders.contentTypeHeader: 'application/json',
    });
    if (body != null) request.body = jsonEncode(body);

    http.StreamedResponse streamed;
    try {
      streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 25));
    } on BangumiSyncException {
      rethrow;
    } catch (_) {
      throw const BangumiSyncException('无法连接 Bangumi；部分网络环境可能需要先开启代理软件');
    }
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const BangumiSyncException('Bangumi Access Token 无效、已过期或权限不足');
      }
      var message = 'Bangumi 请求失败（${response.statusCode}）';
      try {
        final error = BgmUtils.parseJsonMap(response.body) ?? const {};
        final detail = error['description'] ?? error['title'];
        if (detail != null && detail.toString().isNotEmpty) {
          message = detail.toString();
        }
      } catch (_) {}
      throw BangumiSyncException(message, statusCode: response.statusCode);
    }
    if (response.body.trim().isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw const BangumiSyncException('Bangumi 返回了无法识别的数据');
    }
  }
}

class BangumiSyncReport {
  const BangumiSyncReport({
    required this.imported,
    required this.exported,
    required this.unchanged,
    required this.skippedDeletions,
    required this.conflicts,
    required this.failed,
  });

  final int imported;
  final int exported;
  final int unchanged;
  final int skippedDeletions;
  final int conflicts;
  final int failed;

  int get total => imported + exported + unchanged + skippedDeletions + failed;

  String get summary {
    final parts = <String>[
      if (imported > 0) '导入 $imported',
      if (exported > 0) '上传 $exported',
      if (unchanged > 0) '无需更新 $unchanged',
      if (skippedDeletions > 0) '保留单端删除 $skippedDeletions',
      if (conflicts > 0) '冲突 $conflicts（以 Bangumi 为准）',
      if (failed > 0) '失败 $failed',
    ];
    return parts.isEmpty ? '没有可同步的追番记录' : parts.join('，');
  }
}

class BangumiSyncService {
  BangumiSyncService._();

  static final BangumiSyncService instance = BangumiSyncService._();

  static const _tokenKey = 'bangumi_access_token';
  static const _refreshTokenKey = 'bangumi_refresh_token';
  static const _tokenExpiresAtKey = 'bangumi_token_expires_at';
  static const _accountKey = 'bangumi_account';
  static const _snapshotKey = 'bangumi_sync_snapshot';
  static const _pendingPushKey = 'bangumi_sync_pending_push';
  static const _lastSyncKey = 'bangumi_last_sync_at';
  static const _localSnapshotKey = 'bangumi_local_sync_snapshot';
  static const _localPendingPushKey = 'bangumi_local_sync_pending_push';
  static const _localLastSyncKey = 'bangumi_local_last_sync_at';
  static const _autoProgressKey = 'bangumi_auto_episode_progress';
  static const _autoMarkEpisodeKey = 'bangumi_auto_mark_episode';
  static const _quickMarkGridKey = 'bangumi_quick_mark_grid';

  final _BangumiApi _api = _BangumiApi();
  final _BangumiOAuthBroker _oauthBroker = const _BangumiOAuthBroker();

  bool get isLocalMode => Instances.userToken.isEmpty;

  bool get autoMarkEpisode => Instances.sp.getBool(_autoMarkEpisodeKey) ?? true;

  Future<void> setAutoMarkEpisode(bool value) async {
    await Instances.sp.setBool(_autoMarkEpisodeKey, value);
  }

  bool get quickMarkGrid => Instances.sp.getBool(_quickMarkGridKey) ?? true;

  Future<void> setQuickMarkGrid(bool value) async {
    await Instances.sp.setBool(_quickMarkGridKey, value);
  }

  String get _currentSnapshotKey =>
      isLocalMode ? _localSnapshotKey : _snapshotKey;
  String get _currentPendingPushKey =>
      isLocalMode ? _localPendingPushKey : _pendingPushKey;
  String get _currentLastSyncKey =>
      isLocalMode ? _localLastSyncKey : _lastSyncKey;

  bool get isConnected => (Instances.sp.getString(_tokenKey) ?? '').isNotEmpty;

  BangumiAccount? get account {
    final value = Instances.sp.getString(_accountKey);
    if (value == null || value.isEmpty) return null;
    try {
      return BangumiAccount.fromJson(
        BgmUtils.parseJsonMap(jsonDecode(value)) ?? const {},
      );
    } catch (_) {
      return null;
    }
  }

  DateTime? get lastSyncAt {
    return DateTime.tryParse(Instances.sp.getString(_currentLastSyncKey) ?? '');
  }

  Future<BangumiOAuthStart> beginOAuthLogin() async {
    return _oauthBroker.begin();
  }

  Future<BangumiAccount> completeOAuthLogin(String state) async {
    final token = await _oauthBroker.waitForCompletion(state);
    final user = await _api.getMe(token.accessToken);
    if (user.username.isEmpty) {
      throw const BangumiSyncException('无法识别 Bangumi 账号');
    }
    await _saveOAuthToken(token);
    await Instances.sp.setString(_accountKey, jsonEncode(user.toJson()));
    return user;
  }

  Future<BangumiAccount> connect(String rawToken) async {
    final token = rawToken.trim().replaceFirst(
      RegExp(r'^Bearer\s+', caseSensitive: false),
      '',
    );
    if (token.isEmpty) {
      throw const BangumiSyncException('请输入 Bangumi Access Token');
    }
    final user = await _api.getMe(token);
    if (user.username.isEmpty) {
      throw const BangumiSyncException('无法识别 Bangumi 账号');
    }
    await Instances.sp.setString(_tokenKey, token);
    await Instances.sp.remove(_refreshTokenKey);
    await Instances.sp.remove(_tokenExpiresAtKey);
    await Instances.sp.setString(_accountKey, jsonEncode(user.toJson()));
    return user;
  }

  Future<void> disconnect() async {
    await Future.wait([
      Instances.sp.remove(_tokenKey),
      Instances.sp.remove(_refreshTokenKey),
      Instances.sp.remove(_tokenExpiresAtKey),
      Instances.sp.remove(_accountKey),
      Instances.sp.remove(_snapshotKey),
      Instances.sp.remove(_pendingPushKey),
      Instances.sp.remove(_lastSyncKey),
      Instances.sp.remove(_localSnapshotKey),
      Instances.sp.remove(_localPendingPushKey),
      Instances.sp.remove(_localLastSyncKey),
      Instances.sp.remove(_autoProgressKey),
    ]);
  }

  /// 读取当前 Bangumi 账号的单条收藏，供详情页显示真实状态。
  Future<AnimeCollection?> getCollection(int subjectId) async {
    final token = await _getAccessToken();
    return (await _api.getCollection(token, subjectId))?.toAnimeCollection();
  }

  /// 读取当前 Bangumi 账号的全部动画收藏。
  Future<List<AnimeCollection>> getCollections() async {
    final token = await _getAccessToken();
    var user = account;
    if (user == null) {
      user = await _api.getMe(token);
      await Instances.sp.setString(_accountKey, jsonEncode(user.toJson()));
    }
    return [
      for (final item in await _api.getAnimeCollections(token, user.username))
        item.toAnimeCollection(),
    ];
  }

  /// 直接写入 Bangumi 收藏状态；Access Token 只保存在本机。
  Future<void> updateCollection(AnimeCollection collection) async {
    final token = await _getAccessToken();
    await _api.putCollection(token, collection);
  }

  Future<void> updateEpisodeProgress(int subjectId, int watched) async {
    final token = await _getAccessToken();
    await _api.putEpisodeProgress(token, subjectId, watched);
  }

  /// 播放完成后把集数推进到 Bangumi。相同或更早集数不会重复请求。
  Future<void> markEpisodeWatched({
    required int subjectId,
    required int watched,
    AnimeCollection? metadata,
  }) async {
    if (watched <= 0) return;
    final progress = _loadAutoProgress();
    if ((progress['$subjectId'] ?? 0) >= watched) return;

    final token = await _getAccessToken();
    final current = await _api.getCollection(token, subjectId);
    if (current != null && current.episodeWatched >= watched) {
      progress['$subjectId'] = current.episodeWatched;
      await Instances.sp.setString(_autoProgressKey, jsonEncode(progress));
      return;
    }
    if (current == null || current.status == CollectionStatus.wish.value) {
      await _api.putCollection(
        token,
        AnimeCollection(
          bgmId: subjectId,
          status: CollectionStatus.doing.value,
          epWatched: watched,
          postTitle: metadata?.postTitle,
          postCover: metadata?.postCover,
          bgmImage: metadata?.bgmImage,
          bgmTitle: metadata?.bgmTitle,
        ),
      );
    }
    await _api.putEpisodeProgress(token, subjectId, watched);
    progress['$subjectId'] = watched;
    await Instances.sp.setString(_autoProgressKey, jsonEncode(progress));
  }

  Future<BangumiSyncReport> sync({void Function(String)? onProgress}) async {
    final token = await _getAccessToken();
    if (token.isEmpty) {
      throw const BangumiSyncException('请先连接 Bangumi 账号');
    }
    onProgress?.call('正在读取 Bangumi 追番记录…');
    var user = account;
    if (user == null) {
      user = await _api.getMe(token);
      await Instances.sp.setString(_accountKey, jsonEncode(user.toJson()));
    }
    final remote = await _api.getAnimeCollections(token, user.username);
    onProgress?.call(isLocalMode ? '正在读取本机追番记录…' : '正在读取 AniBaka 追番记录…');
    final local = await CollectionService.getAll(refreshBangumi: false);

    final items =
        <int, ({_BangumiCollectionRecord? remote, AnimeCollection? local})>{
          for (final item in remote)
            item.subjectId: (remote: item, local: null),
        };
    for (final item in local) {
      final id = item.bgmId;
      if (id == null || id <= 0) continue;
      items[id] = (remote: items[id]?.remote, local: item);
    }
    final ids = items.keys.toList()..sort();
    final snapshots = _loadSnapshots();
    final pendingPush = _loadPendingPush();
    var imported = 0;
    var exported = 0;
    var unchanged = 0;
    var skippedDeletions = 0;
    var conflicts = 0;
    var failed = 0;
    Object? firstError;

    for (var index = 0; index < ids.length; index++) {
      final id = ids[index];
      final pair = items[id]!;
      final remoteItem = pair.remote;
      final localItem = pair.local;
      onProgress?.call('正在同步 ${index + 1}/${ids.length}…');

      final remoteFingerprint = remoteItem?.fingerprint;
      final localFingerprint = localItem == null
          ? null
          : _localFingerprint(localItem);
      final previous = snapshots['$id'];

      if (previous != null &&
          ((remoteItem == null && localFingerprint == previous) ||
              (localItem == null && remoteFingerprint == previous))) {
        pendingPush.remove(id);
        skippedDeletions++;
        continue;
      }

      if (remoteFingerprint == localFingerprint && remoteFingerprint != null) {
        snapshots['$id'] = remoteFingerprint;
        pendingPush.remove(id);
        unchanged++;
        continue;
      }

      final preferLocal =
          pendingPush.contains(id) ||
          (previous != null &&
              localFingerprint != null &&
              localFingerprint != previous &&
              remoteFingerprint == previous);

      try {
        if (remoteItem == null || (localItem != null && preferLocal)) {
          if (localItem == null) continue;
          await _api.putCollection(token, localItem);
          if (localItem.epWatched != null) {
            await _api.putEpisodeProgress(token, id, localItem.epWatched!);
          }
          snapshots['$id'] = localFingerprint!;
          pendingPush.remove(id);
          exported++;
        } else {
          final localChanged = previous != null && localFingerprint != previous;
          final remoteChanged =
              previous != null && remoteFingerprint != previous;
          if (localChanged && remoteChanged) conflicts++;
          if (await CollectionService.addOrUpdate(
                remoteItem.toAnimeCollection(),
                syncBangumi: false,
              ) ==
              null) {
            throw BangumiSyncException(
              isLocalMode ? '本机保存追番记录失败' : 'AniBaka 保存追番记录失败',
            );
          }
          snapshots['$id'] = remoteFingerprint!;
          pendingPush.remove(id);
          imported++;
        }
      } catch (error) {
        firstError ??= error;
        if (preferLocal || remoteItem == null) pendingPush.add(id);
        failed++;
      }
    }

    await Instances.sp.setString(_currentSnapshotKey, jsonEncode(snapshots));
    await Instances.sp.setString(
      _currentPendingPushKey,
      jsonEncode(pendingPush.toList()..sort()),
    );
    if (failed > 0 &&
        imported == 0 &&
        exported == 0 &&
        unchanged == 0 &&
        skippedDeletions == 0) {
      if (firstError is BangumiSyncException) throw firstError;
      throw const BangumiSyncException('同步失败，请稍后重试');
    }
    final syncedAt = DateTime.now().toUtc();
    await Instances.sp.setString(
      _currentLastSyncKey,
      syncedAt.toIso8601String(),
    );
    return BangumiSyncReport(
      imported: imported,
      exported: exported,
      unchanged: unchanged,
      skippedDeletions: skippedDeletions,
      conflicts: conflicts,
      failed: failed,
    );
  }

  Future<String> _getAccessToken() async {
    final accessToken = Instances.sp.getString(_tokenKey) ?? '';
    if (accessToken.isEmpty) {
      throw const BangumiSyncException('请先登录 Bangumi');
    }
    final expiresAt = DateTime.tryParse(
      Instances.sp.getString(_tokenExpiresAtKey) ?? '',
    );
    if (expiresAt == null ||
        expiresAt.isAfter(
          DateTime.now().toUtc().add(const Duration(minutes: 1)),
        )) {
      return accessToken;
    }

    final refreshToken = Instances.sp.getString(_refreshTokenKey) ?? '';
    if (refreshToken.isEmpty) {
      throw const BangumiSyncException('Bangumi 登录已过期，请重新登录');
    }
    final refreshed = await _oauthBroker.refresh(refreshToken);
    final effectiveToken = refreshed.refreshToken.isEmpty
        ? _BangumiOAuthToken(
            accessToken: refreshed.accessToken,
            refreshToken: refreshToken,
            expiresIn: refreshed.expiresIn,
          )
        : refreshed;
    await _saveOAuthToken(effectiveToken);
    return effectiveToken.accessToken;
  }

  Future<void> _saveOAuthToken(_BangumiOAuthToken token) async {
    await Instances.sp.setString(_tokenKey, token.accessToken);
    if (token.refreshToken.isNotEmpty) {
      await Instances.sp.setString(_refreshTokenKey, token.refreshToken);
    }
    await Instances.sp.setString(
      _tokenExpiresAtKey,
      DateTime.now()
          .toUtc()
          .add(Duration(seconds: token.expiresIn))
          .toIso8601String(),
    );
  }

  Map<String, String> _loadSnapshots() {
    final value = Instances.sp.getString(_currentSnapshotKey);
    if (value == null || value.isEmpty) return {};
    try {
      final json = BgmUtils.parseJsonMap(jsonDecode(value)) ?? const {};
      return json.map((key, value) => MapEntry(key, value.toString()));
    } catch (_) {
      return {};
    }
  }

  Set<int> _loadPendingPush() {
    final value = Instances.sp.getString(_currentPendingPushKey);
    if (value == null || value.isEmpty) return {};
    try {
      return BgmUtils.parseJsonList(
        jsonDecode(value),
      ).map(BgmUtils.toInt).whereType<int>().toSet();
    } catch (_) {
      return {};
    }
  }

  Map<String, int> _loadAutoProgress() {
    final value = Instances.sp.getString(_autoProgressKey);
    if (value == null || value.isEmpty) return {};
    try {
      final json = BgmUtils.parseJsonMap(jsonDecode(value)) ?? const {};
      return json.map(
        (key, value) => MapEntry(key, BgmUtils.toInt(value) ?? 0),
      );
    } catch (_) {
      return {};
    }
  }
}

String _localFingerprint(AnimeCollection collection) => _fingerprint(
  status: collection.status,
  rating: collection.rating,
  comment: collection.comment,
  episodeWatched: collection.epWatched ?? 0,
  tags: _parseTags(collection.tags),
  isPrivate: collection.isPrivate,
);

String _fingerprint({
  required int status,
  required int rating,
  required String? comment,
  required int episodeWatched,
  required List<String> tags,
  required bool isPrivate,
}) {
  final tagStr = tags.isEmpty
      ? ''
      : (tags.length == 1 ? tags.first : (List<String>.from(tags)..sort()).join(','));
  return '$status|$rating|${comment?.trim() ?? ''}|$episodeWatched|$tagStr|${isPrivate ? 1 : 0}';
}

List<String> _parseTags(String? value) {
  if (value == null || value.trim().isEmpty) return const [];
  return value
      .split(RegExp(r'[,，\s]+'))
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toSet()
      .toList();
}
