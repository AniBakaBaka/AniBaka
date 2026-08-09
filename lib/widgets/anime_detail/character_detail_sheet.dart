import 'dart:convert';
import 'dart:math' as math;

import 'package:baka/api/bgm.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/date_util.dart';
import 'package:baka/widgets/common/skeletonizer.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 统一的网络图片组件（封装 wsrv.nl 图片代理 + 缓存 + 错误处理）
class _NetImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final double borderRadius;
  final int proxyWidth;

  const _NetImage({
    required this.url,
    this.width,
    this.height,
    this.borderRadius = 0,
    this.proxyWidth = 240,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final proxyUrl = BgmUtils.bgmImageProxyUrl(url, width: proxyWidth);
    final fallbackBg = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.05);
    final iconColor = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.24);

    Widget child;
    if (proxyUrl.isEmpty) {
      child = Container(
        width: width,
        height: height,
        color: fallbackBg,
        alignment: Alignment.center,
        child: Icon(Icons.person_off, color: iconColor, size: (width != null && width! < 50) ? 18 : 32),
      );
    } else {
      child = CachedNetworkImage(
        imageUrl: proxyUrl,
        width: width,
        height: height,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        memCacheWidth: proxyWidth,
        placeholder: (_, _) => Container(
          width: width,
          height: height,
          color: fallbackBg,
        ),
        errorWidget: (_, _, _) => Container(
          width: width,
          height: height,
          color: fallbackBg,
          alignment: Alignment.center,
          child: Icon(Icons.person_off, color: iconColor, size: (width != null && width! < 50) ? 18 : 32),
        ),
      );
    }

    return borderRadius > 0
        ? ClipRRect(borderRadius: BorderRadius.circular(borderRadius), child: child)
        : child;
  }
}

