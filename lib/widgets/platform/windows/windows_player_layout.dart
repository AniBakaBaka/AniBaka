import 'package:flutter/material.dart';

import 'package:baka/models/playback_episode.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:baka/services/torrent/torrent_engine.dart';
import 'package:baka/services/torrent/torrent_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/baka_player/view.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:baka/widgets/platform/windows/windows_episode_list.dart';

class WindowsPlayerLayout extends StatefulWidget {
  final Map data;
  final List<PlaybackEpisode> videoList;
  final int currPlayIndex;
  final int currUrl;
  final List<String>? sourceNames;
  final bool inited;
  final PlaybackController controller;
  final DanmakuController danmakuController;
  final BgmInfo bgmInfo;
  final ValueNotifier<bool> followNotifier;
  final List<String> cachedTags;
  final String sourceName;
  final String? lineName;
  final VoidCallback onShowDetail;
  final VoidCallback onSourceTap;
  final GlobalKey<CIslandCommentWidgetState> commentKey;
  final void Function(int) onEpisodeChanged;
  final VoidCallback onCastPressed;
  final VoidCallback onWatchPartyPressed;
  final VoidCallback onPickEpisode;
  final ValueChanged<bool> onFullScreenChanged;
  final void Function(int) onUrlChanged;
  final void Function(String, String?, String) onCommentLinkTap;
  final VoidCallback onDownloadPressed;
  final VoidCallback onFollowPressed;
  final bool isSearching;

  const WindowsPlayerLayout({
    required this.data,
    required this.videoList,
    required this.currPlayIndex,
    required this.currUrl,
    required this.inited,
    required this.controller,
    required this.danmakuController,
    required this.followNotifier,
    required this.cachedTags,
    required this.sourceName,
    required this.lineName,
    required this.onShowDetail,
    required this.onSourceTap,
    required this.commentKey,
    required this.onEpisodeChanged,
    required this.onCastPressed,
    required this.onWatchPartyPressed,
    required this.onPickEpisode,
    required this.onFullScreenChanged,
    required this.onUrlChanged,
    required this.onCommentLinkTap,
    required this.onDownloadPressed,
    required this.onFollowPressed,
    this.isSearching = false,
    this.sourceNames,
    this.bgmInfo = const BgmInfo(),
    super.key,
  });

  @override
  State<WindowsPlayerLayout> createState() => _WindowsPlayerLayoutState();
}

class _WindowsPlayerLayoutState extends State<WindowsPlayerLayout> {
  bool _showSidebar = true;
  int _sidebarTabIndex = 0;
  bool _isFullScreen = false;

