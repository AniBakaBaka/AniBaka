import 'package:baka/services/home_service.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/refresh.dart';
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class UpdateScheduleController extends GetxController {
  final scheduleData = RxList<List>(List.generate(7, (_) => []));
  final hasLoaded = false.obs;
  final selectedDay = (DateTime.now().weekday - 1).obs;

  @override
  void onInit() {
    super.onInit();
    loadSchedule();
  }

  Future<void> loadSchedule() async {
    try {
      scheduleData.value = await HomeDataService.loadSharedXinfan();
    } catch (e) {
      debugPrint('加载更新时间表失败: $e');
    } finally {
      hasLoaded.value = true;
    }
  }

  List getDataForDay(int dayIndex) => scheduleData[dayIndex];

  void selectDay(int day) => selectedDay.value = day;

  void goToToday() => selectedDay.value = DateTime.now().weekday - 1;

  void nextDay() => selectedDay.value = (selectedDay.value + 1) % 7;

  void prevDay() => selectedDay.value = (selectedDay.value - 1 + 7) % 7;
}

class UpdateSchedulePage extends StatefulWidget {
  const UpdateSchedulePage({super.key});

  @override
  State<UpdateSchedulePage> createState() => _UpdateSchedulePageState();
}

class _UpdateSchedulePageState extends State<UpdateSchedulePage> {
  static const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  late final UpdateScheduleController _controller = Get.put(
    UpdateScheduleController(),
  );
  late final ScrollController _scrollController = ScrollController();
  AppState? _appState;
  double _lastScrollOffset = 0;

  @override
  void initState() {
    super.initState();
    if (!Instances.isWindows && !Instances.isTV) {
      _appState = Get.find<AppState>();
      _scrollController.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final currentOffset = _scrollController.offset;
    if ((currentOffset - _lastScrollOffset).abs() > 50) {
      _appState?.updateScrollDirection(currentOffset > _lastScrollOffset);
      _lastScrollOffset = currentOffset;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final theme = Theme.of(context);

    return Obx(() {
      final selectedDay = c.selectedDay.value;
      final currentDayData = c.getDataForDay(selectedDay);

      return Scaffold(
        appBar: _buildCustomAppBar(context, c),
        body: RefreshWrapper(
          onRefresh: c.loadSchedule,
          onLoadMore: () async => false,
          child: GestureDetector(
            onHorizontalDragEnd: (details) {
              final v = details.primaryVelocity ?? 0;
              if (v < -300) {
                c.nextDay();
              } else if (v > 300) {
                c.prevDay();
              }
            },
            child: CustomScrollView(
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  sliver: c.hasLoaded.value && currentDayData.isEmpty
                      ? _buildEmptyState(theme)
                      : _buildGrid(context, currentDayData),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _buildWeekSelector(BuildContext context, UpdateScheduleController c) {
    final now = DateTime.now();
    final today = now.weekday - 1;
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final selectedDay = c.selectedDay.value;

    return SizedBox(
      height: 50,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(7, (index) {
          final isSelected = selectedDay == index;
          final isToday = index == today;
          final targetDay = now.add(Duration(days: index - now.weekday + 1));
          final dateStr = '${targetDay.month}/${targetDay.day}';

          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: GestureDetector(
                onTap: () => c.selectDay(index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  height: 46,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? primaryColor.withValues(alpha: 0.15)
                        : isToday
                        ? primaryColor.withValues(alpha: 0.05)
                        : theme.cardColor.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? primaryColor
                          : isToday
                          ? primaryColor.withValues(alpha: 0.3)
                          : Colors.transparent,
                      width: isSelected ? 1.5 : 0.8,
                    ),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: primaryColor.withValues(alpha: 0.15),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _weekdays[index],
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: (isSelected || isToday)
                              ? primaryColor
                              : theme.textTheme.bodySmall?.color?.withValues(
                                  alpha: 0.7,
                                ),
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        dateStr,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: isSelected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: isSelected
                              ? primaryColor
                              : theme.textTheme.bodyMedium?.color,
                        ),
                      ),
                      if (isToday)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: SizedBox(
                            width: 2.5,
                            height: 2.5,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: primaryColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  PreferredSizeWidget _buildCustomAppBar(
    BuildContext context,
    UpdateScheduleController c,
  ) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));

    return PreferredSize(
      preferredSize: const Size.fromHeight(140),
      child: AppBar(
        flexibleSpace: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '更新时间表',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: theme.textTheme.headlineSmall?.color,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${monday.month}/${monday.day} - ${sunday.month}/${sunday.day}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: primaryColor,
                          ),
                        ),
                      ],
                    ),
                    Material(
                      color: primaryColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(18),
                      child: InkWell(
                        onTap: c.goToToday,
                        borderRadius: BorderRadius.circular(18),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.today, size: 14, color: primaryColor),
                              const SizedBox(width: 4),
                              Text(
                                '今天',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: primaryColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildWeekSelector(context, c),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return SliverToBoxAdapter(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 60),
            Icon(
              Icons.calendar_today_outlined,
              size: 64,
              color: theme.disabledColor.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '暂无更新内容',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: theme.textTheme.bodyMedium?.color?.withValues(
                  alpha: 0.6,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '这一天还没有新番更新',
              style: TextStyle(
                fontSize: 14,
                color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(BuildContext context, List data) {
    final size = MediaQuery.of(context).size;
    final isTablet = size.shortestSide >= 600;

    final crossAxisCount = isTablet
        ? (size.width > 1200
              ? 7
              : size.width > 900
              ? 5
              : 4)
        : 3;

    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: 16,
        crossAxisSpacing: isTablet ? 16 : 0,
        childAspectRatio: 0.6,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) => PostCard(data[index]),
        childCount: data.length,
      ),
    );
  }
}
