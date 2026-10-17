import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/services/playback/playback_content.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/widgets/player/settings_panel.dart';

enum DlnaCastState { loading, playing, paused, stopped, error, finished }

/// 投屏会话随播放页存在：面板收起后仍轮询设备并自动续播下一集。
/// 剧集、标题与地址解析直接读取播放页的 [PlaybackContent]，不另存副本。
class DlnaCastController extends ChangeNotifier {
  DlnaCastController(this.content, {required this.onEpisodeChanged}) {
    unawaited(startSearch());
  }

  static final _transportState = RegExp(
    r'<CurrentTransportState>([^<]+)</CurrentTransportState>',
  );
  static final _relTime = RegExp(r'<RelTime>([^<]+)</RelTime>');
  static final _trackDuration = RegExp(
    r'<TrackDuration>([^<]+)</TrackDuration>',
  );

  final PlaybackContent content;
  final ValueChanged<int> onEpisodeChanged;

  /// (position, duration). Polling updates it without rebuilding the panel.
  final progress = ValueNotifier<(Duration, Duration)>((
    Duration.zero,
    Duration.zero,
  ));

  DLNAManager? _manager;
  StreamSubscription<Map<String, DLNADevice>>? _discovery;
  Timer? _searchTimeout;
  Timer? _poll;
  int _session = 0;
  bool _started = false;
  bool _seeking = false;

  List<DLNADevice> devices = const [];
  bool searching = false;
  DLNADevice? device;
  int episodeIndex = 0;
  DlnaCastState state = DlnaCastState.loading;
  bool autoNext = true;

  bool get connected => device != null;
  bool get busy => state == DlnaCastState.loading;
  bool get hasPrevious => episodeIndex > 0;
  bool get hasNext => episodeIndex + 1 < content.videoList.length;
  String get episodeTitle => episodeIndex < content.videoList.length
      ? content.videoList[episodeIndex].title
      : '第 ${episodeIndex + 1} 集';

  Future<void> startSearch() async {
    if (searching) return;
    final manager = _manager = DLNAManager();
    devices = const [];
    searching = true;
    notifyListeners();
    _searchTimeout = Timer(const Duration(seconds: 20), _stopSearch);
    try {
      final found = (await manager.start()).devices.stream;
      if (!identical(_manager, manager)) {
        // Stopped while the sockets were binding.
        manager.stop();
        return;
      }
      _discovery = found.listen((map) {
        devices = map.values.toList(growable: false);
        notifyListeners();
      });
    } catch (error) {
      debugPrint('DLNA 搜索失败: $error');
      if (identical(_manager, manager)) _stopSearch();
    }
  }

  void _stopSearch({bool notify = true}) {
    _searchTimeout?.cancel();
    _discovery?.cancel();
    _discovery = null;
    _manager?.stop();
    _manager = null;
    if (!searching) return;
    searching = false;
    if (notify) notifyListeners();
  }

  Future<void> select(DLNADevice target, String url) {
    _stopSearch(notify: false);
    device = target;
    episodeIndex = content.currPlayIndex;
    return _cast(url);
  }

  void _setState(DlnaCastState next) {
    if (state == next) return;
    state = next;
    notifyListeners();
  }

  Future<void> _cast(String url) async {
    final target = device!;
    final session = ++_session;
    _poll?.cancel();
    _started = false;
    state = DlnaCastState.loading;
    progress.value = (Duration.zero, Duration.zero);
    notifyListeners();
    try {
      await target.setUrl(url, title: '${content.title} P${episodeIndex + 1}');
      await target.play();
    } catch (error) {
      debugPrint('DLNA 投屏失败: $error');
      if (session == _session) _setState(DlnaCastState.error);
      return;
    }
    if (session != _session) return;
    _setState(DlnaCastState.playing);
    _schedulePoll(session);
  }

