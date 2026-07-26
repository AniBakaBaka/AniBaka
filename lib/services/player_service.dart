import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/api/collection.dart';
import 'package:baka/api/post.dart';
import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/services/play_history_sync_service.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/services/danmaku_service.dart';
import 'package:baka/services/torrent/torrent_service.dart';
import 'package:baka/widgets/danmaku/controller.dart';

/// Episode serialization helpers and local progress I/O.
class VideoUtils {
  static Box<Map> get _progressBox => AppStorage.videoProgressBox;

  /// Count playable lines (`$`-separated) in a serialized episode item.
  static int getPathCount(String? videoItem) {
    if (videoItem == null || videoItem.isEmpty) return 0;
    var count = 0;
    for (var i = 0; i < videoItem.length; i++) {
      if (videoItem.codeUnitAt(i) == 0x24 /* $ */ ) count++;
    }
    return count;
  }

  /// Read a line value (1-based) without allocating a full split list.
  static String? getVideoUrl(String? videoItem, int lineIndex) {
    if (videoItem == null || videoItem.isEmpty || lineIndex <= 0) return null;
    var start = -1;
    for (var i = 0; i < lineIndex; i++) {
      start = videoItem.indexOf(PlaybackEpisode.separator, start + 1);
      if (start < 0) return null;
    }
    final end = videoItem.indexOf(PlaybackEpisode.separator, start + 1);
    return videoItem.substring(start + 1, end < 0 ? videoItem.length : end);
  }

  /// Prefer `videoList`; fall back to newline-split `videos`.
  static List<String> extractVideoList(Map data) {
    final rawList = data['videoList'];
    if (rawList is List) {
      final out = <String>[];
      for (final item in rawList) {
        if (item is String && item.trim().isNotEmpty) out.add(item);
      }
      if (out.isNotEmpty) return out;
    }
    final raw = data['videos'];
    if (raw is! String || raw.isEmpty) return const [];

    // Scan in place instead of `split` + `trim`, which creates two temporary
    // strings for every serialized episode (including blank lines).
    final lines = <String>[];
    var start = 0;
    for (var end = 0; end <= raw.length; end++) {
      if (end != raw.length && raw.codeUnitAt(end) != 0x0A) continue;
      var hasContent = false;
      for (var i = start; i < end; i++) {
        if (raw.codeUnitAt(i) > 0x20) {
          hasContent = true;
          break;
        }
      }
      if (hasContent) lines.add(raw.substring(start, end));
      start = end + 1;
    }
    return lines;
  }

  static bool isEpisodeWatched(
    String videoId,
    int episodeIndex,
    Duration? totalDuration,
  ) {
    final position = getVideoProgress('${videoId}_${episodeIndex}_1');
    if (position == Duration.zero) return false;
    final total = totalDuration?.inSeconds ?? 0;
    if (total <= 0) return position.inSeconds > 30;
    return position.inSeconds / total >= 0.9;
  }

  static Future<void> saveVideoProgress(String videoKey, Duration position) =>
      _progressBox.put(videoKey, {
        'positionMs': position.inMilliseconds,
        'updateTime': DateTime.now().millisecondsSinceEpoch,
      });

  static Duration getVideoProgress(String videoKey) {
    final data = _progressBox.get(videoKey);
    if (data == null) return Duration.zero;
    return Duration(milliseconds: (data['positionMs'] as int?) ?? 0);
  }
}

/// 播放器业务逻辑服务
///
/// 负责视频数据管理、适配器源管理、集数切换、进度管理、弹幕数据获取、BGM信息等。
/// UI 层（PlayerPage）持有本实例，将控制器生命周期与界面构建留在 Widget 层。
class PlayerService {
  static const String _prefetchedPlaybackKey = '_prefetchedPlayback';
  static const Duration _prefetchedPlaybackTtl = Duration(minutes: 10);

  static List<String>? _parseSourceNames(Object? raw) {
    if (raw is! List) return null;
    final names = <String>[];
    for (final value in raw) {
      final name = value?.toString() ?? '';
      if (name.isNotEmpty) names.add(name);
    }
    return names.isEmpty ? null : List.unmodifiable(names);
  }

