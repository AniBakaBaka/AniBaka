import 'dart:convert';
import 'package:baka/models/app_user.dart';
import 'package:baka/models/token_response.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:shared_preferences/shared_preferences.dart';

/// Owns account identity and serializes credential writes across transitions.
class AccountSession {
  AccountSession(this.preferences, {required this.refreshTokens}) {
    token = preferences.getString('usertoken') ?? '';
    _refreshToken = preferences.getString('refresh_token');
    _expiresAt = DateTime.tryParse(
      preferences.getString('token_expires_at') ?? '',
    );
    try {
      final stored = preferences.getString('userinfo');
      if (stored != null) user.value = AppUser.fromJson(jsonDecode(stored));
    } catch (_) {
      /* Invalid metadata cannot establish an identity. */
    }
  }
  final SharedPreferences preferences;
  final Future<TokenResponse?> Function(String token) refreshTokens;
  final user = Rx<AppUser>(const AppUser.guest());
  late String token;
  String? _refreshToken;
  DateTime? _expiresAt;
  int generation = 0;
  bool closed = false;
  Future<bool>? _refresh;
  Future<void>? _writes;
  bool get isLoggedIn => user.value.isLoggedIn;
  bool get expiresSoon =>
      _expiresAt != null &&
      !_expiresAt!.isAfter(DateTime.now().add(const Duration(seconds: 30)));
  void refreshView() => user.refresh();

  Future<void> login(TokenResponse credentials, AppUser next) {
    if (closed) throw StateError('Account session is closed');
    generation++;
    _refresh = null;
    token = credentials.token;
    _refreshToken = credentials.refreshToken;
    _expiresAt = credentials.expiresAt;
    user.value = next;
    return _persist();
  }

  Future<void> saveLoginInfo(
    String token,
    AppUser next, {
    String? refreshToken,
    String? tokenExpiresAt,
  }) => login(
    TokenResponse(
      token,
      refreshToken: refreshToken,
      expiresAt: DateTime.tryParse(tokenExpiresAt ?? ''),
    ),
    next,
  );
  Future<void> saveUser(AppUser next) {
    user.value = next;
    return _persist();
  }

  Future<void> logout() =>
      login(const TokenResponse(''), const AppUser.guest());

  Future<bool> refresh() {
    final revision = generation;
    return _refresh ??= _refreshCredentials(revision).whenComplete(() {
      if (revision == generation) _refresh = null;
    });
  }

  Future<bool> _refreshCredentials(int revision) async {
    if (closed) return false;
    final refreshToken = _refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return false;
    final next = await refreshTokens(refreshToken);
    if (closed ||
        revision != generation ||
        next == null ||
        next.token.isEmpty) {
      return false;
    }
    token = next.token;
    _refreshToken = next.refreshToken ?? _refreshToken;
    _expiresAt = next.expiresAt;
    await _persist();
    return revision == generation;
  }

  Future<void> _persist() {
    final values = <String, String?>{
      'usertoken': token.isEmpty ? null : token,
      'refresh_token': _refreshToken,
      'token_expires_at': _expiresAt?.toUtc().toIso8601String(),
      'token_expires_in': null,
      'userinfo': token.isEmpty ? null : jsonEncode(user.value.toJson()),
    };
    Future<void> write() async {
      for (final entry in values.entries) {
        if (entry.value == null) {
          await preferences.remove(entry.key);
        } else {
          await preferences.setString(entry.key, entry.value!);
        }
      }
    }

    final previous = _writes;
    late final Future<void> current;
    return _writes = current = (previous == null
            ? write()
            : previous.catchError((Object _) {}).then((_) => write()))
        .whenComplete(() {
          if (identical(_writes, current)) _writes = null;
        });
  }

  Future<void> flush() => _writes ?? Future.value();
  Future<void> close() {
    closed = true;
    generation++;
    return _writes ?? Future.value();
  }
}
