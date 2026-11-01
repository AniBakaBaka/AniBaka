import 'package:baka/api/bgm.dart';
import 'package:baka/api/post.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/core/app_logger.dart';
import 'package:baka/core/content_filter.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/utils/reg_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/common/image_actions.dart';
import 'package:baka/widgets/common/skeletonizer.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher_string.dart';

const _bgmColor = Color(0xFFF09199);

const _emojis = [
  '(⊙﹏⊙)',
  '(＾o＾)ﾉ',
  '( ´∀`)',
  '(*´∀`)',
  '( ´ー`)',
  '(〃∀〃)',
  '( `д´)',
  '(`ヮ´ )',
  'Σ( ﾟдﾟ)',
  '( ☉д⊙)',
  '(￣∇￣)',
  '(￣皿￣)',
  '(￣艸￣)',
  '┃電柱┃',
];

final _bbImgRe = RegExp(r'\[img\](.*?)\[/img\]', caseSensitive: false);
final _timeLinkRe = RegExp(r'^time(?:_ep://(\d+)/|://)(\d+)$');
final _contentLinkRe = RegExp(
  r'```[\s\S]*?```|`[^`\n]*`|!?\[[^\[\]\n]*\]\([^\s()]*\)|https?://[^\s<>]+'
  r'|gv(\d+)'
  r'|[Pp](\d+)\s*(\d{1,2}:\d{2}(?::\d{2})?)'
  r'|\b(\d{1,2}:\d{2}(?::\d{2})?)\b',
);

int _seconds(String time) {
  var seconds = 0;
  for (final part in time.split(':')) {
    seconds = seconds * 60 + int.parse(part);
  }
  return seconds;
}

String _linkify(String content) =>
    content.replaceAllMapped(_contentLinkRe, (match) {
      if (match[1] != null) return '[${match[0]}](${match[0]})';
      if (match[2] case final episode?) {
        return '[${match[0]}](time_ep://$episode/${_seconds(match[3]!)})';
      }
      if (match[4] case final time?) return '[$time](time://${_seconds(time)})';
      return match[0]!;
    });

bool _isTimeLink(String url) =>
    url.startsWith('time://') || url.startsWith('time_ep://');

Future<void> _openLink(String url) => launchUrlString(
  url.startsWith('gv') ? 'https://www.anibaka.com/play/$url' : url,
  mode: LaunchMode.externalApplication,
);

Future<void> handleCommentLinkTap(
  String? url, {
  required PlaybackController controller,
  required int currentIndex,
  required int episodeCount,
  required Future<void> Function(int) onChangeEpisode,
}) async {
  if (url == null) return;
  if (!_isTimeLink(url)) {
    await _openLink(url);
    return;
  }
  final match = _timeLinkRe.firstMatch(url);
  final seconds = int.tryParse(match?[2] ?? '') ?? 0;
  if (seconds <= 0) {
    showSnackBar('无效的时间跳转值');
    return;
  }
  final episode = match![1] == null
      ? currentIndex
      : (int.tryParse(match[1]!) ?? 0) - 1;
  if (episode < 0 || episode >= episodeCount) {
    showSnackBar('无效的集数：${episode + 1}');
    return;
  }

  final target = Duration(seconds: seconds);
  final changing = episode != currentIndex;
  if (changing) await onChangeEpisode(episode);
  controller.seek(target);
  showSnackBar(
    changing
        ? '已跳转到第${episode + 1}集 ${target.toTimeString()}'
        : '已跳转到 ${target.toTimeString()}',
  );
}

Future<bool> sendComment(
  int pid,
  String text, {
  int rid = 0,
  String runame = '',
}) async {
  final content = text.trim();
  if (content.isEmpty) {
    showSnackBar('要写内容~');
    return false;
  }
  final user = apiTransport.session.user.value;
  if (!user.isLoggedIn) {
    showSnackBar(
      bangumiSession.isConnected
          ? 'Bangumi 登录不能回复 AniBaka 评论，请先登录 AniBaka'
          : '登录后才能评论~',
    );
    return false;
  }
  try {
    final sent = await addComment({
      'content': content,
      'pid': pid,
      'uid': user.id,
      'rid': rid,
      'runame': runame,
      'read': 0,
    });
    if (sent) showSnackBar('发射成功');
    return sent;
  } catch (error) {
    showSnackBar(error.toString());
    return false;
  }
}

