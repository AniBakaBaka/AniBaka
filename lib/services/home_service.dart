import 'package:flutter/foundation.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/api/post.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/utils/bgm_utils.dart';

/// 首页的数据与请求状态。各板块独立通知 UI，网络结果缓存 24 小时。
class HomeDataService {
  static const List<int> rankDays = [1000, 90, 30, 2];

  /// 首页各板块网络结果缓存 24 小时。
  static final TtlCache _homeCache = TtlCache(
    AppStorage.homeCacheBox,
    ttl: const Duration(hours: 24),
  );

  static const String recommendTag = '推荐';
  static const String latestTag = '最新';
  static const String pureTag = '纯净';
  static const List<String> baseTags = [recommendTag, latestTag, pureTag];

  static const String _swiperTag = '幻灯';
  static const String _swiperCacheKey = 'home_swiper_backdrop_v1';
  static final Map<String, Future<dynamic>> _requests = {};

  final _feed = _FeedNotifier();
  final ValueNotifier<List<dynamic>> swipers = ValueNotifier(const []);
  final ValueNotifier<List<List<dynamic>>> schedule = ValueNotifier(
    _emptyGroups(7),
  );
  final ValueNotifier<List<List<dynamic>>> ranks = ValueNotifier(
    _emptyGroups(rankDays.length),
  );
  final ValueNotifier<int> week = ValueNotifier(DateTime.now().weekday - 1);
  final ValueNotifier<int> rankIndex = ValueNotifier(0);
  final ValueNotifier<String> tag = ValueNotifier(recommendTag);

  int _nextPage = 2;
  int _feedRequest = 0;
  bool _loadingFeed = false;
  Future<void>? _firstPageTask;

  ValueNotifier<List<dynamic>> get feed => _feed;

  HomeDataService() {
    final cachedFeed = _readCache(
      'home_feed_$recommendTag',
      allowExpired: true,
    );
    final cachedSwipers = _readCache(_swiperCacheKey, allowExpired: true);
    final cachedRank = _readCache('home_rank_bgm_0', allowExpired: true);
    final cachedSchedule = _readCache('home_xinfan_bgm_v2', allowExpired: true);

    if (cachedFeed is List) {
      _feed.value = List<dynamic>.of(cachedFeed);
    }
    if (cachedSwipers is List) swipers.value = List<dynamic>.of(cachedSwipers);
    if (cachedRank is List) {
      ranks.value = [
        List<dynamic>.of(cachedRank),
        ..._emptyGroups(rankDays.length - 1),
      ];
    }
    if (cachedSchedule is List && cachedSchedule.length == 7) {
      schedule.value = cachedSchedule
          .map<List<dynamic>>(_listOf)
          .toList(growable: false);
    }
  }

  static List<List<dynamic>> _emptyGroups(int count) =>
      List.generate(count, (_) => <dynamic>[]);

  List<String> get displayTags =>
      baseTags.contains(tag.value) ? baseTags : [...baseTags, tag.value];

  void dispose() {
    _feed.dispose();
    swipers.dispose();
    schedule.dispose();
    ranks.dispose();
    week.dispose();
    rankIndex.dispose();
    tag.dispose();
  }

  Future<void> loadFeed({bool force = false}) {
    final task = _loadFirstPage(force: force);
    _firstPageTask = task;
    return task.whenComplete(() {
      if (identical(_firstPageTask, task)) _firstPageTask = null;
    });
  }

  Future<void> _loadFirstPage({required bool force}) async {
    final request = ++_feedRequest;
    final selectedTag = tag.value;
    _loadingFeed = true;

    try {
      final items = await _fetchFeed(selectedTag, 1, force: force);
      if (request != _feedRequest) return;
      _feed.value = List<dynamic>.of(items);
      _nextPage = 2;
    } catch (error) {
      debugPrint('home feed: $error');
    } finally {
      if (request == _feedRequest) _loadingFeed = false;
    }
  }

