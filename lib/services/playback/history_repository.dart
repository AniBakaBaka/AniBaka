import 'package:baka/core/app_logger.dart';
import 'package:baka/core/content_filter.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/utils/json_values.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'package:baka/api/anibaka_api.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/models/play_history.dart';
import 'package:baka/services/account/bangumi_session.dart';

/// 播放历史同步服务
late HistoryRepository historyRepository;

class HistoryRepository {
  HistoryRepository(this.session, this.bangumi);

  final AccountSession session;
  final BangumiSession bangumi;

  static const _historyKey = 'history';
  static const _resumeKey = 'resume';
  static const _maxHistoryCount = 50;
  static const _minPositionToSaveMs = 10000;

  /// 正片播完即算看完。
  static const _completionThreshold = 0.90;
  static const _platform = 'app';

  final Map<String, List<Map<String, dynamic>>> _memory = {};

  /// 每次落盘后自增，供首页「继续观看」刷新。
  final ValueNotifier<int> revision = ValueNotifier(0);

  void _logUploadFailure(Object error) =>
      Log.w('History', '上传播放历史失败（本地已保存）', error);

  String _localKey(Map record) {
    final bgm = toInt(record['bgmId']);
    final ep = toInt(record['index']);
    final video = (bgm != null && bgm > 0) ? 'bgm_$bgm' : 'id_${record['id']}';
    return '$video::ep_$ep';
  }

  String _remoteKey(PlayHistory r) {
    final bgm = r.bgmId;
    final ep = r.episodeId;
    final video = (bgm != null && bgm > 0) ? 'bgm_$bgm' : 'id_${r.videoId}';
    final normalizedEp = ep == null ? null : (ep > 0 ? ep - 1 : 0);
    return '$video::ep_$normalizedEp';
  }

  List<Map<String, dynamic>> _readList(String key) {
    final cached = _memory[key];
    if (cached != null) return cached;
    if (!Hive.isBoxOpen(AppStorage.playHistoryBoxName)) return const [];
    final stored = AppStorage.playHistoryBox.get(key);
    if (stored is! List) return const [];
    final records = <Map<String, dynamic>>[];
    for (var i = 0; i < stored.length; i++) {
      final item = stored[i];
      if (item is Map<String, dynamic>) {
        records.add(item);
      } else if (item is Map) {
        records.add(item.cast<String, dynamic>());
      }
    }
    return _memory[key] = records;
  }

  bool _sameAnime(Map left, Map right, {int? bgmId}) {
    final leftBgmId = bgmId ?? toInt(left['bgmId']);
    final rightBgmId = toInt(right['bgmId']);
    if (leftBgmId != null &&
        leftBgmId > 0 &&
        rightBgmId != null &&
        rightBgmId > 0) {
      return leftBgmId == rightBgmId;
    }
    final leftId = left['id']?.toString();
    final rightId = right['id']?.toString();
    if (leftId != null && leftId.isNotEmpty && leftId == rightId) {
      return true;
    }
    final leftTitle = left['title']?.toString() ?? '';
    final rightTitle = right['title']?.toString() ?? '';
    return leftTitle.isNotEmpty && leftTitle == rightTitle;
  }

  Map<String, dynamic> _fromRemote(PlayHistory r) {
    final bgmId = r.bgmId;
    final ep = r.episodeId;
    return {
      'id': r.videoId.toString(),
      // Cloud records have no adapter catalog or source identity. A Bangumi
      // subject can be matched again; its video_id is not a reliable post ID.
      'source': bgmId != null && bgmId > 0 ? 'bgm' : 'history',
      'title': r.videoTitle,
      'content': r.videoCover ?? '',
      'index': ep == null ? null : (ep > 0 ? ep - 1 : 0),
      'position': r.playProgress * 1000,
      'duration': r.videoDuration * 1000,
      'isFinished':
          r.videoDuration > 0 &&
          r.playProgress / r.videoDuration >= _completionThreshold,
      'watchTime':
          r.updatedAt?.millisecondsSinceEpoch ??
          DateTime.now().millisecondsSinceEpoch,
      'url': 1,
      if (bgmId != null && bgmId > 0) 'bgmId': bgmId,
    };
  }

