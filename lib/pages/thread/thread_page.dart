import 'package:get/get.dart';
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/watch_party.dart';
import 'package:baka/pages/login/qr_scanner_page.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/services/thread_service.dart';
import 'package:baka/services/watch_party_link_service.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/comment/comment_card.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// 单标签页 UI 状态（滚动 + CommentList key）
class _TabUi {
  final ScrollController scroll = ScrollController();
  final GlobalKey<CommentListState> commentKey = GlobalKey<CommentListState>();
  double lastOffset = 0;

  void dispose() => scroll.dispose();
}

class ThreadPage extends StatefulWidget {
  const ThreadPage({super.key});

  @override
  State<ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<ThreadPage>
    with AutomaticKeepAliveClientMixin {
  static final _gvRegex = RegExp(r'gv(\d+)');
  static const int _watchPartyIndex = 2;

  final ThreadService _svc = ThreadService();
  late final PageController _pageController;
  late final List<_TabUi> _uis;
  late final Worker _commentWorker;

  int _index = 0;
  String _joiningRoomCode = '';

  @override
  bool get wantKeepAlive => true;

  int get _pageCount => _svc.tabs.length + 1;
  bool _isWatchPartyTab(int index) => index == _watchPartyIndex;
  int _threadIndex(int pageIndex) =>
      pageIndex < _watchPartyIndex ? pageIndex : pageIndex - 1;
  int _pageIndex(int threadIndex) =>
      threadIndex < _watchPartyIndex ? threadIndex : threadIndex + 1;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _uis = List.generate(_svc.tabs.length, (i) {
      final ui = _TabUi();
      ui.scroll.addListener(() => _onScroll(i));
      return ui;
    });
    _ensureLoaded(_index);
    _commentWorker = ever(Get.find<AppState>().sendCommentTrigger, (_) {
      _sendComment();
    });
  }

  @override
  void dispose() {
    _commentWorker.dispose();
    _pageController.dispose();
    for (final ui in _uis) {
      ui.dispose();
    }
    super.dispose();
  }

  Future<void> _ensureLoaded(int i) async {
    final hasCache = _svc.loadCached(i, ignoreExpiry: true);
    if (hasCache) {
      if (mounted) setState(() {});
      _refresh(i, silent: true);
      return;
    }
    await _refresh(i);
  }

