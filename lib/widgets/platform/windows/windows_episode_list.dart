import 'package:baka/services/playback/playback_content.dart';
import 'package:baka/theme.dart';
import 'package:baka/utils/json_values.dart';
import 'package:flutter/material.dart';
import 'package:baka/widgets/common/platform_tooltip.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/widgets/platform/windows/windows_line_selector.dart';
import 'package:baka/api/anibaka_api.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/widgets/danmaku/danmaku_list_sheet.dart';
import 'package:baka/widgets/player/bgm_follow_pill.dart';
import 'package:baka/widgets/player/download_indicators.dart';

class WindowsEpisodeList extends StatefulWidget {
  const WindowsEpisodeList({
    required this.content,
    required this.onEpisodeSelected,
    required this.onUrlChanged,
    super.key,
    this.followNotifier,
    this.onFollowPressed,
    this.onSourceTap,
    this.isSearching = false,
    this.danmakuController,
    this.onDownloadPressed,
  });

  final PlaybackContent content;
  final ValueChanged<int> onEpisodeSelected;
  final ValueChanged<int> onUrlChanged;
  final VoidCallback? onDownloadPressed;
  final ValueNotifier<bool>? followNotifier;
  final VoidCallback? onFollowPressed;
  final VoidCallback? onSourceTap;
  final bool isSearching;
  final DanmakuController? danmakuController;

  @override
  State<WindowsEpisodeList> createState() => _WindowsEpisodeListState();
}

