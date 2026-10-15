import 'dart:collection';

import 'package:baka/models/anime_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _categories = <(String, List<String>)>[
  (
    '题材',
    [
      '日常',
      '搞笑',
      '恋爱',
      '热血',
      '战斗',
      '冒险',
      '奇幻',
      '科幻',
      '推理',
      '悬疑',
      '恐怖',
      '治愈',
      '运动',
      '校园',
      '机战',
      '音乐',
      '穿越',
      '异世界',
      '美食',
      '职场',
    ],
  ),
  ('类型', ['TV', 'OVA', '剧场版', 'Web', '泡面番']),
  ('改编', ['原创', '漫画改', '小说改', '轻小说改', '游戏改']),
  ('受众', ['后宫', '百合', '耽美', '乙女', '萌', '燃', '致郁', '催泪']),
];

class TagFilterSheet extends StatefulWidget {
  const TagFilterSheet({required this.filter, super.key}) : _dialog = false;

  const TagFilterSheet._dialog({required this.filter}) : _dialog = true;

  final AnimeFilter filter;
  final bool _dialog;

  static Future<AnimeFilter?> show(BuildContext context, AnimeFilter filter) {
    final size = MediaQuery.sizeOf(context);
    final colors = Theme.of(context).colorScheme;
    if (size.width >= 840 && size.height >= 560) {
      return showDialog<AnimeFilter>(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: colors.surface,
          surfaceTintColor: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(32),
          ),
          child: SizedBox(
            width: 880,
            height: size.height * 0.86,
            child: TagFilterSheet._dialog(filter: filter),
          ),
        ),
      );
    }
    return showModalBottomSheet<AnimeFilter>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      backgroundColor: colors.surface,
      constraints: const BoxConstraints(maxWidth: 640),
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (_) => TagFilterSheet(filter: filter),
    );
  }

  @override
  State<TagFilterSheet> createState() => _TagFilterSheetState();
}

class _TagFilterSheetState extends State<TagFilterSheet> {
  late final Set<String> _tags;
  late final int _currentYear;
  int? _year;
  AnimeSeason? _season;

  @override
  void initState() {
    super.initState();
    _tags = widget.filter.tags.toSet();
    _year = widget.filter.year;
    _season = widget.filter.season;
    _currentYear = DateTime.now().year;
  }

  int get _selectionCount =>
      _tags.length + (_year == null ? 0 : 1) + (_season == null ? 0 : 1);

  void _apply() {
    final tags = _tags.toList()..sort();
    Navigator.pop(
      context,
      AnimeFilter(
        year: _year,
        season: _season,
        tags: UnmodifiableListView(tags),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget._dialog) return _buildPanel(null);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      builder: (context, scrollController) => _buildPanel(scrollController),
    );
  }

  Widget _buildPanel(ScrollController? scrollController) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      children: [
        if (!widget._dialog)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: colors.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '分类筛选',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '按首播时间、题材找到想看的番剧',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                tooltip: '关闭筛选',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              children: [
                if (constraints.maxWidth >= 700)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            _buildAirDate(theme),
                            _buildCategory(1),
                            _buildCategory(2),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          children: [_buildCategory(0), _buildCategory(3)],
                        ),
                      ),
                    ],
                  )
                else ...[
                  _buildAirDate(theme),
                  for (var i = 0; i < _categories.length; i++)
                    _buildCategory(i),
                ],
              ],
            ),
          ),
        ),
        _buildActions(theme),
      ],
    );
  }

  Widget _section({
    required String title,
    required IconData icon,
    required Widget child,
    int selectedCount = 0,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                selectedCount == 0
                    ? (title == '首播时间' ? '单选' : '多选')
                    : '已选 $selectedCount',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: selectedCount == 0
                      ? colors.onSurfaceVariant
                      : colors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _choice(String label, bool selected, ValueChanged<bool> onSelected) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (value) {
        HapticFeedback.selectionClick();
        onSelected(value);
      },
      backgroundColor: colors.surfaceContainerHigh,
      selectedColor: colors.secondaryContainer,
      checkmarkColor: colors.onSecondaryContainer,
      labelStyle: theme.textTheme.labelLarge?.copyWith(
        color: selected ? colors.onSecondaryContainer : colors.onSurfaceVariant,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(selected ? 14 : 28),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      chipAnimationStyle: ChipAnimationStyle(
        selectAnimation: AnimationStyle(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 220),
        ),
      ),
    );
  }

  Widget _buildCategory(int index) {
    const icons = [
      Icons.interests_rounded,
      Icons.movie_filter_rounded,
      Icons.auto_stories_rounded,
      Icons.favorite_outline_rounded,
    ];
    final (title, tags) = _categories[index];
    return _section(
      title: title,
      icon: icons[index],
      selectedCount: tags.where(_tags.contains).length,
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final tag in tags)
            _choice(
              tag,
              _tags.contains(tag),
              (selected) => setState(() {
                if (selected) {
                  _tags.add(tag);
                } else {
                  _tags.remove(tag);
                }
              }),
            ),
        ],
      ),
    );
  }

  Widget _buildAirDate(ThemeData theme) => _section(
    title: '首播时间',
    icon: Icons.calendar_month_rounded,
    selectedCount: (_year == null ? 0 : 1) + (_season == null ? 0 : 1),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PopupMenuButton<int>(
          tooltip: '选择年份',
          initialValue: _year ?? 0,
          itemBuilder: (_) => [
            const PopupMenuItem(value: 0, child: Text('不限年份')),
            for (var year = _currentYear; year >= 1980; year--)
              PopupMenuItem(value: year, child: Text('$year 年')),
          ],
          onSelected: (year) => setState(() {
            _year = year == 0 ? null : year;
            if (_year == null) _season = null;
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _year == null ? '不限年份' : '$_year 年',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  Icons.expand_more_rounded,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            _choice(
              '全年',
              _season == null,
              (_) => setState(() => _season = null),
            ),
            for (final season in AnimeSeason.values)
              _choice(
                '${season.label} · ${season.month}月',
                _season == season,
                (selected) => setState(() {
                  _season = selected ? season : null;
                  if (selected) _year ??= _currentYear;
                }),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _buildActions(ThemeData theme) => Material(
    color: theme.colorScheme.surfaceContainer,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _selectionCount == 0
                  ? '不限条件，浏览全部番剧'
                  : '已选 $_selectionCount 项条件 · 同时满足所选标签',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                IconButton.filledTonal(
                  tooltip: '重置',
                  style: IconButton.styleFrom(
                    minimumSize: const Size(56, 56),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  onPressed: _selectionCount == 0
                      ? null
                      : () => setState(() {
                          _tags.clear();
                          _year = null;
                          _season = null;
                        }),
                  icon: const Icon(Icons.restart_alt_rounded),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 56),
                      textStyle: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onPressed: _apply,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('应用筛选'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
