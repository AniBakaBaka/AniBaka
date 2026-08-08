import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/api/post.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/widgets/platform/tv/tv_theme_util.dart';

class TvEpisodeSelector extends StatefulWidget {
  final List<PlaybackEpisode> videoList;
  final int currentIndex;
  final int currUrl;
  final List<String>? sourceNames;
  final Function(int) onEpisodeSelected;
  final Function(int) onUrlChanged;
  final VoidCallback onClose;
  final int? bgmId;
  final int? tmdbId;
  final String? tvdbId;

  const TvEpisodeSelector({
    required this.videoList,
    required this.currentIndex,
    required this.currUrl,
    required this.onEpisodeSelected,
    required this.onUrlChanged,
    required this.onClose,
    this.sourceNames,
    this.bgmId,
    this.tmdbId,
    this.tvdbId,
    super.key,
  });

  @override
  State<TvEpisodeSelector> createState() => _TvEpisodeSelectorState();
}

class _TvEpisodeSelectorState extends State<TvEpisodeSelector> {
  int _tabIndex = 0; // 0: 选集, 1: 线路
  late int _focusedIndex;
  final ScrollController _horizontalScrollController = ScrollController();
  late List<int> _episodeIndexes;
  bool _sortAscending = true;

  /// 集中存储单集剧照与元数据，保证上下共享相同的数据源，零重复获取
  final Map<int, Map<String, dynamic>> _stillsCache = {};
  final Set<int> _loadingEpisodes = {};

  int get _lineCount {
    final index = widget.currentIndex;
    return index >= 0 && index < widget.videoList.length
        ? widget.videoList[index].lineCount
        : 0;
  }

