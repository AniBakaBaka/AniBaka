import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/bangumi_sync_service.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher_string.dart';

const _bangumiIconAsset = 'assets/bangumi.svg';
const _bangumiPink = Color(0xFFF09199);
const _tokenHelperUrl = 'https://next.bgm.tv/demo/access-token';

class BangumiSyncPage extends StatefulWidget {
  const BangumiSyncPage({super.key});

  @override
  State<BangumiSyncPage> createState() => _BangumiSyncPageState();
}

class _BangumiSyncPageState extends State<BangumiSyncPage> {
  static const _apiDocsUrl = 'https://bangumi.github.io/api/';

  final _service = BangumiSyncService.instance;
  bool _busy = false;
  String? _progress;
  BangumiSyncReport? _report;

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
    if (result == null) return;

    setState(() {
      _busy = true;
      _progress = '正在验证 Access Token…';
      _report = null;
    });
    try {
      final account = await _service.connect(result);
      if (!mounted) return;
      setState(() => _progress = null);
      if (Get.isRegistered<AppState>()) {
        Get.find<AppState>().triggerLoginRefresh();
      }
      showSnackBar('已连接 Bangumi：${account.nickname}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _progress = null);
      showSnackBar(error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
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
    if (!action) return;
    await _service.disconnect();
    if (!mounted) return;
    setState(() {
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
      });
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
    final connected = _service.isConnected;
    final account = _service.account;
    final lastSyncAt = _service.lastSyncAt?.toLocal();
    final aniBakaLoggedIn = Instances.userToken.isNotEmpty;
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
                const _NoticeCard(),
                const SizedBox(height: 20),
                const SettingsSectionHeader('Bangumi 账号'),
                SettingsGroup(
                  children: [
                    if (connected)
                      _AccountView(
                        account: account,
                        onReplace: _connectWithAccessToken,
                        onDisconnect: _disconnect,
                      )
                    else
                      _UnconnectedView(
                        onConnectToken: _connectWithAccessToken,
                        onGetToken: () => _openUrl(_tokenHelperUrl),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('快捷偏好'),
                SettingsGroup(
                  children: [
                    SettingsSwitchTile(
                      icon: Icons.auto_awesome_rounded,
                      title: '播放完成自动点格子',
                      subtitle: '播放进度达到 95% 时自动标记为已看',
                      value: _service.autoMarkEpisode,
                      onChanged: (val) async {
                        await _service.setAutoMarkEpisode(val);
                        if (mounted) setState(() {});
                      },
                    ),
                    SettingsSwitchTile(
                      icon: Icons.grid_view_rounded,
                      title: '剧集快捷点格子',
                      subtitle: '在剧集列表中点击集数可快速标记',
                      value: _service.quickMarkGrid,
                      showDivider: false,
                      onChanged: (val) async {
                        await _service.setQuickMarkGrid(val);
                        if (mounted) setState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const SettingsSectionHeader('数据同步'),
                _SyncCard(
                  enabled: connected && !_busy,
                  connected: connected,
                  localMode: !aniBakaLoggedIn,
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
  const _NoticeCard();

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
          Icon(
            Icons.wifi_protected_setup_rounded,
            size: 20,
            color: colors.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '网络连接提示',
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Bangumi API 在部分网络环境下可能无法直连。如遇到连接失败或超时，请开启网络代理后重试。',
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

class _UnconnectedView extends StatelessWidget {
  const _UnconnectedView({
    required this.onConnectToken,
    required this.onGetToken,
  });

  final VoidCallback onConnectToken;
  final VoidCallback onGetToken;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SvgPicture.asset(
                  _bangumiIconAsset,
                  width: 36,
                  height: 36,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '关联 Bangumi 账号',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
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
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onConnectToken,
                  style: FilledButton.styleFrom(
                    backgroundColor: _bangumiPink,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.key_rounded, size: 16),
                  label: const Text(
                    '粘贴 Token 连接',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onGetToken,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  side: BorderSide(
                    color: colors.outline.withValues(alpha: 0.3),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('获取 Token', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AccountView extends StatelessWidget {
  const _AccountView({
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

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: avatarUrl != null && avatarUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: avatarUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => SvgPicture.asset(
                            _bangumiIconAsset,
                            fit: BoxFit.cover,
                          ),
                        )
                      : SvgPicture.asset(
                          _bangumiIconAsset,
                          fit: BoxFit.cover,
                        ),
                ),
              ),
              const SizedBox(width: 12),
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
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
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
          const SizedBox(height: 12),
          Divider(
            height: 1,
            thickness: 0.5,
            color: isDark ? Colors.white10 : Colors.black12,
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: onReplace,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: colors.primary,
                ),
                icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                label: const Text('更换 Token', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: onDisconnect,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: colors.error,
                ),
                icon: const Icon(Icons.link_off_rounded, size: 16),
                label: const Text('断开关联', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
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
    final colors = Theme.of(context).colorScheme;

    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.sync_rounded,
                    size: 20,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '双向同步',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: localMode
                          ? colors.surfaceContainerHighest
                          : colors.primaryContainer.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      localMode ? '本地模式' : '云端模式',
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
              const SizedBox(height: 10),
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
              const SizedBox(height: 6),
              Text(
                !connected
                    ? '请先关联 Bangumi 账号以使用同步功能'
                    : (report?.summary ??
                        '支持同步想看、在看、看过的进度与评分。首次同步冲突以 Bangumi 为准。'),
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: (report?.failed ?? 0) > 0
                      ? colors.error
                      : colors.onSurfaceVariant,
                ),
              ),
              if (progress != null) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  minHeight: 3,
                  backgroundColor: colors.primary.withValues(alpha: 0.12),
                ),
                const SizedBox(height: 6),
                Text(
                  progress!,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: enabled ? onSync : null,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: progress != null
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.onPrimary,
                          ),
                        )
                      : const Icon(Icons.cloud_sync_rounded, size: 16),
                  label: Text(
                    progress == null ? '开始同步' : '正在同步…',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
