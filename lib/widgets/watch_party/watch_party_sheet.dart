import 'dart:async';

import 'package:baka/models/watch_party.dart';
import 'package:baka/services/watch_party_link_service.dart';
import 'package:baka/services/watch_party_service.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class WatchPartySheet extends StatefulWidget {
  const WatchPartySheet({required this.service, super.key});

  final WatchPartyService service;

  static Future<void> show(BuildContext context, WatchPartyService service) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black54,
        constraints: const BoxConstraints(maxWidth: 560),
        builder: (_) => WatchPartySheet(service: service),
      );

  @override
  State<WatchPartySheet> createState() => _WatchPartySheetState();
}

class _WatchPartySheetState extends State<WatchPartySheet> {
  late final TextEditingController _inviteController;
  late final TextEditingController _nicknameController;
  late final TextEditingController _chatController;

  @override
  void initState() {
    super.initState();
    _inviteController = TextEditingController();
    _nicknameController = TextEditingController(
      text: WatchPartyService.currentNickname(),
    );
    _chatController = TextEditingController();
  }

  @override
  void dispose() {
    _inviteController.dispose();
    _nicknameController.dispose();
    _chatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      height: MediaQuery.sizeOf(context).height * 0.8,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: colorScheme.outlineVariant,
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: ValueListenableBuilder<WatchPartyViewState>(
                valueListenable: widget.service.state,
                builder: (context, state, _) {
                  final snapshot = state.snapshot;
                  if (snapshot != null) {
                    return _RoomView(
                      service: widget.service,
                      state: state,
                      snapshot: snapshot,
                      chatController: _chatController,
                      onSendChat: _sendChat,
                    );
                  }
                  return _JoinView(
                    service: widget.service,
                    state: state,
                    inviteController: _inviteController,
                    nicknameController: _nicknameController,
                    onCreateRoom: _handleCreateRoom,
                    onJoinRoom: _handleJoinRoom,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleCreateRoom() async {
    try {
      await widget.service.createRoom();
    } catch (error) {
      if (mounted) {
        showSnackBar(
          error.toString().replaceFirst('Bad state: ', ''),
          isError: true,
        );
      }
    }
  }

  Future<void> _handleJoinRoom() async {
    final rawCode = _inviteController.text;
    final code = WatchPartyLinkService.inviteCodeFromValue(rawCode) ?? rawCode.trim();
    try {
      await widget.service.joinInvite(
        code,
        nickname: _nicknameController.text,
      );
    } catch (error) {
      if (mounted) {
        showSnackBar(
          error.toString().replaceFirst('Bad state: ', ''),
          isError: true,
        );
      }
    }
  }

  void _sendChat() {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    widget.service.sendChat(text);
    _chatController.clear();
  }
}

class _JoinView extends StatelessWidget {
  const _JoinView({
    required this.service,
    required this.state,
    required this.inviteController,
    required this.nicknameController,
    required this.onCreateRoom,
    required this.onJoinRoom,
  });

  final WatchPartyService service;
  final WatchPartyViewState state;
  final TextEditingController inviteController;
  final TextEditingController nicknameController;
  final VoidCallback onCreateRoom;
  final VoidCallback onJoinRoom;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final connecting =
        state.status == WatchPartyConnectionStatus.connecting ||
        state.status == WatchPartyConnectionStatus.reconnecting;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '一起看',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '与好友同步播放剧集，支持 Syncplay 客户端',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        if (state.error.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              state.error,
              style: TextStyle(color: colorScheme.onErrorContainer, fontSize: 13),
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: connecting ? null : onCreateRoom,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(42),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          icon: connecting
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_rounded),
          label: Text(connecting ? '正在创建...' : '创建房间'),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              Expanded(child: Divider()),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('或加入房间', style: TextStyle(fontSize: 12)),
              ),
              Expanded(child: Divider()),
            ],
          ),
        ),
        TextField(
          controller: inviteController,
          decoration: InputDecoration(
            labelText: '邀请码或邀请链接',
            prefixIcon: const Icon(Icons.link_rounded, size: 18),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: nicknameController,
          maxLength: 16,
          decoration: InputDecoration(
            labelText: '昵称',
            prefixIcon: const Icon(Icons.person_outline_rounded, size: 18),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            counterText: '',
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: connecting ? null : onJoinRoom,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(42),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          icon: connecting
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login_rounded),
          label: Text(connecting ? '正在加入...' : '加入'),
        ),
      ],
    );
  }
}

class _RoomView extends StatelessWidget {
  const _RoomView({
    required this.service,
    required this.state,
    required this.snapshot,
    required this.chatController,
    required this.onSendChat,
  });

