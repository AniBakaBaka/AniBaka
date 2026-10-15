import 'package:baka/core/content_filter.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/utils/json_values.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/api/anibaka_api.dart';
import 'package:baka/models/anime_detail_view_data.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/app/navigation.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/anime_detail/video_source_search_sheet.dart';
import 'package:baka/widgets/platform/tv/tv_episode_selector.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/widgets/platform/tv/tv_theme_util.dart';

class TvAnimeDetailPlaceholder extends StatefulWidget {
  final Map data;
  final List<PlaybackEpisode>? episodes;

  const TvAnimeDetailPlaceholder({
    required this.data,
    this.episodes,
    super.key,
  });

  @override
  State<TvAnimeDetailPlaceholder> createState() =>
      _TvAnimeDetailPlaceholderState();
}

class _TvAnimeDetailPlaceholderState extends State<TvAnimeDetailPlaceholder> {
  late BgmInfo _bgmInfo;
  late AnimeDetailViewData _detail;
  late List<PlaybackEpisode> _videoList;

  AnimeCollection? _collection;
  bool _isCollectionLoading = false;
  bool _showEpisodeSelector = false;

  int? get _subjectId => _bgmInfo.subjectId;

  // Enrich only at the navigation boundary; rendering shares the input data.
  PlaybackRequest get _playbackRequest => PlaybackRequest.fromMap(
    widget.data,
    metadataUpdates: {
      'nsfw': _detail.nsfw,
      if (_subjectId != null) 'bgmId': _subjectId,
      if (_bgmInfo.score != null) 'score': _bgmInfo.score,
      if (_bgmInfo.imageUrl != null) 'bgmImageUrl': _bgmInfo.imageUrl,
      if (_detail.logoUrl.isNotEmpty) 'logoUrl': _detail.logoUrl,
    },
  );

  int? get _validPostId => AnimeCollection.postIdFrom(widget.data);

  @override
  void initState() {
    super.initState();
    _bgmInfo = BgmInfo.fromData(widget.data);
    final bgm = (widget.data['bgmDetailData'] as Map?)?.cast<String, dynamic>();
    _detail = AnimeDetailViewData.from(
      source: widget.data,
      bgmInfo: _bgmInfo,
      bgm: bgm,
    );
    _videoList =
        widget.episodes ?? PlaybackEpisodeCatalog.episodesOf(widget.data);
    _fetchBgmData();
  }

  Future<void> _fetchBgmData() async {
    try {
      if (_bgmInfo.subjectId == null) {
        _bgmInfo = await resolveBgmFromData(widget.data);
        if (!mounted) return;
      }

      _fetchCollectionStatus();
      final subjectId = _subjectId;
      if (subjectId == null) return;

      final (bgm, anibaka, episodes) = await (
        getBgmSubject(subjectId),
        AniBakaApi.getAnimeDetail(subjectId).catchError((Object error) {
          debugPrint('获取 AniBaka 详情失败: $error');
          return null;
        }),
        _videoList.isEmpty
            ? getBgmEpisodes(subjectId)
            : Future.value(const <Map<String, dynamic>>[]),
      ).wait;
      if (!mounted) return;

      final detail = AnimeDetailViewData.from(
        source: widget.data,
        bgmInfo: _bgmInfo,
        anibaka: anibaka,
        bgm: bgm,
      );
      if (episodes.isNotEmpty) {
        _videoList = [
          for (final episode in episodes)
            PlaybackEpisode(
              title:
                  '${episode['sort'] as num}. ${(episode['name_cn'] as String).isEmpty ? episode['name'] as String : episode['name_cn'] as String}',
              lines: const [],
            ),
        ];
      }
      setState(() => _detail = detail);
    } catch (e) {
      debugPrint('获取番剧数据失败: $e');
    }
  }