  PlayHistory? _toRemote(Map local) {
    final bgmId = toInt(local['bgmId']);
    final validBgm = (bgmId != null && bgmId > 0) ? bgmId : null;
    final videoId = validBgm ?? toInt(local['id']);
    if (videoId == null) return null;

    final episodeIndex = toInt(local['index']);
    final cover = resolveCoverImage(local);
    final position = local['position'] as num? ?? 0;
    final duration = local['duration'] as num? ?? 0;

    return PlayHistory(
      videoId: videoId,
      videoTitle: local['title']?.toString() ?? '未知标题',
      videoCover: (cover == null || cover.isEmpty) ? null : cover,
      videoDuration: (duration / 1000).round(),
      playProgress: (position / 1000).round(),
      episodeId: episodeIndex != null ? episodeIndex + 1 : null,
      episodeTitle: episodeIndex != null ? '第${episodeIndex + 1}集' : null,
      videoType: 2,
      platform: _platform,
      bgmId: validBgm,
    );
  }

  Future<void> _write(String key, List<Map<String, dynamic>> list) {
    _memory[key] = list;
    if (key == _historyKey) revision.value++;
    return AppStorage.playHistoryBox.put(key, list);
  }

  List<Map<String, dynamic>> getHistoryList() => _readList(_historyKey);

  ({int episodeIndex, int lineIndex, int watchTime})? _findResumeSelection(
    PlaybackRequest request,
    Iterable<Map> records,
    int? bgmId,
  ) {
    for (final record in records) {
      if (!_sameAnime(request.metadata, record, bgmId: bgmId)) continue;
      final episodeIndex = toInt(record['index']);
      if (episodeIndex == null || episodeIndex < 0) continue;
      final source = request.source;
      final rememberedSource = record['source']?.toString() ?? '';
      final sameSource =
          source.isEmpty ||
          rememberedSource.isEmpty ||
          source == rememberedSource;
      final lineIndex = sameSource ? (toInt(record['url']) ?? 1) : 1;
      return (
        episodeIndex: episodeIndex,
        lineIndex: lineIndex > 0 ? lineIndex : 1,
        watchTime: toInt(record['watchTime']) ?? 0,
      );
    }
    return null;
  }

  ({int episodeIndex, int lineIndex})? getResumeSelection(
    PlaybackRequest request, {
    int? bgmId,
  }) {
    final remembered = _findResumeSelection(
      request,
      _readList(_resumeKey),
      bgmId,
    );
    final watched = _findResumeSelection(
      request,
      _readList(_historyKey),
      bgmId,
    );
    final latest =
        remembered == null ||
            (watched != null && watched.watchTime > remembered.watchTime)
        ? watched
        : remembered;
    return latest == null
        ? null
        : (episodeIndex: latest.episodeIndex, lineIndex: latest.lineIndex);
  }

