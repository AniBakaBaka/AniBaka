import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:baka/app/update_presenter.dart';
import 'package:baka/app_state.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/core/content_filter.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/mine/mine_profile.dart';
import 'package:baka/pages/setting/ai_rule_settings_page.dart';
import 'package:baka/pages/setting/bangumi_sync_page.dart';
import 'package:baka/pages/setting/font_settings_page.dart';
import 'package:baka/pages/setting/labs_settings_page.dart';
import 'package:baka/pages/setting/playback_settings_page.dart';
import 'package:baka/pages/source/source_management_page.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/services/account/login_service.dart';
import 'package:baka/theme.dart';
import 'package:baka/core/app_logger.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:baka/widgets/platform/tv/tv_log_export_dialog.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';

class AppSettingsPage extends StatefulWidget {
  const AppSettingsPage({super.key});

  @override
  State<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends State<AppSettingsPage> {
  late final AppState _appState = Get.find<AppState>();
  late final AccountSession _session = Get.find<AccountSession>();
  late final LoginService _loginService = LoginService(
    _session,
    Get.find<ApiTransport>(),
  );

  String _cacheSize = '计算中...';
  bool _isClearing = false;
  bool _isExportingLogs = false;
  bool _isSharingLogs = false;
  bool _isCheckingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadCacheSize();
  }

  Future<void> _loadCacheSize() async {
    final size = await AppStorage.getCacheSize();
    if (mounted) setState(() => _cacheSize = formatBytes(size));
  }

  Future<void> _clearCache() async {
    HapticFeedback.mediumImpact();
    final confirm = await showAppConfirmDialog(
      context,
      title: '清理缓存',
      content: '将清理图片缓存和临时文件，不会影响您的账号数据和观看历史。',
      confirmText: '清理',
    );
    if (!confirm || !mounted) return;

    setState(() => _isClearing = true);
    final ok = await AppStorage.clearAllCache();
    if (!mounted) return;
    setState(() => _isClearing = false);

    if (ok) {
      showSnackBar('缓存已清理');
      HapticFeedback.mediumImpact();
      _loadCacheSize();
    } else {
      showSnackBar('清理失败，请重试');
      HapticFeedback.heavyImpact();
    }
  }

