import 'dart:convert';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/widgets/common/shimmer.dart';

/// 角色卡片（用于角色 Tab 的网格展示）
class CharacterCard extends StatelessWidget {
  final Map<String, dynamic> character;
  const CharacterCard({required this.character, super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fgColor = isDark ? Colors.white : Colors.black;
    final textColor = isDark ? Colors.white : Colors.black87;
    final name = character['name']?.toString() ?? '未知';
    final imageUrl = character['images']?['large']?.toString() ?? '';
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
                BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08), blurRadius: 12, offset: const Offset(0, 4)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                memCacheWidth: 240,
                placeholder: (context, url) => const ShimmerBox(width: double.infinity, height: double.infinity, borderRadius: BorderRadius.all(Radius.circular(12))),
                errorWidget: (context, url, error) => Container(
                  color: fgColor.withValues(alpha: 0.05),
                  alignment: Alignment.center,
                  child: Icon(Icons.person_off, color: fgColor.withValues(alpha: 0.24), size: 32),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(name, style: TextStyle(color: textColor, fontWeight: FontWeight.w600, fontSize: 13, letterSpacing: 0.2, height: 1.2), maxLines: 1, overflow: TextOverflow.ellipsis),
        if (role != null && role.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(role, style: TextStyle(color: textColor.withValues(alpha: 0.6), fontSize: 11, height: 1.2), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
        if (voiceActor.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('CV: $voiceActor', style: TextStyle(color: textColor.withValues(alpha: 0.4), fontSize: 10, height: 1.2), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ],
    );
  }
}

/// 角色 Tab 的网格布局
class CharactersSection extends StatelessWidget {
  final List<Map<String, dynamic>> characters;
  final ValueChanged<Map<String, dynamic>>? onCharacterTap;
  const CharactersSection({required this.characters, this.onCharacterTap, super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      int columns = (constraints.maxWidth / 120).floor();
      if (columns < 3) columns = 3;
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
    });
  }
}

/// 显示角色详情弹窗的便捷方法
void showCharacterDetailSheet(BuildContext context, Map<String, dynamic> character) {
  final characterId = character['id'] as int?;
  if (characterId == null) return;
  HapticFeedback.selectionClick();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.8),
    builder: (_) => CharacterDetailSheet(characterId: characterId),
  );
}

/// 角色详情 + 评论底部弹窗
class CharacterDetailSheet extends StatefulWidget {
  final int characterId;
  const CharacterDetailSheet({required this.characterId, super.key});

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
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final results = await Future.wait([
        getBgmCharacterInfo(widget.characterId),
        getBgmCharacterComments(widget.characterId),
      ]);
      if (!mounted) return;
      final charInfo = BgmUtils.asMap(jsonDecode(results[0].data));
      final comments = BgmUtils.asMapList(jsonDecode(results[1].data));
      setState(() {
        _charInfo = charInfo;
        _charComments = comments;
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
          child: _isLoading
              ? const _CharacterDetailSkeleton()
              : CustomScrollView(
                  controller: scrollController,
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Center(
                        child: Container(
                          margin: const EdgeInsets.only(top: 12, bottom: 32),
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(color: fgColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(2)),
                        ),
                      ),
                    ),
                    if (_charInfo != null)
                      SliverToBoxAdapter(child: _CharHeader(info: _charInfo!)),
                    if (_charInfo?['summary'] != null && (_charInfo!['summary'] as String).isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
                          child: Text(
                            _charInfo!['summary'].toString().trim(),
                            style: TextStyle(color: textColor.withValues(alpha: 0.8), fontSize: 14, height: 1.8, letterSpacing: 0.3, fontWeight: FontWeight.w400),
                          ),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Divider(color: fgColor.withValues(alpha: 0.05), height: 1, thickness: 1),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                        child: Text('评论', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: textColor)),
                      ),
                    ),
                    if (_charComments.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(40),
                          child: Center(child: Text('暂无评论', style: TextStyle(color: textColor.withValues(alpha: 0.4), fontSize: 13))),
                        ),
                      )
                    else
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => _CharCommentItem(comment: _charComments[index]),
                          childCount: math.min(_charComments.length, 50),
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 48)),
                  ],
                ),
        );
      },
    );
  }
}

