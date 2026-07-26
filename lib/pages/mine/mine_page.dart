import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/library/library_page.dart';
import 'package:baka/pages/login/qr_scanner_page.dart';
import 'package:baka/pages/media_library/media_library_page.dart';
import 'package:baka/pages/player/download_page.dart';
import 'package:baka/pages/setting/app_settings_page.dart';
import 'package:baka/pages/source/source_management_page.dart';
import 'package:baka/services/mine_service.dart';
import 'package:baka/services/version_service.dart';
import 'package:baka/utils/reg_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/common/scale_button.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';

class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<StatefulWidget> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> with SingleTickerProviderStateMixin {
  late final MineService _svc = MineService();
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Worker _loginWorker;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _loginWorker = ever(Get.find<AppState>().loginTrigger, (_) {
      if (mounted) setState(() {});
    });
    _controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.reduceMotion) _controller.value = 1;
  }

  @override
  void dispose() {
    _controller.dispose();
    _loginWorker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              _buildHeader(context, isDark),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    const SizedBox(height: 16),
                    _buildDashboard(context, isDark),
                    const SizedBox(height: 12),
                    _buildFeatureCards(context, isDark),
                    const SizedBox(height: 16),
                    _buildSectionTitle(context, '设置与支持'),
                    const SizedBox(height: 8),
                    _buildMenuGroup(context, isDark, [
                      _MenuItem(
                        title: '主题模式',
                        icon: Icons.brightness_6_outlined,
                        onTap: _showThemeDialog,
                        trailing: _buildTag(_svc.themeText, isDark),
                      ),
                      _MenuItem(
                        title: 'APP线路',
                        icon: Icons.swap_calls_outlined,
                        onTap: _switchHost,
                        trailing: _buildTag(_svc.currentHost, isDark),
                      ),
                      _MenuItem(
                        title: '支持开发',
                        icon: Icons.favorite_border,
                        onTap: _showSponsorDialog,
                        trailing: _buildTag('推荐', isDark, color: Colors.pinkAccent),
                      ),
                      _MenuItem(
                        title: '版本更新',
                        icon: Icons.system_update_alt_rounded,
                        onTap: _checkUpdate,
                        trailing: _buildTag('v${Instances.appVersion}', isDark),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    _buildSectionTitle(context, '法律声明'),
                    const SizedBox(height: 8),
                    _buildMenuGroup(context, isDark, [
                      _MenuItem(
                        title: '免责声明',
                        icon: Icons.gavel_outlined,
                        onTap: _showDisclaimerDialog,
                      ),
                    ]),
                    const SizedBox(height: 24),
                    Center(
                      child: Text(
                        'Baka v${Instances.appVersion}',
                        style: TextStyle(
                          color: isDark ? Colors.white30 : Colors.black38,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _navTo(Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  Widget _buildHeader(BuildContext context, bool isDark) {
    final bool isLogin = _svc.isLogin;

    return SliverToBoxAdapter(
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 40, 16, 14),
          child: Row(
            children: [
              ScaleButton(
                onTap: () {
                  if (!isLogin) Navigator.pushNamed(context, 'Baka://login');
                },
                child: CircleAvatar(
                  radius: 30,
                  backgroundColor: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
                  backgroundImage: isLogin ? CachedNetworkImageProvider(getAvatar(avatar: _svc.avatarQq)) : null,
                  child: !isLogin
                      ? Icon(Icons.person_outline, size: 30, color: isDark ? Colors.white70 : Colors.black54)
                      : null,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _svc.displayName,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _svc.displaySubtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (isLogin) ...[
                      const SizedBox(height: 4),
                      GestureDetector(
                        onTap: _copyUid,
                        child: Text(
                          'UID: ${_svc.uid}',
                          style: TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            color: isDark ? Colors.white38 : Colors.black38,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isLogin)
                    _buildHeaderBtn(
                      icon: Icons.qr_code_scanner,
                      onTap: () => _navTo(const QrScannerPage()),
                      isDark: isDark,
                    ),
                  if (isLogin) const SizedBox(width: 6),
                  _buildHeaderBtn(
                    icon: Icons.settings_outlined,
                    onTap: () => _navTo(const AppSettingsPage()),
                    isDark: isDark,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderBtn({
    required IconData icon,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return ScaleButton(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 20, color: isDark ? Colors.white70 : Colors.black87),
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white38 : Colors.black45,
        ),
      ),
    );
  }

  Widget _buildDashboard(BuildContext context, bool isDark) {
    final buttons = [
      _DashItem('历史', Icons.history, Colors.blueAccent, () => _navTo(const LibraryPage(initialIndex: 0))),
      _DashItem('追番', Icons.favorite_border, Colors.pinkAccent, () => _navTo(const LibraryPage(initialIndex: 1))),
      _DashItem('下载', Icons.download_outlined, Colors.greenAccent, () => DownloadManagerPage.show(context)),
      _DashItem('社区', Icons.groups_outlined, Colors.cyanAccent.shade400, _joinQqGroup),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: buttons.map((item) {
          return Expanded(
            child: ScaleButton(
              onTap: item.onTap,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(item.icon, color: item.color, size: 22),
                  const SizedBox(height: 6),
                  Text(
                    item.title,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMenuGroup(BuildContext context, bool isDark, List<_MenuItem> items) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.04),
        ),
      ),
      child: Column(
        children: items.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;
          final isLast = index == items.length - 1;

          return Column(
            children: [
              ScaleButton(
                onTap: item.onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Icon(item.icon, size: 20, color: isDark ? Colors.white70 : Colors.black87),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          item.title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                      ),
                      if (item.trailing != null) item.trailing!,
                      if (item.trailing == null)
                        Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: isDark ? Colors.white24 : Colors.black26,
                        ),
                    ],
                  ),
                ),
              ),
              if (!isLast)
                Divider(
                  height: 1,
                  thickness: 0.5,
                  indent: 48,
                  color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
                ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTag(String text, bool isDark, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: (color ?? (isDark ? Colors.white : Colors.black)).withValues(alpha: color != null ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color ?? (isDark ? Colors.white70 : Colors.black54),
        ),
      ),
    );
  }

  Future<void> _copyUid() async {
    final copied = await _svc.copyUid();
    if (copied && mounted) showSnackBar('UID 已复制');
  }

  void _showThemeDialog() {
    showDialog(
      context: context,
      builder: (_) => SimpleDialog(
        elevation: 0,
        shadowColor: Colors.transparent,
        title: const Text('选择主题模式'),
        children: [
          _themeOption('跟随系统', 0),
          _themeOption('浅色模式', 1),
          _themeOption('深色模式', 2),
        ],
      ),
    );
  }

  Widget _themeOption(String title, int mode) {
    return SimpleDialogOption(
      onPressed: () {
        Navigator.pop(context);
        setState(() => _svc.switchTheme(mode));
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title),
          if (_svc.themeMode == mode)
            Icon(Icons.check, color: Theme.of(context).colorScheme.primary, size: 18),
        ],
      ),
    );
  }

  void _switchHost() {
    _svc.switchHost();
    setState(() {});
    showSnackBar('已切换至 ${_svc.currentHost}，重启生效');
  }

  Future<void> _joinQqGroup() async {
    final success = await _svc.joinQqGroup();
    if (!success && mounted) {
      showSnackBar('无法打开 QQ 群 ${MineService.qqGroupNumber}，请稍后重试');
    }
  }

  void _showSponsorDialog() {
    final colorScheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (ctx) => AppDialog(
        title: '支持开发者',
        contentWidget: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.favorite, color: Colors.pinkAccent, size: 36),
            const SizedBox(height: 12),
            Text(
              '可通过 USDT（TRC20）转账赞助开发者。',
              style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                MineService.tronUsdtAddress,
                style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: colorScheme.onSurface),
              ),
            ),
          ],
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('稍后再说'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () async {
                    await _svc.copySponsorAddress();
                    if (ctx.mounted) Navigator.pop(ctx);
                    showSnackBar('USDT-TRC20 收款地址已复制');
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.pinkAccent,
                    elevation: 0,
                    shadowColor: Colors.transparent,
                  ),
                  child: const Text('复制地址'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureCards(BuildContext context, bool isDark) {
    return Row(
      children: [
        Expanded(
          child: _FeatureCard(
            title: '媒体库',
            subtitle: '本地与影视资源',
            icon: Icons.video_library_outlined,
            color: Colors.indigoAccent,
            isDark: isDark,
            onTap: () => _navTo(const MediaLibraryPage()),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _FeatureCard(
            title: '源管理',
            subtitle: '扩展与自定义源',
            icon: Icons.extension_outlined,
            color: Colors.deepOrangeAccent,
            isDark: isDark,
            onTap: () => _navTo(const SourceManagementPage()),
          ),
        ),
      ],
    );
  }

  void _showDisclaimerDialog() {
    showAppInfoDialog(
      context,
      title: '免责声明',
      content: '本软件仅供学习与交流使用，所有资源均来源于互联网。\n\n'
          '1. 本软件不提供任何视频内容的存储或上传服务。\n'
          '2. 视频版权均归原作者所有，如有侵权请联系我们删除。\n'
          '3. 请勿将本软件用于任何商业目的。',
      buttonText: '我知道啦',
    );
  }

  Future<void> _checkUpdate() async {
    showSnackBar('正在检查更新...');
    try {
      final info = await VersionService.checkUpdateInfo();
      if (mounted) {
        if (info.hasUpdate) {
          VersionService.checkAndShowUpdate();
        } else {
          showSnackBar('当前已是最新版本 (v${Instances.appVersion})');
        }
      }
    } catch (_) {
      if (mounted) showSnackBar('版本检查失败，请稍后重试');
    }
  }
}

class _FeatureCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final bool isDark;
  final VoidCallback onTap;

  const _FeatureCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ScaleButton(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 10,
                      color: isDark ? Colors.white54 : Colors.black54,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashItem {
  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  _DashItem(this.title, this.icon, this.color, this.onTap);
}

class _MenuItem {
  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final Widget? trailing;

  _MenuItem({
    required this.title,
    required this.icon,
    required this.onTap,
    this.trailing,
  });
}