  Future<void> playEpisode(int index) async {
    if (device == null || index < 0 || index >= content.videoList.length) {
      return;
    }
    final session = ++_session;
    _poll?.cancel();
    _setState(DlnaCastState.loading);
    String? url;
    try {
      url = await content.resolveEpisodeUrl(index);
    } catch (error) {
      debugPrint('DLNA 解析剧集失败: $error');
    }
    if (session != _session) return;
    if (url == null || url.isEmpty) {
      _setState(DlnaCastState.error);
      return;
    }
    episodeIndex = index;
    onEpisodeChanged(index);
    await _cast(url);
  }

  /// One request pair in flight at a time; the next poll is scheduled after.
  void _schedulePoll(int session) {
    _poll = Timer(
      const Duration(seconds: 2),
      () => unawaited(_pollOnce(session)),
    );
  }

  Future<void> _pollOnce(int session) async {
    final target = device;
    if (target == null || session != _session) return;
    try {
      final (info, position) = await (
        target.getTransportInfo(),
        target.position(),
      ).wait;
      if (session != _session) return;
      if (!_seeking) {
        final (oldPosition, oldDuration) = progress.value;
        final duration = _parseTime(_trackDuration.firstMatch(position));
        progress.value = (
          _parseTime(_relTime.firstMatch(position)) ?? oldPosition,
          duration != null && duration > Duration.zero ? duration : oldDuration,
        );
      }
      switch (_transportState.firstMatch(info)?.group(1)) {
        case 'PLAYING':
          _started = true;
          _setState(DlnaCastState.playing);
        case 'PAUSED_PLAYBACK':
          _setState(DlnaCastState.paused);
        // Renderers may report STOPPED while still loading; only a stop after
        // real playback means the episode ended.
        case 'STOPPED' when _started:
          _started = false;
          if (autoNext) {
            if (hasNext) {
              unawaited(playEpisode(episodeIndex + 1));
            } else {
              _setState(DlnaCastState.finished);
            }
            return;
          }
          _setState(DlnaCastState.stopped);
        case 'STOPPED' || 'NO_MEDIA_PRESENT':
          _setState(DlnaCastState.stopped);
      }
    } catch (_) {
      // 渲染器偶尔丢弃轮询请求；保持连接，下一轮再取状态。
    }
    if (session == _session) _schedulePoll(session);
  }

  Future<void> seek(Duration position) async {
    final target = device;
    if (target == null) return;
    final session = _session;
    _seeking = true;
    progress.value = (position, progress.value.$2);
    try {
      await target.seek(_formatTime(position));
    } catch (error) {
      debugPrint('DLNA 跳转失败: $error');
    } finally {
      if (session == _session) _seeking = false;
    }
  }

  Future<void> togglePlayPause() async {
    final target = device;
    final resume = state == DlnaCastState.paused;
    if (target == null || (!resume && state != DlnaCastState.playing)) return;
    final session = _session;
    try {
      await (resume ? target.play() : target.pause());
      if (session == _session) {
        _setState(resume ? DlnaCastState.playing : DlnaCastState.paused);
      }
    } catch (error) {
      debugPrint('DLNA 播放控制失败: $error');
    }
  }

  void setAutoNext(bool value) {
    autoNext = value;
    notifyListeners();
  }

  Future<void> disconnect() async {
    final target = device;
    _session++;
    _poll?.cancel();
    _seeking = false;
    device = null;
    progress.value = (Duration.zero, Duration.zero);
    notifyListeners();
    try {
      await target?.stop();
    } catch (error) {
      debugPrint('DLNA 断开失败: $error');
    }
  }

  /// The renderer keeps playing after the page closes; only local work stops.
  @override
  void dispose() {
    _session++;
    _poll?.cancel();
    _stopSearch(notify: false);
    progress.dispose();
    super.dispose();
  }
}