  Future<bool> loadMore() async {
    // 冷启动时用户可能在首屏请求结束前就已经滑到底。
    // 等首屏完成后继续加载下一页，不能把这次滑动直接丢掉。
    var task = _firstPageTask;
    while (task != null) {
      await task;
      if (identical(_firstPageTask, task)) _firstPageTask = null;
      task = _firstPageTask;
    }
    if (_loadingFeed) return true;

    final request = _feedRequest;
    final page = _nextPage;
    final selectedTag = tag.value;
    _loadingFeed = true;

    try {
      final items = await _fetchFeed(selectedTag, page);
      if (request != _feedRequest) return true;
      if (items.isEmpty) return false;

      // 分页只追加新项，复用首屏创建的可增长列表，避免每页复制历史数据。
      _feed.appendAll(items);
      _nextPage = page + 1;
      return true;
    } catch (error) {
      debugPrint('home feed page $page: $error');
      return false;
    } finally {
      if (request == _feedRequest) _loadingFeed = false;
    }
  }

  Future<void> selectTag(String value) async {
    if (tag.value == value) return;
    tag.value = value;
    await loadFeed();
  }

  Future<List<dynamic>> _fetchFeed(
    String selectedTag,
    int page, {
    bool force = false,
  }) async {
    const pageSize = 21;

    Future<List<dynamic>> fetch() async {
      final offset = (page - 1) * pageSize;
      switch (selectedTag) {
        case pureTag:
          return _responseItems(
            (await getPost('', recommendTag, page, 50)).data,
          );
        case recommendTag:
          final response = await getTrendingSubjects(
            type: 2,
            limit: pageSize,
            offset: offset,
          );
          return BgmService.convertTrendingToAppFormat(
            _responseItems(response.data),
          );
        case latestTag:
          final response = await searchBgmByTag(
            const [],
            limit: pageSize,
            offset: offset,
            sort: 'heat',
            airDate: ['>=${DateTime.now().year}-01-01'],
          );
          return BgmService.convertSearchResponseToAppFormat(response.data);
        default:
          final (tags, airDate) = _parseTag(selectedTag);
          final response = await searchBgmByTag(
            tags,
            limit: pageSize,
            offset: offset,
            sort: 'rank',
            airDate: airDate,
          );
          return BgmService.convertSearchResponseToAppFormat(response.data);
      }
    }

    if (page > 1 || selectedTag == pureTag) return fetch();
    final cacheKey = selectedTag == recommendTag
        ? 'home_feed_$selectedTag'
        : 'home_feed_filter_v2_$selectedTag';
    return _listOf(await _cached(cacheKey, fetch, force: force));
  }

  /// 年份和年代从标签中转为 Bangumi 的放送日期范围。
  static (List<String>, List<String>?) _parseTag(String raw) {
    final tags = <String>[];
    List<String>? airDate;

    for (final part in raw.split(',')) {
      final value = part.trim();
      if (value.isEmpty) continue;

      final year = value.length == 4 ? int.tryParse(value) : null;
      if (year != null) {
        airDate = ['>=$year-01-01', '<${year + 1}-01-01'];
        continue;
      }

      if (value.endsWith('年代')) {
        final text = value.substring(0, value.length - 2);
        final parsed = int.tryParse(text);
        final decade = text.length == 2 && parsed != null
            ? 1900 + parsed
            : text.length == 4
            ? parsed
            : null;
        if (decade != null) {
          airDate = ['>=$decade-01-01', '<${decade + 10}-01-01'];
          continue;
        }
      }

      tags.add(value);
    }
    return (tags, airDate);
  }

  Future<void> loadSwipers({bool force = false}) async {
    try {
      swipers.value = _listOf(
        await _cached(_swiperCacheKey, _fetchSwipers, force: force),
      );
    } catch (error) {
      debugPrint('home swipers: $error');
    }
  }

