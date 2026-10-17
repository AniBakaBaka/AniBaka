import 'package:baka/api/bgm.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// 番剧详情页：有 subjectId 时加载 BGM 数据，否则作为纯简介页展示
class BgmDetailPage extends StatefulWidget {
  final int? subjectId;
  final String title;
  final String imageUrl;
  final String? fixedSummary;
  final double? initialScore;
  final VoidCallback? onClose;
  final ScrollController? scrollController;

  const BgmDetailPage({
    required this.title,
    required this.imageUrl,
    super.key,
    this.subjectId,
    this.fixedSummary,
    this.initialScore,
    this.onClose,
    this.scrollController,
  });

  static Future<void> show(
    BuildContext context, {
    required String title,
    int? subjectId,
    String? imageUrl,
    String? fixedSummary,
    double? initialScore,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.96,
        snap: true,
        builder: (context, scrollController) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: BgmDetailPage(
            subjectId: subjectId,
            title: title,
            imageUrl: imageUrl ?? '',
            fixedSummary: fixedSummary,
            initialScore: initialScore,
            scrollController: scrollController,
            onClose: () => Navigator.pop(context),
          ),
        ),
      ),
    );
  }

  @override
  State<BgmDetailPage> createState() => _BgmDetailPageState();
}

class _BgmDetailPageState extends State<BgmDetailPage> {
  /// Bangumi v0 subject; shared with the player through the API cache.
  Map<String, dynamic>? _detail;
  bool _error = false;

  bool get _hasFixedSummary => widget.fixedSummary?.isNotEmpty == true;

  @override
  void initState() {
    super.initState();
    final subjectId = widget.subjectId;
    if (subjectId == null) return;
    _detail = peekBgmSubject(subjectId);
    if (_detail == null) _fetchDetail(subjectId);
  }

  Future<void> _fetchDetail(int subjectId) async {
    try {
      final detail = await getBgmSubject(subjectId);
      if (mounted) setState(() => _detail = detail);
    } catch (_) {
      if (mounted) setState(() => _error = !_hasFixedSummary);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Stack(
        children: [
          if (_error) _buildError(theme) else _buildBody(theme),
          if (widget.onClose != null)
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close_rounded),
                color: theme.colorScheme.onSurfaceVariant,
                onPressed: widget.onClose,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final detail = _detail;
    final tags = detail?['tags'] as List? ?? const [];
    final infobox = detail?['infobox'] as List? ?? const [];
    final subjectId = widget.subjectId;
    return CustomScrollView(
      controller: widget.scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
          sliver: SliverList.list(
            children: [
              _buildHeader(theme, detail),
              _sectionTitle('简介'),
              _buildSummary(
                theme,
                _hasFixedSummary
                    ? widget.fixedSummary!
                    : detail?['summary'] as String? ?? '暂无简介',
              ),
              if (tags.isNotEmpty) ...[_sectionTitle('标签'), _buildTags(theme, tags)],
              if (infobox.isNotEmpty) _sectionTitle('详细信息'),
            ],
          ),
        ),
        if (infobox.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList.builder(
              itemCount: infobox.length,
              itemBuilder: (context, index) =>
                  _buildInfoboxItem(theme, infobox[index] as Map),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
          sliver: SliverToBoxAdapter(
            child: subjectId == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Center(
                      child: TextButton.icon(
                        onPressed: () => launchUrlString(
                          'https://bgm.tv/subject/$subjectId',
                          mode: LaunchMode.externalApplication,
                        ),
                        icon: const Icon(Icons.open_in_new_rounded, size: 16),
                        label: const Text('在 Bangumi 上查看更多'),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 12),
      child: Text(
        text,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildError(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            '无法获取详细信息',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              setState(() => _error = false);
              _fetchDetail(widget.subjectId!);
            },
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, Map<String, dynamic>? detail) {
    final muted = theme.colorScheme.onSurfaceVariant;
    final title = detail?['name'] as String? ?? widget.title;
    final nameCn = detail?['name_cn'] as String? ?? '';
    final rating = detail?['rating'] as Map?;
    final score =
        (rating?['score'] as num?)?.toDouble() ?? widget.initialScore ?? 0;
    final collection = detail?['collection'] as Map?;
    final placeholder = Container(
      width: 100,
      height: 150,
      color: theme.colorScheme.surfaceContainerHighest,
    );
    return Padding(
      padding: const EdgeInsets.only(right: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.imageUrl.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: CachedNetworkImage(
                imageUrl: widget.imageUrl,
                width: 100,
                height: 150,
                fit: BoxFit.cover,
                memCacheWidth: 300,
                placeholder: (_, _) => placeholder,
                errorWidget: (_, _, _) => placeholder,
              ),
            ),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    height: 1.3,
                  ),
                ),
                if (nameCn.isNotEmpty && nameCn != title) ...[
                  const SizedBox(height: 4),
                  Text(
                    nameCn,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: muted),
                  ),
                ],
                if (score > 0) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        size: 18,
                        color: Color(0xFFFFB74D),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        score.toStringAsFixed(1),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFFFB74D),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${rating?['total'] ?? 0} 人评分',
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    ],
                  ),
                ],
                if (collection != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${collection['doing']} 在看 · '
                    '${collection['collect']} 看过 · '
                    '${collection['wish']} 想看',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(ThemeData theme, String summary) {
    final bodyStyle = TextStyle(
      fontSize: 15,
      height: 1.8,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
    );
    // Share selection across paragraphs without a nested EditableText/Scrollable
    // for each paragraph in a long synopsis.
    return SelectionArea(
      child: MarkdownBody(
        data: summary,
        styleSheet: MarkdownStyleSheet(
          p: bodyStyle,
          blockquote: bodyStyle,
          a: TextStyle(color: theme.colorScheme.primary),
          blockquoteDecoration: const BoxDecoration(),
          blockquotePadding: EdgeInsets.zero,
        ),
        onTapLink: (_, url, _) {
          if (url != null) {
            launchUrlString(url, mode: LaunchMode.externalApplication);
          }
        },
      ),
    );
  }

  Widget _buildTags(ThemeData theme, List tags) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final tag in tags.take(15))
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '${tag['name']}  ${tag['count']}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
      ],
    );
  }

  /// Infobox value is a string, or a list of `{k?, v}` entries.
  Widget _buildInfoboxItem(ThemeData theme, Map item) {
    final value = item['value'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              item['key'] as String,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value is List
                  ? value.map((entry) => entry['v']).join(' / ')
                  : value as String,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
