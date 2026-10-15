import 'package:baka/core/content_filter.dart';
import 'package:flutter/material.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/skeletonizer.dart';

/// 详情页的相关动画。只读取关系列表，不为每个条目额外预取详情。
class AnimeDetailRelatedSection extends StatefulWidget {
  const AnimeDetailRelatedSection({
    required this.subjectId,
    required this.onAnimeTap,
    super.key,
  });

  final int subjectId;
  final ValueChanged<Map<String, dynamic>> onAnimeTap;

  @override
  State<AnimeDetailRelatedSection> createState() =>
      _AnimeDetailRelatedSectionState();
}

class _AnimeDetailRelatedSectionState extends State<AnimeDetailRelatedSection>
    with AutomaticKeepAliveClientMixin {
  late Future<List<Map<String, dynamic>>> _items = _load(widget.subjectId);

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant AnimeDetailRelatedSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subjectId != widget.subjectId) {
      _items = _load(widget.subjectId);
    }
  }

  static Future<List<Map<String, dynamic>>> _load(int subjectId) async {
    final response = await getBgmRelatedSubjects(subjectId);
    final items = <Map<String, dynamic>>[];
    for (final raw in response) {
      if (raw['type'] != 2) continue;
      final id = raw['id'] as int;
      final nameCN = raw['name_cn'] as String;
      final image = (raw['images'] as Map)['large'] as String;
      final relation = raw['relation'] as String;
      items.add({
        'id': id,
        'bgmId': id,
        'nsfw': raw['nsfw'] == true,
        'title': nameCN.isEmpty ? raw['name'] as String : nameCN,
        'bgmImageUrl': image,
        'sort': '番剧',
        'tag': relation,
        'info': relation,
        'source': 'bgm',
      });
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: contentFilter,
      builder: (context, _) => _buildItems(),
    );
  }

  Widget _buildItems() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _items,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.hasError) {
          return const Center(child: Text('相关动画加载失败'));
        }
        final loading = snapshot.connectionState != ConnectionState.done;
        final items = contentFilter.visibleItems(
          snapshot.data ?? const <Map<String, dynamic>>[],
        );
        if (!loading && items.isEmpty) {
          return const Center(child: Text('暂无相关动画'));
        }
        return SizedBox(
          height: 260,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: loading ? 5 : items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, index) {
              final item = loading
                  ? const <String, dynamic>{'title': '相关动画标题占位', 'image': ''}
                  : items[index];
              return SizedBox(
                width: 140,
                child: AppSkeletonizer(
                  enabled: loading,
                  child: PostCard(
                    item,
                    onTap: () {
                      if (!loading) widget.onAnimeTap(item);
                    },
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
