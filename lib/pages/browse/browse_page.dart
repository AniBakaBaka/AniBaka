import 'package:flutter/material.dart';

import 'package:baka/source/models/series.dart';
import 'package:baka/source/source_registry.dart';

/// 浏览：按源看内容。首版为「聚合首页」——每个内置源一个区块，区块内通过
/// 源规则的 home 管线拉取首页卡片（最近更新 / 推荐等）横向展示；未配置 home
/// 或拉取失败的源回退到占位，待后续为各源补全 home 规则。
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
  final AdapterDescriptor source;

  const _SourceSection({required this.source});

  @override
  State<_SourceSection> createState() => _SourceSectionState();
}

class _SourceSectionState extends State<_SourceSection> {
  late final Future<List<Series>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadHome();
  }

  Future<List<Series>> _loadHome() async {
    final adapter = AdapterRegistry.createAdapter(widget.source.key);
    if (adapter == null || adapter.rule.home.isEmpty) return const [];
    try {
      return await adapter.fetchHome();
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
                separatorBuilder: (_) => const SizedBox(width: 12),
                itemBuilder: (context, index) =>
                    _SeriesCard(series: items[index]),
              ),
            );
          },
        ),
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

class _SeriesCard extends StatelessWidget {
  final Series series;

  const _SeriesCard({required this.series});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 124,
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
