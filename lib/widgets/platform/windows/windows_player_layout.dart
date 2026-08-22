import 'dart:io';
import 'package:flutter/material.dart';

import 'package:baka/instance.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/pages/setting/player_settings_page.dart';
import 'package:baka/services/torrent/torrent_engine.dart';
import 'package:baka/services/torrent/torrent_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/baka_player/view.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:baka/widgets/platform/windows/windows_episode_list.dart';
import 'package:baka/widgets/platform/windows/windows_title_bar.dart';

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

  @override
  Widget build(BuildContext context) {
    final shouldShowSidebar = _showSidebar && !_isFullScreen;
    final showTitleBar =
        Platform.isWindows && Instances.isDesktopPlatform && !_isFullScreen;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Row(
            children: [
              Expanded(child: _buildPlayerArea(context)),
              AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                width: shouldShowSidebar ? 380 : 0,
                child: ClipRect(
                  child: OverflowBox(
                    minWidth: 380,
                    maxWidth: 380,
                    alignment: Alignment.topLeft,
                    child: _buildSidebar(context),
                  ),
                ),
              ),
            ],
          ),
          if (showTitleBar)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 32,
              child: WindowsTitleBar(
                backgroundColor: Colors.transparent,
                foregroundColor: Colors.white70,
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
              hasNextEpisode:
                  widget.currPlayIndex + 1 < widget.videoList.length,
              onNextEpisode: widget.currPlayIndex + 1 < widget.videoList.length
                  ? () => widget.onEpisodeChanged(widget.currPlayIndex + 1)
                  : null,
              onFullScreenChanged: (full) {
                setState(() => _isFullScreen = full);
                widget.onFullScreenChanged(full);
              },
            ),
          if (!widget.inited) _buildLoadingState(context),
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: Colors.black54,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.white,
              size: 18,
            ),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: '返回',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
          onTap: () => PlayerSettingsPage.show(context, widget.controller),
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
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_upward_rounded, size: 13, color: primaryColor),
              const SizedBox(width: 2),
              Text(
                speedText,
                style: TextStyle(
                  fontSize: 11.5,
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
      child: InkResponse(
        onTap: onTap,
        radius: 18,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 19,
            color: isActive ? Colors.white : Colors.white70,
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
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    color: primaryColor,
                    strokeWidth: 2.5,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  widget.isSearching ? '正在自动匹配源中...' : '正在加载视频...',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
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
                  size: 42,
                ),
                const SizedBox(height: 10),
                const Text(
                  '播放失败，请换源或重试',
                  style: TextStyle(color: Colors.white, fontSize: 13.5),
                ),
                const SizedBox(height: 14),
                ElevatedButton.icon(
                  onPressed: widget.onSourceTap,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 17),
                  label: const Text('切换播放源'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
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
      width: 380,
      decoration: const BoxDecoration(
        color: Color(0xFF141416),
        border: Border(left: BorderSide(color: Colors.white12, width: 1)),
      ),
      child: Column(
        children: [
          _buildSidebarTabs(),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
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
      margin: const EdgeInsets.fromLTRB(14, 38, 14, 8),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF202024),
        borderRadius: BorderRadius.circular(8),
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
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: () => setState(() => _sidebarTabIndex = index),
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF2E2E34) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: isSelected ? Colors.white : Colors.white60,
              ),
              const SizedBox(width: 5),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected ? Colors.white : Colors.white60,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaylistTab() {
    final rawEpisodes = widget.data['bgmDetailData']?['episodes'];
    final bgmEpisodes = (rawEpisodes is List)
        ? rawEpisodes.cast<Map<String, dynamic>>()
        : null;

    final summary =
        widget.data['summary']?.toString() ??
        widget.data['content']?.toString() ??
        '';

    return Padding(
      key: const ValueKey('intro_tab'),
      padding: const EdgeInsets.symmetric(horizontal: 12),
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
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
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
