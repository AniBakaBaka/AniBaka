/// Calendar dates are UTC values used as civil dates, always displayed in UTC+8.
DateTime scheduleToday(DateTime now) {
  final local = now.toUtc().add(const Duration(hours: 8));
  return DateTime.utc(local.year, local.month, local.day);
}

String scheduleDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class SchedulePlatform {
  const SchedulePlatform({
    required this.name,
    required this.time,
    this.url,
    this.regions = const [],
  });
  final String name;
  final String time;
  final Uri? url;
  final List<String> regions;
}

class ScheduleEntry {
  const ScheduleEntry({
    required this.key,
    required this.date,
    required this.post,
    this.time,
    this.episodeDate,
    this.platforms = const [],
    this.premiereOnly = false,
  });
  final String key;
  final DateTime date;
  final String? time;
  final String? episodeDate;
  final Map post;
  final List<SchedulePlatform> platforms;
  final bool premiereOnly;
  int? get bgmId => post['bgmId'] as int?;
  String get title => post['title'] as String;
}

class ScheduleWeek {
  const ScheduleWeek({
    required this.days,
    required this.stale,
    required this.checkedAt,
  });
  final List<List<ScheduleEntry>> days;
  final bool stale;
  final DateTime checkedAt;

  factory ScheduleWeek.merge({
    required DateTime monday,
    required List<List<Map>> calendar,
    required Map<String, dynamic> timetable,
  }) {
    final dates = List.generate(7, (day) => monday.add(Duration(days: day)));
    final dateKeys = List.generate(
      8,
      (day) => scheduleDate(monday.add(Duration(days: day))),
    );
    final days = List.generate(7, (_) => <ScheduleEntry>[]);
    final posts = <int, Map>{
      for (final day in calendar)
        for (final post in day) post['bgmId'] as int: post,
    };
    final records = <String, ({Map post, int? sourceOffset})>{};
    final sites = <(String, String, String), Map>{};
    final scheduledIds = <int>{};
    for (final record in (timetable['items'] as List).cast<Map>()) {
      final key = record['key'] as String;
      final item = record['item'] as Map;
      final id = record['bgm_id'] as int?;
      Map createPost() => <String, dynamic>{
        'title': record['name_cn'] as String,
        'source': 'bgm',
        'bgmId': id,
      };
      records[key] = (
        post: id == null ? createPost() : posts.putIfAbsent(id, createPost),
        sourceOffset: switch (item['lang']) {
          'ja' => 9,
          'zh-Hans' || 'zh-Hant' => 8,
          _ => null,
        },
      );
      if (id != null &&
          (record['rules'] as List).first['timing'] == 'broadcast') {
        scheduledIds.add(id);
      }
      for (final site in (item['sites'] as List).cast<Map>()) {
        sites[(key, site['site'] as String, site['id'] as String)] = site;
      }
    }

    final events = (timetable['events'] as List).cast<Map>();
    final platformEvents = <(String, String), List<Map>>{};
    for (final event in events) {
      if (event['kind'] == 'platform') {
        (platformEvents[(event['key'] as String, event['date'] as String)] ??=
                [])
            .add(event);
      }
    }
    final meta = timetable['site_meta'] as Map;
    // API events are already ordered by timestamp; retain that order directly.
    for (final event in events) {
      if (event['kind'] != 'broadcast') continue;
      if (event['date'] == dateKeys[7]) break;
      final key = event['key'] as String;
      final record = records[key]!;
      final day = (event['weekday'] as int) - 1;
      final at = DateTime.parse(event['at'] as String);
      final id = record.post['bgmId'] as int?;
      if (id != null) scheduledIds.add(id);
      final platforms = <SchedulePlatform>[];
      final seen = <(String, String)>{};
      // Index by record and date instead of scanning a record's entire week.
      for (var delta = 0; delta <= 1; delta++) {
        for (final platform
            in platformEvents[(key, dateKeys[day + delta])] ?? const <Map>[]) {
          if (delta == 1 &&
              DateTime.parse(platform['at'] as String).difference(at) >
                  const Duration(days: 1)) {
            continue;
          }
          final site = platform['site'] as String;
          final siteId = platform['site_id'] as String;
          if (!seen.add((site, siteId))) continue;
          final siteData = sites[(key, site, siteId)]!;
          final url = siteData['url'] as String?;
          platforms.add(
            SchedulePlatform(
              name: (meta[site] as Map)['title'] as String,
              time: '${delta == 1 ? '次日 ' : ''}${platform['time']}',
              url: url == null || url.isEmpty ? null : Uri.parse(url),
              // The API has already applied site metadata defaults.
              regions:
                  (siteData['regions'] as List?)?.cast<String>() ?? const [],
            ),
          );
        }
      }
      days[day].add(
        ScheduleEntry(
          key: '$key/${event['at']}',
          date: dates[day],
          time: event['time'] as String,
          episodeDate: record.sourceOffset == null
              ? null
              : scheduleDate(
                  at.toUtc().add(Duration(hours: record.sourceOffset!)),
                ),
          post: record.post,
          platforms: platforms,
          premiereOnly: event['timing'] == 'premiere_only',
        ),
      );
    }
    for (var day = 0; day < 7; day++) {
      final seen = <int>{};
      for (final post in calendar[day]) {
        final id = post['bgmId'] as int;
        if (scheduledIds.contains(id) || !seen.add(id)) continue;
        days[day].add(
          ScheduleEntry(key: 'unknown/$id/$day', date: dates[day], post: post),
        );
      }
    }
    final source = timetable['source'] as Map;
    return ScheduleWeek(
      days: days,
      stale: source['stale'] as bool,
      checkedAt: DateTime.parse(source['checked_at'] as String),
    );
  }
}
