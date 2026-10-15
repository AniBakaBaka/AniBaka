import 'package:baka/core/content_filter.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/api/post.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/refresh.dart';
import 'package:flutter/material.dart';

class TagPage extends StatefulWidget {
  final String tag;
  final int uid;

  const TagPage(this.tag, this.uid, {super.key});

  @override
  State<TagPage> createState() => _TagPageState();
}

class _TagPageState extends State<TagPage> {
  List<Map> _items = [];
  final _itemsRevision = ValueNotifier<int>(0);
  int _page = 0;
  bool _hasMore = true;

  Future<bool> _loadPage(int page) async {
    try {
      const pageSize = 15;
      List<Map> posts = const [];
      var received = 0;
      if (widget.tag.isNotEmpty) {
        final subjects = await searchBgm(
          tags: [widget.tag],
          limit: pageSize,
          offset: (page - 1) * pageSize,
        );
        if (!mounted) return false;
        received = subjects.length;
        posts = convertBgmSubjectsToAppFormat(subjects, compact: true);
      } else if (widget.uid != 0) {
        posts = await getPost('', '', page, pageSize, uid: widget.uid);
        received = posts.length;
      }

      if (!mounted) return posts.isNotEmpty;
      _page = page;
      // Use the raw page size: conversion can filter malformed subjects.
      _hasMore = received == pageSize;
      if (page == 1) {
        _items = posts;
        _itemsRevision.value++;
      } else if (posts.isNotEmpty) {
        _items.addAll(posts);
        _itemsRevision.value++;
      }
      return _hasMore;
    } catch (e) {
      debugPrint('Error getting tag list: $e');
      return false;
    }
  }

  Future<void> _refresh() async {
    await _loadPage(1);
  }

  Future<bool> _loadMore() =>
      _hasMore ? _loadPage(_page + 1) : Future<bool>.value(false);

  @override
  void dispose() {
    _items = const [];
    _itemsRevision.dispose();
    super.dispose();
  }

  void _openBgmSubject(Map data) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          request: PlaybackRequest.fromMap(<String, dynamic>{
            'title': data['title'],
            'bgmId': data['bgmId'],
            if (data['bgmImageUrl'] != null) 'bgmImageUrl': data['bgmImageUrl'],
            if (data['score'] != null) 'score': data['score'],
          }),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.tag.isEmpty ? '用户上传' : widget.tag,
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      body: RefreshWrapper(
        onRefresh: _refresh,
        onLoadMore: _loadMore,
        child: ListenableBuilder(
          listenable: Listenable.merge([_itemsRevision, contentFilter]),
          builder: (context, _) {
            final items = contentFilter.visibleItems(_items);
            return GridView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(10),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.58,
              ),
              itemCount: items.length,
              itemBuilder: (_, index) {
                final data = items[index];
                return PostCard(
                  data,
                  onTap: widget.tag.isEmpty
                      ? null
                      : () => _openBgmSubject(data),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
