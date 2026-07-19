import 'dart:ui';
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/home/miniapp_page.dart';
import 'package:baka/pages/search/search_page.dart';
import 'package:baka/services/home_service.dart';
import 'package:baka/services/version_service.dart';
import 'package:baka/utils/reg_utils.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/refresh.dart';
import 'package:baka/widgets/common/shimmer.dart';
import 'package:baka/widgets/home/rank_section.dart';
import 'package:baka/widgets/home/swiper_banner.dart';
import 'package:baka/widgets/search/tag_filter_sheet.dart';
import 'package:baka/widgets/platform/tv/tv_home_page.dart';
import 'package:baka/widgets/platform/tv/tv_my_page.dart';
import 'package:baka/widgets/platform/tv/tv_search_page.dart';
import 'package:baka/widgets/platform/windows/windows_home_page.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final HomeDataService _svc = HomeDataService();
  late final AppState _appState = Get.find<AppState>();

  final GlobalKey _rankSectionKey = GlobalKey();
  final GlobalKey _tagSectionKey = GlobalKey();

  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
  );
  late final ScrollController _scrollController = ScrollController();
  double _lastScrollOffset = 0;

  @override
  void initState() {
    super.initState();
    if (!Instances.isTV && !Instances.isWindows) {
      _scrollController.addListener(_onScroll);
    }
    // 先让各板块订阅数据源，再执行首次刷新，避免启动阶段的结果早于页面挂载。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
    VersionService.checkAndShowUpdate().catchError((_) {});
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _tabController.dispose();
    _svc.dispose();
    super.dispose();
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    if ((offset - _lastScrollOffset).abs() > 50) {
      _appState.updateScrollDirection(offset > _lastScrollOffset);
      _lastScrollOffset = offset;
    }
  }

  /// 服务会同步恢复缓存；刷新只更新真正变化的数据。
  Future<void> _refresh() async {
    await Future.wait([
      _svc.loadFeed(force: true),
      if (!Instances.isTV) _svc.loadRank(force: true),
      if (!Instances.isTV) _svc.loadSwipers(force: true),
      if (Instances.isWindows) _svc.loadSchedule(force: true),
    ]);
  }

  void _push(Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    if (Instances.isTV) {
      return TvHomePage(
        svc: _svc,
        onSearchTap: () => _push(const TvSearchPage()),
        onMyPageTap: () => _push(const TvMyPage()),
      );
    }
    if (Instances.isWindows) {
      return WindowsHomePage(svc: _svc, onRefresh: _refresh);
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reduceVisualEffects =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          if (!reduceVisualEffects)
            Positioned.fill(
              child: Stack(
                children: [
                  Positioned(
                    top: -100,
                    right: -50,
                    child: Container(
                      width: 300,
                      height: 300,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.primary.withValues(
                          alpha: isDark ? 0.15 : 0.08,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 200,
                    left: -100,
                    child: Container(
                      width: 400,
                      height: 400,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.secondary.withValues(
                          alpha: isDark ? 0.1 : 0.05,
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 80, sigmaY: 80),
                      child: const SizedBox(),
                    ),
                  ),
                ],
              ),
            ),
          RefreshWrapper(
            onLoadMore: _svc.loadMore,
            onRefresh: _refresh,
            loadMoreResetListenable: _svc.feed,
            showInitialIndicator: false,
            child: CustomScrollView(
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              slivers: [
                _buildAppBar(),
                _buildBanner(),
                _buildRankSection(),
                _buildTagRow(),
                _buildFeedGrid(),
                const SliverToBoxAdapter(child: SizedBox(height: 80)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reduceVisualEffects =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final content = Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.black.withValues(alpha: reduceVisualEffects ? 0.9 : 0.4)
            : Colors.white.withValues(alpha: reduceVisualEffects ? 0.95 : 0.5),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.black.withValues(alpha: 0.05),
          width: 1.2,
        ),
        boxShadow: reduceVisualEffects
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildNavTabBar(),
          const SizedBox(width: 12),
          _buildIconButton(
            'assets/li-font.svg',
            () => _push(
              const WebViewPage(url: 'https://www.bgm.tv', title: '里世界'),
            ),
          ),
          const SizedBox(width: 8),
          _buildIconButton(
            'assets/Search.svg',
            () => _push(const SearchPage()),
            iconSize: 22,
          ),
          const SizedBox(width: 12),
          _buildUserAvatar(),
        ],
      ),
    );

    return SliverAppBar(
      pinned: true,
      floating: true,
      snap: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      toolbarHeight: 68,
      centerTitle: true,
      title: ClipRRect(
        borderRadius: BorderRadius.circular(100),
        child: reduceVisualEffects
            ? content
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: content,
              ),
      ),
    );
  }

  Widget _buildNavTabBar() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reduceVisualEffects =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return Container(
      width: ScreenUtils(context).isTablet ? 240.0 : 160.0,
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(100),
      ),
      child: TabBar(
        controller: _tabController,
        tabAlignment: TabAlignment.fill,
        padding: EdgeInsets.zero,
        indicatorPadding: EdgeInsets.zero,
        indicatorSize: TabBarIndicatorSize.tab,
        labelPadding: EdgeInsets.zero,
        isScrollable: false,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: theme.textTheme.bodyMedium?.color?.withValues(
          alpha: 0.7,
        ),
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        labelStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.2,
        ),
        unselectedLabelStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
        indicator: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              theme.colorScheme.primary,
              theme.colorScheme.primary.withValues(alpha: 0.8),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(100),
          boxShadow: reduceVisualEffects
              ? null
              : [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        onTap: (index) {
          HapticFeedback.lightImpact();
          final target = [
            _rankSectionKey,
            _tagSectionKey,
          ][index].currentContext;
          if (target != null) {
            Scrollable.ensureVisible(
              target,
              duration: reduceVisualEffects
                  ? Duration.zero
                  : const Duration(milliseconds: 600),
              curve: Curves.easeOutQuart,
            );
          }
        },
        tabs: const [
          Tab(height: 36, child: Center(child: Text('排行'))),
          Tab(height: 36, child: Center(child: Text('分类'))),
        ],
      ),
    );
  }

  Widget _buildIconButton(
    String assetName,
    VoidCallback onTap, {
    double iconSize = 20,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      borderRadius: BorderRadius.circular(100),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.05),
          shape: BoxShape.circle,
        ),
        child: SvgPicture.asset(
          assetName,
          height: iconSize,
          width: iconSize,
          colorFilter: ColorFilter.mode(
            isDark ? Colors.white : Colors.black87,
            BlendMode.srcIn,
          ),
        ),
      ),
    );
  }

  Widget _buildUserAvatar() {
    return Obx(() {
      final avatar = _appState.userInfo.value['qq']?.toString() ?? '';
      final isLoggedIn = _appState.isLoggedIn;
      final theme = Theme.of(context);
      final reduceVisualEffects =
          MediaQuery.maybeOf(context)?.disableAnimations ?? false;

      return InkWell(
        onLongPress: isLoggedIn ? _confirmLogout : null,
        onTap: () {
          HapticFeedback.selectionClick();
          if (!isLoggedIn) Navigator.pushNamed(context, 'Baka://login');
        },
        borderRadius: BorderRadius.circular(100),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.5),
              width: 1.5,
            ),
            boxShadow: reduceVisualEffects
                ? null
                : [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          child: ClipOval(
            child: CachedNetworkImage(
              memCacheWidth: 70,
              imageUrl: getAvatar(avatar: avatar),
              width: 32,
              height: 32,
              fit: BoxFit.cover,
              placeholder: (_, _) => const ShimmerBox(
                width: 32,
                height: 32,
                borderRadius: BorderRadius.all(Radius.circular(16)),
              ),
              errorWidget: (_, _, _) => Container(color: Colors.grey[800]),
            ),
          ),
        ),
      );
    });
  }

  Future<void> _confirmLogout() async {
    HapticFeedback.mediumImpact();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确定', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) _appState.performLogout();
  }

  Widget _buildBanner() {
    return ValueListenableBuilder<List<dynamic>>(
      valueListenable: _svc.swipers,
      builder: (context, swipers, _) {
        if (swipers.isEmpty) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        final isTablet = ScreenUtils(context).isTablet;
        final horizontalPadding = isTablet
            ? MediaQuery.sizeOf(context).width * 0.15
            : 20.0;
        final radius = BorderRadius.circular(isTablet ? 24 : 28);
        final reduceVisualEffects =
            MediaQuery.maybeOf(context)?.disableAnimations ?? false;

        return SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: 12,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: reduceVisualEffects
                    ? null
                    : [
                        BoxShadow(
                          color: Theme.of(
                            context,
                          ).shadowColor.withValues(alpha: 0.15),
                          blurRadius: 30,
                          offset: const Offset(0, 16),
                          spreadRadius: -8,
                        ),
                      ],
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: AspectRatio(
                  aspectRatio: isTablet ? 24 / 9 : 16 / 9.5,
                  child: SwiperBanner(swiperData: swipers),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRankSection() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: KeyedSubtree(
          key: _rankSectionKey,
          child: ValueListenableBuilder<int>(
            valueListenable: _svc.rankIndex,
            builder: (context, index, _) =>
                ValueListenableBuilder<List<List<dynamic>>>(
                  valueListenable: _svc.ranks,
                  builder: (context, ranks, _) => RankSection(
                    items: ranks[index],
                    selectedIndex: index,
                    onTypeChanged: _svc.selectRank,
                  ),
                ),
          ),
        ),
      ),
    );
  }

  Widget _buildTagRow() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: ValueListenableBuilder<String>(
          valueListenable: _svc.tag,
          builder: (context, selected, _) {
            final theme = Theme.of(context);
            return Row(
              children: [
                Expanded(child: _buildTagCapsules(theme, selected)),
                const SizedBox(width: 12),
                _buildTagExpandButton(theme),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTagCapsules(ThemeData theme, String selected) {
    return Container(
      key: _tagSectionKey,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final tag in _svc.displayTags)
              _buildTagCapsule(theme, tag, tag == selected),
          ],
        ),
      ),
    );
  }

  Widget _buildTagCapsule(ThemeData theme, String text, bool isSelected) {
    return Padding(
      padding: const EdgeInsets.only(right: 20),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          _svc.selectTag(text);
        },
        behavior: HitTestBehavior.opaque,
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          style: TextStyle(
            fontSize: isSelected ? 18 : 16,
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
            color: isSelected
                ? theme.colorScheme.primary
                : theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.5),
            letterSpacing: 0.5,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(text),
          ),
        ),
      ),
    );
  }

  Widget _buildTagExpandButton(ThemeData theme) {
    return IconButton(
      onPressed: () async {
        HapticFeedback.lightImpact();
        final newTag = await TagFilterSheet.show(context, _svc.tag.value);
        if (newTag != null) await _svc.selectTag(newTag);
      },
      icon: const Icon(Icons.keyboard_arrow_down),
      color: theme.colorScheme.primary,
      iconSize: 24,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      splashRadius: 24,
    );
  }

  Widget _buildFeedGrid() {
    return ValueListenableBuilder<List<dynamic>>(
      valueListenable: _svc.feed,
      builder: (context, items, _) {
        final width = MediaQuery.sizeOf(context).width;
        final columns = width > 1200
            ? 7
            : width > 900
            ? 5
            : 3;
        // 卡片高度 = 2:3 封面 + 间距 + 单行标题，算出固定行高让网格惰性布局。
        final itemWidth = (width - 32 - (columns - 1) * 16) / columns;
        final titleHeight = MediaQuery.textScalerOf(context).scale(13) * 1.2;

        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              mainAxisExtent: itemWidth * 1.5 + 10 + titleHeight,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, index) {
                final item = items[index] as Map;
                return PostCard(
                  item,
                  key: ValueKey('feed_${item['bgmId'] ?? item['id'] ?? index}'),
                );
              },
              childCount: items.length,
              addAutomaticKeepAlives: false,
            ),
          ),
        );
      },
    );
  }
}
