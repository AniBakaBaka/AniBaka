import 'dart:async';

import 'package:baka/instance.dart';
import 'package:baka/models/watch_party.dart';
import 'package:baka/services/watch_party_service.dart';
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
        builder: (_) => WatchPartySheet(service: service),
      );

  @override
  State<WatchPartySheet> createState() => _WatchPartySheetState();
}

class _WatchPartySheetState extends State<WatchPartySheet> {
  final _inviteController = TextEditingController();
  final _nicknameController = TextEditingController();
  final _chatController = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _nicknameController.text = _defaultNickname();
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
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.82,
        child: ValueListenableBuilder<WatchPartyViewState>(
          valueListenable: widget.service.state,
          builder: (context, state, _) => state.snapshot != null
              ? _buildRoom(context, state)
              : _buildJoin(context, state),
        ),
      ),
    );
  }

  Widget _buildJoin(BuildContext context, WatchPartyViewState state) {
    final connecting =
        state.status == WatchPartyConnectionStatus.connecting ||
        state.status == WatchPartyConnectionStatus.reconnecting;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '一起看',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text('AniBaka 用户可通过邀请链接自动匹配剧集；原版 Syncplay 用户也能加入同一个房间。'),
        if (state.error.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            state.error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: connecting || _busy
              ? null
              : () => _run(widget.service.createRoom),
          icon: const Icon(Icons.add_rounded),
          label: const Text('创建房间'),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 22),
          child: Row(
            children: [
              Expanded(child: Divider()),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('或加入房间'),
              ),
              Expanded(child: Divider()),
            ],
          ),
        ),
        TextField(
          controller: _inviteController,
          decoration: const InputDecoration(
            labelText: '邀请码或邀请链接',
            prefixIcon: Icon(Icons.link_rounded),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _nicknameController,
          maxLength: 16,
          decoration: const InputDecoration(
            labelText: '昵称',
            prefixIcon: Icon(Icons.person_outline),
            border: OutlineInputBorder(),
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: connecting || _busy
              ? null
              : () => _run(
                  () => widget.service.joinInvite(
                    _extractInviteCode(_inviteController.text),
                    nickname: _nicknameController.text,
                  ),
                ),
          icon: connecting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login_rounded),
          label: const Text('加入'),
        ),
      ],
    );
  }

  Widget _buildRoom(BuildContext context, WatchPartyViewState state) {
    final snapshot = state.snapshot;
    if (snapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final invite = state.invite;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
          child: Row(
            children: [
              Icon(
                snapshot.canControl
                    ? Icons.admin_panel_settings
                    : Icons.lock_outline,
              ),
              const SizedBox(width: 10),
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
                        fontSize: 18,
                      ),
                    ),
                    Text(
                      state.status == WatchPartyConnectionStatus.reconnecting
                          ? '连接已断开，正在重连'
                          : '${snapshot.canControl ? '你可以控制播放' : '观众模式 · 由控制者操作'}'
                                '${state.latencyMs == null ? '' : ' · 延迟 ${state.latencyMs}ms'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            children: [
              if (invite != null) _buildInviteCard(context, invite),
              const SizedBox(height: 18),
              Text(
                '成员 ${snapshot.members.length}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              ...snapshot.members.map(
                (member) => _buildMember(snapshot, member),
              ),
              const SizedBox(height: 18),
              Text('聊天', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (snapshot.chat.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('暂时没有消息'),
                )
              else
                ...snapshot.chat.map(
                  (message) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      message.username,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(message.message),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            12 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  maxLength: 150,
                  decoration: const InputDecoration(
                    hintText: '发送消息',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _sendChat(),
                ),
              ),
              IconButton(
                onPressed: _sendChat,
                icon: const Icon(Icons.send_rounded),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'leave') {
                    unawaited(widget.service.leave());
                  }
                  if (value == 'close') {
                    unawaited(_run(widget.service.closeRoom));
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'leave', child: Text('离开房间')),
                  if (snapshot.isOwner)
                    const PopupMenuItem(value: 'close', child: Text('结束房间')),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInviteCard(BuildContext context, WatchPartyInvite invite) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (invite.inviteUrl.isNotEmpty)
              QrImageView(
                data: invite.inviteUrl,
                size: 104,
                backgroundColor: Colors.white,
              ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '邀请好友',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(invite.inviteUrl),
                  const SizedBox(height: 8),
                  Text(
                    'Syncplay：${invite.syncplayHost}:${invite.syncplayPort}',
                  ),
                  SelectableText('房间：${invite.syncplayRoom}'),
                  if (invite.controllerPassword.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('仅房主可见的 Syncplay 控制密码'),
                    SelectableText(invite.controllerPassword),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => _copy(invite.inviteUrl),
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('复制链接'),
                      ),
                      if (invite.controllerPassword.isNotEmpty)
                        TextButton.icon(
                          onPressed: () => _copy(invite.controllerPassword),
                          icon: const Icon(Icons.key_rounded, size: 18),
                          label: const Text('复制控制密码'),
                        ),
                      TextButton.icon(
                        onPressed: () => _copy(
                          '${invite.syncplayHost}:${invite.syncplayPort}\n${invite.syncplayRoom}',
                        ),
                        icon: const Icon(Icons.devices, size: 18),
                        label: const Text('复制 Syncplay 信息'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMember(WatchPartySnapshot snapshot, WatchPartyMember member) {
    final isSelf = member.id == snapshot.selfId;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        child: Icon(
          member.protocol == 'syncplay'
              ? Icons.desktop_windows
              : Icons.play_circle_outline,
        ),
      ),
      title: Text('${member.name}${isSelf ? '（你）' : ''}'),
      subtitle: Text(
        member.protocol == 'syncplay'
            ? 'Syncplay · 未验证昵称'
            : (member.verified ? 'AniBaka · 已验证' : 'AniBaka'),
      ),
      trailing: snapshot.isOwner && !isSelf
          ? Switch(
              value: member.controller,
              onChanged: (value) =>
                  widget.service.setController(member.id, value),
            )
          : Icon(
              member.controller
                  ? Icons.admin_panel_settings
                  : Icons.visibility_outlined,
            ),
    );
  }

  void _sendChat() {
    widget.service.sendChat(_chatController.text);
    _chatController.clear();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Bad state: ', '')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已复制')));
    }
  }

  static String _extractInviteCode(String value) {
    final trimmed = value.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last;
    }
    return trimmed;
  }

  static String _defaultNickname() {
    final raw = Instances.sp.getString('userinfo') ?? '';
    final match = RegExp(r'"name"\s*:\s*"([^"]+)"').firstMatch(raw);
    return match?.group(1) ?? 'AniBaka';
  }
}
