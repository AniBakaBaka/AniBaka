class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.qq,
    required this.sign,
    required this.level,
    this.passwordMarker,
    this.email = '',
    this.emailVerified = false,
  });

  const AppUser.guest()
    : id = 0,
      name = '点击登录',
      qq = '',
      sign = '',
      level = 0,
      email = '',
      emailVerified = false,
      passwordMarker = null;

  factory AppUser.fromJson(
    Map<String, dynamic> json, {
    String? retainedPasswordMarker,
  }) => AppUser(
    id: (json['id'] as num).toInt(),
    name: json['name'] as String,
    qq: json['qq'] as String? ?? '',
    sign: json['sign'] as String? ?? '',
    level: (json['level'] as num).toInt(),
    passwordMarker: json['pwd'] as String? ?? retainedPasswordMarker,
    email: json['email'] as String? ?? '',
    emailVerified: json['email_verified'] == true,
  );

  static final qqPattern = RegExp(r'^\d{1,20}$');

  final int id;
  final String name;
  final String qq;
  final String sign;
  final int level;
  final String? passwordMarker;
  final String email;
  final bool emailVerified;

  bool get isLoggedIn => id != 0;
  bool get hasPassword => passwordMarker != null;
  bool get usesQQEmail =>
      !(emailVerified && email.isNotEmpty) && qqPattern.hasMatch(qq);
  String get recoveryEmail => emailVerified && email.isNotEmpty
      ? email
      : usesQQEmail
      ? '$qq@qq.com'
      : '';

  String get maskedRecoveryEmail {
    final address = recoveryEmail;
    final at = address.indexOf('@');
    if (at <= 0) return address;
    final prefix = at > 5
        ? '${address.substring(0, 3)}****${address.substring(at - 2, at)}'
        : '${address.substring(0, 1)}***';
    return '$prefix${address.substring(at)}';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'qq': qq,
    'sign': sign,
    'level': level,
    'email': email,
    'email_verified': emailVerified,
    if (passwordMarker != null) 'pwd': passwordMarker,
  };
}
