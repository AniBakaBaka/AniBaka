import 'package:flutter/material.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/shimmer.dart';

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

class _AnimeDetailRelatedSectionState extends State<AnimeDetailRelatedSection> {
  static const _cacheLimit = 32;
  static final Map<int, Future<List<Map<String, dynamic>>>> _cache = {};
  late final Future<List<Map<String, dynamic>>> _items = _loadCached(
    widget.subjectId,
  );

  static Future<List<Map<String, dynamic>>> _loadCached(int subjectId) {
    final cached = _cache.remove(subjectId);
    if (cached != null) {
      _cache[subjectId] = cached;
      return cached;
    }
    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    return _cache[subjectId] = _load(subjectId);
  }

  static Future<List<Map<String, dynamic>>> _load(int subjectId) async {
    try {
      final response = await getBgmRelatedSubjects(subjectId);
      final items = <Map<String, dynamic>>[];
      final ids = <int>{};

      for (final raw in BgmUtils.parseJsonList(response.data)) {
        if (raw is! Map || BgmUtils.toInt(raw['type']) != 2) continue;
        final id = BgmUtils.toInt(raw['id']);
        final title =
            BgmUtils.trimmed(raw['name_cn']) ?? BgmUtils.trimmed(raw['name']);
        if (id == null || title == null || !ids.add(id)) continue;

        final image =
            BgmUtils.pickImageUrl(raw['images']) ??
            BgmUtils.trimmed(raw['image']) ??
            '';
        final relation = BgmUtils.trimmed(raw['relation']) ?? '相关';
        items.add({
          'id': id,
          'bgmId': id,
          'title': title,
          'content': image.isEmpty ? '' : '<img src="$image">',
          if (image.isNotEmpty) 'bgmImageUrl': image,
          'sort': '番剧',
          'tag': relation,
          'info': relation,
          'source': 'bgm',
        });
      }
      return items;
    } catch (_) {
      _cache.remove(subjectId);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _items,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('相关动画加载失败'));
        }
        if (!snapshot.hasData) {
          return SizedBox(
            height: 260,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: 5,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (_, _) =>
                  const ShimmerCoverCard(width: 140, showSubtitle: true),
            ),
          );
        }

        final items = snapshot.data!;
        if (items.isEmpty) return const Center(child: Text('暂无相关动画'));
        return SizedBox(
          height: 260,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, index) {
              final item = items[index];
              return SizedBox(
                width: 140,
                child: PostCard(item, onTap: () => widget.onAnimeTap(item)),
              );
            },
          ),
        );
      },
    );
  }
}
