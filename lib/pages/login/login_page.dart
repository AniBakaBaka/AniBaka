import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/setting/bangumi_sync_page.dart';
import 'package:baka/services/bangumi_sync_service.dart';
import 'package:baka/services/login_service.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/common/scale_button.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';

/// 登录 / 注册页面
class Login extends StatefulWidget {
  const Login({super.key});

  @override
  LoginState createState() => LoginState();
}

class LoginState extends State<Login> {
  static const _accessTokenUrl = 'https://next.bgm.tv/demo/access-token';
  final _service = LoginService();
  final _bangumi = BangumiSyncService.instance;
  final _formKey = GlobalKey<FormState>();

  final _nameController = TextEditingController();
  final _pwdController = TextEditingController();
  final _qqController = TextEditingController();

  bool _isRegister = false;
  bool _submitting = false;
  bool _obscurePassword = true;
  bool _bangumiBusy = false;

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

  Future<void> _openAccessTokenPage() async {
    final opened = await launchUrlString(
      _accessTokenUrl,
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) showSnackBar('无法打开浏览器', isError: true);
  }

  Future<void> _connectBangumi() async {
    if (_bangumiBusy) return;
    final action = await showAppConfirmDialog(
      context,
      title: '使用 Bangumi 身份',
      content:
          '连接 Bangumi 前请确认：\n\n'
          '• AniBaka 会从本机直接访问 **Bangumi API**，部分网络环境可能需要先开启代理软件。\n'
          '• **收藏、在看状态和播放完成后的集数** 会直接修改你的 Bangumi 数据。\n'
          '• 头像会通过 wsrv.nl 图片代理加载。\n'
          '• Bangumi 登录**并非 AniBaka 登录**：不能回复 AniBaka 评论，播放历史也只保存在本机，不会上传云端。\n'
          '• 发表评论时会复制内容并打开 Bangumi 官方剧集页，由你在网页中确认发布。\n\n'
          '推荐同时登录 AniBaka，以获得云端播放历史、跨设备同步和 AniBaka 评论回复。',
      confirmText: '继续使用 Bangumi',
      cancelText: '返回登录 AniBaka',
    );
    if (action != DialogAction.confirm || !mounted) return;

    final result = await showAppInputDialog(
      context,
      title: 'Bangumi Access Token',
      hintText: '粘贴从 Bangumi 官方页面获取的 Token',
      confirmText: '验证并登录',
      obscureText: true,
    );
    if (result?.isConfirmed != true || !mounted) return;

    setState(() => _bangumiBusy = true);
    try {
      final account = await _bangumi.connect(result!.value ?? '');
      if (!mounted) return;
      if (Get.isRegistered<AppState>()) {
        Get.find<AppState>().triggerLoginRefresh();
      }
      setState(() {});
      showSnackBar('已使用 Bangumi 登录：${account.nickname}');
    } catch (error) {
      if (mounted) showSnackBar(error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _bangumiBusy = false);
    }
  }

  Future<void> _loginThroughAniBaka() async {
    if (_bangumiBusy) return;
    final action = await showAppConfirmDialog(
      context,
      title: '账号授权会经过 AniBaka 服务器',
      content:
          '你的 **Bangumi 密码**只在 Bangumi 官方页面输入，AniBaka **不会接触密码**；但此授权方式并非客户端直连。\n\n'
          '授权过程中，AniBaka 服务器会把本次会话与**你的 AniBaka 账号关联**，接收 Bangumi 返回的授权码，并代为换取 **Access Token** 与 **Refresh Token**。\n\n'
          '**此方法登录需要登录 AniBaka 账号**，如果你不愿承担服务端信任和隐私关联风险，请取消并使用 **Access Token** 方式。',
      confirmText: '了解风险，继续登录',
      cancelText: '改用 Access Token',
    );
    if (action != DialogAction.confirm || !mounted) return;

    setState(() => _bangumiBusy = true);
    try {
      final login = await _bangumi.beginOAuthLogin();
      final opened = await launchUrlString(
        login.authorizationUrl,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        throw const BangumiSyncException('无法打开浏览器，请检查系统是否安装浏览器');
      }
      if (mounted) {
        showSnackBar('请在浏览器中登录并授权，AniBaka 正在等待结果…');
      }
      final account = await _bangumi.completeOAuthLogin(login.state);
      if (!mounted) return;
      if (Get.isRegistered<AppState>()) {
        Get.find<AppState>().triggerLoginRefresh();
      }
      setState(() {});
      showSnackBar('已成功连接 Bangumi：${account.nickname}');
    } catch (error) {
      if (mounted) showSnackBar(error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _bangumiBusy = false);
    }
  }