  final WatchPartyService service;
  final WatchPartyViewState state;
  final WatchPartySnapshot snapshot;
  final TextEditingController chatController;
  final VoidCallback onSendChat;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isReconnecting =
        state.status == WatchPartyConnectionStatus.reconnecting;

    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 8, 4),
            child: Row(
              children: [
                Icon(
                  snapshot.canControl
                      ? Icons.admin_panel_settings_rounded
                      : Icons.visibility_rounded,
                  color: snapshot.canControl
                      ? Colors.green
                      : colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        snapshot.media.title.isEmpty
                            ? '一起看房间'
                            : snapshot.media.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        isReconnecting
                            ? '正在重连...'
                            : (snapshot.canControl ? '你可以控制播放' : '观众模式'),
                        style: TextStyle(
                          fontSize: 11,
                          color: isReconnecting
                              ? Colors.orange
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '选项',
                  onSelected: (value) {
                    if (value == 'leave') unawaited(service.leave());
                    if (value == 'close') unawaited(service.closeRoom());
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'leave', child: Text('离开房间')),
                    if (snapshot.isOwner)
                      PopupMenuItem(
                        value: 'close',
                        child: Text(
                          '结束房间',
                          style: TextStyle(color: colorScheme.error),
                        ),
                      ),
                  ],
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          TabBar(
            dividerColor: colorScheme.outlineVariant,
            indicatorSize: TabBarIndicatorSize.tab,
            labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            tabs: [
              Tab(text: '聊天 (${snapshot.chat.length})'),
              Tab(text: '成员 (${snapshot.members.length})'),
              const Tab(text: '邀请/连接'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _ChatTab(
                  snapshot: snapshot,
                  controller: chatController,
                  onSend: onSendChat,
                ),
                _MembersTab(
                  snapshot: snapshot,
                  service: service,
                ),
                _InviteTab(invite: state.invite),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatTab extends StatelessWidget {
  const _ChatTab({
    required this.snapshot,
    required this.controller,
    required this.onSend,
  });

  final WatchPartySnapshot snapshot;
  final TextEditingController controller;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Expanded(
          child: snapshot.chat.isEmpty
              ? Center(
                  child: Text(
                    '暂时没有消息',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  itemCount: snapshot.chat.length,
                  itemBuilder: (context, index) {
                    final msg = snapshot.chat[index];
                    final isSelf = msg.memberId == snapshot.selfId;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.5),
                      child: Align(
                        alignment: isSelf
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 280),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: isSelf
                                ? colorScheme.primary
                                : colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: isSelf
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              if (!isSelf)
                                Text(
                                  msg.username,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              Text(
                                msg.message,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isSelf
                                      ? colorScheme.onPrimary
                                      : colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        Container(
          padding: EdgeInsets.fromLTRB(
            12,
            6,
            8,
            6 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          decoration: BoxDecoration(
            color: colorScheme.surface,
            border: Border(
              top: BorderSide(color: colorScheme.outlineVariant),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  maxLength: 150,
                  textInputAction: TextInputAction.send,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: '发送消息...',
                    counterText: '',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  onSubmitted: (_) => onSend(),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: onSend,
                icon: const Icon(Icons.send_rounded, size: 20),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MembersTab extends StatelessWidget {
  const _MembersTab({
    required this.snapshot,
    required this.service,
  });

  final WatchPartySnapshot snapshot;
  final WatchPartyService service;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      itemCount: snapshot.members.length,
      itemBuilder: (context, index) {
        final member = snapshot.members[index];
        final isSelf = member.id == snapshot.selfId;
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            member.protocol == 'syncplay'
                ? Icons.desktop_windows_rounded
                : Icons.play_circle_outline_rounded,
            size: 20,
          ),
          title: Text('${member.name}${isSelf ? ' (你)' : ''}'),
          subtitle: Text(
            member.protocol == 'syncplay'
                ? 'Syncplay 客户端'
                : (member.verified ? 'AniBaka · 已验证' : 'AniBaka'),
          ),
          trailing: snapshot.isOwner && !isSelf
              ? Switch(
                  value: member.controller,
                  onChanged: (val) => service.setController(member.id, val),
                )
              : Icon(
                  member.controller
                      ? Icons.admin_panel_settings_rounded
                      : Icons.visibility_outlined,
                  size: 18,
                  color: member.controller
                      ? Colors.green
                      : colorScheme.onSurfaceVariant,
                ),
        );
      },
    );
  }
}

// ================= 邀请 Tab =================

class _InviteTab extends StatelessWidget {
  const _InviteTab({required this.invite});

  final WatchPartyInvite? invite;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (invite == null) {
      return Center(
        child: Text(
          '暂无邀请信息',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }
    final inv = invite!;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (inv.inviteUrl.isNotEmpty)
          Center(
            child: Container(
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: QrImageView(
                data: inv.inviteUrl,
                size: 110,
                backgroundColor: Colors.white,
              ),
            ),
          ),
        _buildInfoTile(
          context,
          '邀请链接',
          inv.inviteUrl,
          onCopy: () => _copy(context, inv.inviteUrl),
        ),
        _buildInfoTile(
          context,
          'Syncplay 服务器',
          '${inv.syncplayHost}:${inv.syncplayPort}',
          onCopy: () => _copy(context, '${inv.syncplayHost}:${inv.syncplayPort}'),
        ),
        _buildInfoTile(
          context,
          '房间名称',
          inv.syncplayRoom,
          onCopy: () => _copy(context, inv.syncplayRoom),
        ),
        if (inv.controllerPassword.isNotEmpty)
          _buildInfoTile(
            context,
            '控制密码 (房主)',
            inv.controllerPassword,
            onCopy: () => _copy(context, inv.controllerPassword),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _copy(
            context,
            '服务器: ${inv.syncplayHost}:${inv.syncplayPort}\n房间: ${inv.syncplayRoom}${inv.controllerPassword.isNotEmpty ? '\n密码: ${inv.controllerPassword}' : ''}',
          ),
          icon: const Icon(Icons.copy_all_rounded, size: 16),
          label: const Text('复制全部 Syncplay 配置'),
        ),
      ],
    );
  }

  Widget _buildInfoTile(
    BuildContext context,
    String label,
    String value, {
    required VoidCallback onCopy,
  }) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
      subtitle: SelectableText(
        value,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.copy_rounded, size: 16),
        onPressed: onCopy,
      ),
    );
  }

  Future<void> _copy(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) showSnackBar('已复制到剪贴板');
  }
}
