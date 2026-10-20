import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/widgets/common/skeletonizer.dart';

/// 评论 Tab — 独立管理评论加载状态
class AnimeCommentsTab extends StatefulWidget {
  final int subjectId;

  const AnimeCommentsTab({required this.subjectId, super.key});

  @override
  State<AnimeCommentsTab> createState() => _AnimeCommentsTabState();
}

class _AnimeCommentsTabState extends State<AnimeCommentsTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _comments = [];
  bool _isCommentsLoading = false;
  bool _hasMoreComments = true;
  bool _failed = false;
  static const int _commentPageSize = 20;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(covariant AnimeCommentsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subjectId != widget.subjectId) _reset();
  }

  void _reset() {
    _comments = [];
    _hasMoreComments = true;
    _isCommentsLoading = false;
    _failed = false;
    _fetchComments();
  }

  Future<void> _fetchComments() async {
    if (_isCommentsLoading || !_hasMoreComments) return;
    final subjectId = widget.subjectId;
    // Each subject owns its growable list; cached pages remain read-only.
    final comments = _comments;
    setState(() {
      _isCommentsLoading = true;
      _failed = false;
    });

    try {
      final page = await getBgmSubjectComments(
        subjectId,
        limit: _commentPageSize,
        offset: comments.length,
      );
      if (!mounted || !identical(comments, _comments)) return;
      comments.addAll(page.comments);
      _hasMoreComments =
          page.comments.isNotEmpty && comments.length < page.total;
    } catch (e) {
      debugPrint('获取番剧评论失败: $e');
      if (identical(comments, _comments)) _failed = true;
    } finally {
      if (mounted && identical(comments, _comments)) {
        setState(() => _isCommentsLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification is ScrollUpdateNotification &&
            notification.metrics.extentAfter < 200 &&
            !_failed) {
          _fetchComments();
        }
        return false;
      },
      child: CustomScrollView(
        key: PageStorageKey(widget.subjectId),
        slivers: [
          if (_isCommentsLoading && _comments.isEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
              sliver: SliverList.builder(
                itemCount: 5,
                itemBuilder: (_, _) => _loadingComment(isDark),
              ),
            )
          else if (_comments.isEmpty && !_failed)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(4, 24, 4, 0),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: Text(
                    '暂无评论',
                    style: TextStyle(
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                ),
              ),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              sliver: SliverList.builder(
                itemCount: _comments.length + (_hasMoreComments ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= _comments.length) {
                    return _isCommentsLoading
                        ? _loadingComment(isDark)
                        : Center(
                            child: TextButton(
                              onPressed: _fetchComments,
                              child: Text(_failed ? '加载失败，点击重试' : '加载更多'),
                            ),
                          );
                  }
                  return _CommentItem(
                    comment: _comments[index],
                    isDark: isDark,
                  );
                },
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
          ],
        ],
      ),
    );
  }

  Widget _loadingComment(bool isDark) => AppSkeletonizer(
    enabled: true,
    child: _CommentItem(
      comment: const {
        'user': {
          'nickname': '用户名称占位符',
          'avatar': {'medium': ''},
        },
        'rate': 8,
        'comment': '这是一条用于自动骨架遮罩的评论内容占位文本...',
        'updatedAt': 0,
      },
      isDark: isDark,
    ),
  );
}

class _CommentItem extends StatelessWidget {
  final Map<String, dynamic> comment;
  final bool isDark;

  const _CommentItem({required this.comment, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final user = comment['user'] as Map<String, dynamic>;
    final nickname = user['nickname'] as String;
    final avatarUrl =
        (user['avatar'] as Map<String, dynamic>)['medium'] as String;
    final content = comment['comment'] as String;
    final rate = comment['rate'] as int;
    final updatedAt = comment['updatedAt'] as int;
    final timeStr = updatedAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(updatedAt * 1000).toRelativeTime()
        : '';
    final avatarPlaceholder = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: isDark ? Colors.white12 : Colors.black12,
        shape: BoxShape.circle,
      ),
    );

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.04),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipOval(
                child: avatarUrl.isEmpty
                    ? avatarPlaceholder
                    : CachedNetworkImage(
                        imageUrl: avatarUrl,
                        memCacheWidth: 80,
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => avatarPlaceholder,
                        errorWidget: (_, _, _) => avatarPlaceholder,
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nickname,
                      style: TextStyle(
                        color: isDark ? Colors.white : Colors.black87,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (timeStr.isNotEmpty)
                      Text(
                        timeStr,
                        style: TextStyle(
                          color: isDark ? Colors.white54 : Colors.black45,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              if (rate > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.amber.withValues(alpha: 0.3),
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        color: Colors.amber,
                        size: 12,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '$rate',
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (content.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              content,
              style: TextStyle(
                color: isDark ? Colors.white70 : Colors.black87,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
