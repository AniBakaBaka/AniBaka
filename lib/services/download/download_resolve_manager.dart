import 'dart:async';

import 'package:baka/api/bgm.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/models/download_task.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/services/download/download_manager.dart';
import 'package:baka/services/playback/playback_content.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 一次批量下载解析任务的全部数据快照。
///
/// 播放页退出后 [PlaybackContent] 会被 dispose；通过 [keepAlive] 的
/// retain/release 让解析期间实例保持存活，解析因此不依赖播放页。
class DownloadResolveJob {
  DownloadResolveJob({
    required this.indices,
    required this.saveDir,
    required this.resolver,
    this.keepAlive,
    required this.detail,
    required this.videoList,
    required this.taskIdPrefix,
  });

  final List<int> indices;
  final String saveDir;
  final Future<String?> Function(int episodeIndex) resolver;
  final PlaybackContent? keepAlive;
  final Map<String, dynamic> detail;
  final List<PlaybackEpisode> videoList;
  final String taskIdPrefix;

  String taskId(int index) => '$taskIdPrefix${index + 1}';
}

/// 悬浮条右侧的一个操作按钮。
class ResolveBannerAction {
  const ResolveBannerAction(this.label, this.onPressed);
  final String label;
  final VoidCallback onPressed;
}

/// 解析进度悬浮条的状态快照。
class ResolveBanner {
  const ResolveBanner({
    required this.text,
    this.isError = false,
    this.actions = const [],
    this.autoHideAfter,
  });

  final String text;
  final bool isError;

  /// 右侧操作按钮（取消/重试）。
  final List<ResolveBannerAction> actions;

  /// 非 null 时由悬浮条在此时长后自动隐藏（用于"完成"这类短暂提示）。
  final Duration? autoHideAfter;
}

/// 批量下载解析管理器：独立于播放页/弹窗生命周期运行。
///
/// - 播放页退出不影响解析（解析前 retain 住 PlaybackContent）。
/// - 进度通过 [banner] 通知常驻悬浮条（数字原地更新，不闪不排队）。
class DownloadResolveManager {
  DownloadResolveManager._();
  static final DownloadResolveManager instance = DownloadResolveManager._();

  /// 首次解析 + 最多 3 次重试。
  static const int _maxAttempts = 4;

  /// 单轮内并发解析的集数：逐集串行时一集一个 15 秒超时，重试会拖很久。
  static const int _resolveConcurrency = 4;

  /// 解析进度悬浮条：数字原地更新，替代 SnackBar（SnackBar 每次更新
  /// 都要整条重建，既闪烁又与操作按钮存在关闭竞态）。
  final ValueNotifier<ResolveBanner?> banner = ValueNotifier(null);
  bool _cancelled = false;

  final _queue = <DownloadResolveJob>[];
  bool _draining = false;
  String _currentTitle = '';
  DownloadResolveJob? _lastAbandoned;
  List<int> _remaining = const [];
  List<int> _failed = const [];
  int _totalOfCurrentJob = 0;
  int _resolvedCount = 0;

  // ---- 对外操作 ----

  void enqueue(DownloadResolveJob job) {
    // 必须在入队时同步 retain：此刻弹窗还开在播放页上，content 一定存活；
    // 若推迟到 job 开始执行，播放页可能已退出、content 已被销毁。
    job.keepAlive?.retain();
    _queue.add(job);
    if (!_draining) unawaited(_drain());
  }

  /// 取消解析：正在解析 → 中断并丢弃全部已解析结果；
  /// 放弃待重试态 → 关闭提示条并不再重试。
  void cancel() {
    if (_draining && !_cancelled) {
      _cancelled = true;
      _showBanner('正在取消解析…');
      return;
    }
    // 放弃待重试态（或空闲）：直接清掉提示并释放。
    if (_lastAbandoned != null) {
      _lastAbandoned?.keepAlive?.release();
      _lastAbandoned = null;
    }
    _failed = const [];
    banner.value = null;
  }

  /// 对最终放弃的集重新发起解析（重置重试计数）。
  void retry() {
    if (_failed.isEmpty) return;
    final job = _lastAbandoned;
    if (job == null) return;
    _queue.add(
      DownloadResolveJob(
        indices: List<int>.from(_failed),
        saveDir: job.saveDir,
        resolver: job.resolver,
        keepAlive: job.keepAlive,
        detail: job.detail,
        videoList: job.videoList,
        taskIdPrefix: job.taskIdPrefix,
      ),
    );
    _failed = const [];
    _lastAbandoned = null;
    if (!_draining) unawaited(_drain());
  }

  // ---- 内部执行 ----

  Future<void> _drain() async {
    _draining = true;
    while (_queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      await _runJob(job);
    }
    _draining = false;
    _remaining = const [];
  }

