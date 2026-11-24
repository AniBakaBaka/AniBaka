import 'package:baka/core/app_logger.dart';
import 'package:baka/core/content_filter.dart';
import 'package:baka/models/skip_segment.dart';
import 'package:baka/source/runtime/source_operation.dart';
import 'dart:async';
import 'package:baka/utils/title_matcher.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/utils/json_values.dart';

import 'package:baka/api/anibaka_api.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/api/post.dart';
import 'package:baka/api/playback.dart';
import 'package:baka/models/anime_detail_view_data.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/services/playback/episode_numbering.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/services/torrent/torrent_service.dart';
import 'package:baka/services/torrent/torrent_model.dart';
import 'package:baka/source/source_adapter.dart';
import 'package:baka/source/source_registry.dart';

/// 播放器业务逻辑服务
///
/// 持有当前播放会话、剧集/线路选择和资源解析；持久化由 Repository 持有。
class PlaybackContent {
  void clearPrefetchedPlaybackMedia() => request.prefetched = null;

  PlaybackContent({
    required PlaybackRequest request,
    required this.sources,
    required this.collections,
    required this.history,
    int? posIndex,
  }) : _request = request.copyWith() {
    _posIndex = posIndex;
    if (!isLocalSource) {
      bgmInfo = BgmInfo.fromData(data);
      bgmDetailData = data['bgmDetailData'] as Map<String, dynamic>?;
      // Auto matching starts before loadDetail. Keep the desired episode even
      // while its source catalog is still empty.
      final remembered = history.getResumeSelection(
        this.request,
        bgmId: bgmInfo.subjectId,
      );
      _request.episodeIndex =
          _takePosIndex() ?? request.episodeIndex ?? remembered?.episodeIndex;
      _request.lineIndex = request.lineIndex ?? remembered?.lineIndex;
    }
  }

  final TorrentService torrent = TorrentService();
  PlaybackRequest _request;
  PlaybackRequest get request => _request;
  SourceOperation _lifetime = SourceOperation();
  bool _disposed = false;
  final SourceAdapterService sources;
  final CollectionRepository collections;
  final HistoryRepository history;
  Map<String, dynamic> get data => request.metadata;

  /// 打开播放页时指定的集下标，只用一次。
  int? _posIndex;

  int? _takePosIndex() {
    final value = _posIndex;
    _posIndex = null;
    return value;
  }

  List<PlaybackEpisode> get videoList => request.episodes;
  int get currPlayIndex => request.episodeIndex ?? 0;
  int get currUrl => request.lineIndex ?? 1;
  List<String>? get sourceNames => request.sourceNames;

  EpisodeNumbering? _numbering;
  List<PlaybackEpisode>? _numberingSource;

  /// 源分集标题里的集号。
  EpisodeNumbering get episodeNumbering {
    if (!identical(_numberingSource, videoList)) {
      _numberingSource = videoList;
      _numbering = EpisodeNumbering(videoList.map((episode) => episode.title));
    }
    return _numbering!;
  }

  /// 播放顺序上的下一集，按集号而不是数组下标。
  int? nextEpisodeIndex() {
    if (videoList.isEmpty) return null;
    final numbering = episodeNumbering;
    final current = numbering.isUsable
        ? numbering.numberAt(currPlayIndex)
        : null;
    if (current != null) {
      final byNumber = numbering.nextIndex(currPlayIndex);
      if (byNumber != null) return byNumber;
    }
    final following = currPlayIndex + 1;
    if (following >= videoList.length) return null;
    // 下一项没编号（特别篇）或集号更大时才顺序前进。
    final next = numbering.numberAt(following);
    if (current == null || next == null || next > current) return following;
    return null;
  }

  int? previousEpisodeIndex() {
    if (videoList.isEmpty) return null;
    final numbering = episodeNumbering;
    final current = numbering.isUsable
        ? numbering.numberAt(currPlayIndex)
        : null;
    if (current != null) {
      final byNumber = numbering.previousIndex(currPlayIndex);
      if (byNumber != null) return byNumber;
    }
    final preceding = currPlayIndex - 1;
    if (preceding < 0) return null;
    final previous = numbering.numberAt(preceding);
    if (current == null || previous == null || previous < current) {
      return preceding;
    }
    return null;
  }

