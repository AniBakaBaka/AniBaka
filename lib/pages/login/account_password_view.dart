import 'dart:async';

import 'package:baka/services/account/login_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class EmailCodeCountdown extends ValueNotifier<int> {
  EmailCodeCountdown() : super(0);

  Timer? _timer;

  void start([int seconds = 60]) {
    _timer?.cancel();
    value = seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (value <= 1) {
        timer.cancel();
        value = 0;
      } else {
        value--;
      }
    });
  }

  void reset() {
    _timer?.cancel();
    value = 0;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

InputDecoration accountInputDecoration(
  BuildContext context, {
  String? label,
  String? hint,
  IconData? icon,
  Widget? suffixIcon,
}) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  final isDark = theme.brightness == Brightness.dark;
  const radius = BorderRadius.all(Radius.circular(14));
  final border = OutlineInputBorder(
    borderRadius: radius,
    borderSide: BorderSide(
      color: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.06),
    ),
  );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    counterText: '',
    filled: true,
    fillColor: isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.025),
    prefixIcon: icon == null ? null : Icon(icon, size: 20),
    suffixIcon: suffixIcon,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: border,
    enabledBorder: border,
    disabledBorder: border.copyWith(borderSide: BorderSide.none),
    focusedBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: colors.primary, width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: colors.error),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: colors.error, width: 1.5),
    ),
  );
}

class AccountPasswordField extends StatefulWidget {
  const AccountPasswordField({
    required this.controller,
    required this.label,
    super.key,
    this.hint,
    this.enabled = true,
    this.current = false,
    this.validator,
    this.decoration,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool enabled;
  final bool current;
  final FormFieldValidator<String>? validator;
  final InputDecoration? decoration;
  final VoidCallback? onSubmitted;

  @override
  State<AccountPasswordField> createState() => _AccountPasswordFieldState();
}

class _AccountPasswordFieldState extends State<AccountPasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final baseDecoration =
        widget.decoration ??
        accountInputDecoration(
          context,
          label: widget.label,
          hint: widget.hint,
          icon: Icons.lock_outline_rounded,
        );
    return TextFormField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _obscure,
      maxLength: 128,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: widget.onSubmitted == null
          ? TextInputAction.next
          : TextInputAction.done,
      autofillHints: [
        widget.current ? AutofillHints.password : AutofillHints.newPassword,
      ],
      decoration: baseDecoration.copyWith(
        counterText: '',
        suffixIcon: IconButton(
          onPressed: widget.enabled
              ? () => setState(() => _obscure = !_obscure)
              : null,
          tooltip: '${_obscure ? '显示' : '隐藏'}${widget.label}',
          icon: Icon(
            _obscure
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            size: 20,
          ),
        ),
      ),
      validator:
          widget.validator ??
          (value) => LoginService.validatePassword(
            value,
            label: widget.label,
            requireLength: !widget.current,
          ),
      onFieldSubmitted: widget.onSubmitted == null
          ? null
          : (_) => widget.onSubmitted!(),
    );
  }
}

class EmailCodeField extends StatelessWidget {
  const EmailCodeField({
    required this.controller,
    required this.countdown,
    required this.onSend,
    super.key,
    this.enabled = true,
    this.sending = false,
    this.outlined = false,
    this.idleLabel = '发送验证码',
  });

  final TextEditingController controller;
  final ValueListenable<int> countdown;
  final VoidCallback onSend;
  final bool enabled;
  final bool sending;
  final bool outlined;
  final String idleLabel;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final field = TextFormField(
        controller: controller,
        enabled: enabled,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.oneTimeCode],
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        decoration: accountInputDecoration(
          context,
          label: '邮箱验证码',
          hint: '6 位数字',
          icon: Icons.key_outlined,
        ),
        validator: (value) =>
            LoginService.isValidCode(value ?? '') ? null : '请输入 6 位验证码',
      );
      final button = ValueListenableBuilder<int>(
        valueListenable: countdown,
        builder: (context, remaining, _) {
          final canSend = enabled && !sending && remaining == 0;
          final label = Text(
            sending
                ? '发送中…'
                : remaining > 0
                ? '${remaining}s 后重发'
                : idleLabel,
          );
          final shape = RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          );
          return outlined
              ? OutlinedButton(
                  onPressed: canSend ? onSend : null,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(112, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: shape,
                  ),
                  child: label,
                )
              : FilledButton.tonal(
                  onPressed: canSend ? onSend : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(116, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: shape,
                  ),
                  child: label,
                );
        },
      );
      if (constraints.maxWidth < 280 ||
          MediaQuery.textScalerOf(context).scale(14) > 19) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [field, const SizedBox(height: 8), button],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: field),
          const SizedBox(width: 10),
          button,
        ],
      );
    },
  );
}

class EmailVerificationFields extends StatefulWidget {
  const EmailVerificationFields({
    required this.email,
    required this.code,
    required this.purpose,
    super.key,
    this.currentPassword,
    this.enabled = true,
  });

  final TextEditingController email;
  final TextEditingController code;
  final String purpose;
  final TextEditingController? currentPassword;
  final bool enabled;

  @override
  State<EmailVerificationFields> createState() =>
      _EmailVerificationFieldsState();
}

class _EmailVerificationFieldsState extends State<EmailVerificationFields> {
  final _countdown = EmailCodeCountdown();
  final _service = LoginService();
  bool _sending = false;
  String? _message;

  @override
  void dispose() {
    _countdown.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || _countdown.value > 0 || !widget.enabled) return;
    if (!LoginService.isValidEmail(widget.email.text)) {
      setState(() => _message = '请先填写有效的邮箱地址');
      return;
    }
    if (widget.purpose == 'bind_email' &&
        (widget.currentPassword?.text.isEmpty ?? true)) {
      setState(() => _message = '请先填写当前密码');
      return;
    }
    setState(() {
      _sending = true;
      _message = null;
    });
    final result = await _service.sendEmailCode(
      email: widget.email.text,
      purpose: widget.purpose,
      currentPassword: widget.currentPassword?.text ?? '',
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      _message = result.message;
    });
    if (result.success) _countdown.start();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextFormField(
        controller: widget.email,
        enabled: widget.enabled && !_sending,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.email],
        autocorrect: false,
        maxLength: 254,
        decoration: accountInputDecoration(
          context,
          label: '邮箱',
          hint: 'name@example.com',
          icon: Icons.mail_outline_rounded,
        ),
        onChanged: (_) => widget.code.clear(),
        validator: (value) =>
            LoginService.isValidEmail(value ?? '') ? null : '请填写有效的邮箱地址',
      ),
      const SizedBox(height: 14),
      EmailCodeField(
        controller: widget.code,
        countdown: _countdown,
        enabled: widget.enabled,
        sending: _sending,
        outlined: true,
        idleLabel: '获取验证码',
        onSend: _send,
      ),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _message!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
    ],
  );
}