class _WindowsEpisodeListState extends State<WindowsEpisodeList> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _ascending = true;
  bool _isGridView = false;
  bool _isEpisodesExpanded = true;
  List<int>? _filteredList;

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(WindowsEpisodeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_filteredList != null) _filteredList = _buildFilteredList();
  }

  List<int>? _buildFilteredList() {
    final query = _searchController.text;
    if (query.trim().isEmpty) return null;
    return PlaybackEpisodeCatalog.filterIndexes(
      widget.content.videoList,
      searchQuery: query,
      ascending: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.content;
    final videoList = content.videoList;
    final currentIndex = content.currPlayIndex;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final source = trimmed(content.sourceName) ?? '切换播放源';
    final line = trimmed(content.lineName);
    final danmaku = widget.danmakuController;
    final itemCount = _filteredList?.length ?? videoList.length;
    final episodes = SliverChildBuilderDelegate(
      (context, index) {
        final position = _ascending ? index : itemCount - 1 - index;
        final i = _filteredList?[position] ?? position;
        final item = videoList[i];
        final isPlaying = i == currentIndex;
        if (_isGridView) {
          return Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              onTap: () => widget.onEpisodeSelected(i),
              borderRadius: BorderRadius.circular(6),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: isPlaying
                      ? primaryColor.withValues(alpha: 0.18)
                      : const Color(0xFF1B1B1F),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isPlaying
                        ? primaryColor.withValues(alpha: 0.6)
                        : Colors.white10,
                    width: 0.8,
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                alignment: Alignment.center,
                child: Text(
                  item.title,
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
        return _buildEpisodeRow(context, i, item, isPlaying, primaryColor);
      },
      childCount: itemCount,
      addAutomaticKeepAlives: false,
    );

    return CustomScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAnimeHeader(),
              const SizedBox(height: 8),
              _buildActionRow(
                context: context,
                label: '播放源',
                action: '切换源',
                accent: primaryColor,
                onTap: widget.onSourceTap,
                child: Text(
                  widget.isSearching
                      ? '正在自动匹配源中...'
                      : line == null
                      ? source
                      : '$source · $line',
                ),
              ),
              const SizedBox(height: 6),
              _buildActionRow(
                context: context,
                label: '弹幕库',
                action: '匹配管理',
                onTap: danmaku == null
                    ? null
                    : () => DanmakuListSheet.show(
                        context,
                        danmaku,
                        defaultTitle: content.title,
                        defaultEpisode: currentIndex + 1,
                      ),
                child: danmaku == null
                    ? const Text('未开启', style: TextStyle(color: Colors.white54))
                    : ListenableBuilder(
                        listenable: danmaku,
                        builder: (context, _) => Text(danmaku.loadStatus),
                      ),
              ),
              const SizedBox(height: 12),
              BtProgressIndicator(
                torrent: content.torrent,
                padding: const EdgeInsets.only(bottom: 12),
              ),
              _buildEpisodeHeaderSection(),
              const SizedBox(height: 6),
            ],
          ),
        ),
        if (_isEpisodesExpanded) ...[
          if (itemCount == 0)
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
          else
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 20),
              sliver: _isGridView
                  ? SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 2.0,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                      delegate: episodes,
                    )
                  : SliverList(delegate: episodes),
            ),
        ] else
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }

  Widget _buildAnimeHeader() {
    final content = widget.content;
    final title = content.title.trim();

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
          if (widget.followNotifier != null &&
              widget.onFollowPressed != null) ...[
            const SizedBox(width: 6),
            ValueListenableBuilder<bool>(
              valueListenable: widget.followNotifier!,
              builder: (context, isFollowed, _) => BgmFollowPill(
                title: title,
                bgmInfo: content.bgmInfo,
                isFollowed: isFollowed,
                onFollowPressed: widget.onFollowPressed!,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionRow({
    required BuildContext context,
    required String label,
    required String action,
    required Widget child,
    VoidCallback? onTap,
    Color? accent,
  }) {
    return Material(
      color: const Color(0xFF1B1B1F),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: Colors.white10, width: 0.8),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white54,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DefaultTextStyle(
                  style: context.withAppFont(
                    const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  child: child,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: accent?.withValues(alpha: 0.15) ?? Colors.white10,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  action,
                  style: TextStyle(
                    fontSize: 11,
                    color: accent ?? Colors.white70,
                    fontWeight: accent == null
                        ? FontWeight.w500
                        : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEpisodeHeaderSection() {
    final hasQuery = _searchController.text.isNotEmpty;

    return Column(
      children: [
        InkWell(
          onTap: () =>
              setState(() => _isEpisodesExpanded = !_isEpisodesExpanded),
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
                  '(${widget.content.videoList.length}话)',
                  style: const TextStyle(fontSize: 11.5, color: Colors.white54),
                ),
                const Spacer(),
                Text(
                  _isEpisodesExpanded ? '收起' : '展开',
                  style: const TextStyle(fontSize: 11.5, color: Colors.white38),
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
                    onChanged: (_) =>
                        setState(() => _filteredList = _buildFilteredList()),
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索剧集...',
                      hintStyle: const TextStyle(
                        color: Colors.white30,
                        fontSize: 12.0,
                      ),
                      prefixIcon: const Icon(
                        Icons.search,
                        color: Colors.white38,
                        size: 16,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 30,
                        minHeight: 32,
                      ),
                      suffixIcon: hasQuery
                          ? IconButton(
                              icon: const Icon(
                                Icons.clear,
                                color: Colors.white54,
                                size: 14,
                              ),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _filteredList = null);
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 28,
                                minHeight: 32,
                              ),
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
                icon: _isGridView
                    ? Icons.view_list_rounded
                    : Icons.grid_view_rounded,
                onPressed: () => setState(() => _isGridView = !_isGridView),
                tooltip: _isGridView ? '列表视图' : '网格视图',
              ),
              _buildIconButton(
                icon: _ascending
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
                onPressed: () => setState(() => _ascending = !_ascending),
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
    return PlatformTooltip(
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

  Widget _buildEpisodeRow(
    BuildContext context,
    int index,
    PlaybackEpisode item,
    bool isPlaying,
    Color primaryColor,
  ) {
    final content = widget.content;
    final bgmId = content.bgmInfo.subjectId;
    final stillFuture = bgmId != null && bgmId > 0
        ? AniBakaApi.getEpisodeStills(
            bgmId: bgmId,
            season: 1,
            episode: index + 1,
          )
        : null;
    if (stillFuture == null) {
      return _buildEpisodeRowContent(index, item, isPlaying, primaryColor, null);
    }
    return FutureBuilder<Map<String, dynamic>?>(
      future: stillFuture,
      builder: (context, snapshot) => _buildEpisodeRowContent(
        index,
        item,
        isPlaying,
        primaryColor,
        snapshot.data,
      ),
    );
  }

  Widget _buildEpisodeRowContent(
    int index,
    PlaybackEpisode item,
    bool isPlaying,
    Color primaryColor,
    Map<String, dynamic>? still,
  ) {
    final content = widget.content;
    final episode = index < content.bgmEpisodes.length
        ? content.bgmEpisodes[index]
        : null;
    final stillName = trimmed(still?['name']);
    final name = episode != null
        ? trimmed(episode['name_cn']) ?? trimmed(episode['name']) ?? item.title
        : stillName ?? item.title.trim();
    final rawTitle = episode == null && stillName == null;
    final title =
        name.startsWith('S') ||
            name.startsWith('第') ||
            (rawTitle && (name.contains('话') || name.contains('集')))
        ? name
        : 'S1E${index + 1}: $name';
    final airDate =
        trimmed(episode?['airdate']) ?? trimmed(still?['air_date']) ?? '';
    final overview =
        trimmed(still?['overview']) ?? trimmed(episode?['desc']) ?? '暂无本集剧情简介';
    final stillUrl =
        trimmed(still?['still_thumb']) ??
        trimmed(still?['still_url']) ??
        content.coverImageUrl ??
        '';
    final lineCount = item.availableLineIndexes.length;
    const placeholder = Center(
      child: Icon(Icons.movie_outlined, size: 22, color: Colors.white24),
    );

    return AnimatedContainer(
      key: ValueKey((content.bgmInfo.subjectId, index)),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: isPlaying ? const Color(0xFF222226) : const Color(0xFF18181B),
        border: Border.all(
          color: isPlaying
              ? primaryColor.withValues(alpha: 0.6)
              : Colors.white10,
          width: 0.8,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => widget.onEpisodeSelected(index),
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
                    ClipRRect(
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
                                fadeInDuration: const Duration(
                                  milliseconds: 150,
                                ),
                                fadeOutDuration: const Duration(
                                  milliseconds: 150,
                                ),
                                placeholder: (_, _) => placeholder,
                                errorWidget: (_, _, _) => placeholder,
                              )
                            else
                              placeholder,
                            if (isPlaying)
                              ColoredBox(
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
                    ),
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
                                    fontWeight: isPlaying
                                        ? FontWeight.bold
                                        : FontWeight.w600,
                                    color: isPlaying
                                        ? primaryColor
                                        : Colors.white,
                                    height: 1.25,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (lineCount > 1)
                                Container(
                                  margin: const EdgeInsets.only(left: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: primaryColor.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: primaryColor.withValues(
                                        alpha: 0.4,
                                      ),
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
                              style: const TextStyle(
                                fontSize: 11.0,
                                color: Colors.white38,
                              ),
                            ),
                          ],
                          if (overview.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              overview,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Colors.white60,
                                height: 1.35,
                              ),
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
                    child: Divider(
                      height: 1,
                      thickness: 0.6,
                      color: Colors.white12,
                    ),
                  ),
                  WindowsLineSelector(
                    availableLineIndexes: item.availableLineIndexes,
                    currUrl: content.currUrl,
                    onUrlChanged: widget.onUrlChanged,
                    sourceNames: content.sourceNames,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
