import 'package:baka/api/anime_schedule.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/models/anime_schedule.dart';
import 'package:baka/utils/json_values.dart';

class ScheduleService {
  final _labels = <int, Future<Map<String, String>>>{};
  bool _refresh = false;

  Future<ScheduleWeek> loadWeek(DateTime monday, {bool force = false}) async {
    _labels.clear();
    _refresh = force;
    final (timetable, calendar) = await (
      getAnimeSchedule(monday),
      getBgmCalendar(force: force),
    ).wait;
    return ScheduleWeek.merge(
      monday: monday,
      calendar: calendar,
      timetable: timetable,
    );
  }

  /// 只保留本周章节文案；章节原始数据、分页和并发请求由 BGM API 共用。
  Future<Map<String, String>> loadEpisodeLabels(ScheduleEntry entry) {
    final id = entry.bgmId;
    if (id == null) return Future.value(const {});
    return _labels.putIfAbsent(id, () async {
      final monday = entry.date.subtract(
        Duration(days: entry.date.weekday - 1),
      );
      final start = scheduleDate(monday);
      // 日本深夜放送的章节日期可能落在下周一。
      final end = scheduleDate(monday.add(const Duration(days: 7)));
      final episodes = await getBgmEpisodes(id, refresh: _refresh);
      final labels = <String, StringBuffer>{};
      for (final episode in episodes) {
        final date = episode['airdate'] as String;
        if (date.compareTo(start) < 0 || date.compareTo(end) > 0) continue;
        final label = labels.putIfAbsent(date, StringBuffer.new);
        if (label.isNotEmpty) label.writeln();
        final sort = episode['sort'] as num;
        if (sort > 0) {
          label.write('第 ${sort == sort.round() ? sort.toInt() : sort} 话 · ');
        }
        label.write(
          trimmed(episode['name_cn']) ?? trimmed(episode['name']) ?? '本集标题待公布',
        );
      }
      return {
        for (final entry in labels.entries) entry.key: entry.value.toString(),
      };
    });
  }
}
