import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/widgets/platform/windows/windows_line_selector.dart';
import 'package:baka/api/anibaka_api.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:baka/widgets/danmaku/danmaku_list_sheet.dart';
import 'package:baka/widgets/player/bgm_follow_pill.dart';

class WindowsEpisodeList extends StatefulWidget {
  const WindowsEpisodeList({
    required this.videoList,
    required this.currentIndex,
    required this.onEpisodeSelected,
    super.key,
    this.title,
    this.summary,
    this.bgmInfo,
    this.followNotifier,
    this.onFollowPressed,
    this.sourceName,
    this.lineName,
    this.onSourceTap,
    this.isSearching = false,
    this.danmakuController,
    this.onShowDetail,
    this.cachedTags,
    this.onUrlSelected,
    this.onDownloadPressed,
    this.currUrl,
    this.sourceNames,
    this.bgmId,
    this.bgmEpisodes,
    this.fallbackCoverUrl,
  });

  final List<PlaybackEpisode> videoList;
  final int currentIndex;
  final ValueChanged<int> onEpisodeSelected;
  final void Function(int, int)? onUrlSelected;
  final VoidCallback? onDownloadPressed;
  final int? currUrl;
  final List<String>? sourceNames;
  final int? bgmId;
  final List<Map<String, dynamic>>? bgmEpisodes;
  final String? fallbackCoverUrl;

  final String? title;
  final String? summary;
  final BgmInfo? bgmInfo;
  final ValueNotifier<bool>? followNotifier;
  final VoidCallback? onFollowPressed;
  final String? sourceName;
  final String? lineName;
  final VoidCallback? onSourceTap;
  final bool isSearching;
  final DanmakuController? danmakuController;
  final VoidCallback? onShowDetail;
  final List<String>? cachedTags;

  @override
  State<WindowsEpisodeList> createState() => _WindowsEpisodeListState();
}

