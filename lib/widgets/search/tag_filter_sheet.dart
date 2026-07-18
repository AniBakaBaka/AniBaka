import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class _TagCategory {
  final String title;
  final IconData icon;
  final Color color;
  final List<String> tags;

  const _TagCategory({
    required this.title,
    required this.icon,
    required this.color,
    required this.tags,
  });
}

const List<_TagCategory> _categories = [
  _TagCategory(
    title: '热门',
    icon: Icons.whatshot_rounded,
    color: Color(0xFFFF6B6B),
    tags: ['推荐', '最新'],
  ),
  _TagCategory(
    title: '题材',
    icon: Icons.auto_awesome_rounded,
    color: Color(0xFF60A5FA),
    tags: [
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
  _TagCategory(
    title: '年份',
    icon: Icons.calendar_month_rounded,
    color: Color(0xFF4ADE80),
    tags: [
      '2026',
      '2025',
      '2024',
      '2023',
      '2022',
      '2021',
      '2020',
      '2019',
      '2018',
      '2017',
      '2016',
      '2015',
      '2014',
      '2013',
      '2012',
      '2011',
      '2010',
      '2000年代',
      '90年代',
      '80年代',
    ],
  ),
  _TagCategory(
    title: '类型',
    icon: Icons.movie_filter_rounded,
    color: Color(0xFFA78BFA),
    tags: ['TV', 'OVA', '剧场版', 'Web', '泡面番'],
  ),
  _TagCategory(
    title: '改编',
    icon: Icons.auto_stories_rounded,
    color: Color(0xFFFBBF24),
    tags: ['原创', '漫画改', '小说改', '轻小说改', '游戏改'],
  ),
  _TagCategory(
    title: '受众',
    icon: Icons.people_rounded,
    color: Color(0xFFF472B6),
    tags: ['后宫', '百合', '耽美', '乙女', '萌', '燃', '致郁', '催泪'],
  ),
];

class TagFilterSheet extends StatefulWidget {
  const TagFilterSheet({required this.tags, super.key});

  final String tags;

  static Future<String?> show(BuildContext context, String tags) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TagFilterSheet(tags: tags),
    );
  }

  @override
  State<TagFilterSheet> createState() => _TagFilterSheetState();
}

class _TagFilterSheetState extends State<TagFilterSheet> {
  late final Set<String> _selectedTags;

  @override
  void initState() {
    super.initState();
    _selectedTags = widget.tags.isNotEmpty
        ? widget.tags.split(',').toSet()
        : {};
  }

  void _toggleTag(String tag) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_selectedTags.remove(tag)) {
        _selectedTags.add(tag);
      }
    });
  }

  void _resetSelection() {
    HapticFeedback.lightImpact();
    if (_selectedTags.isNotEmpty) setState(_selectedTags.clear);
  }

  void _confirm() {
    HapticFeedback.mediumImpact();
    Navigator.pop(context, _selectedTags.join(','));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final primary = colorScheme.primary;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            children: [
              _buildHeader(theme, primary, isDark),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    if (_selectedTags.isNotEmpty) ...[
                      _buildSelectedSummary(theme, primary, isDark),
                      const SizedBox(height: 20),
                    ],
                    for (int i = 0; i < _categories.length; i++) ...[
                      _buildCategorySection(_categories[i], theme, isDark),
                      if (i < _categories.length - 1)
                        const SizedBox(height: 24),
                    ],
                    SizedBox(height: MediaQuery.paddingOf(context).bottom + 20),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(ThemeData theme, Color primary, bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? Colors.white10
                : Colors.black.withValues(alpha: 0.05),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.tune_rounded, size: 20, color: primary),
              ),
              const SizedBox(width: 12),
              Text(
                '分类筛选',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.3,
                ),
              ),
              const Spacer(),
              if (_selectedTags.isNotEmpty)
                TextButton(
                  onPressed: _resetSelection,
                  style: TextButton.styleFrom(
                    foregroundColor: isDark ? Colors.white70 : Colors.black54,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: const Text('重置'),
                ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _confirm,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  elevation: 0,
                ),
                child: Text(
                  _selectedTags.isNotEmpty
                      ? '确认 (${_selectedTags.length})'
                      : '完成',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedSummary(ThemeData theme, Color primary, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: isDark ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_rounded, size: 20, color: primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _selectedTags.join('、'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: primary,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategorySection(
    _TagCategory category,
    ThemeData theme,
    bool isDark,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: category.color.withValues(alpha: isDark ? 0.18 : 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(category.icon, size: 16, color: category.color),
            ),
            const SizedBox(width: 10),
            Text(
              category.title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final tag in category.tags) _buildTagChip(tag, theme, isDark),
          ],
        ),
      ],
    );
  }

  Widget _buildTagChip(String tag, ThemeData theme, bool isDark) {
    final isSelected = _selectedTags.contains(tag);
    final primary = theme.colorScheme.primary;
    final surfaceColor = isDark
        ? const Color(0xFF2C2C2E)
        : const Color(0xFFF2F2F7);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _toggleTag(tag),
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? primary : surfaceColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? primary
                  : (isDark
                        ? Colors.white10
                        : Colors.black.withValues(alpha: 0.05)),
              width: 0.5,
            ),
          ),
          child: Text(
            tag,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              color: isSelected
                  ? theme.colorScheme.onPrimary
                  : (isDark ? Colors.white70 : Colors.black87),
            ),
          ),
        ),
      ),
    );
  }
}
