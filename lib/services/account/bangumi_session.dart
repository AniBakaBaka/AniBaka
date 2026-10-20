import 'package:baka/utils/json_values.dart';
import 'package:baka/api/bangumi_account_api.dart';
import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/models/collection.dart';

late BangumiSession bangumiSession;

class BangumiSession {
  BangumiSession(this.preferences, this.accountSession, this.api, this.oauth);

  final SharedPreferences preferences;
  final AccountSession accountSession;
  int generation = 0;
  BangumiAccount? _account;
  Future<String>? _refresh;
  Completer<void>? _oauthAbort;
  void ensureCurrent(int revision) {
    if (revision != generation) {
      throw const BangumiSyncException('Bangumi 账号已变更');
    }
  }

  static const _tokenKey = 'bangumi_access_token';
  static const _refreshTokenKey = 'bangumi_refresh_token';
  static const _tokenExpiresAtKey = 'bangumi_token_expires_at';
  static const accountKey = 'bangumi_account';
  static const _snapshotKey = 'bangumi_sync_snapshot';
  static const _pendingPushKey = 'bangumi_sync_pending_push';
  static const _lastSyncKey = 'bangumi_last_sync_at';
  static const _localSnapshotKey = 'bangumi_local_sync_snapshot';
  static const _localPendingPushKey = 'bangumi_local_sync_pending_push';
  static const _localLastSyncKey = 'bangumi_local_last_sync_at';
  static const _autoProgressKey = 'bangumi_auto_episode_progress';
  static const _autoMarkEpisodeKey = 'bangumi_auto_mark_episode';
  static const _quickMarkGridKey = 'bangumi_quick_mark_grid';

  final BangumiApi api;
  final BangumiOAuthBroker oauth;

  bool get isLocalMode => accountSession.token.isEmpty;

  bool get autoMarkEpisode => preferences.getBool(_autoMarkEpisodeKey) ?? true;

  Future<void> setAutoMarkEpisode(bool value) async {
    await preferences.setBool(_autoMarkEpisodeKey, value);
  }

  bool get quickMarkGrid => preferences.getBool(_quickMarkGridKey) ?? true;

  Future<void> setQuickMarkGrid(bool value) async {
    await preferences.setBool(_quickMarkGridKey, value);
  }

  String get snapshotKey => isLocalMode ? _localSnapshotKey : _snapshotKey;
  String get pendingPushKey =>
      isLocalMode ? _localPendingPushKey : _pendingPushKey;
  String get lastSyncKey => isLocalMode ? _localLastSyncKey : _lastSyncKey;

  bool get isConnected => (preferences.getString(_tokenKey) ?? '').isNotEmpty;

