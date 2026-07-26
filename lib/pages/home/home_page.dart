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
      if (mounted) _refresh(force: false);
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
  Future<void> _refresh({bool force = true}) async {
    await Future.wait([
      _svc.loadFeed(force: force),
      if (!Instances.isTV) _svc.loadRank(force: force),
      if (!Instances.isTV) _svc.loadSwipers(force: force),
      if (Instances.isWindows) _svc.loadSchedule(force: force),
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
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      body: RefreshWrapper(
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
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reduceVisualEffects = context.reduceMotion;
    final content = ClipRRect(
      borderRadius: BorderRadius.circular(100),
      child: BackdropFilter(
        filter: reduceVisualEffects
            ? ImageFilter.blur(sigmaX: 0, sigmaY: 0)
            : ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF1B1B1F).withValues(alpha: reduceVisualEffects ? 0.96 : 0.84)
                : Colors.white.withValues(alpha: reduceVisualEffects ? 0.98 : 0.88),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.18)
                  : Colors.black.withValues(alpha: 0.08),
              width: 1.2,
            ),
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
        ),
      ),
    );

    return SliverAppBar(
      pinned: true,
      floating: true,
      snap: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      toolbarHeight: 64,
      centerTitle: true,
      title: content,
    );
  }

  Widget _buildNavTabBar() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      width: ScreenUtils(context).isTablet ? 240.0 : 160.0,
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.14)
            : Colors.black.withValues(alpha: 0.07),
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
        unselectedLabelColor: isDark
            ? Colors.white.withValues(alpha: 0.85)
            : Colors.black.withValues(alpha: 0.75),
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        labelStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.2,
        ),
        unselectedLabelStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
        indicator: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              theme.colorScheme.primary,
              theme.colorScheme.primary.withValues(alpha: 0.85),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(100),
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
              duration: context.reduceMotion
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
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.black.withValues(alpha: 0.07),
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
        final radius = BorderRadius.circular(isTablet ? 20 : 24);

        return SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: 8,
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: AspectRatio(
                aspectRatio: isTablet ? 24 / 9 : 16 / 9.5,
                child: SwiperBanner(swiperData: swipers),
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
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
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
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
        child: ValueListenableBuilder<String>(
          valueListenable: _svc.tag,
          builder: (context, selected, _) {
            final theme = Theme.of(context);
            return Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    key: _tagSectionKey,
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final text in _svc.displayTags)
                          Padding(
                            padding: const EdgeInsets.only(right: 14),
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
                                  fontSize: text == selected ? 17 : 15,
                                  fontWeight: text == selected
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                  color: text == selected
                                      ? theme.colorScheme.primary
                                      : theme.textTheme.bodyMedium?.color
                                            ?.withValues(alpha: 0.5),
                                  letterSpacing: 0.4,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Text(text),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () async {
                    HapticFeedback.lightImpact();
                    final next = await TagFilterSheet.show(context, selected);
                    if (next != null) await _svc.selectTag(next);
                  },
                  icon: const Icon(Icons.keyboard_arrow_down),
                  color: theme.colorScheme.primary,
                  iconSize: 22,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  splashRadius: 20,
                ),
              ],
            );
          },
        ),
      ),
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
        // 卡片高度 = 2:3 封面 + 间距 + 单行标题
        final itemWidth = (width - 40 - (columns - 1) * 12) / columns;
        final titleHeight = MediaQuery.textScalerOf(context).scale(13) * 1.2;

        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              mainAxisExtent: itemWidth * 1.5 + 8 + titleHeight,
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
