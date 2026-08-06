import 'dart:async';

import 'package:baka/utils/date_util.dart';
import 'package:dlna_dart/dlna.dart';
import 'package:flutter/material.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// DLNA 投屏下一集 URL 解析回调
typedef DlnaEpisodeUrlResolver = Future<String?> Function(int episodeIndex);

/// 投屏切集回调（通知 PlayerPage 同步更新 UI 状态）
typedef DlnaEpisodeChangedCallback = void Function(int episodeIndex);

/// 投屏控制器（持久化，不随 UI 关闭而销毁）
class DlnaController extends GetxController {
  DlnaController({
    required this.initialDatasource,
    required this.animeTitle,
    required this.videoList,
    required this.initialEpisodeIndex,
  });

  String initialDatasource;
  String animeTitle;
  List<PlaybackEpisode> videoList;
  int initialEpisodeIndex;
  DlnaEpisodeUrlResolver? urlResolver;
  DlnaEpisodeChangedCallback? onEpisodeChanged;

  final deviceList = <String, DLNADevice>{}.obs;
  DLNADevice? selectedDevice;

  final isSearching = true.obs;
  final isConnected = false.obs;
  final autoNextEnabled = true.obs;
  final currentEpisodeIndex = 0.obs;
  final transportState = 'UNKNOWN'.obs;
  final isLoadingNext = false.obs;

  final currentPosition = Duration.zero.obs;
  final totalDuration = Duration.zero.obs;
  final isSeeking = false.obs;

  final DLNAManager searcher = DLNAManager();
  Timer? _stopSearchTimer;
  Timer? _pollTimer;
  StreamSubscription? _deviceSub;
  bool _hasStartedPlaying = false;
  bool _isPolling = false;

  static final _stateRegex = RegExp(
    r'<CurrentTransportState>([^<]+)</CurrentTransportState>',
  );
  static final _relTimeRegex = RegExp(r'<RelTime>([^<]+)</RelTime>');
  static final _trackDurRegex = RegExp(
    r'<TrackDuration>([^<]+)</TrackDuration>',
  );

  bool get hasNextEpisode => currentEpisodeIndex.value + 1 < videoList.length;
  bool get hasPrevEpisode => currentEpisodeIndex.value > 0;

  @override
  void onInit() {
    super.onInit();
    currentEpisodeIndex.value = initialEpisodeIndex;
    searcher.stop();
    startSearch();
  }

  @override
  void onClose() {
    _deviceSub?.cancel();
    _stopSearchTimer?.cancel();
    _pollTimer?.cancel();
    searcher.stop();
    super.onClose();
  }

  void startSearch() async {
    _deviceSub?.cancel();
    _stopSearchTimer?.cancel();

    isSearching.value = true;
    isConnected.value = false;
    deviceList.clear();

    _stopSearchTimer = Timer(const Duration(seconds: 20), () {
      isSearching.value = false;
      searcher.stop();
    });

    final m = await searcher.start();
    _deviceSub = m.devices.stream.listen((devices) {
      deviceList.assignAll(devices);
    });
  }

  Future<void> selectDevice(DLNADevice dev) async {
    if (selectedDevice != null) {
      _pollTimer?.cancel();
      selectedDevice!.stop();
    }

    selectedDevice = dev;
    isConnected.value = true;
    _hasStartedPlaying = false;

    await _castCurrentEpisode(initialDatasource);
  }

