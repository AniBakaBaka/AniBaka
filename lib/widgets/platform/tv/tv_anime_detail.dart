import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/api/collection.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/services/play_history_sync_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/reg_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/services/playback_settings_service.dart';
import 'package:baka/widgets/anime_detail/video_source_search_sheet.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/shimmer.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';

class TvAnimeDetailPlaceholder extends StatefulWidget {
  final Map data;

  const TvAnimeDetailPlaceholder({required this.data, super.key});

  @override
  State<TvAnimeDetailPlaceholder> createState() =>
      _TvAnimeDetailPlaceholderState();
}

class _TvAnimeDetailPlaceholderState extends State<TvAnimeDetailPlaceholder> {
  late final String _cardCoverUrl;
  late BgmInfo _bgmInfo;
  Map<String, dynamic>? _detailData;
  String? _bgmCoverUrl;
  String _displayCover = '';
  List<String> _tags = const [];

  AnimeCollection? _collection;
  bool _isCollectionLoading = false;

  int? get _subjectId => _bgmInfo.subjectId;

  int? get _validPostId {
    final postId = BgmUtils.toInt(widget.data['id']);
    return (postId != null && postId > 0) ? postId : null;
  }

  bool get _isLoggedIn => Instances.userToken.isNotEmpty;

  double? get _displayScore =>
      BgmUtils.extractScore(_detailData?['rating']) ?? _bgmInfo.score;

  int get _displayScoreCount =>
      BgmUtils.toInt(BgmUtils.asMap(_detailData?['rating'])?['total']) ?? 0;

  @override
  void initState() {
    super.initState();
    _cardCoverUrl = BgmUtils.resolveCoverImage(widget.data) ?? kDefaultImage;
    _refreshCachedData();
    _fetchBgmData().then((_) {
      if (mounted) _fetchCollectionStatus();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showSearchSheet();
    });
  }

  void _refreshCachedData() {
    _bgmInfo = BgmUtils.readFromData(widget.data);
    _detailData = BgmUtils.asMap(widget.data['bgmDetailData']);
    _bgmCoverUrl = BgmUtils.resolveCoverImage(widget.data, bgmInfo: _bgmInfo);
    _displayCover = _cardCoverUrl != kDefaultImage
        ? _cardCoverUrl
        : (_bgmCoverUrl ?? _cardCoverUrl);
    final tags = _detailData?['tags'];
    _tags = tags is List
        ? [
            for (final tag in tags)
              if (tag is Map && tag['name'] != null) tag['name'].toString(),
          ]
        : const [];
  }

  Future<void> _fetchBgmData() async {
    if (_detailData != null && _bgmInfo.subjectId != null) return;
    try {
      await BgmService.resolveFromData(widget.data);
      if (!mounted) return;
      setState(_refreshCachedData);

      final subjectId = _subjectId;
      if (subjectId == null || _detailData != null) return;

      final detail = await getBgmAnimeFullDetail(subjectId);
      if (!mounted || detail == null) return;

      widget.data['bgmDetailData'] = detail;
      setState(_refreshCachedData);
    } catch (e) {
      debugPrint('获取番剧详情失败: $e');
    }
  }

  Future<void> _fetchCollectionStatus() async {
    if (!_isLoggedIn) return;
    setState(() => _isCollectionLoading = true);
    AnimeCollection? collection;
    try {
      final bgmId = _subjectId;
      if (bgmId != null) {
        collection = await CollectionApi.getByBgmId(bgmId);
      }
      if (collection == null) {
        final postId = _validPostId;
        if (postId != null) {
          collection = await CollectionApi.getByPostId(postId);
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
    if (!_isLoggedIn) {
      showSnackBar('请先登录');
      return;
    }
    try {
      if (_collection != null && _collection!.status == status.value) {
        await _deleteCollection();
        return;
      }
      final col = AnimeCollection(
        postId: _validPostId,
        bgmId: _subjectId,
        status: status.value,
        postTitle: widget.data['title']?.toString() ?? '',
        postCover: _displayCover,
        bgmImage: _bgmInfo.imageUrl,
        bgmTitle:
            _detailData?['name_cn']?.toString() ??
            _detailData?['name']?.toString() ??
            widget.data['title']?.toString() ??
            '',
      );
      final result = await CollectionApi.addOrUpdate(col);
      if (result != null && mounted) {
        setState(() => _collection = result);
        showSnackBar('已标记为「${status.label}」');
      }
    } catch (e) {
      debugPrint('更新收藏失败: $e');
    }
  }

  Future<void> _deleteCollection() async {
    if (_collection == null) return;
    final bgmId = _collection!.bgmId ?? _subjectId;
    bool success = false;
    if (bgmId != null) {
      success = await CollectionApi.deleteByBgmId(bgmId);
    } else {
      final postId = _validPostId;
      if (postId != null) {
        success = await CollectionApi.delete(postId);
      }
    }
    if (success && mounted) {
      setState(() => _collection = null);
      showSnackBar('已取消收藏');
    }
  }

  void _showSearchSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => VideoSourceSearchSheet(
        title: widget.data['title'] ?? '',
        cover: _displayCover,
        score: _displayScore,
        scoreCount: _displayScoreCount > 0 ? _displayScoreCount : null,
        seedData: {
          if (_bgmInfo.subjectId != null) 'bgmId': _bgmInfo.subjectId,
          if (_displayScore != null) 'score': _displayScore,
          if (_bgmCoverUrl != null && _bgmCoverUrl!.isNotEmpty)
            'bgmImageUrl': _bgmCoverUrl,
          if (_detailData != null) 'bgmDetailData': _detailData,
        },
        autoMatchMode: PlaybackSettingsService.getAutoMatchSource(),
        headlessMode: false,
        targetEpisodeIndex:
            PlayHistorySyncService.getResumeSelection(
              widget.data,
            )?.episodeIndex ??
            0,
        onMatchFailed: () {
          showSnackBar('自动匹配失败，已切换至手动搜索');
        },
        heroTag: coverHeroTag(widget.data),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.data['title']?.toString() ?? '番剧详情';
    final summary = _detailData?['summary']?.toString() ?? '';
    final score = _displayScore;

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
            if (_displayCover.isNotEmpty)
              Positioned.fill(
                child: CachedNetworkImage(
                  imageUrl: _displayCover,
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
                              child: _displayCover.isNotEmpty
                                  ? CachedNetworkImage(
                                      imageUrl: _displayCover,
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
                                if (_displayScoreCount > 0) ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    '($_displayScoreCount人)',
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

                            if (_detailData?['name'] != null &&
                                _detailData!['name'] != title)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  _detailData!['name'].toString(),
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
                                  icon: Icons.search,
                                  label: '搜索视频源',
                                  color: Theme.of(context).colorScheme.primary,
                                  onPressed: _showSearchSheet,
                                ),
                                _buildCollectionButton(),
                              ],
                            ),

                            const SizedBox(height: 24),

                            if (_tags.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final tag in _tags.take(10))
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
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        decoration: BoxDecoration(
          color: context.tvHighlightColor(0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const ShimmerTextLine(width: 72, height: 14),
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
