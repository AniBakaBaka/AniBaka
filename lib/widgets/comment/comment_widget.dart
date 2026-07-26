import 'dart:convert';

import 'package:baka/api/bgm.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/date_util.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/comment/comment_card.dart';
import 'package:baka/widgets/common/shimmer.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';

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

typedef _BgmReply = ({String name, String content});
typedef _BgmComment = ({
  String name,
  String avatarUrl,
  String content,
  List<String> images,
  int createdAt,
  List<_BgmReply> replies,
});
typedef _BgmSection = ({String episodeName, List<_BgmComment> comments});

_BgmComment? _parseBgmComment(Object? value) {
  if (value is! Map) return null;

  final user = value['user'] as Map?;
  final rawContent = value['content']?.toString() ?? '';
  final images = <String>[];
  final textWithoutImages = rawContent.replaceAllMapped(BgmUtils.bbImgPattern, (
    match,
  ) {
    final url = match.group(1)?.trim();
    if (url != null && url.isNotEmpty) images.add(url);
    return '';
  });
  final content = BgmUtils.cleanBbCode(textWithoutImages);
  if (content.isEmpty && images.isEmpty) return null;

  final replies = <_BgmReply>[];
  final rawReplies = value['replies'];
  if (rawReplies is List) {
    for (final reply in rawReplies.take(5)) {
      if (reply is! Map) continue;
      final replyUser = reply['user'] as Map?;
      final replyContent = BgmUtils.cleanBbCode(
        reply['content']?.toString() ?? '',
      );
      if (replyContent.isEmpty) continue;
      replies.add((
        name: replyUser?['nickname']?.toString() ?? '匿名',
        content: replyContent,
      ));
    }
  }

  return (
    name: user?['nickname']?.toString() ?? '匿名',
    avatarUrl: (user?['avatar'] as Map?)?['small']?.toString() ?? '',
    content: content,
    images: images,
    createdAt: BgmUtils.toInt(value['createdAt']) ?? 0,
    replies: replies,
  );
}

Future<void> handleCommentLinkTap({
  required String text,
  required String? url,
  required String title,
  required PlaybackController controller,
  required int currentPlayIndex,
  required List videoList,
  required Future<void> Function(int) onChangePlayIndex,
}) async {
  if (url == null) return;
  if (!url.startsWith('time://') && !url.startsWith('time_ep://')) {
    await launchUrlString(
      url.startsWith('gv') ? 'https://www.anibaka.com/play/$url' : url,
      mode: LaunchMode.externalApplication,
    );
    return;
  }

  var targetEpisode = currentPlayIndex;
  var seconds = 0;
  if (url.startsWith('time_ep://')) {
    final separator = url.indexOf('/', 10);
    if (separator > 10) {
      targetEpisode = (int.tryParse(url.substring(10, separator)) ?? 1) - 1;
      seconds = int.tryParse(url.substring(separator + 1)) ?? 0;
    }
  } else {
    seconds = int.tryParse(url.substring(7)) ?? 0;
  }

  if (seconds <= 0) {
    showSnackBar('无效的时间跳转值');
    return;
  }
  if (targetEpisode < 0 || targetEpisode >= videoList.length) {
    showSnackBar('无效的集数：${targetEpisode + 1}');
    return;
  }

  final targetTime = Duration(seconds: seconds);
  final changingEpisode = targetEpisode != currentPlayIndex;
  if (changingEpisode) await onChangePlayIndex(targetEpisode);
  controller.seek(targetTime);
  showSnackBar(
    changingEpisode
        ? '已跳转到第${targetEpisode + 1}集 ${targetTime.toTimeString()}'
        : '已跳转到 ${targetTime.toTimeString()}',
  );
}

class CommentAvatar extends StatelessWidget {
  const CommentAvatar({required this.url, this.size = 38, super.key});

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final baseColor = AppShimmer.defaultBaseColor(Theme.of(context));
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        memCacheWidth: (size * 2).round(),
        width: size,
        height: size,
        fit: BoxFit.cover,
        fadeInDuration: Duration.zero,
        placeholder: (_, _) => ColoredBox(color: baseColor),
        errorWidget: (_, _, _) => ColoredBox(
          color: baseColor,
          child: Icon(Icons.person_rounded, size: size * 0.58),
        ),
      ),
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

  final String? hintText;
  final bool isInline;
  final ValueChanged<String>? onSendComment;

  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      elevation: 0,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: const SafeArea(top: false, child: CommentInputWidget()),
      ),
    );
  }

  @override
  State<CommentInputWidget> createState() => _CommentInputWidgetState();
}

class _CommentInputWidgetState extends State<CommentInputWidget> {
  final _focusNode = FocusNode();
  final _controller = TextEditingController();
  bool _showEmoji = false;

