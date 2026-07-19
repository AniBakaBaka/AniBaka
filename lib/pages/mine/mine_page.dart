import 'package:cached_network_image/cached_network_image.dart';
import 'package:get/get.dart';
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/library/library_page.dart';
import 'package:baka/pages/player/download_page.dart';
import 'package:baka/pages/setting/app_settings_page.dart';
import 'package:baka/pages/source/source_management_page.dart';
import 'package:baka/pages/media_library/media_library_page.dart';
import 'package:baka/services/mine_service.dart';
import 'package:baka/pages/login/qr_scanner_page.dart';
import 'package:baka/utils/reg_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:baka/widgets/common/scale_button.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';

class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<StatefulWidget> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage>
    with SingleTickerProviderStateMixin {
  late final MineService _svc = MineService();

  // Animation for the header
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  late final Worker _loginWorker;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutQuart,
    );

    _svc.initUser();
    _loginWorker = ever(Get.find<AppState>().loginTrigger, (_) {
      if (mounted) {
        _svc.initUser();
        setState(() {});
      }
    });
    _controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _controller.value = 1;
    }
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
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              _buildHeader(context, isDark),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    const SizedBox(height: 24),
                    _buildDashboard(context, isDark),
                    const SizedBox(height: 32),
                    _buildSectionTitle(context, '常用功能'),
                    const SizedBox(height: 12),
                    _buildMenuGroup(context, isDark, [
                      _MenuItem(
                        title: '媒体库',
                        icon: Icons.video_library_rounded,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const MediaLibraryPage(),
                          ),
                        ),
                      ),
                      _MenuItem(
                        title: '源管理',
                        icon: Icons.extension_outlined,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SourceManagementPage(),
                          ),
                        ),
                      ),
                      _MenuItem(
                        title: '主题模式',
                        icon: Icons.brightness_6_outlined,
                        onTap: _showThemeDialog,
                        trailing: _buildValueTag(_svc.themeText, isDark),
                      ),
                      _MenuItem(
                        title: 'APP线路',
                        icon: Icons.swap_calls_outlined,
                        onTap: _switchHost,
                        trailing: _buildValueTag(_svc.currentHost, isDark),
                      ),
                      _MenuItem(
                        title: '支持开发',
                        icon: Icons.favorite_border,
                        onTap: _showSponsorDialog,
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.pinkAccent.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            '推荐',
                            style: TextStyle(
                              color: Colors.pinkAccent,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 24),
                    _buildSectionTitle(context, '法律声明'),
                    const SizedBox(height: 12),
                    _buildMenuGroup(context, isDark, [
                      _MenuItem(
                        title: '免责声明',
                        icon: Icons.gavel_outlined,
                        onTap: _showDisclaimerDialog,
                      ),
                    ]),
                    const SizedBox(height: 40),
                    Center(
                      child: Text(
                        'Baka v${Instances.appVersion}',
                        style: TextStyle(
                          color: isDark ? Colors.white24 : Colors.black26,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 100),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool isDark) {
    final bool isLogin = _svc.isLogin;
    final avatarUrl = getAvatar(avatar: _svc.avatarQq);
    final String name = _svc.displayName;
    final String subtitle = _svc.displaySubtitle;
    final reduceVisualEffects =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return SliverAppBar(
      expandedHeight: 180.0,
      collapsedHeight: 60,
      toolbarHeight: 60,
      pinned: true,
      stretch: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      elevation: 0,
      flexibleSpace: FlexibleSpaceBar(
        collapseMode: CollapseMode.pin,
        background: Stack(
          children: [
            Positioned(
              right: -50,
              top: -50,
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.2),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Align(
                      alignment: Alignment.topRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isLogin) ...[
                            ScaleButton(
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const QrScannerPage(),
                                ),
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Colors.white10
                                      : Colors.black.withValues(alpha: 0.04),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: isDark
                                        ? Colors.white12
                                        : Colors.black.withValues(alpha: 0.05),
                                  ),
                                ),
                                child: Icon(
                                  Icons.qr_code_scanner,
                                  size: 18,
                                  color: isDark ? Colors.white : Colors.black,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          ScaleButton(
                            onTap: _openSettings,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white10
                                    : Colors.black.withValues(alpha: 0.04),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: isDark
                                      ? Colors.white12
                                      : Colors.black.withValues(alpha: 0.05),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.settings_outlined,
                                    size: 18,
                                    color: isDark ? Colors.white : Colors.black,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        ScaleButton(
                          onTap: () {
                            if (!isLogin) {
                              Navigator.pushNamed(context, 'Baka://login');
                            }
                          },
                          child: Hero(
                            tag: 'avatar',
                            child: Container(
                              width: 80,
                              height: 80,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isDark
                                      ? Colors.white12
                                      : Colors.black12,
                                  width: 1,
                                ),
                                boxShadow: reduceVisualEffects
                                    ? null
                                    : [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.1,
                                          ),
                                          blurRadius: 20,
                                          offset: const Offset(0, 10),
                                        ),
                                      ],
                              ),
                              child: ClipOval(
                                child: isLogin
                                    ? CachedNetworkImage(
                                        imageUrl: avatarUrl,
                                        fit: BoxFit.cover,
                                        memCacheWidth: 200,
                                      )
                                    : Container(
                                        color: isDark
                                            ? Colors.white10
                                            : Colors.grey[200],
                                        child: Icon(
                                          Icons.person_outline,
                                          size: 40,
                                          color: isDark
                                              ? Colors.white54
                                              : Colors.black54,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                name,
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  color: isDark ? Colors.white : Colors.black,
                                  letterSpacing: -0.5,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                subtitle,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isDark
                                      ? Colors.white54
                                      : Colors.black54,
                                  height: 1.4,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (isLogin) ...[
                                const SizedBox(height: 8),
                                GestureDetector(
                                  onTap: _copyUid,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? Colors.white10
                                          : Colors.black.withValues(
                                              alpha: 0.05,
                                            ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'UID: ${_svc.uid}',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: isDark
                                            ? Colors.white38
                                            : Colors.black38,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: isDark ? Colors.white38 : Colors.black38,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildDashboard(BuildContext context, bool isDark) {
    final buttons = [
      _DashboardButton(
        title: '观看历史',
        icon: Icons.history,
        color: Colors.blueAccent,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const LibraryPage(initialIndex: 0)),
        ),
        isDark: isDark,
      ),
      _DashboardButton(
        title: '我的追番',
        icon: Icons.favorite_rounded,
        color: Colors.pinkAccent,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const LibraryPage(initialIndex: 1)),
        ),
        isDark: isDark,
      ),
      _DashboardButton(
        title: '离线缓存',
        icon: Icons.download_rounded,
        color: Colors.greenAccent,
        onTap: () => DownloadManagerPage.show(context),
        isDark: isDark,
      ),
      _DashboardButton(
        title: '交流吹水',
        icon: Icons.groups_rounded,
        color: Colors.cyanAccent.shade400,
        onTap: _joinQqGroup,
        isDark: isDark,
      ),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(40),
        border: Border.all(
          color: isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        children: [
          for (int i = 0; i < buttons.length; i++) ...[
            Expanded(child: buttons[i]),
            if (i < buttons.length - 1)
              Container(
                width: 1,
                height: 40,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: isDark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.black.withValues(alpha: 0.05),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildMenuGroup(
    BuildContext context,
    bool isDark,
    List<_MenuItem> items,
  ) {
    final reduceVisualEffects =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: reduceVisualEffects
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        item.icon,
                        size: 22,
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          item.title,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: isDark ? Colors.white : Colors.black,
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
                  indent: 58,
                  color: isDark
                      ? Colors.white10
                      : Colors.black.withValues(alpha: 0.05),
                ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Future<void> _copyUid() async {
    final copied = await _svc.copyUid();
    if (copied && mounted) showSnackBar('UID 已复制');
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AppSettingsPage()),
    );
  }

  void _showThemeDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) => SimpleDialog(
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
            Icon(Icons.check, color: Theme.of(context).colorScheme.primary),
        ],
      ),
    );
  }

  Widget _buildValueTag(String value, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white70 : Colors.black54,
        ),
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
      builder: (context) => AppDialog(
        title: '支持开发者',
        contentWidget: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.pinkAccent.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.favorite,
                color: Colors.pinkAccent,
                size: 32,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '如果你愿意支持这个项目，目前可通过 USDT（TRC20）转账赞助开发者。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'USDT 收款地址',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.6,
                      ),
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '请在支持 TRC20（波场网络）的钱包或交易平台中转账到下方地址。',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    MineService.tronUsdtAddress,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '说明：仅接受 USDT-TRC20 赞助 ，暂不接受国内平台赞助。',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: () => Navigator.pop(context),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('先不支持'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    await _svc.copySponsorAddress();
                    navigator.pop();
                    showSnackBar('USDT-TRC20 收款地址已复制');
                  },
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    backgroundColor: Colors.pinkAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
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

  void _showDisclaimerDialog() {
    showAppInfoDialog(
      context,
      title: '免责声明',
      content:
          '本软件仅供学习与交流使用，所有资源均来源于互联网。\n\n'
          '1. 本软件不提供任何视频内容的存储或上传服务。\n'
          '2. 视频版权均归原作者所有，如有侵权请联系我们删除。\n'
          '3. 请勿将本软件用于任何商业目的。',
      buttonText: '我知道啦',
    );
  }
}

class _DashboardButton extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool isDark;

  const _DashboardButton({
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return ScaleButton(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : Colors.black87,
              letterSpacing: -0.2,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
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
