import 'package:baka/utils/json_values.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/api/anibaka_api.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'package:baka/widgets/common/value_selector.dart';

class TvEpisodeSelector extends StatefulWidget {
  final List<PlaybackEpisode> videoList;
  final int currentIndex;
  final int currUrl;
  final List<String>? sourceNames;
  final ValueChanged<int> onEpisodeSelected;
  final ValueChanged<int>? onUrlChanged;
  final VoidCallback onClose;
  final int? bgmId;
  final int? tmdbId;
  final String? tvdbId;

  const TvEpisodeSelector({
    required this.videoList,
    required this.currentIndex,
    required this.currUrl,
    required this.onEpisodeSelected,
    required this.onClose,
    this.onUrlChanged,
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
  static const _stillsCacheLimit = 5;
  static const _cardExtent = 110.0 * 16 / 9 + 14;
  int _tabIndex = 0; // 0: 选集, 1: 线路
  final _focusedEpisode = ValueNotifier(0);
  int get _focusedIndex => _focusedEpisode.value;
  set _focusedIndex(int value) => _focusedEpisode.value = value;
  late final ScrollController _horizontalScrollController;
  bool _sortAscending = true;

  // 共享请求结果；完成时只更新使用它的预览和卡片。
  final _stillsCache = <int, Future<Map<String, dynamic>?>>{};

  late List<int> _lineIndexes;

  @override
  void initState() {
    super.initState();
    _updateLineIndexes();
    _focusedIndex = widget.currentIndex.clamp(
      0,
      widget.videoList.isEmpty ? 0 : widget.videoList.length - 1,
    );
    _horizontalScrollController = ScrollController(
      initialScrollOffset: (_focusedIndex * _cardExtent - 80).clamp(
        0,
        double.infinity,
      ),
    );
    _fetchEpisodeDetails(_focusedIndex);

    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToCurrentEpisode(),
    );
  }

  @override
  void didUpdateWidget(covariant TvEpisodeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoList != widget.videoList ||
        oldWidget.currentIndex != widget.currentIndex) {
      _updateLineIndexes();
    }
    final catalogChanged =
        oldWidget.videoList != widget.videoList ||
        oldWidget.bgmId != widget.bgmId ||
        oldWidget.tmdbId != widget.tmdbId ||
        oldWidget.tvdbId != widget.tvdbId;
    if (catalogChanged) _stillsCache.clear();
    if (catalogChanged || oldWidget.currentIndex != widget.currentIndex) {
      _focusedIndex = widget.currentIndex.clamp(
        0,
        widget.videoList.isEmpty ? 0 : widget.videoList.length - 1,
      );
      if (_lineIndexes.length <= 1) _tabIndex = 0;
      _fetchEpisodeDetails(_focusedIndex);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCurrentEpisode(),
      );
    }
  }

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    _focusedEpisode.dispose();
    _stillsCache.clear();
    super.dispose();
  }

  void _updateLineIndexes() {
    final index = widget.currentIndex;
    _lineIndexes = index >= 0 && index < widget.videoList.length
        ? widget.videoList[index].availableLineIndexes.toList(growable: false)
        : const [];
  }

  void _toggleSortOrder() {
    setState(() => _sortAscending = !_sortAscending);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToCurrentEpisode(),
    );
  }

  void _scrollToCurrentEpisode() {
    if (!mounted ||
        widget.videoList.isEmpty ||
        !_horizontalScrollController.hasClients) {
      return;
    }
    final targetIndex = _sortAscending
        ? _focusedIndex
        : widget.videoList.length - _focusedIndex - 1;
    final targetOffset = (targetIndex * _cardExtent - 80).clamp(
      0.0,
      _horizontalScrollController.position.maxScrollExtent,
    );
    _horizontalScrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  /// 只保留当前集及相邻集；相邻预取不能递归扩散到整季。
  void _fetchEpisodeDetails(int episodeIndex) {
    if ((widget.bgmId ?? 0) <= 0 &&
        (widget.tmdbId ?? 0) <= 0 &&
        (widget.tvdbId == null || widget.tvdbId!.isEmpty)) {
      return;
    }
    for (var index = episodeIndex - 1; index <= episodeIndex + 1; index++) {
      if (index < 0 || index >= widget.videoList.length) continue;
      final cached = _stillsCache.remove(index);
      if (cached != null) {
        _stillsCache[index] = cached;
        continue;
      }
      if (_stillsCache.length == _stillsCacheLimit) {
        _stillsCache.remove(_stillsCache.keys.first);
      }
      _stillsCache[index] =
          AniBakaApi.getEpisodeStills(
            bgmId: widget.bgmId,
            tmdbId: widget.tmdbId,
            tvdbId: widget.tvdbId,
            season: 1,
            episode: index + 1,
          ).catchError((Object error) {
            debugPrint('获取 TV 剧集剧照失败: $error');
            return null;
          });
    }
  }

  static String _stillUrl(Map<String, dynamic>? data) =>
      trimmed(data?['still_url']) ?? trimmed(data?['still_thumb']) ?? '';

  Widget _buildStill(String url, IconData icon, double size) {
    final fallback = Center(
      child: Icon(icon, color: context.tvTextHintColor, size: size),
    );
    return ColoredBox(
      color: context.tvHighlightColor(0.08),
      child: url.isEmpty
          ? fallback
          : CachedNetworkImage(
              imageUrl: url,
              memCacheWidth: (210 * MediaQuery.devicePixelRatioOf(context))
                  .ceil(),
              fit: BoxFit.cover,
              placeholder: (context, url) => const SizedBox.expand(),
              errorWidget: (context, url, error) => fallback,
            ),
    );
  }

  void _onEpisodeFocused(int episodeIndex) {
    if (_focusedIndex != episodeIndex) {
      _fetchEpisodeDetails(episodeIndex);
      _focusedIndex = episodeIndex;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final showLineTab = _lineIndexes.length > 1;

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
                Colors.transparent,
                Colors.black.withValues(alpha: 0.15),
                Colors.black.withValues(alpha: 0.55),
                Colors.black.withValues(alpha: 0.78),
              ],
              stops: const [0.0, 0.55, 0.85, 1.0],
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ValueListenableBuilder<int>(
                valueListenable: _focusedEpisode,
                builder: (_, index, _) => FutureBuilder<Map<String, dynamic>?>(
                  key: ValueKey(_stillsCache[index]),
                  future: _stillsCache[index],
                  builder: (context, snapshot) => _buildFocusedDetailsHeader(
                    primaryColor,
                    showLineTab,
                    snapshot.data,
                  ),
                ),
              ),

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
  Widget _buildFocusedDetailsHeader(
    Color primaryColor,
    bool showLineTab,
    Map<String, dynamic>? stillData,
  ) {
    final epItem =
        (_focusedIndex >= 0 && _focusedIndex < widget.videoList.length)
        ? widget.videoList[_focusedIndex]
        : null;
    final stillUrl = _stillUrl(stillData);

    final name = trimmed(stillData?['name']) ?? epItem?.title ?? '剧集详情';
    final overview =
        trimmed(stillData?['overview']) ??
        (epItem != null ? '第 ${_focusedIndex + 1} 集' : '');
    final airDate = trimmed(stillData?['air_date']);
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
                child: _buildStill(stillUrl, Icons.movie_rounded, 36),
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
                          borderRadius: const BorderRadius.all(
                            Radius.circular(6),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
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
    if (widget.videoList.isEmpty) {
      return Center(
        child: Text(
          '暂无剧集',
          style: TextStyle(color: context.tvTextSecondaryColor, fontSize: 16),
        ),
      );
    }

    return ListView.builder(
      key: ValueKey((
        widget.videoList,
        widget.bgmId,
        widget.tmdbId,
        widget.tvdbId,
      )),
      controller: _horizontalScrollController,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      itemExtent: _cardExtent,
      itemCount: widget.videoList.length,
      findChildIndexCallback: (key) {
        final episode = (key as ValueKey<int>).value;
        return _sortAscending ? episode : widget.videoList.length - episode - 1;
      },
      itemBuilder: (context, index) {
        final episodeIndex = _sortAscending
            ? index
            : widget.videoList.length - index - 1;
        final item = widget.videoList[episodeIndex];
        final isPlaying = episodeIndex == widget.currentIndex;
        return ValueSelector<int, Future<Map<String, dynamic>?>?>(
          key: ValueKey(episodeIndex),
          valueListenable: _focusedEpisode,
          select: (_) => _stillsCache[episodeIndex],
          builder: (_, future) => FutureBuilder<Map<String, dynamic>?>(
            future: future,
            builder: (context, snapshot) {
              final data = snapshot.connectionState == ConnectionState.done
                  ? snapshot.data
                  : null;
              final stillUrl = _stillUrl(data);
              final epName = trimmed(data?['name']) ?? item.title;
              return Padding(
                padding: const EdgeInsets.only(right: 14),
                child: Center(
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
                                  child: _buildStill(
                                    stillUrl,
                                    Icons.play_circle_outline,
                                    32,
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'EP ${episodeIndex + 1}',
                                        style: TextStyle(
                                          color: isPlaying
                                              ? primaryColor
                                              : Colors.white.withValues(
                                                  alpha: 0.7,
                                                ),
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
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildLineList(Color primaryColor) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      itemCount: _lineIndexes.length,
      itemBuilder: (context, index) {
        final lineIndex = _lineIndexes[index];
        final isSelected = lineIndex == widget.currUrl;
        final lineName =
            (widget.sourceNames != null &&
                lineIndex > 0 &&
                lineIndex <= widget.sourceNames!.length)
            ? widget.sourceNames![lineIndex - 1]
            : '线路 $lineIndex';

        return Padding(
          padding: const EdgeInsets.only(right: 14),
          child: TvFocusable(
            autofocus: isSelected,
            onPressed: () => widget.onUrlChanged?.call(lineIndex),
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
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
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
