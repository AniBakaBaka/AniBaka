import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/mine_service.dart';
import 'package:baka/services/qr_login_server.dart';
import 'package:baka/services/collection_service.dart';
import 'package:baka/services/play_history_sync_service.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'package:baka/widgets/platform/tv/tv_log_export_dialog.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/utils/toast_utils.dart';

class TvMyPage extends StatefulWidget {
  const TvMyPage({super.key});

  @override
  State<TvMyPage> createState() => _TvMyPageState();
}

class _TvMyPageState extends State<TvMyPage> {
  final MineService _mineService = MineService();
  final QrLoginServer _qrServer = QrLoginServer();
  late final Worker _loginWorker;

  bool _isQrLoading = true;
  String? _qrContent;
  String? _qrError;
  Timer? _qrTimeoutTimer;

  CollectionStats? _stats;
  int _historyCount = 0;

  @override
  void initState() {
    super.initState();
    _loginWorker = ever(Get.find<AppState>().loginTrigger, (_) {
      if (mounted) {
        setState(() {});
        _loadUserData();
      }
    });
    _loadUserData();
  }

  void _loadUserData() {
    if (!_mineService.isLogin) {
      _startQrServer();
    } else {
      _qrServer.stop();
      _qrTimeoutTimer?.cancel();
      _loadStats();
    }
  }

  Future<void> _loadStats() async {
    try {
      final stats = await CollectionService.getStats();
      final history = PlayHistorySyncService.getHistoryList();
      if (mounted) {
        setState(() {
          _stats = stats;
          _historyCount = history.length;
        });
      }
    } catch (e) {
      debugPrint('加载统计失败: $e');
    }
  }

