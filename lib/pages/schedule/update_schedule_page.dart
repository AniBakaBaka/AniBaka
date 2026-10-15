import 'package:baka/core/content_filter.dart';
import 'dart:async';

import 'package:baka/app/navigation.dart';
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/anime_schedule.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/pages/schedule/schedule_service.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:url_launcher/url_launcher.dart';

class UpdateSchedulePage extends StatefulWidget {
  const UpdateSchedulePage({super.key, this.service, this.now});
  final ScheduleService? service;
  final DateTime Function()? now;

  @override
  State<UpdateSchedulePage> createState() => _UpdateSchedulePageState();
}

class _UpdateSchedulePageState extends State<UpdateSchedulePage>
    with WidgetsBindingObserver {
  static const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  final _scrollController = ScrollController();
  final _details = <String, ValueNotifier<ScheduleDetails?>>{};
  final _groupSizes = <String, int>{};
  late final ScheduleService _service =
      widget.service ?? ScheduleService(now: _now);
  late DateTime _today = scheduleToday(_now());
  late DateTime _monday = _today.subtract(Duration(days: _today.weekday - 1));
  late int _selectedDay = _today.weekday - 1;
  ScheduleWeek? _week;
  bool _loading = true;
  String? _error;
  int _loadGeneration = 0;
  int _detailGeneration = 0;
  double _lastScrollOffset = 0;
  AppState? _appState;

  DateTime _now() => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!Instances.isDesktopPlatform &&
        !Instances.isTV &&
        Get.isRegistered<AppState>()) {
      _appState = Get.find<AppState>();
      _scrollController.addListener(_onScroll);
    }
    unawaited(_loadSchedule());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loadGeneration++;
    _detailGeneration++;
    _clearDetails();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && scheduleToday(_now()) != _today) {
      unawaited(_loadSchedule(force: true));
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.offset;
    if ((offset - _lastScrollOffset).abs() > 50) {
      _appState?.updateScrollDirection(offset > _lastScrollOffset);
      _lastScrollOffset = offset;
    }
  }

  Future<void> _loadSchedule({bool force = false}) async {
    final generation = ++_loadGeneration;
    _detailGeneration++;
    final today = scheduleToday(_now());
    final monday = today.subtract(Duration(days: today.weekday - 1));
    setState(() {
      _loading = true;
      _error = null;
      if (monday != _monday) {
        _week = null;
        _clearDetails();
        _selectedDay = today.weekday - 1;
      }
      _today = today;
      _monday = monday;
    });
    try {
      final result = await _service.loadWeek(monday, force: force);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        // A temporary endpoint outage must not erase previously known clock times.
        if (result.timingUnavailable &&
            _week != null &&
            !_week!.timingUnavailable) {
          _error = '暂时无法刷新，正在显示上次排期';
        } else {
          _week = result;
          _indexGroups(result);
        }
        if (force) _clearDetails();
        _loading = false;
      });
      unawaited(_loadDayDetails());
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        if (force) _clearDetails();
        _loading = false;
        _error = _week == null ? '暂时无法获取更新时间表' : '暂时无法刷新，正在显示上次排期';
      });
      if (_week != null) unawaited(_loadDayDetails());
    }
  }

  Future<void> _loadDayDetails() async {
    final generation = ++_detailGeneration;
    final entries = (_week?.days[_selectedDay] ?? const <ScheduleEntry>[])
        .where((entry) => contentFilter.allows(entry.post))
        .toList(growable: false);
    var next = 0;
    // Bound requests when switching days; only the selected day gets enrichment.
    Future<void> worker() async {
      while (mounted &&
          generation == _detailGeneration &&
          next < entries.length) {
        final entry = entries[next++];
        final notifier = _detailFor(entry);
        if (notifier.value != null) continue;
        ScheduleDetails details;
        try {
          details = await _service.loadDetails(entry);
        } catch (_) {
          details = const ScheduleDetails(episodeLabel: '章节加载失败，下拉重试');
        }
        if (!mounted || generation != _detailGeneration) return;
        notifier.value = details;
      }
    }

    await Future.wait(
      List.generate(entries.length.clamp(0, 4), (_) => worker()),
    );
  }

  ValueNotifier<ScheduleDetails?> _detailFor(ScheduleEntry entry) =>
      _details.putIfAbsent(entry.key, () => ValueNotifier(null));

  void _clearDetails() {
    for (final details in _details.values) {
      details.dispose();
    }
    _details.clear();
  }

  void _indexGroups(ScheduleWeek week) {
    _groupSizes.clear();
    for (final day in week.days) {
      final entries = day
          .where((entry) => contentFilter.allows(entry.post))
          .toList(growable: false);
      for (var start = 0; start < entries.length;) {
        var end = start + 1;
        while (end < entries.length &&
            entries[end].time == entries[start].time) {
          end++;
        }
        _groupSizes[entries[start].key] = end - start;
        start = end;
      }
    }
  }

  void _selectDay(int day) {
    if (_selectedDay == day) return;
    setState(() => _selectedDay = day);
    _lastScrollOffset = 0;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    _appState?.updateScrollDirection(false);
    unawaited(_loadDayDetails());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: contentFilter,
    builder: (context, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final entries = (_week?.days[_selectedDay] ?? const <ScheduleEntry>[])
        .where((entry) => contentFilter.allows(entry.post))
        .toList(growable: false);
    if (_week != null) _indexGroups(_week!);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 48,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '常规放送 · UTC+8',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '更新时间表',
              style: theme.textTheme.titleSmall?.copyWith(fontSize: 12),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '排期与数据来源',
            onPressed: _showSource,
            icon: const Icon(Icons.info_outline, size: 20),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              children: [
                _buildWeekSelector(theme),
                if (_notice != null) _buildNotice(theme, _notice!),
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                          _selectDay((_selectedDay + 6) % 7),
                      const SingleActivator(
                        LogicalKeyboardKey.arrowRight,
                      ): () =>
                          _selectDay((_selectedDay + 1) % 7),
                    },
                    child: Focus(
                      autofocus: true,
                      child: RefreshWrapper(
                        onRefresh: () => _loadSchedule(force: true),
                        onLoadMore: () async => false,
                        showInitialIndicator: false,
                        child: GestureDetector(
                          onHorizontalDragEnd: (details) {
                            final velocity = details.primaryVelocity ?? 0;
                            if (velocity.abs() > 300) {
                              _selectDay(
                                (_selectedDay + (velocity < 0 ? 1 : 6)) % 7,
                              );
                            }
                          },
                          child: CustomScrollView(
                            controller: _scrollController,
                            scrollCacheExtent: const ScrollCacheExtent.pixels(
                              500,
                            ),
                            physics: const AlwaysScrollableScrollPhysics(
                              parent: BouncingScrollPhysics(),
                            ),
                            slivers: [
                              if (_week == null || entries.isEmpty)
                                SliverFillRemaining(
                                  hasScrollBody: false,
                                  child: _empty(theme),
                                )
                              else ...[
                                SliverPadding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    12,
                                    12,
                                    0,
                                  ),
                                  sliver: SliverList.builder(
                                    itemCount: entries.length,
                                    itemBuilder: (context, index) =>
                                        _buildTimelineEntry(
                                          entries[index],
                                          _groupSizes[entries[index].key] ?? 0,
                                          index == entries.length - 1 ||
                                              entries[index + 1].time !=
                                                  entries[index].time,
                                          theme,
                                        ),
                                  ),
                                ),
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      16,
                                      10,
                                      16,
                                      bottomInset + 24,
                                    ),
                                    child: Text(
                                      '排期数据：bangumi-data · 放送时间不代表片源已更新',
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: colors.onSurfaceVariant,
                                            fontSize: 11,
                                          ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
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
  }

  String? get _notice =>
      _error ??
      (_week?.timingUnavailable == true
          ? '具体时间暂不可用，先显示每日番剧'
          : _week?.stale == true
          ? '排期数据较旧，请以官方公告为准'
          : _week?.calendarUnavailable == true
          ? '部分番剧信息暂未加载'
          : null);

  Widget _buildNotice(ThemeData theme, String notice) => Padding(
    padding: const EdgeInsets.only(left: 16, right: 6),
    child: Row(
      children: [
        Icon(
          Icons.info_outline,
          size: 15,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(child: Text(notice, style: theme.textTheme.bodySmall)),
        TextButton(
          onPressed: _loading ? null : () => _loadSchedule(force: true),
          child: const Text('重试'),
        ),
      ],
    ),
  );

  Widget _buildWeekSelector(ThemeData theme) {
    final colors = theme.colorScheme;
    final sunday = _monday.add(const Duration(days: 6));
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
    final range = Text(
      '${_monday.month}.${_monday.day} — ${sunday.month}.${sunday.day}',
      style: theme.textTheme.bodySmall?.copyWith(
        color: colors.onSurfaceVariant,
        fontSize: 10,
        height: 1.1,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
      child: Column(
        children: [
          Stack(
            children: [
              Row(
                children: List.generate(7, (day) {
                  final date = _monday.add(Duration(days: day));
                  final selected = day == _selectedDay;
                  final color = selected
                      ? colors.primary
                      : colors.onSurfaceVariant;
                  return Expanded(
                    child: Semantics(
                      selected: selected,
                      label: '${date.month}月${date.day}日 ${_weekdays[day]}',
                      child: InkWell(
                        key: ValueKey('schedule-day-$day'),
                        onTap: () => _selectDay(day),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: EdgeInsets.zero,
                          child: Column(
                            children: [
                              Text(
                                _weekdays[day],
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: color,
                                  fontSize: 11,
                                  height: 1.1,
                                ),
                              ),
                              Text(
                                '${date.day}',
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: color,
                                  fontSize: 20,
                                  height: 1.2,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Container(
                                width: 28,
                                height: 2,
                                color: selected ? color : Colors.transparent,
                              ),
                              Text(
                                date == _today ? '今天' : ' ',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: color,
                                  fontSize: 10,
                                  height: 1.1,
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
              if (!largeText)
                Positioned(
                  right: _today.weekday <= 4 ? 8 : null,
                  left: _today.weekday > 4 ? 8 : null,
                  bottom: 0,
                  child: IgnorePointer(child: range),
                ),
            ],
          ),
          if (largeText)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: range,
              ),
            ),
        ],
      ),
    );
  }

  Widget _empty(ThemeData theme) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_loading && _week == null) ...[
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('正在加载排期…'),
          ] else ...[
            Icon(
              _error != null && _week == null
                  ? Icons.cloud_off_outlined
                  : Icons.event_available_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              _error != null && _week == null ? _error! : '这一天暂无放送排期',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text('下拉刷新，或切换其他日期', style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    ),
  );

  Widget _buildTimelineEntry(
    ScheduleEntry entry,
    int groupSize,
    bool lastInGroup,
    ThemeData theme,
  ) {
    final color = theme.colorScheme.primary;
    final time = entry.time;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
    final narrow = MediaQuery.sizeOf(context).width < 360;
    final gutter = narrow || largeText ? 72.0 : 80.0;
    return Stack(
      key: ValueKey('schedule-timeline-${entry.key}'),
      children: [
        Positioned(
          left: gutter,
          top: 0,
          bottom: 0,
          child: SizedBox(
            width: 1,
            child: ColoredBox(color: color.withValues(alpha: .22)),
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: gutter,
              child: groupSize == 0
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(top: 5, right: 10),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          time ?? '时间待定',
                          key: ValueKey('schedule-time-${time ?? 'unknown'}'),
                          style: theme.textTheme.headlineMedium?.copyWith(
                            color: color,
                            fontSize: time == null ? 18 : 28,
                            fontWeight: FontWeight.w800,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (time != null && groupSize > 1)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8, top: 2),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: .09),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            child: Text(
                              '同一时刻 · $groupSize部',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: color,
                              ),
                            ),
                          ),
                        ),
                      ),
                    _ScheduleRow(
                      key: ValueKey((entry.key, _loadGeneration)),
                      entry: entry,
                      details: _detailFor(entry),
                      service: _service,
                      compact: narrow || largeText,
                      onPlatforms: _showPlatforms,
                    ),
                    if (lastInGroup)
                      const SizedBox(height: 10)
                    else
                      Divider(
                        height: 12,
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: .5,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (groupSize > 0)
          Positioned(
            left: gutter - 4,
            top: 15,
            child: SizedBox(
              width: 9,
              height: 9,
              child: DecoratedBox(
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
          ),
        if (lastInGroup)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Divider(
              height: 1,
              color: theme.colorScheme.outlineVariant.withValues(alpha: .45),
            ),
          ),
      ],
    );
  }

  void _showSource() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('排期与数据来源', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 14),
              const Text(
                '时间以 UTC+8 显示，来自公开的常规放送排期。停播或临时调整请以官方公告为准，时间已到不代表片源已更新。',
              ),
              const SizedBox(height: 12),
              const Text(
                '集数与标题按 Bangumi 章节的播出日期匹配；时间未知的番剧按日历日期匹配。过去日期无匹配时显示“未查到当日章节”，不会按周数推算集数。平台可能存在地区限制。',
              ),
              if (_week?.checkedAt != null) ...[
                const SizedBox(height: 12),
                Text(
                  '排期最近检查：${scheduleDate(_week!.checkedAt!.toUtc().add(const Duration(hours: 8)))}',
                ),
              ],
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => _openLink(
                  Uri.parse('https://github.com/bangumi-data/bangumi-data'),
                ),
                child: const Text('bangumi-data · CC BY 4.0'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  void _showPlatforms(ScheduleEntry entry) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  entry.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final platform in entry.platforms)
                ListTile(
                  leading: const Icon(Icons.ondemand_video_outlined),
                  title: Text(platform.name),
                  subtitle: Text(
                    '${platform.time} · UTC+8${platform.regions.isEmpty ? '' : '\n地区：${platform.regions.join('、')}'}',
                  ),
                  trailing: platform.url == null
                      ? null
                      : const Icon(Icons.open_in_new, size: 18),
                  onTap: platform.url == null
                      ? null
                      : () => _openLink(platform.url!),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _openLink(Uri uri) async {
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂时无法打开链接')));
    }
  }
}

class _ScheduleRow extends StatefulWidget {
  const _ScheduleRow({
    required this.entry,
    required this.details,
    required this.service,
    required this.compact,
    required this.onPlatforms,
    super.key,
  });
  final ScheduleEntry entry;
  final ValueNotifier<ScheduleDetails?> details;
  final ScheduleService service;
  final bool compact;
  final ValueChanged<ScheduleEntry> onPlatforms;

  @override
  State<_ScheduleRow> createState() => _ScheduleRowState();
}

class _ScheduleRowState extends State<_ScheduleRow> {
  String? _coverUrl;
  int _coverGeneration = 0;

  @override
  void initState() {
    super.initState();
    _updateCover();
  }

  @override
  void didUpdateWidget(covariant _ScheduleRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.entry, oldWidget.entry) ||
        widget.service != oldWidget.service) {
      _updateCover();
    }
  }

  void _updateCover() {
    _coverGeneration++;
    _coverUrl = resolveCoverImage(widget.entry.post);
    if (_coverUrl == null) unawaited(_loadCover());
  }

  Future<void> _loadCover() async {
    final generation = _coverGeneration;
    try {
      final image = await widget.service.loadCover(widget.entry);
      if (mounted && generation == _coverGeneration && image != null) {
        setState(() => _coverUrl = image);
      }
    } catch (_) {
      // Keep the local placeholder; refreshing retries failed cover requests.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final entry = widget.entry;
    final heroTag = 'schedule/${entry.key}';
    final coverWidth = widget.compact ? 60.0 : 80.0;
    void open() {
      if (entry.bgmId == null) {
        NavigationService.toSearch(context, keyword: entry.title);
      } else {
        navigateToDetail(context, {
          ...entry.post,
          if (_coverUrl != null) 'bgmImageUrl': _coverUrl,
        }, heroTag: heroTag);
      }
    }

    return InkWell(
      key: ValueKey('schedule-entry-${entry.key}'),
      onTap: open,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hero(
              tag: heroTag,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: ColoredBox(
                  color: colors.surfaceContainerHighest,
                  child: _coverUrl == null
                      ? SizedBox(
                          width: coverWidth,
                          height: coverWidth * 1.5,
                          child: Icon(
                            Icons.image_outlined,
                            color: colors.outline,
                          ),
                        )
                      : buildNetworkImage(
                          _coverUrl!,
                          coverWidth,
                          coverWidth * 1.5,
                          fit: BoxFit.contain,
                        ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ValueListenableBuilder<ScheduleDetails?>(
                    valueListenable: widget.details,
                    builder: (context, details, child) {
                      final label = details?.episodeLabel ?? '正在加载章节…';
                      return Tooltip(
                        message: label,
                        child: Text(
                          label,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12,
                            height: 1.5,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      );
                    },
                  ),
                  if (entry.premiereOnly)
                    Text(
                      '仅首播时间',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 5),
                  if (entry.platforms.isNotEmpty)
                    InkWell(
                      onTap: () => widget.onPlatforms(entry),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.smart_display,
                              size: 14,
                              color: colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                '${entry.platforms.first.name}  ${entry.platforms.first.time}${entry.platforms.length > 1 ? ' · ${entry.platforms.length}个平台' : ''}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 11,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.help_outline,
                          size: 13,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '平台时间未确认',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
