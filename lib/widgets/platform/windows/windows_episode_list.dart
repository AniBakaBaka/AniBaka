import 'package:flutter/material.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/widgets/platform/windows/windows_line_selector.dart';

/// Windows平台的剧集列表组件
class WindowsEpisodeList extends StatefulWidget {
  const WindowsEpisodeList({
    required this.videoList,
    required this.currentIndex,
    required this.onEpisodeSelected,
    super.key,
    this.onUrlSelected,
    this.onDownloadPressed,
    this.currUrl,
    this.sourceNames,
  });

  final List<PlaybackEpisode> videoList;
  final int currentIndex;
  final Function(int) onEpisodeSelected;
  final Function(int, int)? onUrlSelected;
  final VoidCallback? onDownloadPressed;
  final int? currUrl;
  final List<String>? sourceNames;

  @override
  State<WindowsEpisodeList> createState() => _WindowsEpisodeListState();
}

class _WindowsEpisodeListState extends State<WindowsEpisodeList> {
  final TextEditingController _searchController = TextEditingController();
  bool _ascending = true;
  bool _isGridView = false;
  late List<int> _filteredList = _buildFilteredList();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_rebuildFiltered);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(WindowsEpisodeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.videoList, widget.videoList)) {
      _filteredList = _buildFilteredList();
    }
  }

  void _rebuildFiltered() {
    setState(() => _filteredList = _buildFilteredList());
  }

  List<int> _buildFilteredList() {
    return PlaybackEpisodeCatalog.filterIndexes(
      widget.videoList,
      searchQuery: _searchController.text,
      ascending: _ascending,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final hasQuery = _searchController.text.isNotEmpty;

    return Column(
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            color: theme.cardColor.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.1),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: theme.scaffoldBackgroundColor.withValues(alpha: 0.8),
                  ),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: '搜索剧集...',
                      hintStyle: const TextStyle(
                        color: Colors.grey,
                        fontSize: 13,
                      ),
                      prefixIcon: const Icon(
                        Icons.search,
                        color: Colors.grey,
                        size: 18,
                      ),
                      suffixIcon: hasQuery
                          ? IconButton(
                              icon: const Icon(
                                Icons.clear,
                                color: Colors.grey,
                                size: 16,
                              ),
                              onPressed: _searchController.clear,
                            )
                          : null,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 8,
                      ),
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildIconButton(
                color: color,
                icon: _isGridView
                    ? Icons.view_list_rounded
                    : Icons.grid_view_rounded,
                onPressed: () => setState(() => _isGridView = !_isGridView),
                tooltip: _isGridView ? '列表视图' : '网格视图',
              ),
              _buildIconButton(
                color: color,
                icon: _ascending
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
                onPressed: () => setState(() {
                  _ascending = !_ascending;
                  _filteredList = _buildFilteredList();
                }),
                tooltip: _ascending ? '升序' : '降序',
              ),
              if (widget.onDownloadPressed != null)
                _buildIconButton(
                  color: color,
                  icon: Icons.download_rounded,
                  onPressed: widget.onDownloadPressed,
                  tooltip: '下载全部',
                ),
            ],
          ),
        ),

        Expanded(
          child: _filteredList.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.search_off_rounded,
                        size: 48,
                        color: Colors.grey,
                      ),
                      SizedBox(height: 16),
                      Text(
                        '没有找到匹配的剧集',
                        style: TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : _isGridView
              ? _buildGridView(theme, color)
              : _buildListView(theme, color),
        ),
      ],
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    VoidCallback? onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 20, color: color.withValues(alpha: 0.8)),
        ),
      ),
    );
  }

  Widget _buildGridView(ThemeData theme, Color color) {
    final cardColor = theme.cardColor;
    final dividerColor = theme.dividerColor.withValues(alpha: 0.1);
    final selectedColor = color.withValues(alpha: 0.15);
    final selectedBorder = color.withValues(alpha: 0.5);
    final selectedShadow = [
      BoxShadow(
        color: color.withValues(alpha: 0.1),
        blurRadius: 8,
        offset: const Offset(0, 2),
      ),
    ];

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 2.2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _filteredList.length,
      itemBuilder: (context, index) {
        final i = _filteredList[index];
        final isPlaying = i == widget.currentIndex;
        final title = widget.videoList[i].title;

        return InkWell(
          onTap: () => widget.onEpisodeSelected(i),
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: isPlaying ? selectedColor : cardColor,
              border: Border.all(
                color: isPlaying ? selectedBorder : dividerColor,
                width: 1,
              ),
              boxShadow: isPlaying ? selectedShadow : const [],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Center(
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: isPlaying ? FontWeight.w600 : FontWeight.normal,
                  fontSize: 13,
                  color: isPlaying ? color : null,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildListView(ThemeData theme, Color color) {
    final cardColor = theme.cardColor.withValues(alpha: 0.6);
    final dividerColor = theme.dividerColor.withValues(alpha: 0.05);
    final selectedColor = color.withValues(alpha: 0.08);
    final selectedBorder = color.withValues(alpha: 0.3);
    final lineBadgeColor = theme.dividerColor.withValues(alpha: 0.1);
    final subTextColor = theme.textTheme.bodySmall?.color;
    final currUrl = widget.currUrl ?? 1;

    return ListView.builder(
      itemCount: _filteredList.length,
      padding: const EdgeInsets.only(bottom: 20),
      itemBuilder: (context, index) {
        final i = _filteredList[index];
        final item = widget.videoList[i];
        final isPlaying = i == widget.currentIndex;
        final title = item.title;
        final lineCount = item.lineCount;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: isPlaying ? selectedColor : cardColor,
            border: Border.all(
              color: isPlaying ? selectedBorder : dividerColor,
              width: 1,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => widget.onEpisodeSelected(i),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (isPlaying) ...[
                          Icon(
                            Icons.play_arrow_rounded,
                            color: color,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isPlaying
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: isPlaying ? color : null,
                            ),
                          ),
                        ),
                        if (lineCount > 1)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: lineBadgeColor,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '$lineCount 路线',
                              style: TextStyle(
                                fontSize: 11,
                                color: subTextColor,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (isPlaying && lineCount > 1) ...[
                      const SizedBox(height: 12),
                      const Divider(height: 1, thickness: 0.5),
                      const SizedBox(height: 12),
                      WindowsLineSelector(
                        lineCount: lineCount,
                        currUrl: currUrl,
                        onUrlChanged: (urlIndex) =>
                            widget.onUrlSelected?.call(i, urlIndex),
                        sourceNames: widget.sourceNames,
                        isInline: true,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
