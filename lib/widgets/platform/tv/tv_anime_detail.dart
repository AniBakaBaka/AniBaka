import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/models/anime_detail_view_data.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/services/collection_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:baka/widgets/common/skeletonizer.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';

class TvAnimeDetailPlaceholder extends StatefulWidget {
  final Map data;

  const TvAnimeDetailPlaceholder({required this.data, super.key});

  @override
  State<TvAnimeDetailPlaceholder> createState() =>
      _TvAnimeDetailPlaceholderState();
}

class _TvAnimeDetailPlaceholderState extends State<TvAnimeDetailPlaceholder> {
  late BgmInfo _bgmInfo;
  Map<String, dynamic>? _detailData;
  late AnimeDetailViewData _detail;

  AnimeCollection? _collection;
  bool _isCollectionLoading = false;

  int? get _subjectId => _bgmInfo.subjectId;

  int? get _validPostId {
    final postId = BgmUtils.toInt(widget.data['id']);
    return (postId != null && postId > 0) ? postId : null;
  }

  void _rebuildDetail() {
    _bgmInfo = BgmUtils.readFromData(widget.data);
    _detailData = BgmUtils.asMap(widget.data['bgmDetailData']);
    _detail = AnimeDetailViewData.from(
      source: widget.data,
      bgmInfo: _bgmInfo,
      bgm: _detailData,
    );
  }

  @override
  void initState() {
    super.initState();
    _rebuildDetail();
    _fetchBgmData().then((_) {
      if (mounted) _fetchCollectionStatus();
    });
  }

  Future<void> _fetchBgmData() async {
    if (_detailData != null && _bgmInfo.subjectId != null) return;
    try {
      await BgmService.resolveFromData(widget.data);
      if (!mounted) return;
      setState(_rebuildDetail);

      final subjectId = _subjectId;
      if (subjectId == null || _detailData != null) return;

      final detail = await getBgmAnimeFullDetail(subjectId);
      if (!mounted || detail == null) return;

      widget.data['bgmDetailData'] = detail;
      setState(_rebuildDetail);
    } catch (e) {
      debugPrint('获取番剧详情失败: $e');
    }
  }

