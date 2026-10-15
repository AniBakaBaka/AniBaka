import 'dart:async';

import 'package:baka/api/anibaka_api.dart';
import 'package:baka/api/post.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/app/watch_party_links.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/watch_party.dart';
import 'package:baka/pages/login/qr_scanner_page.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/pages/thread/thread_controller.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/comment/comment_card.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';

class _ThreadTab {
  _ThreadTab(this.name, int pid) : data = ThreadController(pid);

  final String name;
  final ThreadController data;
  final ScrollController scroll = ScrollController();
  final GlobalKey<CommentListState> commentKey = GlobalKey<CommentListState>();
  double lastOffset = 0;

  void dispose() {
    data.dispose();
    scroll.dispose();
  }
}

class ThreadPage extends StatefulWidget {
  const ThreadPage({super.key});

  @override
  State<ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<ThreadPage>
    with AutomaticKeepAliveClientMixin {
  static final _gvRegex = RegExp(r'^gv(\d+)$');
  final _tabs = [
    _ThreadTab('#茶馆', 6),
    _ThreadTab('#baka', 8),
    null, // 一起看
    _ThreadTab('#求番报错', 7),
    _ThreadTab('#反馈', 9),
    _ThreadTab('#里世界', 10),
  ];
  final _pageController = PageController();
  final _watchRooms = ValueNotifier(
    const AsyncSnapshot<List<WatchPartyInvite>>.nothing(),
  );
  final _joiningRoomCode = ValueNotifier('');
  Completer<void>? _watchRoomsAbort;
  late final Worker _commentWorker;

  int _index = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    for (final tab in _tabs) {
      if (tab != null) tab.scroll.addListener(() => _onScroll(tab));
    }
    _tabs.first!.data.load();
    _commentWorker = ever(Get.find<AppState>().sendCommentTrigger, (_) {
      _sendComment();
    });
  }

  @override
  void dispose() {
    _commentWorker.dispose();
    _pageController.dispose();
    for (final tab in _tabs) {
      tab?.dispose();
    }
    _watchRoomsAbort?.complete();
    _watchRooms.dispose();
    _joiningRoomCode.dispose();
    super.dispose();
  }

  void _onScroll(_ThreadTab tab) {
    if (tab != _tabs[_index] || !tab.scroll.hasClients) return;
    if (tab.data.canLoadMore && tab.scroll.position.extentAfter < 400) {
      tab.data.load();
    }
    if (Instances.isDesktopPlatform) return;
    final offset = tab.scroll.offset;
    if ((offset - tab.lastOffset).abs() <= 50) return;
    Get.find<AppState>().updateScrollDirection(offset > tab.lastOffset);
    tab.lastOffset = offset;
  }

  void _switch(int i, {bool fromPage = false}) {
    if (i == _index) return;
    setState(() => _index = i);
    if (!fromPage) {
      _pageController.jumpToPage(i);
    }
    final tab = _tabs[i];
    if (tab == null) {
      _refreshWatchRooms();
    } else if (tab.data.comments.isEmpty) {
      tab.data.load();
    }
  }

  Future<void> _sendComment() async {
    final tab = _tabs[_index];
    if (tab == null) {
      showSnackBar('一起看房间页不支持发帖');
      return;
    }
    final result = await CommentInputWidget.show(context);
    if (result == null || !mounted) return;
    final state = tab.commentKey.currentState;
    if (state == null) return;
    await state.sendComment(result, 0, '');
  }

  Future<void> _refreshWatchRooms() async {
    if (_watchRoomsAbort != null) {
      return;
    }
    final abort = _watchRoomsAbort = Completer<void>();
    _watchRooms.value = _watchRooms.value.inState(ConnectionState.waiting);
    try {
      final rooms = await AniBakaApi.listWatchRooms(abortTrigger: abort.future);
      if (mounted) {
        _watchRooms.value = AsyncSnapshot.withData(ConnectionState.done, rooms);
      }
    } catch (error, stackTrace) {
      if (mounted) {
        _watchRooms.value = AsyncSnapshot.withError(
          ConnectionState.done,
          error,
          stackTrace,
        );
      }
    } finally {
      _watchRoomsAbort = null;
    }
  }

