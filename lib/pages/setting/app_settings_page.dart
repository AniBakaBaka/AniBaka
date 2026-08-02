import 'dart:convert';
import 'package:baka/api/post.dart';
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:get/get.dart';
import 'package:baka/services/cache_manager.dart';
import 'package:baka/services/theme_service.dart';
import 'package:baka/utils/app_logger.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:baka/pages/setting/font_settings_page.dart';
import 'package:baka/pages/setting/playback_settings_page.dart';
import 'package:baka/pages/source/source_management_page.dart';
import 'package:baka/theme.dart';
import 'package:flutter/material.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';
import 'package:baka/widgets/platform/tv/tv_log_export_dialog.dart';
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

  String _cacheSize = '计算中...';
  bool _isClearing = false;
  bool _isExportingLogs = false;
  bool _isSharingLogs = false;

  /// 会话数据只有 [AppState] 一份，页面不再自己 jsonDecode 一遍 `userinfo`。
  Map<String, dynamic>? get _userInfo =>
      _appState.isLoggedIn ? _appState.userInfo.value : null;

  @override
  void initState() {
    super.initState();
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

  /// 导出/分享日志共用的外壳：忙碌位守卫 → 震动 → 记日志 → 执行 → 失败上报。
  /// 两个入口原先各抄了一份完全相同的 30 行样板。
  Future<void> _runLogAction({
    required String name,
    required bool busy,
    required ValueChanged<bool> setBusy,
    required Future<void> Function() action,
  }) async {
    if (busy) return;

    HapticFeedback.mediumImpact();
    setState(() => setBusy(true));
    try {
      AppLogger.instance.info('$name logs requested', tag: 'Settings');
      await action();
    } catch (error, stackTrace) {
      AppLogger.instance.error(
        '$name logs failed',
        tag: 'Settings',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        showSnackBar(
          '${name == 'Export' ? '导出' : '分享'}日志失败：$error',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => setBusy(false));
    }
  }

  Future<void> _exportLogs() => _runLogAction(
    name: 'Export',
    busy: _isExportingLogs,
    setBusy: (value) => _isExportingLogs = value,
    action: () async {
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
    },
  );

  Future<void> _shareLogs() => _runLogAction(
    name: 'Share',
    busy: _isSharingLogs,
    setBusy: (value) => _isSharingLogs = value,
    action: () async {
      final result = await AppLogger.instance.shareLogs();
      if (!mounted) return;
      showSnackBar(switch (result.status) {
        ShareResultStatus.success => '日志已分享',
        ShareResultStatus.dismissed => '已取消分享日志',
        ShareResultStatus.unavailable => '已打开系统分享',
      });
    },
  );

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
        final updated = Map<String, dynamic>.from(_userInfo!)..[key] = value;
        await Instances.sp.setString('userinfo', jsonEncode(updated));
        // triggerLoginRefresh 会从 SP 重新加载并广播，页面随之重建。
        _appState.triggerLoginRefresh();
        if (mounted) setState(() {});
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
      title: '退出 AniBaka',
      content:
          '退出后，播放历史将不再保存到 AniBaka 云端，也不能回复 AniBaka 评论。已连接的 Bangumi 账号不会被退出，其收藏与集数同步仍可继续使用。',
      confirmText: '退出',
      isDestructive: true,
    );
    if (action != DialogAction.confirm || !mounted) return;
    _appState.performLogout();
    Navigator.pop(context);
  }

  Future<void> _showThemeModeDialog() async {
    HapticFeedback.selectionClick();
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择主题模式'),
        children: [
          for (var mode = 0; mode < ThemeService.themeModeLabels.length; mode++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, mode),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(ThemeService.themeModeLabels[mode]),
                  if (_appState.themeMode == mode)
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

  String get _themeModeLabel =>
      ThemeService.themeModeLabel(_appState.themeMode);

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
                  const SettingsSectionHeader('账户与安全'),
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
                        showDivider: _userInfo?['pwd'] != null,
                      ),
                      if (_userInfo?['pwd'] != null)
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
                const SettingsSectionHeader('内容来源'),
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
                const SettingsSectionHeader('外观与显示'),
                SettingsGroup(
                  children: [
                    Obx(
                      () => SettingsTile(
                        title: '主题模式',
                        value: _themeModeLabel,
                        icon: Icons.brightness_6_outlined,
                        onTap: _showThemeModeDialog,
                      ),
                    ),
                    Obx(
                      () => SettingsSwitchTile(
                        title: '动态取色',
                        subtitle: '使用系统壁纸或强调色生成 Material 3 配色',
                        value: _appState.dynamicColor,
                        icon: Icons.palette_outlined,
                        onChanged: _appState.setDynamicColor,
                      ),
                    ),
                    Obx(
                      () => SettingsTile(
                        title: '字体',
                        value: AppFonts.getLabelForFont(_appState.fontFamily),
                        icon: Icons.font_download_rounded,
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const FontSettingsPage(),
                            ),
                          );
                        },
                      ),
                    ),
                    Obx(
                      () => SettingsSwitchTile(
                        title: '减少视觉效果',
                        subtitle: '关闭动效、毛玻璃与自动轮播，并减少装饰阴影',
                        value: _appState.reduceVisualEffects,
                        icon: Icons.motion_photos_off_outlined,
                        onChanged: _appState.setReduceVisualEffects,
                        showDivider: false,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('交互'),
                SettingsGroup(
                  children: [
                    Obx(
                      () => SettingsSwitchTile(
                        title: '滑动时隐藏底栏',
                        subtitle: '向下浏览内容时收起底部导航',
                        value: _appState.isHideBottomNavOnScroll.value,
                        icon: Icons.swipe_down_rounded,
                        onChanged: _appState.toggleHideBottomNavOnScroll,
                        showDivider: false,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('存储'),
                SettingsGroup(
                  children: [
                    SettingsTile(
                      title: '清理缓存',
                      value: _isClearing ? '清理中...' : _cacheSize,
                      icon: Icons.cleaning_services_rounded,
                      onTap: _isClearing ? null : _clearCache,
                      showDivider: false,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('诊断'),
                SettingsGroup(
                  children: [
                    SettingsTile(
                      title: '导出日志',
                      value: Instances.isTV
                          ? '手机扫码下载'
                          : (_isExportingLogs ? '导出中...' : 'ZIP'),
                      icon: Instances.isTV
                          ? Icons.qr_code_2_rounded
                          : Icons.file_download_outlined,
                      onTap: Instances.isTV
                          ? () => showTvLogExportDialog(context)
                          : (_isExportingLogs ? null : _exportLogs),
                      showDivider: !Instances.isTV,
                    ),
                    if (!Instances.isTV)
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
                const SettingsSectionHeader('关于'),
                SettingsGroup(
                  children: [
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
                      title: 'GitHub 地址',
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
