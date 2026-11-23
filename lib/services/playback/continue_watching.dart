import 'package:baka/models/bgm.dart';
import 'package:baka/utils/json_values.dart';

/// 首页「继续观看」的一条：一部番，加上它最近看的那一集。
/// 历史是每集一条记录，这里按番聚合，只留最近一条。
class ContinueWatchingEntry {
  const ContinueWatchingEntry({
    required this.key,
    required this.record,
    required this.episodeIndex,
    required this.watchedAt,
    required this.progress,
    required this.isFinished,
  });

  /// 聚合用的番剧标识，同 key 只会保留最近的一条记录。
  final String key;

  /// 这条记录本身，续播时交给 `PlaybackRequest.fromHistory`。
  final Map<String, dynamic> record;

  /// 最近观看那一集的源下标（0 起）。
  final int episodeIndex;

  /// 本机时间戳（毫秒）。
  final int watchedAt;

  /// 该集观看进度 0..1。
  final double progress;

  /// 这一集是否已经看完（进度过了完成阈值）。
  final bool isFinished;

  String get title => record['title']?.toString() ?? '';

  String? get cover => resolveCoverImage(record);

  int? get bgmId {
    final id = toInt(record['bgmId']);
    return id != null && id > 0 ? id : null;
  }

  /// 点进去应该从哪一集开始：看完的那一集直接跳到下一集。
  int get targetEpisodeIndex => isFinished ? episodeIndex + 1 : episodeIndex;

  /// 卡片上那一行「继续观看 02」。
  String get episodeLabel {
    final number = (targetEpisodeIndex + 1).toString().padLeft(2, '0');
    return '继续观看 $number';
  }
}

/// 把观看历史聚合成「继续观看」列表，按最近观看倒序。
List<ContinueWatchingEntry> buildContinueWatching(
  Iterable<Map<String, dynamic>> history, {
  int limit = 12,
  int minPositionMs = 10000,
}) {
  final latest = <String, ContinueWatchingEntry>{};
  for (final record in history) {
    final index = toInt(record['index']);
    final duration = toInt(record['duration']) ?? 0;
    final position = toInt(record['position']) ?? 0;
    if (index == null || index < 0 || duration <= 0) continue;
    // 点开没看几秒就退出的记录不该占一张卡。
    if (position < minPositionMs) continue;

    final entry = ContinueWatchingEntry(
      key: _animeKey(record),
      record: record,
      episodeIndex: index,
      watchedAt: toInt(record['watchTime']) ?? 0,
      progress: (position / duration).clamp(0.0, 1.0),
      isFinished: record['isFinished'] == true,
    );
    final existing = latest[entry.key];
    if (existing == null || entry.watchedAt > existing.watchedAt) {
      latest[entry.key] = entry;
    }
  }

  final entries = latest.values.toList()
    ..sort((a, b) => b.watchedAt.compareTo(a.watchedAt));
  return entries.take(limit).toList(growable: false);
}

/// Bangumi 条目优先：同一部番换了源也还是同一张卡。
String _animeKey(Map record) {
  final bgmId = toInt(record['bgmId']);
  if (bgmId != null && bgmId > 0) return 'bgm_$bgmId';
  final id = record['id']?.toString();
  if (id != null && id.isNotEmpty) return 'id_$id';
  return 'title_${record['title']}';
}