  Future<void> rememberEpisode({
    required PlaybackRequest request,
    required int episodeIndex,
    required int urlIndex,
    int? bgmId,
  }) async {
    if (episodeIndex < 0 || !Hive.isBoxOpen(AppStorage.playHistoryBoxName)) {
      return;
    }
    final record = <String, dynamic>{
      'id': request.metadata['id'],
      'title': request.metadata['title'],
      'bgmId': bgmId ?? request.metadata['bgmId'],
      'source': request.source,
      'index': episodeIndex,
      'url': urlIndex > 0 ? urlIndex : 1,
      'watchTime': DateTime.now().millisecondsSinceEpoch,
    };

    final list = _readList(_resumeKey);
    final next = <Map<String, dynamic>>[record];
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      if (_sameAnime(record, item)) continue;
      next.add(item);
      if (next.length >= _maxHistoryCount) break;
    }
    await _write(_resumeKey, next);
  }

  Future<void> syncRemoteToLocal() async {
    try {
      final response = await AniBakaApi.getPlayHistory(
        pageSize: _maxHistoryCount,
      );
      if (response.isEmpty) return;

      final list = getHistoryList();
      final map = <String, Map<String, dynamic>>{};
      for (var i = 0; i < list.length; i++) {
        final item = list[i];
        map.putIfAbsent(_localKey(item), () => item);
      }

      for (final remote in response) {
        final key = _remoteKey(remote);
        final local = map[key];
        final remoteTime = remote.updatedAt?.millisecondsSinceEpoch ?? 0;
        final localTime = (local?['watchTime'] as int?) ?? 0;
        if (local == null || remoteTime >= localTime) {
          final next = {...?local, ..._fromRemote(remote)};
          if (local != null) {
            // Update progress without discarding this device's playback route.
            final request = PlaybackRequest.fromHistory(local);
            next['id'] = local['id'];
            next['source'] = request.source;
            next['url'] = local['url'] ?? 1;
          }
          map[key] = next;
        }
      }

      final ordered = map.values.toList(growable: false)
        ..sort(
          (a, b) => ((b['watchTime'] as int?) ?? 0).compareTo(
            (a['watchTime'] as int?) ?? 0,
          ),
        );
      final finalHistory = ordered.length > _maxHistoryCount
          ? ordered.sublist(0, _maxHistoryCount)
          : ordered;
      await _write(_historyKey, finalHistory);
    } catch (e) {
      Log.w('History', '同步远程历史失败: $e');
    }
  }

  Future<void> saveHistory({
    required PlaybackRequest request,
    required int episodeIndex,
    required int positionMs,
    required int durationMs,
    required int urlIndex,
    String? cover,
    int? bgmId,
    int? bgmEpisodeOrdinal,
  }) async {
    if (durationMs <= 0 || positionMs < 0) return;

    final record = <String, dynamic>{
      'id': request.metadata['id'],
      'title': request.metadata['title'],
      'content': request.metadata['content'],
      'image': request.metadata['image'],
      'bgmImageUrl': cover ?? request.metadata['bgmImageUrl'],
      'bgmId': bgmId ?? request.metadata['bgmId'],
      'source': request.source,
      'seriesUrl': request.metadata['seriesUrl'],
      'sourceUrl': request.metadata['sourceUrl'],
      'sourceDisplayName': request.metadata['sourceDisplayName'],
      'tag': request.metadata['tag'],
      'score': request.metadata['score'],
      'nsfw': ContentFilter.isNsfw(request.metadata),
      'info': request.metadata['info'],
      'index': episodeIndex,
      'position': positionMs,
      'duration': durationMs,
      'watchTime': DateTime.now().millisecondsSinceEpoch,
      'url': urlIndex,
      'isFinished': positionMs / durationMs >= _completionThreshold,
    };

    final key = _localKey(record);
    final list = _readList(_historyKey);
    if (positionMs <= _minPositionToSaveMs &&
        !list.any((item) => _localKey(item) == key)) {
      return;
    }
    final next = <Map<String, dynamic>>[record];
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      if (_localKey(item) == key) continue;
      next.add(item);
      if (next.length >= _maxHistoryCount) break;
    }
    await _write(_historyKey, next);

    final remote = _toRemote(record);
    if (remote != null && session.token.isNotEmpty) {
      unawaited(
        AniBakaApi.savePlayHistory(
          remote,
          notifyOnError: false,
        ).catchError(_logUploadFailure),
      );
    }

    final subjectId = toInt(record['bgmId']);
    // 拿不到 Bangumi 集序时不上报集数。
    final ordinal = bgmEpisodeOrdinal;
    if (record['isFinished'] == true &&
        subjectId != null &&
        ordinal != null &&
        bangumi.isConnected &&
        bangumi.autoMarkEpisode) {
      unawaited(
        bangumi
            .markEpisodeWatched(subjectId: subjectId, watched: ordinal)
            .catchError((Object error, StackTrace stackTrace) {
              Log.w('History', '更新 Bangumi 集数失败: $error');
            }),
      );
    }
  }

  static String _watchedKey(String videoId, int episodeIndex) =>
      '${videoId}_${episodeIndex}_watched';

  /// 任何一条线路上进度最远的那条记录。
  static bool isEpisodeWatched(String videoId, int episodeIndex) {
    if (Hive.isBoxOpen(AppStorage.videoProgressBoxName)) {
      final raw = AppStorage.videoProgressBox.get(
        _watchedKey(videoId, episodeIndex),
      );
      final flag = raw is Map ? raw['watched'] : null;
      if (flag is bool) return flag;
    }
    final progress = _furthestProgress(videoId, episodeIndex);
    final position = toInt(progress?['positionMs']) ?? 0;
    if (position <= 0) return false;
    final duration = toInt(progress?['durationMs']) ?? 0;
    if (duration <= 0) return position >= 30000;
    return position / duration >= _completionThreshold;
  }

  /// 追番列表用：这部番在本地算作看过的集数。
  /// 标记记录里直接带 bgmId；旧记录没有，退回用观看历史里的源 id 对上。
  /// 同一集的多条线路记录按集下标去重。
  static int watchedCountForBgm(int bgmId) {
    if (bgmId <= 0 || !Hive.isBoxOpen(AppStorage.videoProgressBoxName)) {
      return 0;
    }
    final videoIds = _videoIdsForBgm(bgmId);
    final box = AppStorage.videoProgressBox;
    final indexes = <int>{};
    final skipped = <int>{};
    for (final key in box.keys) {
      if (key is! String) continue;
      final parts = key.split('_');
      if (parts.length < 3) continue;
      final index = int.tryParse(parts[parts.length - 2]);
      if (index == null) continue;
      if (indexes.contains(index) || skipped.contains(index)) continue;
      final videoId = parts.sublist(0, parts.length - 2).join('_');
      final item = box.get(key);
      final ownBgm = item is Map ? toInt(item['bgmId']) : null;
      if (ownBgm != bgmId && !videoIds.contains(videoId)) continue;
      final flag = item is Map ? item['watched'] : null;
      if (flag == false) {
        skipped.add(index);
        continue;
      }
      if (flag == true || isEpisodeWatched(videoId, index)) indexes.add(index);
    }
    return indexes.length;
  }

  /// 观看历史里记着每条记录的源 id 与 Bangumi 编号，用它把两者对上。
  static Set<String> _videoIdsForBgm(int bgmId) {
    if (!Hive.isBoxOpen(AppStorage.playHistoryBoxName)) return const {};
    final raw = AppStorage.playHistoryBox.get(_resumeKey);
    if (raw is! List) return const {};
    final ids = <String>{};
    for (final item in raw) {
      if (item is! Map) continue;
      if (toInt(item['bgmId']) != bgmId) continue;
      final id = item['id'];
      if (id != null) ids.add('$id');
    }
    return ids;
  }

  static Map? _furthestProgress(String videoId, int episodeIndex) {
    if (!Hive.isBoxOpen(AppStorage.videoProgressBoxName)) return null;
    final box = AppStorage.videoProgressBox;
    final prefix = '${videoId}_${episodeIndex}_';
    Map? best;
    var bestPosition = -1;
    for (final key in box.keys) {
      if (key is! String || !key.startsWith(prefix)) continue;
      final item = box.get(key);
      if (item is! Map) continue;
      final position = toInt(item['positionMs']) ?? 0;
      if (position > bestPosition) {
        bestPosition = position;
        best = item;
      }
    }
    return best;
  }

  Future<void> setEpisodeWatched(
    String videoId,
    int episodeIndex,
    bool watched, {
    int? bgmId,
  }) async {
    if (!Hive.isBoxOpen(AppStorage.videoProgressBoxName)) return;
    await AppStorage.videoProgressBox.put(_watchedKey(videoId, episodeIndex), {
      'watched': watched,
      if (bgmId != null && bgmId > 0) 'bgmId': bgmId,
      'updateTime': DateTime.now().millisecondsSinceEpoch,
    });
    revision.value = revision.value + 1;
  }

  static Map? _readProgress(String key) =>
      Hive.isBoxOpen(AppStorage.videoProgressBoxName)
      ? AppStorage.videoProgressBox.get(key)
      : null;

  static Duration readProgress(String key) =>
      Duration(milliseconds: toInt(_readProgress(key)?['positionMs']) ?? 0);

  /// Use the latest record for this episode, including history from another
  /// matched source or a synced device. A newer rewind must win over old progress.
  Duration getResumePosition({
    required String videoKey,
    required PlaybackRequest request,
    int? bgmId,
  }) {
    final progress = _readProgress(videoKey);
    var position = toInt(progress?['positionMs']) ?? 0;
    var duration = toInt(progress?['durationMs']) ?? 0;
    var updated = toInt(progress?['updateTime']) ?? 0;
    if (request.source != '_local') {
      for (final record in getHistoryList()) {
        if (toInt(record['index']) != request.episodeIndex ||
            !_sameAnime(request.metadata, record, bgmId: bgmId)) {
          continue;
        }
        final time = toInt(record['watchTime']) ?? 0;
        if (progress == null || time > updated) {
          position = toInt(record['position']) ?? 0;
          duration = toInt(record['duration']) ?? 0;
          updated = time;
        }
        break;
      }
    }
    if (position <= 0 || (duration > 0 && position >= duration)) {
      return Duration.zero;
    }
    return Duration(milliseconds: position);
  }

  Future<void> saveProgress(
    String key,
    Duration position, {
    Duration? duration,
  }) => AppStorage.videoProgressBox.put(key, {
    'positionMs': position.inMilliseconds,
    if (duration != null) 'durationMs': duration.inMilliseconds,
    'updateTime': DateTime.now().millisecondsSinceEpoch,
  });

  Future<void> clearHistory() async {
    await Future.wait([
      _write(_historyKey, const []),
      _write(_resumeKey, const []),
    ]);
  }
}