  Future<void> _startQrServer() async {
    if (mounted) {
      setState(() {
        _isQrLoading = true;
        _qrError = null;
      });
    }
    try {
      await _qrServer.start();
      if (_qrServer.localIp == null) {
        if (mounted) {
          setState(() {
            _isQrLoading = false;
            _qrError = '无法获取本机 IP，请检查网络';
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _qrContent = _qrServer.qrContent;
          _isQrLoading = false;
        });
      }

      _qrTimeoutTimer = Timer(const Duration(minutes: 5), () {
        if (mounted && !_mineService.isLogin) {
          setState(() {
            _qrError = '二维码已过期，请点击刷新';
          });
        }
      });

      final result = await _qrServer.loginResult;
      _qrTimeoutTimer?.cancel();

      if (!mounted) return;

      await Get.find<AppState>().saveLoginInfo(
        result['token'] as String,
        Map<String, dynamic>.from(result['user'] as Map),
        refreshToken: result['refresh_token'] as String?,
        tokenExpiresAt: result['token_expires_at'] as String?,
      );

      showSnackBar('登录成功');
      Get.find<AppState>().triggerLoginRefresh();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isQrLoading = false;
          _qrError = '登录服务器启动失败';
        });
      }
    }
  }

  Future<void> _logout() async {
    HapticFeedback.mediumImpact();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.tvPanelBgColor,
        title: Text(
          '确认退出登录？',
          style: TextStyle(color: context.tvTextColor, fontWeight: FontWeight.bold),
        ),
        content: Text(
          '退出后，播放历史将不再保存至 AniBaka 云端。',
          style: TextStyle(color: context.tvTextSecondaryColor),
        ),
        actions: [
          TvFocusable(
            onPressed: () => Navigator.of(context).pop(false),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('取消', style: TextStyle(color: context.tvTextColor)),
            ),
          ),
          const SizedBox(width: 8),
          TvFocusable(
            onPressed: () => Navigator.of(context).pop(true),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text('退出', style: TextStyle(color: Colors.redAccent)),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      Get.find<AppState>().performLogout();
      showSnackBar('已退出登录');
    }
  }

  @override
  void dispose() {
    _loginWorker.dispose();
    _qrTimeoutTimer?.cancel();
    _qrServer.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLogin = _mineService.isLogin;

    return Focus(
      canRequestFocus: false,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 4,
              child: Container(
                decoration: BoxDecoration(
                  color: context.tvHighlightColor(0.04),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: context.tvHighlightColor(0.08),
                    width: 1,
                  ),
                ),
                padding: const EdgeInsets.all(28),
                child: isLogin ? _buildProfileArea() : _buildLoginQrArea(),
              ),
            ),

            const SizedBox(width: 24),

            Expanded(
              flex: 6,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '我的空间',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: context.tvTextColor,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: isLogin
                        ? _buildStatsGrid()
                        : _buildGuestInfoGrid(),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Baka v${Instances.appVersion} · 二次元大屏先行UI',
                    style: TextStyle(
                      color: context.tvTextHintColor,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileArea() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                blurRadius: 20,
                spreadRadius: 2,
              )
            ],
          ),
          child: ClipOval(
            child: _mineService.avatarUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: _mineService.avatarUrl,
                    fit: BoxFit.cover,
                  )
                : Container(
                    color: context.tvHighlightColor(0.1),
                    child: Icon(
                      Icons.person_rounded,
                      size: 60,
                      color: context.tvTextSecondaryColor,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          _mineService.displayName,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            color: context.tvTextColor,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        Text(
          _mineService.displaySubtitle,
          style: TextStyle(
            fontSize: 13,
            color: context.tvTextSecondaryColor,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const Spacer(),
        TvFocusable(
          onPressed: _logout,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.redAccent.withValues(alpha: 0.2),
              ),
            ),
            alignment: Alignment.center,
            child: const Text(
              '退出登录',
              style: TextStyle(
                color: Colors.redAccent,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoginQrArea() {
    if (_isQrLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_qrError != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: Colors.redAccent.withValues(alpha: 0.8),
            size: 48,
          ),
          const SizedBox(height: 16),
          Text(
            _qrError!,
            style: TextStyle(color: context.tvTextSecondaryColor, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          TvFocusable(
            onPressed: _startQrServer,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                '重试',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '手机扫码登录',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: context.tvTextColor,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '使用同一Wi-Fi下的手机扫码',
          style: TextStyle(
            fontSize: 12,
            color: context.tvTextSecondaryColor,
          ),
        ),
        const SizedBox(height: 20),
        if (_qrContent != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 10,
                  spreadRadius: 2,
                )
              ],
            ),
            child: QrImageView(
              data: _qrContent!,
              version: QrVersions.auto,
              size: 160,
              gapless: false,
            ),
          ),
        const SizedBox(height: 16),
        TvFocusable(
          onPressed: _startQrServer,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              '刷新二维码',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatsGrid() {
    return GridView(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 1.3,
      ),
      children: [
        _buildStatsCard(
          icon: Icons.play_circle_fill_rounded,
          title: '正在看',
          value: '${_stats?.doing ?? 0}',
          subtitle: '追番同步中',
          color: Colors.pinkAccent,
        ),
        _buildStatsCard(
          icon: Icons.star_rounded,
          title: '已收藏',
          value: '${_stats?.total ?? 0}',
          subtitle: '想看/看过/在看',
          color: Colors.amber,
        ),
        _buildStatsCard(
          icon: Icons.history_toggle_off_rounded,
          title: '播放历史',
          value: '$_historyCount',
          subtitle: '条观看记录',
          color: Colors.blueAccent,
        ),
        _buildStatsCard(
          icon: Icons.library_books_rounded,
          title: '日志管理',
          value: '导出',
          subtitle: '导出运行日志',
          color: Colors.indigoAccent,
          onPressed: () => showTvLogExportDialog(context),
        ),
      ],
    );
  }

  Widget _buildGuestInfoGrid() {
    return GridView(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 1.3,
      ),
      children: [
        _buildStatsCard(
          icon: Icons.cloud_off_rounded,
          title: '游客模式',
          value: '未登录',
          subtitle: '历史与追番仅存本地',
          color: Colors.grey,
        ),
        _buildStatsCard(
          icon: Icons.extension_rounded,
          title: '源管理',
          value: '管理',
          subtitle: '启用/添加番剧视频源',
          color: Colors.orangeAccent,
          onPressed: () => NavigationService.toSourceManagement(context),
        ),
        _buildStatsCard(
          icon: Icons.alt_route_rounded,
          title: '应用线路',
          value: '切换',
          subtitle: '当前: ${_mineService.currentHost}',
          color: Colors.tealAccent,
          onPressed: () {
            _mineService.switchHost();
            setState(() {});
            showSnackBar('线路已切换至 ${_mineService.currentHost}');
          },
        ),
        _buildStatsCard(
          icon: Icons.bug_report_rounded,
          title: '异常诊断',
          value: '日志',
          subtitle: '导出应用运行日志',
          color: Colors.indigoAccent,
          onPressed: () => showTvLogExportDialog(context),
        ),
      ],
    );
  }

  Widget _buildStatsCard({
    required IconData icon,
    required String title,
    required String value,
    required String subtitle,
    required Color color,
    VoidCallback? onPressed,
  }) {
    final cardContent = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.tvHighlightColor(0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: context.tvHighlightColor(0.08),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: context.tvTextSecondaryColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: context.tvTextColor,
              fontSize: 28,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(
              color: context.tvTextHintColor,
              fontSize: 11,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

    if (onPressed != null) {
      return TvFocusable(
        onPressed: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: cardContent,
      );
    }

    return cardContent;
  }
}