/// 角色卡片（用于角色 Tab 的网格展示）
class CharacterCard extends StatelessWidget {
  final Map<String, dynamic> character;
  const CharacterCard({required this.character, super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final name = character['name']?.toString() ?? '未知';
    final role = character['role_name']?.toString();
    final voiceActor = (character['actors'] as List?)
            ?.map((actor) => (actor as Map)['name']?.toString())
            .where((v) => v != null && v.isNotEmpty)
            .join(' / ') ??
        '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 3 / 4,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: _NetImage(
              url: character['images']?['large']?.toString() ?? character['images']?['grid']?.toString() ?? '',
              borderRadius: 12,
              proxyWidth: 240,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          name,
          style: TextStyle(color: textColor, fontWeight: FontWeight.w600, fontSize: 13, height: 1.2),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (role != null && role.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            role,
            style: TextStyle(color: textColor.withValues(alpha: 0.6), fontSize: 11, height: 1.2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (voiceActor.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'CV: $voiceActor',
            style: TextStyle(color: textColor.withValues(alpha: 0.4), fontSize: 10, height: 1.2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// 角色 Tab 的网格布局
class CharactersSection extends StatelessWidget {
  final List<Map<String, dynamic>> characters;
  final ValueChanged<Map<String, dynamic>>? onCharacterTap;

  const CharactersSection({
    required this.characters,
    this.onCharacterTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = math.max(3, (constraints.maxWidth / 120).floor());
        final itemWidth = (constraints.maxWidth - (12 * (columns - 1))) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 24,
          children: characters.map((character) {
            return SizedBox(
              width: itemWidth,
              child: GestureDetector(
                onTap: () => onCharacterTap?.call(character),
                behavior: HitTestBehavior.opaque,
                child: CharacterCard(character: character),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

/// 显示角色详情弹窗的便捷方法
void showCharacterDetailSheet(BuildContext context, Map<String, dynamic> character) {
  final characterId = BgmUtils.toInt(
    character['id'] ?? character['character_id'] ?? character['characterId'],
  );
  if (characterId == null) return;
  HapticFeedback.selectionClick();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.8),
    builder: (_) => CharacterDetailSheet(
      characterId: characterId,
      initialData: character,
    ),
  );
}

/// 角色详情 + 评论底部弹窗
class CharacterDetailSheet extends StatefulWidget {
  final int characterId;
  final Map<String, dynamic>? initialData;

  const CharacterDetailSheet({
    required this.characterId,
    this.initialData,
    super.key,
  });

  @override
  State<CharacterDetailSheet> createState() => _CharacterDetailSheetState();
}

class _CharacterDetailSheetState extends State<CharacterDetailSheet> {
  Map<String, dynamic>? _charInfo;
  List<Map<String, dynamic>> _charComments = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // 秒开预览：优先保留外部传入的角色基础信息
    if (widget.initialData != null) {
      _charInfo = Map<String, dynamic>.from(widget.initialData!);
    }
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final results = await Future.wait([
        getBgmCharacterInfo(widget.characterId),
        getBgmCharacterComments(widget.characterId),
      ]);
      if (!mounted) return;

      final infoData = jsonDecode(results[0]) as Map<String, dynamic>;
      final commentsList = (jsonDecode(results[1]) as List<dynamic>)
          .cast<Map<String, dynamic>>();

      setState(() {
        if (infoData.isNotEmpty) {
          _charInfo = {
            if (_charInfo != null) ..._charInfo!,
            ...infoData,
          };
        }
        _charComments = commentsList;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('获取角色详情失败: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fgColor = isDark ? Colors.white : Colors.black;
    final textColor = isDark ? Colors.white : Colors.black87;
    final summary = _charInfo?['summary']?.toString().trim() ?? '';
    final hasBasicData = _charInfo != null && _charInfo!.isNotEmpty;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      snap: true,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF121212) : const Color(0xFFF9F9F9),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: (_isLoading && !hasBasicData)
              ? AppSkeletonizer(
                  enabled: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _CharHeader(
                          info: {
                            'name': '角色名称占位',
                            'nameCN': '角色中文名占位',
                            'role_name': '主角',
                            'actors': [
                              {'name': '声优名称占位'}
                            ],
                            'collects': 100,
                            'comment': 50,
                            'info': '性别: 女性\n生日: 1月1日',
                            'images': {'large': ''},
                          },
                        ),
                        const SizedBox(height: 24),
                        Text(
                          '这是一段用于自动骨架遮罩的角色详细介绍文本，展示真实的人物背景和设定描述...',
                          style: TextStyle(
                            color: textColor.withValues(alpha: 0.8),
                            fontSize: 14,
                            height: 1.7,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : CustomScrollView(
                  controller: scrollController,
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Center(
                        child: Container(
                          margin: const EdgeInsets.only(top: 12, bottom: 24),
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: fgColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                    if (_charInfo != null) SliverToBoxAdapter(child: _CharHeader(info: _charInfo!)),
                    if (summary.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                          child: Text(
                            summary,
                            style: TextStyle(
                              color: textColor.withValues(alpha: 0.8),
                              fontSize: 14,
                              height: 1.7,
                            ),
                          ),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Divider(color: fgColor.withValues(alpha: 0.05), height: 1),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                        child: Text(
                          '评论',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: textColor),
                        ),
                      ),
                    ),
                    if (_isLoading && _charComments.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(40),
                          child: Center(child: CircularProgressIndicator.adaptive()),
                        ),
                      )
                    else if (_charComments.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(40),
                          child: Center(
                            child: Text(
                              '暂无评论',
                              style: TextStyle(color: textColor.withValues(alpha: 0.4), fontSize: 13),
                            ),
                          ),
                        ),
                      )
                    else
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => _CharCommentItem(comment: _charComments[index]),
                          childCount: math.min(_charComments.length, 50),
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 32)),
                  ],
                ),
        );
      },
    );
  }
}

/// 角色头部信息
class _CharHeader extends StatelessWidget {
  final Map<String, dynamic> info;
  const _CharHeader({required this.info});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final name = info['name']?.toString() ?? info['nameCN']?.toString() ?? '未知';
    final nameCN = info['nameCN']?.toString() ?? '';
    final role = info['role_name']?.toString();
    final voiceActor = (info['actors'] as List?)
            ?.map((actor) => (actor as Map)['name']?.toString())
            .where((v) => v != null && v.isNotEmpty)
            .join(' / ') ??
        '';
    final collects = info['collects'] as int? ?? info['collects_count'] as int? ?? 0;
    final commentCount = info['comment'] as int? ?? info['comment_count'] as int? ?? 0;
    final infoStr = info['info']?.toString().replaceAll('\r\n', '\n').trim() ?? '';
    final imageUrl = (info['images'] as Map?)?['large']?.toString() ??
        (info['images'] as Map?)?['grid']?.toString() ??
        '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.15),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: _NetImage(
              url: imageUrl,
              width: 110,
              height: 154,
              borderRadius: 16,
              proxyWidth: 240,
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: textColor, height: 1.1),
                ),
                if (nameCN.isNotEmpty && nameCN != name) ...[
                  const SizedBox(height: 4),
                  Text(
                    nameCN,
                    style: TextStyle(fontSize: 13, color: textColor.withValues(alpha: 0.6)),
                  ),
                ],
                if (role != null && role.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '定位：$role',
                    style: TextStyle(fontSize: 12, color: textColor.withValues(alpha: 0.6)),
                  ),
                ],
                if (voiceActor.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'CV：$voiceActor',
                    style: TextStyle(fontSize: 12, color: textColor.withValues(alpha: 0.6)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (infoStr.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    infoStr,
                    style: TextStyle(fontSize: 12, color: textColor.withValues(alpha: 0.4), height: 1.35),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (collects > 0 || commentCount > 0) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (collects > 0)
                        _badge(Icons.favorite_rounded, '$collects', const Color(0xFFE57373)),
                      if (commentCount > 0)
                        _badge(Icons.chat_bubble_rounded, '$commentCount', const Color(0xFF64B5F6)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// 角色评论项
class _CharCommentItem extends StatelessWidget {
  final Map<String, dynamic> comment;
  const _CharCommentItem({required this.comment});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fgColor = isDark ? Colors.white : Colors.black;
    final textColor = isDark ? Colors.white : Colors.black87;
    final user = comment['user'] as Map<String, dynamic>? ?? const {};
    final nickname = user['nickname']?.toString() ?? '匿名';
    final content = comment['content']?.toString() ?? '';
    final createdAt = comment['createdAt'] as int? ?? 0;
    final replies = (comment['replies'] as List?) ?? const [];
    final timeStr = createdAt > 0 ? DateTime.fromMillisecondsSinceEpoch(createdAt * 1000).toRelativeTime() : '';
    final displayReplies = math.min(replies.length, 3);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _NetImage(
                url: (user['avatar'] as Map?)?['medium']?.toString() ?? '',
                width: 32,
                height: 32,
                borderRadius: 16,
                proxyWidth: 96,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nickname, style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w600)),
                    if (timeStr.isNotEmpty)
                      Text(timeStr, style: TextStyle(color: textColor.withValues(alpha: 0.4), fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
          if (content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 8),
              child: Text(
                BgmUtils.cleanBbCode(content).trim(),
                style: TextStyle(color: textColor.withValues(alpha: 0.85), fontSize: 13, height: 1.5),
              ),
            ),
          if (replies.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 10),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: fgColor.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (int i = 0; i < displayReplies; i++)
                      Padding(
                        padding: EdgeInsets.only(bottom: i < displayReplies - 1 ? 8 : 0),
                        child: _replyRichText(replies[i] as Map, textColor),
                      ),
                    if (replies.length > 3)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '还有 ${replies.length - 3} 条回复',
                          style: const TextStyle(color: Color(0xFF64B5F6), fontSize: 11, fontWeight: FontWeight.w500),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _replyRichText(Map reply, Color textColor) {
    final rNick = (reply['user'] as Map?)?['nickname']?.toString() ?? '匿名';
    final rContent = reply['content']?.toString() ?? '';
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$rNick  ',
            style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          TextSpan(
            text: BgmUtils.cleanBbCode(rContent).trim(),
            style: TextStyle(color: textColor.withValues(alpha: 0.6), fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }
}
