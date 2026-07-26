import 'package:baka/api/collection.dart';
import 'package:baka/api/play_history.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/services/play_history_sync_service.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/shimmer.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

class LibraryPage extends StatefulWidget {
  final int initialIndex;

  const LibraryPage({super.key, this.initialIndex = 0});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<Map<String, dynamic>> _historyList = [];
  List<AnimeCollection> _collectionList = [];
  CollectionStats? _stats;
  late int _selectedIndex = widget.initialIndex;
  bool _isCollectionLoading = false;
  int? _collectionStatusFilter;
  int _collectionPage = 1;
  bool _hasMoreCollection = true;
  final ScrollController _scrollController = ScrollController();

  bool get _isLoggedIn =>
      Instances.sp.getString('usertoken')?.isNotEmpty == true;

  @override
  void initState() {
    super.initState();
    _historyList = PlayHistorySyncService.getHistoryList();
    _scrollController.addListener(_onScroll);
    if (_isLoggedIn) _loadInitialData();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_selectedIndex != 1 || !_hasMoreCollection || _isCollectionLoading) {
      return;
    }
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _fetchCollectionData(reset: false);
    }
  }

  Future<void> _loadInitialData() async {
    setState(() => _isCollectionLoading = true);
    try {
      await Future.wait([
        CollectionApi.getStats().then((res) {
          if (res != null) _stats = res;
        }),
        CollectionApi.getList(
          page: 1,
          pageSize: 20,
          status: _collectionStatusFilter,
        ).then((res) {
          if (res != null) {
            _collectionList = res.list;
            _hasMoreCollection = _collectionList.length < res.total;
          }
        }),
        PlayHistorySyncService.syncRemoteToLocal().then((_) {
          _historyList = PlayHistorySyncService.getHistoryList();
        }),
      ]);
    } finally {
      if (mounted) setState(() => _isCollectionLoading = false);
    }
  }

  Future<void> _fetchStats() async {
    final newStats = await CollectionApi.getStats();
    if (newStats != null && mounted) setState(() => _stats = newStats);
  }

  Future<void> _fetchCollectionData({bool reset = true}) async {
    if (_isCollectionLoading) return;
    setState(() => _isCollectionLoading = true);
    try {
      final page = reset ? 1 : _collectionPage + 1;
      final response = await CollectionApi.getList(
        page: page,
        pageSize: 20,
        status: _collectionStatusFilter,
      );
      if (response != null && mounted) {
        _collectionPage = page;
        if (reset) {
          _collectionList = response.list;
        } else {
          _collectionList.addAll(response.list);
        }
        _hasMoreCollection = _collectionList.length < response.total;
      }
    } catch (e) {
      debugPrint('获取收藏列表失败: $e');
    } finally {
      if (mounted) setState(() => _isCollectionLoading = false);
    }
  }

  void _onStatusFilterChanged(int? status) {
    if (_collectionStatusFilter == status) return;
    HapticFeedback.selectionClick();
    _collectionStatusFilter = status;
    _fetchCollectionData();
  }

  Future<void> _clearHistory() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: '清空历史',
      content: '确定要清空所有历史记录吗？此操作无法撤销。',
      confirmText: '确定',
      cancelText: '取消',
      isDestructive: true,
    );
    if (confirmed == DialogAction.confirm) {
      await PlayHistorySyncService.clearHistory();
      if (_isLoggedIn) {
        PlayHistoryApi.clearPlayHistory().catchError((_) => false);
      }
      if (mounted) setState(() => _historyList.clear());
    }
  }

  int? _getFilterCount(int? statusValue) {
    if (_stats == null) return null;
    if (statusValue == null) return _stats!.total > 0 ? _stats!.total : null;
    final status = CollectionStatus.fromValue(statusValue);
    if (status == null) return null;
    final c = _stats!.countForStatus(status);
    return c > 0 ? c : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverAppBar(
            pinned: true,
            title: const Text(
              '我的片库',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            actions: [
              if (_selectedIndex == 0 && _historyList.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: _clearHistory,
                  tooltip: '清空历史',
                ),
              if (_selectedIndex == 1)
                IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: () {
                    _fetchCollectionData();
                    _fetchStats();
                  },
                  tooltip: '刷新',
                ),
              const SizedBox(width: 8),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: _buildSegmentedControl(),
            ),
          ),
          if (_selectedIndex == 1)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _buildStatusFilterChips(),
              ),
            ),
          _selectedIndex == 0
              ? _buildHistoryContent()
              : _buildCollectionContent(),
          if (_selectedIndex == 1 &&
              _isCollectionLoading &&
              _collectionList.isNotEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: ShimmerTextLine(width: 100, height: 12)),
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
        ],
      ),
    );
  }

  Widget _buildSegmentedControl() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildSegmentTab(
              label: '历史记录',
              isSelected: _selectedIndex == 0,
              onTap: () {
                if (_selectedIndex == 0) return;
                HapticFeedback.selectionClick();
                setState(() => _selectedIndex = 0);
              },
            ),
          ),
          Expanded(
            child: _buildSegmentTab(
              label: '我的追番',
              isSelected: _selectedIndex == 1,
              onTap: () {
                if (_selectedIndex == 1) return;
                HapticFeedback.selectionClick();
                setState(() => _selectedIndex = 1);
                if (_collectionList.isEmpty && _isLoggedIn) {
                  _fetchCollectionData();
                  if (_stats == null) _fetchStats();
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentTab({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.primary)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            color: isSelected
                ? (isDark
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onPrimary)
                : (isDark ? Colors.white60 : Colors.black54),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusFilterChips() {
    const filters = <(int?, String)>[
      (null, '全部'),
      (3, '在看'),
      (1, '想看'),
      (2, '看过'),
      (4, '搁置'),
      (5, '抛弃'),
    ];
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (statusValue, label) = filters[index];
          final count = _getFilterCount(statusValue);
          final isSelected = _collectionStatusFilter == statusValue;

          return ChoiceChip(
            label: Text(
              count != null ? '$label $count' : label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected
                    ? (isDark
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onPrimary)
                    : (isDark ? Colors.white70 : Colors.black87),
              ),
            ),
            selected: isSelected,
            onSelected: (_) => _onStatusFilterChanged(statusValue),
            showCheckmark: false,
            selectedColor: isDark
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.primary,
            backgroundColor: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.04),
            side: BorderSide.none,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(17),
            ),
          );
        },
      ),
    );
  }

  Widget _buildGrid(
    int itemCount,
    Widget Function(BuildContext, int) itemBuilder,
  ) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverMasonryGrid.count(
        crossAxisCount: _getGridCrossAxisCount(context),
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childCount: itemCount,
        itemBuilder: itemBuilder,
      ),
    );
  }

  Widget _buildHistoryContent() {
    if (_historyList.isEmpty) {
      return _buildEmptyState(Icons.history_toggle_off, '暂无历史记录');
    }
    return _buildGrid(_historyList.length, (context, index) {
      final item = _historyList[index];
      return _HistoryCard(data: item, onTap: () => _handleHistoryCardTap(item));
    });
  }

  Widget _buildCollectionContent() {
    if (_isCollectionLoading && _collectionList.isEmpty) {
      return _buildGrid(
        _getGridCrossAxisCount(context) * 3,
        (context, index) => const _LibraryCardSkeleton(),
      );
    }

    if (_collectionList.isEmpty) {
      final filterLabel = _collectionStatusFilter != null
          ? CollectionStatus.fromValue(_collectionStatusFilter)?.label ?? ''
          : '';
      return _buildEmptyState(
        Icons.bookmark_border_rounded,
        filterLabel.isNotEmpty ? '暂无「$filterLabel」的番剧' : '暂无追番记录',
      );
    }

    return _buildGrid(_collectionList.length, (context, index) {
      final item = _collectionList[index];
      return _CollectionCard(
        collection: item,
        onTap: () => _handleCollectionCardTap(item),
      );
    });
  }

  Widget _buildEmptyState(IconData icon, String text) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: color.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text(text, style: TextStyle(fontSize: 15, color: color)),
          ],
        ),
      ),
    );
  }

  int _getGridCrossAxisCount(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 1200) return 6;
    if (width >= 900) return 5;
    if (width >= 600) return 4;
    return 3;
  }

  void _handleHistoryCardTap(Map data) {
    _navigateToPlayer(Map<String, dynamic>.from(data), posIndex: data['index']);
  }

  void _handleCollectionCardTap(AnimeCollection collection) {
    final hasPostId = collection.postId != null && collection.postId! > 0;
    final id = hasPostId ? collection.postId : collection.bgmId;
    if (id == null || id <= 0) return;

    final title = collection.displayTitle;
    _navigateToPlayer({
      'id': id,
      'title': title.isEmpty && !hasPostId ? '加载中...' : title,
      'content': collection.displayCover,
      'image': collection.displayCover,
      if (collection.bgmId != null) 'bgmId': collection.bgmId,
      if (!hasPostId) 'source': 'bgm',
    });
  }

  void _navigateToPlayer(Map<String, dynamic> data, {int? posIndex}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerPage(data: data, posIndex: posIndex),
      ),
    ).then((_) {
      if (!mounted) return;
      setState(() => _historyList = PlayHistorySyncService.getHistoryList());
    });
  }
}

