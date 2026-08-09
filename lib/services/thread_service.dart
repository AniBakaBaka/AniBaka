import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:baka/api/post.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/widgets/comment/comment_card.dart';

/// 讨论区频道
class ThreadChannel {
  final String name;
  final int pid;
  const ThreadChannel(this.name, this.pid);
}

/// 单频道运行时状态（数据与加载标志合一，避免平行数组）
class ThreadTab {
  final ThreadChannel channel;
  List comments = [];
  final Set<Object?> seenIds = <Object?>{};
  bool isRefreshing = false;
  bool isLoadingMore = false;
  bool hasMore = true;

  /// 已成功加载的页数；0 表示尚未加载
  int page = 0;
  ThreadTab(this.channel);

  int get pid => channel.pid;
  String get name => channel.name;
}

/// 帖子/讨论区业务逻辑
///
/// 分页：固定 pageSize，按 page 递增拉取并 append，
/// 避免「每次把 pageSize 加大再整表重拉」的 O(n²) 网络与处理开销。
class ThreadService {
  static const int pageSize = 20;

  /// 评论缓存 1 小时（首页缓存忽略过期，供冷启动快速填充）。
  static final TtlCache _commentsCache = TtlCache(
    AppStorage.threadCommentsBox,
    ttl: const Duration(hours: 1),
  );

  static const channels = <ThreadChannel>[
    ThreadChannel('#茶馆', 6),
    ThreadChannel('#baka', 8),
    ThreadChannel('#求番报错', 7),
    ThreadChannel('#反馈', 9),
    ThreadChannel('#里世界', 10),
  ];

  final List<ThreadTab> tabs = List.generate(
    channels.length,
    (i) => ThreadTab(channels[i]),
  );

  List? _readCache(int pid, {bool ignoreExpiry = true}) {
    final data = _commentsCache.read(
      'comments_$pid',
      allowExpired: ignoreExpiry,
    );
    return data is List ? data : null;
  }

  Future<void> _writeCache(int pid, List comments) async {
    try {
      await _commentsCache.write('comments_$pid', comments);
    } catch (e) {
      debugPrint('保存评论缓存失败: $e');
    }
  }

  static void _resetSeenIds(ThreadTab tab) {
    tab.seenIds
      ..clear()
      ..addAll(<Object?>[
        for (final c in tab.comments)
          if (c is Map) c['id'],
      ]);
  }

  Future<List> _fetchPage(int pid, int page) async {
    final response = await getComments(pid, pageSize, '', page: page);
    final decoded = jsonDecode(response);
    final data = decoded is Map ? decoded['data'] : null;
    return CommentListState.processCommentsList(data is List ? data : null);
  }

  /// 尝试用本地缓存填充 [tabIndex]；命中返回 true。
  bool loadCached(int tabIndex, {bool ignoreExpiry = true}) {
    final tab = tabs[tabIndex];
    try {
      final cached = _readCache(tab.pid, ignoreExpiry: ignoreExpiry);
      if (cached == null || cached.isEmpty) return false;
      tab.comments = List.of(cached);
      _resetSeenIds(tab);
      // 缓存只保证首页数据；hasMore 保守为 true，由后续 loadMore 校正
      tab.page = 1;
      tab.hasMore = cached.length >= pageSize;
      return true;
    } catch (e) {
      debugPrint('读取评论缓存失败: $e');
      return false;
    }
  }

  /// 刷新首页。返回最新列表。
  Future<List> refresh(int tabIndex) async {
    final tab = tabs[tabIndex];
    if (tab.isRefreshing) return tab.comments;

    tab.isRefreshing = true;
    tab.hasMore = true;
    try {
      final list = await _fetchPage(tab.pid, 1);
      tab.comments = list;
      _resetSeenIds(tab);
      tab.page = 1;
      tab.hasMore = list.length >= pageSize;
      await _writeCache(tab.pid, list);
      return list;
    } catch (e) {
      debugPrint('刷新评论失败: $e');
      rethrow;
    } finally {
      tab.isRefreshing = false;
    }
  }

  bool canLoadMore(int tabIndex) {
    final tab = tabs[tabIndex];
    // page == 0 表示首页还没成功加载过，此时没有「下一页」可言。
    return tab.page > 0 && !tab.isLoadingMore && tab.hasMore;
  }

  /// 加载下一页并 append。无新数据时返回 null。
  Future<List?> loadMore(int tabIndex) async {
    if (!canLoadMore(tabIndex)) return null;

    final tab = tabs[tabIndex];
    final nextPage = tab.page + 1;
    tab.isLoadingMore = true;
    try {
      final page = await _fetchPage(tab.pid, nextPage);
      if (page.isEmpty) {
        tab.hasMore = false;
        return null;
      }

      final fresh = [
        for (final c in page)
          if (c is! Map || tab.seenIds.add(c['id'])) c,
      ];

      if (fresh.isEmpty) {
        tab.hasMore = false;
        return null;
      }

      tab.comments.addAll(fresh);
      tab.page = nextPage;
      tab.hasMore = page.length >= pageSize;
      return tab.comments;
    } catch (e) {
      debugPrint('加载更多评论失败: $e');
      return null;
    } finally {
      tab.isLoadingMore = false;
    }
  }

  Future<Map?> resolveGvLink(String gvId) async {
    try {
      final response = await getPostDetail(int.parse(gvId));
      final decoded = jsonDecode(response);
      return decoded is Map ? decoded['data'] as Map? : null;
    } catch (e) {
      debugPrint('解析 gv 链接失败: $e');
      return null;
    }
  }
}