  @override
  void initState() {
    super.initState();
    if (widget.isInline) _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!mounted) return;
    setState(() {
      if (!_focusNode.hasFocus) _showEmoji = false;
    });
  }

  void _insertEmoji(String emoji) {
    final value = _controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final text = value.text.replaceRange(selection.start, selection.end, emoji);
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: selection.start + emoji.length,
      ),
    );
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final callback = widget.onSendComment;
    if (callback == null) {
      Navigator.pop(context, text);
      return;
    }

    callback(text);
    _controller.clear();
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inline = widget.isInline;
    final showButtons = !inline || _focusNode.hasFocus;

    return Container(
      padding: EdgeInsets.fromLTRB(
        inline ? 12 : 10,
        inline ? 10 : 12,
        inline ? 12 : 10,
        inline ? 8 : 12,
      ),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: inline
            ? Border(
                top: BorderSide(
                  color: theme.dividerColor.withValues(alpha: 0.05),
                  width: 0.5,
                ),
              )
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (showButtons)
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 6),
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      setState(() => _showEmoji = !_showEmoji);
                    },
                    child: Icon(
                      Icons.emoji_emotions_outlined,
                      size: 26,
                      color: _showEmoji
                          ? theme.colorScheme.primary
                          : theme.textTheme.bodySmall?.color?.withValues(
                              alpha: 0.45,
                            ),
                    ),
                  ),
                ),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.dividerColor.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: TextField(
                    autofocus: !inline,
                    focusNode: _focusNode,
                    controller: _controller,
                    minLines: 1,
                    maxLines: inline ? 4 : 6,
                    textInputAction: TextInputAction.newline,
                    style: TextStyle(
                      fontSize: 15,
                      color: theme.textTheme.bodyMedium?.color,
                    ),
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      hintStyle: TextStyle(
                        fontSize: 14,
                        color: theme.textTheme.bodySmall?.color?.withValues(
                          alpha: 0.35,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (inline)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _controller,
                    builder: (context, value, _) {
                      final enabled = value.text.trim().isNotEmpty;
                      return GestureDetector(
                        onTap: enabled
                            ? () {
                                HapticFeedback.lightImpact();
                                _send();
                              }
                            : null,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: enabled
                                ? theme.colorScheme.primary
                                : theme.dividerColor.withValues(alpha: 0.08),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.arrow_upward_rounded,
                            size: 20,
                            color: enabled
                                ? Colors.white
                                : theme.textTheme.bodySmall?.color?.withValues(
                                    alpha: 0.3,
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: FilledButton(
                    onPressed: _send,
                    style: FilledButton.styleFrom(
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      minimumSize: const Size(0, 36),
                    ),
                    child: const Text('发送'),
                  ),
                ),
            ],
          ),
          if (_showEmoji)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  for (final emoji in _emojis)
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _insertEmoji(emoji);
                      },
                      child: Container(
                        height: 36,
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: theme.dividerColor.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Text(
                          emoji,
                          style: TextStyle(
                            fontSize: 14,
                            color: theme.colorScheme.primary,
                          ),
                        ),
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
  final Function(String, String, String)? onCommentLinkTap;
  final int? bgmSubjectId;
  final int? episodeIndex;
  final String? episodeName;

  @override
  State<CIslandCommentWidget> createState() => _CIslandCommentWidgetState();
}

class _CIslandCommentWidgetState extends State<CIslandCommentWidget> {
  final _commentKey = GlobalKey<CommentListState>();
  late Future<_BgmSection> _bgmRequest = _loadBgmComments();

  @override
  void didUpdateWidget(covariant CIslandCommentWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.bgmSubjectId != oldWidget.bgmSubjectId ||
        widget.episodeIndex != oldWidget.episodeIndex) {
      setState(() => _bgmRequest = _loadBgmComments());
    }
  }

  Future<_BgmSection> _loadBgmComments() async {
    final subjectId = widget.bgmSubjectId;
    final episodeIndex = widget.episodeIndex;
    final fallbackName = widget.episodeName ?? '';
    if (subjectId == null || episodeIndex == null) {
      return (episodeName: fallbackName, comments: const <_BgmComment>[]);
    }

    try {
      final episode = await BgmService.resolveEpisodeByIndex(
        subjectId,
        episodeIndex,
      );
      if (episode?.episodeId == null) {
        return (episodeName: fallbackName, comments: const <_BgmComment>[]);
      }

      final response = await getBgmEpisodeComments(episode!.episodeId!);
      final decoded = jsonDecode(response.data);
      final comments = <_BgmComment>[];
      if (decoded is List) {
        for (final value in decoded.take(30)) {
          final comment = _parseBgmComment(value);
          if (comment != null) comments.add(comment);
        }
      }
      return (episodeName: episode.name, comments: comments);
    } catch (error) {
      debugPrint('获取BGM剧集评论失败: $error');
      return (episodeName: fallbackName, comments: const <_BgmComment>[]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasBgm = widget.bgmSubjectId != null && widget.episodeIndex != null;

    return Column(
      children: [
        Expanded(
          child: FutureBuilder<_BgmSection>(
            future: _bgmRequest,
            builder: (context, snapshot) {
              final section = snapshot.data;
              final episodeName = section?.episodeName.isNotEmpty == true
                  ? section!.episodeName
                  : (widget.episodeName ?? '');
              final comments = section?.comments ?? const <_BgmComment>[];
              final loading =
                  hasBgm && snapshot.connectionState == ConnectionState.waiting;

              return CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        episodeName.isEmpty ? 'Baka 评论' : 'Baka · $episodeName',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverToBoxAdapter(
                      child: _buildSourceLabel('Baka', theme),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: CommentList(
                      key: _commentKey,
                      pid: widget.postId,
                      size: 100,
                      asSliver: true,
                      onTapLink: widget.onCommentLinkTap == null
                          ? null
                          : (text, url, title) {
                              if (url != null) {
                                widget.onCommentLinkTap!(text, url, title);
                              }
                            },
                    ),
                  ),
                  if (hasBgm) ...[
                    const SliverToBoxAdapter(child: SizedBox(height: 16)),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverToBoxAdapter(
                        child: _buildSourceLabel(
                          'Bangumi',
                          theme,
                          color: const Color(0xFFF09199),
                        ),
                      ),
                    ),
                    if (loading)
                      const SliverPadding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverToBoxAdapter(
                          child: AppShimmer(
                            child: CommentSkeleton(avatarSize: 36),
                          ),
                        ),
                      )
                    else if (comments.isEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        sliver: SliverToBoxAdapter(
                          child: Center(
                            child: Text(
                              '暂无剧评',
                              style: TextStyle(
                                fontSize: 13,
                                color: theme.textTheme.bodySmall?.color
                                    ?.withValues(alpha: 0.3),
                              ),
                            ),
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) =>
                                _buildBgmComment(comments[index], theme),
                            childCount: comments.length,
                            addAutomaticKeepAlives: false,
                          ),
                        ),
                      ),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                ],
              );
            },
          ),
        ),
        CommentInputWidget(
          isInline: true,
          onSendComment: (text) =>
              _commentKey.currentState?.sendComment(text, 0, ''),
        ),
      ],
    );
  }

  Widget _buildSourceLabel(String label, ThemeData theme, {Color? color}) {
    final badgeColor = color ?? theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: badgeColor,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Divider(
              height: 0.5,
              color: theme.dividerColor.withValues(alpha: 0.08),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBgmComment(_BgmComment comment, ThemeData theme) {
    final mutedColor = theme.textTheme.bodySmall?.color?.withValues(alpha: 0.4);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: CommentAvatar(url: comment.avatarUrl, size: 36),
          ),
          const SizedBox(width: 12),
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
                        comment.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: theme.textTheme.bodyLarge?.color,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF09199).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'BGM',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFF09199),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (comment.createdAt > 0)
                      Text(
                        DateTime.fromMillisecondsSinceEpoch(
                          comment.createdAt * 1000,
                        ).toRelativeTime(),
                        style: TextStyle(fontSize: 11, color: mutedColor),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                if (comment.content.isNotEmpty)
                  Text(
                    comment.content,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: theme.textTheme.bodyMedium?.color,
                    ),
                  ),
                if (comment.images.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final url in comment.images)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: CachedNetworkImage(
                              imageUrl: url,
                              memCacheWidth: 240,
                              width: 120,
                              height: 120,
                              fit: BoxFit.cover,
                              placeholder: (_, _) => ColoredBox(
                                color: AppShimmer.defaultBaseColor(theme),
                              ),
                              errorWidget: (_, _, _) => const SizedBox.shrink(),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 12,
                      color: mutedColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '来自 Bangumi · 无法回复',
                      style: TextStyle(fontSize: 11, color: mutedColor),
                    ),
                  ],
                ),
                if (comment.replies.isNotEmpty)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: theme.dividerColor.withValues(alpha: 0.04),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final reply in comment.replies)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${reply.name}: ',
                                    style: TextStyle(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                  TextSpan(
                                    text: reply.content,
                                    style: TextStyle(
                                      color: theme.textTheme.bodyMedium?.color
                                          ?.withValues(alpha: 0.8),
                                      fontSize: 13,
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Divider(
                    height: 0.5,
                    color: theme.dividerColor.withValues(alpha: 0.08),
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
