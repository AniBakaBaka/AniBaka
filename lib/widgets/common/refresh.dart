import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

typedef LoadMoreCallback = Future<bool> Function();

class RefreshWrapper extends StatefulWidget {
  final Widget child;
  final RefreshCallback onRefresh;
  final LoadMoreCallback onLoadMore;
  final Listenable? loadMoreResetListenable;
  final bool showInitialIndicator;

  const RefreshWrapper({
    required this.child,
    required this.onRefresh,
    required this.onLoadMore,
    this.loadMoreResetListenable,
    this.showInitialIndicator = true,
    super.key,
  });

  @override
  State<RefreshWrapper> createState() => _RefreshWrapperState();
}

class _RefreshWrapperState extends State<RefreshWrapper> {
  final _refreshIndicatorKey = GlobalKey<RefreshIndicatorState>();
  Future<bool>? _loadMoreTask;
  bool _isRefreshing = false;
  bool _hasMore = true;
  int _loadMoreGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.loadMoreResetListenable?.addListener(_resetLoadMore);
    if (!widget.showInitialIndicator) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshIndicatorKey.currentState?.show();
      }
    });
  }

  @override
  void didUpdateWidget(covariant RefreshWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loadMoreResetListenable == widget.loadMoreResetListenable) {
      return;
    }
    oldWidget.loadMoreResetListenable?.removeListener(_resetLoadMore);
    widget.loadMoreResetListenable?.addListener(_resetLoadMore);
    _resetLoadMore();
  }

  @override
  void dispose() {
    widget.loadMoreResetListenable?.removeListener(_resetLoadMore);
    super.dispose();
  }

  void _resetLoadMore() {
    _hasMore = true;
    _loadMoreGeneration++;
  }

  Future<void> _onLoadMore() async {
    if (_isRefreshing || !_hasMore || _loadMoreTask != null) return;
    final generation = _loadMoreGeneration;
    final task = widget.onLoadMore();
    _loadMoreTask = task;
    try {
      final hasMore = await task;
      if (generation == _loadMoreGeneration) _hasMore = hasMore;
    } catch (e) {
      debugPrint('load more error: $e');
    } finally {
      if (identical(_loadMoreTask, task)) _loadMoreTask = null;
    }
  }

  Future<void> _onRefresh() async {
    if (_isRefreshing || _loadMoreTask != null) return;
    _isRefreshing = true;
    _resetLoadMore();

    try {
      await widget.onRefresh();
    } finally {
      _isRefreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      key: _refreshIndicatorKey,
      onRefresh: _onRefresh,
      child: NotificationListener<ScrollNotification>(
        child: widget.child,
        onNotification: (ScrollNotification scrollInfo) {
          if (scrollInfo.depth != 0 ||
              scrollInfo.metrics.axis != Axis.vertical ||
              (scrollInfo is! ScrollUpdateNotification &&
                  scrollInfo is! OverscrollNotification)) {
            return false;
          }

          final isForwardOverscroll =
              scrollInfo is OverscrollNotification && scrollInfo.overscroll > 0;
          if (scrollInfo.metrics.extentAfter <= 200 &&
              (scrollInfo.metrics.pixels > 0 || isForwardOverscroll)) {
            _onLoadMore();
          }
          return false;
        },
      ),
    );
  }
}