Color _muted(ThemeData theme, [double alpha = 0.7]) =>
    theme.colorScheme.onSurfaceVariant.withValues(alpha: alpha);

Widget _avatar(String url, double size) => CircleAvatar(
  radius: size / 2,
  backgroundImage: url.isEmpty
      ? null
      : ResizeImage(CachedNetworkImageProvider(url), width: (size * 2).round()),
  onBackgroundImageError: url.isEmpty ? null : (_, _) {},
  child: url.isEmpty ? Icon(Icons.person_rounded, size: size * 0.6) : null,
);

Widget _commentDivider(ThemeData theme, {double indent = 0}) => Divider(
  height: 1,
  thickness: 0,
  indent: indent,
  color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
);

Widget _tag(String text, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
  decoration: BoxDecoration(
    color: color.withValues(alpha: 0.12),
    borderRadius: BorderRadius.circular(6),
  ),
  child: Text(
    text,
    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color),
  ),
);

Widget _tile(
  ThemeData theme, {
  required String avatar,
  required String name,
  required String time,
  required List<Widget> body,
  Color? nameColor,
  List<Widget> badges = const [],
  Widget? trailing,
}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 10),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _avatar(avatar, 36),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    spacing: 6,
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: nameColor,
                          ),
                        ),
                      ),
                      ...badges,
                      Text(
                        time,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: _muted(theme, 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 4),
            ...body,
          ],
        ),
      ),
    ],
  ),
);

Widget _replyBox(ThemeData theme, List<Widget> lines) => Container(
  width: double.infinity,
  margin: const EdgeInsets.only(top: 8),
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  decoration: BoxDecoration(
    color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
    borderRadius: BorderRadius.circular(12),
  ),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 6,
    children: [
      for (var i = 0; i < lines.length; i++) ...[
        if (i > 0) _commentDivider(theme),
        lines[i],
      ],
    ],
  ),
);

Widget _replyLine(
  ThemeData theme,
  String name,
  String content, {
  required String avatar,
  String? target,
}) {
  final strong = TextStyle(
    fontWeight: FontWeight.w600,
    color: theme.colorScheme.onSurface,
  );
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 8,
    children: [
      _avatar(avatar, 24),
      Expanded(
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: name, style: strong),
              if (target != null) ...[
                const TextSpan(text: ' 回复 '),
                TextSpan(text: target, style: strong),
              ],
              TextSpan(text: '：$content'),
            ],
          ),
          style: theme.textTheme.bodySmall?.copyWith(
            height: 1.5,
            color: _muted(theme, 1),
          ),
        ),
      ),
    ],
  );
}

