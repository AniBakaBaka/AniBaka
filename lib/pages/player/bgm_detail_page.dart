import 'package:baka/api/bgm.dart';
import 'package:baka/widgets/common/shimmer.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
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
  bool _loading = false;
  bool _error = false;
  late String _title = widget.title;
  late String _summary = widget.fixedSummary ?? '暂无简介';
  late double _score = widget.initialScore ?? 0;
  String _cnName = '';
  int _ratingCount = 0;
  Map? _collection;
  List<Map<String, dynamic>> _tags = [];
  List<Map<String, dynamic>> _infobox = [];

  @override
  void initState() {
    super.initState();
    if (widget.subjectId != null) _fetchDetail();
  }

  Future<void> _fetchDetail() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final detail = await getBgmAnimeFullDetail(widget.subjectId!);
      if (!mounted) return;
      if (detail == null) throw Exception('无数据');
      setState(() {
        final rating = detail['rating'] as Map?;
        _collection = detail['collection'] as Map?;
        _tags = (detail['tags'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        _infobox =
            (detail['infobox'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        _title = detail['name']?.toString() ?? widget.title;
        _cnName = detail['name_cn']?.toString() ?? '';
        if (widget.fixedSummary?.isNotEmpty != true) {
          _summary = detail['summary']?.toString() ?? '暂无简介';
        }
        _score =
            (rating?['score'] as num?)?.toDouble() ?? widget.initialScore ?? 0;
        _ratingCount = (rating?['total'] as num?)?.toInt() ?? 0;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = widget.fixedSummary == null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.scaffoldBackgroundColor,
      child: Stack(
        children: [
          _buildBody(theme),
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
    if (_loading) return _buildSkeleton();
    if (_error) return _buildError(theme);

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      children: [
        _buildHeader(theme),
        _buildSectionTitle('简介'),
        _buildSummary(theme),
        if (_tags.isNotEmpty) ...[_buildSectionTitle('标签'), _buildTags(theme)],
        if (_infobox.isNotEmpty) ...[
          _buildSectionTitle('详细信息'),
          _buildInfobox(theme),
        ],
        if (widget.subjectId != null) ...[
          const SizedBox(height: 24),
          Center(
            child: TextButton.icon(
              onPressed: () => launchUrlString(
                'https://bgm.tv/subject/${widget.subjectId}',
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('在 Bangumi 上查看更多'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 12),
      child: Text(
        text,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildSkeleton() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShimmerBox(
            width: 100,
            height: 150,
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShimmerTextLine(width: 150, height: 24),
                SizedBox(height: 8),
                ShimmerTextLine(width: 100, height: 14),
                SizedBox(height: 16),
                ShimmerTextLine(width: 200, height: 14),
              ],
            ),
          ),
        ],
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
          TextButton(onPressed: _fetchDetail, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
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
                placeholder: (_, _) =>
                    const ShimmerBox(width: 100, height: 150),
                errorWidget: (_, _, _) => Container(
                  width: 100,
                  height: 150,
                  color: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    height: 1.3,
                  ),
                ),
                if (_cnName.isNotEmpty && _cnName != _title) ...[
                  const SizedBox(height: 4),
                  Text(
                    _cnName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (_score > 0) ...[
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
                        _score.toStringAsFixed(1),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFFFB74D),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '$_ratingCount 人评分',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
                if (_collection != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${_collection!['doing'] ?? 0} 在看 · '
                    '${_collection!['collect'] ?? 0} 看过 · '
                    '${_collection!['wish'] ?? 0} 想看',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(ThemeData theme) {
    final bodyStyle = TextStyle(
      fontSize: 15,
      height: 1.8,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
    );
    return MarkdownBody(
      data: _summary,
      selectable: true,
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
    );
  }

  Widget _buildTags(ThemeData theme) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _tags.take(15).map((e) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '${e['name']}  ${e['count']}',
            style: const TextStyle(fontSize: 12),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildInfobox(ThemeData theme) {
    return Column(
      children: _infobox.map((item) {
        final dynamic v = item['value'];
        final valueStr = v is List
            ? v.map((i) => (i is Map ? i['v'] : i).toString()).join(' / ')
            : v.toString();

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 80,
                child: Text(
                  item['key'].toString(),
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: Text(valueStr, style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
