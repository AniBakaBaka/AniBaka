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

/// 每个标签页的强类型状态
class _TabState {
  final ScrollController scrollController;
  final GlobalKey<CommentListState> commentKey;
  double lastOffset = 0.0;

  _TabState()
    : scrollController = ScrollController(),
      commentKey = GlobalKey<CommentListState>();

  void dispose() {
    scrollController.dispose();
  }
}

class ThreadPage extends StatefulWidget {
  const ThreadPage({super.key});

  @override
  State<StatefulWidget> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<ThreadPage>
    with AutomaticKeepAliveClientMixin {
  late final ThreadService _svc = ThreadService();

  int _currentThread = 0;
  late PageController _pageController;
  late final List<_TabState> _tabStates;
  late final Worker _commentWorker;

  @override
  bool get wantKeepAlive => true;
  bool get isWindows => Instances.isWindows;

  static final _gvRegex = RegExp(r'gv(\d+)');

  List<List> get _threads => ThreadService.threads;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _currentThread);

    _tabStates = List.generate(_threads.length, (i) {
      final tab = _TabState();
      tab.scrollController.addListener(() => _onScroll(i, tab));
      return tab;
    });

    _loadCachedComments(_currentThread);

    final appState = Get.find<AppState>();
    _commentWorker = ever(appState.sendCommentTrigger, (_) {
      _sendComment();
    });
  }

  void _onScroll(int tabIndex, _TabState tab) {
    final controller = tab.scrollController;

    if (_svc.canLoadMore(tabIndex) &&
        controller.position.pixels >=
            controller.position.maxScrollExtent - 200) {
      _loadMoreComments(tabIndex);
    }

    // 滚动方向检测（只在当前标签页触发）
    if (tabIndex == _currentThread && !Instances.isWindows) {
      final currentOffset = controller.offset;
      if ((currentOffset - tab.lastOffset).abs() > 50) {
        Get.find<AppState>().updateScrollDirection(
          currentOffset > tab.lastOffset,
        );
        tab.lastOffset = currentOffset;
      }
    }
  }

  @override
  void dispose() {
    _commentWorker.dispose();
    _pageController.dispose();
    for (final tab in _tabStates) {
      tab.dispose();
    }
    super.dispose();
  }

  Future<void> _loadCachedComments(int tabIndex) async {
    final cacheHit = await _svc.loadCachedComments(tabIndex);
    if (cacheHit && mounted) {
      final tab = _tabStates[tabIndex];
      tab.commentKey.currentState?.setComments(_svc.caches[tabIndex]);
    } else {
      _refreshComments(tabIndex);
    }
  }

  Future<void> _refreshComments(int tabIndex) async {
    final tab = _tabStates[tabIndex];
    if (!mounted || _svc.isRefreshing[tabIndex]) return;

    try {
      final comments = await _svc.refreshComments(tabIndex);
      if (mounted) {
        tab.commentKey.currentState?.setComments(comments);
      }
    } catch (e) {
      debugPrint('刷新评论出错: $e');
      if (mounted && tabIndex == _currentThread) {
        showSnackBar('加载评论失败，请检查网络');
      }
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadMoreComments(int tabIndex) async {
    final tab = _tabStates[tabIndex];
    if (!mounted) {
      return;
    }

    try {
      final comments = await _svc.loadMoreComments(tabIndex);
      if (comments != null) {
        tab.commentKey.currentState?.setComments(comments);
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('加载更多评论出错: $e');
      if (mounted) setState(() {});
    }
  }

  void _switchThread(int index, {bool fromPageView = false}) {
    if (index == _currentThread) return;
    _currentThread = index;
    if (!fromPageView) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }

    final tab = _tabStates[index];
    final needsLoad = tab.commentKey.currentState?.needsLoad ?? true;
    if (needsLoad) {
      _loadCachedComments(index);
    }
    if (mounted) setState(() {});
  }

  Future<void> _sendComment() async {
    final result = await CommentInputWidget.show(context);
    if (result != null && mounted) {
      final state = _tabStates[_currentThread].commentKey.currentState;
      if (state != null) {
        await state.sendComment(result, 0, '');
        if (mounted) {
          showSnackBar('评论发送成功');
          await Future.delayed(const Duration(seconds: 1));
          if (mounted) _refreshComments(_currentThread);
        }
      }
    }
  }

  void _handleLinkTap(String text, String? url, String title) async {
    if (url == null) return;

    final gvMatch = _gvRegex.firstMatch(url) ?? _gvRegex.firstMatch(text);

    if (gvMatch != null) {
      try {
        final videoData = await _svc.resolveGvLink(gvMatch.group(1)!);

        if (videoData != null && mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => PlayerPage(data: videoData),
            ),
          );
        } else {
          showSnackBar('无法获取视频信息');
        }
      } catch (e) {
        showSnackBar('跳转失败: $e');
      }
    } else {
      launchUrlString(url, mode: LaunchMode.externalApplication);
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
          _buildHeader(theme, isDark),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: _threads.length,
              onPageChanged: (index) =>
                  _switchThread(index, fromPageView: true),
              itemBuilder: (context, index) {
                final pid = _threads[index][1];
                final tab = _tabStates[index];
                return RefreshIndicator(
                  onRefresh: () => _refreshComments(index),
                  color: theme.colorScheme.primary,
                  backgroundColor: theme.colorScheme.surface,
                  displacement: 24,
                  strokeWidth: 2.5,
                  child: SingleChildScrollView(
                    controller: tab.scrollController,
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 80),
                      child: Column(
                        children: [
                          CommentList(
                            pid: pid,
                            key: tab.commentKey,
                            autoLoad: false,
                            onTapLink: _handleLinkTap,
                          ),
                          if (_svc.isLoadingMore[index])
                            _buildLoadingMore(theme),
                          if (!_svc.hasMore[index] &&
                              _svc.caches[index].isNotEmpty)
                            _buildEndIndicator(theme),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, bool isDark) {
    final topPadding = MediaQuery.of(context).padding.top;
    return Container(
      padding: EdgeInsets.only(top: topPadding),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.black.withValues(alpha: 0.05),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 10, 10),
        child: Row(
          children: [
            Expanded(child: _buildTabBar(theme, isDark)),
            const SizedBox(width: 8),
            _buildRefreshButton(theme, isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar(ThemeData theme, bool isDark) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(100),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: List.generate(_threads.length, (index) {
            final isSelected = _currentThread == index;
            return GestureDetector(
              onTap: () {
                HapticFeedback.lightImpact();
                _switchThread(index);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(100),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.25,
                            ),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : [],
                ),
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 260),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    letterSpacing: 0.3,
                    color: isSelected
                        ? Colors.white
                        : (isDark
                              ? Colors.white54
                              : theme.textTheme.bodyMedium?.color?.withValues(
                                      alpha: 0.55,
                                    ) ??
                                    Colors.black54),
                  ),
                  child: Text(_threads[index][0]),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildRefreshButton(ThemeData theme, bool isDark) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        _refreshComments(_currentThread);
      },
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.035),
          shape: BoxShape.circle,
        ),
        child: _svc.isRefreshing[_currentThread]
            ? ShimmerCircle(
                size: 18,
                baseColor: theme.colorScheme.primary.withValues(alpha: 0.18),
                highlightColor: theme.colorScheme.primary.withValues(
                  alpha: 0.5,
                ),
              )
            : Icon(
                Icons.refresh_rounded,
                size: 19,
                color: isDark
                    ? Colors.white60
                    : theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.5),
              ),
      ),
    );
  }

  Widget _buildEndIndicator(ThemeData theme) {
    final mutedColor =
        theme.textTheme.bodySmall?.color?.withValues(alpha: 0.15) ??
        Colors.grey.withValues(alpha: 0.15);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(width: 28, height: 0.5, color: mutedColor),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              '到底了',
              style: TextStyle(
                color: theme.textTheme.bodySmall?.color?.withValues(
                  alpha: 0.25,
                ),
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 1,
              ),
            ),
          ),
          Container(width: 28, height: 0.5, color: mutedColor),
        ],
      ),
    );
  }

  Widget _buildLoadingMore(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: ShimmerTextLine(
          width: 96,
          height: 10,
          baseColor: theme.colorScheme.primary.withValues(alpha: 0.14),
          highlightColor: theme.colorScheme.primary.withValues(alpha: 0.36),
        ),
      ),
    );
  }
}
