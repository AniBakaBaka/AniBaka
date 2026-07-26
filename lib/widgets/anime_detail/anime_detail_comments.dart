import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/date_util.dart';
import 'package:baka/widgets/common/shimmer.dart';

/// 评论 Tab — 独立管理评论加载状态
class AnimeCommentsTab extends StatefulWidget {
  final int subjectId;
  final List<Map<String, dynamic>> initialComments;
  final int initialTotal;
  final ValueChanged<(List<Map<String, dynamic>>, int)>? onCommentsChanged;

  const AnimeCommentsTab({
    required this.subjectId,
    this.initialComments = const [],
    this.initialTotal = 0,
    this.onCommentsChanged,
    super.key,
  });

  @override
  State<AnimeCommentsTab> createState() => _AnimeCommentsTabState();
}

class _AnimeCommentsTabState extends State<AnimeCommentsTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _comments = [];
  int _commentTotal = 0;
  bool _isCommentsLoading = false;
  bool _isLoadingMoreComments = false;
  static const int _commentPageSize = 20;

  bool get _hasMoreComments => _comments.length < _commentTotal;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _comments = List.of(widget.initialComments);
    _commentTotal = widget.initialTotal;
    if (_comments.isEmpty) {
      _fetchComments();
    }
  }

  Future<void> _fetchComments({bool loadMore = false}) async {
    if (!loadMore && _isCommentsLoading) return;
    if (!loadMore && _comments.isNotEmpty && _commentTotal > 0) return;
    if (loadMore && (_isLoadingMoreComments || !_hasMoreComments)) return;

    if (loadMore) {
      setState(() => _isLoadingMoreComments = true);
    } else {
      setState(() {
        _isCommentsLoading = true;
        _comments = [];
      });
    }

    try {
      final response = await getBgmSubjectComments(
        widget.subjectId,
        limit: _commentPageSize,
        offset: _comments.length,
      );
      if (!mounted) return;
      final parsed = BgmUtils.asMap(jsonDecode(response.data));
      if (parsed == null) return;
      final data = BgmUtils.asMapList(parsed['data']);
      final total = (parsed['total'] as num?)?.toInt() ?? 0;
      setState(() {
        if (loadMore) {
          _comments.addAll(data);
        } else {
          _comments = data;
        }
        _commentTotal = total;
      });
      widget.onCommentsChanged?.call((_comments, _commentTotal));
    } catch (e) {
      debugPrint('获取番剧评论失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isCommentsLoading = false;
          _isLoadingMoreComments = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.extentAfter < 200 &&
            !_isLoadingMoreComments &&
            _hasMoreComments) {
          _fetchComments(loadMore: true);
        }
        return false;
      },
      child: CustomScrollView(slivers: _buildCommentsSlivers(context)),
    );
  }

  List<Widget> _buildCommentsSlivers(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_isCommentsLoading && _comments.isEmpty) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => const _CommentSkeletonItem(),
              childCount: 5,
            ),
          ),
        ),
      ];
    }
    if (_comments.isEmpty) {
      return [
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
        ),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            if (index >= _comments.length) {
              return const _CommentSkeletonItem();
            }
            return _CommentItem(comment: _comments[index], isDark: isDark);
          }, childCount: _comments.length + (_hasMoreComments ? 1 : 0)),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 16)),
    ];
  }
}

class _CommentSkeletonItem extends StatelessWidget {
  const _CommentSkeletonItem();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ShimmerCircle(size: 32),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ShimmerTextLine(height: 13, widthFactor: 0.36),
                    SizedBox(height: 6),
                    ShimmerTextLine(height: 11, widthFactor: 0.22),
                  ],
                ),
              ),
              SizedBox(width: 12),
              ShimmerBox(
                width: 32,
                height: 20,
                borderRadius: BorderRadius.all(Radius.circular(10)),
              ),
            ],
          ),
          SizedBox(height: 14),
          ShimmerTextLine(height: 13),
          SizedBox(height: 8),
          ShimmerTextLine(height: 13, widthFactor: 0.74),
        ],
      ),
    );
  }
}

/// 独立 StatelessWidget — 仅在自身数据变化时重建，避免整列表级联 rebuild
class _CommentItem extends StatelessWidget {
  final Map<String, dynamic> comment;
  final bool isDark;

  const _CommentItem({required this.comment, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final user = comment['user'] as Map<String, dynamic>? ?? const {};
    final nickname = user['nickname']?.toString() ?? '匿名';
    final avatarUrl = (user['avatar'] as Map?)?['medium']?.toString() ?? '';
    final content = comment['comment']?.toString() ?? '';
    final rate = comment['rate'] as int? ?? 0;
    final updatedAt = comment['updatedAt'] as int? ?? 0;
    final timeStr = updatedAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(updatedAt * 1000).toRelativeTime()
        : '';

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
                child: CachedNetworkImage(
                  imageUrl: avatarUrl,
                  width: 32,
                  height: 32,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => _avatarPlaceholder,
                  errorWidget: (_, _, _) => _avatarPlaceholder,
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
              if (rate > 0) _buildRateBadge(rate),
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

  Widget get _avatarPlaceholder => const ShimmerCircle(size: 32);

  Widget _buildRateBadge(int rate) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
          const Icon(Icons.star_rounded, color: Colors.amber, size: 12),
          const SizedBox(width: 2),
          Text(
            rate.toString(),
            style: const TextStyle(
              color: Colors.amber,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