  Future<void> _fetchCollectionStatus() async {
    setState(() => _isCollectionLoading = true);
    AnimeCollection? collection;
    try {
      final bgmId = _subjectId;
      if (bgmId != null) {
        collection = await collections.getByBgmId(bgmId);
      }
      if (collection == null) {
        final postId = _validPostId;
        if (postId != null) {
          collection = await collections.getByPostId(postId);
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
        nsfw: _detail.nsfw,
        postTitle: _detail.title,
        postCover: _detail.coverUrl,
        bgmImage: _bgmInfo.imageUrl,
        bgmTitle: _detail.title,
      );
      final result = await collections.addOrUpdate(col);
      if (mounted) {
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
        success = await collections.deleteByBgmId(bgmId);
      } else {
        final postId = _validPostId;
        if (postId != null) {
          success = await collections.delete(postId);
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
    NavigationService.toPlayback(context, _playbackRequest);
  }

  String _formatNumber(int number) {
    if (number <= 0) return '0';
    final str = number.toString();
    final reg = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    return str.replaceAllMapped(reg, (Match m) => '${m[1]},');
  }

  String _collectionStatusText() {
    if (_isCollectionLoading) return '加载中...';
    if (_collection == null) return '未收藏';
    return CollectionStatus.fromValue(_collection!.status)?.label ?? '已在看';
  }

  String _buildAirDateText() {
    final date = _detail.airDate;
    if (date != null && date.isNotEmpty) {
      final parts = date.split('-');
      if (parts.length >= 2) {
        final year = parts[0];
        final month = int.tryParse(parts[1]) ?? parts[1];
        return '$year 年 $month 月';
      }
      return date;
    }
    return '';
  }

  String _buildEpisodeStatusText() {
    final status = _detail.status;
    final eps = _detail.episodeCount;
    if (eps != null && eps > 0) {
      return status.isEmpty ? '全 $eps 话' : '$status · 全 $eps 话';
    }
    return status;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: contentFilter,
    builder: (context, _) => _buildPage(context),
  );

  Widget _buildPage(BuildContext context) {
    if (contentFilter.value && _detail.nsfw) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('已隐藏 NSFW 内容')),
      );
    }
    final title = _detail.title;
    final alias = _detail.alias;
    final bgUrl = _detail.backgroundUrl;

    return Scaffold(
      backgroundColor: context.tvBgColor,
      body: Focus(
        canRequestFocus: false,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.escape ||
                  event.logicalKey == LogicalKeyboardKey.goBack)) {
            if (_showEpisodeSelector) {
              setState(() => _showEpisodeSelector = false);
              return KeyEventResult.handled;
            }
            Navigator.of(context).maybePop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (bgUrl.isNotEmpty)
              Positioned.fill(
                child: CachedNetworkImage(
                  imageUrl: bgUrl,
                  memCacheWidth: 1920,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  filterQuality: FilterQuality.medium,
                  placeholder: (_, _) => ColoredBox(color: context.tvBgColor),
                  errorWidget: (_, _, _) =>
                      ColoredBox(color: context.tvShadowColor(0.87)),
                ),
              ),

            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent, // 上方 100% 透明
                      context.tvBgColor.withValues(alpha: 0.1),
                      context.tvBgColor.withValues(alpha: 0.4),
                      context.tvBgColor.withValues(alpha: 0.75),
                      context.tvBgColor.withValues(alpha: 0.95), // 底部阴影沉淀
                    ],
                    stops: const [0.0, 0.35, 0.60, 0.82, 1.0],
                  ),
                ),
              ),
            ),

            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 40,
                  vertical: 36,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildLeftSidebar(),

                    const SizedBox(width: 36),

                    Expanded(
                      child: FocusTraversalGroup(
                        policy: ReadingOrderTraversalPolicy(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildTitleOrLogo(title, _detail.logoUrl),

                            if (alias.isNotEmpty && alias != title)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  alias.toUpperCase(),
                                  style: TextStyle(
                                    color: context.tvTextSecondaryColor
                                        .withValues(alpha: 0.8),
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 1.2,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),

                            const SizedBox(height: 16),

                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      _buildAirDateText(),
                                      style: TextStyle(
                                        color: context.tvTextColor,
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _buildEpisodeStatusText(),
                                      style: TextStyle(
                                        color: context.tvTextSecondaryColor
                                            .withValues(alpha: 0.8),
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(width: 28),
                                _buildStatCounter(
                                  count: _detail.collectCount,
                                  label: '收藏',
                                ),
                                const SizedBox(width: 20),
                                _buildStatCounter(
                                  count: _detail.doingCount,
                                  label: '在看',
                                ),
                                const SizedBox(width: 20),
                                _buildStatCounter(
                                  count: _detail.wishCount,
                                  label: '想看',
                                ),
                              ],
                            ),

                            const Spacer(),

                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: TvFocusable(
                                        onPressed: () {
                                          if (_collection != null) {
                                            _deleteCollection();
                                          } else {
                                            _updateCollectionStatus(
                                              CollectionStatus.doing,
                                            );
                                          }
                                        },
                                        borderRadius: BorderRadius.circular(6),
                                        enableScale: false,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 2,
                                          ),
                                          child: Text(
                                            _collectionStatusText(),
                                            style: TextStyle(
                                              color: context
                                                  .tvTextSecondaryColor
                                                  .withValues(alpha: 0.9),
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        _buildIconButton(
                                          icon: Icons.play_arrow_rounded,
                                          autofocus: true,
                                          onPressed: _startWatching,
                                        ),
                                        const SizedBox(width: 16),
                                        _buildIconButton(
                                          icon: Icons.grid_view_rounded,
                                          onPressed: () {
                                            setState(() {
                                              _showEpisodeSelector = true;
                                            });
                                          },
                                        ),
                                        const SizedBox(width: 16),
                                        _buildIconButton(
                                          icon: Icons.open_in_new_rounded,
                                          onPressed: () {
                                            VideoSourceSearchSheet.show(
                                              context,
                                              seedData:
                                                  _playbackRequest.metadata,
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),

                                const Spacer(),

                                _buildRightBottomPanel(),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            if (_showEpisodeSelector)
              Positioned.fill(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  color: Colors.black.withValues(alpha: 0.5),
                  child: TvEpisodeSelector(
                    videoList: _videoList,
                    currentIndex: 0,
                    currUrl: 1,
                    bgmId: _subjectId ?? _detail.bgmId,
                    tmdbId: toInt(_detail.tmdbId),
                    tvdbId: _detail.tvdbId,
                    onEpisodeSelected: (index) {
                      setState(() {
                        _showEpisodeSelector = false;
                      });
                      NavigationService.toPlayback(
                        context,
                        _playbackRequest,
                        posIndex: index,
                        autoMatch: true,
                      );
                    },
                    onClose: () {
                      setState(() {
                        _showEpisodeSelector = false;
                      });
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeftSidebar() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        _buildSideIcon(
          icon: Icons.arrow_back_rounded,
          onPressed: () {
            Navigator.of(context).maybePop();
          },
        ),
        const SizedBox(height: 20),
        _buildSideIcon(
          icon: _collection != null
              ? Icons.star_rounded
              : Icons.star_outline_rounded,
          color: _collection != null ? Colors.amber : null,
          onPressed: () {
            if (_collection != null) {
              _deleteCollection();
            } else {
              _updateCollectionStatus(CollectionStatus.doing);
            }
          },
        ),
      ],
    );
  }

  Widget _buildSideIcon({
    required IconData icon,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return TvFocusable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(20),
      focusScale: 1.15,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Icon(
          icon,
          color: color ?? context.tvTextSecondaryColor.withValues(alpha: 0.8),
          size: 22,
        ),
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback onPressed,
    bool autofocus = false,
  }) {
    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(30),
      focusScale: 1.1,
      child: Container(
        width: 58,
        height: 58,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: context.tvTextColor.withValues(alpha: 0.1),
          border: Border.all(
            color: context.tvTextColor.withValues(alpha: 0.2),
            width: 1.5,
          ),
        ),
        child: Icon(icon, color: context.tvTextColor, size: 30),
      ),
    );
  }

  Widget _buildStatCounter({required int count, required String label}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _formatNumber(count),
          style: TextStyle(
            color: context.tvTextColor,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: context.tvTextSecondaryColor.withValues(alpha: 0.8),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildRightBottomPanel() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            child: _buildTagsWall(alignRight: true),
          ),
        ),
        const SizedBox(width: 24),
        _buildScorePanel(),
      ],
    );
  }

  Widget _buildTagsWall({bool alignRight = false}) {
    final tags = _detail.tags;
    if (tags.isEmpty) return const SizedBox.shrink();

    return Wrap(
      alignment: alignRight ? WrapAlignment.end : WrapAlignment.start,
      spacing: 8,
      runSpacing: 8,
      children: tags.take(8).map((tag) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: context.tvTextColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            tag,
            style: TextStyle(
              color: context.tvTextColor.withValues(alpha: 0.9),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildRatingHistogram() {
    final counts = _detail.scoreDistribution;

    int maxCount = counts.fold(0, (max, c) => c > max ? c : max);
    if (maxCount == 0) maxCount = 1;

    const double maxBarHeight = 58.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          height: maxBarHeight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(10, (index) {
              final count = counts[index];
              final ratio = count / maxCount;
              final barHeight = (ratio * maxBarHeight).clamp(6.0, maxBarHeight);
              final isHigh = index >= 7;

              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 3.5),
                width: 13,
                height: barHeight,
                decoration: BoxDecoration(
                  color: isHigh
                      ? const Color(0xFF1DE9B6).withValues(alpha: 0.85)
                      : context.tvTextColor.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(4),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(10, (index) {
            return SizedBox(
              width: 20,
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.tvTextSecondaryColor.withValues(alpha: 0.8),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildScorePanel() {
    final score = _detail.score ?? 0.0;
    final scoreCount = _detail.scoreCount;
    final rank = _detail.rank;

    final starRating = (score / 2.0).clamp(0.0, 5.0);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_detail.hasScoreDistribution) ...[
          _buildRatingHistogram(),
          const SizedBox(width: 24),
        ],
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  score > 0 ? score.toStringAsFixed(1) : 'N/A',
                  style: TextStyle(
                    color: context.tvTextColor,
                    fontSize: 48,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: List.generate(5, (i) {
                        final starVal = i + 1;
                        IconData icon;
                        if (starRating >= starVal) {
                          icon = Icons.star_rounded;
                        } else if (starRating >= starVal - 0.5) {
                          icon = Icons.star_half_rounded;
                        } else {
                          icon = Icons.star_outline_rounded;
                        }
                        return Icon(
                          icon,
                          color: const Color(0xFFFFC107),
                          size: 18,
                        );
                      }),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${rank != null && rank > 0 ? '#$rank · ' : ''}${_formatNumber(scoreCount)} 人评分',
                      style: TextStyle(
                        color: context.tvTextSecondaryColor.withValues(
                          alpha: 0.8,
                        ),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTitleOrLogo(String title, String logoUrl) {
    if (logoUrl.isNotEmpty) {
      return Container(
        height: 85,
        alignment: Alignment.centerLeft,
        child: CachedNetworkImage(
          key: ValueKey(logoUrl),
          imageUrl: logoUrl,
          memCacheHeight: 170,
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          errorWidget: (context, url, error) => Text(
            title,
            style: TextStyle(
              color: context.tvTextColor,
              fontSize: 40,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              height: 1.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    return Text(
      title,
      style: TextStyle(
        color: context.tvTextColor,
        fontSize: 40,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.5,
        height: 1.1,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
