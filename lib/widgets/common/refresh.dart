import 'package:baka/core/app_logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

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
  bool _isLoading = false;
  bool _hasMore = true;
  int _loadMoreGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.loadMoreResetListenable?.addListener(_resetLoadMore);
    if (!widget.showInitialIndicator) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshIndicatorKey.currentState?.show();
      }
    });
  }

  @override
  void didUpdateWidget(covariant RefreshWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(
      oldWidget.loadMoreResetListenable,
      widget.loadMoreResetListenable,
    )) {
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
    if (!mounted || _isLoading || !_hasMore) return;
    _isLoading = true;
    final generation = _loadMoreGeneration;
    try {
      final hasMore = await widget.onLoadMore();
      if (mounted && generation == _loadMoreGeneration) _hasMore = hasMore;
    } catch (e) {
      Log.w('Refresh', 'load more error: $e');
    } finally {
      _isLoading = false;
    }
  }

  Future<void> _onRefresh() async {
    if (!mounted || _isLoading) return;
    _isLoading = true;
    _resetLoadMore();

    try {
      await widget.onRefresh();
    } finally {
      _isLoading = false;
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
              scrollInfo.metrics.axis != Axis.vertical) {
            return false;
          }

          final isScrollingTowardEnd =
              (scrollInfo is ScrollUpdateNotification &&
                  (scrollInfo.scrollDelta ?? 0) > 0) ||
              (scrollInfo is OverscrollNotification &&
                  scrollInfo.overscroll > 0) ||
              (scrollInfo is UserScrollNotification &&
                  scrollInfo.direction == ScrollDirection.reverse);
          if (isScrollingTowardEnd && scrollInfo.metrics.extentAfter <= 200) {
            _onLoadMore();
          }
          return false;
        },
      ),
    );
  }
}