  Future<void> _exportLogs() async {
    if (_isExportingLogs) return;
    HapticFeedback.mediumImpact();
    setState(() => _isExportingLogs = true);
    try {
      AppLogger.instance.info('Export logs requested', tag: 'Settings');
      final archive = await AppLogger.instance.exportLogs();
      if (!mounted) return;
      if (archive == null) {
        showSnackBar('已取消导出日志');
      } else {
        showSnackBar(
          '日志已导出：${archive.fileName}',
          action: SnackBarAction(
            label: '打开',
            onPressed: () => OpenFilex.open(archive.file.path),
          ),
        );
      }
    } catch (e, st) {
      AppLogger.instance.error(
        'Export logs failed',
        tag: 'Settings',
        error: e,
        stackTrace: st,
      );
      if (mounted) showSnackBar('导出日志失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _isExportingLogs = false);
    }
  }

  Future<void> _shareLogs() async {
    if (_isSharingLogs) return;
    HapticFeedback.mediumImpact();
    setState(() => _isSharingLogs = true);
    try {
      AppLogger.instance.info('Share logs requested', tag: 'Settings');
      final result = await AppLogger.instance.shareLogs();
      if (!mounted) return;
      showSnackBar(switch (result.status) {
        ShareResultStatus.success => '日志已分享',
        ShareResultStatus.dismissed => '已取消分享日志',
        ShareResultStatus.unavailable => '已打开系统分享',
      });
    } catch (e, st) {
      AppLogger.instance.error(
        'Share logs failed',
        tag: 'Settings',
        error: e,
        stackTrace: st,
      );
      if (mounted) showSnackBar('分享日志失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _isSharingLogs = false);
    }
  }

  Future<void> _editUserField(String title, String field) async {
    HapticFeedback.selectionClick();
    final value = await showAppInputDialog(context, title: title);
    if (value == null || value.isEmpty || !_session.isLoggedIn) return;

    final user = _session.user.value;
    final result = await _loginService.updateUser(user, field, value);
    if (!mounted) return;
    showSnackBar(result.message, isError: !result.success);

    if (result.user != null) {
      await _session.saveUser(result.user!);
      HapticFeedback.mediumImpact();
    }
  }

  Future<void> _logout() async {
    HapticFeedback.mediumImpact();
    final ok = await showAppConfirmDialog(
      context,
      title: '退出 AniBaka',
      content:
          '退出后，播放历史将不再保存到 AniBaka 云端，也不能回复 AniBaka 评论。已连接的 Bangumi 账号不会被退出，其收藏与集数同步仍可继续使用。',
      confirmText: '退出',
      isDestructive: true,
    );
    if (!ok || !mounted) return;
    _session.logout();
    Navigator.pop(context);
  }

  Future<void> _showThemeModeDialog() async {
    HapticFeedback.selectionClick();
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择主题模式'),
        children: [
          for (var i = 0; i < AppState.themeModeLabels.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, i),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(AppState.themeModeLabels[i]),
                  if (_appState.themeMode == i)
                    Icon(
                      Icons.check_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null) _appState.setThemeMode(selected);
  }

  Future<void> _checkUpdate() async {
    if (_isCheckingUpdate) return;
    setState(() => _isCheckingUpdate = true);
    showSnackBar('正在检查更新...');
    try {
      final info = await VersionService.checkUpdateInfo();
      if (!mounted) return;
      if (info.hasUpdate) {
        VersionService.checkAndShowUpdate();
      } else {
        showSnackBar('当前已是最新版本 (v${Instances.appVersion})');
      }
    } catch (_) {
      if (mounted) showSnackBar('版本检查失败，请稍后重试', isError: true);
    } finally {
      if (mounted) setState(() => _isCheckingUpdate = false);
    }
  }

  void _switchHost() {
    _session.switchHost();
    setState(() {});
    showSnackBar('已切换至 ${_session.currentHost}，重启生效');
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

  void _pushPage(Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  Widget _buildAccountSection() {
    return Obx(() {
      final user = _session.user.value;
      final isLoggedIn = _session.isLoggedIn;
      final bgm = bangumiSession.account;
      final bgmLabel = !bangumiSession.isConnected
          ? '未关联'
          : (bgm?.nickname.isNotEmpty == true
                ? bgm!.nickname
                : (bgm?.username.isNotEmpty == true
                      ? '@${bgm!.username}'
                      : '已关联'));

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SettingsSectionHeader('账户与同步'),
          SettingsGroup(
            children: [
              if (isLoggedIn) ...[
                SettingsTile(
                  title: '昵称',
                  value: user.name,
                  icon: Icons.person_outline_rounded,
                  onTap: () => _editUserField('修改昵称', 'name'),
                ),
                SettingsTile(
                  title: 'QQ',
                  value: user.qq,
                  icon: Icons.chat_bubble_outline_rounded,
                  onTap: () => _editUserField('修改QQ', 'qq'),
                ),
                SettingsTile(
                  title: '个性签名',
                  value: user.sign,
                  icon: Icons.edit_note_rounded,
                  onTap: () => _editUserField('修改签名', 'sign'),
                  showDivider: true,
                ),
                if (user.hasPassword)
                  SettingsTile(
                    title: '修改密码',
                    value: '******',
                    icon: Icons.lock_outline_rounded,
                    onTap: () => _editUserField('修改密码', 'pwd'),
                    showDivider: true,
                  ),
              ] else
                SettingsTile(
                  title: 'AniBaka 账号',
                  value: '未登录',
                  icon: Icons.account_circle_outlined,
                  onTap: () => Navigator.pushNamed(context, 'Baka://login'),
                  showDivider: true,
                ),
              SettingsTile(
                title: 'Bangumi 同步',
                value: bgmLabel,
                icon: Icons.sync_alt_rounded,
                onTap: () => _pushPage(const BangumiSyncPage()),
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      );
    });
  }

  Widget _buildPlaybackSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsSectionHeader('播放与拓展'),
        SettingsGroup(
          children: [
            SettingsTile(
              title: '播放设置',
              value: '解码 / 渲染 / 广告过滤 / 跳过片头等',
              icon: Icons.play_circle_outline_rounded,
              onTap: () => _pushPage(const PlaybackSettingsPage()),
            ),
            ListenableBuilder(
              listenable: ruleRepository,
              builder: (context, _) => SettingsTile(
                title: '搜索源管理',
                value: ruleRepository.updateCount > 0
                    ? '${ruleRepository.updateCount} 个源有更新'
                    : '开关 / 排序 / 自定义导入',
                icon: Icons.extension_rounded,
                iconWidget: Badge.count(
                  count: ruleRepository.updateCount,
                  isLabelVisible: ruleRepository.updateCount > 0,
                  child: const Icon(Icons.extension_rounded, size: 18),
                ),
                onTap: () => _pushPage(const SourceManagementPage()),
              ),
            ),
            SettingsTile(
              title: 'AI 规则编写',
              value: 'OpenAI 兼容模型 / API Key',
              icon: Icons.auto_awesome_rounded,
              onTap: () => _pushPage(const AiRuleSettingsPage()),
              showDivider: Platform.isWindows,
            ),
            if (Platform.isWindows)
              SettingsTile(
                title: '实验室',
                value: 'DLSS 5 视频增强',
                icon: Icons.science_outlined,
                onTap: () => _pushPage(const LabsSettingsPage()),
                showDivider: false,
              ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildAppearanceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsSectionHeader('外观与交互'),
        Obx(
          () => SettingsGroup(
            children: [
              SettingsTile(
                title: '主题模式',
                value: _appState.themeModeLabel,
                icon: Icons.brightness_6_outlined,
                onTap: _showThemeModeDialog,
              ),
              SettingsSwitchTile(
                title: '动态取色',
                subtitle: '使用系统壁纸或强调色生成 Material 3 配色',
                value: _appState.dynamicColor,
                icon: Icons.palette_outlined,
                onChanged: _appState.setDynamicColor,
              ),
              SettingsTile(
                title: '字体',
                value: AppFonts.getLabelForFont(_appState.fontFamily),
                icon: Icons.font_download_rounded,
                onTap: () => _pushPage(const FontSettingsPage()),
              ),
              SettingsSwitchTile(
                title: '减少视觉效果',
                subtitle: '关闭动效、毛玻璃与自动轮播，并减少装饰阴影',
                value: _appState.reduceVisualEffects,
                icon: Icons.motion_photos_off_outlined,
                onChanged: _appState.setReduceVisualEffects,
              ),
              SettingsSwitchTile(
                title: '滑动时隐藏底栏',
                subtitle: '向下浏览内容时收起底部导航',
                value: _appState.isHideBottomNavOnScroll.value,
                icon: Icons.swipe_down_rounded,
                onChanged: _appState.toggleHideBottomNavOnScroll,
                showDivider: false,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildStorageSection() {
    final isTV = Instances.isTV;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsSectionHeader('存储与诊断'),
        SettingsGroup(
          children: [
            SettingsTile(
              title: '清理缓存',
              value: _isClearing ? '清理中...' : _cacheSize,
              icon: Icons.cleaning_services_rounded,
              onTap: _isClearing ? null : _clearCache,
            ),
            SettingsTile(
              title: '导出日志',
              value: isTV ? '手机扫码下载' : (_isExportingLogs ? '导出中...' : 'ZIP'),
              icon: Icons.file_download_outlined,
              onTap: isTV
                  ? () => showTvLogExportDialog(context)
                  : (_isExportingLogs ? null : _exportLogs),
              showDivider: !isTV,
            ),
            if (!isTV)
              SettingsTile(
                title: '分享日志',
                value: _isSharingLogs ? '准备中...' : '系统分享',
                icon: Icons.ios_share_rounded,
                onTap: _isSharingLogs ? null : _shareLogs,
                showDivider: false,
              ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildAboutSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsSectionHeader('关于与支持'),
        SettingsGroup(
          children: [
            SettingsTile(
              title: '检查更新',
              value: _isCheckingUpdate ? '检查中...' : 'v${Instances.appVersion}',
              icon: Icons.system_update_alt_rounded,
              onTap: _checkUpdate,
            ),
            SettingsTile(
              title: 'APP 线路',
              value: _session.currentHost,
              icon: Icons.swap_calls_outlined,
              onTap: _switchHost,
            ),
            SettingsTile(
              title: '免责声明',
              value: '条款说明',
              icon: Icons.gavel_outlined,
              onTap: _showDisclaimerDialog,
            ),
            SettingsTile(
              title: 'GitHub 开源',
              value: 'AniBaka',
              icon: Icons.code_rounded,
              onTap: () => launchUrlString(
                'https://github.com/AniBakaBaka/AniBaka',
                mode: LaunchMode.externalApplication,
              ),
              showDivider: false,
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          const SettingsSliverAppBar(title: '设置'),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList.list(
              children: [
                const SizedBox(height: 20),
                _buildAccountSection(),
                _buildPlaybackSection(),
                const SettingsSectionHeader('内容偏好'),
                SettingsGroup(
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: contentFilter,
                      builder: (context, enabled, _) => SettingsSwitchTile(
                        title: '隐藏 NSFW 内容',
                        subtitle: '开启后隐藏被数据源标记为 NSFW 的内容',
                        icon: Icons.visibility_off_outlined,
                        value: enabled,
                        onChanged: (value) =>
                            contentFilter.setEnabled(value, Instances.sp),
                        showDivider: false,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildAppearanceSection(),
                _buildStorageSection(),
                _buildAboutSection(),
                Obx(() {
                  if (!_session.isLoggedIn) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 36),
                    child: FilledButton.tonalIcon(
                      onPressed: _logout,
                      icon: const Icon(Icons.logout_rounded),
                      label: const Text('退出登录'),
                      style: FilledButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 48),
                Center(
                  child: Text(
                    'Designed for Baka',
                    style: TextStyle(
                      color: isDark ? Colors.white24 : Colors.black26,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
