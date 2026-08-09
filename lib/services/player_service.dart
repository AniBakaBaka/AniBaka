import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/api/post.dart';
import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/services/collection_service.dart';
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

/// 播放器业务逻辑服务
///
/// 负责视频数据管理、适配器源管理、集数切换、进度管理、弹幕数据获取、BGM信息等。
/// UI 层（PlayerPage）持有本实例，将控制器生命周期与界面构建留在 Widget 层。
class PlayerService {
  static const String _prefetchedPlaybackKey = '_prefetchedPlayback';
  static const Duration _prefetchedPlaybackTtl = Duration(minutes: 10);

  static bool isEpisodeWatched(String videoId, int episodeIndex) =>
      _readProgress('${videoId}_${episodeIndex}_1').inSeconds > 30;

  static Duration _readProgress(String key) {
    final progress = AppStorage.videoProgressBox.get(key);
    return Duration(milliseconds: progress?['positionMs'] as int? ?? 0);
  }

  static List<String>? _parseSourceNames(Object? raw) {
    if (raw == null) return null;
    final names = (raw as List).cast<String>();
    return names.isEmpty ? null : names;
  }

  /// Carries a direct URL resolved during matching into the player so opening
  /// the selected source does not resolve the same episode twice.
  static void storePrefetchedPlaybackMedia(
    Map data, {
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

  /// 丢弃失效预取（打开失败 / 校验失败后必须清，避免死链死循环）。
  static void clearPrefetchFrom(Map data) {
    data.remove(_prefetchedPlaybackKey);
  }

  void clearPrefetchedPlaybackMedia() => clearPrefetchFrom(data);

  PlayerService({required Map data, this.posIndex})
    : data = data.cast<String, dynamic>() {
    sourceNames = _parseSourceNames(data['sourceNames']);
    if (!isLocalSource) {
      bgmInfo = BgmUtils.readFromData(data);
      bgmDetailData = BgmUtils.asMap(data['bgmDetailData']);
      final embeddedEpisodes = bgmDetailData?['episodes'];
      if (embeddedEpisodes is List) {
        bgmEpisodes = BgmUtils.asMapList(embeddedEpisodes);
        _bgmEpisodesLoaded = true;
      }
      BgmUtils.normalizeCoverImage(data, bgmInfo: bgmInfo);
    }
  }

  final Map<String, dynamic> data;
  final int? posIndex;

  List<PlaybackEpisode> videoList = const [];
  int currPlayIndex = 0;
  int currUrl = 1;
  List<String>? sourceNames;

  bool get isLocalSource => data['source']?.toString() == '_local';
  bool get isAdapter {
    final source = data['source']?.toString();
    return !isLocalSource && AdapterRegistry.isAdapterSource(source);
  }

  String? get localFilePath => data['localFilePath'] as String?;
  String? get danmakuPath => data['danmakuPath'] as String?;
  Map<String, String>? get localHttpHeaders =>
      data['httpHeaders'] as Map<String, String>?;

  BgmInfo bgmInfo = const BgmInfo();
  Map<String, dynamic>? bgmDetailData;
  List<Map<String, dynamic>> bgmEpisodes = const [];
  bool _bgmEpisodesLoaded = false;
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
    if (currPlayIndex < 0 || currPlayIndex >= bgmEpisodes.length) return null;
    final ep = bgmEpisodes[currPlayIndex];
    return (ep['name_cn']?.toString().isNotEmpty == true
            ? ep['name_cn']
            : ep['name'])
        ?.toString();
  }

  String get title => data['title']?.toString() ?? '';

  String? get coverImageUrl =>
      BgmUtils.resolveCoverImage(data, bgmInfo: bgmInfo);

  /// 换源 / 自动匹配共用的 seed：title、身份字段、BGM 元数据一次打包，
  /// 避免 PlayerPage / Sheet 各自再拆 title/cover/score。
  Map<String, dynamic> buildSourceSeedData() {
    final subjectId = bgmInfo.subjectId;
    if (subjectId != null) data['bgmId'] = subjectId;
    final score = bgmInfo.score;
    if (score != null) data['score'] = score;
    final cover = coverImageUrl;
    if (cover != null && cover.isNotEmpty) data['bgmImageUrl'] = cover;
    final detail = bgmDetailData;
    if (detail != null) data['bgmDetailData'] = detail;
    return data;
  }

  String get logoUrl {
    final explicitLogo =
        data['logoUrl'] ?? data['logo'] ?? data['images']?['logo'];
    if (explicitLogo != null && explicitLogo.toString().isNotEmpty) {
      if (explicitLogo is List && explicitLogo.isNotEmpty) {
        return explicitLogo.first.toString();
      }
      return explicitLogo.toString();
    }
    return '';
  }

  PlaybackMediaInfo get initialMediaInfo => PlaybackMediaInfo(
    title: title,
    imageUrl: coverImageUrl ?? '',
    logoUrl: logoUrl,
  );

  PlaybackMediaInfo get currentMediaInfo {
    final episodeTitle = bgmEpisodeTitle;
    return PlaybackMediaInfo(
      title: title,
      episode: episodeTitle?.isNotEmpty == true
          ? episodeTitle!
          : currentEpisodeTitle,
      imageUrl: coverImageUrl ?? '',
      logoUrl: logoUrl,
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

  void applySelection(({int episodeIndex, int lineIndex}) selection) {
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
    // Adapter data stays typed for its whole in-memory lifetime.
    data.remove('videos');
    data['videoList'] = nextVideoList;
    if (sourceNames != null) {
      this.sourceNames = sourceNames;
      data['sourceNames'] = sourceNames;
    }

    applySelection(
      normalizeSelection(
        preferredEpisodeIndex ?? currPlayIndex,
        preferredLineIndex ?? currUrl,
      ),
    );
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
          if (response.isNotEmpty) {
            final postDetail =
                (jsonDecode(response) as Map<String, dynamic>)['data'] as Map?;
            if (postDetail != null) {
              data.addAll(postDetail.cast<String, dynamic>());
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
      PlaybackEpisodeCatalog.episodesOf(data, mergeDuplicateTitles: true),
      sourceNames: _parseSourceNames(data['sourceNames']),
      preferredEpisodeIndex: initialEpisodeIndex,
      preferredLineIndex: initialLineIndex,
    );
  }

  AdapterBase? _getAdapter(String? source) {
    if (source == null || source.isEmpty) return null;
    if (_adapterSource == source) return _adapter;

    _adapter = SourceAdapterService.instance.adapterFor(source);
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
      final catalog = await adapter.getPlaybackCatalog(seriesUrl.toString());
      if (catalog.isEmpty) throw Exception('无法获取剧集信息');
      syncVideoData(catalog.episodes, sourceNames: catalog.sourceNames);
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
    bool preferPrefetch = true,
  }) async {
    var media =
        (preferPrefetch ? _readPrefetchedPlaybackMedia(episodeId) : null) ??
        await adapter.resolvePlaybackMedia(episodeId);

    if (media.url.isEmpty) {
      clearPrefetchedPlaybackMedia();
      final episode = currentVideoItem;
      if (episode != null) {
        for (var line = 1; line <= episode.lines.length; line++) {
          if (line == currUrl) continue;
          final alternateId = episode.lineAt(line);
          if (alternateId == null || alternateId.isEmpty) continue;
          // 换线必须带校验，空壳 m3u8 直接跳过。
          final alternate = await adapter.resolvePlaybackMedia(alternateId);
          if (alternate.url.isEmpty) continue;
          applySelection((episodeIndex: currPlayIndex, lineIndex: line));
          media = alternate;
          storePrefetchedPlaybackMedia(
            data,
            episodeIndex: currPlayIndex,
            lineIndex: line,
            episodeId: alternateId,
            url: alternate.url,
            httpHeaders: alternate.httpHeaders,
          );
          break;
        }
      }
    }
    if (media.url.isEmpty || !TorrentService.isBtLink(media.url)) {
      return media;
    }

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

  /// 将选中的播放源写回播放器持有的唯一数据对象。
  void adoptPlaybackData(Map from) {
    final v = from[_prefetchedPlaybackKey];
    if (v != null) data[_prefetchedPlaybackKey] = v;

    for (final key in [
      'id',
      'source',
      'sourceUrl',
      'sourceDisplayName',
      'seriesUrl',
      'seriesId',
      'videos',
      'videoList',
      'sourceNames',
      'currPlayIndex',
      'currUrl',
    ]) {
      if (from.containsKey(key) && from[key] != null) {
        data[key] = from[key];
      }
    }

    final episodes = PlaybackEpisodeCatalog.episodesOf(
      data,
      mergeDuplicateTitles: true,
    );
    if (episodes.isNotEmpty) {
      syncVideoData(
        episodes,
        sourceNames: _parseSourceNames(data['sourceNames']),
        preferredEpisodeIndex:
            BgmUtils.toInt(from['currPlayIndex']) ?? currPlayIndex,
        preferredLineIndex: BgmUtils.toInt(from['currUrl']) ?? currUrl,
      );
    }
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

    return (url: url, httpHeaders: raw['httpHeaders'] as Map<String, String>);
  }

  Future<String?> _resolvePlayUrl(String episodeId) async {
    final response = await getPlayUrl(
      episodeId,
    ).timeout(const Duration(seconds: 15));
    if (response.isEmpty) return null;
    final jsonData = jsonDecode(response) as Map<String, dynamic>;
    return (jsonData['data'] as Map<String, dynamic>?)?['url'] as String?;
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
    if (bgmDetailData != null && _bgmEpisodesLoaded) {
      return Future.value(bgmDetailData);
    }
    return _bgmDetailFuture ??= _loadBgmDetail();
  }

  Future<Map<String, dynamic>?> _loadBgmDetail() async {
    try {
      final subjectId = (await ensureBgmInfo()).subjectId;
      if (subjectId == null) return null;

      final detailFuture = bgmDetailData == null
          ? getBgmSubject(subjectId)
          : Future.value(bgmDetailData!);
      final episodesFuture = _bgmEpisodesLoaded
          ? Future.value(bgmEpisodes)
          : getBgmEpisodes(subjectId);
      final detail = await detailFuture;
      bgmEpisodes = await episodesFuture;
      _bgmEpisodesLoaded = true;

      bgmDetailData = detail;
      final airDate = BgmUtils.formatPlainDate(detail['date']);
      if (airDate != null) data['airDate'] = airDate;
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

    return DanmakuService.fetch(
      subjectId: bgmId,
      episodeIndex: episodeIndex + 1,
      titles: BgmUtils.buildSearchTitles([title]),
    );
  }

  Future<void> saveProgress(
    Duration position,
    bool rememberLastPosition,
  ) async {
    if (!rememberLastPosition) return;
    await AppStorage.videoProgressBox.put(videoKey, {
      'positionMs': position.inMilliseconds,
      'updateTime': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Duration getSavedProgress() => _readProgress(videoKey);

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

  int? get validPostId {
    final postId = BgmUtils.toInt(data['id']);
    return postId != null && postId > 0 ? postId : null;
  }

  bool isFollow() =>
      CollectionStatus.fromValue(collection?.status) == CollectionStatus.doing;

  Future<AnimeCollection?> ensureCollectionStatus() {
    if (isLocalSource) return Future.value(collection);
    return _collectionFuture ??= _loadCollection();
  }

  Future<AnimeCollection?> _loadCollection() async {
    try {
      final bgmId = (await ensureBgmInfo()).subjectId;
      if (bgmId == null) return collection;
      final result = await CollectionService.getByBgmId(bgmId);
      if (result != null) collection = result;
      return collection;
    } catch (e) {
      debugPrint('获取追番状态失败: $e');
      _collectionFuture = null;
      return collection;
    }
  }

  Future<String> toggleFollow() async {
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
          ? await CollectionService.deleteByBgmId(bgmId)
          : postId != null
          ? await CollectionService.delete(postId)
          : false;
      if (!success) throw Exception('取消追番失败');
      collection = null;
      return '已取消在看';
    }

    final detail = bgmDetailData;
    final epCount = videoList.isEmpty ? null : videoList.length;
    final result = await CollectionService.addOrUpdate(
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
    _adapter?.dispose();
    _adapter = null;
    _adapterSource = null;
    TorrentService.instance.stopStream();
  }
}