/// UPnP AVTransport time: `H+:MM:SS[.F+]`, or `NOT_IMPLEMENTED`.
Duration? _parseTime(RegExpMatch? match) {
  final parts = match?.group(1)?.split(':');
  if (parts == null || parts.length != 3) return null;
  final hours = int.tryParse(parts[0]);
  final minutes = int.tryParse(parts[1]);
  final seconds = double.tryParse(parts[2]);
  if (hours == null || minutes == null || seconds == null) return null;
  return Duration(
    milliseconds: ((hours * 60 + minutes) * 60000 + seconds * 1000).round(),
  );
}

String _formatTime(Duration value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.inHours)}:${two(value.inMinutes % 60)}:'
      '${two(value.inSeconds % 60)}';
}

/// 投屏面板（Bottom Sheet）
class DlnaCastPanel extends StatelessWidget {
  const DlnaCastPanel({required this.controller, required this.url, super.key});

  final DlnaCastController controller;

  /// Cast when a device is picked; ignored while already connected.
  final String url;

  static Future<void> show(
    BuildContext context,
    DlnaCastController controller, {
    required String url,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (_) => DlnaCastPanel(controller: controller, url: url),
    );
  }

  @override
  Widget build(BuildContext context) {
    final portrait = isBottomPlayerPanel(context);
    final theme = playerPanelTheme(
      Theme.of(context),
      bottom: true,
      compact: isCompactPlayerPanel(context) && !portrait,
    );
    final media = MediaQuery.of(context);
    final height = portrait
        ? (media.size.height - media.padding.top - media.size.width * 9 / 16)
              .clamp(0.0, media.size.height * 0.74)
        : (media.size.height - media.padding.top) * 0.9;

    return Theme(
      data: theme,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: height,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                SizedBox(
                  height: 24,
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.4,
                        ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '投屏',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: '收起投屏面板',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) => controller.connected
                        ? _buildControls(theme)
                        : _buildDevices(theme),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDevices(ThemeData theme) {
    final colors = theme.colorScheme;
    final searching = controller.searching;
    final devices = controller.devices;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    searching ? '正在搜索设备' : '可用设备',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.primary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '重新搜索设备',
                  onPressed: searching ? null : controller.startSearch,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
        ),
        if (devices.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (searching)
                    const CircularProgressIndicator()
                  else
                    Icon(Icons.tv_off_rounded, size: 48, color: colors.primary),
                  const SizedBox(height: 20),
                  Text(
                    searching ? '寻找附近的投屏设备' : '未找到可用设备',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '请确保手机与电视连接同一网络',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (!searching) ...[
                    const SizedBox(height: 24),
                    FilledButton.tonalIcon(
                      onPressed: controller.startSearch,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重新搜索'),
                    ),
                  ],
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            sliver: SliverList.builder(
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final device = devices[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(24),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      minTileHeight: 76,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      leading: Icon(Icons.cast_rounded, color: colors.primary),
                      title: Text(
                        device.info.friendlyName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        controller.select(device, url);
                      },
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildControls(ThemeData theme) {
    final c = controller;
    final colors = theme.colorScheme;
    final groupShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
    );
    final busy = c.busy;
    final playing = c.state == DlnaCastState.playing;
    final canToggle = playing || c.state == DlnaCastState.paused;
    final sectionStyle = theme.textTheme.titleSmall?.copyWith(
      color: colors.primary,
    );
    final mutedSmall = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final stepStyle = IconButton.styleFrom(
      minimumSize: const Size(48, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    );

    void step(int delta) {
      HapticFeedback.lightImpact();
      c.playEpisode(c.episodeIndex + delta);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: colors.surfaceContainerHigh,
            shape: groupShape,
            child: ListTile(
              minTileHeight: 76,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: CircleAvatar(
                radius: 24,
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
                child: const Icon(Icons.cast_connected_rounded),
              ),
              title: Text(
                c.device!.info.friendlyName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                '已连接',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
            child: Text('正在播放', style: sectionStyle),
          ),
          Material(
            color: colors.surfaceContainerHigh,
            shape: groupShape,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${c.content.title} · ${c.episodeTitle}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(switch (c.state) {
                    DlnaCastState.loading => '正在加载…',
                    DlnaCastState.error => '投屏失败，请重试',
                    DlnaCastState.paused => '已暂停',
                    DlnaCastState.stopped => '已停止',
                    DlnaCastState.finished => '已播放完全部剧集',
                    DlnaCastState.playing => '当前剧集',
                  }, style: mutedSmall),
                  _CastSeekBar(c),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 12,
                    children: [
                      IconButton.filledTonal(
                        tooltip: '上一集',
                        iconSize: 28,
                        style: stepStyle,
                        onPressed: !busy && c.hasPrevious
                            ? () => step(-1)
                            : null,
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                      IconButton.filled(
                        tooltip: playing ? '暂停投屏' : '继续投屏',
                        iconSize: 40,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(72, 72),
                          backgroundColor: colors.primary,
                          foregroundColor: colors.onPrimary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                        onPressed: !busy && canToggle
                            ? () {
                                HapticFeedback.mediumImpact();
                                c.togglePlayPause();
                              }
                            : null,
                        icon: busy
                            ? const SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                ),
                              )
                            : Icon(
                                playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                      ),
                      IconButton.filledTonal(
                        tooltip: '下一集',
                        iconSize: 28,
                        style: stepStyle,
                        onPressed: !busy && c.hasNext ? () => step(1) : null,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
            child: Text('播放设置', style: sectionStyle),
          ),
          Material(
            color: colors.surfaceContainerHigh,
            shape: groupShape,
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Text('自动播放下一集', style: theme.textTheme.bodyLarge),
              subtitle: Text(
                c.hasNext
                    ? '剩余 ${c.content.videoList.length - c.episodeIndex - 1} 集'
                    : '已是最后一集',
                style: mutedSmall,
              ),
              value: c.autoNext,
              onChanged: (value) {
                HapticFeedback.selectionClick();
                c.setAutoNext(value);
              },
            ),
          ),
          const SizedBox(height: 18),
          Material(
            color: colors.surfaceContainerHigh,
            shape: groupShape,
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              minTileHeight: 56,
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: Icon(Icons.tv_off_rounded, color: colors.primary),
              title: Text(
                '断开投屏',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: colors.primary,
                ),
              ),
              onTap: c.disconnect,
            ),
          ),
        ],
      ),
    );
  }
}

class _CastSeekBar extends StatefulWidget {
  const _CastSeekBar(this.controller);

  final DlnaCastController controller;

  @override
  State<_CastSeekBar> createState() => _CastSeekBarState();
}

class _CastSeekBarState extends State<_CastSeekBar> {
  /// Drag fraction; shown instead of polled progress until released.
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return ValueListenableBuilder<(Duration, Duration)>(
      valueListenable: widget.controller.progress,
      builder: (context, progress, _) {
        final (position, duration) = progress;
        final total = duration.inMilliseconds;
        final drag = _drag;
        final shown = drag == null
            ? position
            : Duration(milliseconds: (drag * total).round());
        final seekable = total > 0 && !widget.controller.busy;
        return Column(
          children: [
            Slider(
              value:
                  drag ??
                  (total > 0
                      ? (position.inMilliseconds / total).clamp(0.0, 1.0)
                      : 0.0),
              semanticFormatterCallback: (_) =>
                  '${shown.toTimeString()} / ${duration.toTimeString()}',
              onChanged: seekable ? (v) => setState(() => _drag = v) : null,
              onChangeEnd: seekable
                  ? (v) {
                      setState(() => _drag = null);
                      widget.controller.seek(
                        Duration(milliseconds: (v * total).round()),
                      );
                    }
                  : null,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(shown.toTimeString(), style: timeStyle),
                Text(duration.toTimeString(), style: timeStyle),
              ],
            ),
          ],
        );
      },
    );
  }
}
