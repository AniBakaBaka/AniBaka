import 'dart:async';

import 'package:baka/api/post.dart';
import 'package:baka/core/app_storage.dart';
import 'package:flutter/foundation.dart';

/// 一个频道持有一份列表；加载状态只通知该频道。
class ThreadController extends ChangeNotifier {
  ThreadController(this.pid);

  static const pageSize = 20;

  final int pid;
  List<Map> comments = [];
  final _seenIds = <int>{};
  int _page = 0;
  int _requestPage = 1;
  bool hasMore = true;
  Object? error;
  Completer<void>? _abort;
  Future<void>? _task;
  bool _disposed = false;

  bool get isRefreshing => _task != null && _requestPage == 1;
  bool get isLoadingMore => _task != null && _requestPage > 1;
  bool get canLoadMore =>
      _page > 0 && _task == null && hasMore && error == null;

  Future<void> load({bool refresh = false}) {
    if (_disposed) return Future.value();
    if (_task != null && (!refresh || isRefreshing)) return _task!;
    if (!refresh && error == null && !hasMore) return Future.value();

    _abort?.complete();
    final abort = _abort = Completer<void>();
    _requestPage = refresh ? 1 : (error != null ? _requestPage : _page + 1);
    error = null;
    final task = _task = _load(_requestPage, abort);
    notifyListeners();
    return task;
  }

  Future<void> _load(int page, Completer<void> abort) async {
    TtlCache? cache;
    try {
      if (page == 1) {
        try {
          await AppStorage.open(AppStorage.threadCommentsBoxName);
          if (abort != _abort) return;
          cache = TtlCache(
            AppStorage.threadCommentsBox,
            ttl: const Duration(hours: 1),
          );
          if (_page == 0) {
            final cached = cache.read('raw_comments_$pid', allowExpired: true);
            if (cached is List && cached.isNotEmpty) {
              // Cache is display-only until page one replaces it; no copy needed.
              comments = cached.cast<Map>();
              notifyListeners();
            }
          }
        } catch (error) {
          debugPrint('读取评论缓存失败: $error');
        }
      }

      if (abort != _abort) return;
      final result = await getComments(
        pid,
        pageSize,
        page: page,
        abortTrigger: abort.future,
        notifyOnError: false,
      );
      if (abort != _abort) return;

      if (page == 1) {
        comments = result;
        _seenIds
          ..clear()
          ..addAll(result.map((comment) => comment['id'] as int));
      } else {
        // Offset pagination can repeat IDs after a new comment is inserted.
        for (final comment in result) {
          if (_seenIds.add(comment['id'] as int)) comments.add(comment);
        }
      }
      _page = page;
      // The API groups replies after pagination and exposes no total/has_more.
      // Keep the legacy length heuristic until the server supplies that contract.
      hasMore = result.length >= pageSize;
      if (cache != null) {
        try {
          // Keep only page one in Hive; later appends must not grow the cache.
          await cache.write(
            'raw_comments_$pid',
            List<Map>.of(result, growable: false),
          );
        } catch (error) {
          debugPrint('保存评论缓存失败: $error');
        }
      }
    } catch (failure) {
      if (abort == _abort) error = failure;
    } finally {
      if (abort == _abort) {
        _abort = null;
        _task = null;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _abort?.complete();
    _abort = null;
    _task = null;
    comments = const [];
    _seenIds.clear();
    super.dispose();
  }
}
