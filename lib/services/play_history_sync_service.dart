import 'dart:async';

import 'package:baka/api/play_history.dart';
import 'package:baka/models/play_history.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// 播放历史同步服务
///
/// 负责本地播放历史与远程API之间的数据同步
class PlayHistorySyncService {
  static const _historyKey = 'history';
  static const _resumeKey = 'resume';
  static const _maxHistoryCount = 50;
  static const _minPositionToSaveMs = 10000;
  static const _completionThreshold = 0.95;
  static const _platform = 'app';

  /// Fields needed to resume playback and render history cards.
  static const _snapshotKeys = <String>{
    'id',
    'title',
    'content',
    'image',
    'bgmImageUrl',
    'bgmId',
    'source',
    'seriesUrl',
    'sourceUrl',
    'sourceDisplayName',
    'tag',
    'score',
    'info',
  };

  static String _uniqueKey(dynamic id, dynamic bgmId, [dynamic episodeId]) {
    final bgm = BgmUtils.toInt(bgmId);
    final ep = BgmUtils.toInt(episodeId);
    final video = (bgm != null && bgm > 0)
        ? 'bgm_$bgm'
        : 'id_${BgmUtils.toInt(id) ?? id}';
    return '$video::ep_${ep ?? 'null'}';
  }

  static String _localKey(Map record) =>
      _uniqueKey(record['id'], record['bgmId'], record['index']);

  static String _remoteKey(PlayHistory r) {
    final ep = r.episodeId;
    return _uniqueKey(
      r.videoId,
      r.bgmId,
      ep == null
          ? null
          : ep > 0
          ? ep - 1
          : 0,
    );
  }

  static int _watchTime(Map record) => record['watchTime'] as int? ?? 0;

  static List<Map<String, dynamic>> _readList(String key) {
    if (!Hive.isBoxOpen(AppStorage.playHistoryBoxName)) {
      return <Map<String, dynamic>>[];
    }
    final stored = AppStorage.playHistoryBox.get(key);
    if (stored is! List) return <Map<String, dynamic>>[];
    final result = <Map<String, dynamic>>[];
    for (final item in stored) {
      if (item is Map) result.add(Map<String, dynamic>.from(item));
    }
    return result;
  }

  static bool _sameAnime(Map left, Map right) {
    final leftBgmId = BgmUtils.toInt(left['bgmId']);
    final rightBgmId = BgmUtils.toInt(right['bgmId']);
    if (leftBgmId != null &&
        leftBgmId > 0 &&
        rightBgmId != null &&
        rightBgmId > 0) {
      return leftBgmId == rightBgmId;
    }

    final leftTitle = BgmUtils.normalizeTitle(left['title']?.toString() ?? '');
    final rightTitle = BgmUtils.normalizeTitle(
      right['title']?.toString() ?? '',
    );
    if (leftTitle.isNotEmpty &&
        rightTitle.isNotEmpty &&
        leftTitle == rightTitle) {
      return true;
    }

    final leftId = left['id']?.toString();
    final rightId = right['id']?.toString();
    if (leftId == null || leftId.isEmpty || leftId != rightId) return false;
    final leftSource = left['source']?.toString() ?? '';
    final rightSource = right['source']?.toString() ?? '';
    return leftSource.isEmpty ||
        rightSource.isEmpty ||
        leftSource == rightSource;
  }

  static Map<String, dynamic> _snapshot(Map videoData) {
    final out = <String, dynamic>{};
    for (final key in _snapshotKeys) {
      final value = videoData[key];
      if (value != null) out[key] = value;
    }
    return out;
  }

  static Map<String, dynamic> _fromRemote(PlayHistory r) {
    final bgmId = r.bgmId;
    final ep = r.episodeId;
    return {
      'id': r.videoId.toString(),
      'title': r.videoTitle,
      'content': r.videoCover ?? '',
      'index': ep == null
          ? null
          : ep > 0
          ? ep - 1
          : 0,
      'position': r.playProgress * 1000,
      'duration': r.videoDuration * 1000,
      'watchTime':
          r.updatedAt?.millisecondsSinceEpoch ??
          DateTime.now().millisecondsSinceEpoch,
      'url': 1,
      if (bgmId != null && bgmId > 0) 'bgmId': bgmId,
    };
  }

  static PlayHistory? _toRemote(Map local) {
    final bgmId = BgmUtils.toInt(local['bgmId']);
    final validBgm = (bgmId != null && bgmId > 0) ? bgmId : null;
    final videoId = validBgm ?? BgmUtils.toInt(local['id']);
    if (videoId == null) return null;

    final episodeIndex = BgmUtils.toInt(local['index']);
    final cover = BgmUtils.resolveCoverImage(local);
    final position = local['position'];
    final duration = local['duration'];

    return PlayHistory(
      videoId: videoId,
      videoTitle: local['title']?.toString() ?? '未知标题',
      videoCover: (cover == null || cover.isEmpty) ? null : cover,
      videoDuration: ((duration is num ? duration : 0) / 1000).round(),
      playProgress: ((position is num ? position : 0) / 1000).round(),
      episodeId: episodeIndex != null ? episodeIndex + 1 : null,
      episodeTitle: episodeIndex != null ? '第${episodeIndex + 1}集' : null,
      videoType: 2,
      platform: _platform,
      bgmId: validBgm,
    );
  }

