import 'package:baka/models/app_user.dart';
import 'package:baka/pages/login/account_password_view.dart';
import 'package:baka/services/account/login_service.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide ContextExtensionss;

export 'package:baka/pages/login/account_password_view.dart'
    show
        AccountPasswordField,
        EmailCodeCountdown,
        EmailCodeField,
        EmailVerificationFields,
        accountInputDecoration;

class AccountSecurityPage extends StatefulWidget {
  const AccountSecurityPage({super.key}) : recovery = false;

  const AccountSecurityPage._({required this.recovery, super.key});

  final bool recovery;

  @override
  State<AccountSecurityPage> createState() => _AccountSecurityPageState();
}

class PasswordRecoveryPage extends AccountSecurityPage {
  const PasswordRecoveryPage({super.key}) : super._(recovery: true);
}

class _AccountSecurityPageState extends State<AccountSecurityPage> {
  final _form = GlobalKey<FormState>();
  final _emailField = GlobalKey<FormFieldState<String>>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _countdown = EmailCodeCountdown();
  final _service = LoginService();

  bool _busy = false;
  bool _sending = false;
  bool _done = false;
  bool _codeError = false;
  String? _message;
  String? _codeMessage;

  bool get _recovery => widget.recovery;

  @override
  void dispose() {
    _countdown.dispose();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _clearVerificationState() {
    _countdown.reset();
    _code.clear();
    setState(() {
      _codeMessage = null;
      _codeError = false;
      _message = null;
    });
  }

  Future<void> _sendCode() async {
    if (_busy || _sending || _countdown.value > 0) return;
    var targetAddress = '';
    if (_recovery) {
      if (!(_emailField.currentState?.validate() ?? false)) return;
      targetAddress = LoginService.normalizeRecoveryAddress(_email.text);
    } else if (_service.session.user.value.recoveryEmail.isEmpty) {
      return;
    }

    setState(() {
      _sending = true;
      _codeMessage = null;
      _message = null;
    });

    final result = _recovery
        ? await _service.sendEmailCode(
            email: targetAddress,
            purpose: 'reset_password',
          )
        : await _service.sendPasswordChangeCode();
    if (!mounted) return;

    setState(() {
      _sending = false;
      _codeMessage = result.message;
      _codeError = !result.success;
    });

    if (result.success &&
        (!_recovery ||
            targetAddress ==
                LoginService.normalizeRecoveryAddress(_email.text))) {
      _code.clear();
      _countdown.start();
    }
  }

  Future<void> _submit() async {
    if (_busy ||
        _sending ||
        (!_recovery && _service.session.user.value.recoveryEmail.isEmpty) ||
        !(_form.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });

    final result = _recovery
        ? await _service.resetPassword(
            email: _email.text,
            code: _code.text,
            password: _password.text,
          )
        : await _service.changePassword(
            code: _code.text,
            password: _password.text,
          );
    if (!mounted) return;

    setState(() {
      _busy = false;
      _done = result.success;
      _message = result.success ? null : result.message;
    });

    if (result.success) {
      _countdown.reset();
      _code.clear();
      _password.clear();
      _confirm.clear();
      if (!_recovery) {
        showSnackBar('密码已修改，请使用新密码重新登录');
        await Navigator.maybePop(context);
      }
    }
  }

  Future<void> _manageEmail() async {
    if (_busy || _sending) return;
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _BindRecoveryEmailDialog(service: _service),
    );
    if (mounted && changed == true) {
      _clearVerificationState();
    }
  }

  @override
  Widget build(BuildContext context) => _recovery
      ? _buildScaffold(context, const AppUser.guest())
      : Obx(() => _buildScaffold(context, _service.session.user.value));

  Widget _buildScaffold(BuildContext context, AppUser user) {
    final wide = MediaQuery.sizeOf(context).width >= 880;
    final onBack = _busy ? null : () => Navigator.maybePop(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: onBack),
        title: Text(_recovery ? '找回密码' : '账户安全'),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              wide ? 40 : 16,
              wide ? 24 : 12,
              wide ? 40 : 16,
              24,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: wide ? 980 : 520),
              child: _done
                  ? _buildCompletedNotice(context, onBack)
                  : wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 5,
                          child: _buildContextCard(context, user),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          flex: 7,
                          child: _buildFormCard(context, user, onBack),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildContextCard(context, user),
                        const SizedBox(height: 16),
                        _buildFormCard(context, user, onBack),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContextCard(BuildContext context, AppUser user) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final hasEmail = !_recovery && user.recoveryEmail.isNotEmpty;