  /// Carries a direct URL resolved during matching into the player so opening
  /// the selected source does not resolve the same episode twice.
  static void storePrefetchedPlaybackMedia(
    Map<String, dynamic> data, {
    required int episodeIndex,
    required int lineIndex,
    required String episodeId,
    required String url,
    required Map<String, String> httpHeaders,
  }) {
    data[_prefetchedPlaybackKey] = <String, dynamic>{
      'episodeIndex': episodeIndex,
      'lineIndex': lineIndex,
      'episodeId': episodeId,
      'url': url,
      'httpHeaders': httpHeaders,
      'resolvedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  PlayerService({required this.data, this.posIndex}) {
    final source = data['source']?.toString();
    isLocalSource = source == '_local';
    isAdapter = !isLocalSource && AdapterRegistry.isAdapterSource(source);

    sourceNames = _parseSourceNames(data['sourceNames']);
    if (!isLocalSource) {
      bgmInfo = BgmUtils.readFromData(data);
      bgmDetailData = BgmUtils.asMap(data['bgmDetailData']);
      BgmUtils.normalizeCoverImage(data, bgmInfo: bgmInfo);
    }
  }

  final Map data;
  final int? posIndex;

  List<PlaybackEpisode> videoList = const [];
  int currPlayIndex = 0;
  int currUrl = 1;
  List<String>? sourceNames;
  late final bool isLocalSource;
  late final bool isAdapter;

  String? get localFilePath => data['localFilePath'] as String?;
  String? get danmakuPath => data['danmakuPath'] as String?;
  Map<String, String>? get localHttpHeaders => data['httpHeaders'] is Map
      ? Map<String, String>.from(data['httpHeaders'] as Map)
      : null;

  BgmInfo bgmInfo = const BgmInfo();
  Map<String, dynamic>? bgmDetailData;
  Future<BgmInfo>? _bgmInfoFuture;
  Future<Map<String, dynamic>?>? _bgmDetailFuture;
  AnimeCollection? collection;
  Future<AnimeCollection?>? _collectionFuture;

  AdapterBase? _adapter;
  String? _adapterSource;
  AdapterBase? _playbackKeepAliveAdapter;
  int _playbackKeepAliveGeneration = 0;
  PlaybackEpisode? get currentVideoItem =>
      currPlayIndex >= 0 && currPlayIndex < videoList.length
      ? videoList[currPlayIndex]
      : null;

  String get currentEpisodeTitle {
    if (isLocalSource) {
      final localEpisodeTitle = data['episodeTitle']?.toString().trim();
      if (localEpisodeTitle != null && localEpisodeTitle.isNotEmpty) {
        return localEpisodeTitle;
      }

      final path = localFilePath;
      if (path != null && path.isNotEmpty) {
        final slash = path.lastIndexOf('/');
        final backslash = path.lastIndexOf('\\');
        final separator = slash > backslash ? slash : backslash;
        return separator < 0 ? path : path.substring(separator + 1);
      }
    }

    return currentVideoItem?.title ?? '';
  }

  /// 从 BGM 详情数据获取当前剧集名
  String? get bgmEpisodeTitle {
    final episodes = bgmDetailData?['episodes'];
    if (episodes is! List || episodes.isEmpty) return null;
    if (currPlayIndex < 0 || currPlayIndex >= episodes.length) return null;
    final ep = episodes[currPlayIndex];
    if (ep is! Map) return null;
    return (ep['name_cn']?.toString().isNotEmpty == true
            ? ep['name_cn']
            : ep['name'])
        ?.toString();
  }

  String get title => data['title']?.toString() ?? '';

  String? get coverImageUrl =>
      BgmUtils.resolveCoverImage(data, bgmInfo: bgmInfo);

  PlaybackMediaInfo get initialMediaInfo =>
      PlaybackMediaInfo(title: title, imageUrl: coverImageUrl ?? '');

  PlaybackMediaInfo get currentMediaInfo {
    final episodeTitle = bgmEpisodeTitle;
    return PlaybackMediaInfo(
      title: title,
      episode: episodeTitle?.isNotEmpty == true
          ? episodeTitle!
          : currentEpisodeTitle,
      imageUrl: coverImageUrl ?? '',
      episodeIndex: currPlayIndex,
      totalEpisodes: videoList.length,
    );
  }

  String get videoKey => isLocalSource
      ? localFilePath ?? ''
      : "${data['id']}_${currPlayIndex}_$currUrl";

  ({int episodeIndex, int lineIndex}) normalizeSelection(
    int episodeIndex, [
    int? lineIndex,
  ]) {
    if (videoList.isEmpty) {
      return (episodeIndex: 0, lineIndex: 1);
    }

    final normalizedEpisodeIndex = episodeIndex.clamp(0, videoList.length - 1);

    final preferred = lineIndex ?? currUrl;
    final lineCount = videoList[normalizedEpisodeIndex].lineCount;
    return (
      episodeIndex: normalizedEpisodeIndex,
      lineIndex: (lineCount <= 0 || preferred < 1 || preferred > lineCount)
          ? 1
          : preferred,
    );
  }

  void _applySelection(({int episodeIndex, int lineIndex}) selection) {
    currPlayIndex = selection.episodeIndex;
    currUrl = selection.lineIndex;
    data['currPlayIndex'] = currPlayIndex;
    data['currUrl'] = currUrl;
  }

  void syncVideoData(
    List<PlaybackEpisode> nextVideoList, {
    List<String>? sourceNames,
    int? preferredEpisodeIndex,
    int? preferredLineIndex,
  }) {
    videoList = nextVideoList;
    final serialized = nextVideoList
        .map((episode) => episode.serialize())
        .toList(growable: false);
    data['videos'] = serialized.join('\n');
    data['videoList'] = serialized;
    if (sourceNames != null) {
      this.sourceNames = List.unmodifiable(sourceNames);
      data['sourceNames'] = this.sourceNames;
    }

    _applySelection(
      normalizeSelection(
        preferredEpisodeIndex ?? currPlayIndex,
        preferredLineIndex ?? currUrl,
      ),
    );
  }

  /// 准备切换集数的数据，返回 true 表示确实需要切换。
  bool prepareSwitchEpisode(int episodeIndex, {int? lineIndex}) {
    final target = normalizeSelection(episodeIndex, lineIndex ?? currUrl);
    if (target.episodeIndex == currPlayIndex && target.lineIndex == currUrl) {
      return false;
    }
    _applySelection(target);
    return true;
  }

  /// 加载视频详情数据（不涉及播放器控制器初始化）。
  Future<void> loadDetail() async {
    if (isLocalSource) {
      if (localFilePath != null) {
        videoList = [
          PlaybackEpisode(title: currentEpisodeTitle, lines: [localFilePath!]),
        ];
        currPlayIndex = 0;
      }
      return;
    }

    final explicitEpisodeIndex = posIndex ?? data['currPlayIndex'];
    final explicitLineIndex = data['currUrl'];

    if (!isAdapter) {
      final postId = int.tryParse(data['id']?.toString() ?? '');
      if (postId != null && postId > 0) {
        try {
          final response = await getPostDetail(postId);
          if (response != null && response.data != null) {
            final resData = response.data is String
                ? jsonDecode(response.data)
                : response.data;
            final postDetail = resData['data'];
            if (postDetail is Map) {
              data.addAll(Map<String, dynamic>.from(postDetail));
            }
          }
        } catch (e) {
          debugPrint('[PlayerService] Failed to load post detail: $e');
        }
      }
    }

    final remembered = PlayHistorySyncService.getResumeSelection(data);
    final initialEpisodeIndex =
        int.tryParse(
          (explicitEpisodeIndex ?? remembered?.episodeIndex ?? currPlayIndex)
              .toString(),
        ) ??
        0;
    final initialLineIndex =
        int.tryParse(
          (explicitLineIndex ?? remembered?.lineIndex ?? currUrl).toString(),
        ) ??
        1;

    syncVideoData(
      PlaybackEpisodeCatalog.parse(
        VideoUtils.extractVideoList(data),
        mergeDuplicateTitles: true,
      ),
      sourceNames: _parseSourceNames(data['sourceNames']),
      preferredEpisodeIndex: initialEpisodeIndex,
      preferredLineIndex: initialLineIndex,
    );
  }

  AdapterBase? _getAdapter(String? source) {
    if (source == null || source.isEmpty) return null;
    if (_adapterSource == source) return _adapter;

    CustomSourceConfig? typedConfig;
    if (AdapterRegistry.isCustomSource(source)) {
      final sourceId = source.substring(
        AdapterRegistry.customSourcePrefix.length,
      );
      typedConfig = SourceAdapterService.instance.customSourceById(sourceId);
      final embeddedConfig = data['customConfig'] ?? data['sourceConfig'];
      if (typedConfig == null && embeddedConfig is CustomSourceConfig) {
        typedConfig = embeddedConfig;
      }
    }

    _adapter = AdapterRegistry.createAdapterForSource(
      source,
      customSourceConfig: typedConfig,
    );
    _adapterSource = source;
    return _adapter;
  }

  /// 准备适配器源播放所需数据，返回 adapter 实例。
  Future<AdapterBase> prepareAdapterSource() async {
    final source = data['source']?.toString();
    final adapter = _getAdapter(source);
    if (adapter == null) throw Exception('不支持的源类型: $source');

    data['sourceUrl'] ??= adapter.baseUrl;
    data['sourceDisplayName'] ??= adapter.name;

    if (videoList.isEmpty || sourceNames == null) {
      final seriesUrl = data['seriesUrl'] ?? data['id'].toString();
      final sources = await adapter.getSourcesWithContext(
        seriesUrl.toString(),
        Map<String, dynamic>.from(data),
      );
      if (sources.isEmpty) throw Exception('无法获取剧集信息');
      final episodes = PlaybackEpisodeCatalog.parse(
        buildAdapterVideoList(sources),
      );
      if (episodes.isEmpty) throw Exception('无法获取剧集信息');
      syncVideoData(
        episodes,
        sourceNames: [
          for (var i = 0; i < sources.length; i++)
            sources[i].sourceName ?? '线路${i + 1}',
        ],
      );
    }

    return adapter;
  }

  String get currentEpisodeId => currentVideoItem?.lineAt(currUrl) ?? '';

  /// Resolve adapter media and transparently convert BT results to the local
  /// loopback stream served by [TorrentService].
  ///
  /// The player page can use this for every pipeline source; regular HTTP media
  /// keeps the adapter-provided headers while BT media deliberately clears
  /// remote headers before opening `127.0.0.1/stream.video`.
  Future<({String url, Map<String, String> httpHeaders})>
  resolveAdapterPlaybackMedia(
    AdapterBase adapter,
    String episodeId, {
    Duration torrentBufferTimeout = TorrentService.defaultBufferTimeout,
  }) async {
    var media =
        _readPrefetchedPlaybackMedia(episodeId) ??
        await adapter.resolvePlaybackMedia(episodeId);
    if (media.url.isEmpty && adapter.validateAutoMatchedUrls) {
      final episode = currentVideoItem;
      if (episode != null) {
        for (var line = 1; line <= episode.lines.length; line++) {
          if (line == currUrl) continue;
          final alternateId = episode.lineAt(line);
          if (alternateId == null || alternateId.isEmpty) continue;
          final alternate = await adapter.resolvePlaybackMedia(alternateId);
          if (alternate.url.isEmpty) continue;
          currUrl = line;
          data['currUrl'] = line;
          media = alternate;
          break;
        }
      }
    }
    if (media.url.isEmpty || !TorrentService.isBtLink(media.url)) return media;

    final streamUrl = await TorrentService.instance.resolvePlaybackUrl(
      media.url,
      bufferTimeout: torrentBufferTimeout,
    );
    return (url: streamUrl, httpHeaders: const <String, String>{});
  }

  /// Activates playback-scoped authorization refresh for the selected media.
  /// The returned generation prevents a stale playback request from stopping a
  /// newer keep-alive session during rapid episode switches.
  Future<int> startAdapterPlaybackKeepAlive(
    AdapterBase adapter,
    String mediaUrl,
  ) async {
    final generation = ++_playbackKeepAliveGeneration;
    _playbackKeepAliveAdapter?.stopPlaybackKeepAlive();
    _playbackKeepAliveAdapter = adapter;
    await adapter.startPlaybackKeepAlive(mediaUrl);
    return generation;
  }

  void stopAdapterPlaybackKeepAlive([int? generation]) {
    if (generation != null && generation != _playbackKeepAliveGeneration) {
      return;
    }
    _playbackKeepAliveGeneration++;
    _playbackKeepAliveAdapter?.stopPlaybackKeepAlive();
    _playbackKeepAliveAdapter = null;
  }

  ({String url, Map<String, String> httpHeaders})? _readPrefetchedPlaybackMedia(
    String episodeId,
  ) {
    final raw = data[_prefetchedPlaybackKey];
    if (raw is! Map ||
        raw['episodeId']?.toString() != episodeId ||
        raw['episodeIndex'] != currPlayIndex ||
        raw['lineIndex'] != currUrl) {
      return null;
    }

    final resolvedAt = int.tryParse(raw['resolvedAt']?.toString() ?? '') ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - resolvedAt;
    if (age < 0 || age > _prefetchedPlaybackTtl.inMilliseconds) return null;

    final url = raw['url']?.toString() ?? '';
    if (url.isEmpty) return null;

    final headers = raw['httpHeaders'];
    if (headers is Map<String, String>) {
      return (url: url, httpHeaders: headers);
    }
    if (headers is Map) {
      return (
        url: url,
        httpHeaders: {
          for (final e in headers.entries) e.key.toString(): e.value.toString(),
        },
      );
    }
    return (url: url, httpHeaders: const <String, String>{});
  }

  Future<String?> _resolvePlayUrl(String episodeId) async {
    final response = await getPlayUrl(
      episodeId,
    ).timeout(const Duration(seconds: 15));
    final rawData = response?.data;
    if (rawData == null) return null;
    final jsonData = rawData is String ? jsonDecode(rawData) : rawData;
    return jsonData?['data']?['url'];
  }

  Future<String?> getVideoUrl() async {
    try {
      final videoUrl = currentVideoItem?.lineAt(currUrl);
      if (videoUrl == null) return null;
      return await _resolvePlayUrl(videoUrl);
    } catch (e) {
      debugPrint('获取视频URL失败: $e');
      return null;
    }
  }

  Future<String?> resolveEpisodeUrl(int episodeIndex) async {
    try {
      final item = videoList[episodeIndex];
      final episodeId = item.lineAt(currUrl);
      if (episodeId == null) return null;

      if (isAdapter) {
        final adapter = _getAdapter(data['source']?.toString());
        if (adapter == null) return null;
        final resolvedUrl =
            _readPrefetchedPlaybackMedia(episodeId)?.url ??
            await adapter.resolveDownloadUrl(episodeId);
        return resolvedUrl.isEmpty ? null : resolvedUrl;
      }

      return await _resolvePlayUrl(episodeId);
    } catch (e) {
      debugPrint('解析第 ${episodeIndex + 1} 集下载地址失败: $e');
      return null;
    }
  }

  Future<BgmInfo> ensureBgmInfo() {
    if (isLocalSource || bgmInfo.subjectId != null) {
      return Future.value(bgmInfo);
    }
    return _bgmInfoFuture ??= _loadBgmInfo();
  }

  Future<BgmInfo> _loadBgmInfo() async {
    try {
      bgmInfo = await BgmService.resolveFromData(data);
      BgmUtils.normalizeCoverImage(data, bgmInfo: bgmInfo);
      return bgmInfo;
    } catch (_) {
      _bgmInfoFuture = null;
      return bgmInfo;
    }
  }

  Future<Map<String, dynamic>?> ensureBgmDetail() {
    if (isLocalSource) return Future.value(null);
    if (bgmDetailData != null) return Future.value(bgmDetailData);
    return _bgmDetailFuture ??= _loadBgmDetail();
  }

  Future<Map<String, dynamic>?> _loadBgmDetail() async {
    try {
      final subjectId = (await ensureBgmInfo()).subjectId;
      if (subjectId == null) return null;

      final subject = await BgmService.resolveSubject(
        bgmId: subjectId.toString(),
        title: title,
        withDetail: true,
      );
      if (subject == null) return null;

      final detail = getCachedBgmAnimeFullDetail(subjectId);
      if (detail == null) return null;

      bgmDetailData = detail;
      data['bgmDetailData'] = detail;
      final airDate = BgmUtils.formatPlainDate(detail['date']);
      if (airDate != null) data['airDate'] = airDate;
      BgmUtils.normalizeCoverImage(data, bgmInfo: bgmInfo);
      return detail;
    } catch (e) {
      debugPrint('获取 BGM 放映信息失败: $e');
      _bgmDetailFuture = null;
      return null;
    }
  }

  /// 获取弹幕数据列表（不涉及控制器绑定）。
  Future<List<DanmakuItem>> fetchDanmakuData(int episodeIndex) async {
    final title = data['title']?.toString() ?? '';
    final info = await ensureBgmInfo();
    final bgmId = info.subjectId;
    if (bgmId == null) return const [];

    return DanmakuService.getDanmakuItems(
      bgmId: bgmId.toString(),
      episodeIndex: episodeIndex + 1,
      originalTitle: title,
    );
  }

  Future<void> saveProgress(
    Duration position,
    bool rememberLastPosition,
  ) async {
    if (!rememberLastPosition) return;
    await VideoUtils.saveVideoProgress(videoKey, position);
  }

  Duration getSavedProgress() => VideoUtils.getVideoProgress(videoKey);

  Future<void> rememberCurrentEpisode() async {
    if (isLocalSource || videoList.isEmpty) return;
    final bgmId = bgmInfo.subjectId;
    if (bgmId != null) data['bgmId'] ??= bgmId;
    await PlayHistorySyncService.rememberEpisode(
      videoData: data,
      episodeIndex: currPlayIndex,
      urlIndex: currUrl,
    );
  }

  /// 读取本地弹幕文件（仅本地源使用）。
  Future<String?> readLocalDanmakuFile(String videoPath) async {
    final explicitPath = danmakuPath;
    if (explicitPath != null) {
      final file = File(explicitPath);
      if (await file.exists()) return file.readAsString();
    }
    if (videoPath.startsWith('http://') || videoPath.startsWith('https://')) {
      return null;
    }
    final videoFile = File(videoPath);
    final danmakuFile = File(
      '${videoFile.parent.path}${Platform.pathSeparator}${videoFile.uri.pathSegments.last}_danmaku.json',
    );
    if (await danmakuFile.exists()) return danmakuFile.readAsString();
    return null;
  }

  void saveHistory({required int positionMs, required int durationMs}) {
    if (isLocalSource) return;
    // Fill missing cover/bgm in place — snapshot filters fields downstream.
    final cover = coverImageUrl;
    if (cover != null && cover.isNotEmpty) data['bgmImageUrl'] ??= cover;
    final bgmId = bgmInfo.subjectId;
    if (bgmId != null) data['bgmId'] ??= bgmId;

    PlayHistorySyncService.saveHistory(
      videoData: data,
      episodeIndex: currPlayIndex,
      positionMs: positionMs,
      durationMs: durationMs,
      urlIndex: currUrl,
    );
  }

  bool get isLoggedIn => (Instances.sp.getString('usertoken') ?? '').isNotEmpty;

  int? get validPostId {
    final postId = BgmUtils.toInt(data['id']);
    return postId != null && postId > 0 ? postId : null;
  }

  bool isFollow() =>
      CollectionStatus.fromValue(collection?.status) == CollectionStatus.doing;

  Future<AnimeCollection?> ensureCollectionStatus() {
    if (isLocalSource || !isLoggedIn) return Future.value(collection);
    return _collectionFuture ??= _loadCollection();
  }

  Future<AnimeCollection?> _loadCollection() async {
    try {
      final bgmId = (await ensureBgmInfo()).subjectId;
      if (bgmId == null) return collection;
      final result = await CollectionApi.getByBgmId(bgmId);
      if (result != null) collection = result;
      return collection;
    } catch (e) {
      debugPrint('获取追番状态失败: $e');
      _collectionFuture = null;
      return collection;
    }
  }

  Future<String> toggleFollow() async {
    if (!isLoggedIn) throw Exception('请先登录');

    await Future.wait([
      ensureBgmInfo(),
      ensureBgmDetail(),
      ensureCollectionStatus(),
    ]);

    if (isFollow()) {
      final current = collection;
      if (current == null) return '操作失败';
      final bgmId = current.bgmId ?? bgmInfo.subjectId;
      final postId = current.postId ?? validPostId;
      final success = bgmId != null
          ? await CollectionApi.deleteByBgmId(bgmId)
          : postId != null
          ? await CollectionApi.delete(postId)
          : false;
      if (!success) throw Exception('取消追番失败');
      collection = null;
      return '已取消在看';
    }

    final detail = bgmDetailData;
    final epCount = videoList.isEmpty ? null : videoList.length;
    final result = await CollectionApi.addOrUpdate(
      AnimeCollection(
        postId: validPostId,
        bgmId: bgmInfo.subjectId,
        status: CollectionStatus.doing.value,
        epTotal: epCount,
        epWatched: epCount == null ? null : currPlayIndex + 1,
        postTitle: title,
        postCover: coverImageUrl,
        bgmImage: bgmInfo.imageUrl,
        bgmTitle:
            detail?['name_cn']?.toString() ??
            detail?['name']?.toString() ??
            title,
      ),
    );
    if (result == null) throw Exception('追番失败');
    collection = result;
    return '已加入在看';
  }

  void dispose() {
    stopAdapterPlaybackKeepAlive();
    _adapter = null;
    TorrentService.instance.stopStream();
  }
}