  Future<void> _runJob(DownloadResolveJob job) async {
    try {
      await downloads.init();
      _currentTitle = job.detail['title'] as String? ?? '';
      final bgmId = await _resolveBgmId(job);
      final total = job.indices.length;
      _totalOfCurrentJob = total;
      _resolvedCount = 0;
      _remaining = List<int>.from(job.indices);
      _showRunningBanner();

      final tasks = <DownloadTask>[];
      for (
        var attempt = 1;
        attempt <= _maxAttempts && _remaining.isNotEmpty && !_cancelled;
        attempt++
      ) {
        if (attempt > 1) {
          if (_cancelled) break;
          _showBanner(
            '正在解析《$_currentTitle》：第 ${episodeNumbers(_remaining)} 集解析失败，开始第 ${attempt - 1} 次重试（${_resolvedCount.clamp(0, total)}/$total）${_queueSuffix()}',
            actions: [
              ResolveBannerAction('取消', cancel),
            ],
          );
          await Future<void>.delayed(_retryDelay(attempt - 1));
        }
        final retry = <int>[];
        for (
          var start = 0;
          start < _remaining.length && !_cancelled;
          start += _resolveConcurrency
        ) {
          if (_cancelled) break;
          final end = start + _resolveConcurrency > _remaining.length
              ? _remaining.length
              : start + _resolveConcurrency;
          final chunk = _remaining.sublist(start, end);
          final resolved = await Future.wait(
            chunk.map((index) => _resolveOne(job, index, bgmId)),
          );
          for (var i = 0; i < chunk.length; i++) {
            final task = resolved[i];
            if (task == null) {
              retry.add(chunk[i]);
            } else {
              tasks.add(task);
            }
          }
          // 每批解析完刷新一次进度（X/N）。
          _resolvedCount = tasks.length;
          if (_remaining.length > end || retry.isNotEmpty) {
            _showRunningBanner();
          }
        }
        _remaining = retry;
      }

      if (_cancelled) {
        // 用户取消：全部丢弃。解析中的任务从未入队，不会留下任何记录。
        _cancelled = false;
        _failed = const [];
        _lastAbandoned = null;
        for (final task in tasks) {
          task.dispose();
        }
        _showBanner(
          '解析已取消',
          autoHideAfter: const Duration(seconds: 3),
        );
        job.keepAlive?.release();
        return;
      }

      // 第4条修复：已成功解析的集无论全部/部分成功都必须入队，不再因部分失败丢弃。
      // downloads.addTasks 内部按 id 去重，重复入队安全。
      final int added = tasks.isNotEmpty ? downloads.addTasks(tasks) : 0;

      if (_remaining.isEmpty) {
        // 本次全部解析成功。
        if (_lastAbandoned == null) {
          // 无前序挂起失败：正常清状态并提示成功。
          _failed = const [];
          _lastAbandoned = null;
          _showBanner(
            added > 0 ? '解析完成，$added 集已加入下载队列' : '解析完成，所选剧集已在下载队列中',
            autoHideAfter: const Duration(seconds: 3),
          );
        } else {
          // 第5条修复：前序仍有未处理失败，本次成功不清空其重试入口。
          _showBanner(
            '本次解析已全部成功（$added 集已加入下载队列）；仍有之前失败的集可重试',
            isError: true,
            actions: [
              ResolveBannerAction('重试', retry),
              ResolveBannerAction('取消', cancel),
            ],
          );
        }
        job.keepAlive?.release();
        return;
      }

      if (_lastAbandoned == null) {
        // 无前序挂起失败：记录本次失败集并提供重试入口。
        _failed = List<int>.from(_remaining);
        _lastAbandoned = job;
        _showBanner(
          '解析完成：第 ${episodeNumbers(_failed)} 集解析失败（其余已加入下载），已放弃',
          isError: true,
          actions: [
            ResolveBannerAction('重试', retry),
            ResolveBannerAction('取消', cancel),
          ],
        );
      } else {
        // 第5条修复：前序已有挂起失败，本次失败集不覆盖前序重试入口；
        // 已成功的集已在上面入队，失败的集本次不单独提供重试。
        _showBanner(
          '本次部分集解析失败（成功的已加入下载）；仍有之前失败的集可重试',
          isError: true,
          actions: [
            ResolveBannerAction('重试', retry),
            ResolveBannerAction('取消', cancel),
          ],
        );
      }
      // 保留 retain：用户随时可能点「重试」；放弃的实例在本会话内
      // 不再销毁，重启应用后自然回收。
    } catch (error) {
      debugPrint('DownloadResolveManager: job failed: $error');
      job.keepAlive?.release();
      _showBanner(
        '解析失败：$error',
        isError: true,
        autoHideAfter: const Duration(seconds: 5),
      );
    }
  }

