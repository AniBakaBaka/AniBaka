import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:baka/app/update_presenter.dart';
import 'package:baka/app_state.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/core/app_logger.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/core/content_filter.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/mine/mine_profile.dart';
import 'package:baka/pages/setting/ai_rule_settings_page.dart';
import 'package:baka/pages/setting/bangumi_sync_page.dart';
import 'package:baka/pages/login/account_security_page.dart';
import 'package:baka/pages/setting/labs_settings_page.dart';
import 'package:baka/pages/setting/network_settings_page.dart';
import 'package:baka/pages/setting/playback_settings_page.dart';
import 'package:baka/pages/source/source_management_page.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/services/account/login_service.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'package:baka/theme.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:baka/widgets/dialog/update_dialog.dart';
import 'package:baka/widgets/platform/tv/tv_log_export_dialog.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';

class AppSettingsPage extends StatefulWidget {
  const AppSettingsPage({super.key});

  @override
  State<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends State<AppSettingsPage> {
  final _appState = Get.find<AppState>();
  final _session = Get.find<AccountSession>();
  String? _cacheSize;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _loadCacheSize();
  }

  Future<void> _loadCacheSize() async {
    final size = await AppStorage.getCacheSize();
    if (mounted) setState(() => _cacheSize = formatBytes(size));
  }