  BangumiAccount? get account {
    if (_account != null) return _account;
    final value = preferences.getString(accountKey);
    if (value == null || value.isEmpty) return null;
    try {
      return _account = BangumiAccount.fromJson(
        jsonDecode(value) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  DateTime? get lastSyncAt {
    return DateTime.tryParse(preferences.getString(lastSyncKey) ?? '');
  }

  Future<BangumiOAuthStart> beginOAuthLogin() async {
    cancelOAuthLogin();
    final revision = ++generation;
    final abort = _oauthAbort = Completer<void>();
    try {
      final login = await oauth.begin(abortTrigger: abort.future);
      ensureCurrent(revision);
      return login;
    } catch (_) {
      if (identical(_oauthAbort, abort)) cancelOAuthLogin();
      rethrow;
    }
  }

  void cancelOAuthLogin() {
    final abort = _oauthAbort;
    if (abort == null) return;
    generation++;
    _oauthAbort = null;
    abort.complete();
  }

  Future<BangumiAccount> completeOAuthLogin(String state) async {
    final revision = generation;
    final abort = _oauthAbort;
    if (abort == null) throw const BangumiSyncException('Bangumi 登录已取消');
    _account = null;
    _refresh = null;
    try {
      final token = await oauth.waitForCompletion(
        state,
        abortTrigger: abort.future,
      );
      ensureCurrent(revision);
      final user = await api.getMe(
        token.accessToken,
        abortTrigger: abort.future,
      );
      ensureCurrent(revision);
      if (user.username.isEmpty) {
        throw const BangumiSyncException('无法识别 Bangumi 账号');
      }
      await _saveOAuthToken(token);
      await preferences.setString(accountKey, jsonEncode(user.toJson()));
      // Binding is already saved. A lost acknowledgement (or an older server
      // without this endpoint) must not undo it; the server also expires state.
      unawaited(oauth.acknowledge(state).catchError((Object _) {}));
      return user;
    } finally {
      if (identical(_oauthAbort, abort)) {
        _oauthAbort = null;
        abort.complete();
      }
    }
  }

  Future<BangumiAccount> connect(String rawToken) async {
    cancelOAuthLogin();
    final revision = ++generation;
    _account = null;
    _refresh = null;
    final token = rawToken.trim().replaceFirst(
      RegExp(r'^Bearer\s+', caseSensitive: false),
      '',
    );
    if (token.isEmpty) {
      throw const BangumiSyncException('请输入 Bangumi Access Token');
    }
    final user = await api.getMe(token);
    ensureCurrent(revision);
    if (user.username.isEmpty) {
      throw const BangumiSyncException('无法识别 Bangumi 账号');
    }
    await preferences.setString(_tokenKey, token);
    await preferences.remove(_refreshTokenKey);
    await preferences.remove(_tokenExpiresAtKey);
    await preferences.setString(accountKey, jsonEncode(user.toJson()));
    return user;
  }

  Future<void> disconnect() async {
    cancelOAuthLogin();
    generation++;
    _account = null;
    _refresh = null;
    await Future.wait([
      preferences.remove(_tokenKey),
      preferences.remove(_refreshTokenKey),
      preferences.remove(_tokenExpiresAtKey),
      preferences.remove(accountKey),
      preferences.remove(_snapshotKey),
      preferences.remove(_pendingPushKey),
      preferences.remove(_lastSyncKey),
      preferences.remove(_localSnapshotKey),
      preferences.remove(_localPendingPushKey),
      preferences.remove(_localLastSyncKey),
      preferences.remove(_autoProgressKey),
    ]);
  }

  /// 读取当前 Bangumi 账号的单条收藏，供详情页显示真实状态。
  Future<AnimeCollection?> getCollection(int subjectId) async {
    final revision = generation;
    final token = await accessToken();
    ensureCurrent(revision);
    final result = await api.getCollection(token, subjectId);
    ensureCurrent(revision);
    return result;
  }

  /// 读取当前 Bangumi 账号的全部动画收藏。
  Future<List<AnimeCollection>> getCollections() async {
    final revision = generation;
    final token = await accessToken();
    ensureCurrent(revision);
    var user = account;
    if (user == null) {
      user = await api.getMe(token);
      ensureCurrent(revision);
      await preferences.setString(accountKey, jsonEncode(user.toJson()));
    }
    final remote = await api.getAnimeCollections(token, user.username);
    ensureCurrent(revision);
    return remote;
  }

  /// 直接写入 Bangumi 收藏状态；Access Token 只保存在本机。
  Future<void> updateCollection(AnimeCollection collection) async {
    final revision = generation;
    final token = await accessToken();
    ensureCurrent(revision);
    await api.putCollection(token, collection);
    ensureCurrent(revision);
  }

  Future<void> updateEpisodeProgress(int subjectId, int watched) async {
    final revision = generation;
    final token = await accessToken();
    ensureCurrent(revision);
    await api.putEpisodeProgress(token, subjectId, watched);
    ensureCurrent(revision);
  }

  /// 播放完成后把集数推进到 Bangumi。相同或更早集数不会重复请求。
  Future<void> markEpisodeWatched({
    required int subjectId,
    required int watched,
    AnimeCollection? metadata,
  }) async {
    final revision = generation;
    if (watched <= 0) return;
    final progress = _loadAutoProgress();
    if ((progress['$subjectId'] ?? 0) >= watched) return;

    final token = await accessToken();
    ensureCurrent(revision);
    final current = await api.getCollection(token, subjectId);
    ensureCurrent(revision);
    if (current != null && (current.epWatched ?? 0) >= watched) {
      progress['$subjectId'] = (current.epWatched ?? 0);
      await preferences.setString(_autoProgressKey, jsonEncode(progress));
      return;
    }
    if (current == null || current.status == CollectionStatus.wish.value) {
      await api.putCollection(
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
    await api.putEpisodeProgress(token, subjectId, watched);
    ensureCurrent(revision);
    progress['$subjectId'] = watched;
    await preferences.setString(_autoProgressKey, jsonEncode(progress));
  }

  Future<String> accessToken() {
    final revision = generation;
    return _refresh ??= _accessToken(revision).whenComplete(() {
      if (revision == generation) _refresh = null;
    });
  }

  Future<String> _accessToken(int revision) async {
    final accessToken = preferences.getString(_tokenKey) ?? '';
    if (accessToken.isEmpty) {
      throw const BangumiSyncException('请先登录 Bangumi');
    }
    final expiresAt = DateTime.tryParse(
      preferences.getString(_tokenExpiresAtKey) ?? '',
    );
    if (expiresAt == null ||
        expiresAt.isAfter(
          DateTime.now().toUtc().add(const Duration(minutes: 1)),
        )) {
      return accessToken;
    }

    final refreshToken = preferences.getString(_refreshTokenKey) ?? '';
    if (refreshToken.isEmpty) {
      throw const BangumiSyncException('Bangumi 登录已过期，请重新登录');
    }
    if (accountSession.token.isEmpty) {
      throw const BangumiSyncException('AniBaka账号未登录，无法续期 Bangumi 登录');
    }
    final refreshed = await oauth.refresh(refreshToken);
    ensureCurrent(revision);
    final effectiveToken = refreshed.refreshToken.isEmpty
        ? BangumiOAuthToken(
            accessToken: refreshed.accessToken,
            refreshToken: refreshToken,
            expiresIn: refreshed.expiresIn,
          )
        : refreshed;
    await _saveOAuthToken(effectiveToken);
    return effectiveToken.accessToken;
  }

  Future<void> _saveOAuthToken(BangumiOAuthToken token) async {
    await preferences.setString(_tokenKey, token.accessToken);
    if (token.refreshToken.isNotEmpty) {
      await preferences.setString(_refreshTokenKey, token.refreshToken);
    }
    await preferences.setString(
      _tokenExpiresAtKey,
      DateTime.now()
          .toUtc()
          .add(Duration(seconds: token.expiresIn))
          .toIso8601String(),
    );
  }

  Map<String, String> loadSnapshots() {
    final value = preferences.getString(snapshotKey);
    if (value == null || value.isEmpty) return {};
    try {
      final json = jsonDecode(value) as Map<String, dynamic>;
      return json.map((key, value) => MapEntry(key, value.toString()));
    } catch (_) {
      return {};
    }
  }

  Set<int> loadPendingPush() {
    final value = preferences.getString(pendingPushKey);
    if (value == null || value.isEmpty) return {};
    try {
      return (jsonDecode(value) as List).map(toInt).whereType<int>().toSet();
    } catch (_) {
      return {};
    }
  }

  Map<String, int> _loadAutoProgress() {
    final value = preferences.getString(_autoProgressKey);
    if (value == null || value.isEmpty) return {};
    try {
      final json = jsonDecode(value) as Map<String, dynamic>;
      return json.map((key, value) => MapEntry(key, toInt(value) ?? 0));
    } catch (_) {
      return {};
    }
  }
}
