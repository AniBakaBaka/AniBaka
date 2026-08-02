import 'dart:io';
import 'package:baka/utils/format_utils.dart';
import 'package:flutter/material.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/widgets/platform/windows/windows_episode_list.dart';
import 'package:baka/widgets/baka_player/index.dart';
import 'package:baka/widgets/danmaku/view.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:baka/services/torrent/torrent_service.dart';
import 'package:baka/services/torrent/torrent_engine.dart';
import 'package:baka/services/torrent/piece_manager.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/widgets/player/video_detail_card.dart';

class WindowsPlayerLayout extends StatelessWidget {
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
  final VoidCallback onPickEpisode;
  final ValueChanged<bool> onFullScreenChanged;
  final void Function(int) onUrlChanged;
  final void Function(String, String?, String) onCommentLinkTap;
  final VoidCallback onDownloadPressed;
  final VoidCallback onFollowPressed;

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
    required this.onPickEpisode,
    required this.onFullScreenChanged,
    required this.onUrlChanged,
    required this.onCommentLinkTap,
    required this.onDownloadPressed,
    required this.onFollowPressed,
    this.sourceNames,
    this.bgmInfo = const BgmInfo(),
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Column(
        children: [
          if (Platform.isWindows || Platform.isMacOS)
            _DesktopPlayerTitleBar(title: data['title'] ?? ''),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: _PlayerArea(
                          data: data,
                          inited: inited,
                          controller: controller,
                          danmakuController: danmakuController,
                          onCastPressed: onCastPressed,
                          videoList: videoList,
                          currentEpisodeIndex: currPlayIndex,
                          onEpisodeChanged: onEpisodeChanged,
                          onPickEpisode: onPickEpisode,
                          onFullScreenChanged: onFullScreenChanged,
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: VideoDetailCard(
                          detail: data,
                          bgmInfo: bgmInfo,
                          followNotifier: followNotifier,
                          cachedTags: cachedTags,
                          sourceName: sourceName,
                          lineName: lineName,
                          onSourceTap: onSourceTap,
                          onFollowPressed: onFollowPressed,
                          onShowDetail: onShowDetail,
                        ),
                      ),
                      const SliverToBoxAdapter(
                        child: _DesktopBtProgressIndicator(),
                      ),
                      SliverToBoxAdapter(
                        child: _DescriptionSection(
                          content: data['content'] ?? '',
                        ),
                      ),
                    ],
                  ),
                ),
                _PlayerSidebar(
                  data: data,
                  videoList: videoList,
                  currPlayIndex: currPlayIndex,
                  currUrl: currUrl,
                  sourceNames: sourceNames,
                  bgmInfo: bgmInfo,
                  commentKey: commentKey,
                  onEpisodeChanged: onEpisodeChanged,
                  onDownloadPressed: onDownloadPressed,
                  onUrlChanged: onUrlChanged,
                  onCommentLinkTap: onCommentLinkTap,
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'comment_fab',
        onPressed: () => CommentInputWidget.show(context).then((result) {
          if (result is String && result.isNotEmpty) {
            commentKey.currentState?.sendComment(result);
          }
        }),
        backgroundColor: theme.colorScheme.secondary,
        tooltip: '发表评论',
        child: const Icon(Icons.comment, color: Colors.white),
      ),
    );
  }
}

class _PlayerArea extends StatelessWidget {
  final Map data;
  final bool inited;
  final PlaybackController controller;
  final DanmakuController danmakuController;
  final VoidCallback onCastPressed;
  final List<PlaybackEpisode> videoList;
  final int currentEpisodeIndex;
  final void Function(int) onEpisodeChanged;
  final VoidCallback onPickEpisode;
  final ValueChanged<bool> onFullScreenChanged;