  Future<void> _openBangumiManagement() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BangumiSyncPage()),
    );
    if (!mounted) return;
    if (Get.isRegistered<AppState>()) {
      Get.find<AppState>().triggerLoginRefresh();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduceMotion = context.reduceMotion;
    final aniBakaLoggedIn = Instances.userToken.isNotEmpty;

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
                      if (aniBakaLoggedIn)
                        _buildAniBakaConnected(theme)
                      else ...[
                        _buildModeSwitcher(theme, reduceMotion),
                        const SizedBox(height: 24),
                        _buildFormFields(theme, reduceMotion),
                        const SizedBox(height: 28),
                        _buildSubmitButton(theme),
                      ],
                      const SizedBox(height: 24),
                      _buildOrDivider(theme),
                      const SizedBox(height: 20),
                      _buildBangumiLogin(theme),
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

  Widget _buildAniBakaConnected(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.verified_user_rounded, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AniBaka 已登录',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 3),
                Text(
                  '播放历史可保存到云端，并可回复 AniBaka 评论',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrDivider(ThemeData theme) {
    return Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'Bangumi 登录',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }

  Widget _buildBangumiLogin(ThemeData theme) {
    final account = _bangumi.account;
    final connected = _bangumi.isConnected;
    final isDark = theme.brightness == Brightness.dark;
    const bangumiPink = Color(0xFFF09199);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.6)
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: connected
              ? bangumiPink.withValues(alpha: 0.4)
              : theme.dividerColor.withValues(alpha: 0.15),
          width: 1,
        ),
        boxShadow: [
          if (!isDark)
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: bangumiPink.withValues(alpha: 0.1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SvgPicture.asset(
                    'assets/bangumi.svg',
                    width: 44,
                    height: 44,
                    semanticsLabel: 'Bangumi',
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          connected
                              ? (account?.nickname ?? 'Bangumi 用户')
                              : 'Bangumi 账号登录',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        if (connected) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              '已连接',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.green,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      connected
                          ? '@${account?.username ?? ''} · 数据同步中'
                          : '支持 Access Token 登录与网页跳转授权登录',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_bangumiBusy)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '正在处理 Bangumi 登录…',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            )
          else if (connected) ...[
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _openBangumiManagement,
                    icon: const Icon(Icons.sync_rounded, size: 18),
                    label: const Text('管理与同步'),
                  ),
                ),
              ],
            ),
          ] else ...[
            ScaleButton(
              onTap: _connectBangumi,
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: bangumiPink,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: bangumiPink.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.key_rounded,
                      size: 20,
                      color: Colors.white,
                    ),
                    SizedBox(width: 8),
                    Text(
                      '使用 Access Token 登录 (推荐)',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _loginThroughAniBaka,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                side: BorderSide(
                  color: theme.colorScheme.outline.withValues(alpha: 0.4),
                ),
              ),
              icon: const Icon(Icons.touch_app_rounded, size: 18),
              label: const Text(
                '点击授权登录 (网页跳转)',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: _openAccessTokenPage,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    '获取 Access Token',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _openBangumiManagement,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    '详细说明与设置',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '提示：若网络请求超时或验证失败，请开启代理软件。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
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
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: _isRegister
                ? Alignment.centerRight
                : Alignment.centerLeft,
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
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 180),
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
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 220),
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
                    validator: (v) =>
                        _isRegister && (v == null || v.trim().isEmpty)
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
                _obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 20,
              ),
              tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
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