class _LibraryCardSkeleton extends StatelessWidget {
  const _LibraryCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ShimmerBox(borderRadius: BorderRadius.all(Radius.circular(12))),
              Positioned(
                top: 8,
                left: 8,
                child: ShimmerBox(
                  width: 44,
                  height: 20,
                  borderRadius: BorderRadius.all(Radius.circular(6)),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: ShimmerBox(
                  width: 38,
                  height: 20,
                  borderRadius: BorderRadius.all(Radius.circular(6)),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 8),
        ShimmerTextLine(height: 13, widthFactor: 0.88),
      ],
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final Map data;
  final VoidCallback onTap;

  const _HistoryCard({required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final progressInfo = resolveProgressInfo(data);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final episodeIndex = int.tryParse(data['index']?.toString() ?? '');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            PostCard(data, onTap: onTap),
            if (episodeIndex != null)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '看到第${episodeIndex + 1}集',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              progressInfo.watchTimeText,
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 10,
              ),
            ),
            Text(
              progressInfo.positionText,
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: progressInfo.progress,
            backgroundColor:
                isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.08),
            valueColor: AlwaysStoppedAnimation<Color>(
              theme.colorScheme.primary,
            ),
            minHeight: 3,
          ),
        ),
      ],
    );
  }
}

class _CollectionCard extends StatelessWidget {
  final AnimeCollection collection;
  final VoidCallback onTap;