  Future<void> _run(String action, Future<void> Function() task) async {
    if (_busy != null) return;
    setState(() => _busy = action);
    try {
      await task();
    } catch (e) {
      showSnackBar('$action失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _clearCache() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: '清理缓存',
      content: '清理图片缓存和临时文件',
      confirmText: '清理',
    );
    if (!confirmed) return;
    await _run('清理缓存', () async {
      final ok = await AppStorage.clearAllCache();
      showSnackBar(ok ? '缓存已清理' : '清理缓存失败', isError: !ok);
      await _loadCacheSize();
    });
  }

  Future<void> _exportLogs() => _run('导出日志', () async {
    final archive = await AppLogger.instance.exportLogs();
    if (archive == null) return;
    showSnackBar(
      '日志已导出：${archive.fileName}',
      action: SnackBarAction(
        label: '打开',
        onPressed: () => OpenFilex.open(archive.file.path),
      ),
    );
  });

  Future<void> _checkUpdate() => _run('检查更新', () async {
    final info = await VersionService.checkUpdateInfo();
    if (info.hasUpdate) {
      showAnnouncementDialog(content: '', updateInfo: info);
    } else {
      showSnackBar('已是最新版本');
    }
  });

  Future<void> _editUser(String title, String field) async {
    final value = await showAppInputDialog(context, title: title);
    if (value == null || (value.isEmpty && field != 'qq')) return;
    var currentPassword = '';
    if (field == 'qq' && value.trim() != _session.user.value.qq) {
      if (!mounted) return;
      final password = await showAppInputDialog(
        context,
        title: '修改 QQ 需验证当前密码',
        obscureText: true,
      );
      if (password == null || password.isEmpty) return;
      currentPassword = password;
    }
    final result = await LoginService(_session, apiTransport).updateUser(
      _session.user.value,
      field,
      value,
      currentPassword: currentPassword,
    );
    showSnackBar(result.message, isError: !result.success);
    if (result.user case final user?) await _session.saveUser(user);
  }

  Future<void> _logout() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: '退出登录',
      content: '确定退出 AniBaka 账号？',
      confirmText: '退出',
      isDestructive: true,
    );
    if (!confirmed) return;
    _session.logout();
    if (mounted) Navigator.pop(context);
  }

  void _switchHost() {
    _session.switchHost();
    setState(() {});
    showSnackBar('已切换至 ${_session.currentHost}，重启生效');
  }

  Future<void> _push(Widget page) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: '设置',
      children: [
        Obx(() {
          final user = _session.user.value;
          final loggedIn = _session.isLoggedIn;
          return SettingsSection(
            title: '账户',
            children: [
              if (loggedIn) ...[
                SettingsTile(
                  icon: Icons.person_outline_rounded,
                  title: '昵称',
                  value: user.name,
                  onTap: () => _editUser('修改昵称', 'name'),
                ),
                SettingsTile(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: 'QQ',
                  value: user.qq,
                  onTap: () => _editUser('修改 QQ', 'qq'),
                ),
                SettingsTile(
                  icon: Icons.edit_note_rounded,
                  title: '个性签名',
                  value: user.sign,
                  onTap: () => _editUser('修改签名', 'sign'),
                ),
                SettingsTile(
                  icon: Icons.verified_user_outlined,
                  title: '账户安全',
                  value: user.recoveryEmail.isNotEmpty
                      ? user.recoveryEmail
                      : '修改密码 · 可选绑定邮箱',
                  onTap: () => _push(const AccountSecurityPage()),
                ),
              ] else
                SettingsTile(
                  icon: Icons.account_circle_outlined,
                  title: 'AniBaka 账号',
                  value: '未登录',
                  onTap: () => Navigator.pushNamed(context, 'Baka://login'),
                ),
              SettingsTile(
                icon: Icons.sync_alt_rounded,
                title: 'Bangumi 同步',
                value: bangumiSession.account?.nickname ?? '未关联',
                onTap: () async {
                  await _push(const BangumiSyncPage());
                  _session.refreshView();
                },
              ),
              if (loggedIn)
                SettingsTile(
                  icon: Icons.logout_rounded,
                  title: '退出登录',
                  color: Theme.of(context).colorScheme.error,
                  onTap: _logout,
                ),
            ],
          );
        }),
        SettingsSection(
          title: '播放与扩展',
          children: [
            SettingsTile(
              icon: Icons.play_circle_outline_rounded,
              title: '播放设置',
              onTap: () => _push(const PlaybackSettingsPage()),
            ),
            ListenableBuilder(
              listenable: ruleRepository,
              builder: (context, _) => SettingsTile(
                icon: Icons.extension_outlined,
                title: '搜索源管理',
                value: ruleRepository.updateCount > 0
                    ? '${ruleRepository.updateCount} 个更新'
                    : null,
                onTap: () => _push(const SourceManagementPage()),
              ),
            ),
            SettingsTile(
              icon: Icons.auto_awesome_outlined,
              title: 'AI 规则编写',
              onTap: () => _push(const AiRuleSettingsPage()),
            ),
            if (Platform.isWindows)
              SettingsTile(
                icon: Icons.science_outlined,
                title: '实验室',
                onTap: () => _push(const LabsSettingsPage()),
              ),
          ],
        ),
        Obx(
          () => SettingsSection(
            title: '外观',
            children: [
              SettingsSelectTile<int>(
                icon: Icons.brightness_6_outlined,
                title: '主题模式',
                value: _appState.themeMode,
                options: AppState.themeModeLabels.asMap(),
                onChanged: _appState.setThemeMode,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.palette_outlined),
                title: const Text('动态取色'),
                value: _appState.dynamicColor,
                onChanged: _appState.setDynamicColor,
              ),
              SettingsSelectTile<String>(
                icon: Icons.font_download_outlined,
                title: '字体',
                value: _appState.fontFamily,
                options: AppFonts.fontOptions,
                onChanged: _appState.setFontFamily,
              ),
              SettingsSelectTile<int>(
                icon: Icons.format_bold_rounded,
                title: '字重',
                value: _appState.fontWeightIndex,
                options: AppFonts.weightLabels.asMap(),
                onChanged: _appState.setFontWeightIndex,
              ),
              SettingsSliderTile(
                icon: Icons.format_size_rounded,
                title: '字号',
                value: _appState.fontScale,
                min: .8,
                max: 1.3,
                divisions: 10,
                label: '${(_appState.fontScale * 100).round()}%',
                onChanged: _appState.setFontScale,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.motion_photos_off_outlined),
                title: const Text('减少视觉效果'),
                value: _appState.reduceVisualEffects,
                onChanged: _appState.setReduceVisualEffects,
              ),
            ],
          ),
        ),
        SettingsSection(
          title: '浏览',
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: contentFilter,
              builder: (context, enabled, _) => SwitchListTile(
                secondary: const Icon(Icons.visibility_off_outlined),
                title: const Text('隐藏 NSFW 内容'),
                value: enabled,
                onChanged: (value) =>
                    contentFilter.setEnabled(value, Instances.sp),
              ),
            ),
            if (!Instances.isDesktopPlatform)
              Obx(
                () => SwitchListTile(
                  secondary: const Icon(Icons.swipe_down_outlined),
                  title: const Text('滑动时隐藏底栏'),
                  value: _appState.isHideBottomNavOnScroll.value,
                  onChanged: _appState.toggleHideBottomNavOnScroll,
                ),
              ),
          ],
        ),
        SettingsSection(
          title: '网络',
          children: [
            SettingsTile(
              icon: Icons.swap_calls_outlined,
              title: 'APP 线路',
              value: _session.currentHost,
              trailingIcon: Icons.swap_horiz_rounded,
              onTap: _switchHost,
            ),
            SettingsTile(
              icon: Icons.security_outlined,
              title: '网络设置',
              onTap: () => _push(const NetworkSettingsPage()),
            ),
          ],
        ),
        SettingsSection(
          title: '存储与诊断',
          children: [
            SettingsTile(
              icon: Icons.cleaning_services_outlined,
              title: '清理缓存',
              value: _cacheSize,
              busy: _busy == '清理缓存',
              onTap: _clearCache,
            ),
            SettingsTile(
              icon: Icons.file_download_outlined,
              title: '导出日志',
              busy: _busy == '导出日志',
              onTap: Instances.isTV
                  ? () => showTvLogExportDialog(context)
                  : _exportLogs,
            ),
            if (!Instances.isTV)
              SettingsTile(
                icon: Icons.ios_share_rounded,
                title: '分享日志',
                busy: _busy == '分享日志',
                onTap: () => _run('分享日志', AppLogger.instance.shareLogs),
              ),
          ],
        ),
        SettingsSection(
          title: '关于',
          children: [
            SettingsTile(
              icon: Icons.system_update_alt_rounded,
              title: '检查更新',
              value: 'v${Instances.appVersion}',
              busy: _busy == '检查更新',
              onTap: _checkUpdate,
            ),
            SettingsTile(
              icon: Icons.gavel_outlined,
              title: '免责声明',
              onTap: () => showAppInfoDialog(
                context,
                title: '免责声明',
                content:
                    '本软件仅供学习与交流使用，所有资源均来源于互联网。\n\n'
                    '1. 本软件不提供任何视频内容的存储或上传服务。\n'
                    '2. 视频版权均归原作者所有，如有侵权请联系我们删除。\n'
                    '3. 请勿将本软件用于任何商业目的。',
                buttonText: '我知道啦',
              ),
            ),
            SettingsTile(
              icon: Icons.code_rounded,
              title: 'GitHub',
              value: 'AniBaka',
              trailingIcon: Icons.open_in_new_rounded,
              onTap: () => launchUrlString(
                'https://github.com/AniBakaBaka/AniBaka',
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
