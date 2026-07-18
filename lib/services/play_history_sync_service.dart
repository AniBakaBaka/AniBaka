import 'dart:async';
import 'package:baka/services/app_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:baka/api/play_history.dart';
import 'package:baka/models/play_history.dart';
import 'package:baka/utils/bgm_utils.dart';

/// 播放历史同步服务
///
/// 负责本地播放历史与远程API之间的数据同步
class PlayHistorySyncService {
  static const _historyKey = 'history';
  static const _maxHistoryCount = 50;
  static const _minPositionToSaveMs = 10000; // 最少观看10秒才保存历史
  static const _completionThreshold = 0.95;
  static const _platform = 'app';

  static String _uniqueKey(dynamic id, dynamic bgmId, [dynamic episodeId]) {
    final normalizedBgmId = BgmUtils.toInt(bgmId);
    final normalizedId = BgmUtils.toInt(id) ?? id;
    final normalizedEpisode = BgmUtils.toInt(episodeId);
    final videoPart = normalizedBgmId != null && normalizedBgmId > 0
        ? 'bgm_$normalizedBgmId'
        : 'id_$normalizedId';
    return '$videoPart::ep_${normalizedEpisode ?? 'null'}';
  }

  static int? _remoteEpisodeIndex(int? episodeId) => episodeId == null
      ? null
      : episodeId > 0
      ? episodeId - 1
      : 0;

  static String _localRecordKey(Map<String, dynamic> record) =>
      _uniqueKey(record['id'], record['bgmId'], record['index']);

  static String _remoteRecordKey(PlayHistory record) =>
      _uniqueKey(
        record.videoId,
        record.bgmId,
        _remoteEpisodeIndex(record.episodeId),
      );

  static int _recordTime(Map<String, dynamic> record) =>
      record['watchTime'] as int? ?? 0;

  static Map<String, dynamic> _mergeRemoteRecord(
    Map<String, dynamic> localRecord,
    PlayHistory remoteRecord,
  ) {
    final remoteTime = remoteRecord.updatedAt?.millisecondsSinceEpoch ?? 0;
    if (remoteTime < _recordTime(localRecord)) return localRecord;

    final merged = Map<String, dynamic>.from(localRecord)
      ..addAll(_toLocalHistoryRecord(remoteRecord));
    merged['url'] = localRecord['url'] ?? 1;
    return merged;
  }

  static PlayHistory? _toRemoteHistoryRecord(
    Map<String, dynamic> localHistory,
  ) {
    final positionSeconds = ((localHistory['position'] ?? 0) / 1000).round();
    final durationSeconds = ((localHistory['duration'] ?? 0) / 1000).round();
    final coverUrl = BgmUtils.resolveCoverImage(localHistory) ?? '';
    final rawBgmId = localHistory['bgmId'] is int
        ? localHistory['bgmId'] as int
        : int.tryParse(localHistory['bgmId']?.toString() ?? '');
    final bgmId = rawBgmId != null && rawBgmId > 0 ? rawBgmId : null;

    final rawId = (localHistory['id'] is int)
        ? localHistory['id'] as int
        : int.tryParse(localHistory['id']?.toString() ?? '');
    final videoId = bgmId != null && bgmId > 0 ? bgmId : rawId;
    final episodeIndex = BgmUtils.toInt(localHistory['index']);

    if (videoId == null) return null;

    return PlayHistory(
      videoId: videoId,
      videoTitle: localHistory['title']?.toString() ?? '未知标题',
      videoCover: coverUrl.isNotEmpty ? coverUrl : null,
      videoDuration: durationSeconds,
      playProgress: positionSeconds,
      episodeId: episodeIndex != null ? episodeIndex + 1 : null,
      episodeTitle: episodeIndex != null
          ? '第${episodeIndex + 1}集'
          : null,
      videoType: 2,
      platform: _platform,
      bgmId: bgmId,
    );
  }

