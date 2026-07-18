import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:baka/api/post.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/widgets/comment/comment_card.dart';

/// 帖子/讨论区业务逻辑服务
///
/// 负责评论加载、分页、缓存读写等。
/// UI 层（ThreadPage）持有本实例并驱动界面刷新。
class ThreadService {
  static const int pageSize = 20;
  static const int cacheExpiryHours = 1;
  static const Duration loadThrottleDuration = Duration(seconds: 2);

  static const List<List> threads = [
    ['#茶馆', 6],
    ['#baka', 8],
    ['#求番报错', 7],
    ['#反馈', 9],
    ['#里世界', 10],
  ];

  // ─── Per-Tab State ───

  final List<List<dynamic>> caches = List.generate(threads.length, (_) => []);
  final List<bool> isRefreshing = List.generate(threads.length, (_) => false);
  final List<bool> isLoadingMore = List.generate(threads.length, (_) => false);
  final List<bool> hasMore = List.generate(threads.length, (_) => true);
  final List<DateTime?> lastLoadTimes = List.generate(
    threads.length,
    (_) => null,
  );

  // ─── Cache ───

  Map<String, dynamic>? readCommentsCache(int pid) {
    final cache = AppStorage.threadCommentsBox.get('comments_$pid');
    if (cache == null) return null;
    return Map<String, dynamic>.from(cache);
  }

  Future<void> saveCommentsCache(int pid, List comments) async {
    try {
      await AppStorage.threadCommentsBox.put('comments_$pid', {
        'data': comments,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('保存评论到缓存失败: $e');
    }
  }

  // ─── Data Loading ───

  /// 加载缓存的评论，缓存有效则直接返回，否则触发远程刷新。
  /// 返回 true 表示缓存命中（UI 无需额外加载）。
  Future<bool> loadCachedComments(int tabIndex) async {
    final pid = threads[tabIndex][1];
    try {
      final cache = readCommentsCache(pid);
      if (cache != null) {
        final cacheTime = cache['timestamp'] ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - cacheTime < cacheExpiryHours * 3600000) {
          caches[tabIndex] = List.from(cache['data']);
          return true;
        }
      }
    } catch (e) {
      debugPrint('加载缓存评论出错: $e');
    }
    return false;
  }

  /// 刷新指定标签页的评论。返回处理后的评论列表。
  Future<List<dynamic>> refreshComments(int tabIndex) async {
    if (isRefreshing[tabIndex]) return caches[tabIndex];

    final pid = threads[tabIndex][1];
    isRefreshing[tabIndex] = true;
    hasMore[tabIndex] = true;

    try {
      final response = await getComments(pid, pageSize, '');
      final commentsData = jsonDecode(response.data)['data'];
      final processedComments = CommentListState.processCommentsList(
        commentsData,
      );
      await saveCommentsCache(pid, processedComments);
      caches[tabIndex] = processedComments;
      lastLoadTimes[tabIndex] = DateTime.now();
      return processedComments;
    } catch (e) {
      debugPrint('刷新评论出错: $e');
      rethrow;
    } finally {
      isRefreshing[tabIndex] = false;
    }
  }

  bool canLoadMore(int tabIndex) {
    if (isRefreshing[tabIndex] ||
        isLoadingMore[tabIndex] ||
        !hasMore[tabIndex]) {
      return false;
    }

    final lastLoad = lastLoadTimes[tabIndex];
    return lastLoad == null ||
        DateTime.now().difference(lastLoad) >= loadThrottleDuration;
  }

  /// 加载更多评论。返回处理后的评论列表（如果有新数据）。
  Future<List<dynamic>?> loadMoreComments(int tabIndex) async {
    if (!canLoadMore(tabIndex)) {
      return null;
    }

    final pid = threads[tabIndex][1];
    final currentLength = caches[tabIndex].length;
    final nextPageSize = currentLength + pageSize;

    isLoadingMore[tabIndex] = true;
    try {
      final response = await getComments(pid, nextPageSize, '');
      final commentsData = jsonDecode(response.data)['data'];
      final processedComments = CommentListState.processCommentsList(
        commentsData,
      );

      if (currentLength >= processedComments.length) {
        hasMore[tabIndex] = false;
        return null;
      }

      await saveCommentsCache(pid, processedComments);
      caches[tabIndex] = processedComments;
      lastLoadTimes[tabIndex] = DateTime.now();
      return processedComments;
    } catch (e) {
      debugPrint('加载更多评论出错: $e');
      return null;
    } finally {
      isLoadingMore[tabIndex] = false;
    }
  }

  /// 处理 gv 链接跳转，返回视频详情数据（供 UI 层导航）。
  Future<Map?> resolveGvLink(String gvId) async {
    try {
      final response = await getPostDetail(int.parse(gvId));
      return jsonDecode(response.data)['data'];
    } catch (e) {
      debugPrint('解析 gv 链接失败: $e');
      return null;
    }
  }
}