  Future<void> _castCurrentEpisode(String url) async {
    if (selectedDevice == null || url.isEmpty) return;
    final title = '$animeTitle P${currentEpisodeIndex.value + 1}';
    await selectedDevice!.setUrl(url, title: title);
    await selectedDevice!.play();
    _hasStartedPlaying = true;
    transportState.value = 'PLAYING';
    currentPosition.value = Duration.zero;
    totalDuration.value = Duration.zero;
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _isPolling = false;
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_isPolling) return;
      _isPolling = true;
      await _pollStatus();
      _isPolling = false;
    });
  }

  Future<void> _pollStatus() async {
    if (selectedDevice == null) return;
    try {
      final futures = await Future.wait([
        selectedDevice!.getTransportInfo(),
        selectedDevice!.position(),
      ]);

      final stateMatch = _stateRegex.firstMatch(futures[0]);
      final state = stateMatch?.group(1) ?? 'UNKNOWN';
      transportState.value = state;

      if (!isSeeking.value) {
        final posMatch = _relTimeRegex.firstMatch(futures[1]);
        if (posMatch != null) {
          final pos = _parseDuration(posMatch.group(1)!);
          if (pos != null) currentPosition.value = pos;
        }

        final durMatch = _trackDurRegex.firstMatch(futures[1]);
        if (durMatch != null) {
          final dur = _parseDuration(durMatch.group(1)!);
          if (dur != null && dur > Duration.zero) totalDuration.value = dur;
        }
      }

      if (_hasStartedPlaying && state == 'STOPPED') {
        _hasStartedPlaying = false;
        if (autoNextEnabled.value) {
          _playNextEpisode();
        }
      }
    } catch (_) {
      // 忽略轮询错误以保持连接
    }
  }

  Duration? _parseDuration(String str) {
    final parts = str.split(':');
    if (parts.length == 3) {
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      final s = int.tryParse(parts[2].split('.').first) ?? 0;
      return Duration(hours: h, minutes: m, seconds: s);
    }
    return null;
  }

  Future<void> seekTo(Duration position) async {
    if (selectedDevice == null) return;
    isSeeking.value = true;
    final h = position.inHours.toString().padLeft(2, '0');
    final m = (position.inMinutes % 60).toString().padLeft(2, '0');
    final s = (position.inSeconds % 60).toString().padLeft(2, '0');
    try {
      await selectedDevice!.seek('$h:$m:$s');
      currentPosition.value = position;
    } finally {
      isSeeking.value = false;
    }
  }

  Future<void> _playNextEpisode() async {
    final nextIndex = currentEpisodeIndex.value + 1;
    if (nextIndex >= videoList.length) {
      transportState.value = 'COMPLETED_ALL';
      _pollTimer?.cancel();
      return;
    }
    await playEpisodeAt(nextIndex);
  }

  Future<void> playEpisodeAt(int index) async {
    if (index < 0 || index >= videoList.length || selectedDevice == null) {
      return;
    }

    _pollTimer?.cancel();
    _hasStartedPlaying = false;
    isLoadingNext.value = true;

    try {
      String? url;
      if (urlResolver != null) {
        url = await urlResolver!(index);
      }
      if (url == null || url.isEmpty) {
        transportState.value = 'ERROR';
        return;
      }

      currentEpisodeIndex.value = index;
      onEpisodeChanged?.call(index);
      await _castCurrentEpisode(url);
    } catch (_) {
      transportState.value = 'ERROR';
    } finally {
      isLoadingNext.value = false;
    }
  }

  Future<void> togglePlayPause() async {
    if (selectedDevice == null) return;
    if (transportState.value == 'PLAYING') {
      await selectedDevice!.pause();
      transportState.value = 'PAUSED_PLAYBACK';
    } else if (transportState.value == 'PAUSED_PLAYBACK') {
      await selectedDevice!.play();
      transportState.value = 'PLAYING';
    }
  }

  Future<void> stopCast() async {
    _pollTimer?.cancel();
    _hasStartedPlaying = false;
    await selectedDevice?.stop();
    isConnected.value = false;
    transportState.value = 'STOPPED';
    currentPosition.value = Duration.zero;
    totalDuration.value = Duration.zero;
  }
}

/// 投屏面板（Bottom Sheet）
class DlnaCastPanel extends StatelessWidget {
  final String datasource;
  final String animeTitle;
  final List<PlaybackEpisode> videoList;
  final int currentEpisodeIndex;
  final DlnaEpisodeUrlResolver? urlResolver;
  final DlnaEpisodeChangedCallback? onEpisodeChanged;

  const DlnaCastPanel({
    required this.datasource,
    required this.animeTitle,
    required this.videoList,
    required this.currentEpisodeIndex,
    this.urlResolver,
    this.onEpisodeChanged,
    super.key,
  });

  static const _tag = 'dlna_cast';

