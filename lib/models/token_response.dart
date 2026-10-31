/// 登录 / 刷新接口返回的凭证。
///
/// `expires_in`（相对秒数，线上现状）优先于 `token_expires_at`（绝对时间），
/// 两者都缺失时过期时间保持为 null，由 [AccountSession.expiresSoon] 判定为不过期。
class TokenResponse {
  const TokenResponse(this.token, {this.refreshToken, this.expiresAt});

  factory TokenResponse.fromJson(Map<String, dynamic> json) => TokenResponse(
    json['token'] as String? ?? '',
    refreshToken: json['refresh_token'] as String?,
    expiresAt: json['expires_in'] is num
        ? DateTime.now().toUtc().add(
            Duration(seconds: (json['expires_in'] as num).toInt()),
          )
        : DateTime.tryParse(json['token_expires_at'] as String? ?? ''),
  );

  final String token;
  final String? refreshToken;
  final DateTime? expiresAt;

  /// The [TokenResponse.fromJson] form, for handing a sign-in to another device.
  Map<String, dynamic> toJson() => {
    'token': token,
    'refresh_token': ?refreshToken,
    'token_expires_at': ?expiresAt?.toUtc().toIso8601String(),
  };
}
