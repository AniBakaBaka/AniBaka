import 'package:flutter/material.dart';

import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/source_adapter.dart';
import 'package:baka/source/source_registry.dart';

/// 浏览：按源看内容。每个内置源一个区块：区块内通过源规则的 home 管线拉取
/// 首页卡片（最近更新 / 推荐等）横向展示；若该源声明了 categories，还会在
/// 首页下方展示分类入口，点击后用 category 管线拉取该分类的卡片网格。
/// 未配置 home / category 或拉取失败的源优雅回退到占位。
class BrowsePage extends StatelessWidget {
  const BrowsePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('浏览'),
        elevation: 0,
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                for (final source in AdapterRegistry.builtinSources) ...[
                  _SourceSection(source: source),
                  const SizedBox(height: 16),
                ],
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceSection extends StatefulWidget {
  const _SourceSection({required this.source});

  final AdapterDescriptor source;

  @override
  State<_SourceSection> createState() => _SourceSectionState();
}

class _SourceSectionState extends State<_SourceSection> {
  SourceAdapter? _adapter;
  late final Future<List<Series>> _future;

  @override
  void initState() {
    super.initState();
    _adapter = AdapterRegistry.createAdapter(widget.source.key);
    _future = _loadHome();
  }

  Future<List<Series>> _loadHome() async {
    final adapter = _adapter;
    if (adapter == null || adapter.rule.home.isEmpty) return const [];
    try {
      return await adapter.fetchHome();
    } catch (_) {
      return const [];
    }
  }

  void _openCategory(SourceCategory category) {
    final adapter = _adapter;
    if (adapter == null || adapter.rule.category.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CategorySheet(
        adapter: adapter,
        categoryId: category.id,
        title: category.name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final categories = _adapter?.rule.categories ?? const <SourceCategory>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(widget.source.icon, color: widget.source.color, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.source.displayName,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            FutureBuilder<List<Series>>(
              future: _future,
              builder: (context, snapshot) {
                final label = !snapshot.hasData
                    ? '加载中'
                    : snapshot.data!.isEmpty
                        ? '待接入'
                        : '已接入';
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: colors.onSurface.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    label,
                    style: textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 10),
        FutureBuilder<List<Series>>(
          future: _future,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return _placeholder(colors, textTheme, '加载中…');
            }
            final items = snapshot.data!;
            if (items.isEmpty) {
              return _placeholder(colors, textTheme, '首页内容接入中');
            }
            return SizedBox(
              height: 184,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                padding: EdgeInsets.zero,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) =>
                    _SeriesCard(series: items[index]),
              ),
            );
          },
        ),
        if (categories.isNotEmpty) ...[
          const SizedBox(height: 10),
          _CategoryChips(categories: categories, onTap: _openCategory),
        ],
      ],
    );
  }

  Widget _placeholder(
    ColorScheme colors,
    TextTheme textTheme,
    String text,
  ) =>
      Container(
        height: 184,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.onSurface.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Text(
          text,
          style: textTheme.bodyMedium?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      );
}

/// 分类入口 chips：横向滚动的分类按钮，点击回调到父级去拉取分类结果。
class _CategoryChips extends StatelessWidget {
  const _CategoryChips({required this.categories, required this.onTap});

  final List<SourceCategory> categories;
  final ValueChanged<SourceCategory> onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final category = categories[index];
          return ActionChip(
            label: Text(category.name),
            onPressed: () => onTap(category),
          );
        },
      ),
    );
  }
}

/// 分类结果面板：底部弹出，用 category 管线拉取该分类的卡片网格。
class _CategorySheet extends StatefulWidget {
  const _CategorySheet({
    required this.adapter,
    required this.categoryId,
    required this.title,
  });

  final SourceAdapter adapter;
  final String categoryId;
  final String title;

  @override
  State<_CategorySheet> createState() => _CategorySheetState();
}

class _CategorySheetState extends State<_CategorySheet> {
  late final Future<List<Series>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Series>> _load() async {
    try {
      return await widget.adapter.fetchCategory(widget.categoryId);
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              widget.title,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Series>>(
              future: _future,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  );
                }
                final items = snapshot.data!;
                if (items.isEmpty) {
                  return Center(
                    child: Text(
                      '该分类暂无内容',
                      style: textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 140,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.62,
                      ),
                  itemCount: items.length,
                  itemBuilder: (context, index) =>
                      _SeriesCard(series: items[index], width: double.infinity),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SeriesCard extends StatelessWidget {
  const _SeriesCard({required this.series, this.width = 124});

  final Series series;
  final double width;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Card(
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: series.image?.isNotEmpty == true
                  ? Image.network(
                      series.image!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorBuilder: (_, _, _) => _posterFallback(colors),
                    )
                  : _posterFallback(colors),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                series.name,
                style: textTheme.labelSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _posterFallback(ColorScheme colors) => Container(
        width: double.infinity,
        color: colors.primary.withValues(alpha: 0.08),
        alignment: Alignment.center,
        child: Icon(
          Icons.movie_outlined,
          color: colors.onSurfaceVariant,
        ),
      );
}