  Future<void> _onLink(String text, String? url, String title) async {
    if (url == null) return;
    final match = _gvRegex.firstMatch(url);
    if (match == null) {
      launchUrlString(url, mode: LaunchMode.externalApplication);
      return;
    }
    try {
      final data = await getPostDetail(int.parse(match.group(1)!));
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlayerPage(request: PlaybackRequest.fromMap(data)),
          ),
        );
      }
    } catch (e) {
      showSnackBar('跳转失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Column(
        children: [
          _header(theme, isDark),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: _tabs.length,
              onPageChanged: (i) => _switch(i, fromPage: true),
              itemBuilder: (_, i) {
                final tab = _tabs[i];
                return tab == null
                    ? ValueListenableBuilder(
                        valueListenable: _watchRooms,
                        builder: (_, snapshot, _) =>
                            _watchPartyPage(theme, snapshot),
                      )
                    : ListenableBuilder(
                        listenable: tab.data,
                        builder: (_, _) => _page(tab, theme),
                      );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _page(_ThreadTab ui, ThemeData theme) {
    final tab = ui.data;

    return RefreshIndicator(
      onRefresh: () => tab.load(refresh: true),
      color: theme.colorScheme.primary,
      backgroundColor: theme.colorScheme.surface,
      displacement: 24,
      strokeWidth: 2.5,
      child: CustomScrollView(
        controller: ui.scroll,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          if (tab.error == null || tab.comments.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
              sliver: CommentList(
                pid: tab.pid,
                comments: tab.isRefreshing && tab.comments.isEmpty
                    ? null
                    : tab.comments,
                key: ui.commentKey,
                autoLoad: false,
                onRefresh: () => tab.load(refresh: true),
                asSliver: true,
                onTapLink: _onLink,
              ),
            ),
          if (tab.error != null)
            SliverToBoxAdapter(
              child: TextButton(
                onPressed: tab.load,
                child: const Text('加载评论失败，点击重试'),
              ),
            ),
          if (tab.isLoadingMore) SliverToBoxAdapter(child: _loadingMore(theme)),
          if (!tab.hasMore && tab.comments.isNotEmpty)
            const SliverToBoxAdapter(child: _EndIndicator()),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }

  Widget _watchPartyPage(
    ThemeData theme,
    AsyncSnapshot<List<WatchPartyInvite>> snapshot,
  ) {
    final rooms = snapshot.data ?? const [];
    return RefreshIndicator(
      onRefresh: _refreshWatchRooms,
      color: theme.colorScheme.primary,
      backgroundColor: theme.colorScheme.surface,
      displacement: 24,
      strokeWidth: 2.5,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '正在一起看',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _scanWatchParty,
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: const Text('扫一扫'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'AniBaka 房间可自动匹配剧集；Syncplay 房间会显示对方的媒体名称，需要手动打开对应视频。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (snapshot.connectionState == ConnectionState.waiting &&
              rooms.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (rooms.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _watchPartyEmptyState(theme, snapshot.error),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 90),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final roomIndex = index ~/ 2;
                  if (index.isOdd) return const SizedBox(height: 12);
                  return ValueListenableBuilder(
                    valueListenable: _joiningRoomCode,
                    builder: (_, code, _) =>
                        _watchPartyCard(rooms[roomIndex], theme, code),
                  );
                }, childCount: rooms.length * 2 - 1),
              ),
            ),
        ],
      ),
    );
  }

  Widget _watchPartyEmptyState(ThemeData theme, Object? error) {
    final hasError = error != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 12, 28, 100),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasError ? Icons.cloud_off_outlined : Icons.groups_outlined,
              size: 42,
              color: theme.colorScheme.primary.withValues(alpha: 0.75),
            ),
            const SizedBox(height: 12),
            Text(
              hasError ? error.toString() : '暂时没有正在进行的房间',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (hasError) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _refreshWatchRooms,
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _watchPartyCard(
    WatchPartyInvite room,
    ThemeData theme,
    String joiningCode,
  ) {
    final roomTitle = room.title.trim();
    final hasTitle = roomTitle.isNotEmpty;
    final title = hasTitle ? roomTitle : 'Syncplay 房间';
    final media = hasTitle
        ? 'EP${room.episodeIndex + 1}'
        : '房间 ${room.syncplayRoom}';
    final joining = joiningCode == room.inviteCode;

    return Material(
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: joiningCode.isEmpty ? () => _joinWatchParty(room) : null,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      theme.colorScheme.primary,
                      theme.colorScheme.tertiary,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.play_circle_fill_rounded,
                  color: Colors.white,
                  size: 32,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '$media · ${room.memberCount} 人在线',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (joining)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _joinWatchParty(WatchPartyInvite room) async {
    if (_joiningRoomCode.value.isNotEmpty) return;
    _joiningRoomCode.value = room.inviteCode;
    try {
      await Get.find<WatchPartyLinks>().joinInviteLink(room.inviteCode);
    } finally {
      if (mounted) _joiningRoomCode.value = '';
    }
  }

  Future<void> _scanWatchParty() async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const QrScannerPage()));
  }

  Widget _header(ThemeData theme, bool isDark) {
    final top = MediaQuery.paddingOf(context).top;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.black.withValues(alpha: 0.05);
    final chipBg = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.035);

    return Container(
      padding: EdgeInsets.only(top: top),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 10, 10),
        child: Row(
          children: [
            Expanded(child: _tabBar(theme, isDark, chipBg)),
            const SizedBox(width: 8),
            _refreshBtn(theme, isDark, chipBg),
          ],
        ),
      ),
    );
  }

  Widget _tabBar(ThemeData theme, bool isDark, Color chipBg) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: chipBg,
        borderRadius: BorderRadius.circular(100),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: [
            for (var i = 0; i < _tabs.length; i++) _tabChip(i, theme, isDark),
          ],
        ),
      ),
    );
  }

  Widget _tabChip(int i, ThemeData theme, bool isDark) {
    final selected = _index == i;
    final muted = isDark
        ? Colors.white54
        : theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.55) ??
              Colors.black54;

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        _switch(i);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(100),
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 220),
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            letterSpacing: 0.3,
            color: selected ? Colors.white : muted,
          ),
          child: Text(_tabs[i]?.name ?? '#一起看'),
        ),
      ),
    );
  }

  Widget _refreshBtn(ThemeData theme, bool isDark, Color chipBg) {
    final iconColor = isDark
        ? Colors.white60
        : theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.5);

    final tab = _tabs[_index]?.data;
    return ListenableBuilder(
      listenable: tab ?? _watchRooms,
      builder: (_, _) {
        final refreshing =
            tab?.isRefreshing ??
            (_watchRooms.value.connectionState == ConnectionState.waiting);
        return GestureDetector(
          onTap: refreshing
              ? null
              : () {
                  HapticFeedback.mediumImpact();
                  if (tab == null) {
                    _refreshWatchRooms();
                  } else {
                    tab.load(refresh: true);
                  }
                },
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: chipBg, shape: BoxShape.circle),
            child: refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.refresh_rounded, size: 19, color: iconColor),
          ),
        );
      },
    );
  }

  Widget _loadingMore(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '正在加载更多...',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.4),
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EndIndicator extends StatelessWidget {
  const _EndIndicator();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted =
        theme.textTheme.bodySmall?.color?.withValues(alpha: 0.15) ??
        Colors.grey.withValues(alpha: 0.15);
    final textColor = theme.textTheme.bodySmall?.color?.withValues(alpha: 0.25);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(width: 28, height: 0.5, color: muted),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              '到底了',
              style: TextStyle(
                color: textColor,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 1,
              ),
            ),
          ),
          Container(width: 28, height: 0.5, color: muted),
        ],
      ),
    );
  }
}