  const _CollectionCard({required this.collection, required this.onTap});

  static const _statusColors = {
    1: Color(0xFF34D399),
    2: Color(0xFFA78BFA),
    3: Color(0xFF60A5FA),
    4: Color(0xFFFBBF24),
    5: Color(0xFFF87171),
  };

  @override
  Widget build(BuildContext context) {
    final statusColor = _statusColors[collection.status] ?? Colors.grey;
    final statusText =
        collection.statusText ??
        CollectionStatus.fromValue(collection.status)?.label ??
        '';
    final title = collection.displayTitle;
    final hasEp = collection.epWatched != null && collection.epWatched! > 0;
    final hasTotal = collection.epTotal != null && collection.epTotal! > 0;

    final mapData = {
      'title': title.isNotEmpty ? title : '未知番剧',
      'content': collection.displayCover,
      'url': collection.displayCover,
      '_heroTag':
          'collection_${collection.postId ?? collection.bgmId ?? collection.hashCode}',
    };

    String? remainingText;
    if (hasTotal && hasEp && collection.epTotal! >= collection.epWatched!) {
      final remain = collection.epTotal! - collection.epWatched!;
      remainingText = remain > 0 ? '剩 $remain 集' : '已看完';
    } else if (hasTotal) {
      remainingText = '全 ${collection.epTotal} 集';
    } else if (hasEp) {
      remainingText = '已看 ${collection.epWatched} 集';
    }

    return Stack(
      children: [
        PostCard(mapData, onTap: onTap),
        Positioned(
          top: 8,
          left: 8,
          right: 8,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (statusText.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        statusText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (collection.bgmRating != null &&
                      collection.bgmRating! > 0) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.star_rounded,
                            size: 10,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            collection.bgmRating!.toStringAsFixed(1),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              if (remainingText != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    remainingText,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
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
