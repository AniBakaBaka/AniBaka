import 'dart:math' as math;
import 'package:baka/app/watch_party_links.dart';
import 'package:baka/models/watch_party.dart';
import 'package:baka/pages/mine/mine_profile.dart';
import 'package:baka/services/playback/watch_party.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/player/settings_panel.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class _MembersView extends StatelessWidget {
  const _MembersView({
    required this.snapshot,
    required this.service,
    required this.connected,
  });
  final WatchPartySnapshot snapshot;
  final WatchPartyService service;
  final bool connected;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverList.list(
            children: [
              Text(
                '${snapshot.members.length} 人在房间中',
                style: TextStyle(color: colors.primary),
              ),
              const SizedBox(height: 8),
              if (snapshot.isOwner)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    '开启成员开关，允许对方控制播放',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          sliver: SliverList.builder(
            itemCount: snapshot.members.length,
            itemBuilder: (context, index) {
              final member = snapshot.members[index];
              return Material(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.vertical(
                  top: index == 0 ? const Radius.circular(24) : Radius.zero,
                  bottom: index == snapshot.members.length - 1
                      ? const Radius.circular(24)
                      : Radius.zero,
                ),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  leading: _Avatar(
                    name: member.name,
                    imageUrl: member.id == snapshot.selfId
                        ? service.session.avatarUrl
                        : null,
                  ),
                  title: Text(
                    '${member.name}${member.id == snapshot.selfId ? '（你）' : ''}',
                  ),
                  subtitle: Text(
                    '${member.id == snapshot.ownerId ? '房主 · ' : ''}${member.protocol == 'syncplay'
                        ? 'Syncplay'
                        : member.verified
                        ? 'AniBaka · 已验证'
                        : 'AniBaka'}\n${member.controller ? '可控制播放' : '观众'}',
                  ),
                  trailing: snapshot.isOwner && member.id != snapshot.selfId
                      ? Switch(
                          value: member.controller,
                          onChanged: connected
                              ? (value) =>
                                    service.setController(member.id, value)
                              : null,
                        )
                      : Icon(
                          member.controller
                              ? Icons.verified_user_rounded
                              : Icons.visibility_outlined,
                          color: colors.primary,
                        ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _InviteView extends StatelessWidget {
  const _InviteView({required this.invite, required this.isOwner});
  final WatchPartyInvite invite;
  final bool isOwner;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final includePassword = isOwner && invite.controllerPassword.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text(
          '邀请好友，同步观看',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: QrImageView(
              data: invite.inviteUrl,
              size: 144,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => _copy(invite.inviteUrl),
          style: FilledButton.styleFrom(
            backgroundColor: colors.primary,
            foregroundColor: colors.onPrimary,
          ),
          icon: const Icon(Icons.link_rounded),
          label: const Text('复制邀请链接'),
        ),
        const SizedBox(height: 12),
        _copyTile(context, '邀请码', invite.inviteCode),
        const SizedBox(height: 16),
        Material(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            title: const Text('使用 Syncplay 客户端'),
            subtitle: const Text('服务器、房间及控制密码'),
            shape: const Border(),
            collapsedShape: const Border(),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              _copyTile(
                context,
                '服务器',
                '${invite.syncplayHost}:${invite.syncplayPort}',
              ),
              _copyTile(context, '房间名称', invite.syncplayRoom),
              if (includePassword)
                _copyTile(context, '控制密码（房主）', invite.controllerPassword),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _copy(
                  '服务器: ${invite.syncplayHost}:${invite.syncplayPort}\n房间: ${invite.syncplayRoom}${includePassword ? '\n密码: ${invite.controllerPassword}' : ''}',
                ),
                icon: const Icon(Icons.copy_all_rounded),
                label: const Text('复制全部 Syncplay 配置'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _copyTile(BuildContext context, String label, String value) =>
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        title: Text(label, style: Theme.of(context).textTheme.labelMedium),
        subtitle: SelectableText(value),
        trailing: IconButton(
          tooltip: '复制$label',
          onPressed: () => _copy(value),
          icon: const Icon(Icons.copy_rounded, size: 20),
        ),
      );
  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      showSnackBar('已复制到剪贴板');
    } catch (_) {
      showSnackBar('复制失败，请长按内容复制', isError: true);
    }
  }
}

class _PartyHeader extends StatelessWidget {
  const _PartyHeader({
    required this.title,
    this.onBack,
    this.actions = const [],
  });
  final String title;
  final VoidCallback? onBack;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(onBack == null ? 20 : 8, 0, 8, 4),
    child: Row(
      children: [
        if (onBack != null)
          IconButton(
            tooltip: '返回聊天',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        ...actions,
        IconButton.filledTonal(
          tooltip: '收起一起看',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );
}

class _MediaCard extends StatelessWidget {
  const _MediaCard({
    required this.media,
    required this.caption,
    this.coverUrl,
    this.statusIcon,
    this.onInvite,
  });
  final WatchPartyMedia? media;
  final String caption;
  final String? coverUrl;
  final IconData? statusIcon;
  final VoidCallback? onInvite;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final data = media;
    final episode = data == null
        ? ''
        : data.episodeTitle.isNotEmpty
        ? data.episodeTitle
        : '第 ${data.episodeIndex + 1} 集';
    final cover = Container(
      width: 64,
      height: 52,
      alignment: Alignment.center,
      color: colors.primaryContainer,
      child: Icon(Icons.movie_rounded, color: colors.onPrimaryContainer),
    );
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            if (MediaQuery.sizeOf(context).width >= 360) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: coverUrl?.isNotEmpty == true
                    ? CachedNetworkImage(
                        imageUrl: coverUrl!,
                        width: 64,
                        height: 52,
                        memCacheWidth:
                            (64 * MediaQuery.devicePixelRatioOf(context))
                                .ceil(),
                        fit: BoxFit.cover,
                        placeholder: (_, _) => cover,
                        errorWidget: (_, _, _) => cover,
                      )
                    : cover,
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data == null ? '还没有播放视频' : '${data.title} · $episode',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (statusIcon != null) ...[
                        Icon(statusIcon, size: 16, color: colors.primary),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          caption,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (onInvite != null) ...[
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: onInvite,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(48, 40),
                ),
                icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                label: const Text('邀请'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, this.imageUrl, this.radius = 20});
  final String name;
  final String? imageUrl;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final trimmed = name.trim();
    final fallback = CircleAvatar(
      radius: radius,
      backgroundColor: colors.secondaryContainer,
      foregroundColor: colors.onSecondaryContainer,
      child: Text(
        trimmed.isEmpty ? '?' : trimmed.characters.first,
        style: TextStyle(fontSize: radius, fontWeight: FontWeight.w500),
      ),
    );
    final url = imageUrl;
    if (url == null || url.isEmpty) return fallback;
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        width: radius * 2,
        height: radius * 2,
        memCacheWidth: (radius * 2 * MediaQuery.devicePixelRatioOf(context))
            .ceil(),
        fit: BoxFit.cover,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.errorContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(message, style: TextStyle(color: colors.onErrorContainer)),
      ),
    );
  }
}

String _errorText(Object error) =>
    error is StateError ? error.message : error.toString();

class _RoomView extends StatefulWidget {
  const _RoomView({
    required this.service,
    required this.state,
    required this.compact,
    super.key,
  });
  final WatchPartyService service;
  final WatchPartyViewState state;
  final bool compact;
  @override
  State<_RoomView> createState() => _RoomViewState();
}

class _RoomViewState extends State<_RoomView> {
  final _chat = TextEditingController();
  final _scroll = ScrollController();
  _RoomPage _page = _RoomPage.chat;
  bool _nearBottom = true;
  bool _unread = false;
  bool _leaving = false;
  String _error = '';
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant _RoomView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.state.snapshot!.chat.lastOrNull?.id;
    final snapshot = widget.state.snapshot!;
    final after = snapshot.chat.lastOrNull;
    if (after != null && before != after.id) {
      if (_nearBottom || after.memberId == snapshot.selfId) {
        _scrollToLatest();
      } else {
        _unread = true;
      }
    }
  }

  @override
  void dispose() {
    _chat.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    _nearBottom = _scroll.offset < 64;
    if (_nearBottom && _unread) setState(() => _unread = false);
  }

  void _scrollToLatest() {
    _nearBottom = true;
    _unread = false;
    if (_scroll.hasClients && _scroll.offset != 0) _scroll.jumpTo(0);
  }

  void _openPage(_RoomPage page) {
    FocusScope.of(context).unfocus();
    if (_nearBottom) _scrollToLatest();
    setState(() => _page = page);
  }

  void _send() {
    if (!_canSend) return;
    widget.service.sendChat(_chat.text);
    HapticFeedback.lightImpact();
    _chat.clear();
    setState(_scrollToLatest);
  }

  bool get _canSend =>
      widget.state.connected &&
      _chat.text.trim().isNotEmpty &&
      (!_chat.value.composing.isValid || _chat.value.composing.isCollapsed);

  Future<void> _leave({required bool close}) async {
    if (_leaving) return;
    setState(() {
      _leaving = true;
      _error = '';
    });
    try {
      if (close) {
        await widget.service.closeRoom();
      } else {
        await widget.service.leave();
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _leaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final snapshot = widget.state.snapshot!;
    final canControl = snapshot.canControl;
    final chatPage = _page == _RoomPage.chat;
    final title = switch (_page) {
      _RoomPage.chat => '一起看',
      _RoomPage.members => '房间成员',
      _RoomPage.invite => '邀请好友',
    };
    final error = _error.isNotEmpty
        ? _error
        : widget.state.status == WatchPartyConnectionStatus.reconnecting
        ? ''
        : widget.state.error;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (chatPage) {
            Navigator.of(context).pop();
          } else {
            _openPage(_RoomPage.chat);
          }
        },
      },
      child: PopScope(
        canPop: chatPage,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _openPage(_RoomPage.chat);
        },
        child: Column(
          children: [
            _PartyHeader(
              title: title,
              onBack: chatPage ? null : () => _openPage(_RoomPage.chat),
              actions: chatPage
                  ? [
                      Semantics(
                        label: '房间成员，${snapshot.members.length}人',
                        button: true,
                        child: FilledButton.tonalIcon(
                          key: const ValueKey('party-members'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(56, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          onPressed: () => _openPage(_RoomPage.members),
                          icon: const Icon(Icons.group_rounded, size: 18),
                          label: Text('${snapshot.members.length}'),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '房间选项',
                        style: IconButton.styleFrom(
                          backgroundColor: colors.surfaceContainerHigh,
                        ),
                        enabled: !_leaving,
                        onSelected: (value) => _leave(close: value == 'close'),
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'leave',
                            child: Text('离开房间'),
                          ),
                          if (snapshot.isOwner)
                            PopupMenuItem(
                              value: 'close',
                              child: Text(
                                '结束房间',
                                style: TextStyle(color: colors.error),
                              ),
                            ),
                        ],
                      ),
                    ]
                  : const [],
            ),
            if (!chatPage)
              Expanded(
                child: _page == _RoomPage.members
                    ? _MembersView(
                        snapshot: snapshot,
                        service: widget.service,
                        connected: widget.state.connected,
                      )
                    : _InviteView(
                        invite: widget.state.invite!,
                        isOwner: snapshot.isOwner,
                      ),
              )
            else ...[
              if (!widget.compact)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: _MediaCard(
                    media: snapshot.media,
                    coverUrl:
                        widget.service.matchesAttachedMedia(snapshot.media)
                        ? widget.service.currentCoverImageUrl
                        : null,
                    caption: switch (widget.state.status) {
                      WatchPartyConnectionStatus.connected =>
                        canControl ? '你可以控制播放' : '观众模式',
                      WatchPartyConnectionStatus.reconnecting => '连接已断开，正在重连…',
                      WatchPartyConnectionStatus.connecting => '正在连接…',
                      _ => '连接已断开',
                    },
                    statusIcon: widget.state.connected
                        ? canControl
                              ? Icons.verified_user_rounded
                              : Icons.visibility_outlined
                        : Icons.sync_rounded,
                    onInvite: () => _openPage(_RoomPage.invite),
                  ),
                ),
              if (widget.compact && !widget.state.connected)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    '连接已断开，正在重连…',
                    style: TextStyle(color: colors.primary),
                  ),
                ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: _Notice(message: error),
                ),
              Expanded(
                child: Stack(
                  children: [
                    if (snapshot.chat.isEmpty)
                      Center(
                        child: Text(
                          '邀请好友，聊聊正在看的这一集',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      )
                    else
                      ListView.builder(
                        key: PageStorageKey(snapshot.roomId),
                        controller: _scroll,
                        // Read the shared history backwards so the newest row
                        // stays at offset zero, including keyboard resizes.
                        reverse: true,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        itemCount: snapshot.chat.length,
                        itemBuilder: (_, reverseIndex) {
                          final index = snapshot.chat.length - 1 - reverseIndex;
                          final message = snapshot.chat[index];
                          bool sameAuthor(WatchPartyChatMessage other) =>
                              other.memberId == message.memberId &&
                              other.username == message.username;
                          return _MessageBubble(
                            key: ValueKey(message.id),
                            message: message,
                            isSelf: message.memberId == snapshot.selfId,
                            first:
                                index == 0 ||
                                !sameAuthor(snapshot.chat[index - 1]),
                            last:
                                index == snapshot.chat.length - 1 ||
                                !sameAuthor(snapshot.chat[index + 1]),
                          );
                        },
                      ),
                    if (_unread)
                      Positioned(
                        bottom: 8,
                        right: 16,
                        child: FilledButton.tonalIcon(
                          onPressed: () {
                            setState(_scrollToLatest);
                          },
                          icon: const Icon(
                            Icons.arrow_downward_rounded,
                            size: 18,
                          ),
                          label: const Text('新消息'),
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
                  widget.compact ? 12 : 24,
                ),
                child: Material(
                  key: const ValueKey('party-composer-island'),
                  color: colors.surfaceContainerHigh,
                  elevation: 2,
                  shadowColor: Colors.black26,
                  borderRadius: BorderRadius.circular(32),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('party-message-input'),
                            controller: _chat,
                            minLines: 1,
                            maxLines: widget.compact ? 2 : 3,
                            maxLength: 150,
                            textInputAction: TextInputAction.send,
                            style: Theme.of(context).textTheme.bodyLarge,
                            decoration: InputDecoration(
                              hintText: widget.state.connected
                                  ? '聊点什么…'
                                  : '重连中，草稿会保留',
                              counterText: '',
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 12,
                              ),
                            ),
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _chat,
                          builder: (_, _, _) => IconButton.filled(
                            tooltip: '发送消息',
                            onPressed: _canSend ? _send : null,
                            style: IconButton.styleFrom(
                              minimumSize: const Size(48, 48),
                              backgroundColor: colors.primary,
                              foregroundColor: colors.onPrimary,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                            icon: const Icon(Icons.send_rounded),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isSelf,
    required this.first,
    required this.last,
    super.key,
  });
  final WatchPartyChatMessage message;
  final bool isSelf;
  final bool first;
  final bool last;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final shape = BorderRadius.only(
      topLeft: Radius.circular(!isSelf && !first ? 4 : 24),
      bottomLeft: Radius.circular(!isSelf && !last ? 4 : 24),
      topRight: Radius.circular(isSelf && !first ? 4 : 24),
      bottomRight: Radius.circular(isSelf && !last ? 4 : 24),
    );
    return Padding(
      padding: EdgeInsets.only(top: first ? 16 : 3),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          mainAxisAlignment: isSelf
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isSelf) ...[
              SizedBox(
                width: 32,
                child: first
                    ? Padding(
                        padding: const EdgeInsets.only(top: 22),
                        child: _Avatar(name: message.username, radius: 16),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
            ],
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .84,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!isSelf && first) ...[
                      Text(
                        message.username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: isSelf
                            ? colors.primaryContainer
                            : colors.surfaceContainerHigh,
                        borderRadius: shape,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Text(
                          message.message,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: isSelf
                                ? colors.onPrimaryContainer
                                : colors.onSurface,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WatchPartySheet extends StatelessWidget {
  const WatchPartySheet({required this.service, super.key});
  final WatchPartyService service;
  static Future<void> show(BuildContext context, WatchPartyService service) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.transparent,
        constraints: const BoxConstraints(maxWidth: 560),
        builder: (_) => WatchPartySheet(service: service),
      );
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final portrait = isBottomPlayerPanel(context);
    final theme = playerPanelTheme(
      Theme.of(context),
      bottom: true,
      compact: false,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = math.max(
          0.0,
          constraints.maxHeight - media.viewInsets.bottom,
        );
        final preferred = portrait
            ? (media.size.height - media.size.width * 9 / 16).clamp(
                0.0,
                media.size.height * .74,
              )
            : media.size.height * .9;
        final height = math.min(preferred, available);
        return Padding(
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: Theme(
            data: theme,
            child: Material(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(32),
              ),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                height: height,
                child: SafeArea(
                  top: false,
                  child: Column(
                    children: [
                      SizedBox(
                        height: 24,
                        child: Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: .4),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: ValueListenableBuilder<WatchPartyViewState>(
                          valueListenable: service.state,
                          builder: (context, state, _) {
                            final snapshot = state.snapshot;
                            return snapshot == null
                                ? _EntryView(service: service)
                                : _RoomView(
                                    key: ValueKey(snapshot.roomId),
                                    service: service,
                                    state: state,
                                    compact: height < 360,
                                  );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

enum _EntryMode { create, join }

enum _RoomPage { chat, members, invite }

class _EntryView extends StatefulWidget {
  const _EntryView({required this.service});
  final WatchPartyService service;

  @override
  State<_EntryView> createState() => _EntryViewState();
}

class _EntryViewState extends State<_EntryView> {
  final _invite = TextEditingController();
  late final TextEditingController _nickname;
  final _nicknameFocus = FocusNode();
  _EntryMode _mode = _EntryMode.create;
  String _error = '';
  @override
  void initState() {
    super.initState();
    _nickname = TextEditingController(text: widget.service.currentNickname());
  }

  @override
  void dispose() {
    _invite.dispose();
    _nickname.dispose();
    _nicknameFocus.dispose();
    super.dispose();
  }

  bool get _busy => switch (widget.service.state.value.status) {
    WatchPartyConnectionStatus.connecting ||
    WatchPartyConnectionStatus.reconnecting ||
    WatchPartyConnectionStatus.connected => true,
    _ => false,
  };
  Future<void> _connect() async {
    if (_busy) return;
    final mode = _mode;
    final code = mode == _EntryMode.join
        ? WatchPartyLinks.inviteCodeFromValue(_invite.text)
        : null;
    if (mode == _EntryMode.join && code == null) {
      setState(() => _error = '请输入有效的邀请码或邀请链接');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _error = '');
    try {
      if (mode == _EntryMode.create) {
        await widget.service.createRoom();
      } else {
        await widget.service.joinInvite(code!, nickname: _nickname.text);
      }
    } catch (error) {
      if (mounted && widget.service.state.value.error.isEmpty) {
        setState(() => _error = _errorText(error));
      }
    }
  }

  Future<void> _pasteInvite() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        setState(() => _error = '剪贴板中没有邀请内容');
        return;
      }
      _invite.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      setState(() => _error = '');
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取剪贴板，请手动输入邀请');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.service.state.value;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final joining = _mode == _EntryMode.join;
    final error = _error.isNotEmpty ? _error : state.error;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final current = widget.service.currentMedia;
    return Column(
      children: [
        const _PartyHeader(title: '一起看'),
        Expanded(
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Material(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(32),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    children: [
                      for (final mode in _EntryMode.values)
                        Expanded(
                          child: Semantics(
                            selected: _mode == mode,
                            inMutuallyExclusiveGroup: true,
                            child: TextButton(
                              onPressed: _busy
                                  ? null
                                  : () {
                                      FocusScope.of(context).unfocus();
                                      setState(() {
                                        _mode = mode;
                                        _error = '';
                                      });
                                    },
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 48),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                backgroundColor: _mode == mode
                                    ? colors.primary
                                    : Colors.transparent,
                                foregroundColor: _mode == mode
                                    ? colors.onPrimary
                                    : colors.onSurfaceVariant,
                                shape: const StadiumBorder(),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (_mode == mode) ...[
                                    const Icon(
                                      Icons.check_circle_rounded,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Flexible(
                                    child: Text(
                                      mode == _EntryMode.create
                                          ? '创建房间'
                                          : '加入房间',
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (!keyboard) ...[
                const SizedBox(height: 16),
                ExcludeSemantics(
                  child: Image.asset(
                    joining
                        ? 'assets/watch_party_join.png'
                        : 'assets/watch_party_create.png',
                    height: 108,
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(height: 20),
              ] else
                const SizedBox(height: 16),
              Text(
                joining ? '输入邀请，加入好友' : '和朋友，同步看',
                textAlign: joining ? TextAlign.start : TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                joining ? '支持邀请链接或邀请码' : '播放、暂停与进度一起同步',
                textAlign: joining ? TextAlign.start : TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              if (joining) ...[
                TextField(
                  key: const ValueKey('party-invite-input'),
                  controller: _invite,
                  enabled: !_busy,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: '邀请链接或邀请码',
                    hintText: '粘贴好友发来的邀请',
                    filled: true,
                    fillColor: colors.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: colors.primary, width: 2),
                    ),
                    contentPadding: const EdgeInsets.all(20),
                    suffixIcon: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: IconButton(
                        tooltip: '粘贴邀请',
                        onPressed: _busy ? null : _pasteInvite,
                        icon: const Icon(Icons.content_paste_rounded),
                      ),
                    ),
                  ),
                  onSubmitted: (_) => _connect(),
                ),
                const SizedBox(height: 12),
              ] else ...[
                _MediaCard(
                  media: current,
                  coverUrl: widget.service.currentCoverImageUrl,
                  caption: current == null ? '请先打开要观看的视频' : '当前视频',
                ),
                const SizedBox(height: 16),
              ],
              Material(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _nickname,
                        builder: (_, value, _) => _Avatar(
                          imageUrl: widget.service.session.avatarUrl,
                          name: joining
                              ? value.text
                              : widget.service.currentNickname(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: joining
                            ? TextField(
                                key: const ValueKey('party-nickname-input'),
                                controller: _nickname,
                                focusNode: _nicknameFocus,
                                readOnly: _busy,
                                maxLength: 16,
                                textInputAction: TextInputAction.done,
                                decoration: const InputDecoration(
                                  labelText: '昵称',
                                  counterText: '',
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  isDense: true,
                                ),
                                onSubmitted: (_) => _nicknameFocus.unfocus(),
                              )
                            : Text(
                                '以 ${widget.service.currentNickname()} 的身份加入',
                                style: theme.textTheme.bodyMedium,
                              ),
                      ),
                      if (joining)
                        IconButton(
                          tooltip: '编辑昵称',
                          onPressed: _busy ? null : _nicknameFocus.requestFocus,
                          icon: const Icon(Icons.edit_rounded),
                        ),
                    ],
                  ),
                ),
              ),
              if (joining)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Text(
                    '这个名字会显示在房间里',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: _Notice(message: error),
                ),
              const SizedBox(height: 20),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _invite,
                builder: (_, value, _) => FilledButton.icon(
                  key: const ValueKey('party-connect'),
                  onPressed:
                      _busy ||
                          (joining
                              ? value.text.trim().isEmpty
                              : current == null)
                      ? null
                      : _connect,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: colors.primary,
                    foregroundColor: colors.onPrimary,
                  ),
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          joining
                              ? Icons.arrow_forward_rounded
                              : Icons.add_rounded,
                        ),
                  label: Text(
                    _busy
                        ? (joining ? '正在加入…' : '正在创建…')
                        : joining
                        ? '加入房间'
                        : '创建房间',
                  ),
                ),
              ),
              if (!joining)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '创建后分享邀请，好友即可加入',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
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
