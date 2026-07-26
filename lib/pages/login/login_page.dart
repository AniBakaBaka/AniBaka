import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/instance.dart';
import 'package:baka/services/login_service.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/common/scale_button.dart';

/// 登录 / 注册页面
class Login extends StatefulWidget {
  const Login({super.key});

  @override
  LoginState createState() => LoginState();
}

class LoginState extends State<Login> {
  final _service = LoginService();
  final _formKey = GlobalKey<FormState>();

  final _nameController = TextEditingController();
  final _pwdController = TextEditingController();
  final _qqController = TextEditingController();

  bool _isRegister = false;
  bool _submitting = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _nameController.dispose();
    _pwdController.dispose();
    _qqController.dispose();
    super.dispose();
  }

  void _switchMode(bool isRegister) {
    if (_isRegister == isRegister || _submitting) return;
    HapticFeedback.lightImpact();
    setState(() => _isRegister = isRegister);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _formKey.currentState?.reset();
    });
  }

  Future<void> _submit() async {
    if (_submitting || !(_formKey.currentState?.validate() ?? false)) return;

    HapticFeedback.lightImpact();
    setState(() => _submitting = true);

    try {
      if (_isRegister) {
        final result = await _service.performRegister(
          name: _nameController.text,
          pwd: _pwdController.text,
          qq: _qqController.text,
        );
        showSnackBar(result.message, isError: !result.success);
        if (result.success && mounted) {
          _switchMode(false);
        }
      } else {
        final result = await _service.performLogin(
          name: _nameController.text,
          pwd: _pwdController.text,
        );
        if (!result.success) {
          showSnackBar(result.message, isError: true);
        } else if (mounted) {
          Navigator.pop(context);
        }
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduceMotion = context.reduceMotion;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(leading: const BackButton()),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _formKey,
                child: AutofillGroup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeader(theme, reduceMotion),
                      const SizedBox(height: 28),
                      _buildModeSwitcher(theme, reduceMotion),
                      const SizedBox(height: 24),
                      _buildFormFields(theme, reduceMotion),
                      const SizedBox(height: 28),
                      _buildSubmitButton(theme),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, bool reduceMotion) {
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.asset('assets/ic_launcher.png', height: 72, width: 72),
      ),
    );
  }

  Widget _buildModeSwitcher(ThemeData theme, bool reduceMotion) {
    final isDark = theme.brightness == Brightness.dark;
    final trackColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.05);

    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: trackColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: _isRegister ? Alignment.centerRight : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
          Row(
            children: [
              _buildTabOption('登录', !_isRegister, theme, reduceMotion),
              _buildTabOption('注册', _isRegister, theme, reduceMotion),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTabOption(
    String label,
    bool isSelected,
    ThemeData theme,
    bool reduceMotion,
  ) {
    return Expanded(
      child: ScaleButton(
        onTap: () => _switchMode(label == '注册'),
        child: Container(
          color: Colors.transparent,
          alignment: Alignment.center,
          child: AnimatedDefaultTextStyle(
            duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
            style: TextStyle(
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              letterSpacing: 1,
              color: isSelected
                  ? Colors.white
                  : theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }

  Widget _buildFormFields(ThemeData theme, bool reduceMotion) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSize(
          duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: _isRegister
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: TextFormField(
                    controller: _qqController,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    enabled: !_submitting,
                    decoration: _inputDecoration(
                      theme,
                      hintText: '请填写 QQ 号',
                      prefixIcon: Icons.badge_outlined,
                    ),
                    validator: (v) => _isRegister && (v == null || v.trim().isEmpty)
                        ? '请填写 QQ 号'
                        : null,
                  ),
                )
              : const SizedBox.shrink(),
        ),
        TextFormField(
          controller: _nameController,
          textInputAction: TextInputAction.next,
          enabled: !_submitting,
          autofillHints: const [AutofillHints.username],
          decoration: _inputDecoration(
            theme,
            hintText: _isRegister ? '用户名' : '用户名或 QQ',
            prefixIcon: Icons.person_outline,
          ),
          validator: (v) => (v == null || v.trim().isEmpty) ? '请填写用户名' : null,
        ),
        const SizedBox(height: 14),
        TextFormField(
          controller: _pwdController,
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.done,
          enabled: !_submitting,
          autofillHints: const [AutofillHints.password],
          onFieldSubmitted: (_) => _submit(),
          decoration: _inputDecoration(
            theme,
            hintText: '密码',
            prefixIcon: Icons.lock_outline,
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                size: 20,
              ),
              tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          validator: (v) => (v == null || v.trim().isEmpty) ? '请填写密码' : null,
        ),
      ],
    );
  }

  InputDecoration _inputDecoration(
    ThemeData theme, {
    required String hintText,
    required IconData prefixIcon,
    Widget? suffixIcon,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    final fillColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.03);

    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide.none,
    );

    final focusBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
    );

    return InputDecoration(
      hintText: hintText,
      hintStyle: TextStyle(
        fontSize: 14,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
      ),
      prefixIcon: Icon(prefixIcon, size: 20),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: fillColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: border,
      enabledBorder: border,
      focusedBorder: focusBorder,
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: theme.colorScheme.error, width: 1),
      ),
    );
  }

  Widget _buildSubmitButton(ThemeData theme) {
    return ScaleButton(
      onTap: _submitting ? null : _submit,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.center,
        child: _submitting
            ? SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.onPrimary,
                ),
              )
            : Text(
                _isRegister ? '注 册' : '登 录',
                style: TextStyle(
                  color: theme.colorScheme.onPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
      ),
    );
  }
}
