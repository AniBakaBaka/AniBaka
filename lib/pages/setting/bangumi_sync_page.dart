import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/login/login_page.dart';
import 'package:baka/services/bangumi_sync_service.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher_string.dart';

const _bangumiIconAsset = 'assets/bangumi.svg';
const _bangumiPink = Color(0xFFF09199);

class BangumiSyncPage extends StatefulWidget {
  const BangumiSyncPage({super.key});

  @override
  State<BangumiSyncPage> createState() => _BangumiSyncPageState();
}

class _BangumiSyncPageState extends State<BangumiSyncPage> {
  static const _apiDocsUrl = 'https://bangumi.github.io/api/';

  final _service = BangumiSyncService.instance;
  BangumiAccount? _account;
  bool _busy = false;
  String? _progress;
  BangumiSyncReport? _report;
  late bool _autoMarkEpisode;
  late bool _quickMarkGrid;

  bool get _connected => _service.isConnected;
  bool get _aniBakaLoggedIn => Instances.userToken.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _account = _service.account;
    _autoMarkEpisode = _service.autoMarkEpisode;
    _quickMarkGrid = _service.quickMarkGrid;
  }

  Future<void> _openUrl(String url) async {
    if (!await launchUrlString(url, mode: LaunchMode.externalApplication) &&
        mounted) {
      showSnackBar('无法打开浏览器', isError: true);
    }
  }

  Future<void> _connectWithAccessToken() async {
    if (_busy) return;
    final result = await showAppInputDialog(
      context,
      title: '使用 Access Token',
      hintText: '粘贴 Bangumi Access Token',
      confirmText: '验证并连接',
      obscureText: true,
    );
    if (result?.isConfirmed != true) return;

    setState(() {
      _busy = true;
      _progress = '正在验证 Access Token…';
      _report = null;
    });
    try {
      final account = await _service.connect(result!.value ?? '');
      if (!mounted) return;
      setState(() {
        _account = account;
        _progress = null;
      });
      if (Get.isRegistered<AppState>()) {
        Get.find<AppState>().triggerLoginRefresh();
      }
      HapticFeedback.mediumImpact();
      showSnackBar('已连接 Bangumi：${account.nickname}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _progress = null);
      showSnackBar(error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _navigateToLogin() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const Login()),
    );
    if (!mounted) return;
    setState(() {
      _account = _service.account;
    });
    if (Get.isRegistered<AppState>()) {
      Get.find<AppState>().triggerLoginRefresh();
    }
  }

  Future<void> _disconnect() async {
    if (_busy) return;
    final action = await showAppConfirmDialog(
      context,
      title: '断开 Bangumi 关联',
      content: '将从本机移除 Access Token 和同步快照，不会影响 Bangumi 上的追番记录。',
      confirmText: '断开连接',
      isDestructive: true,
    );
    if (action != DialogAction.confirm) return;
    await _service.disconnect();
    if (!mounted) return;
    setState(() {
      _account = null;
      _progress = null;
      _report = null;
    });
    if (Get.isRegistered<AppState>()) {
      Get.find<AppState>().triggerLoginRefresh();
    }
    showSnackBar('已断开 Bangumi 关联');
  }

  Future<void> _sync() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = '正在准备同步…';
      _report = null;
    });
    try {
      final report = await _service.sync(
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        _progress = null;
        _account = _service.account;
      });
      HapticFeedback.mediumImpact();
      showSnackBar(report.summary, isError: report.failed > 0);
    } catch (error) {
      if (!mounted) return;
      setState(() => _progress = null);
      showSnackBar(error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lastSyncAt = _service.lastSyncAt?.toLocal();
    final theme = Theme.of(context);

    return Scaffold(
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          const SettingsSliverAppBar(title: 'Bangumi 同步'),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 40),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const _NoticeCard(
                  icon: Icons.wifi_protected_setup_rounded,
                  title: '网络连接提示',
                  content:
                      'Bangumi API 在部分网络环境下可能无法直连。如遇到连接失败或超时，请开启网络代理后重试。',
                ),
                const SizedBox(height: 20),
                const SettingsSectionHeader('Bangumi 账号'),
                if (_connected)
                  _AccountCard(
                    account: _account,
                    onReplace: _connectWithAccessToken,
                    onDisconnect: _disconnect,
                  )
                else
                  _UnconnectedCard(
                    onGoToLogin: _navigateToLogin,
                    onConnectToken: _connectWithAccessToken,
                  ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('快捷偏好'),
                SettingsGroup(
                  children: [
                    SettingsSwitchTile(
                      icon: Icons.auto_awesome_rounded,
                      title: '播放完成自动点格子',
                      subtitle: '播放进度达到 95% 时自动标记为已看',
                      value: _autoMarkEpisode,
                      onChanged: (val) async {
                        await _service.setAutoMarkEpisode(val);
                        if (mounted) setState(() => _autoMarkEpisode = val);
                      },
                    ),
                    SettingsSwitchTile(
                      icon: Icons.grid_view_rounded,
                      title: '剧集快捷点格子',
                      subtitle: '在剧集列表中点击集数可快速标记',
                      value: _quickMarkGrid,
                      showDivider: false,
                      onChanged: (val) async {
                        await _service.setQuickMarkGrid(val);
                        if (mounted) setState(() => _quickMarkGrid = val);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('数据同步'),
                _SyncCard(
                  enabled: _connected && !_busy,
                  connected: _connected,
                  localMode: !_aniBakaLoggedIn,
                  progress: _progress,
                  report: _report,
                  lastSyncText: lastSyncAt == null
                      ? '尚未同步'
                      : DateFormat('yyyy-MM-dd HH:mm').format(lastSyncAt),
                  onSync: _sync,
                ),
                const SizedBox(height: 28),
                Center(
                  child: TextButton.icon(
                    onPressed: () => _openUrl(_apiDocsUrl),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.7),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                    icon: const Icon(Icons.code_rounded, size: 16),
                    label: const Text('Bangumi API 文档'),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.title,
    required this.content,
  });

  final IconData icon;
  final String title;
  final String content;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: isDark
            ? colors.surfaceContainerHigh.withValues(alpha: 0.5)
            : colors.primaryContainer.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.primary.withValues(alpha: 0.12),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  content,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UnconnectedCard extends StatelessWidget {
  const _UnconnectedCard({
    required this.onGoToLogin,
    required this.onConnectToken,
  });

  final VoidCallback onGoToLogin;
  final VoidCallback onConnectToken;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _bangumiPink.withValues(alpha: 0.2),
          width: 1,
        ),
        boxShadow: context.reduceMotion
            ? null
            : [
                BoxShadow(
                  color: _bangumiPink.withValues(alpha: 0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _bangumiPink.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const _BangumiIcon(size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '关联 Bangumi 账号',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '自动同步追番进度、观影状态与个人评分',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    onGoToLogin();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: _bangumiPink,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: const Text(
                    '前往 Bangumi 登录',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  onConnectToken();
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  side: BorderSide(
                    color: colors.outline.withValues(alpha: 0.3),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.key_rounded, size: 18),
                label: const Text('粘贴 Token'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.onReplace,
    required this.onDisconnect,
  });

  final BangumiAccount? account;
  final VoidCallback onReplace;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final name = account?.nickname.isNotEmpty == true
        ? account!.nickname
        : 'Bangumi 用户';
    final username = account?.username;
    final avatarUrl = account?.avatarUrl;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: context.reduceMotion
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Stack(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _bangumiPink.withValues(alpha: 0.15),
                    ),
                    child: ClipOval(
                      child: avatarUrl != null && avatarUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: avatarUrl,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) =>
                                  const _BangumiIcon(size: 32, circular: true),
                            )
                          : const _BangumiIcon(size: 32, circular: true),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: theme.scaffoldBackgroundColor,
                        shape: BoxShape.circle,
                      ),
                      child: const _BangumiIcon(size: 14, circular: true),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            '已关联',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.green,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (username != null && username.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        '@$username',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(
            height: 1,
            thickness: 0.5,
            color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  onReplace();
                },
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: colors.primary,
                ),
                icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                label: const Text('更换 Token', style: TextStyle(fontSize: 13)),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  onDisconnect();
                },
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: colors.error,
                ),
                icon: const Icon(Icons.link_off_rounded, size: 16),
                label: const Text('断开关联', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BangumiIcon extends StatelessWidget {
  const _BangumiIcon({required this.size, this.circular = false});

  final double size;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    final image = SvgPicture.asset(
      _bangumiIconAsset,
      width: size,
      height: size,
      fit: BoxFit.cover,
      semanticsLabel: 'Bangumi',
    );
    if (circular) return ClipOval(child: image);
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: image,
    );
  }
}

class _SyncCard extends StatelessWidget {
  const _SyncCard({
    required this.enabled,
    required this.connected,
    required this.localMode,
    required this.progress,
    required this.report,
    required this.lastSyncText,
    required this.onSync,
  });

  final bool enabled;
  final bool connected;
  final bool localMode;
  final String? progress;
  final BangumiSyncReport? report;
  final String lastSyncText;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.sync_rounded,
                      size: 20,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '双向同步',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: localMode
                          ? colors.surfaceContainerHighest
                          : colors.primaryContainer.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      localMode ? '本地同步模式' : '云端同步模式',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: localMode
                            ? colors.onSurfaceVariant
                            : colors.primary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(
                    Icons.history_rounded,
                    size: 14,
                    color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '上次同步：$lastSyncText',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                !connected
                    ? '请先关联 Bangumi 账号以使用同步功能'
                    : (report?.summary ??
                        '支持同步想看、在看、看过的进度与评分。首次同步冲突以 Bangumi 为准。'),
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: (report?.failed ?? 0) > 0
                      ? colors.error
                      : colors.onSurfaceVariant,
                ),
              ),
              if (progress != null) ...[
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    minHeight: 4,
                    backgroundColor: colors.primary.withValues(alpha: 0.12),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  progress!,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: enabled
                      ? () {
                          HapticFeedback.mediumImpact();
                          onSync();
                        }
                      : null,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: progress != null
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.onPrimary,
                          ),
                        )
                      : const Icon(Icons.cloud_sync_rounded, size: 18),
                  label: Text(progress == null ? '开始同步' : '正在同步…'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

