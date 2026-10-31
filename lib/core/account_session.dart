import 'dart:convert';

import 'package:baka/core/app_logger.dart';
import 'package:baka/models/app_user.dart';
import 'package:baka/models/token_response.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:shared_preferences/shared_preferences.dart';

/// Owns account identity and serializes credential writes across transitions.
/// [generation] changes on every identity change so in-flight work for the
/// previous identity can be discarded.
class AccountSession {
  AccountSession(this.preferences, {required this.refreshTokens})
    : token = preferences.getString(_tokenKey) ?? '',
      _refreshToken = preferences.getString(_refreshKey),
      _expiresAt = DateTime.tryParse(preferences.getString(_expiresKey) ?? '') {
    final stored = preferences.getString(_userKey);
    if (stored == null) return;
    try {
      user.value = AppUser.fromJson(jsonDecode(stored) as Map<String, dynamic>);
    } catch (error) {
      Log.w('Account', 'Stored profile unreadable; signed out view', error);
    }
  }

  static const _tokenKey = 'usertoken';
  static const _refreshKey = 'refresh_token';
  static const _expiresKey = 'token_expires_at';
  static const _userKey = 'userinfo';

  final SharedPreferences preferences;
  final Future<TokenResponse?> Function(String refreshToken) refreshTokens;
  final user = Rx<AppUser>(const AppUser.guest());
  String token;
  String? _refreshToken;
  DateTime? _expiresAt;
  int generation = 0;
  bool closed = false;
  Future<bool>? _refresh;
  Future<void> _writes = Future.value();

  bool get isLoggedIn => user.value.isLoggedIn;
  TokenResponse get credentials =>
      TokenResponse(token, refreshToken: _refreshToken, expiresAt: _expiresAt);
  bool get expiresSoon =>
      _expiresAt != null &&
      !_expiresAt!.isAfter(DateTime.now().add(const Duration(seconds: 30)));

  Future<void> login(TokenResponse credentials, AppUser next) {
    if (closed) throw StateError('Account session is closed');
    generation++;
    _refresh = null;
    token = credentials.token;
    _refreshToken = credentials.refreshToken;
    _expiresAt = credentials.expiresAt;
    user.value = next;
    Log.i('Account', token.isEmpty ? 'Signed out' : 'Signed in as ${next.id}');
    return _persist();
  }

  Future<void> logout() =>
      login(const TokenResponse(''), const AppUser.guest());

  Future<void> saveUser(AppUser next) {
    user.value = next;
    return _persist();
  }

  /// Concurrent callers share one refresh; a refresh that outlives its
  /// identity reports false and stores nothing.
  Future<bool> refresh() {
    final revision = generation;
    return _refresh ??= _refreshCredentials(revision).whenComplete(() {
      if (revision == generation) _refresh = null;
    });
  }

  Future<bool> _refreshCredentials(int revision) async {
    final refreshToken = _refreshToken;
    if (closed || refreshToken == null || refreshToken.isEmpty) return false;
    final next = await refreshTokens(refreshToken);
    if (closed || revision != generation) return false;
    if (next == null || next.token.isEmpty) {
      Log.w('Account', 'Refresh token rejected');
      return false;
    }
    token = next.token;
    _refreshToken = next.refreshToken ?? _refreshToken;
    _expiresAt = next.expiresAt;
    await _persist();
    return revision == generation;
  }

  /// Writes a snapshot after all earlier writes; a failed write is logged and
  /// reported to its caller without blocking later ones.
  Future<void> _persist() {
    final signedIn = token.isNotEmpty;
    final values = {
      _tokenKey: signedIn ? token : null,
      _refreshKey: _refreshToken,
      _expiresKey: _expiresAt?.toUtc().toIso8601String(),
      _userKey: signedIn ? jsonEncode(user.value.toJson()) : null,
    };
    final write = _writes.then(
      (_) => Future.wait([
        for (final MapEntry(:key, :value) in values.entries)
          value == null
              ? preferences.remove(key)
              : preferences.setString(key, value),
      ]),
    );
    _writes = write.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) =>
          Log.e('Account', 'Credential write failed', error, stack),
    );
    return write;
  }

  Future<void> flush() => _writes;

  Future<void> close() {
    closed = true;
    generation++;
    return _writes;
  }
}