  const _PlayerArea({
    required this.data,
    required this.inited,
    required this.controller,
    required this.danmakuController,
    required this.onCastPressed,
    required this.videoList,
    required this.currentEpisodeIndex,
    required this.onEpisodeChanged,
    required this.onPickEpisode,
    required this.onFullScreenChanged,
  });

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    return Container(
      constraints: BoxConstraints(maxHeight: screenHeight * 0.75),
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: ValueListenableBuilder<PlaybackCoreState>(
            valueListenable: controller.core,
            builder: (context, core, _) {
              if (core.failed) {
                return _buildErrorState(context);
              }
              if (!inited) return _loadingState;
              return BakaPlayer(
                detail: data,
                danmuWidget: DanmakuView(controller: danmakuController),
                headerControl: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.cast_connected_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                        onPressed: onCastPressed,
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.more_vert,
                          color: Colors.white,
                          size: 24,
                        ),
                        onPressed: () => NavigationService.showPlayerSettings(
                          context,
                          controller,
                        ),
                      ),
                    ],
                  ),
                ),
                controller: controller,
                full: false,
                onPickEpisode: onPickEpisode,
                hasNextEpisode: currentEpisodeIndex + 1 < videoList.length,
                onNextEpisode: currentEpisodeIndex + 1 < videoList.length
                    ? () => onEpisodeChanged(currentEpisodeIndex + 1)
                    : null,
                onFullScreenChanged: onFullScreenChanged,
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('播放失败，请换源或到BAKA报错', style: TextStyle(color: Colors.white)),
          const SizedBox(height: 10),
          if (data['title'] != null)
            ElevatedButton.icon(
              onPressed: () => NavigationService.toSearch(
                context,
                keyword: data['title'],
                initialSource: 2,
              ),
              icon: const Icon(Icons.search, color: Colors.white),
              label: const Text('搜索番剧源', style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.withValues(alpha: 0.7),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static const _loadingState = Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(color: Colors.white),
        ),
        SizedBox(height: 16),
        Text('正在加载播放器...', style: TextStyle(color: Colors.white, fontSize: 14)),
      ],
    ),
  );
}

class _PlayerSidebar extends StatelessWidget {
  final Map data;
  final List<PlaybackEpisode> videoList;
  final int currPlayIndex;
  final int currUrl;
  final List<String>? sourceNames;
  final BgmInfo bgmInfo;
  final GlobalKey<CIslandCommentWidgetState> commentKey;
  final void Function(int) onEpisodeChanged;
  final VoidCallback onDownloadPressed;
  final void Function(int) onUrlChanged;
  final void Function(String, String?, String) onCommentLinkTap;

  const _PlayerSidebar({
    required this.data,
    required this.videoList,
    required this.currPlayIndex,
    required this.currUrl,
    required this.bgmInfo,
    required this.commentKey,
    required this.onEpisodeChanged,
    required this.onDownloadPressed,
    required this.onUrlChanged,
    required this.onCommentLinkTap,
    this.sourceNames,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 320, maxWidth: 360),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
      ),
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            _buildTabBar(theme),
            Expanded(
              child: TabBarView(
                children: [_buildEpisodeTab(), _buildCommentTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar(ThemeData theme) => Container(
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(
          color: theme.dividerColor.withValues(alpha: 0.1),
          width: 1,
        ),
      ),
    ),
    child: TabBar(
      tabs: const [
        Tab(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.playlist_play_rounded, size: 18),
              SizedBox(width: 8),
              Text('播放列表'),
            ],
          ),
        ),
        Tab(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline_rounded, size: 18),
              SizedBox(width: 8),
              Text('互动评论'),
            ],
          ),
        ),
      ],
      labelColor: theme.colorScheme.primary,
      unselectedLabelColor: theme.textTheme.bodyMedium?.color?.withValues(
        alpha: 0.6,
      ),
      labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
      unselectedLabelStyle: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      indicatorSize: TabBarIndicatorSize.label,
      indicatorWeight: 3,
      dividerColor: Colors.transparent,
      splashFactory: NoSplash.splashFactory,
    ),
  );

  Widget _buildEpisodeTab() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: WindowsEpisodeList(
      videoList: videoList,
      currentIndex: currPlayIndex,
      onEpisodeSelected: onEpisodeChanged,
      onDownloadPressed: onDownloadPressed,
      onUrlSelected: (_, urlIndex) => onUrlChanged(urlIndex),
      currUrl: currUrl,
      sourceNames: sourceNames,
    ),
  );

  Widget _buildCommentTab() {
    final isAdapter = data['sourceUrl'] != null;
    final pid = (isAdapter && bgmInfo.subjectId != null)
        ? bgmInfo.subjectId!
        : (int.tryParse(data['id']?.toString() ?? '') ?? 11);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: CIslandCommentWidget(
        key: commentKey,
        postId: pid,
        bgmSubjectId: bgmInfo.subjectId,
        episodeIndex: currPlayIndex,
        onCommentLinkTap: onCommentLinkTap,
      ),
    );
  }
}

