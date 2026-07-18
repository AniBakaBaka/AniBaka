import 'dart:convert';
import 'package:baka/api/post.dart';
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:get/get.dart';
import 'package:baka/services/cache_manager.dart';
import 'package:baka/utils/app_logger.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:baka/pages/setting/font_settings_page.dart';
import 'package:baka/pages/setting/playback_settings_page.dart';
import 'package:baka/pages/source/source_management_page.dart';
import 'package:baka/theme.dart';
import 'package:flutter/material.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';

class AppSettingsPage extends StatefulWidget {
  const AppSettingsPage({super.key});

  @override
  State<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends State<AppSettingsPage> {
  final _appState = Get.find<AppState>();

  Map<String, dynamic>? _userInfo;
  String _cacheSize = '计算中...';
  bool _isClearing = false;
  bool _isExportingLogs = false;
  bool _isSharingLogs = false;

  @override
  void initState() {
    super.initState();
    final storedUser = Instances.sp.getString('userinfo');
    if (storedUser != null) {
      _userInfo = Map<String, dynamic>.from(jsonDecode(storedUser));
    }
    _loadCacheSize();
  }

  Future<void> _loadCacheSize() async {
    final size = await CacheManagerService.instance.getCacheSize();
    if (mounted) {
      setState(() {
        _cacheSize = CacheManagerService.formatSize(size);
      });
    }
  }

  Future<void> _clearCache() async {
    HapticFeedback.mediumImpact();
    final action = await showAppConfirmDialog(
      context,
      title: '清理缓存',
      content: '将清理图片缓存和临时文件，不会影响您的账号数据和观看历史。',
      confirmText: '清理',
    );

    if (action == DialogAction.confirm) {
      setState(() => _isClearing = true);
      final success = await CacheManagerService.instance.clearAllCache();
      if (mounted) {
        setState(() => _isClearing = false);
        if (success) {
          showSnackBar('缓存已清理');
          HapticFeedback.mediumImpact();
          _loadCacheSize();
        } else {
          showSnackBar('清理失败，请重试');
          HapticFeedback.heavyImpact();
        }
      }
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
        return;
      }

      showActionSnackBar(
        '日志已导出：${archive.fileName}',
        actionLabel: '打开',
        onAction: () => OpenFilex.open(archive.file.path),
      );
    } catch (error, stackTrace) {
      AppLogger.instance.error(
        'Export logs failed',
        tag: 'Settings',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        showSnackBar('导出日志失败：$error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isExportingLogs = false);
      }
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

      switch (result.status) {
        case ShareResultStatus.success:
          showSnackBar('日志已分享');
        case ShareResultStatus.dismissed:
          showSnackBar('已取消分享日志');
        case ShareResultStatus.unavailable:
          showSnackBar('已打开系统分享');
      }
    } catch (error, stackTrace) {
      AppLogger.instance.error(
        'Share logs failed',
        tag: 'Settings',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        showSnackBar('分享日志失败：$error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isSharingLogs = false);
      }
    }
  }

  Future<void> _showUpdateDialog(String title, String key) async {
    HapticFeedback.selectionClick();
    final result = await showAppInputDialog(context, title: title);
    if (result?.isConfirmed == true &&
        result!.value != null &&
        result.value!.isNotEmpty) {
      await _updateUser(key, result.value!);
    }
  }

  Future<void> _updateUser(String key, String value) async {
    final data = Map<String, dynamic>.from(_userInfo!);
    data['pwd'] = '';
    data[key] = value;
    try {
      final res = jsonDecode((await register(data)).data);
      showSnackBar(res['msg']);
      if (res['code'] == 200) {
        _userInfo![key] = value;
        Instances.sp.setString('userinfo', jsonEncode(_userInfo));
        setState(() {});
        _appState.triggerLoginRefresh();
        HapticFeedback.mediumImpact();
      }
    } catch (e) {
      showSnackBar('更新失败: $e');
      HapticFeedback.heavyImpact();
    }
  }

  Future<void> _logout() async {
    HapticFeedback.mediumImpact();
    final action = await showAppConfirmDialog(
      context,
      title: '确认退出',
      content: '退出登录后，您将无法同步观看历史和收藏内容。',
      confirmText: '退出',
      isDestructive: true,
    );
    if (action != DialogAction.confirm || !mounted) return;
    _appState.performLogout();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLoggedIn = _userInfo != null;

    return Scaffold(
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          const SettingsSliverAppBar(title: '设置'),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 20),
                if (isLoggedIn) ...[
                  const SettingsSectionHeader('个人信息'),
                  SettingsGroup(
                    children: [
                      SettingsTile(
                        title: '昵称',
                        value: _userInfo?['name'] ?? '未设置',
                        icon: Icons.person_outline_rounded,
                        onTap: () => _showUpdateDialog('修改昵称', 'name'),
                      ),
                      SettingsTile(
                        title: 'QQ',
                        value: _userInfo?['qq'] ?? '未设置',
                        icon: Icons.chat_bubble_outline_rounded,
                        onTap: () => _showUpdateDialog('修改QQ', 'qq'),
                      ),
                      SettingsTile(
                        title: '个性签名',
                        value: _userInfo?['sign'] ?? '未设置',
                        icon: Icons.edit_note_rounded,
                        onTap: () => _showUpdateDialog('修改签名', 'sign'),
                        showDivider: false,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (_userInfo?['pwd'] != null) ...[
                    const SettingsSectionHeader('安全'),
                    SettingsGroup(
                      children: [
                        SettingsTile(
                          title: '修改密码',
                          value: '******',
                          icon: Icons.lock_outline_rounded,
                          onTap: () => _showUpdateDialog('修改密码', 'pwd'),
                          showDivider: false,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                ],
                const SettingsSectionHeader('播放'),
                SettingsGroup(
                  children: [
                    SettingsTile(
                      title: '播放设置',
                      value: '倍速 / 弹幕 / 字幕 / BT下载等',
                      icon: Icons.play_circle_outline_rounded,
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const PlaybackSettingsPage(),
                          ),
                        );
                      },
                      showDivider: false,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('源管理'),
                SettingsGroup(
                  children: [
                    SettingsTile(
                      title: '搜索源管理',
                      value: '开关 / 排序',
                      icon: Icons.extension_rounded,
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SourceManagementPage(),
                          ),
                        );
                      },
                      showDivider: false,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('外观'),
                SettingsGroup(
                  children: [
                    Obx(
                      () => SettingsSwitchTile(
                        title: '滑动时隐藏底栏',
                        value: _appState.isHideBottomNavOnScroll.value,
                        icon: Icons.swipe_down_rounded,
                        onChanged: _appState.toggleHideBottomNavOnScroll,
                      ),
                    ),
                    Obx(
                      () => SettingsTile(
                        title: '字体',
                        value: AppFonts.getLabelForFont(
                          _appState.fontFamily,
                        ),
                        icon: Icons.font_download_rounded,
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const FontSettingsPage(),
                            ),
                          );
                        },
                        showDivider: false,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('关于'),
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
                      value: _isExportingLogs ? '导出中...' : 'ZIP',
                      icon: Icons.file_download_outlined,
                      onTap: _isExportingLogs ? null : _exportLogs,
                    ),
                    SettingsTile(
                      title: '分享日志',
                      value: _isSharingLogs ? '准备中...' : '系统分享',
                      icon: Icons.ios_share_rounded,
                      onTap: _isSharingLogs ? null : _shareLogs,
                    ),
                    SettingsTile(
                      title: '版本更新',
                      value: 'v${Instances.appVersion}',
                      icon: Icons.system_update_alt_rounded,
                      onTap: () => launchUrlString(
                        'https://app.anibaka.com/',
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                    SettingsTile(
                      title: 'Github地址',
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
                if (isLoggedIn) ...[
                  const SizedBox(height: 40),
                  FilledButton.tonalIcon(
                    onPressed: _logout,
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('退出登录'),
                    style: FilledButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ],
                const SizedBox(height: 60),
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
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
