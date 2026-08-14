import 'dart:async';

import 'package:baka/instance.dart';
import 'package:baka/models/watch_party.dart';
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
        barrierColor: Colors.black.withValues(alpha: 0.45),
        constraints: const BoxConstraints(maxWidth: 580),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      height: MediaQuery.sizeOf(context).height * 0.82,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: isDark ? Colors.white24 : Colors.black12,
                ),
              ),
            ),
            Expanded(
              child: ValueListenableBuilder<WatchPartyViewState>(
                valueListenable: widget.service.state,
                builder: (context, state, _) => state.snapshot != null
                    ? _buildRoom(context, state, isDark, colorScheme)
                    : _buildJoin(context, state, isDark, colorScheme),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ================= 未加入：创建 / 加入 视图 =================

  Widget _buildJoin(
    BuildContext context,
    WatchPartyViewState state,
    bool isDark,
    ColorScheme colorScheme,
  ) {
    final connecting =
        state.status == WatchPartyConnectionStatus.connecting ||
        state.status == WatchPartyConnectionStatus.reconnecting;
    final primary = colorScheme.primary;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '一起看',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
              color: colorScheme.error.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              state.error,
              style: TextStyle(color: colorScheme.error, fontSize: 13),
            ),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: connecting || _busy
              ? null
              : () => _run(widget.service.createRoom),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          icon: connecting
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.add_rounded),
          label: Text(connecting ? '正在创建...' : '创建房间'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Row(
            children: [
              Expanded(
                child: Divider(color: isDark ? Colors.white10 : Colors.black12),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '或加入房间',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: Divider(color: isDark ? Colors.white10 : Colors.black12),
              ),
            ],
          ),
        ),
        TextField(
          controller: _inviteController,
          decoration: _inputDeco(
            labelText: '邀请码或邀请链接',
            icon: Icons.link_rounded,
            isDark: isDark,
            primary: primary,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _nicknameController,
          maxLength: 16,
          decoration: _inputDeco(
            labelText: '昵称',
            icon: Icons.person_outline_rounded,
            isDark: isDark,
            primary: primary,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: connecting || _busy
              ? null
              : () => _run(
                  () => widget.service.joinInvite(
                    _extractInviteCode(_inviteController.text),
                    nickname: _nicknameController.text,
                  ),
                ),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
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

  // ================= 房间详情视图（Tab 结构） =================

  Widget _buildRoom(
    BuildContext context,
    WatchPartyViewState state,
    bool isDark,
    ColorScheme colorScheme,
  ) {
    final snapshot = state.snapshot!;
    final invite = state.invite;
    final primary = colorScheme.primary;
    final isReconnecting =
        state.status == WatchPartyConnectionStatus.reconnecting;

    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          // 顶部 Header 状态
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 12, 6),
            child: Row(
              children: [
                Icon(
                  snapshot.canControl
                      ? Icons.admin_panel_settings_rounded
                      : Icons.visibility_rounded,
                  color: snapshot.canControl
                      ? const Color(0xFF66BB6A)
                      : primary,
                  size: 22,
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
                          fontSize: 16,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        isReconnecting
                            ? '正在重连...'
                            : '${snapshot.canControl ? '你可以控制播放' : '观众模式'}${state.latencyMs != null ? ' · 延迟 ${state.latencyMs}ms' : ''}',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isReconnecting
                              ? const Color(0xFFFFB300)
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '选项',
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onSelected: (value) {
                    if (value == 'leave') unawaited(widget.service.leave());
                    if (value == 'close')
                      unawaited(_run(widget.service.closeRoom));
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

          // Tab 栏
          Container(
            height: 38,
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            child: TabBar(
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: isDark ? const Color(0xFF2C2C2E) : Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              labelColor: colorScheme.onSurface,
              unselectedLabelColor: colorScheme.onSurfaceVariant,
              labelStyle: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
              tabs: [
                Tab(text: '聊天 (${snapshot.chat.length})'),
                Tab(text: '成员 (${snapshot.members.length})'),
                const Tab(text: '邀请/连接'),
              ],
            ),
          ),

          // TabBar 对应视图
          Expanded(
            child: TabBarView(
              children: [
                // 1. 聊天 Tab
                _buildChatTab(snapshot, isDark, colorScheme),
                // 2. 成员 Tab
                _buildMembersTab(snapshot, colorScheme),
                // 3. 邀请 Tab
                _buildInviteTab(invite, isDark, colorScheme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ================= 子 Tab 视图 =================

  Widget _buildChatTab(
    WatchPartySnapshot snapshot,
    bool isDark,
    ColorScheme colorScheme,
  ) {
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
                    vertical: 10,
                  ),
                  itemCount: snapshot.chat.length,
                  itemBuilder: (context, index) {
                    final msg = snapshot.chat[index];
                    final isSelf = msg.memberId == snapshot.selfId;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Align(
                        alignment: isSelf
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 300),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: isSelf
                                ? colorScheme.primary
                                : (isDark
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : const Color(0xFFF0F1F5)),
                            borderRadius: BorderRadius.circular(12),
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
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              Text(
                                msg.message,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isSelf
                                      ? Colors.white
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
            16,
            6,
            12,
            6 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF16151D) : const Color(0xFFF8F9FC),
            border: Border(
              top: BorderSide(
                color: isDark
                    ? Colors.white10
                    : Colors.black.withValues(alpha: 0.05),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  maxLength: 150,
                  textInputAction: TextInputAction.send,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    hintText: '发送消息...',
                    counterText: '',
                    isDense: true,
                    filled: true,
                    fillColor: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                  ),
                  onSubmitted: (_) => _sendChat(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _sendChat,
                icon: Icon(
                  Icons.send_rounded,
                  color: colorScheme.primary,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMembersTab(
    WatchPartySnapshot snapshot,
    ColorScheme colorScheme,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: snapshot.members.length,
      itemBuilder: (context, index) {
        final member = snapshot.members[index];
        final isSelf = member.id == snapshot.selfId;
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(
            radius: 16,
            child: Icon(
              member.protocol == 'syncplay'
                  ? Icons.desktop_windows_rounded
                  : Icons.play_circle_outline_rounded,
              size: 16,
            ),
          ),
          title: Text('${member.name}${isSelf ? ' (你)' : ''}'),
          subtitle: Text(
            member.protocol == 'syncplay'
                ? 'Syncplay 客户端'
                : (member.verified ? 'AniBaka · 已验证' : 'AniBaka'),
          ),
          trailing: snapshot.isOwner && !isSelf
              ? Transform.scale(
                  scale: 0.8,
                  child: Switch(
                    value: member.controller,
                    onChanged: (val) =>
                        widget.service.setController(member.id, val),
                  ),
                )
              : Icon(
                  member.controller
                      ? Icons.admin_panel_settings_rounded
                      : Icons.visibility_outlined,
                  size: 18,
                  color: member.controller
                      ? const Color(0xFF66BB6A)
                      : colorScheme.onSurfaceVariant,
                ),
        );
      },
    );
  }

  Widget _buildInviteTab(
    WatchPartyInvite? invite,
    bool isDark,
    ColorScheme colorScheme,
  ) {
    if (invite == null) {
      return Center(
        child: Text(
          '暂无邀请信息',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (invite.inviteUrl.isNotEmpty)
          Center(
            child: Container(
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: invite.inviteUrl,
                size: 120,
                backgroundColor: Colors.white,
              ),
            ),
          ),
        _buildInfoTile(
          '邀请链接',
          invite.inviteUrl,
          onCopy: () => _copy(invite.inviteUrl),
        ),
        _buildInfoTile(
          'Syncplay 服务器',
          '${invite.syncplayHost}:${invite.syncplayPort}',
          onCopy: () => _copy('${invite.syncplayHost}:${invite.syncplayPort}'),
        ),
        _buildInfoTile(
          '房间名称',
          invite.syncplayRoom,
          onCopy: () => _copy(invite.syncplayRoom),
        ),
        if (invite.controllerPassword.isNotEmpty)
          _buildInfoTile(
            '控制密码 (房主)',
            invite.controllerPassword,
            onCopy: () => _copy(invite.controllerPassword),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _copy(
            '服务器: ${invite.syncplayHost}:${invite.syncplayPort}\n房间: ${invite.syncplayRoom}${invite.controllerPassword.isNotEmpty ? '\n密码: ${invite.controllerPassword}' : ''}',
          ),
          icon: const Icon(Icons.copy_all_rounded, size: 16),
          label: const Text('复制全部 Syncplay 配置'),
        ),
      ],
    );
  }

  Widget _buildInfoTile(
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

  InputDecoration _inputDeco({
    required String labelText,
    required IconData icon,
    required bool isDark,
    required Color primary,
  }) {
    return InputDecoration(
      labelText: labelText,
      counterText: '',
      prefixIcon: Icon(icon, size: 18),
      filled: true,
      fillColor: isDark
          ? Colors.white.withValues(alpha: 0.05)
          : Colors.black.withValues(alpha: 0.03),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );
  }

  // ================= 行为方法 =================

  void _sendChat() {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    widget.service.sendChat(text);
    _chatController.clear();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted)
        showSnackBar(
          error.toString().replaceFirst('Bad state: ', ''),
          isError: true,
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) showSnackBar('已复制到剪贴板');
  }

  static String _extractInviteCode(String value) {
    final trimmed = value.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.pathSegments.isNotEmpty)
      return uri.pathSegments.last;
    return trimmed;
  }

  static String _defaultNickname() {
    final raw = Instances.sp.getString('userinfo') ?? '';
    final match = RegExp(r'"name"\s*:\s*"([^"]+)"').firstMatch(raw);
    return match?.group(1) ?? 'AniBaka';
  }
}