  bool get hasNextEpisode => nextEpisodeIndex() != null;

  /// 当前集在 Bangumi 上是「第几集」，用于收藏进度。
  int? get currentBgmOrdinal {
    final number = episodeNumbering.numberAt(currPlayIndex);
    if (bgmEpisodes.isNotEmpty && number != null) {
      return BgmEpisodeOrder.ordinalOf(bgmEpisodes, number);
    }
    if (number != null) return number;
    if (bgmEpisodes.isEmpty || bgmEpisodes.length == videoList.length) {
      return currPlayIndex + 1;
    }
    return null;
  }

  /// Bangumi 条目的本篇总集数；未知时为 null。
  int? get bgmEpisodeCount {
    if (bgmEpisodes.isNotEmpty) return bgmEpisodes.length;
    final total = toInt(
      bgmDetailData?['eps'] ?? bgmDetailData?['total_episodes'],
    );
    return total != null && total > 0 ? total : null;
  }

  /// 源下标 → Bangumi 分集条目；集号对不上时返回 null。
  Map<String, dynamic>? _bgmEpisodeForSource(int index) {
    final number = episodeNumbering.numberAt(index);
    if (number != null && bgmEpisodes.isNotEmpty) {
      return BgmEpisodeOrder.byNumber(bgmEpisodes, number);
    }
    if (index >= 0 && index < bgmEpisodes.length) return bgmEpisodes[index];
    return null;
  }

  bool get isLocalSource => request.source == '_local';
  bool get isAdapter {
    final source = request.source;
    return !isLocalSource && AdapterRegistry.isAdapterSource(source);
  }

  /// Bangumi 条目的 `id` 是 BGM 条目 id，与贴文 id 不在同一命名空间。
  bool get isBgmSubject => request.source.trim() == 'bgm';

  /// A cloud history record identifies the anime, not a source on this device.
  bool get needsSourceMatch =>
      isBgmSubject || request.source.trim() == 'history';

  String? get localFilePath {
    if (isLocalSource && videoList.isNotEmpty) {
      final item = currentVideoItem;
      if (item != null && item.lines.isNotEmpty) {
        return item.lineAt(currUrl) ??
            item.lineAt(item.availableLineIndexes.firstOrNull ?? 1) ??
            '';
      }
    }
    return data['localFilePath'] as String?;
  }

  String? get danmakuPath => data['danmakuPath'] as String?;
  Map<String, String>? get localHttpHeaders => request.httpHeaders;

  BgmInfo bgmInfo = const BgmInfo();
  Map<String, dynamic>? bgmDetailData;
  List<Map<String, dynamic>> bgmEpisodes = const [];
  Future<BgmInfo>? _bgmInfoFuture;
  Future<void>? _bgmDetailFuture;
  AnimeCollection? collection;
  /// 收藏读取的版本号；写入时自增，用来丢弃过期的读取结果。
  int _collectionRevision = 0;

  SourceAdapter? _playbackKeepAliveAdapter;
  int _playbackKeepAliveGeneration = 0;

  PlaybackEpisode? get currentVideoItem =>
      currPlayIndex >= 0 && currPlayIndex < videoList.length
      ? videoList[currPlayIndex]
      : null;