  @override
  void initState() {
    super.initState();
    _focusedIndex = widget.currentIndex.clamp(
      0,
      widget.videoList.isEmpty ? 0 : widget.videoList.length - 1,
    );
    _refreshEpisodeIndexes();
    _fetchEpisodeDetails(_focusedIndex);

    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToCurrentEpisode(),
    );
  }

  @override
  void didUpdateWidget(covariant TvEpisodeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoList != widget.videoList) {
      _refreshEpisodeIndexes();
    }
    if (oldWidget.currentIndex != widget.currentIndex) {
      _focusedIndex = widget.currentIndex;
      _fetchEpisodeDetails(_focusedIndex);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCurrentEpisode(),
      );
    }
  }

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    super.dispose();
  }

  void _refreshEpisodeIndexes() {
    _episodeIndexes = PlaybackEpisodeCatalog.filterIndexes(
      widget.videoList,
      ascending: true,
    );
  }

  void _toggleSortOrder() {
    setState(() => _sortAscending = !_sortAscending);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToCurrentEpisode(),
    );
  }

  void _scrollToCurrentEpisode() {
    var targetIndex = _episodeIndexes.indexOf(_focusedIndex);
    if (targetIndex < 0 || !_horizontalScrollController.hasClients) return;
    if (!_sortAscending) {
      targetIndex = _episodeIndexes.length - targetIndex - 1;
    }
    final cardWidth = (110.0 * 16 / 9) + 14.0; // 16:9 card width + spacing
    final targetOffset = (targetIndex * cardWidth - 80.0).clamp(
      0.0,
      _horizontalScrollController.position.maxScrollExtent,
    );
    _horizontalScrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  /// 共享从单一数据源获取剧照，绝不重复拉取
  void _fetchEpisodeDetails(int episodeIndex) {
    if (episodeIndex < 0 || episodeIndex >= widget.videoList.length) return;
    if (_stillsCache.containsKey(episodeIndex) ||
        _loadingEpisodes.contains(episodeIndex)) {
      return;
    }

    _loadingEpisodes.add(episodeIndex);
    final epNum = episodeIndex + 1;

    getEpisodeStills(
      bgmId: widget.bgmId,
      tmdbId: widget.tmdbId,
      tvdbId: widget.tvdbId,
      season: 1,
      episode: epNum,
    ).then((data) {
      if (mounted) {
        _loadingEpisodes.remove(episodeIndex);
        if (data != null) {
          setState(() {
            _stillsCache[episodeIndex] = data;
          });
        }
      }
    }).catchError((_) {
      if (mounted) {
        _loadingEpisodes.remove(episodeIndex);
      }
    });

    for (final nextEp in [episodeIndex - 1, episodeIndex + 1]) {
      if (nextEp >= 0 &&
          nextEp < widget.videoList.length &&
          !_stillsCache.containsKey(nextEp) &&
          !_loadingEpisodes.contains(nextEp)) {
        _fetchEpisodeDetails(nextEp);
      }
    }
  }

  /// 获取指定剧集的剧照路径，上下组件共享相同链接与缓存
  String _getEpisodeStillUrl(int episodeIndex) {
    final stillData = _stillsCache[episodeIndex];
    if (stillData == null) return '';
    return BgmUtils.trimmed(stillData['still_url']) ??
        BgmUtils.trimmed(stillData['still_thumb']) ??
        '';
  }

  void _onEpisodeFocused(int episodeIndex) {
    if (_focusedIndex != episodeIndex) {
      setState(() {
        _focusedIndex = episodeIndex;
      });
      _fetchEpisodeDetails(episodeIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final showLineTab = _lineCount > 1;

    return Align(
      alignment: Alignment.bottomCenter,
      child: FocusScope(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.goBack) {
              widget.onClose();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          width: double.infinity,
          height: 360,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.35),
                Colors.black.withValues(alpha: 0.85),
                Colors.black.withValues(alpha: 0.96),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(
                color: primaryColor.withValues(alpha: 0.4),
                width: 1.5,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.6),
                blurRadius: 36,
                offset: const Offset(0, -10),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildFocusedDetailsHeader(primaryColor, showLineTab),

              const Divider(height: 1, thickness: 0.5, color: Colors.white12),

              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: _tabIndex == 0
                      ? _buildHorizontalEpisodeList(primaryColor)
                      : _buildLineList(primaryColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 上半部分：焦点剧集的 16:9 剧照 + 标题 + 剧情简介预览
  Widget _buildFocusedDetailsHeader(Color primaryColor, bool showLineTab) {
    final epItem =
        (_focusedIndex >= 0 && _focusedIndex < widget.videoList.length)
            ? widget.videoList[_focusedIndex]
            : null;
    final stillData = _stillsCache[_focusedIndex];

    final stillUrl = _getEpisodeStillUrl(_focusedIndex);

    final name = BgmUtils.trimmed(stillData?['name']) ?? epItem?.title ?? '剧集详情';
    final overview = BgmUtils.trimmed(stillData?['overview']) ??
        (epItem != null ? '第 ${_focusedIndex + 1} 集' : '');
    final airDate = BgmUtils.trimmed(stillData?['air_date']);
    final isPlaying = _focusedIndex == widget.currentIndex;

    return Container(
      height: 165,
      padding: const EdgeInsets.fromLTRB(28, 14, 28, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 118,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  color: context.tvHighlightColor(0.08),
                  child: stillUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: stillUrl,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            color: context.tvHighlightColor(0.08),
                            child: const Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                          errorWidget: (context, url, error) => Center(
                            child: Icon(
                              Icons.movie_rounded,
                              color: context.tvTextHintColor,
                              size: 36,
                            ),
                          ),
                        )
                      : Center(
                          child: Icon(
                            Icons.movie_rounded,
                            color: context.tvTextHintColor,
                            size: 36,
                          ),
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 20),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '第 ${_focusedIndex + 1} 集',
                        style: TextStyle(
                          color: primaryColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (isPlaying) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(
                              Icons.play_circle_fill,
                              color: Colors.greenAccent,
                              size: 12,
                            ),
                            SizedBox(width: 4),
                            Text(
                              '正在播放',
                              style: TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (airDate != null && airDate.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      Text(
                        '首播: $airDate',
                        style: TextStyle(
                          color: context.tvTextSecondaryColor,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const Spacer(),

                    if (showLineTab) ...[
                      _buildTabButton('选集', 0, primaryColor),
                      const SizedBox(width: 8),
                      _buildTabButton('线路', 1, primaryColor),
                      const SizedBox(width: 12),
                    ],
                    TvFocusable(
                      onPressed: _toggleSortOrder,
                      borderRadius: BorderRadius.circular(16),
                      enableScale: false,
                      enableGlow: false,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: context.tvHighlightColor(0.08),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _sortAscending
                                  ? Icons.arrow_upward_rounded
                                  : Icons.arrow_downward_rounded,
                              color: primaryColor,
                              size: 14,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _sortAscending ? '正序' : '倒序',
                              style: TextStyle(
                                color: context.tvTextColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  name,
                  style: TextStyle(
                    color: context.tvTextColor,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Text(
                    overview.isNotEmpty ? overview : '暂无详细简介',
                    style: TextStyle(
                      color: context.tvTextSecondaryColor,
                      fontSize: 13,
                      height: 1.4,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton(String label, int index, Color primaryColor) {
    final isSelected = _tabIndex == index;
    return TvFocusable(
      onPressed: () => setState(() => _tabIndex = index),
      borderRadius: BorderRadius.circular(16),
      enableScale: false,
      enableGlow: false,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor : context.tvHighlightColor(0.08),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected
                ? context.tvTextColor
                : context.tvTextSecondaryColor,
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// 下半部分：带 16:9 剧照的选集卡片横向列表，上下共享图片数据
  Widget _buildHorizontalEpisodeList(Color primaryColor) {
    if (_episodeIndexes.isEmpty) {
      return Center(
        child: Text(
          '暂无剧集',
          style: TextStyle(color: context.tvTextSecondaryColor, fontSize: 16),
        ),
      );
    }

    return ListView.builder(
      controller: _horizontalScrollController,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      itemCount: _episodeIndexes.length,
      itemBuilder: (context, index) {
        final episodeIndex = _sortAscending
            ? _episodeIndexes[index]
            : _episodeIndexes[_episodeIndexes.length - index - 1];
        final item = widget.videoList[episodeIndex];
        final isPlaying = episodeIndex == widget.currentIndex;
        final stillData = _stillsCache[episodeIndex];

        final stillUrl = _getEpisodeStillUrl(episodeIndex);
        final epName = BgmUtils.trimmed(stillData?['name']) ?? item.title;

        return Padding(
          padding: const EdgeInsets.only(right: 14),
          child: TvFocusable(
            autofocus: isPlaying,
            onFocusChange: (focused) {
              if (focused) _onEpisodeFocused(episodeIndex);
            },
            onPressed: () => widget.onEpisodeSelected(episodeIndex),
            borderRadius: BorderRadius.circular(12),
            focusScale: 1.06,
            enableGlow: true,
            focusBorderWidth: 2.5,
            child: SizedBox(
              height: 110,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  decoration: BoxDecoration(
                    color: context.tvHighlightColor(0.06),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isPlaying
                          ? primaryColor
                          : context.tvHighlightColor(0.12),
                      width: isPlaying ? 1.5 : 0.8,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: stillUrl.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: stillUrl,
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => Container(
                                    color: context.tvHighlightColor(0.05),
                                  ),
                                  errorWidget: (context, url, error) => Container(
                                    color: context.tvHighlightColor(0.08),
                                    child: Center(
                                      child: Icon(
                                        Icons.play_circle_outline,
                                        color: context.tvTextHintColor,
                                        size: 32,
                                      ),
                                    ),
                                  ),
                                )
                              : Container(
                                  color: context.tvHighlightColor(0.08),
                                  child: Center(
                                    child: Icon(
                                      Icons.play_circle_outline,
                                      color: context.tvTextHintColor,
                                      size: 32,
                                    ),
                                  ),
                                ),
                        ),

                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.85),
                                ],
                                stops: const [0.4, 1.0],
                              ),
                            ),
                          ),
                        ),

                        if (isPlaying)
                          Positioned(
                            top: 8,
                            left: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: primaryColor,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.black,
                                size: 14,
                              ),
                            ),
                          ),

                        Positioned(
                          left: 10,
                          right: 10,
                          bottom: 8,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'EP ${episodeIndex + 1}',
                                style: TextStyle(
                                  color: isPlaying
                                      ? primaryColor
                                      : Colors.white.withValues(alpha: 0.7),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                epName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLineList(Color primaryColor) {
    if (_lineCount <= 1) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline, color: context.tvTextHintColor, size: 40),
            const SizedBox(height: 8),
            Text(
              '此剧集暂无其他线路',
              style: TextStyle(
                color: context.tvTextSecondaryColor,
                fontSize: 15,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      itemCount: _lineCount,
      itemBuilder: (context, index) {
        final lineIndex = index + 1;
        final isSelected = lineIndex == widget.currUrl;
        final lineName = (widget.sourceNames != null &&
                lineIndex > 0 &&
                lineIndex <= widget.sourceNames!.length)
            ? widget.sourceNames![lineIndex - 1]
            : '线路 $lineIndex';

        return Padding(
          padding: const EdgeInsets.only(right: 14),
          child: TvFocusable(
            autofocus: isSelected,
            onPressed: () => widget.onUrlChanged(lineIndex),
            borderRadius: BorderRadius.circular(12),
            focusScale: 1.04,
            enableGlow: false,
            focusBorderWidth: 2,
            child: Container(
              width: 160,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: isSelected
                    ? primaryColor.withValues(alpha: 0.2)
                    : context.tvHighlightColor(0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected
                      ? primaryColor
                      : context.tvHighlightColor(0.12),
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: isSelected ? primaryColor : context.tvTextHintColor,
                    size: 24,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    lineName,
                    style: TextStyle(
                      color: isSelected ? primaryColor : context.tvTextColor,
                      fontSize: 15,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