/// 简介区域
class _DescriptionSection extends StatelessWidget {
  final String content;

  const _DescriptionSection({required this.content});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '简介',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          MarkdownBody(
            selectable: true,
            data: content,
            onTapLink: (_, url, _) =>
                launchUrlString(url!, mode: LaunchMode.externalApplication),
            styleSheet: MarkdownStyleSheet(
              blockquotePadding: const EdgeInsets.only(left: 6),
              blockquoteDecoration: BoxDecoration(
                border: Border(
                  left: BorderSide(width: 1, color: theme.colorScheme.primary),
                ),
              ),
              blockquote: const TextStyle(fontSize: 14),
              code: const TextStyle(fontFamily: 'Source Code Pro'),
              a: TextStyle(color: theme.colorScheme.primary),
              p: TextStyle(
                fontSize: 14,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 桌面播放器标题栏组件（Windows/macOS 通用）
class _DesktopPlayerTitleBar extends StatelessWidget {
  final String title;

  const _DesktopPlayerTitleBar({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.textTheme.bodyMedium?.color;
    final isMac = Platform.isMacOS;

    IconButton btn(
      IconData icon,
      VoidCallback onPressed,
      String tooltip, {
      double size = 16,
      Color? iconColor,
    }) => IconButton(
      icon: Icon(icon, size: size, color: iconColor ?? color),
      onPressed: onPressed,
      tooltip: tooltip,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
    );

    return GestureDetector(
      onPanStart: (_) => appWindow.startDragging(),
      child: Container(
        width: double.infinity,
        height: isMac ? 40.0 : 30.0,
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          border: isMac
              ? Border(
                  bottom: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                )
              : null,
        ),
        child: Row(
          children: [
            if (isMac) const SizedBox(width: 80),
            btn(
              Icons.arrow_back,
              () => Navigator.of(context).pop(),
              '返回',
              size: isMac ? 20.0 : 16.0,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!isMac) ...[
              btn(Icons.minimize, () => appWindow.minimize(), '最小化'),
              btn(
                Icons.crop_square,
                () => appWindow.maximizeOrRestore(),
                '最大化/还原',
              ),
              btn(
                Icons.close,
                () => appWindow.close(),
                '关闭',
                iconColor: Colors.red,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 桌面端 BT 下载进度指示器
class _DesktopBtProgressIndicator extends StatelessWidget {
  const _DesktopBtProgressIndicator();

  @override
  Widget build(BuildContext context) {
    final torrent = TorrentService.instance;
    return ValueListenableBuilder<TorrentStats?>(
      valueListenable: torrent.statsNotifier,
      builder: (context, stats, _) {
        if (stats == null || stats.state == TorrentState.idle) {
          return const SizedBox.shrink();
        }
        return _buildIndicator(context, torrent, stats);
      },
    );
  }

  Widget _buildIndicator(
    BuildContext context,
    TorrentService torrent,
    TorrentStats stats,
  ) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final bodyColor = theme.textTheme.bodyMedium?.color;
    const readyColor = Color(0xFF34C759);

    final (stateText, stateIcon, stateColor) = switch (stats.state) {
      TorrentState.resolving => (
        '解析中',
        Icons.manage_search_rounded,
        theme.colorScheme.secondary,
      ),
      TorrentState.connecting => (
        '连接 Peers',
        Icons.sync_rounded,
        theme.colorScheme.secondary,
      ),
      TorrentState.downloading => (
        '${(stats.progress * 100).toStringAsFixed(1)}%',
        Icons.downloading_rounded,
        primary,
      ),
      TorrentState.seeding => (
        '做种中',
        Icons.check_circle_outline_rounded,
        readyColor,
      ),
      TorrentState.error => (
        torrent.engine?.errorMessage ?? '错误',
        Icons.error_outline_rounded,
        theme.colorScheme.error,
      ),
      _ => ('', Icons.help, theme.colorScheme.error),
    };
    if (stats.state == TorrentState.idle) return const SizedBox.shrink();

    final readyToPlay = stats.readyToPlay;
    final speed = stats.downloadSpeed;
    final uploadSpeed = stats.uploadSpeed;
    final peers = stats.peers;
    final total = stats.totalBytes;
    final uploadedBytes = stats.uploadedBytes;
    final contiguous = stats.contiguousBytes;
    final required = stats.bufferRequiredBytes;
    final remaining = (required - contiguous).clamp(0, required);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(stateIcon, size: 15, color: stateColor),
                const SizedBox(width: 6),
                Text(
                  'BT $stateText',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: stateColor,
                  ),
                ),
                if (speed > 0 || uploadSpeed > 0) ...[
                  const SizedBox(width: 10),
                  Icon(
                    Icons.arrow_downward_rounded,
                    size: 12,
                    color: primary.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    formatBytesPerSecond(speed),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.arrow_upward_rounded,
                    size: 12,
                    color: Colors.orange.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    formatBytesPerSecond(uploadSpeed),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange,
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  readyToPlay ? '可播放' : '待缓冲',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: readyToPlay
                        ? readyColor
                        : bodyColor?.withValues(alpha: 0.45),
                  ),
                ),
                if (peers > 0) ...[
                  const SizedBox(width: 10),
                  Text(
                    '$peers peers',
                    style: TextStyle(
                      fontSize: 11,
                      color: bodyColor?.withValues(alpha: 0.4),
                    ),
                  ),
                ],
                if (total > 0) ...[
                  const SizedBox(width: 10),
                  Text(
                    '${formatBytes(stats.downloadedBytes)} / ${formatBytes(total)}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: bodyColor?.withValues(alpha: 0.5),
                    ),
                  ),
                ],
                if (uploadedBytes > 0) ...[
                  const SizedBox(width: 10),
                  Text(
                    '↑${formatBytes(uploadedBytes)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.orange.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ],
            ),
            _buildPieceGrid(theme, stateColor),
            const SizedBox(height: 6),
            Text(
              readyToPlay
                  ? '连续缓冲 ${formatBytes(contiguous)} / ${formatBytes(required)}，已达标'
                  : '连续缓冲 ${formatBytes(contiguous)} / ${formatBytes(required)}，还差 ${formatBytes(remaining)}',
              style: TextStyle(
                fontSize: 11,
                color: bodyColor?.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPieceGrid(ThemeData theme, Color stateColor) {
    final pm = TorrentService.instance.engine?.pieceManager;
    if (pm == null) return const SizedBox.shrink();

    final firstPiece = pm.firstPiece;
    final lastPiece = pm.lastPiece;
    final totalTargetPieces = lastPiece - firstPiece + 1;
    if (totalTargetPieces <= 0) return const SizedBox.shrink();

    final states = pm.pieceStates;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 1,
        runSpacing: 1,
        children: List.generate(totalTargetPieces, (i) {
          final pieceIdx = firstPiece + i;
          final state = pieceIdx < states.length
              ? states[pieceIdx]
              : PieceState.pending;
          final color = switch (state) {
            PieceState.completed => const Color(0xFF34C759),
            PieceState.downloading => stateColor.withValues(alpha: 0.6),
            PieceState.pending => theme.dividerColor.withValues(alpha: 0.15),
          };
          return SizedBox(
            width: 5,
            height: 5,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          );
        }),
      ),
    );
  }
}
