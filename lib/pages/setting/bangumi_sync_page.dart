import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/services/collection/bangumi_sync.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';

class BangumiSyncPage extends StatefulWidget {
  const BangumiSyncPage({super.key});

  @override
  State<BangumiSyncPage> createState() => _BangumiSyncPageState();
}

class _BangumiSyncPageState extends State<BangumiSyncPage> {
  String? _progress;

  Future<void> _run(String progress, Future<void> Function() task) async {
    setState(() => _progress = progress);
    try {
      await task();
    } catch (e) {
      showSnackBar('$e', isError: true);
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  Future<void> _connect() async {
    final token = await showAppInputDialog(
      context,
      title: 'Bangumi Access Token',
      hintText: '粘贴 Access Token',
      confirmText: '连接',
      obscureText: true,
    );
    if (token == null) return;
    await _run('正在验证…', () async {
      final account = await bangumiSession.connect(token);
      showSnackBar('已连接 Bangumi：${account.nickname}');
    });
  }

  Future<void> _disconnect() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: '断开 Bangumi',
      content: '移除本机保存的 Token 与同步记录',
      confirmText: '断开',
      isDestructive: true,
    );
    if (!confirmed) return;
    await bangumiSession.disconnect();
    if (mounted) setState(() {});
  }

  Future<void> _sync() => _run('正在同步…', () async {
    final report = await bangumiSync.sync(
      onProgress: (progress) {
        if (mounted) setState(() => _progress = progress);
      },
    );
    showSnackBar(report.summary, isError: report.failed > 0);
  });

  @override
  Widget build(BuildContext context) {
    final account = bangumiSession.account;
    final busy = _progress != null;
    final lastSync = bangumiSession.lastSyncAt?.toLocal().toRelativeTime();
    return SettingsPage(
      title: 'Bangumi 同步',
      children: [
        SettingsSection(
          title: '账号',
          children: [
            if (account == null) ...[
              SettingsTile(
                icon: Icons.key_rounded,
                title: '使用 Access Token 连接',
                busy: busy,
                onTap: _connect,
              ),
              SettingsTile(
                icon: Icons.vpn_key_outlined,
                title: '获取 Access Token',
                trailingIcon: Icons.open_in_new_rounded,
                onTap: () => launchUrlString(
                  'https://next.bgm.tv/demo/access-token',
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ] else ...[
              ListTile(
                leading: CircleAvatar(
                  foregroundImage: account.avatarUrl == null
                      ? null
                      : ResizeImage(
                          CachedNetworkImageProvider(account.avatarUrl!),
                          width: 120,
                        ),
                ),
                title: Text(account.nickname),
                subtitle: Text('@${account.username}'),
              ),
              SettingsTile(
                icon: Icons.swap_horiz_rounded,
                title: '更换 Token',
                busy: busy,
                onTap: _connect,
              ),
              SettingsTile(
                icon: Icons.link_off_rounded,
                title: '断开关联',
                color: Theme.of(context).colorScheme.error,
                onTap: busy ? null : _disconnect,
              ),
            ],
          ],
        ),
        SettingsSection(
          title: '偏好',
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.done_all_rounded),
              title: const Text('播放完成自动点格子'),
              value: bangumiSession.autoMarkEpisode,
              onChanged: (v) {
                bangumiSession.setAutoMarkEpisode(v);
                setState(() {});
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.grid_view_rounded),
              title: const Text('剧集列表快捷点格子'),
              value: bangumiSession.quickMarkGrid,
              onChanged: (v) {
                bangumiSession.setQuickMarkGrid(v);
                setState(() {});
              },
            ),
          ],
        ),
        if (account != null)
          SettingsSection(
            children: [
              SettingsTile(
                icon: Icons.cloud_sync_outlined,
                title: '立即同步',
                subtitle: _progress ?? (lastSync == null ? '尚未同步' : '上次同步 $lastSync'),
                busy: busy,
                onTap: _sync,
              ),
            ],
          ),
      ],
    );
  }
}