    final badgeText = _recovery
        ? '邮箱验证'
        : !hasEmail
        ? '未设置'
        : user.usesQQEmail
        ? '默认 QQ 邮箱'
        : '已验证';
    final description = _recovery
        ? '有 QQ 号可直接通过对应 QQ 邮箱找回，无需提前绑定；已绑定其他邮箱的账户请直接填写该邮箱。'
        : !hasEmail
        ? '先绑定找回邮箱，即可通过邮箱验证码修改登录密码。'
        : user.usesQQEmail
        ? '当前默认使用 QQ 邮箱接收验证码，也可绑定其他常用邮箱。'
        : '该邮箱已验证，可用于接收验证码以修改或找回登录密码。';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: isDark ? 0.28 : 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: colors.primary.withValues(alpha: isDark ? 0.22 : 0.14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _recovery
                      ? Icons.lock_reset_rounded
                      : Icons.mark_email_read_outlined,
                  color: colors.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _recovery ? '找回你的账户' : '找回邮箱',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      badgeText,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!_recovery) ...[
            const SizedBox(height: 16),
            Text(
              hasEmail ? user.maskedRecoveryEmail : '尚未设置',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          if (!_recovery) ...[
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _busy || _sending ? null : _manageEmail,
              icon: Icon(
                hasEmail ? Icons.swap_horiz_rounded : Icons.add_link_rounded,
                size: 18,
              ),
              label: Text(hasEmail ? '更换邮箱' : '绑定邮箱'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFormCard(
    BuildContext context,
    AppUser user,
    VoidCallback? onBack,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final hasEmail = _recovery || user.recoveryEmail.isNotEmpty;
    final enabled = !_busy && hasEmail;
    final helper = _codeMessage ?? (_recovery ? null : '验证邮箱后即可设置新密码');

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : colors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Form(
        key: _form,
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _recovery ? '重置密码' : '修改密码',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _recovery
                    ? '验证邮箱后，即可重新设置密码'
                    : hasEmail
                    ? '验证码将发送至当前找回邮箱'
                    : '请先绑定找回邮箱，再通过验证码修改密码',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              if (_recovery) ...[
                TextFormField(
                  key: _emailField,
                  controller: _email,
                  enabled: enabled && !_sending,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  autocorrect: false,
                  maxLength: 254,
                  decoration: accountInputDecoration(
                    context,
                    label: 'QQ 号 / 邮箱',
                    hint: '输入 QQ 号或邮箱',
                    icon: Icons.mail_outline_rounded,
                  ),
                  onChanged: (_) => _clearVerificationState(),
                  validator: (value) =>
                      LoginService.isValidRecoveryAddress(value ?? '')
                      ? null
                      : '请填写 QQ 号或有效的邮箱地址',
                ),
                const SizedBox(height: 14),
              ],
              EmailCodeField(
                controller: _code,
                countdown: _countdown,
                enabled: enabled,
                sending: _sending,
                onSend: _sendCode,
              ),
              if (helper != null) ...[
                const SizedBox(height: 6),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    helper,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _codeError
                          ? colors.error
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              AccountPasswordField(
                controller: _password,
                label: '新密码',
                hint: '至少 8 位字符',
                enabled: enabled,
              ),
              const SizedBox(height: 14),
              AccountPasswordField(
                controller: _confirm,
                label: '确认新密码',
                hint: '再次输入新密码',
                enabled: enabled,
                validator: (value) => value == null || value.isEmpty
                    ? '请再次输入新密码'
                    : value != _password.text
                    ? '两次密码输入不一致'
                    : null,
                onSubmitted: enabled && !_sending ? _submit : null,
              ),
              if (_message != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _message!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: enabled && !_sending ? _submit : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.lock_outline_rounded, size: 20),
                label: Text(
                  _busy
                      ? '验证中…'
                      : _recovery
                      ? '验证并重置密码'
                      : '验证并修改密码',
                ),
              ),
              const SizedBox(height: 12),
              if (_recovery)
                Center(
                  child: TextButton(
                    onPressed: onBack,
                    child: const Text('返回登录'),
                  ),
                )
              else
                Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '修改成功后需重新登录',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompletedNotice(BuildContext context, VoidCallback? onBack) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(
            Icons.check_circle_outline_rounded,
            size: 48,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(
              '密码已${_recovery ? '重置' : '修改'}，请使用新密码登录',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.tonal(
            onPressed: onBack,
            child: Text(_recovery ? '返回登录' : '返回'),
          ),
        ],
      ),
    );
  }
}

class _BindRecoveryEmailDialog extends StatefulWidget {
  const _BindRecoveryEmailDialog({required this.service});

  final LoginService service;

  @override
  State<_BindRecoveryEmailDialog> createState() =>
      _BindRecoveryEmailDialogState();
}

class _BindRecoveryEmailDialogState extends State<_BindRecoveryEmailDialog> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _current.dispose();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await widget.service.bindEmail(
      email: _email.text,
      code: _code.text,
      currentPassword: _current.text,
    );
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _message = result.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_busy,
      child: AppDialog(
        title: '绑定找回邮箱',
        content: Form(
          key: _form,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '更换找回邮箱需验证当前密码和新邮箱。修改登录密码使用当前找回邮箱的验证码。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
                AccountPasswordField(
                  controller: _current,
                  label: '当前密码',
                  current: true,
                  enabled: !_busy,
                ),
                const SizedBox(height: 14),
                EmailVerificationFields(
                  email: _email,
                  code: _code,
                  purpose: 'bind_email',
                  currentPassword: _current,
                  enabled: !_busy,
                ),
                if (_message != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _message!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: Row(
          children: [
            Expanded(
              child: FilledButton.tonal(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? '验证中…' : '验证并绑定'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
