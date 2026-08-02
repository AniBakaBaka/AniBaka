import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/mine_service.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/widgets/platform/tv/tv_log_export_dialog.dart';
import 'package:baka/widgets/platform/tv/tv_qr_login_page.dart';

class TvMyPage extends StatefulWidget {
  const TvMyPage({super.key});

  @override
  State<TvMyPage> createState() => _TvMyPageState();
}

class _TvMyPageState extends State<TvMyPage> {
  late final MineService _svc = MineService();
  late final Worker _loginWorker;

  @override
  void initState() {
    super.initState();
    _loginWorker = ever(Get.find<AppState>().loginTrigger, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _loginWorker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.tvBgColor,
      body: Focus(
        canRequestFocus: false,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.escape ||
                  event.logicalKey == LogicalKeyboardKey.goBack)) {
            Navigator.of(context).maybePop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: SafeArea(
          child: Row(
            children: [
              SizedBox(
                width: 360,
                child: Padding(
                  padding: const EdgeInsets.all(48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TvFocusable(
                        autofocus: true,
                        onPressed: () => Navigator.of(context).maybePop(),
                        borderRadius: BorderRadius.circular(24),
                        enableScale: false,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: context.tvHighlightColor(0.1),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.arrow_back,
                                color: context.tvTextSecondaryColor,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '返回',
                                style: TextStyle(
                                  color: context.tvTextSecondaryColor,
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 40),

                      _buildProfile(),

                      const Spacer(),

                      Text(
                        'Baka v${Instances.appVersion}',
                        style: TextStyle(
                          color: context.tvTextHintColor,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              Container(width: 1, color: context.tvHighlightColor(0.08)),

              Expanded(
                child: FocusTraversalGroup(
                  policy: ReadingOrderTraversalPolicy(),
                  child: Padding(
                    padding: const EdgeInsets.all(48),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '功能',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: context.tvTextHintColor,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 24),

                        Expanded(
                          child: Wrap(
                            spacing: 16,
                            runSpacing: 16,
                            children: [
                              _buildMenuItem(
                                icon: Icons.history,
                                title: '观看历史',
                                color: Colors.blueAccent,
                                onPressed: () => NavigationService.toLibrary(
                                  context,
                                  initialIndex: 0,
                                ),
                              ),
                              _buildMenuItem(
                                icon: Icons.favorite_rounded,
                                title: '我的追番',
                                color: Colors.pinkAccent,
                                onPressed: () => NavigationService.toLibrary(
                                  context,
                                  initialIndex: 1,
                                ),
                              ),
                              _buildMenuItem(
                                icon: Icons.extension_outlined,
                                title: '源管理',
                                color: Colors.orangeAccent,
                                onPressed: () =>
                                    NavigationService.toSourceManagement(
                                      context,
                                    ),
                              ),
                              _buildMenuItem(
                                icon: Icons.settings_outlined,
                                title: '设置',
                                color: Colors.grey,
                                onPressed: () =>
                                    NavigationService.toAppSettings(context),
                              ),
                              _buildMenuItem(
                                icon: Icons.qr_code_2_rounded,
                                title: '导出日志',
                                subtitle: '手机扫码下载',
                                color: Colors.indigoAccent,
                                onPressed: () => showTvLogExportDialog(context),
                              ),
                              if (!_svc.isLogin)
                                _buildMenuItem(
                                  icon: Icons.login,
                                  title: '登录',
                                  color: Colors.greenAccent,
                                  onPressed: _openQrLogin,
                                ),
                              _buildMenuItem(
                                icon: Icons.swap_calls_outlined,
                                title: 'APP线路',
                                subtitle: _svc.currentHost,
                                color: Colors.tealAccent,
                                onPressed: () {
                                  _svc.switchHost();
                                  setState(() {});
                                  showSnackBar('已切换至 ${_svc.currentHost}，重启生效');
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfile() {
    final profile = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: context.tvTextHintColor, width: 2),
          ),
          child: ClipOval(
            child: _svc.hasIdentity && _svc.avatarUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: _svc.avatarUrl,
                    fit: BoxFit.cover,
                  )
                : Container(
                    color: context.tvHighlightColor(0.1),
                    child: Icon(
                      Icons.person_outline,
                      size: 48,
                      color: context.tvTextSecondaryColor,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          _svc.hasIdentity ? _svc.displayName : '点击登录',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: _svc.hasIdentity
                ? context.tvTextColor
                : Theme.of(context).colorScheme.primary,
            letterSpacing: -0.5,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        Text(
          _svc.displaySubtitle,
          style: TextStyle(fontSize: 14, color: context.tvTextSecondaryColor),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );

    if (_svc.isLogin) return profile;

    return TvFocusable(
      enableScale: false,
      enableGlow: false,
      borderRadius: BorderRadius.circular(12),
      onPressed: _openQrLogin,
      child: profile,
    );
  }

  void _openQrLogin() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const TvQrLoginPage()),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String title,
    required Color color,
    required VoidCallback onPressed,
    String? subtitle,
  }) {
    return TvFocusable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 180,
        height: 120,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: context.tvHighlightColor(0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.tvHighlightColor(0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const Spacer(),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: context.tvTextColor,
              ),
            ),
            if (subtitle != null)
              Text(
                subtitle,
                style: TextStyle(fontSize: 11, color: context.tvTextHintColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }
}