/// 角色头部信息 — 独立 Widget
class _CharHeader extends StatelessWidget {
  final Map<String, dynamic> info;
  const _CharHeader({required this.info});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fgColor = isDark ? Colors.white : Colors.black;
    final textColor = isDark ? Colors.white : Colors.black87;
    final name = info['name']?.toString() ?? '';
    final nameCN = info['nameCN']?.toString() ?? '';
    final imageUrl = (info['images'] as Map?)?['large']?.toString() ?? '';
    final collects = info['collects'] as int? ?? 0;
    final commentCount = info['comment'] as int? ?? 0;
    final infoStr = info['info']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 110,
            height: 154,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.15), blurRadius: 24, offset: const Offset(0, 12)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                memCacheWidth: 240,
                placeholder: (_, _) => const ShimmerBox(width: double.infinity, height: double.infinity, borderRadius: BorderRadius.all(Radius.circular(16))),
                errorWidget: (_, _, _) => Container(
                  color: fgColor.withValues(alpha: 0.05),
                  child: Icon(Icons.person_off, color: fgColor.withValues(alpha: 0.24), size: 40),
                ),
              ),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: textColor, letterSpacing: -0.5, height: 1.1)),
                if (nameCN.isNotEmpty && nameCN != name) ...[
                  const SizedBox(height: 6),
                  Text(nameCN, style: TextStyle(fontSize: 14, color: textColor.withValues(alpha: 0.6), fontWeight: FontWeight.w400)),
                ],
                if (infoStr.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    infoStr.replaceAll('\r\n', '\n').trim(),
                    style: TextStyle(fontSize: 12, color: textColor.withValues(alpha: 0.4), height: 1.4),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (collects > 0)
                      _badge(Icons.favorite_rounded, '$collects', const Color(0xFFE57373)),
                    if (commentCount > 0)
                      _badge(Icons.chat_bubble_rounded, '$commentCount', const Color(0xFF64B5F6)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// 角色评论项 — 独立 Widget 减少 SliverList 中每项的 rebuild 范围
class _CharCommentItem extends StatelessWidget {
  final Map<String, dynamic> comment;
  const _CharCommentItem({required this.comment});

  @override
  Widget build(BuildContext context) {
    final textColor = Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black87;
    final user = comment['user'] as Map<String, dynamic>? ?? const {};
    final nickname = user['nickname']?.toString() ?? '匿名';
    final avatarUrl = (user['avatar'] as Map?)?['medium']?.toString() ?? '';
    final content = comment['content']?.toString() ?? '';
    final createdAt = comment['createdAt'] as int? ?? 0;
    final replies = (comment['replies'] as List?) ?? const [];
    final timeStr = createdAt > 0 ? BgmUtils.formatRelativeTime(createdAt) : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
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
                  memCacheWidth: 96,
                  placeholder: (_, _) => const ShimmerCircle(size: 32),
                  errorWidget: (_, _, _) => const ShimmerCircle(size: 32),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nickname, style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w600)),
                    if (timeStr.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(timeStr, style: TextStyle(color: textColor.withValues(alpha: 0.4), fontSize: 11)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (content.isNotEmpty) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(left: 44),
              child: Text(BgmUtils.cleanBbCode(content).trim(), style: TextStyle(color: textColor.withValues(alpha: 0.85), fontSize: 13, height: 1.6)),
            ),
          ],
          if (replies.isNotEmpty) ...[
            const SizedBox(height: 12),
            _RepliesBlock(replies: replies),
          ],
        ],
      ),
    );
  }
}

/// 回复块
class _RepliesBlock extends StatelessWidget {
  final List<dynamic> replies;
  const _RepliesBlock({required this.replies});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fgColor = isDark ? Colors.white : Colors.black;
    final textColor = isDark ? Colors.white : Colors.black87;
    final displayCount = math.min(replies.length, 3);

    return Padding(
      padding: const EdgeInsets.only(left: 44),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: fgColor.withValues(alpha: 0.03), borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < displayCount; i++)
              Padding(
                padding: EdgeInsets.only(bottom: i < displayCount - 1 ? 10 : 0),
                child: _replyText(replies[i] as Map, textColor),
              ),
            if (replies.length > 3)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('还有 ${replies.length - 3} 条回复', style: const TextStyle(color: Color(0xFF64B5F6), fontSize: 11, fontWeight: FontWeight.w500)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _replyText(Map reply, Color textColor) {
    final rUser = reply['user'] as Map? ?? const {};
    final rNick = rUser['nickname']?.toString() ?? '匿名';
    final rContent = reply['content']?.toString() ?? '';
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(text: '$rNick  ', style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.w600)),
          TextSpan(text: BgmUtils.cleanBbCode(rContent).trim(), style: TextStyle(color: textColor.withValues(alpha: 0.6), fontSize: 12, height: 1.5)),
        ],
      ),
    );
  }
}

class _CharacterDetailSkeleton extends StatelessWidget {
  const _CharacterDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 48),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShimmerBox(
                width: 110,
                height: 154,
                borderRadius: BorderRadius.all(Radius.circular(16)),
              ),
              SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ShimmerBox(
                      width: 160,
                      height: 24,
                      borderRadius: BorderRadius.all(Radius.circular(6)),
                    ),
                    SizedBox(height: 8),
                    ShimmerBox(
                      width: 100,
                      height: 14,
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    SizedBox(height: 16),
                    ShimmerBox(
                      width: 80,
                      height: 28,
                      borderRadius: BorderRadius.all(Radius.circular(8)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 32),
          ShimmerBox(
            width: double.infinity,
            height: 12,
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
          SizedBox(height: 8),
          ShimmerBox(
            width: double.infinity,
            height: 12,
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
          SizedBox(height: 8),
          ShimmerBox(
            width: 200,
            height: 12,
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
          SizedBox(height: 32),
          ShimmerBox(
            width: 60,
            height: 18,
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
          SizedBox(height: 24),
          ShimmerCircle(size: 38),
          SizedBox(height: 12),
          ShimmerBox(
            width: double.infinity,
            height: 12,
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
          SizedBox(height: 8),
          ShimmerBox(
            width: 250,
            height: 12,
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
        ],
      ),
    );
  }
}