  Future<void> _fetchCollectionStatus() async {
    setState(() => _isCollectionLoading = true);
    AnimeCollection? collection;
    try {
      final bgmId = _subjectId;
      if (bgmId != null) {
        collection = await CollectionService.getByBgmId(bgmId);
      }
      if (collection == null) {
        final postId = _validPostId;
        if (postId != null) {
          collection = await CollectionService.getByPostId(postId);
        }
      }
    } catch (e) {
      debugPrint('获取收藏状态失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _collection = collection;
          _isCollectionLoading = false;
        });
      }
    }
  }

  Future<void> _updateCollectionStatus(CollectionStatus status) async {
    try {
      if (_collection != null && _collection!.status == status.value) {
        await _deleteCollection();
        return;
      }
      final col = AnimeCollection(
        postId: _validPostId,
        bgmId: _subjectId,
        status: status.value,
        postTitle: _detail.title,
        postCover: _detail.coverUrl,
        bgmImage: _bgmInfo.imageUrl,
        bgmTitle: _detail.title,
      );
      final result = await CollectionService.addOrUpdate(col);
      if (result != null && mounted) {
        setState(() => _collection = result);
        showSnackBar('已标记为「${status.label}」');
      }
    } catch (e) {
      debugPrint('更新收藏失败: $e');
      if (mounted) showSnackBar(e.toString(), isError: true);
    }
  }

  Future<void> _deleteCollection() async {
    if (_collection == null) return;
    try {
      final bgmId = _collection!.bgmId ?? _subjectId;
      bool success = false;
      if (bgmId != null) {
        success = await CollectionService.deleteByBgmId(bgmId);
      } else {
        final postId = _validPostId;
        if (postId != null) {
          success = await CollectionService.delete(postId);
        }
      }
      if (success && mounted) {
        setState(() => _collection = null);
        showSnackBar('已取消收藏');
      }
    } catch (e) {
      if (mounted) showSnackBar(e.toString(), isError: true);
    }
  }

  void _startWatching() {
    NavigationService.toPlayer(context, widget.data, autoMatch: true);
  }

  @override
  Widget build(BuildContext context) {
    final title = _detail.title;
    final summary = _detail.summary;
    final score = _detail.score;
    final cover = _detail.coverUrl;
    final tags = _detail.tags;
    final scoreCount = _detail.scoreCount;
    final alias = _detail.alias;

    return Scaffold(
      backgroundColor: context.tvBgColor,
      body: Focus(
        canRequestFocus: false,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.escape ||
                  event.logicalKey == LogicalKeyboardKey.goBack)) {
            Navigator.of(context).maybePop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (cover.isNotEmpty)
              Positioned.fill(
                child: CachedNetworkImage(
                  imageUrl: cover,
                  memCacheWidth: 960,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  filterQuality: FilterQuality.low,
                  placeholder: (_, _) =>
                      const ColoredBox(color: Color(0xFF141414)),
                  errorWidget: (_, _, _) =>
                      ColoredBox(color: context.tvShadowColor(0.87)),
                ),
              ),

            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    context.tvShadowColor(0.7),
                    context.tvShadowColor(0.9),
                  ],
                ),
              ),
            ),

            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(48),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 280,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TvFocusable(
                            autofocus: true,
                            onPressed: () => Navigator.of(context).maybePop(),
                            borderRadius: BorderRadius.circular(20),
                            enableScale: false,
                            enableGlow: false,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: context.tvHighlightColor(0.1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.arrow_back,
                                    color: context.tvTextSecondaryColor,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '返回',
                                    style: TextStyle(
                                      color: context.tvTextSecondaryColor,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),

                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: SizedBox(
                              width: 200,
                              height: 280,
                              child: cover.isNotEmpty
                                  ? CachedNetworkImage(
                                      imageUrl: cover,
                                      fit: BoxFit.cover,
                                      errorWidget: (_, _, _) =>
                                          _buildPlaceholderCover(),
                                    )
                                  : _buildPlaceholderCover(),
                            ),
                          ),
                          const SizedBox(height: 16),

                          if (score != null && score > 0)
                            Row(
                              children: [
                                const Icon(
                                  Icons.star,
                                  color: Colors.amber,
                                  size: 20,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  score.toStringAsFixed(1),
                                  style: TextStyle(
                                    color: context.tvTextColor,
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (scoreCount > 0) ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    '($scoreCount人)',
                                    style: TextStyle(
                                      color: context.tvTextHintColor,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(width: 40),

                    Expanded(
                      child: FocusTraversalGroup(
                        policy: ReadingOrderTraversalPolicy(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                color: context.tvTextColor,
                                fontSize: 32,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                                height: 1.2,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),

                            if (alias.isNotEmpty && alias != title)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  alias,
                                  style: TextStyle(
                                    color: context.tvTextSecondaryColor,
                                    fontSize: 16,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),

                            const SizedBox(height: 20),

                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                _buildActionButton(
                                  icon: Icons.play_arrow_rounded,
                                  label: '开始观看',
                                  color: Theme.of(context).colorScheme.primary,
                                  onPressed: _startWatching,
                                ),
                                _buildCollectionButton(),
                              ],
                            ),

                            const SizedBox(height: 24),

                            if (tags.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final tag in tags.take(10))
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: context.tvTextColor.withValues(
                                            alpha: 0.08,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                        ),
                                        child: Text(
                                          tag,
                                          style: TextStyle(
                                            color: context.tvTextSecondaryColor,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),

                            if (summary.isNotEmpty)
                              Expanded(
                                child: SingleChildScrollView(
                                  child: Text(
                                    summary,
                                    style: TextStyle(
                                      color: context.tvTextSecondaryColor,
                                      fontSize: 15,
                                      height: 1.7,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholderCover() {
    return Container(
      color: context.tvHighlightColor(0.05),
      child: Icon(Icons.movie, color: context.tvTextHintColor, size: 48),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return TvFocusable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollectionButton() {
    if (_isCollectionLoading) {
      return AppSkeletonizer(
        enabled: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: BoxDecoration(
            color: context.tvHighlightColor(0.06),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Text('收藏状态', style: TextStyle(fontSize: 14)),
        ),
      );
    }

    final hasCollection = _collection != null;
    final statusLabel = hasCollection
        ? (CollectionStatus.fromValue(_collection!.status)?.label ?? '已收藏')
        : '收藏';
    final icon = hasCollection ? Icons.favorite : Icons.favorite_border;
    final color = hasCollection
        ? Colors.pinkAccent
        : context.tvTextSecondaryColor;

    return TvFocusable(
      onPressed: () {
        if (hasCollection) {
          _deleteCollection();
        } else {
          _updateCollectionStatus(CollectionStatus.doing);
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 10),
            Text(
              statusLabel,
              style: TextStyle(
                color: color,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