  static Future<List<dynamic>> _fetchSwipers() async {
    final items = _responseItems((await getPost('', _swiperTag, 1, 6)).data);

    await Future.wait(
      items.whereType<Map>().map((item) async {
        var bgmId = BgmUtils.toInt(item['bgmId']);
        if (bgmId == null) {
          final subject = await BgmService.resolveSubject(
            title: item['title']?.toString() ?? '',
          );
          bgmId = subject?.subjectId;
          if (bgmId != null) item['bgmId'] = bgmId;
        }
        if (bgmId == null) return;

        final detail = await getAnimeDetail(bgmId);
        final url = BgmUtils.pickAniBakaTmdbBackdrop(detail);
        if (url != null) item['backdropUrl'] = url;
      }),
    );
    return items;
  }

  Future<void> loadRank({bool force = false}) async {
    final index = rankIndex.value;
    try {
      final items = _listOf(
        await _cached(
          'home_rank_bgm_$index',
          () async {
            final response = await searchBgmByTag(
              const [],
              limit: 21,
              sort: 'rank',
              airDate: _rankAirDateFilter(rankDays[index]),
            );
            return BgmService.convertSearchResponseToAppFormat(response.data);
          },
          force: force,
        ),
      );
      final updated = List<List<dynamic>>.of(ranks.value);
      updated[index] = items;
      ranks.value = updated;
    } catch (error) {
      debugPrint('home rank $index: $error');
    }
  }

  /// 排行榜各档期对应的 BGM 放送日期下限；总榜不限日期。
  static List<String>? _rankAirDateFilter(int days) {
    if (days >= 1000) return null;
    final start = DateTime.now().subtract(Duration(days: days));
    final month = start.month.toString().padLeft(2, '0');
    final day = start.day.toString().padLeft(2, '0');
    return ['>=${start.year}-$month-$day'];
  }

  Future<void> selectRank(int index) async {
    if (rankIndex.value == index) return;
    rankIndex.value = index;
    if (ranks.value[index].isEmpty) await loadRank();
  }

  Future<void> loadSchedule({bool force = false}) async {
    try {
      schedule.value = await loadSharedXinfan(force: force);
    } catch (error) {
      debugPrint('home schedule: $error');
    }
  }

  /// 新番更新表与更新时间表页面共用同一份缓存。
  /// 数据源为 BGM 每日放送（p1/calendar），key 1=周一 … 7=周日。
  static Future<List<List<dynamic>>> loadSharedXinfan({
    bool force = false,
  }) async {
    final raw = await _cached('home_xinfan_bgm_v2', () async {
      final groups = _emptyGroups(7);
      final days = BgmUtils.parseJsonMap(
        (await getBgmCalendar()).data,
      );
      if (days == null) return groups;

      days.forEach((key, value) {
        final day = int.tryParse(key);
        if (day == null || day < 1 || day > 7 || value is! List) return;
        groups[day - 1] = BgmService.convertTrendingToAppFormat(value);
      });
      return groups;
    }, force: force);

    if (raw is! List || raw.length != 7) return _emptyGroups(7);
    return raw.map<List<dynamic>>(_listOf).toList(growable: false);
  }

  /// 读取缓存，并合并同一 key 的并发网络请求。
  static Future<dynamic> _cached(
    String key,
    Future<dynamic> Function() loader, {
    bool force = false,
  }) {
    if (!force) {
      final cached = _readCache(key);
      if (cached != null) return Future.value(cached);
    }

    return _requests[key] ??= loader()
        .then((data) {
          _homeCache.write(key, data);
          return data;
        })
        .whenComplete(() {
          // 块回调返回 void；表达式回调会返回刚移除的同一个 Future，
          // 使 whenComplete 等待自身，首次请求因此永远无法发布到 UI。
          _requests.remove(key);
        });
  }

  static dynamic _readCache(String key, {bool allowExpired = false}) =>
      _homeCache.read(key, allowExpired: allowExpired);

  static List<dynamic> _listOf(dynamic value) =>
      value is List ? value : <dynamic>[];

  static List<dynamic> _responseItems(dynamic response) =>
      _listOf(BgmUtils.parseJsonMap(response)?['data']);
}

class _FeedNotifier extends ValueNotifier<List<dynamic>> {
  _FeedNotifier() : super(<dynamic>[]);

  void appendAll(List<dynamic> items) {
    value.addAll(items);
    notifyListeners();
  }
}
