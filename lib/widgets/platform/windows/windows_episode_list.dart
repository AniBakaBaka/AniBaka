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
  final Function(int) onEpisodeSelected;
  final Function(int, int)? onUrlSelected;
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

  final Map<int, Map<String, dynamic>> _stillsCache = {};
  final Set<int> _loadingEpisodes = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_rebuildFiltered);
    _preloadVisibleStills();
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
      _preloadVisibleStills();
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

  void _preloadVisibleStills() {
    final targetIndices = [
      widget.currentIndex,
      widget.currentIndex + 1,
      widget.currentIndex + 2,
      widget.currentIndex + 3,
      widget.currentIndex + 4,
    ];
    for (final index in targetIndices) {
      if (index >= 0 && index < widget.videoList.length) {
        _fetchStill(index);
      }
    }
  }

  Future<void> _fetchStill(int episodeIndex) async {
    if (widget.bgmId == null || widget.bgmId! <= 0) return;
    if (_stillsCache.containsKey(episodeIndex) ||
        !_loadingEpisodes.add(episodeIndex)) {
      return;
    }

    try {
      final data = await AniBakaApi.getEpisodeStills(
        bgmId: widget.bgmId,
        season: 1,
        episode: episodeIndex + 1,
      );
      if (mounted && data != null) {
        setState(() {
          _stillsCache[episodeIndex] = data;
        });
      }
    } catch (_) {
    } finally {
      if (mounted) {
        _loadingEpisodes.remove(episodeIndex);
      }
    }
  }

  String _formatEpisodeTitle(int index, String rawTitle) {
    if (widget.bgmEpisodes != null &&
        index >= 0 &&
        index < widget.bgmEpisodes!.length) {
      final ep = widget.bgmEpisodes![index];
      final cn = ep['name_cn']?.toString().trim();
      final jp = ep['name']?.toString().trim();
      final sort = ep['sort']?.toString().trim() ?? '${index + 1}';
      final name = (cn != null && cn.isNotEmpty)
          ? cn
          : (jp != null && jp.isNotEmpty ? jp : rawTitle);
      if (name.startsWith('S') || name.startsWith('第')) {
        return name;
      }
      return 'S1E$sort: $name';
    }

    final still = _stillsCache[index];
    if (still != null) {
      final name = BgmUtils.trimmed(still['name']);
      if (name != null && name.isNotEmpty) {
        if (name.startsWith('S') || name.startsWith('第')) return name;
        return 'S1E${index + 1}: $name';
      }
    }

    final trimmed = rawTitle.trim();
    if (trimmed.startsWith('S') ||
        trimmed.startsWith('第') ||
        trimmed.contains('话') ||
        trimmed.contains('集')) {
      return trimmed;
    }
    return 'S1E${index + 1}: $trimmed';
  }

  String _getAirDate(int index) {
    if (widget.bgmEpisodes != null &&
        index >= 0 &&
        index < widget.bgmEpisodes!.length) {
      final ep = widget.bgmEpisodes![index];
      final airdate = ep['airdate']?.toString().trim();
      if (airdate != null && airdate.isNotEmpty) {
        return '$airdate 23:59';
      }
    }

    final still = _stillsCache[index];
    if (still != null) {
      final airDate = BgmUtils.trimmed(still['air_date']);
      if (airDate != null && airDate.isNotEmpty) {
        return airDate.contains(':') ? airDate : '$airDate 23:59';
      }
    }

    return '';
  }

  String _getOverview(int index) {
    final still = _stillsCache[index];
    if (still != null) {
      final overview = BgmUtils.trimmed(still['overview']);
      if (overview != null && overview.isNotEmpty) return overview;
    }

    if (widget.bgmEpisodes != null &&
        index >= 0 &&
        index < widget.bgmEpisodes!.length) {
      final ep = widget.bgmEpisodes![index];
      final desc = ep['desc']?.toString().trim();
      if (desc != null && desc.isNotEmpty) return desc;
    }

    return '暂无本集剧情简介';
  }

  String _getStillUrl(int index) {
    final still = _stillsCache[index];
    if (still != null) {
      final url = BgmUtils.trimmed(still['still_url']) ??
          BgmUtils.trimmed(still['still_thumb']);
      if (url != null && url.isNotEmpty) return url;
    }
    return widget.fallbackCoverUrl ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return CustomScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAnimeHeader(theme, primaryColor),
              const SizedBox(height: 10),
              _buildSourceRow(theme, primaryColor),
              const SizedBox(height: 8),
              _buildDanmakuRow(theme, primaryColor),
              const SizedBox(height: 16),
              _buildEpisodeHeaderSection(theme, primaryColor),
              const SizedBox(height: 8),
            ],
          ),
        ),
        if (_isEpisodesExpanded) ...[
          if (_filteredList.isEmpty)
            SliverToBoxAdapter(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 36),
                child: const Center(
                  child: Text(
                    '没有找到匹配的剧集',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white38,
                    ),
                  ),
                ),
              ),
            )
          else if (_isGridView)
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 24),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 2.3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildGridItem(context, index, primaryColor),
                  childCount: _filteredList.length,
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildListItem(context, index, theme, primaryColor),
                  childCount: _filteredList.length,
                ),
              ),
            ),
        ] else
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  Widget _buildAnimeHeader(ThemeData theme, Color primaryColor) {
    final title = widget.title?.trim() ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              title.isNotEmpty ? title : '番剧详情',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1.25,
                letterSpacing: -0.3,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.followNotifier != null && widget.onFollowPressed != null) ...[
            const SizedBox(width: 10),
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
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onSourceTap,
        borderRadius: BorderRadius.circular(8),
        hoverColor: Colors.white.withValues(alpha: 0.04),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1B1B1F),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.07),
            ),
          ),
          child: Row(
            children: [
              Text(
                '播放源',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.5),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.isSearching ? '正在自动匹配源中...' : label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '切换源',
                  style: TextStyle(
                    fontSize: 11,
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
      color: Colors.transparent,
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
        borderRadius: BorderRadius.circular(8),
        hoverColor: Colors.white.withValues(alpha: 0.04),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1B1B1F),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.07),
            ),
          ),
          child: Row(
            children: [
              Text(
                '弹幕库',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.5),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: widget.danmakuController != null
                    ? ListenableBuilder(
                        listenable: widget.danmakuController!,
                        builder: (context, _) {
                          final count = widget.danmakuController!.items.length;
                          return Text(
                            count > 0 ? '$count 条弹幕' : '暂无关联弹幕',
                            style: const TextStyle(
                              fontSize: 13,
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
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70,
                        ),
                      ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '匹配管理',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.8),
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
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Row(
              children: [
                const Text(
                  '剧集列表',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '共 ${widget.videoList.length} 话',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: Colors.white.withValues(alpha: 0.6),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  _isEpisodesExpanded ? '收起' : '展开',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_isEpisodesExpanded) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.06),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 32,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      color: Colors.black.withValues(alpha: 0.3),
                    ),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: '搜索剧集...',
                        hintStyle: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 12,
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          color: Colors.white.withValues(alpha: 0.4),
                          size: 16,
                        ),
                        suffixIcon: hasQuery
                            ? IconButton(
                                icon: const Icon(
                                  Icons.clear,
                                  color: Colors.grey,
                                  size: 14,
                                ),
                                onPressed: _searchController.clear,
                              )
                            : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 6,
                        ),
                      ),
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _buildIconButton(
                  color: Colors.white.withValues(alpha: 0.8),
                  icon: _isGridView
                      ? Icons.view_list_rounded
                      : Icons.grid_view_rounded,
                  onPressed: () => setState(() => _isGridView = !_isGridView),
                  tooltip: _isGridView ? '列表视图' : '网格视图',
                ),
                _buildIconButton(
                  color: Colors.white.withValues(alpha: 0.8),
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
                    color: Colors.white.withValues(alpha: 0.8),
                    icon: Icons.download_rounded,
                    onPressed: widget.onDownloadPressed,
                    tooltip: '下载全部',
                  ),
              ],
            ),
          ),
        ],
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
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 17, color: color),
        ),
      ),
    );
  }

  Widget _buildListItem(BuildContext context, int index, ThemeData theme, Color primaryColor) {
    final i = _filteredList[index];
    final item = widget.videoList[i];
    final isPlaying = i == widget.currentIndex;
    final title = _formatEpisodeTitle(i, item.title);
    final airDate = _getAirDate(i);
    final overview = _getOverview(i);
    final stillUrl = _getStillUrl(i);
    final lineCount = item.lineCount;

    if (!_stillsCache.containsKey(i)) {
      _fetchStill(i);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: isPlaying
            ? const Color(0xFF222226)
            : Colors.white.withValues(alpha: 0.03),
        border: Border.all(
          color: isPlaying
              ? primaryColor.withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.06),
          width: isPlaying ? 1.2 : 0.8,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => widget.onEpisodeSelected(i),
          borderRadius: BorderRadius.circular(10),
          hoverColor: Colors.white.withValues(alpha: 0.04),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 130,
                        height: 73,
                        color: const Color(0xFF1E1E22),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (stillUrl.isNotEmpty)
                              CachedNetworkImage(
                                imageUrl: stillUrl,
                                fit: BoxFit.cover,
                                placeholder: (ctx, url) => Container(
                                  color: const Color(0xFF1A1A1E),
                                  child: const Center(
                                    child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white38,
                                      ),
                                    ),
                                  ),
                                ),
                                errorWidget: (ctx, url, err) => const Center(
                                  child: Icon(
                                    Icons.movie_outlined,
                                    size: 24,
                                    color: Colors.white24,
                                  ),
                                ),
                              )
                            else
                              const Center(
                                child: Icon(
                                  Icons.movie_outlined,
                                  size: 24,
                                  color: Colors.white24,
                                ),
                              ),
                            if (isPlaying)
                              Container(
                                color: Colors.black.withValues(alpha: 0.4),
                                child: Center(
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: primaryColor,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: primaryColor.withValues(alpha: 0.5),
                                          blurRadius: 8,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      color: Colors.white,
                                      size: 16,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  title,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isPlaying
                                        ? FontWeight.bold
                                        : FontWeight.w600,
                                    color: isPlaying
                                        ? primaryColor
                                        : Colors.white.withValues(alpha: 0.95),
                                    letterSpacing: 0.2,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (lineCount > 1)
                                Container(
                                  margin: const EdgeInsets.only(left: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '$lineCount 线路',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.white.withValues(alpha: 0.65),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (airDate.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              airDate,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: Colors.white.withValues(alpha: 0.45),
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  overview,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (isPlaying && lineCount > 1) ...[
                  const SizedBox(height: 10),
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  const SizedBox(height: 10),
                  WindowsLineSelector(
                    lineCount: lineCount,
                    currUrl: widget.currUrl ?? 1,
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
  }

  Widget _buildGridItem(BuildContext context, int index, Color primaryColor) {
    final i = _filteredList[index];
    final isPlaying = i == widget.currentIndex;
    final title = widget.videoList[i].title;

    return InkWell(
      onTap: () => widget.onEpisodeSelected(i),
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isPlaying
              ? primaryColor.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.04),
          border: Border.all(
            color: isPlaying
                ? primaryColor.withValues(alpha: 0.7)
                : Colors.white.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Center(
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: isPlaying ? FontWeight.bold : FontWeight.w500,
              fontSize: 12.5,
              color: isPlaying ? primaryColor : Colors.white70,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
