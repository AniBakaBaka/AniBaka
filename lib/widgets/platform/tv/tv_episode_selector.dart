import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/models/playback_episode.dart';

class TvEpisodeSelector extends StatefulWidget {
  final List<PlaybackEpisode> videoList;
  final int currentIndex;
  final int currUrl;
  final List<String>? sourceNames;
  final Function(int) onEpisodeSelected;
  final Function(int) onUrlChanged;
  final VoidCallback onClose;

  const TvEpisodeSelector({
    required this.videoList,
    required this.currentIndex,
    required this.currUrl,
    required this.onEpisodeSelected,
    required this.onUrlChanged,
    required this.onClose,
    this.sourceNames,
    super.key,
  });

  @override
  State<TvEpisodeSelector> createState() => _TvEpisodeSelectorState();
}

class _TvEpisodeSelectorState extends State<TvEpisodeSelector> {
  int _tabIndex = 0;
  final ScrollController _episodeScrollController = ScrollController();
  late List<int> _episodeIndexes;
  bool _sortAscending = true;

  int get _lineCount {
    final index = widget.currentIndex;
    return index >= 0 && index < widget.videoList.length
        ? widget.videoList[index].lineCount
        : 0;
  }

  @override
  void initState() {
    super.initState();
    _refreshEpisodeIndexes();
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
    if (oldWidget.videoList != widget.videoList ||
        oldWidget.currentIndex != widget.currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCurrentEpisode(),
      );
    }
  }

  @override
  void dispose() {
    _episodeScrollController.dispose();
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
    var targetIndex = _episodeIndexes.indexOf(widget.currentIndex);
    if (targetIndex < 0 || !_episodeScrollController.hasClients) return;
    if (!_sortAscending) {
      targetIndex = _episodeIndexes.length - targetIndex - 1;
    }
    final targetOffset = (targetIndex * 64.0).clamp(
      0.0,
      _episodeScrollController.position.maxScrollExtent,
    );
    _episodeScrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final showLineTab = _lineCount > 1;

    return Align(
      alignment: Alignment.centerRight,
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
          width: 420,
          height: double.infinity,
          decoration: BoxDecoration(
            color: context.tvPanelBgColor,
            border: Border(
              left: BorderSide(
                color: primaryColor.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: context.tvShadowColor(0.6),
                blurRadius: 40,
                offset: const Offset(-10, 0),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 32),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Icon(Icons.playlist_play, color: primaryColor, size: 28),
                    const SizedBox(width: 12),
                    Text(
                      widget.videoList.isNotEmpty
                          ? '${widget.videoList.length} 集'
                          : '选集',
                      style: TextStyle(
                        color: context.tvTextColor,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    TvFocusable(
                      onPressed: _toggleSortOrder,
                      borderRadius: BorderRadius.circular(18),
                      focusBorderWidth: 2,
                      enableScale: false,
                      enableGlow: false,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: context.tvHighlightColor(0.08),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _sortAscending
                                  ? Icons.arrow_upward_rounded
                                  : Icons.arrow_downward_rounded,
                              color: primaryColor,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _sortAscending ? '正序' : '倒序',
                              style: TextStyle(
                                color: context.tvTextColor,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: context.tvHighlightColor(0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.arrow_back,
                            color: context.tvTextSecondaryColor,
                            size: 14,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '返回',
                            style: TextStyle(
                              color: context.tvTextSecondaryColor,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              if (showLineTab)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      _buildTabButton('选集', 0, primaryColor),
                      const SizedBox(width: 8),
                      _buildTabButton('线路', 1, primaryColor),
                    ],
                  ),
                ),

              if (showLineTab) const SizedBox(height: 16),

              Expanded(
                child: _tabIndex == 0
                    ? _buildEpisodeList(primaryColor)
                    : _buildLineList(primaryColor),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabButton(String label, int index, Color primaryColor) {
    final isSelected = _tabIndex == index;
    return TvFocusable(
      onPressed: () => setState(() => _tabIndex = index),
      borderRadius: BorderRadius.circular(20),
      enableScale: false,
      enableGlow: false,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor : context.tvHighlightColor(0.08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected
                ? context.tvTextColor
                : context.tvTextSecondaryColor,
            fontSize: 15,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildEpisodeList(Color primaryColor) {
    if (_episodeIndexes.isEmpty) {
      return Center(
        child: Text(
          '暂无剧集',
          style: TextStyle(color: context.tvTextSecondaryColor, fontSize: 16),
        ),
      );
    }

    return ListView.builder(
      controller: _episodeScrollController,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemCount: _episodeIndexes.length,
      itemExtent: 64,
      itemBuilder: (context, index) {
        final episodeIndex = _sortAscending
            ? _episodeIndexes[index]
            : _episodeIndexes[_episodeIndexes.length - index - 1];
        final item = widget.videoList[episodeIndex];
        final isPlaying = episodeIndex == widget.currentIndex;
        final title = item.title;
        final lineCount = item.lineCount;

        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: TvFocusable(
            autofocus: isPlaying,
            onPressed: () => widget.onEpisodeSelected(episodeIndex),
            borderRadius: BorderRadius.circular(10),
            focusScale: 1.02,
            enableGlow: false,
            focusBorderWidth: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isPlaying
                    ? primaryColor.withValues(alpha: 0.2)
                    : context.tvHighlightColor(0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  if (isPlaying)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: primaryColor,
                        size: 22,
                      ),
                    ),

                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            color: isPlaying
                                ? primaryColor
                                : context.tvTextColor,
                            fontSize: 16,
                            fontWeight: isPlaying
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (lineCount > 1)
                          Text(
                            '$lineCount 条线路',
                            style: TextStyle(
                              color: context.tvHighlightColor(0.4),
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),

                  Text(
                    '${episodeIndex + 1}',
                    style: TextStyle(
                      color: isPlaying
                          ? primaryColor.withValues(alpha: 0.7)
                          : context.tvHighlightColor(0.3),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
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
            Icon(Icons.info_outline, color: context.tvTextHintColor, size: 48),
            const SizedBox(height: 12),
            Text(
              '此剧集暂无其他线路',
              style: TextStyle(
                color: context.tvTextSecondaryColor,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemCount: _lineCount,
      itemExtent: 64,
      itemBuilder: (context, index) {
        final lineIndex = index + 1;
        final isSelected = lineIndex == widget.currUrl;
        final lineName =
            (widget.sourceNames != null &&
                lineIndex > 0 &&
                lineIndex <= widget.sourceNames!.length)
            ? widget.sourceNames![lineIndex - 1]
            : '线路 $lineIndex';

        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: TvFocusable(
            autofocus: isSelected,
            onPressed: () => widget.onUrlChanged(lineIndex),
            borderRadius: BorderRadius.circular(10),
            focusScale: 1.02,
            enableGlow: false,
            focusBorderWidth: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isSelected
                    ? primaryColor.withValues(alpha: 0.2)
                    : context.tvHighlightColor(0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: isSelected ? primaryColor : context.tvTextHintColor,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      lineName,
                      style: TextStyle(
                        color: isSelected ? primaryColor : context.tvTextColor,
                        fontSize: 16,
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (isSelected)
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
                        '当前',
                        style: TextStyle(
                          color: primaryColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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
