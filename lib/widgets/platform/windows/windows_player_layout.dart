import 'dart:io';
import 'package:flutter/material.dart';
import 'package:baka/widgets/common/platform_tooltip.dart';

import 'package:baka/services/playback/playback_content.dart';
import 'package:baka/pages/setting/player_settings_page.dart';
import 'package:baka/services/torrent/torrent_engine.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/baka_player/view.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/widgets/platform/windows/windows_episode_list.dart';
import 'package:baka/widgets/platform/windows/windows_title_bar.dart';
import 'package:baka/widgets/player/player_tab.dart';

class WindowsPlayerLayout extends StatefulWidget {
  final PlaybackContent content;
  final bool inited;
  final PlaybackController controller;
  final DanmakuController danmakuController;
  final ValueNotifier<bool> followNotifier;
  final VoidCallback onSourceTap;
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
  final bool terminalPlaybackFailure;
  final VoidCallback onAiRepair;

  const WindowsPlayerLayout({
    required this.content,
    required this.inited,
    required this.controller,
    required this.danmakuController,
    required this.followNotifier,
    required this.onSourceTap,
    required this.onEpisodeChanged,
    required this.onCastPressed,
    required this.onWatchPartyPressed,
    required this.onPickEpisode,
    required this.onFullScreenChanged,
    required this.onUrlChanged,
    required this.onCommentLinkTap,
    required this.onDownloadPressed,
    required this.onFollowPressed,
    required this.onAiRepair,
    this.isSearching = false,
    this.terminalPlaybackFailure = false,
    super.key,
  });

  @override
  State<WindowsPlayerLayout> createState() => _WindowsPlayerLayoutState();
}

class _WindowsPlayerLayoutState extends State<WindowsPlayerLayout>
    with SingleTickerProviderStateMixin {
  bool _showSidebar = true;
  late final _sidebarTabs = TabController(
    length: 2,
    vsync: this,
    animationDuration: Duration.zero,
  );
  bool _isFullScreen = false;

  @override
  void dispose() {
    _sidebarTabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shouldShowSidebar = _showSidebar && !_isFullScreen;
    final showTitleBar = Platform.isWindows && !_isFullScreen;

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
                    child: TickerMode(
                      enabled: shouldShowSidebar,
                      child: _buildSidebar(context),
                    ),
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
    final content = widget.content;
    final nextIndex = content.currPlayIndex + 1;
    final hasNextEpisode = nextIndex < content.videoList.length;
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
              hasNextEpisode: hasNextEpisode,
              onNextEpisode: hasNextEpisode
                  ? () => widget.onEpisodeChanged(nextIndex)
                  : null,
              onFullScreenChanged: (full) {
                setState(() => _isFullScreen = full);
                widget.onFullScreenChanged(full);
              },
              showPlaybackError: false,
            ),
          if (!widget.inited || widget.terminalPlaybackFailure)
            _buildPlaybackStatus(context),
        ],
      ),
    );
  }

  Widget _buildTopHeaderBar(BuildContext context) {
    final title = widget.content.title;

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
    final torrent = widget.content.torrent;
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
              Icon(Icons.arrow_downward_rounded, size: 13, color: primaryColor),
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
    return PlatformTooltip(
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

  Widget _buildPlaybackStatus(BuildContext context) {
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
                if (!widget.terminalPlaybackFailure) ...[
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
                ] else ...[
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
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
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
                      OutlinedButton.icon(
                        onPressed: widget.onAiRepair,
                        icon: const Icon(Icons.auto_awesome_rounded, size: 17),
                        label: const Text('AI 修复当前源'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white54),
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
                ],
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
          ListenableBuilder(
            listenable: _sidebarTabs,
            builder: (context, _) => _buildSidebarTabs(),
          ),
          Expanded(
            child: TabBarView(
              controller: _sidebarTabs,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                PlayerTab(child: _buildPlaylistTab()),
                _buildCommentTab(),
              ],
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
    final isSelected = _sidebarTabs.index == index;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: () => _sidebarTabs.animateTo(index),
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
    final content = widget.content;

    return Padding(
      key: const ValueKey('intro_tab'),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: WindowsEpisodeList(
        torrent: content.torrent,
        videoList: content.videoList,
        currentIndex: content.currPlayIndex,
        onEpisodeSelected: widget.onEpisodeChanged,
        onDownloadPressed: widget.onDownloadPressed,
        onUrlChanged: widget.onUrlChanged,
        currUrl: content.currUrl,
        sourceNames: content.sourceNames,
        bgmEpisodes: content.bgmEpisodes,
        fallbackCoverUrl: content.coverImageUrl,
        title: content.title,
        bgmInfo: content.bgmInfo,
        followNotifier: widget.followNotifier,
        onFollowPressed: widget.onFollowPressed,
        sourceName: content.sourceName,
        lineName: content.lineName,
        onSourceTap: widget.onSourceTap,
        isSearching: widget.isSearching,
        danmakuController: widget.danmakuController,
      ),
    );
  }

  Widget _buildCommentTab() {
    final content = widget.content;
    final pid = content.commentPostId;
    if (pid == null) {
      return const Center(
        child: Text('此视频没有关联评论', style: TextStyle(color: Colors.white54)),
      );
    }
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
          postId: pid,
          bgmSubjectId: content.bgmInfo.subjectId,
          episodeIndex: content.currPlayIndex,
          onCommentLinkTap: widget.onCommentLinkTap,
        ),
      ),
    );
  }
}
