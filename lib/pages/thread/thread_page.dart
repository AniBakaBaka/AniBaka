import 'package:get/get.dart';
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/services/thread_service.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/comment/comment_card.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:baka/widgets/common/shimmer.dart';
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

  final ThreadService _svc = ThreadService();
  late final PageController _pageController;
  late final List<_TabUi> _uis;
  late final Worker _commentWorker;

  int _index = 0;

  @override
  bool get wantKeepAlive => true;

  ThreadTab get _tab => _svc.tabs[_index];

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
      if (mounted && i == _index && !silent) showSnackBar('加载评论失败，请检查网络');
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
    if (i != _index || Instances.isWindows) return;
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
    if (_svc.tabs[i].comments.isEmpty && _svc.tabs[i].page == 0) {
      _ensureLoaded(i);
    } else {
      _refresh(i, silent: true);
    }
  }

  Future<void> _sendComment() async {
    final result = await CommentInputWidget.show(context);
    if (result == null || !mounted) return;
    final state = _uis[_index].commentKey.currentState;
    if (state == null) return;
    await state.sendComment(result, 0, '');
    if (!mounted) return;
    showSnackBar('评论发送成功');
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) _refresh(_index);
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

  // ─── Build ───

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
              itemCount: _svc.tabs.length,
              onPageChanged: (i) => _switch(i, fromPage: true),
              itemBuilder: (_, i) => _page(i, theme),
            ),
          ),
        ],
      ),
    );
  }

  Widget _page(int i, ThemeData theme) {
    final tab = _svc.tabs[i];
    final ui = _uis[i];
    final showSkeleton = tab.page == 0 && tab.isRefreshing && tab.comments.isEmpty;

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
            for (var i = 0; i < _svc.tabs.length; i++)
              _tabChip(i, theme, isDark),
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
          child: Text(_svc.tabs[i].name),
        ),
      ),
    );
  }

  Widget _refreshBtn(ThemeData theme, bool isDark, Color chipBg) {
    final iconColor = isDark
        ? Colors.white60
        : theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.5);

    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        _refresh(_index);
      },
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: chipBg, shape: BoxShape.circle),
        child: _tab.isRefreshing
            ? ShimmerCircle(
                size: 18,
                baseColor: theme.colorScheme.primary.withValues(alpha: 0.18),
                highlightColor: theme.colorScheme.primary.withValues(
                  alpha: 0.5,
                ),
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