  static Map<String, dynamic> _toLocalHistoryRecord(PlayHistory remoteHistory) {
    return {
      'id': remoteHistory.videoId.toString(),
      'title': remoteHistory.videoTitle,
      'content': remoteHistory.videoCover ?? '',
      'index': _remoteEpisodeIndex(remoteHistory.episodeId),
      'position': remoteHistory.playProgress * 1000,
      'duration': remoteHistory.videoDuration * 1000,
      'watchTime':
          remoteHistory.updatedAt?.millisecondsSinceEpoch ??
          DateTime.now().millisecondsSinceEpoch,
      'url': 1,
      if (remoteHistory.bgmId != null && remoteHistory.bgmId! > 0)
        'bgmId': remoteHistory.bgmId,
    };
  }

  /// 获取历史记录列表
  static List<Map<String, dynamic>> getHistoryList() {
    final stored = AppStorage.playHistoryBox.get(_historyKey);
    if (stored is! List) return <Map<String, dynamic>>[];
    return stored
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  /// 从远程服务器拉取历史记录并合并到本地
  static Future<void> syncRemoteToLocal() async {
    try {
      final response = await PlayHistoryApi.getPlayHistoryList(
        pageSize: _maxHistoryCount,
      );
      if (response == null || response.list.isEmpty) return;

      final localList = getHistoryList();
      final map = <String, Map<String, dynamic>>{};
      for (final item in localList) {
        map[_localRecordKey(item)] = item;
      }

      for (final remote in response.list) {
        final key = _remoteRecordKey(remote);
        final local = map[key];
        map[key] = local == null
            ? _toLocalHistoryRecord(remote)
            : _mergeRemoteRecord(local, remote);
      }

      final mergedList = map.values.toList();
      mergedList.sort((a, b) => _recordTime(b).compareTo(_recordTime(a)));
      await AppStorage.playHistoryBox.put(
        _historyKey,
        mergedList.take(_maxHistoryCount).toList(),
      );
    } catch (e) {
      debugPrint('同步远程历史失败: $e');
    }
  }

  static Future<bool> _uploadHistoryRecord(
    Map<String, dynamic> localRecord,
  ) async {
    final remoteHistory = _toRemoteHistoryRecord(localRecord);
    if (remoteHistory == null) return false;
    return (await PlayHistoryApi.addOrUpdatePlayHistory(remoteHistory)) != null;
  }

  /// 保存观看记录（同时保存到本地和远程服务器）
  static Future<void> saveHistory({
    required Map<String, dynamic> videoData,
    required int episodeIndex,
    required int positionMs,
    required int durationMs,
    required int urlIndex,
  }) async {
    try {
      if (durationMs <= 0 || positionMs <= _minPositionToSaveMs) return;

      final historyRecord = <String, dynamic>{
        ...videoData,
        'index': episodeIndex,
        'position': positionMs,
        'duration': durationMs,
        'watchTime': DateTime.now().millisecondsSinceEpoch,
        'url': urlIndex,
        'isFinished': positionMs / durationMs >= _completionThreshold,
      };

      final list = getHistoryList();
      final key = _localRecordKey(historyRecord);

      list.removeWhere((item) => _localRecordKey(item) == key);
      list.insert(0, historyRecord);
      if (list.length > _maxHistoryCount) {
        list.removeRange(_maxHistoryCount, list.length);
      }

      await AppStorage.playHistoryBox.put(_historyKey, list);
      unawaited(_uploadHistoryRecord(historyRecord));
    } catch (e) {
      debugPrint('保存历史记录错误: $e');
    }
  }

  /// 清除所有历史记录
  static Future<void> clearHistory() async {
    await AppStorage.playHistoryBox.put(_historyKey, []);
  }

  /// 删除指定历史记录（支持 videoId 或 bgmId）
  static Future<void> removeHistory(String videoId, {int? bgmId}) async {
    final targetPrefix = bgmId != null && bgmId > 0
        ? 'bgm_$bgmId::'
        : 'id_$videoId::';
    final list = getHistoryList();
    list.removeWhere((item) => _localRecordKey(item).startsWith(targetPrefix));
    await AppStorage.playHistoryBox.put(_historyKey, list);
  }
}