  String get currentEpisodeTitle {
    if (isLocalSource) {
      final item = currentVideoItem;
      if (item != null && item.title.isNotEmpty) return item.title;

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

  String? get bgmEpisodeTitle {
    final ep = _bgmEpisodeForSource(currPlayIndex);
    if (ep == null) return null;
    return (ep['name_cn']?.toString().isNotEmpty == true
            ? ep['name_cn']
            : ep['name'])
        ?.toString();
  }

  String get title => data['title']?.toString() ?? '';

  bool get isNsfw =>
      ContentFilter.isNsfw(data) || bgmDetailData?['nsfw'] == true;

  /// Matching progress is rendered by the source chips themselves.
  String get sourceName => needsSourceMatch
      ? '选择播放源'
      : trimmed(data['sourceDisplayName']) ?? trimmed(request.source) ?? '播放源';

  String? get lineName {
    final names = sourceNames;
    return names != null && currUrl <= names.length
        ? trimmed(names[currUrl - 1])
        : null;
  }

  /// External sources share one comment thread per Bangumi subject.
  int? get commentPostId {
    final id = (isAdapter ? bgmInfo.subjectId : null) ?? toInt(data['id']);
    return id != null && id > 0 ? id : null;
  }

  /// Must match the episode picker, or the progress bar misses local tasks.
  String get downloadTaskPrefix {
    final id = data['id'];
    return request.source.isNotEmpty ? '${request.source}_${id}_' : '${id}_';
  }

  List<String> get tags {
    final bgmTags = bgmDetailData?['tags'] as List?;
    if (bgmTags != null && bgmTags.isNotEmpty) {
      return [
        for (final tag in bgmTags.take(6)) (tag as Map)['name'] as String,
      ];
    }
    final raw = data['tag']?.toString();
    if (raw == null) return const [];
    final hidden = {
      data['sourceDisplayName']?.toString(),
      request.source,
      sourceName,
    };
    return raw
        .split(' ')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty && !hidden.contains(tag))
        .take(5)
        .toList(growable: false);
  }

  /// Annotation identity of the open line. The hashed parts must stay stable,
  /// or saved OP/ED segments of existing users stop matching.
  SkipContext buildSkipContext(String timelineKey) {
    final names = sourceNames;
    final Object line = names != null && currUrl <= names.length
        ? names[currUrl - 1]
        : currUrl;
    return SkipContext(
      sourceKey: SkipContext.sourceIdentity([
        request.source,
        request.contentId,
        currentVideoItem?.lineAt(currUrl),
        line,
      ]),
      timelineKey: timelineKey,
      episodeNumber:
          episodeNumbering.numberAt(currPlayIndex)?.toDouble() ??
          skipEpisodeNumber(currentEpisodeTitle) ??
          (currPlayIndex + 1).toDouble(),
      seriesKey: SkipContext.sourceIdentity([
        request.source,
        request.contentId,
        line,
      ]),
      // Display metadata may come from fuzzy title search; only an explicit
      // playback identity (or a saved personal binding) can drive a seek.
      subjectId: BgmInfo.fromData(data).subjectId,
    );
  }

  String? _searchTitle;
  List<String> _searchTitles = const [];

  List<String> get searchTitles {
    final current = title;
    if (_searchTitle != current) {
      _searchTitle = current;
      _searchTitles = buildSearchTitles([current]);
    }
    return _searchTitles;
  }

  String? get coverImageUrl => resolveCoverImage(data, bgmInfo: bgmInfo);

  String? _logoUrl;
  String get logoUrl => _logoUrl ?? AnimeDetailViewData.resolveLogoUrl(data);

  ({
    PlaybackRequest request,
    BgmInfo bgmInfo,
    Map<String, dynamic>? bgmDetail,
    String? logo,
  })?
  _detailInputs;
  Map<String, dynamic>? _detailData;

  /// The item as the detail page and source search read it. One map is kept
  /// until the request or its Bangumi metadata changes, so widgets given it
  /// see the same item across rebuilds.
  Map<String, dynamic> get detailData {
    final inputs = (
      request: request,
      bgmInfo: bgmInfo,
      bgmDetail: bgmDetailData,
      logo: _logoUrl,
    );
    if (_detailData != null && _detailInputs == inputs) return _detailData!;
    _detailInputs = inputs;
    final logo = logoUrl;
    return _detailData = Map.unmodifiable({
      ...data,
      'source': request.source,
      'bgmId': ?bgmInfo.subjectId,
      'score': ?bgmInfo.score,
      'bgmImageUrl': ?coverImageUrl,
      'bgmDetailData': ?bgmDetailData,
      if (logo.isNotEmpty) 'logoUrl': logo,
    });
  }

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
      return (
        episodeIndex: episodeIndex < 0 ? 0 : episodeIndex,
        lineIndex: (lineIndex ?? currUrl) > 0 ? (lineIndex ?? currUrl) : 1,
      );
    }
    var target = episodeIndex;
    if (target < 0 || target >= videoList.length) {
      // 越界时按标题里的集号反查源下标，找不到再夹取。
      final mapped = episodeNumbering.indexOfNumber(target + 1);
      if (mapped != null) {
        Log.w('Playback', '剧集下标 $episodeIndex 越界，按集号映射到第 ${target + 1} 集');
        target = mapped;
      }
    }
    final normalizedEpisodeIndex = target.clamp(0, videoList.length - 1);
    final preferred = lineIndex ?? currUrl;
    final episode = videoList[normalizedEpisodeIndex];
    return (
      episodeIndex: normalizedEpisodeIndex,
      lineIndex: episode.lineAt(preferred) != null
          ? preferred
          : episode.availableLineIndexes.firstOrNull ?? 1,
    );
  }

  void applySelection(({int episodeIndex, int lineIndex}) selection) {
    request.episodeIndex = selection.episodeIndex;
    request.lineIndex = selection.lineIndex;
    if (_readPrefetchedPlaybackMedia(currentEpisodeId) == null) {
      clearPrefetchedPlaybackMedia();
    }
  }

  void syncVideoData(
    List<PlaybackEpisode> nextVideoList, {
    List<String>? sourceNames,
    int? preferredEpisodeIndex,
    int? preferredLineIndex,
  }) {
    _request = request.copyWith(
      episodes: nextVideoList,
      sourceNames: sourceNames,
    );
    applySelection(
      normalizeSelection(
        preferredEpisodeIndex ?? currPlayIndex,
        preferredLineIndex ?? currUrl,
      ),
    );
  }

  /// A source name alone is not ready to play. Reload its catalog on this
  /// device, then require an actual line for the selected episode.
  Future<bool> prepareInitialPlayback() async {
    if (needsSourceMatch) return false;
    await loadDetail();
    if (isAdapter) await prepareAdapterSource();
    return currentEpisodeId.trim().isNotEmpty;
  }

  Future<void> loadDetail() async {
    if (isLocalSource) {
      if (videoList.isEmpty && localFilePath != null) {
        _request = request.copyWith(
          episodes: [
            PlaybackEpisode(
              title: currentEpisodeTitle,
              lines: [localFilePath!],
            ),
          ],
        );
      }
      final preferred = _takePosIndex() ?? currPlayIndex;
      applySelection(normalizeSelection(preferred, currUrl));
      return;
    }

    final explicitEpisodeIndex = _takePosIndex() ?? request.episodeIndex;
    final explicitLineIndex = request.lineIndex;

    // Bangumi 条目的 `id` 是 BGM 条目 id，拿去查贴文只会拿到 null 或别人的贴文。
    if (!isAdapter &&
        !needsSourceMatch &&
        (request.source.isEmpty || request.source == 'internal')) {
      final postId = int.tryParse(data['id']?.toString() ?? '');
      if (postId != null && postId > 0) {
        final lifetime = _lifetime;
        lifetime.token.throwIfCancelled();
        final abort = Completer<void>();
        final detach = lifetime.token.onCancel(abort.complete);
        try {
          final response = await getPostDetail(
            postId,
            abortTrigger: abort.future,
          );
          lifetime.token.throwIfCancelled();
          if (response.isNotEmpty) {
            final detail = PlaybackRequest.fromMap(response);
            _request = request.copyWith(
              episodes: detail.episodes,
              sourceNames: detail.sourceNames,
              metadataUpdates: detail.metadata,
            );
          }
        } catch (e) {
          if (lifetime.isCancelled || videoList.isEmpty) rethrow;
          Log.w('Playback', 'Failed to load post detail: $e');
        } finally {
          detach();
        }
      }
    }

    final remembered = history.getResumeSelection(
      request,
      bgmId: bgmInfo.subjectId,
    );
    syncVideoData(
      videoList,
      sourceNames: sourceNames,
      preferredEpisodeIndex:
          explicitEpisodeIndex ?? remembered?.episodeIndex ?? currPlayIndex,
      preferredLineIndex: explicitLineIndex ?? remembered?.lineIndex ?? currUrl,
    );
  }

  Future<SourceAdapter> prepareAdapterSource() async {
    final operation = SourceOperation(
      parent: _lifetime,
      timeout: const Duration(seconds: 15),
    );
    final detach = SourceOperation.current?.token.onCancel(operation.cancel);
    try {
      return await operation.run(() async {
        final current = request;
        await sources.init();
        _lifetime.token.throwIfCancelled();
        SourceOperation.check();
        final source = current.source;
        final adapter = sources.adapterFor(source);
        if (adapter == null) throw Exception('不支持的源类型: $source');

        sources.retainPlayback(this, adapter);

        if (currentEpisodeId.trim().isEmpty || sourceNames == null) {
          final seriesUrl = data['seriesUrl'] ?? data['id'].toString();
          final catalog = await adapter.getPlaybackCatalog(
            seriesUrl.toString(),
          );
          _lifetime.token.throwIfCancelled();
          SourceOperation.check();
          if (!identical(current, request)) throw StateError('播放会话已变更');
          if (catalog.isEmpty) throw Exception('无法获取剧集信息');
          syncVideoData(catalog.episodes, sourceNames: catalog.sourceNames);
        }
        return adapter;
      });
    } finally {
      detach?.call();
      operation.close();
    }
  }

  String get currentEpisodeId => currentVideoItem?.lineAt(currUrl) ?? '';

  Future<PlaybackMedia> resolveAdapterPlaybackMedia(
    SourceAdapter adapter,
    String episodeId, {
    Duration torrentBufferTimeout = TorrentService.defaultBufferTimeout,
    bool preferPrefetch = true,
  }) async {
    final operation = SourceOperation(parent: _lifetime);
    final detachOuter = SourceOperation.current?.token.onCancel(
      operation.cancel,
    );
    try {
      return await operation.run(() async {
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
              final alternate = await adapter.resolvePlaybackMedia(alternateId);
              if (alternate.url.isEmpty) continue;
              applySelection((episodeIndex: currPlayIndex, lineIndex: line));
              media = alternate;
              request.storePrefetched(
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
        if (media.url.isEmpty || !isTorrentLink(media.url)) {
          return media;
        }

        final detach = SourceOperation.current?.token.onCancel(() {
          unawaited(torrent.stopStream());
        });
        final String streamUrl;
        try {
          streamUrl = await torrent.resolvePlaybackUrl(
            media.url,
            bufferTimeout: torrentBufferTimeout,
          );
        } finally {
          detach?.call();
        }
        return (url: streamUrl, httpHeaders: const <String, String>{});
      });
    } finally {
      detachOuter?.call();
      operation.close();
    }
  }

  Future<int> startAdapterPlaybackKeepAlive(
    SourceAdapter adapter,
    String mediaUrl,
  ) async {
    _lifetime.token.throwIfCancelled();
    SourceOperation.check();
    sources.retainPlayback(this, adapter);
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

  void adoptPlaybackRequest(PlaybackRequest next) {
    _lifetime.token.throwIfCancelled();
    _lifetime.cancel();
    _lifetime.close();
    _lifetime = SourceOperation();
    stopAdapterPlaybackKeepAlive();
    sources.releasePlayback(this);
    _request = next.copyWith();
    applySelection(normalizeSelection(currPlayIndex, currUrl));
  }

  PlaybackMedia? _readPrefetchedPlaybackMedia(
    String episodeId, {
    int? episodeIndex,
  }) {
    final media = request.prefetched;
    if (media == null ||
        !media.matches(
          request.source,
          episodeIndex ?? currPlayIndex,
          currUrl,
          episodeId,
          DateTime.now().millisecondsSinceEpoch,
        )) {
      return null;
    }
    return (url: media.url, httpHeaders: media.httpHeaders);
  }

  Future<String?> resolveEpisodeUrl(int episodeIndex) async {
    final operation = SourceOperation(
      parent: _lifetime,
      timeout: const Duration(seconds: 15),
    );
    final detach = SourceOperation.current?.token.onCancel(operation.cancel);
    try {
      return await operation.run(() async {
        if (episodeIndex < 0 || episodeIndex >= videoList.length) return null;
        final item = videoList[episodeIndex];
        final episodeId =
            item.lineAt(currUrl) ??
            item.lineAt(item.availableLineIndexes.firstOrNull ?? 1);
        if (episodeId == null) return null;

        if (isLocalSource) return episodeId;

        if (isAdapter) {
          final adapter = sources.adapterFor(request.source);
          if (adapter == null) return null;
          final resolvedUrl =
              _readPrefetchedPlaybackMedia(
                episodeId,
                episodeIndex: episodeIndex,
              )?.url ??
              (await adapter.resolvePlaybackMedia(episodeId)).url;
          return resolvedUrl.isEmpty ? null : resolvedUrl;
        }

        final abort = Completer<void>();
        final detach = operation.token.onCancel(() => abort.complete());
        try {
          return await getPlayUrl(episodeId, abortTrigger: abort.future);
        } finally {
          detach();
        }
      });
    } finally {
      detach?.call();
      operation.cancel();
      operation.close();
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
      bgmInfo = await resolveBgmFromData(data);
      return bgmInfo;
    } catch (_) {
      _bgmInfoFuture = null;
      return bgmInfo;
    }
  }

  Future<void> ensureBgmDetail() {
    if (isLocalSource) return Future.value();
    return _bgmDetailFuture ??= _loadBgmDetail();
  }

  Future<void> _loadBgmDetail() async {
    try {
      final subjectId = (await ensureBgmInfo()).subjectId;
      if (subjectId == null) return;

      final detailFuture = bgmDetailData == null
          ? getBgmSubject(subjectId)
          : Future.value(bgmDetailData!);
      final episodesFuture = getBgmEpisodes(subjectId);
      final animeDetailFuture = logoUrl.isEmpty
          ? AniBakaApi.getAnimeDetail(subjectId).catchError((_) => null)
          : Future<Map<String, dynamic>?>.value(null);

      final result = await (
        detailFuture,
        episodesFuture,
        animeDetailFuture,
      ).wait;
      final detail = result.$1;
      bgmEpisodes = result.$2;
      final animeDetail = result.$3;
      bgmDetailData = detail;
      final resolvedLogo = AnimeDetailViewData.resolveLogoUrl(animeDetail);
      if (resolvedLogo.isNotEmpty) _logoUrl = resolvedLogo;
    } catch (e) {
      Log.w('Playback', '获取 BGM 放映信息失败: $e');
      _bgmDetailFuture = null;
    }
  }

  Future<List<DanmakuItem>> fetchDanmakuData(
    int episodeIndex, {
    Future<void>? abortTrigger,
  }) async {
    final lifetime = _lifetime;
    if (isLocalSource) {
      return DanmakuController.loadLocal(
        localFilePath,
        danmakuPath: danmakuPath,
      );
    }
    final info = await ensureBgmInfo();
    lifetime.token.throwIfCancelled();
    final bgmId = info.subjectId;
    if (bgmId == null) return const [];

    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    final detach = lifetime.token.onCancel(cancel);
    final detachOuter = SourceOperation.current?.token.onCancel(cancel);
    try {
      // `p` 是集号，不是源分集的数组下标。
      final episodeNumber =
          episodeNumbering.numberAt(episodeIndex) ?? episodeIndex + 1;
      return await DanmakuController.fetchDanmaku(
        subjectId: bgmId,
        episodeIndex: episodeNumber,
        titles: searchTitles,
        abortTrigger: abortTrigger == null
            ? abort.future
            : Future.any([abort.future, abortTrigger]),
      );
    } finally {
      detach();
      detachOuter?.call();
    }
  }

  /// 贴文 id 只对本站条目成立，BGM 条目 id 不能写进收藏的 post_id。
  int? get validPostId =>
      AnimeCollection.postIdFrom(data, source: request.source);

  bool isFollow() =>
      CollectionStatus.fromValue(collection?.status) == CollectionStatus.doing;

  Future<void> refreshCollection() async {
    if (isLocalSource || _disposed) return;
    final revision = ++_collectionRevision;
    final bgmId = (await ensureBgmInfo()).subjectId;
    final postId = validPostId;
    if (_disposed || revision != _collectionRevision) return;
    var current = bgmId != null ? await collections.getByBgmId(bgmId) : null;
    if (current == null && postId != null) {
      current = await collections.getByPostId(postId);
    }
    // An initial read must not overwrite a newer follow/unfollow operation.
    if (!_disposed && revision == _collectionRevision) collection = current;
  }

  /// 追番开关：已追番则取消，否则标记为「在看」。
  Future<void> toggleFollow() async {
    if (isFollow()) return removeFromCollection();
    return setCollectionStatus(CollectionStatus.doing);
  }

  /// 取消收藏。[collection] 先清空，请求失败再放回。
  Future<void> removeFromCollection() async {
    final previous = collection;
    if (previous == null) return;
    // 进页面时的收藏读取如果还没返回，忽略它的结果。
    ++_collectionRevision;
    final postId = previous.postId ?? validPostId;
    final bgmId = previous.bgmId ?? (postId == null ? bgmInfo.subjectId : null);
    collection = null;
    try {
      final success = bgmId != null
          ? await collections.deleteByBgmId(bgmId)
          : postId != null
          ? await collections.delete(postId)
          : false;
      if (!success) throw Exception('取消追番失败');
    } catch (error) {
      collection = previous;
      rethrow;
    }
  }

  /// 切换收藏状态，[status] 为空表示取消收藏。
  ///
  /// 本地模式先写本地、Bangumi 同步放后台；云端模式等本站保存返回后再更新。
  /// Bangumi 只做镜像，失败不影响收藏结果。
  Future<void> setCollectionStatus(CollectionStatus? status) async {
    if (status == null) return removeFromCollection();
    final previous = collection;
    if (CollectionStatus.fromValue(previous?.status) == status) return;
    // 进页面时的收藏读取如果还没返回，忽略它的结果。
    ++_collectionRevision;

    final detail = bgmDetailData;
    // 总集数与已看集数都以 Bangumi 为准。
    final epCount =
        bgmEpisodeCount ?? (videoList.isEmpty ? null : videoList.length);
    final bgmId = previous?.bgmId ?? bgmInfo.subjectId;
    final localWatched = bgmId == null
        ? 0
        : HistoryRepository.watchedCountForBgm(bgmId);
    final watched = currentBgmOrdinal ?? 0;
    final optimistic = AnimeCollection(
      postId: previous?.postId ?? validPostId,
      bgmId: bgmId,
      status: status.value,
      rating: previous?.rating ?? 0,
      comment: previous?.comment,
      epTotal: previous?.epTotal ?? epCount,
      epWatched: localWatched > watched ? localWatched : watched,
      tags: previous?.tags ?? const [],
      isPrivate: previous?.isPrivate ?? false,
      nsfw: previous?.nsfw ?? isNsfw,
      postTitle: previous?.postTitle ?? title,
      postCover: previous?.postCover ?? coverImageUrl,
      bgmRating: previous?.bgmRating,
      bgmImage: previous?.bgmImage ?? bgmInfo.imageUrl,
      bgmTitle:
          previous?.bgmTitle ??
          detail?['name_cn']?.toString() ??
          detail?['name']?.toString() ??
          title,
    );
    collection = optimistic;
    // 本地先落盘，Bangumi 同步放后台。
    if (collections.isLocalMode) {
      try {
        await collections.saveLocal(optimistic);
      } catch (error) {
        collection = previous;
        rethrow;
      }
      if (collections.isBangumiMode) {
        unawaited(
          collections.syncToBangumi(optimistic).catchError((
            Object error,
            StackTrace stackTrace,
          ) {
            Log.w('Player', 'Bangumi 收藏状态同步失败', error);
          }),
        );
      }
      return;
    }
    try {
      collection = await collections.addOrUpdate(optimistic);
    } catch (error) {
      collection = previous;
      rethrow;
    }
  }

  Future<void>? _disposing;
  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    _lifetime.cancel();
    _lifetime.close();
    stopAdapterPlaybackKeepAlive();
    sources.releasePlayback(this);
    await torrent.dispose();
  }
}
