import 'dart:convert';

import 'package:baka/api/bgm.dart';
import 'package:baka/api/post.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/services/bgm_service.dart';
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
  List<dynamic> _items = const [];
  int _page = 0;

  Future<bool> _loadPage(int page) async {
    try {
      List<dynamic> posts = const [];
      if (widget.tag.isNotEmpty) {
        const pageSize = 15;
        final response = await searchBgmByTag(
          [widget.tag],
          limit: pageSize,
          offset: (page - 1) * pageSize,
        );
        posts = BgmService.convertSearchResponseToAppFormat(response.data);
      } else if (widget.uid != 0) {
        final response = await getPost('', '', page, 15, uid: widget.uid);
        posts = List<dynamic>.from(jsonDecode(response.data)['data'] as List);
      }

      if (!mounted) return posts.isNotEmpty;
      setState(() {
        _page = page;
        _items = page == 1 ? posts : [..._items, ...posts];
      });
      return posts.isNotEmpty;
    } catch (e) {
      debugPrint('Error getting tag list: $e');
      return false;
    }
  }

  Future<void> _refresh() async {
    await _loadPage(1);
  }

  Future<bool> _loadMore() => _loadPage(_page + 1);

  void _openBgmSubject(Map data) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          data: <String, dynamic>{
            'title': data['title'],
            'bgmId': data['bgmId'],
            if (data['bgmImageUrl'] != null) 'bgmImageUrl': data['bgmImageUrl'],
            if (data['score'] != null) 'score': data['score'],
          },
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
        child: GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(10),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.58,
          ),
          itemCount: _items.length,
          itemBuilder: (_, index) {
            final data = _items[index] as Map;
            return PostCard(
              data,
              onTap: widget.tag.isEmpty ? null : () => _openBgmSubject(data),
            );
          },
        ),
      ),
    );
  }
}