  @override
  Widget build(BuildContext context) {
    final c = Get.isRegistered<DlnaController>(tag: _tag)
        ? Get.find<DlnaController>(tag: _tag)
        : Get.put(
            DlnaController(
              initialDatasource: datasource,
              animeTitle: animeTitle,
              videoList: videoList,
              initialEpisodeIndex: currentEpisodeIndex,
            ),
            tag: _tag,
            permanent: true,
          );

    // 每次构建更新最新的瞬态回调和列表，避免旧闭包捕获
    c.urlResolver = urlResolver;
    c.onEpisodeChanged = onEpisodeChanged;
    c.videoList = videoList;
    c.animeTitle = animeTitle;

    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.4,
                ),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Obx(() {
                final connected = c.isConnected.value;
                return Row(
                  children: [
                    Text(
                      connected ? '投屏控制' : '选择设备',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    if (connected)
                      TextButton(
                        onPressed: c.stopCast,
                        child: Text(
                          '断开',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      )
                    else
                      IconButton(
                        onPressed: c.startSearch,
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                      ),
                  ],
                );
              }),
            ),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.6,
                ),
                child: Obx(
                  () => c.isConnected.value
                      ? _buildCastControls(context, c, theme)
                      : _buildDeviceList(context, c, theme),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceList(
    BuildContext context,
    DlnaController c,
    ThemeData theme,
  ) {
    if (c.deviceList.isEmpty) {
      final secondary = TextStyle(
        fontSize: 13,
        color: theme.colorScheme.onSurfaceVariant,
      );
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: c.isSearching.value
                ? [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text('正在搜索设备...', style: secondary),
                  ]
                : [
                    Icon(
                      Icons.tv_off_rounded,
                      size: 48,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 16),
                    Text('未找到可用设备', style: secondary),
                  ],
          ),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      itemCount: c.deviceList.length,
      itemBuilder: (context, index) {
        final dev = c.deviceList.values.elementAt(index);
        return ListTile(
          leading: Icon(Icons.tv_rounded, color: theme.colorScheme.primary),
          title: Text(
            dev.info.friendlyName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Icon(
            Icons.chevron_right_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          onTap: () {
            HapticFeedback.mediumImpact();
            c.selectDevice(dev);
          },
        );
      },
    );
  }

  Widget _buildCastControls(
    BuildContext context,
    DlnaController c,
    ThemeData theme,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.tv_rounded, color: theme.colorScheme.primary),
            title: Text(
              c.selectedDevice?.info.friendlyName ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Obx(
              () => Text(
                '${c.animeTitle} · P${c.currentEpisodeIndex.value + 1}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            trailing: Obx(
              () => c.isLoadingNext.value
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          const SizedBox(height: 8),
          _buildSeekBar(c, theme),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Obx(
                () => IconButton(
                  iconSize: 32,
                  onPressed: c.hasPrevEpisode
                      ? () {
                          HapticFeedback.lightImpact();
                          c.playEpisodeAt(c.currentEpisodeIndex.value - 1);
                        }
                      : null,
                  icon: const Icon(Icons.skip_previous_rounded),
                ),
              ),
              const SizedBox(width: 24),
              Obx(
                () => IconButton.filled(
                  iconSize: 32,
                  padding: const EdgeInsets.all(12),
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    c.togglePlayPause();
                  },
                  icon: Icon(
                    c.transportState.value == 'PLAYING'
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              Obx(
                () => IconButton(
                  iconSize: 32,
                  onPressed: c.hasNextEpisode
                      ? () {
                          HapticFeedback.lightImpact();
                          c.playEpisodeAt(c.currentEpisodeIndex.value + 1);
                        }
                      : null,
                  icon: const Icon(Icons.skip_next_rounded),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Obx(
            () => SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('自动播放下一集', style: TextStyle(fontSize: 14)),
              subtitle: c.hasNextEpisode
                  ? Text(
                      '剩余 ${c.videoList.length - c.currentEpisodeIndex.value - 1} 集',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  : null,
              value: c.autoNextEnabled.value,
              onChanged: (v) {
                HapticFeedback.selectionClick();
                c.autoNextEnabled.value = v;
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeekBar(DlnaController c, ThemeData theme) {
    return Obx(() {
      final pos = c.currentPosition.value;
      final dur = c.totalDuration.value;
      final progress = dur.inMilliseconds > 0
          ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
          : 0.0;
      final timeStyle = TextStyle(
        fontSize: 12,
        color: theme.colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

      return Column(
        children: [
          Slider(
            value: progress,
            onChangeStart: (_) => c.isSeeking.value = true,
            onChanged: (v) {
              c.currentPosition.value = Duration(
                milliseconds: (v * dur.inMilliseconds).round(),
              );
            },
            onChangeEnd: (v) {
              c.seekTo(
                Duration(milliseconds: (v * dur.inMilliseconds).round()),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(pos.toTimeString(), style: timeStyle),
                Text(dur.toTimeString(), style: timeStyle),
              ],
            ),
          ),
        ],
      );
    });
  }
}