/// 评论加载时使用真正的占位块，避免渲染假评论和 Markdown。
Widget _placeholder(ThemeData theme, int count) {
  final color = AppShimmer.defaultBaseColor(theme);
  Widget bar(double widthFactor, double height) => FractionallySizedBox(
    widthFactor: widthFactor,
    alignment: Alignment.centerLeft,
    child: Container(
      height: height,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
    ),
  );
  return Semantics(
    container: true,
    label: '正在加载评论',
    child: ExcludeSemantics(
      child: AppShimmer(
        child: Column(
          children: [
            for (var i = 0; i < count; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    CircleAvatar(radius: 18, backgroundColor: color),
                    Expanded(
                      child: Column(
                        children: [
                          bar(0.3, 12),
                          bar(i.isEven ? 0.92 : 0.8, 10),
                          bar(i.isEven ? 0.6 : 0.7, 10),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

final _savingImages = <String>{};

Future<void> _saveImage(String url) async {
  if (!_savingImages.add(url)) return;
  HapticFeedback.mediumImpact();
  try {
    final path = await saveImage(url);
    if (path != null) showSnackBar('保存图片路径：$path');
  } catch (_) {
    showSnackBar('图片保存失败，请重试', isError: true);
  } finally {
    _savingImages.remove(url);
  }
}

Widget _image(ThemeData theme, String url, BoxConstraints constraints) =>
    GestureDetector(
      onTap: () => previewImage(url),
      onLongPress: () => _saveImage(url),
      child: Container(
        constraints: constraints,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppShimmer.defaultBaseColor(theme),
          borderRadius: BorderRadius.circular(12),
        ),
        child: CachedNetworkImage(
          imageUrl: url,
          memCacheWidth: (constraints.maxWidth * 2).round(),
          fit: BoxFit.cover,
          placeholder: (_, _) => const SizedBox(width: 240, height: 160),
          errorWidget: (_, _, _) => const Icon(Icons.broken_image_outlined),
        ),
      ),
    );

Widget _hint(ThemeData theme, IconData icon, String text) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 40),
  child: Column(
    mainAxisSize: MainAxisSize.min,
    spacing: 8,
    children: [
      Icon(icon, size: 36, color: _muted(theme, 0.25)),
      Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(color: _muted(theme, 0.6)),
      ),
    ],
  ),
);

typedef CommentReplyCallback =
    Future<void> Function(String text, int rid, String runame);

/// AniBaka 评论的惰性 Sliver，直接嵌入 [CustomScrollView]，避免 shrinkWrap 全量构建。
/// [comments] 为 null 表示加载中；数据由调用方持有。
class CommentList extends StatelessWidget {
  const CommentList({
    required this.comments,
    required this.onReply,
    this.onTapLink,
    super.key,
  });

  final List<Map>? comments;
  final CommentReplyCallback onReply;
  final MarkdownTapLinkCallback? onTapLink;

  static final _styles = Expando<MarkdownStyleSheet>();

  // The comments API prepends the same global notice to every channel.
  static bool _isPinned(Map comment) =>
      comment['id'] == -1 && comment['pid'] == 0;

  static String _pinnedId(Map comment) =>
      'pinned_comment_${host}_${comment['id']}';

  static MarkdownStyleSheet _markdownStyle(ThemeData theme) {
    final scheme = theme.colorScheme;
    return MarkdownStyleSheet(
      p: theme.textTheme.bodyMedium?.copyWith(fontSize: 15, height: 1.6),
      a: TextStyle(color: scheme.primary, fontWeight: FontWeight.w500),
      code: TextStyle(
        fontFamily: 'Source Code Pro',
        fontSize: 13,
        backgroundColor: scheme.onSurface.withValues(alpha: 0.06),
      ),
      blockquote: TextStyle(color: _muted(theme)),
      blockquotePadding: const EdgeInsets.only(left: 12),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            width: 3,
            color: scheme.primary.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: contentVisibility,
    builder: (context, _) {
      final theme = Theme.of(context);
      final comments = this.comments;
      if (comments == null) {
        return SliverToBoxAdapter(child: _placeholder(theme, 3));
      }
      final pinned = comments.isNotEmpty && _isPinned(comments.first)
          ? comments.first
          : null;
      final start =
          pinned != null &&
              contentVisibility.isDismissed(
                _pinnedId(pinned),
                pinned['content'] as String? ?? '',
              )
          ? 1
          : 0;
      if (comments.length == start) {
        return SliverToBoxAdapter(
          child: start > 0
              ? null
              : _hint(theme, Icons.mode_comment_outlined, '留下第一条评论吧'),
        );
      }
      final style = _styles[theme] ??= _markdownStyle(theme);
      return SliverList.separated(
        itemCount: comments.length - start,
        addAutomaticKeepAlives: false,
        separatorBuilder: (_, _) => _commentDivider(theme, indent: 48),
        itemBuilder: (_, index) {
          final comment = comments[index + start];
          return _CommentCard(
            key: ValueKey(comment['id']),
            comment: comment,
            markdownStyle: style,
            onTapLink: onTapLink,
            onReply: onReply,
            onDismiss: _isPinned(comment)
                ? () => contentVisibility.dismiss(
                    _pinnedId(comment),
                    comment['content'] as String? ?? '',
                  )
                : null,
          );
        },
      );
    },
  );
}

class _CommentCard extends StatefulWidget {
  const _CommentCard({
    required this.comment,
    required this.markdownStyle,
    required this.onReply,
    this.onTapLink,
    this.onDismiss,
    super.key,
  });

  final Map comment;
  final MarkdownStyleSheet markdownStyle;
  final CommentReplyCallback onReply;
  final MarkdownTapLinkCallback? onTapLink;
  final VoidCallback? onDismiss;

  @override
  State<_CommentCard> createState() => _CommentCardState();
}

class _CommentCardState extends State<_CommentCard> {
  String? _content;
  MarkdownStyleSheet? _style;
  late Widget _body;
  bool _liking = false;

  void _onTapLink(String text, String? url, String title) {
    if (url == null) return;
    final onTapLink = widget.onTapLink;
    if (onTapLink != null) {
      onTapLink(text, url, title);
    } else if (!_isTimeLink(url)) {
      _openLink(url);
    }
  }

  void _delete(Object? id) => launchUrlString(
    '$host/comment/delete/$id?token=${apiTransport.session.token}',
  );

  Future<void> _reply(String runame) async {
    final text = await CommentInputWidget.show(context);
    if (text != null) {
      await widget.onReply(text, widget.comment['id'] as int, runame);
    }
  }

  Future<void> _like(String userName) async {
    if (_liking) return;
    _liking = true;
    try {
      widget.comment['uv'] = await updateCommentUv(
        widget.comment['id'],
        userName,
      );
      if (mounted) setState(() {});
    } catch (_) {
      showSnackBar('操作失败');
    } finally {
      _liking = false;
    }
  }

  Widget _action(
    ThemeData theme,
    IconData icon,
    VoidCallback onTap, [
    Color? color,
  ]) => IconButton(
    onPressed: () {
      HapticFeedback.selectionClick();
      onTap();
    },
    visualDensity: VisualDensity.compact,
    iconSize: 17,
    color: color ?? _muted(theme, 0.5),
    icon: Icon(icon),
  );

  @override
  Widget build(BuildContext context) {
    final comment = widget.comment;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final content = comment['content'] as String? ?? '';
    if (content != _content || _style != widget.markdownStyle) {
      _content = content;
      _style = widget.markdownStyle;
      // Keep selection while avoiding one EditableText/Scrollable per paragraph.
      _body = SelectionArea(
        child: MarkdownBody(
          data: _linkify(content),
          onTapLink: _onTapLink,
          styleSheet: widget.markdownStyle,
          imageBuilder: (uri, _, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _image(
              theme,
              uri.toString(),
              const BoxConstraints(maxWidth: 240, maxHeight: 300),
            ),
          ),
        ),
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final isVip = (comment['uviptime'] as num? ?? 0) > now;
    final isUp = (comment['ulevel'] as num? ?? 0) > 1;
    final accent = isUp
        ? scheme.secondary
        : isVip
        ? scheme.primary
        : null;
    final user = apiTransport.session.user.value;
    final likes = comment['uv'] as String? ?? '';
    final liked = user.isLoggedIn && likes.contains(user.name);
    final replies = (comment['replies'] as List? ?? const []).cast<Map>();
    final name = comment['uname'] as String? ?? '匿名';

    return _tile(
      theme,
      avatar: getAvatar(avatar: comment['uqq'] ?? ''),
      name: name,
      nameColor: accent,
      time: DateTime.parse(comment['time'] as String).toRelativeTime(),
      badges: [
        if (accent != null)
          SvgPicture.asset(
            isVip ? 'assets/dahuiyuan.svg' : 'assets/upzhu.svg',
            width: 14,
            height: 14,
            colorFilter: ColorFilter.mode(accent, BlendMode.srcIn),
          ),
        if (widget.onDismiss != null) _tag('置顶', scheme.primary),
      ],
      trailing: widget.onDismiss == null
          ? null
          : IconButton(
              tooltip: '关闭置顶评论，内容更新后再次显示',
              onPressed: widget.onDismiss,
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              color: _muted(theme, 0.5),
              icon: const Icon(Icons.close_rounded),
            ),
      body: [
        _body,
        if (user.isLoggedIn)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (user.level > 1 || user.id == comment['uid'])
                _action(
                  theme,
                  Icons.delete_outline_rounded,
                  () => _delete(comment['id']),
                ),
              _action(
                theme,
                liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                () => _like(user.name),
                liked ? scheme.primary : null,
              ),
              _action(
                theme,
                Icons.chat_bubble_outline_rounded,
                () => _reply(name),
              ),
            ],
          ),
        if (likes.isNotEmpty || replies.isNotEmpty)
          _replyBox(theme, [
            if (likes.isNotEmpty)
              Text.rich(
                TextSpan(
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Icon(
                        Icons.favorite_rounded,
                        size: 13,
                        color: scheme.primary,
                      ),
                    ),
                    TextSpan(text: ' $likes'),
                  ],
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _muted(theme),
                ),
              ),
            for (final reply in replies.reversed)
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  _reply(reply['uname'] as String? ?? '');
                },
                onDoubleTap: () {
                  HapticFeedback.mediumImpact();
                  _delete(reply['id']);
                },
                child: _replyLine(
                  theme,
                  reply['uname'] as String? ?? '',
                  '${reply['content'] ?? ''}',
                  avatar: getAvatar(avatar: reply['uqq'] ?? ''),
                  target: switch (reply['runame']) {
                    final String target
                        when target.isNotEmpty && target != name =>
                      target,
                    _ => null,
                  },
                ),
              ),
          ]),
      ],
    );
  }
}

class CommentInputWidget extends StatefulWidget {
  const CommentInputWidget({
    super.key,
    this.hintText = '发个友好的文字见证当下',
    this.isInline = false,
    this.onSendComment,
  });

  final String hintText;
  final bool isInline;
  final ValueChanged<String>? onSendComment;

  static Future<String?> show(BuildContext context) =>
      showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: const SafeArea(top: false, child: CommentInputWidget()),
        ),
      );

  @override
  State<CommentInputWidget> createState() => _CommentInputWidgetState();
}

class _CommentInputWidgetState extends State<CommentInputWidget> {
  final _controller = TextEditingController();
  bool _showEmoji = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _insertEmoji(String emoji) {
    final value = _controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    _controller.value = TextEditingValue(
      text: value.text.replaceRange(selection.start, selection.end, emoji),
      selection: TextSelection.collapsed(
        offset: selection.start + emoji.length,
      ),
    );
  }

  void _send() {
    final text = _controller.text.trim();
    final callback = widget.onSendComment;
    if (callback == null) {
      Navigator.pop(context, text);
      return;
    }
    HapticFeedback.lightImpact();
    callback(text);
    _controller.clear();
    FocusScope.of(context).unfocus();
    setState(() => _showEmoji = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: widget.isInline
          ? BoxDecoration(
              color: theme.scaffoldBackgroundColor,
              border: Border(
                top: BorderSide(
                  color: theme.dividerColor.withValues(alpha: 0.08),
                ),
              ),
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 8,
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  autofocus: !widget.isInline,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: widget.hintText,
                    isDense: true,
                    filled: true,
                    fillColor: scheme.onSurface.withValues(alpha: 0.05),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon: IconButton(
                      tooltip: '颜文字',
                      onPressed: () => setState(() => _showEmoji = !_showEmoji),
                      color: _showEmoji ? scheme.primary : null,
                      icon: const Icon(Icons.emoji_emotions_outlined),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: ValueListenableBuilder(
                  valueListenable: _controller,
                  builder: (_, value, _) => IconButton.filled(
                    tooltip: '发送',
                    onPressed: value.text.trim().isEmpty ? null : _send,
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                ),
              ),
            ],
          ),
          if (_showEmoji)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(top: 8),
                children: [
                  for (final emoji in _emojis)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        label: Text(emoji),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onPressed: () => _insertEmoji(emoji),
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

typedef _BgmReply = ({String name, String avatarUrl, String content});
typedef _BgmComment = ({
  String name,
  String avatarUrl,
  String content,
  List<String> images,
  int createdAt,
  List<_BgmReply> replies,
});
typedef _BgmSection = ({
  int episodeId,
  String episodeName,
  List<_BgmComment> comments,
});

String _bgmAvatarUrl(Map? user) => user == null
    ? ''
    : BgmUtils.bgmImageProxyUrl(
        (user['avatar'] as Map)['medium'] as String,
        width: 120,
      );

/// Fields follow the p1 `getEpisodeComments` schema; only `user` is optional.
/// https://github.com/bangumi/dev-docs/blob/master/api.yaml
_BgmComment? _parseBgmComment(Map<String, dynamic> value) {
  final images = <String>[];
  final content = BgmUtils.cleanBbCode(
    (value['content'] as String).replaceAllMapped(_bbImgRe, (match) {
      final url = match[1]!.trim();
      if (url.isNotEmpty) images.add(url);
      return '';
    }),
  );
  if (content.isEmpty && images.isEmpty) return null;

  final user = value['user'] as Map<String, dynamic>?;
  return (
    name: user?['nickname'] as String? ?? '匿名',
    avatarUrl: _bgmAvatarUrl(user),
    content: content,
    images: images,
    createdAt: value['createdAt'] as int,
    replies: [
      for (final reply
          in (value['replies'] as List).take(5).cast<Map<String, dynamic>>())
        if (BgmUtils.cleanBbCode(reply['content'] as String) case final text
            when text.isNotEmpty)
          (
            name: (reply['user'] as Map?)?['nickname'] as String? ?? '匿名',
            avatarUrl: _bgmAvatarUrl(reply['user'] as Map?),
            content: text,
          ),
    ],
  );
}

Widget _bgmTile(ThemeData theme, _BgmComment comment) => _tile(
  theme,
  avatar: comment.avatarUrl,
  name: comment.name,
  time: DateTime.fromMillisecondsSinceEpoch(
    comment.createdAt * 1000,
  ).toRelativeTime(),
  body: [
    if (comment.content.isNotEmpty)
      Text(
        comment.content,
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
      ),
    if (comment.images.isNotEmpty)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final url in comment.images)
              _image(theme, url, BoxConstraints.tight(const Size.square(120))),
          ],
        ),
      ),
    if (comment.replies.isNotEmpty)
      _replyBox(theme, [
        for (final reply in comment.replies)
          _replyLine(theme, reply.name, reply.content, avatar: reply.avatarUrl),
      ]),
  ],
);

/// 聚合 Baka 与 Bangumi 两个来源的评论。
class CIslandCommentWidget extends StatefulWidget {
  const CIslandCommentWidget({
    required this.postId,
    this.onCommentLinkTap,
    this.bgmSubjectId,
    this.episodeIndex,
    this.episodeName,
    super.key,
  });

  final int postId;
  final MarkdownTapLinkCallback? onCommentLinkTap;
  final int? bgmSubjectId;
  final int? episodeIndex;
  final String? episodeName;

  @override
  State<CIslandCommentWidget> createState() => _CIslandCommentWidgetState();
}

class _CIslandCommentWidgetState extends State<CIslandCommentWidget>
    with AutomaticKeepAliveClientMixin<CIslandCommentWidget> {
  late Future<List<Map>> _comments = _loadComments();
  late Future<_BgmSection?> _bgm = _loadBgmComments();

  @override
  bool get wantKeepAlive => true;

  bool get _hasBgm =>
      widget.bgmSubjectId != null && widget.episodeIndex != null;

  @override
  void didUpdateWidget(covariant CIslandCommentWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.postId != oldWidget.postId) _comments = _loadComments();
    if (widget.bgmSubjectId != oldWidget.bgmSubjectId ||
        widget.episodeIndex != oldWidget.episodeIndex) {
      _bgm = _loadBgmComments();
    }
  }

  Future<List<Map>> _loadComments() async {
    try {
      return await getComments(widget.postId, 100);
    } catch (error) {
      Log.w('Comment', '获取评论失败: $error');
      return const [];
    }
  }

  Future<_BgmSection?> _loadBgmComments() async {
    final subjectId = widget.bgmSubjectId;
    final index = widget.episodeIndex;
    if (subjectId == null || subjectId <= 0 || index == null || index < 0) {
      return null;
    }
    try {
      final episodes = await getBgmEpisodes(subjectId);
      if (index >= episodes.length) return null;
      final episode = episodes[index];
      final id = episode['id'] as int;
      final comments = <_BgmComment>[];
      for (final value in (await getBgmEpisodeComments(id)).take(30)) {
        if (_parseBgmComment(value) case final comment?) comments.add(comment);
      }
      final nameCn = (episode['name_cn'] as String).trim();
      return (
        episodeId: id,
        episodeName: nameCn.isEmpty
            ? (episode['name'] as String).trim()
            : nameCn,
        comments: comments,
      );
    } catch (error) {
      Log.w('Comment', '获取BGM剧集评论失败: $error');
      return null;
    }
  }

  Future<void> _reply(String text, int rid, String runame) async {
    if (await sendComment(widget.postId, text, rid: rid, runame: runame) &&
        mounted) {
      setState(() => _comments = _loadComments());
    }
  }

  Future<void> _send(String text) async {
    if (apiTransport.session.token.isNotEmpty || !bangumiSession.isConnected) {
      return _reply(text, 0, '');
    }

    final section = await _bgm;
    if (section == null) {
      showSnackBar('当前条目无法定位到 Bangumi 剧集', isError: true);
      return;
    }
    if (!mounted) return;
    final confirmed = await showAppConfirmDialog(
      context,
      title: '前往 Bangumi 发表评论',
      content:
          'Bangumi 官方公开 API 暂不提供评论发布接口。AniBaka 将复制你输入的内容，并打开对应的 Bangumi 官方剧集页，由你确认发布。\n\n'
          '打开 Bangumi 可能需要网络代理。Bangumi 登录不能回复 AniBaka 评论；如需站内回复和云端历史，推荐登录 AniBaka。',
      confirmText: '复制并打开',
      cancelText: '取消',
    );
    if (!confirmed) return;

    try {
      await Clipboard.setData(ClipboardData(text: text));
      final opened = await launchUrlString(
        'https://bgm.tv/ep/${section.episodeId}',
        mode: LaunchMode.externalApplication,
      );
      showSnackBar(
        opened ? '评论内容已复制，请在 Bangumi 页面粘贴并发布' : '无法打开浏览器',
        isError: !opened,
      );
    } catch (error) {
      showSnackBar(error.toString(), isError: true);
    }
  }

  Widget _section(ThemeData theme, String label, Color color, [String? note]) =>
      SliverPadding(
        padding: const EdgeInsets.only(top: 16, bottom: 2),
        sliver: SliverToBoxAdapter(
          child: Row(
            spacing: 8,
            children: [
              _tag(label, color),
              if (note != null)
                Text(
                  note,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _muted(theme, 0.5),
                  ),
                ),
              Expanded(
                child: Divider(
                  height: 1,
                  color: theme.dividerColor.withValues(alpha: 0.08),
                ),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);

    return Column(
      children: [
        Expanded(
          child: FutureBuilder<_BgmSection?>(
            future: _bgm,
            builder: (context, bgm) {
              final name = bgm.data?.episodeName ?? '';
              final episodeName = name.isNotEmpty
                  ? name
                  : widget.episodeName ?? '';
              final bgmComments = bgm.data?.comments ?? const <_BgmComment>[];
              return CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    sliver: SliverMainAxisGroup(
                      slivers: [
                        SliverToBoxAdapter(
                          child: Text(
                            episodeName.isEmpty
                                ? 'Baka 评论'
                                : 'Baka · $episodeName',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        _section(theme, 'Baka', theme.colorScheme.primary),
                        FutureBuilder<List<Map>>(
                          key: ValueKey(widget.postId),
                          future: _comments,
                          builder: (_, comments) => CommentList(
                            comments: comments.data,
                            onReply: _reply,
                            onTapLink: widget.onCommentLinkTap,
                          ),
                        ),
                        if (_hasBgm) ...[
                          _section(theme, 'Bangumi', _bgmColor, '仅查看'),
                          if (bgm.connectionState == ConnectionState.waiting)
                            SliverToBoxAdapter(child: _placeholder(theme, 2))
                          else if (bgmComments.isEmpty)
                            SliverToBoxAdapter(
                              child: _hint(theme, Icons.forum_outlined, '暂无剧评'),
                            )
                          else
                            SliverList.separated(
                              itemCount: bgmComments.length,
                              addAutomaticKeepAlives: false,
                              separatorBuilder: (_, _) =>
                                  _commentDivider(theme, indent: 48),
                              itemBuilder: (_, index) =>
                                  _bgmTile(theme, bgmComments[index]),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        CommentInputWidget(isInline: true, onSendComment: _send),
      ],
    );
  }
}