  static Map<String, Map<String, dynamic>> _indexByKey(
    List<Map<String, dynamic>> list,
  ) {
    final map = <String, Map<String, dynamic>>{};
    for (final item in list) {
      map.putIfAbsent(_localKey(item), () => item);
    }
    return map;
  }

  /// Recency-ordered list capped at [_maxHistoryCount].
  static List<Map<String, dynamic>> _ordered(
    Map<String, Map<String, dynamic>> map,
  ) {
    final list = map.values.toList(growable: false);
    list.sort((a, b) => _watchTime(b).compareTo(_watchTime(a)));
    if (list.length <= _maxHistoryCount) return list;
    return list.sublist(0, _maxHistoryCount);
  }

  static Future<void> _persist(List<Map<String, dynamic>> list) =>
      AppStorage.playHistoryBox.put(_historyKey, list);

  /// 获取历史记录列表
  static List<Map<String, dynamic>> getHistoryList() {
    return _readList(_historyKey);
  }

  /// Returns the most recently opened episode for this anime.
  ///
  /// Older installs transparently fall back to their latest history entry.
  static ({int episodeIndex, int lineIndex})? getResumeSelection(
    Map videoData,
  ) {
    for (final records in [_readList(_resumeKey), getHistoryList()]) {
      for (final record in records) {
        if (!_sameAnime(videoData, record)) continue;
        final episodeIndex = BgmUtils.toInt(record['index']);
        if (episodeIndex == null || episodeIndex < 0) continue;
        final source = videoData['source']?.toString() ?? '';
        final rememberedSource = record['source']?.toString() ?? '';
        final sameSource =
            source.isEmpty ||
            rememberedSource.isEmpty ||
            source == rememberedSource;
        final lineIndex = sameSource ? BgmUtils.toInt(record['url']) ?? 1 : 1;
        return (
          episodeIndex: episodeIndex,
          lineIndex: lineIndex > 0 ? lineIndex : 1,
        );
      }
    }
    return null;
  }

  /// Remembers episode selection immediately after playback opens.
  static Future<void> rememberEpisode({
    required Map videoData,
    required int episodeIndex,
    required int urlIndex,
  }) async {
    if (episodeIndex < 0 || !Hive.isBoxOpen(AppStorage.playHistoryBoxName)) {
      return;
    }
    final record = _snapshot(videoData)
      ..['index'] = episodeIndex
      ..['url'] = urlIndex > 0 ? urlIndex : 1
      ..['watchTime'] = DateTime.now().millisecondsSinceEpoch;

    final next = <Map<String, dynamic>>[record];
    for (final item in _readList(_resumeKey)) {
      if (_sameAnime(record, item)) continue;
      next.add(item);
      if (next.length >= _maxHistoryCount) break;
    }
    await AppStorage.playHistoryBox.put(_resumeKey, next);
  }

  /// 从远程服务器拉取历史记录并合并到本地
  static Future<void> syncRemoteToLocal() async {
    try {
      final response = await PlayHistoryApi.getPlayHistoryList(
        pageSize: _maxHistoryCount,
      );
      if (response == null || response.list.isEmpty) return;

      final map = _indexByKey(getHistoryList());
      for (final remote in response.list) {
        final key = _remoteKey(remote);
        final local = map[key];
        final remoteTime = remote.updatedAt?.millisecondsSinceEpoch ?? 0;
        if (local == null || remoteTime >= _watchTime(local)) {
          final next = _fromRemote(remote);
          // Preserve local line selection when remote has no line info.
          if (local != null) next['url'] = local['url'] ?? 1;
          map[key] = next;
        }
      }
      await _persist(_ordered(map));
    } catch (e) {
      debugPrint('同步远程历史失败: $e');
    }
  }

  /// 保存观看记录（同时保存到本地和远程服务器）
  static Future<void> saveHistory({
    required Map videoData,
    required int episodeIndex,
    required int positionMs,
    required int durationMs,
    required int urlIndex,
  }) async {
    try {
      if (durationMs <= 0 || positionMs <= _minPositionToSaveMs) return;

      final record = _snapshot(videoData)
        ..['index'] = episodeIndex
        ..['position'] = positionMs
        ..['duration'] = durationMs
        ..['watchTime'] = DateTime.now().millisecondsSinceEpoch
        ..['url'] = urlIndex
        ..['isFinished'] = positionMs / durationMs >= _completionThreshold;

      // Single O(n) pass: new record first, drop same-key duplicates, cap size.
      final key = _localKey(record);
      final next = <Map<String, dynamic>>[record];
      for (final item in getHistoryList()) {
        if (_localKey(item) == key) continue;
        next.add(item);
        if (next.length >= _maxHistoryCount) break;
      }
      await _persist(next);

      final remote = _toRemote(record);
      if (remote != null) {
        unawaited(PlayHistoryApi.addOrUpdatePlayHistory(remote));
      }
    } catch (e) {
      debugPrint('保存历史记录错误: $e');
    }
  }

  /// 清除所有历史记录
  static Future<void> clearHistory() async {
    await Future.wait([
      _persist(const []),
      AppStorage.playHistoryBox.put(_resumeKey, const []),
    ]);
  }

}