  Future<void> _refresh(int i, {bool silent = false}) async {
    if (!mounted || _svc.tabs[i].isRefreshing) return;
    if (!silent && mounted) setState(() {});
    try {
      await _svc.refresh(i);
    } catch (e) {
      debugPrint('刷新评论出错: $e');
      if (mounted && _pageIndex(i) == _index && !silent) {
        showSnackBar('加载评论失败，请检查网络');
      }
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadMore(int i) async {
    if (!mounted) return;
    await _svc.loadMore(i);
    if (!mounted) return;
    setState(() {});
  }

  void _onScroll(int i) {
    final c = _uis[i].scroll;
    if (!c.hasClients) return;

    if (_svc.canLoadMore(i) &&
        c.position.pixels >= c.position.maxScrollExtent - 400) {
      _loadMore(i);
    }

    // 仅当前页、非 Windows 上报滚动方向
    if (_pageIndex(i) != _index || Instances.isWindows) return;
    final offset = c.offset;
    final ui = _uis[i];
    if ((offset - ui.lastOffset).abs() <= 50) return;
    Get.find<AppState>().updateScrollDirection(offset > ui.lastOffset);
    ui.lastOffset = offset;
  }

  void _switch(int i, {bool fromPage = false}) {
    if (i == _index) return;
    setState(() => _index = i);
    if (!fromPage) {
      _pageController.animateToPage(
        i,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
    if (_isWatchPartyTab(i)) {
      _refreshWatchRooms(silent: true);
    } else {
      final threadIndex = _threadIndex(i);
      if (_svc.tabs[threadIndex].comments.isEmpty &&
          _svc.tabs[threadIndex].page == 0) {
        _ensureLoaded(threadIndex);
      } else {
        _refresh(threadIndex, silent: true);
      }
    }
  }

  Future<void> _sendComment() async {
    if (_isWatchPartyTab(_index)) {
      showSnackBar('一起看房间页不支持发帖');
      return;
    }
    final threadIndex = _threadIndex(_index);
    final result = await CommentInputWidget.show(context);
    if (result == null || !mounted) return;
    final state = _uis[threadIndex].commentKey.currentState;
    if (state == null) return;
    await state.sendComment(result, 0, '');
    if (!mounted) return;
    showSnackBar('评论发送成功');
    if (mounted) _refresh(threadIndex);
  }

  Future<void> _refreshWatchRooms({bool silent = false}) async {
    final task = _svc.refreshWatchRooms();
    if (!silent && mounted) setState(() {});
    try {
      await task;
    } catch (_) {
      if (mounted && _isWatchPartyTab(_index) && !silent) {
        showSnackBar('加载一起看房间失败，请检查网络');
      }
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _onLink(String text, String? url, String title) async {
    if (url == null) return;
    final match = _gvRegex.firstMatch(url) ?? _gvRegex.firstMatch(text);
    if (match == null) {
      launchUrlString(url, mode: LaunchMode.externalApplication);
      return;
    }
    try {
      final data = await _svc.resolveGvLink(match.group(1)!);
      if (data != null && mounted) {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => PlayerPage(data: data)));
      } else {
        showSnackBar('无法获取视频信息');
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
              itemCount: _pageCount,
              onPageChanged: (i) => _switch(i, fromPage: true),
              itemBuilder: (_, i) => _isWatchPartyTab(i)
                  ? _watchPartyPage(theme)
                  : _page(_threadIndex(i), theme),
            ),
          ),
        ],
      ),
    );
  }

  Widget _page(int i, ThemeData theme) {
    final tab = _svc.tabs[i];
    final ui = _uis[i];
    final showSkeleton =
        tab.page == 0 && tab.isRefreshing && tab.comments.isEmpty;

    return RefreshIndicator(
      onRefresh: () => _refresh(i),
      color: theme.colorScheme.primary,
      backgroundColor: theme.colorScheme.surface,
      displacement: 24,
      strokeWidth: 2.5,
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollInfo) {
          if (scrollInfo.metrics.pixels >=
              scrollInfo.metrics.maxScrollExtent - 400) {
            if (_svc.canLoadMore(i)) {
              _loadMore(i);
            }
          }
          return false;
        },
        child: CustomScrollView(
          controller: ui.scroll,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
              sliver: CommentList(
                pid: tab.pid,
                comments: showSkeleton ? null : tab.comments,
                key: ui.commentKey,
                autoLoad: false,
                asSliver: true,
                onTapLink: _onLink,
              ),
            ),
            if (tab.isLoadingMore)
              SliverToBoxAdapter(child: _loadingMore(theme)),
            if (!tab.hasMore && tab.comments.isNotEmpty)
              const SliverToBoxAdapter(child: _EndIndicator()),
            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),
      ),
    );
  }

  Widget _watchPartyPage(ThemeData theme) {
    final rooms = _svc.watchRooms;
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
          if (_svc.watchRoomsRefreshing && rooms.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (rooms.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _watchPartyEmptyState(theme),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 90),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final roomIndex = index ~/ 2;
                  if (index.isOdd) return const SizedBox(height: 12);
                  return _watchPartyCard(rooms[roomIndex], theme);
                }, childCount: rooms.length * 2 - 1),
              ),
            ),
        ],
      ),
    );
  }

  Widget _watchPartyEmptyState(ThemeData theme) {
    final hasError = _svc.watchRoomsError.isNotEmpty;
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
              hasError ? _svc.watchRoomsError : '暂时没有正在进行的房间',
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

  Widget _watchPartyCard(WatchPartyInvite room, ThemeData theme) {
    final hasTitle = room.title.trim().isNotEmpty;
    final title = hasTitle ? room.title.trim() : 'Syncplay 房间';
    final media = hasTitle
        ? 'EP${room.episodeIndex + 1}'
        : '房间 ${room.syncplayRoom}';
    final joining = _joiningRoomCode == room.inviteCode;

    return Material(
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: joining ? null : () => _joinWatchParty(room),
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
    if (_joiningRoomCode.isNotEmpty) return;
    setState(() => _joiningRoomCode = room.inviteCode);
    try {
      await WatchPartyLinkService.joinInvite(room.inviteCode);
    } finally {
      if (mounted) setState(() => _joiningRoomCode = '');
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
            for (var i = 0; i < _pageCount; i++) _tabChip(i, theme, isDark),
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
          child: Text(
            _isWatchPartyTab(i) ? '#一起看' : _svc.tabs[_threadIndex(i)].name,
          ),
        ),
      ),
    );
  }

  Widget _refreshBtn(ThemeData theme, bool isDark, Color chipBg) {
    final iconColor = isDark
        ? Colors.white60
        : theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.5);

    final refreshing = _isWatchPartyTab(_index)
        ? _svc.watchRoomsRefreshing
        : _svc.tabs[_threadIndex(_index)].isRefreshing;

    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        if (_isWatchPartyTab(_index)) {
          _refreshWatchRooms();
        } else {
          _refresh(_threadIndex(_index));
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