  Future<DownloadTask?> _resolveOne(
    DownloadResolveJob job,
    int index,
    int? bgmId,
  ) async {
    try {
      final resolvedUrl = await job.resolver(index);
      if (resolvedUrl == null || resolvedUrl.isEmpty) return null;
      final episodeTitle = job.videoList[index].title;
      final kind = DownloadTask.inferKind(resolvedUrl);
      final extension = kind == DownloadTaskKind.hls ? 'm3u8' : 'mp4';
      final sourceName =
          job.detail['sourceDisplayName'] as String? ?? '';
      final title = job.detail['title'] as String? ?? '';
      final filenamePrefix = sourceName.isNotEmpty
          ? '${title}_[$sourceName]_'
          : '${title}_';
      final subtitlePrefix = sourceName.isNotEmpty ? '$sourceName · ' : '';
      final thumbnail = resolveCoverImage(job.detail);
      return DownloadTask(
        id: job.taskId(index),
        url: resolvedUrl,
        filename: '$filenamePrefix${episodeTitle}_${index + 1}.$extension',
        title: title,
        subtitle: '$subtitlePrefix$episodeTitle',
        thumbnail: thumbnail,
        bgmId: bgmId,
        episodeIndex: index + 1,
        kind: kind,
        saveDir: job.saveDir,
        sourceName: sourceName,
        lineName: job.detail['downloadLineName'] as String?,
      );
    } catch (error) {
      debugPrint('resolve download episode ${index + 1}: $error');
      return null;
    }
  }

  /// 仅在开启「下载弹幕」时才请求 Bangumi，避免无谓的网络等待拖慢解析。
  Future<int?> _resolveBgmId(DownloadResolveJob job) async {
    if (Instances.sp.getBool('download_danmaku') != true) return null;
    try {
      return (await resolveBgmFromData(job.detail)).subjectId;
    } catch (error) {
      debugPrint('resolve bgm for download: $error');
      return null;
    }
  }

  /// 队列等待提示：不同作品串行解析，展示还有几部作品在排队。
  String _queueSuffix() {
    final waiting = _queue.length;
    return waiting > 0
        ? '【剩余$waiting部作品排队中】'
        : '【剩余0部作品排队中】';
  }

  void _showRunningBanner() {
    if (_cancelled) return;
    final total = _totalOfCurrentJob;
    final done = _resolvedCount.clamp(0, total);
    final title = _currentTitle.isNotEmpty ? _currentTitle : '$total 集';
    _showBanner(
      '正在解析《$title》（$done/$total）${_queueSuffix()}',
      actions: [
        ResolveBannerAction('取消', cancel),
      ],
    );
  }

  void _showBanner(
    String text, {
    bool isError = false,
    List<ResolveBannerAction> actions = const [],
    Duration? autoHideAfter,
  }) {
    banner.value = ResolveBanner(
      text: text,
      isError: isError,
      actions: actions,
      autoHideAfter: autoHideAfter,
    );
  }

  String episodeNumbers(List<int> indexes) =>
      indexes.map((index) => '${index + 1}').join('、');

  Duration _retryDelay(int retryRound) {
    if (retryRound <= 1) return const Duration(seconds: 1);
    if (retryRound <= 2) return const Duration(seconds: 2);
    return const Duration(seconds: 3);
  }
}

/// 解析进度的常驻悬浮条：监听 [DownloadResolveManager.banner]，
/// 数字变化时只重建文本（SnackBar 则要整条拆除重建——闪烁且与
/// 按钮点击存在关闭竞态）。挂在 MaterialApp.builder 的最外层。
class DownloadResolveBanner extends StatefulWidget {
  const DownloadResolveBanner({super.key});

  @override
  State<DownloadResolveBanner> createState() => _DownloadResolveBannerState();
}

class _DownloadResolveBannerState extends State<DownloadResolveBanner> {
  static const _hideDelay = Duration(milliseconds: 220);
  ResolveBanner? _last;
  Timer? _autoHide;

  @override
  void initState() {
    super.initState();
    DownloadResolveManager.instance.banner.addListener(_onChanged);
  }

  @override
  void dispose() {
    DownloadResolveManager.instance.banner.removeListener(_onChanged);
    _autoHide?.cancel();
    super.dispose();
  }

  void _onChanged() {
    _autoHide?.cancel();
    _autoHide = null;
    final banner = DownloadResolveManager.instance.banner.value;
    if (banner != null) _last = banner;
    if (banner?.autoHideAfter != null) {
      _autoHide = Timer(banner!.autoHideAfter!, () {
        DownloadResolveManager.instance.banner.value = null;
      });
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final current = DownloadResolveManager.instance.banner.value;
    final banner = current ?? _last;
    final visible = current != null && banner != null;
    return Positioned(
      left: 24,
      right: 24,
      bottom: 24,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: _hideDelay,
          curve: Curves.easeOut,
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, 0.3),
            duration: _hideDelay,
            curve: Curves.easeOut,
            child: banner == null
                ? const SizedBox.shrink()
                : Material(
                    color: banner.isError
                        ? const Color(0xFFD32F2F)
                        : const Color(0xFF323232),
                    borderRadius: BorderRadius.circular(10),
                    elevation: 6,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              banner.text,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          for (final action in banner.actions)
                            TextButton(
                              onPressed: action.onPressed,
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                              ),
                              child: Text(action.label),
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
