import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/instance.dart';
import 'package:baka/services/cache_manager.dart';
import 'package:baka/services/mine_service.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:baka/services/version_service.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'package:baka/widgets/platform/tv/tv_log_export_dialog.dart';
import 'package:baka/widgets/dialog/update_dialog.dart';
import 'package:baka/utils/toast_utils.dart';

class TvSettingsPage extends StatefulWidget {
  const TvSettingsPage({super.key});

  @override
  State<TvSettingsPage> createState() => _TvSettingsPageState();
}

class _TvSettingsPageState extends State<TvSettingsPage> {
  int _selectedCategoryIndex = 0; // 0: 常规偏好, 1: 缓存与数据, 2: 关于系统
  String _cacheSize = '计算中...';
  bool _isCheckingUpdate = false;
  bool _isClearingCache = false;
  final MineService _mineService = MineService();

  final List<String> _categories = ['常规偏好', '缓存与数据', '关于与更新'];

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
    if (_isClearingCache) return;
    HapticFeedback.mediumImpact();
    setState(() => _isClearingCache = true);
    final success = await CacheManagerService.instance.clearAllCache();
    if (mounted) {
      setState(() => _isClearingCache = false);
      if (success) {
        showSnackBar('缓存清理成功');
        _loadCacheSize();
      } else {
        showSnackBar('清理失败，请重试', isError: true);
      }
    }
  }

  Future<void> _checkUpdate() async {
    if (_isCheckingUpdate) return;
    setState(() => _isCheckingUpdate = true);
    try {
      final info = await VersionService.checkUpdateInfo();
      if (!mounted) return;
      setState(() => _isCheckingUpdate = false);
      if (info.hasUpdate) {
        showAnnouncementDialog(
          content: '发现新版本 ${info.latestVersion}\n\n更新日志:\n${info.changelog}',
          updateInfo: info,
        );
      } else {
        showSnackBar('当前已是最新版本 v${Instances.appVersion}');
      }
    } catch (e) {
      if (mounted) setState(() => _isCheckingUpdate = false);
      showSnackBar('检查更新失败: $e', isError: true);
    }
  }

  void _switchHost() {
    _mineService.switchHost();
    setState(() {});
    showSnackBar('线路已切换至 ${_mineService.currentHost}，重启APP后生效');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.settings_outlined,
                color: Theme.of(context).colorScheme.primary,
                size: 28,
              ),
              const SizedBox(width: 12),
              Text(
                '设置中心',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: context.tvTextColor,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 200,
                  padding: const EdgeInsets.only(right: 16),
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(
                        color: context.tvHighlightColor(0.08),
                        width: 1,
                      ),
                    ),
                  ),
                  child: FocusTraversalGroup(
                    policy: ReadingOrderTraversalPolicy(),
                    child: ListView.builder(
                      itemCount: _categories.length,
                      itemBuilder: (context, index) {
                        final isSelected = _selectedCategoryIndex == index;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: TvFocusable(
                            onPressed: () {
                              setState(() {
                                _selectedCategoryIndex = index;
                              });
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                _categories[index],
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  color: isSelected
                                      ? Colors.white
                                      : context.tvTextSecondaryColor,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),

                const SizedBox(width: 32),

                Expanded(
                  child: FocusTraversalGroup(
                    policy: ReadingOrderTraversalPolicy(),
                    child: _buildCategorySettings(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategorySettings() {
    switch (_selectedCategoryIndex) {
      case 0:
        return _buildGeneralSettings();
      case 1:
        return _buildDataSettings();
      case 2:
        return _buildAboutSettings();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildGeneralSettings() {
    return ListView(
      physics: const BouncingScrollPhysics(),
      children: [
        _buildSettingCard(
          icon: Icons.extension_outlined,
          title: '源管理',
          subtitle: '管理并启用或禁用您的视频爬虫源',
          onPressed: () => NavigationService.toSourceManagement(context),
        ),
        const SizedBox(height: 16),
        _buildSettingCard(
          icon: Icons.alt_route_rounded,
          title: 'APP线路切换',
          subtitle: '当前线路: ${_mineService.currentHost}',
          onPressed: _switchHost,
        ),
      ],
    );
  }

  Widget _buildDataSettings() {
    return ListView(
      physics: const BouncingScrollPhysics(),
      children: [
        _buildSettingCard(
          icon: Icons.cleaning_services_rounded,
          title: '清理缓存',
          subtitle: '已占用: $_cacheSize (清理图片及播放器缓冲，不影响数据)',
          isLoading: _isClearingCache,
          onPressed: _clearCache,
        ),
        const SizedBox(height: 16),
        _buildSettingCard(
          icon: Icons.qr_code_2_rounded,
          title: '导出调试日志',
          subtitle: '在大屏显示二维码，方便用手机扫码保存应用运行日志',
          onPressed: () => showTvLogExportDialog(context),
        ),
      ],
    );
  }

  Widget _buildAboutSettings() {
    return ListView(
      physics: const BouncingScrollPhysics(),
      children: [
        _buildSettingCard(
          icon: Icons.system_update_rounded,
          title: '检查更新',
          subtitle: '当前版本: v${Instances.appVersion}。点击在线检查新版本。',
          isLoading: _isCheckingUpdate,
          onPressed: _checkUpdate,
        ),
        const SizedBox(height: 16),
        _buildSettingCard(
          icon: Icons.info_outline_rounded,
          title: '关于 AniBaka TV',
          subtitle: '基于 Flutter 开发的高颜自动漫番剧播放器客户端',
          onPressed: () {
            showSnackBar('Baka v${Instances.appVersion} 是一款专为影院大屏体验设计的动漫播放器');
          },
        ),
      ],
    );
  }

  Widget _buildSettingCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onPressed,
    bool isLoading = false,
  }) {
    return TvFocusable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: context.tvHighlightColor(0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: context.tvHighlightColor(0.08),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: Theme.of(context).colorScheme.primary,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: context.tvTextColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 14,
                      color: context.tvTextSecondaryColor,
                    ),
                  ),
                ],
              ),
            ),
            if (isLoading)
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).colorScheme.primary,
                  ),
                ),
              )
            else
              Icon(
                Icons.arrow_forward_ios_rounded,
                color: context.tvTextHintColor,
                size: 16,
              ),
          ],
        ),
      ),
    );
  }
}
