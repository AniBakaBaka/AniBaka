import 'dart:convert';

import 'package:baka/api/post.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/bangumi_sync_service.dart';
import 'package:baka/services/network_service.dart';
import 'package:baka/utils/date_util.dart';
import 'package:baka/utils/image_utils.dart';
import 'package:baka/utils/reg_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:baka/widgets/common/skeletonizer.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher_string.dart';

Color? _commentMutedColor(ThemeData theme, {double alpha = 0.35}) =>
    theme.textTheme.bodySmall?.color?.withValues(alpha: alpha);

class CommentTile extends StatelessWidget {
  const CommentTile({
    required this.name,
    required this.avatar,
    required this.nameColor,
    required this.time,
    required this.content,
    this.badge,
    this.replies,
    this.actions,
    this.avatarSize = 40,
    this.avatarPadding = 4,
    this.spacing = 14,
    this.showDivider = false,
    super.key,
  });

  final String name;
  final Widget avatar;
  final Color? nameColor;
  final String time;
  final Widget content;
  final Widget? badge;
  final Widget? replies;
  final Widget? actions;
  final double avatarSize;
  final double avatarPadding;
  final double spacing;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: showDivider ? 4 : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: avatarPadding),
            child: avatar,
          ),
          SizedBox(width: spacing),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          letterSpacing: showDivider ? 0.2 : 0,
                          color: nameColor,
                        ),
                      ),
                    ),
                    if (badge case final badge?) ...[
                      const SizedBox(width: 6),
                      badge,
                    ],
                    const SizedBox(width: 8),
                    if (time.isNotEmpty)
                      Text(
                        time,
                        style: TextStyle(
                          fontSize: showDivider ? 12 : 11,
                          letterSpacing: showDivider ? 0.2 : 0,
                          fontWeight: showDivider ? FontWeight.w500 : null,
                          color: _commentMutedColor(
                            Theme.of(context),
                            alpha: showDivider ? 0.35 : 0.4,
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(height: showDivider ? 6 : 4),
                content,
                ?actions,
                ?replies,
                if (showDivider)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Divider(
                      height: 0.5,
                      color: Theme.of(
                        context,
                      ).dividerColor.withValues(alpha: 0.08),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class CommentList extends StatefulWidget {
  const CommentList({
    required this.pid,
    this.comments,
    this.size,
    this.onTapLink,
    this.autoLoad = true,
    this.asSliver = false,
    super.key,
  });

  final int pid;
  final List? comments;
  final int? size;
  final Function(String, String?, String)? onTapLink;
  final bool autoLoad;

  /// 嵌入 [CustomScrollView] 时直接生成惰性 Sliver，避免 shrinkWrap 全量构建。
  final bool asSliver;

  @override
  State<CommentList> createState() => CommentListState();
}

class CommentListState extends State<CommentList> {
  static final _contentLinkPattern = RegExp(
    r'gv(\d+)'
    r'|[Pp](\d+)\s*(\d{1,2}:\d{2}(?::\d{2})?)'
    r'|\b(\d{1,2}:\d{2}(?::\d{2})?)\b',
  );

  late final Map userInfo = getUserInfo();
  List? _internalComments;
  int _requestSerial = 0;
  late MarkdownStyleSheet _markdownStyle;
  ThemeData? _markdownTheme;

  List? get _effectiveComments => widget.comments ?? _internalComments;
  bool get needsLoad => _effectiveComments == null;
  List get comments => _effectiveComments ?? const [];

  @override
  void initState() {
    super.initState();
    if (widget.comments == null && widget.autoLoad) _loadComments();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    if (_markdownTheme == theme) return;
    _markdownTheme = theme;
    _markdownStyle = MarkdownStyleSheet(
      blockquotePadding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            width: 3,
            color: theme.colorScheme.primary.withValues(alpha: 0.3),
          ),
        ),
      ),
      blockquote: TextStyle(
        fontSize: 14,
        fontStyle: FontStyle.italic,
        color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
      ),
      code: const TextStyle(fontFamily: 'Source Code Pro', fontSize: 13),
      a: TextStyle(
        color: theme.colorScheme.primary,
        decoration: TextDecoration.none,
        fontWeight: FontWeight.w500,
      ),
      p: TextStyle(
        fontSize: 15,
        height: 1.6,
        letterSpacing: 0.2,
        color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.95),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant CommentList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pid != oldWidget.pid && widget.comments == null) {
      _internalComments = null;
      _loadComments();
    }
  }

  Future<void> _loadComments() async {
    final requestSerial = ++_requestSerial;
    List result;

    try {
      final response = await getComments(widget.pid, widget.size ?? 80, '');
      final decoded = jsonDecode(response);
      result = processCommentsList(
        decoded is Map ? decoded['data'] as List? : null,
      );
    } catch (error) {
      debugPrint('获取评论失败: $error');
      result = [];
    }

    if (!mounted || requestSerial != _requestSerial) return;
    setState(() => _internalComments = result);
  }

  static int _timeToSeconds(String value) {
    var seconds = 0;
    for (final part in value.split(':')) {
      seconds = seconds * 60 + int.parse(part);
    }
    return seconds;
  }

  static String processContent(String content) {
    return content.replaceAllMapped(_contentLinkPattern, (match) {
      final gv = match.group(1);
      if (gv != null) return '[${match.group(0)}](${match.group(0)})';

      final episode = match.group(2);
      final episodeTime = match.group(3);
      if (episode != null && episodeTime != null) {
        return '[${match.group(0)}](time_ep://$episode/${_timeToSeconds(episodeTime)})';
      }

      final time = match.group(4);
      return time == null
          ? match.group(0)!
          : '[$time](time://${_timeToSeconds(time)})';
    });
  }

  /// 接口数据只预处理一次；原地更新可避免为整棵回复树创建副本。
  static List processCommentsList(List? data) {
    if (data == null || data.isEmpty) return [];

    for (final item in data) {
      if (item is! Map) continue;
      final content = item['content'];
      if (content != null) item['content'] = processContent(content.toString());

      final replies = item['replies'];
      if (replies is! List) continue;
      for (final reply in replies) {
        if (reply is Map && reply['content'] != null) {
          reply['content'] = processContent(reply['content'].toString());
        }
      }
    }
    return data;
  }

  void setComments(List newComments) {
    if (!mounted) return;
    setState(() => _internalComments = newComments);
  }

  static final Map<String, dynamic> _dummyComment = {
    'uname': '用户名称占位符',
    'time': '2026-08-06 12:00:00',
    'content': '这是一条用于自动骨架遮罩的占位评论内容文本，展示真实的评论排版。',
    'uqq': '',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final comments = _effectiveComments;

    if (comments == null) {
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final loading = AppSkeletonizer(
        enabled: true,
        child: Column(
          children: List.generate(
            3,
            (_) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _buildCommentItem(
                context,
                _dummyComment,
                theme,
                _markdownStyle,
                nowSeconds,
              ),
            ),
          ),
        ),
      );
      return widget.asSliver ? SliverToBoxAdapter(child: loading) : loading;
    }

    if (comments.isEmpty) {
      final empty = Padding(
        padding: const EdgeInsets.symmetric(vertical: 64),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.mode_comment_outlined,
              size: 42,
              color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.1),
            ),
            const SizedBox(height: 16),
            Text(
              '留下第一条评论吧...',
              style: TextStyle(
                fontSize: 14,
                letterSpacing: 0.5,
                color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.4),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
      return widget.asSliver ? SliverToBoxAdapter(child: empty) : empty;
    }

    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Widget buildComment(int index) => _buildCommentItem(
      context,
      comments[index] as Map,
      theme,
      _markdownStyle,
      nowSeconds,
    );

    Widget buildSeparator() => Padding(
      padding: const EdgeInsets.only(left: 54, right: 16, top: 8, bottom: 12),
      child: Divider(
        height: 0.5,
        color: theme.dividerColor.withValues(alpha: 0.08),
      ),
    );

    if (widget.asSliver) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) =>
              index.isEven ? buildComment(index ~/ 2) : buildSeparator(),
          childCount: comments.length * 2 - 1,
          addAutomaticKeepAlives: false,
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      addAutomaticKeepAlives: false,
      itemCount: comments.length,
      itemBuilder: (_, index) => buildComment(index),
      separatorBuilder: (_, _) => buildSeparator(),
    );
  }

  Widget _buildCommentItem(
    BuildContext context,
    Map comment,
    ThemeData theme,
    MarkdownStyleSheet markdownStyle,
    int nowSeconds,
  ) {
    final isVip = (comment['uviptime'] as num? ?? 0) > nowSeconds;
    final isUp = (comment['ulevel'] as num? ?? 0) > 1;
    final nameColor = isUp
        ? theme.colorScheme.secondary
        : isVip
        ? theme.colorScheme.primary
        : (theme.textTheme.bodyLarge?.color ?? theme.colorScheme.onSurface);
    final mutedColor = theme.textTheme.bodySmall?.color?.withValues(
      alpha: 0.35,
    );
    final userName = userInfo['name']?.toString();
    final likes = comment['uv']?.toString() ?? '';
    final isLiked = userName != null && likes.contains(userName);
    final replies = comment['replies'] is List
        ? comment['replies'] as List
        : const [];

    final avatar = Stack(
      clipBehavior: Clip.none,
      children: [
        CommentAvatar(url: getAvatar(avatar: comment['uqq'] ?? ''), size: 40),
        if (isVip || isUp)
          Positioned(
            right: -2,
            bottom: -2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.scaffoldBackgroundColor,
              ),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: SvgPicture.asset(
                  isVip ? 'assets/dahuiyuan.svg' : 'assets/upzhu.svg',
                  width: 12,
                  height: 12,
                  colorFilter: ColorFilter.mode(nameColor, BlendMode.srcIn),
                ),
              ),
            ),
          ),
      ],
    );

    return CommentTile(
      avatar: avatar,
      avatarPadding: 4,
      name: comment['uname']?.toString() ?? '匿名',
      nameColor: nameColor,
      time: DateTime.parse(comment['time']).toEnDate(),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarkdownBody(
            selectable: true,
            data: comment['content']?.toString() ?? '',
            onTapLink: (text, url, title) {
              if (url == null) return;
              if (widget.onTapLink != null) {
                widget.onTapLink!(text, url, title);
              } else if (!url.startsWith('time')) {
                launchUrlString(
                  url.startsWith('gv')
                      ? 'https://www.anibaka.com/play/$url'
                      : url,
                  mode: LaunchMode.externalApplication,
                );
              }
            },
            styleSheetTheme: MarkdownStyleSheetBaseTheme.platform,
            styleSheet: markdownStyle,
            sizedImageBuilder: (config) =>
                _buildMarkdownImage(config.uri, theme),
          ),
          const SizedBox(height: 10),
          if ((userInfo['id'] as num? ?? 0) != 0)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if ((userInfo['level'] as num? ?? 0) > 1 ||
                    userInfo['id'] == comment['uid']) ...[
                  _buildActionButton(
                    icon: Icons.delete_outline_rounded,
                    color: mutedColor,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      launchUrlString(
                        '$host/comment/delete/${comment['id']}?token=${Instances.userToken}',
                      );
                    },
                  ),
                  const SizedBox(width: 16),
                ],
                _buildActionButton(
                  icon: isLiked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: isLiked ? theme.colorScheme.primary : mutedColor,
                  onTap: () async {
                    HapticFeedback.selectionClick();
                    try {
                      final response = await updateCommentUv(
                        comment['id'],
                        userName,
                      );
                      if (!mounted) return;
                      comment['uv'] = jsonDecode(response)['msg'];
                      setState(() {});
                    } catch (_) {
                      showSnackBar('操作失败');
                    }
                  },
                ),
                const SizedBox(width: 16),
                _buildActionButton(
                  icon: Icons.chat_bubble_outline_rounded,
                  color: mutedColor,
                  onTap: () async {
                    HapticFeedback.selectionClick();
                    final result = await CommentInputWidget.show(context);
                    if (result != null) {
                      await sendComment(
                        result,
                        comment['id'] as int,
                        comment['uname']?.toString() ?? '',
                      );
                    }
                  },
                ),
              ],
            ),
          if (replies.isNotEmpty || likes.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.only(left: 14, top: 4, bottom: 4),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: theme.colorScheme.primary.withValues(alpha: 0.15),
                    width: 2,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (likes.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.favorite_rounded,
                            size: 14,
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.7,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              likes,
                              style: TextStyle(
                                color: theme.textTheme.bodySmall?.color
                                    ?.withValues(alpha: 0.6),
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (final reply in replies.reversed)
                    if (reply is Map) _buildReplyItem(reply, comment, theme),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildReplyItem(Map reply, Map parentComment, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8, top: 2),
            child: CommentAvatar(
              url: getAvatar(avatar: reply['uqq'] ?? ''),
              size: 24,
            ),
          ),
          Expanded(
            child: GestureDetector(
              onDoubleTap: () {
                HapticFeedback.mediumImpact();
                launchUrlString(
                  '$host/comment/delete/${reply['id']}?token=${Instances.userToken}',
                );
              },
              onTap: () async {
                HapticFeedback.lightImpact();
                final result = await CommentInputWidget.show(context);
                if (result != null) {
                  await sendComment(
                    result,
                    parentComment['id'] as int,
                    reply['uname']?.toString() ?? '',
                  );
                }
              },
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: reply['uname']?.toString() ?? '',
                      style: TextStyle(
                        color: theme.textTheme.bodyMedium?.color?.withValues(
                          alpha: 0.9,
                        ),
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        letterSpacing: 0.2,
                      ),
                    ),
                    if (reply['runame'] != null &&
                        reply['runame'] != (parentComment['uname'] ?? '')) ...[
                      TextSpan(
                        text: ' 回复 ',
                        style: TextStyle(
                          color: theme.textTheme.bodySmall?.color?.withValues(
                            alpha: 0.4,
                          ),
                          fontSize: 12,
                        ),
                      ),
                      TextSpan(
                        text: reply['runame'].toString(),
                        style: TextStyle(
                          color: theme.textTheme.bodyMedium?.color?.withValues(
                            alpha: 0.9,
                          ),
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                    TextSpan(
                      text: '  ${reply['content'] ?? ''}',
                      style: TextStyle(
                        color: theme.textTheme.bodySmall?.color?.withValues(
                          alpha: 0.8,
                        ),
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMarkdownImage(Uri uri, ThemeData theme) {
    final url = uri.toString();
    return GestureDetector(
      onTap: () => ImageUtils.previewImage(url),
      onLongPress: () async {
        HapticFeedback.mediumImpact();
        final path = await ImageUtils.saveImageToGallery(url);
        if (path != null) showSnackBar('保存图片路径：$path');
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        clipBehavior: Clip.antiAlias,
        constraints: const BoxConstraints(maxWidth: 240, maxHeight: 300),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
        child: CachedNetworkImage(
          imageUrl: url,
          memCacheWidth: 480,
          fit: BoxFit.cover,
          fadeInDuration: const Duration(milliseconds: 200),
          placeholder: (_, _) => ColoredBox(
            color: AppShimmer.defaultBaseColor(theme),
            child: const SizedBox(width: 240, height: 160),
          ),
          errorWidget: (_, _, _) => ColoredBox(
            color: theme.dividerColor.withValues(alpha: 0.03),
            child: const Center(child: Icon(Icons.broken_image_outlined)),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required Color? color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }

  Future<void> sendComment(String text, int rid, String runame) async {
    final content = text.trim();
    if (content.isEmpty) {
      showSnackBar('要写内容~');
      return;
    }
    if ((userInfo['id'] as num? ?? 0) == 0) {
      showSnackBar(
        BangumiSyncService.instance.isConnected
            ? 'Bangumi 登录不能回复 AniBaka 评论，请先登录 AniBaka'
            : '登录后才能评论~',
      );
      return;
    }

    try {
      final response = await addComment({
        'content': content,
        'pid': widget.pid,
        'uid': userInfo['id'],
        'rid': rid,
        'runame': runame,
        'read': 0,
      });
      if (jsonDecode(response)['code'] == 200) {
        showSnackBar('发射成功');
        await _loadComments();
      }
    } catch (error) {
      showSnackBar(error.toString());
    }
  }
}