  String get _currentEpisodeTitle {
    final episodes = widget.data['bgmDetailData']?['episodes'];
    if (episodes is List &&
        widget.currPlayIndex >= 0 &&
        widget.currPlayIndex < episodes.length) {
      final ep = episodes[widget.currPlayIndex];
      final cn = ep['name_cn']?.toString().trim();
      final name = ep['name']?.toString().trim();
      if (cn != null && cn.isNotEmpty) return cn;
      if (name != null && name.isNotEmpty) return name;
    }
    if (widget.currPlayIndex >= 0 &&
        widget.currPlayIndex < widget.videoList.length) {
      return widget.videoList[widget.currPlayIndex].title;
    }
    return '第${widget.currPlayIndex + 1}话';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Row(
        children: [
          Expanded(
            child: _buildPlayerArea(context),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            width: _showSidebar && !_isFullScreen ? 400 : 0,
            child: ClipRect(
              child: OverflowBox(
                minWidth: 400,
                maxWidth: 400,
                alignment: Alignment.topLeft,
                child: _buildSidebar(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerArea(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.inited)
            BakaPlayer(
              controller: widget.controller,
              canSearchSource: true,
              danmakuEnabled: true,
              headerControl: _buildHeaderControls(context),
              full: false,
              onPickEpisode: widget.onPickEpisode,
              hasNextEpisode: widget.currPlayIndex + 1 < widget.videoList.length,
              onNextEpisode: widget.currPlayIndex + 1 < widget.videoList.length
                  ? () => widget.onEpisodeChanged(widget.currPlayIndex + 1)
                  : null,
              onFullScreenChanged: (full) {
                setState(() => _isFullScreen = full);
                widget.onFullScreenChanged(full);
              },
            ),
          if (!widget.inited)
            _buildLoadingState(context),
          ValueListenableBuilder<PlaybackCoreState>(
            valueListenable: widget.controller.core,
            builder: (context, core, _) {
              if (core.failed) {
                return _buildErrorState(context);
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTopHeaderBar(BuildContext context) {
    final title = widget.data['title']?.toString() ?? '';
    final epTitle = _currentEpisodeTitle;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.8),
            Colors.black.withValues(alpha: 0.0),
          ],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.white,
              size: 20,
            ),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: '返回',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  'S1E${widget.currPlayIndex + 1}: $epTitle',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.65),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          _buildNetworkSpeedBadge(),
          _buildHeaderIconButton(
            icon: _showSidebar
                ? Icons.splitscreen_rounded
                : Icons.view_sidebar_outlined,
            tooltip: _showSidebar ? '隐藏侧边栏' : '显示侧边栏',
            isActive: _showSidebar,
            onTap: () => setState(() => _showSidebar = !_showSidebar),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderControls(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildNetworkSpeedBadge(),
        _buildHeaderIconButton(
          icon: Icons.group_rounded,
          tooltip: '一起看',
          onTap: widget.onWatchPartyPressed,
        ),
        _buildHeaderIconButton(
          icon: Icons.cast_connected_rounded,
          tooltip: '投屏',
          onTap: widget.onCastPressed,
        ),
        _buildHeaderIconButton(
          icon: _showSidebar
              ? Icons.splitscreen_rounded
              : Icons.view_sidebar_outlined,
          tooltip: _showSidebar ? '隐藏侧边栏' : '显示侧边栏',
          isActive: _showSidebar,
          onTap: () => setState(() => _showSidebar = !_showSidebar),
        ),
        _buildHeaderIconButton(
          icon: Icons.settings_outlined,
          tooltip: '播放设置',
          onTap: () => NavigationService.showPlayerSettings(
            context,
            widget.controller,
          ),
        ),
      ],
    );
  }

  Widget _buildNetworkSpeedBadge() {
    final torrent = TorrentService.instance;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return ValueListenableBuilder<TorrentStats?>(
      valueListenable: torrent.statsNotifier,
      builder: (context, stats, _) {
        final speed = stats?.downloadSpeed ?? 0.0;
        if (speed <= 0) return const SizedBox.shrink();
        final speedText = formatBytesPerSecond(speed);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_upward_rounded,
                size: 14,
                color: primaryColor,
              ),
              const SizedBox(width: 2),
              Text(
                speedText,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: primaryColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeaderIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool isActive = false,
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 300),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Icon(
            icon,
            size: 20,
            color: isActive
                ? Colors.white
                : Colors.white.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildTopHeaderBar(context),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(
                    color: primaryColor,
                    strokeWidth: 2.5,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  widget.isSearching ? '正在自动匹配源中...' : '正在加载视频...',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildTopHeaderBar(context),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  color: Colors.redAccent,
                  size: 48,
                ),
                const SizedBox(height: 12),
                const Text(
                  '播放失败，请换源或重试',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: widget.onSourceTap,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                  label: const Text('切换播放源'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    return Container(
      width: 400,
      decoration: BoxDecoration(
        color: const Color(0xFF141416),
        border: Border(
          left: BorderSide(
            color: Colors.white.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          _buildSidebarTabs(),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _sidebarTabIndex == 0
                  ? _buildPlaylistTab()
                  : _buildCommentTab(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarTabs() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF202024),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildTabButton(
              index: 0,
              icon: Icons.info_outline_rounded,
              title: '简介',
            ),
          ),
          Expanded(
            child: _buildTabButton(
              index: 1,
              icon: Icons.chat_bubble_outline_rounded,
              title: '互动评论',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton({
    required int index,
    required IconData icon,
    required String title,
  }) {
    final isSelected = _sidebarTabIndex == index;
    return InkWell(
      onTap: () => setState(() => _sidebarTabIndex = index),
      borderRadius: BorderRadius.circular(7),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF2D2D32) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? Colors.white : Colors.white54,
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? Colors.white : Colors.white54,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistTab() {
    final rawEpisodes = widget.data['bgmDetailData']?['episodes'];
    final bgmEpisodes = (rawEpisodes is List)
        ? rawEpisodes.cast<Map<String, dynamic>>()
        : null;

    final summary = widget.data['summary']?.toString() ??
        widget.data['content']?.toString() ??
        '';

    return Padding(
      key: const ValueKey('intro_tab'),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: WindowsEpisodeList(
        videoList: widget.videoList,
        currentIndex: widget.currPlayIndex,
        onEpisodeSelected: widget.onEpisodeChanged,
        onDownloadPressed: widget.onDownloadPressed,
        onUrlSelected: (_, urlIndex) => widget.onUrlChanged(urlIndex),
        currUrl: widget.currUrl,
        sourceNames: widget.sourceNames,
        bgmId: widget.bgmInfo.subjectId,
        bgmEpisodes: bgmEpisodes,
        fallbackCoverUrl: BgmUtils.resolveCoverImage(
          widget.data,
          bgmInfo: widget.bgmInfo,
        ),
        title: widget.data['title']?.toString() ?? '',
        summary: summary,
        bgmInfo: widget.bgmInfo,
        followNotifier: widget.followNotifier,
        onFollowPressed: widget.onFollowPressed,
        sourceName: widget.sourceName,
        lineName: widget.lineName,
        onSourceTap: widget.onSourceTap,
        isSearching: widget.isSearching,
        danmakuController: widget.danmakuController,
        onShowDetail: widget.onShowDetail,
        cachedTags: widget.cachedTags,
      ),
    );
  }

  Widget _buildCommentTab() {
    final isAdapter = widget.data['sourceUrl'] != null;
    final pid = (isAdapter && widget.bgmInfo.subjectId != null)
        ? widget.bgmInfo.subjectId!
        : (int.tryParse(widget.data['id']?.toString() ?? '') ?? 11);
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Theme(
      key: const ValueKey('comment_tab'),
      data: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF141416),
        colorScheme: ColorScheme.dark(
          primary: primaryColor,
          surface: const Color(0xFF1E1E22),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: CIslandCommentWidget(
          key: widget.commentKey,
          postId: pid,
          bgmSubjectId: widget.bgmInfo.subjectId,
          episodeIndex: widget.currPlayIndex,
          onCommentLinkTap: widget.onCommentLinkTap,
        ),
      ),
    );
  }
}