class _WindowsEpisodeListState extends State<WindowsEpisodeList> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _ascending = true;
  bool _isGridView = false;
  bool _isEpisodesExpanded = true;
  late List<int> _filteredList = _buildFilteredList();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(WindowsEpisodeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.videoList, widget.videoList)) {
      _filteredList = _buildFilteredList();
    }
  }

  void _onSearchChanged() {
    final newList = _buildFilteredList();
    if (newList.length != _filteredList.length ||
        !newList.every((idx) => _filteredList.contains(idx))) {
      setState(() => _filteredList = newList);
    }
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
    final primaryColor = theme.colorScheme.primary;

    return CustomScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAnimeHeader(theme, primaryColor),
              const SizedBox(height: 8),
              _buildSourceRow(theme, primaryColor),
              const SizedBox(height: 6),
              _buildDanmakuRow(theme, primaryColor),
              const SizedBox(height: 12),
              _buildEpisodeHeaderSection(theme, primaryColor),
              const SizedBox(height: 6),
            ],
          ),
        ),
        if (_isEpisodesExpanded) ...[
          if (_filteredList.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '没有找到匹配的剧集',
                    style: TextStyle(fontSize: 13, color: Colors.white38),
                  ),
                ),
              ),
            )
          else if (_isGridView)
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 20),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 2.0,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final i = _filteredList[index];
                    return _WindowsEpisodeGridItem(
                      index: i,
                      isPlaying: i == widget.currentIndex,
                      title: widget.videoList[i].title,
                      primaryColor: primaryColor,
                      onTap: () => widget.onEpisodeSelected(i),
                    );
                  },
                  childCount: _filteredList.length,
                  addAutomaticKeepAlives: false,
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 20),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final i = _filteredList[index];
                    final item = widget.videoList[i];
                    return _WindowsEpisodeListItem(
                      key: ValueKey(i),
                      index: i,
                      item: item,
                      isPlaying: i == widget.currentIndex,
                      bgmId: widget.bgmId,
                      bgmEpisodes: widget.bgmEpisodes,
                      fallbackCoverUrl: widget.fallbackCoverUrl,
                      currUrl: widget.currUrl,
                      sourceNames: widget.sourceNames,
                      primaryColor: primaryColor,
                      onEpisodeSelected: widget.onEpisodeSelected,
                      onUrlSelected: widget.onUrlSelected,
                    );
                  },
                  childCount: _filteredList.length,
                  addAutomaticKeepAlives: false,
                ),
              ),
            ),
        ] else
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }

  Widget _buildAnimeHeader(ThemeData theme, Color primaryColor) {
    final title = widget.title?.trim() ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              title.isNotEmpty ? title : '番剧详情',
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: -0.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.followNotifier != null && widget.onFollowPressed != null) ...[
            const SizedBox(width: 6),
            ValueListenableBuilder<bool>(
              valueListenable: widget.followNotifier!,
              builder: (context, isFollowed, _) => BgmFollowPill(
                title: title,
                bgmInfo: widget.bgmInfo ?? const BgmInfo(),
                isFollowed: isFollowed,
                onFollowPressed: widget.onFollowPressed!,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSourceRow(ThemeData theme, Color primaryColor) {
    final source = widget.sourceName?.isNotEmpty == true ? widget.sourceName! : '切换播放源';
    final line = widget.lineName;
    final label = (line != null && line.isNotEmpty) ? '$source · $line' : source;

    return Material(
      color: const Color(0xFF1B1B1F),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: widget.onSourceTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white10, width: 0.8),
          ),
          child: Row(
            children: [
              const Text(
                '播放源',
                style: TextStyle(
                  fontSize: 12.0,
                  color: Colors.white54,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.isSearching ? '正在自动匹配源中...' : label,
                  style: const TextStyle(
                    fontSize: 13.0,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '切换源',
                  style: TextStyle(
                    fontSize: 11.0,
                    color: primaryColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDanmakuRow(ThemeData theme, Color primaryColor) {
    return Material(
      color: const Color(0xFF1B1B1F),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: () {
          if (widget.danmakuController != null) {
            DanmakuListSheet.show(
              context,
              widget.danmakuController!,
              defaultTitle: widget.title,
              defaultEpisode: widget.currentIndex + 1,
            );
          }
        },
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white10, width: 0.8),
          ),
          child: Row(
            children: [
              const Text(
                '弹幕库',
                style: TextStyle(
                  fontSize: 12.0,
                  color: Colors.white54,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: widget.danmakuController != null
                    ? ListenableBuilder(
                        listenable: widget.danmakuController!,
                        builder: (context, _) {
                          final count = widget.danmakuController!.items.length;
                          return Text(
                            count > 0 ? '$count 条弹幕' : '暂无关联弹幕',
                            style: const TextStyle(
                              fontSize: 13.0,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          );
                        },
                      )
                    : const Text(
                        '未开启',
                        style: TextStyle(
                          fontSize: 13.0,
                          fontWeight: FontWeight.w600,
                          color: Colors.white54,
                        ),
                      ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '匹配管理',
                  style: TextStyle(
                    fontSize: 11.0,
                    color: Colors.white70,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEpisodeHeaderSection(ThemeData theme, Color primaryColor) {
    final hasQuery = _searchController.text.isNotEmpty;

    return Column(
      children: [
        InkWell(
          onTap: () => setState(() => _isEpisodesExpanded = !_isEpisodesExpanded),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const Text(
                  '剧集列表',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '(${widget.videoList.length}话)',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Colors.white54,
                  ),
                ),
                const Spacer(),
                Text(
                  _isEpisodesExpanded ? '收起' : '展开',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Colors.white38,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_isEpisodesExpanded) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 32,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                  child: TextField(
                    controller: _searchController,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索剧集...',
                      hintStyle: const TextStyle(color: Colors.white30, fontSize: 12.0),
                      prefixIcon: const Icon(Icons.search, color: Colors.white38, size: 16),
                      prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 32),
                      suffixIcon: hasQuery
                          ? IconButton(
                              icon: const Icon(Icons.clear, color: Colors.white54, size: 14),
                              onPressed: _searchController.clear,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 28, minHeight: 32),
                            )
                          : null,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                    style: const TextStyle(fontSize: 12.0, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _buildIconButton(
                icon: _isGridView ? Icons.view_list_rounded : Icons.grid_view_rounded,
                onPressed: () => setState(() => _isGridView = !_isGridView),
                tooltip: _isGridView ? '列表视图' : '网格视图',
              ),
              _buildIconButton(
                icon: _ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                onPressed: () => setState(() {
                  _ascending = !_ascending;
                  _filteredList = _buildFilteredList();
                }),
                tooltip: _ascending ? '升序' : '降序',
              ),
              if (widget.onDownloadPressed != null)
                _buildIconButton(
                  icon: Icons.download_rounded,
                  onPressed: widget.onDownloadPressed,
                  tooltip: '下载全部',
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 17, color: Colors.white70),
        ),
      ),
    );
  }
}

class _WindowsEpisodeListItem extends StatelessWidget {
  final int index;
  final PlaybackEpisode item;
  final bool isPlaying;
  final int? bgmId;
  final List<Map<String, dynamic>>? bgmEpisodes;
  final String? fallbackCoverUrl;
  final int? currUrl;
  final List<String>? sourceNames;
  final Color primaryColor;
  final ValueChanged<int> onEpisodeSelected;
  final void Function(int, int)? onUrlSelected;

  const _WindowsEpisodeListItem({
    required this.index,
    required this.item,
    required this.isPlaying,
    required this.bgmId,
    required this.bgmEpisodes,
    required this.fallbackCoverUrl,
    required this.currUrl,
    required this.sourceNames,
    required this.primaryColor,
    required this.onEpisodeSelected,
    required this.onUrlSelected,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (bgmId != null && bgmId! > 0) {
      return FutureBuilder<Map<String, dynamic>?>(
        future: AniBakaApi.getEpisodeStills(
          bgmId: bgmId,
          season: 1,
          episode: index + 1,
        ),
        builder: (context, snapshot) {
          return _buildItemContent(context, snapshot.data);
        },
      );
    }
    return _buildItemContent(context, null);
  }

  String _resolveTitle(Map<String, dynamic>? still) {
    if (bgmEpisodes != null && index >= 0 && index < bgmEpisodes!.length) {
      final ep = bgmEpisodes![index];
      final cn = ep['name_cn']?.toString().trim();
      final jp = ep['name']?.toString().trim();
      final name = (cn != null && cn.isNotEmpty)
          ? cn
          : (jp != null && jp.isNotEmpty ? jp : item.title);
      if (name.startsWith('S') || name.startsWith('第')) return name;
      return 'S1E${index + 1}: $name';
    }
    final stillName = BgmUtils.trimmed(still?['name']);
    if (stillName != null && stillName.isNotEmpty) {
      if (stillName.startsWith('S') || stillName.startsWith('第')) return stillName;
      return 'S1E${index + 1}: $stillName';
    }
    final raw = item.title.trim();
    if (raw.startsWith('S') || raw.startsWith('第') || raw.contains('话') || raw.contains('集')) {
      return raw;
    }
    return 'S1E${index + 1}: $raw';
  }

  String _resolveAirDate(Map<String, dynamic>? still) {
    if (bgmEpisodes != null && index >= 0 && index < bgmEpisodes!.length) {
      final ep = bgmEpisodes![index];
      final airdate = ep['airdate']?.toString().trim();
      if (airdate != null && airdate.isNotEmpty) return airdate;
    }
    final stillDate = BgmUtils.trimmed(still?['air_date']);
    if (stillDate != null && stillDate.isNotEmpty) return stillDate;
    return '';
  }

  String _resolveOverview(Map<String, dynamic>? still) {
    final stillOverview = BgmUtils.trimmed(still?['overview']);
    if (stillOverview != null && stillOverview.isNotEmpty) return stillOverview;

    if (bgmEpisodes != null && index >= 0 && index < bgmEpisodes!.length) {
      final ep = bgmEpisodes![index];
      final desc = ep['desc']?.toString().trim();
      if (desc != null && desc.isNotEmpty) return desc;
    }
    return '暂无本集剧情简介';
  }

  String _resolveStillUrl(Map<String, dynamic>? still) {
    if (still != null) {
      final url = BgmUtils.trimmed(still['still_url']) ?? BgmUtils.trimmed(still['still_thumb']);
      if (url != null && url.isNotEmpty) return url;
    }
    return fallbackCoverUrl ?? '';
  }

  Widget _buildItemContent(BuildContext context, Map<String, dynamic>? still) {
    final title = _resolveTitle(still);
    final airDate = _resolveAirDate(still);
    final overview = _resolveOverview(still);
    final stillUrl = _resolveStillUrl(still);
    final lineCount = item.lineCount;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: isPlaying ? const Color(0xFF222226) : const Color(0xFF18181B),
        border: Border.all(
          color: isPlaying ? primaryColor.withValues(alpha: 0.6) : Colors.white10,
          width: 0.8,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onEpisodeSelected(index),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildCoverThumbnail(stillUrl),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  title,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: isPlaying ? FontWeight.bold : FontWeight.w600,
                                    color: isPlaying ? primaryColor : Colors.white,
                                    height: 1.25,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (lineCount > 1)
                                Container(
                                  margin: const EdgeInsets.only(left: 6),
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: primaryColor.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: primaryColor.withValues(alpha: 0.4),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Text(
                                    '$lineCount 线路',
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (airDate.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              airDate,
                              style: const TextStyle(fontSize: 11.0, color: Colors.white38),
                            ),
                          ],
                          if (overview.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              overview,
                              style: const TextStyle(fontSize: 11.5, color: Colors.white60, height: 1.35),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (isPlaying && lineCount > 1) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Divider(height: 1, thickness: 0.6, color: Colors.white12),
                  ),
                  WindowsLineSelector(
                    lineCount: lineCount,
                    currUrl: currUrl ?? 1,
                    onUrlChanged: (urlIndex) => onUrlSelected?.call(index, urlIndex),
                    sourceNames: sourceNames,
                    isInline: true,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCoverThumbnail(String stillUrl) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 126,
        height: 71,
        color: const Color(0xFF1E1E22),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (stillUrl.isNotEmpty)
              CachedNetworkImage(
                memCacheWidth: 260,
                imageUrl: stillUrl,
                fit: BoxFit.cover,
                fadeInDuration: const Duration(milliseconds: 150),
                fadeOutDuration: const Duration(milliseconds: 150),
                placeholder: (_, _) => _placeholderIcon(),
                errorWidget: (_, _, _) => _placeholderIcon(),
              )
            else
              _placeholderIcon(),
            if (isPlaying)
              Container(
                color: Colors.black45,
                child: Center(
                  child: Icon(
                    Icons.play_circle_fill_rounded,
                    color: primaryColor,
                    size: 24,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholderIcon() {
    return const Center(
      child: Icon(Icons.movie_outlined, size: 22, color: Colors.white24),
    );
  }
}

class _WindowsEpisodeGridItem extends StatelessWidget {
  final int index;
  final bool isPlaying;
  final String title;
  final Color primaryColor;
  final VoidCallback onTap;

  const _WindowsEpisodeGridItem({
    required this.index,
    required this.isPlaying,
    required this.title,
    required this.primaryColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: isPlaying ? primaryColor.withValues(alpha: 0.18) : const Color(0xFF1B1B1F),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isPlaying ? primaryColor.withValues(alpha: 0.6) : Colors.white10,
              width: 0.8,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          alignment: Alignment.center,
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: isPlaying ? FontWeight.bold : FontWeight.w500,
              fontSize: 12.5,
              color: isPlaying ? primaryColor : Colors.white70,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
