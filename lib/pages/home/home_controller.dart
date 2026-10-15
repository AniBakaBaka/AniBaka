import 'package:baka/models/bgm.dart';
import 'package:baka/models/anime_filter.dart';
import 'package:baka/models/anime_detail_view_data.dart';
import 'package:flutter/foundation.dart';

import 'package:baka/api/bgm.dart';
import 'package:baka/api/anibaka_api.dart';
import 'package:baka/api/post.dart';
import 'package:baka/api/request_cache.dart';
import 'package:baka/core/app_storage.dart';

typedef HomeItem = Map;
typedef HomeItems = List<HomeItem>;

/// 首页的数据与请求状态。各板块独立通知 UI，网络结果缓存 24 小时。
class HomeController {
  static const List<int> rankDays = [1000, 90, 30, 2];

  /// 首页各板块网络结果缓存 24 小时。
  static final TtlCache _homeCache = TtlCache(
    AppStorage.homeCacheBox,
    ttl: const Duration(hours: 24),
  );

  static final _requests = RequestCache<String, Object>(limit: 0);

  final DateTime Function() _now;
  late String _swipersKey;
  int _swipersRequest = 0;
  final _feed = _FeedNotifier();
  final ValueNotifier<HomeItems> swipers = ValueNotifier(const []);
  final ValueNotifier<List<HomeItems>> schedule = ValueNotifier(
    _emptyGroups(7),
  );
  final _HomeGroupsNotifier _ranks = _HomeGroupsNotifier(
    _emptyGroups(rankDays.length),
  );
  final ValueNotifier<int> week = ValueNotifier(DateTime.now().weekday - 1);
  final ValueNotifier<int> rankIndex = ValueNotifier(0);
  final filter = ValueNotifier(AnimeFilter.presets.first);

  int _nextPage = 2;
  int _feedRequest = 0;
  bool _loadingFeed = false;
  Future<void>? _firstPageTask;
  ({AnimeFilter filter, bool force})? _firstPageKey;
  bool _disposed = false;

  ValueNotifier<HomeItems> get feed => _feed;
  ValueNotifier<List<HomeItems>> get ranks => _ranks;

  HomeController({DateTime Function()? now}) : _now = now ?? DateTime.now {
    final cachedFeed = _readCache('home_feed_bgm_v4_推荐', allowExpired: true);
    _swipersKey = _swiperCacheKey(_seasonStart(_now()));
    final cachedSwipers = _readCache(_swipersKey, allowExpired: true);
    final cachedRank = _readCache('home_rank_bgm_v2_0', allowExpired: true);
    final cachedSchedule = _readCache('home_xinfan_bgm_v3', allowExpired: true);

    if (cachedFeed is List) _feed.value = List<Map>.of(cachedFeed.cast<Map>());
    if (cachedSwipers is List) swipers.value = cachedSwipers.cast<Map>();
    if (cachedRank is List) {
      _ranks.value = [
        cachedRank.cast<Map>(),
        ..._emptyGroups(rankDays.length - 1),
      ];
    }
    if (cachedSchedule is List && cachedSchedule.length == 7) {
      schedule.value = List.generate(
        7,
        (index) => (cachedSchedule[index] as List).cast<Map>(),
        growable: false,
      );
    }
  }

  static List<HomeItems> _emptyGroups(int count) =>
      List.generate(count, (_) => <Map>[]);

  Iterable<AnimeFilter> get displayFilters sync* {
    yield* AnimeFilter.presets;
    if (filter.value.feed == null) yield filter.value;
  }

  void dispose() {
    _disposed = true;
    ++_feedRequest;
    ++_swipersRequest;
    _feed.dispose();
    swipers.dispose();
    schedule.dispose();
    _ranks.dispose();
    week.dispose();
    rankIndex.dispose();
    filter.dispose();
  }

  Future<void> loadFeed({bool force = false}) {
    if (_disposed) return Future.value();
    final key = (filter: filter.value, force: force);
    final running = _firstPageTask;
    if (running != null && _firstPageKey == key) return running;

    late final Future<void> task;
    task = _loadFirstPage(selected: key.filter, force: force).whenComplete(() {
      if (identical(_firstPageTask, task)) {
        _firstPageTask = null;
        _firstPageKey = null;
      }
    });
    _firstPageTask = task;
    _firstPageKey = key;
    return task;
  }

  Future<void> _loadFirstPage({
    required AnimeFilter selected,
    required bool force,
  }) async {
    final request = ++_feedRequest;
    _loadingFeed = true;

    try {
      final items = await _fetchFeed(selected, 1, force: force);
      if (request != _feedRequest) return;
      // 缓存及并发请求共享首屏；只在取得可变分页列表时复制一次引用。
      _feed.value = List<Map>.of(items);
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
    if (_disposed) return false;
    if (_loadingFeed) return true;

    final request = _feedRequest;
    final page = _nextPage;
    final selected = filter.value;
    _loadingFeed = true;

    try {
      final items = await _fetchFeed(selected, page);
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

  Future<void> selectFilter(AnimeFilter value) async {
    if (_disposed || filter.value == value) return;
    filter.value = value;
    _nextPage = 1;
    _feed.value = <Map>[];
    await loadFeed();
  }

  Future<HomeItems> _fetchFeed(
    AnimeFilter selected,
    int page, {
    bool force = false,
  }) async {
    const pageSize = 21;

    Future<HomeItems> fetch() async {
      final offset = (page - 1) * pageSize;
      switch (selected.feed) {
        case AnimeFeed.pure:
          return getPost('', '推荐', page, 50);
        case AnimeFeed.recommended:
          final subjects = await getTrendingSubjects(
            type: 2,
            limit: pageSize,
            offset: offset,
          );
          return convertBgmSubjectsToAppFormat(subjects, trending: true);
        case AnimeFeed.latest:
        case null:
          final latest = selected.feed == AnimeFeed.latest;
          final subjects = await searchBgm(
            tags: selected.tags,
            limit: pageSize,
            offset: offset,
            sort: latest ? 'heat' : 'rank',
            airDate: latest
                ? AnimeFilter(year: _now().year).airDate
                : selected.airDate,
          );
          return convertBgmSubjectsToAppFormat(subjects);
      }
    }

    if (page > 1 || selected.feed == AnimeFeed.pure) return fetch();
    final cacheKey = selected.feed == AnimeFeed.recommended
        ? 'home_feed_bgm_v4_推荐'
        : 'home_feed_filter_v4_${selected.feed == AnimeFeed.latest ? _now().year : ''}_${selected.cacheKey}';
    return _itemList(await _cached(cacheKey, fetch, force: force));
  }

  Future<void> loadSwipers({bool force = false}) async {
    final season = _seasonStart(_now());
    final key = _swiperCacheKey(season);
    final request = ++_swipersRequest;
    if (_swipersKey != key) {
      _swipersKey = key;
      swipers.value = const [];
    }
    try {
      final items = _itemList(
        await _cached(key, () => _fetchSwipers(season), force: force),
      );
      if (request != _swipersRequest ||
          key != _swiperCacheKey(_seasonStart(_now()))) {
        return;
      }
      swipers.value = items;
    } catch (error) {
      debugPrint('home swipers: $error');
    }
  }

  static DateTime _seasonStart(DateTime date) =>
      DateTime(date.year, ((date.month - 1) ~/ 3) * 3 + 1);

  static String _swiperCacheKey(DateTime season) =>
      'home_swiper_bgm_season_v1_${season.year}_${season.month}';

  /// 当季首播的 TV / WEB 动画按 Bangumi 收藏热度选取，名单不依赖站内帖子。
  static Future<HomeItems> _fetchSwipers(DateTime season) async {
    final end = DateTime(season.year, season.month + 3);
    final subjects = await searchBgm(
      limit: 24,
      sort: 'heat',
      airDate: [
        '>=${season.toIso8601String().substring(0, 10)}',
        '<${end.toIso8601String().substring(0, 10)}',
      ],
    );
    final candidates = subjects.where((subject) {
      final platform = subject['platform']?.toString().toLowerCase();
      final date = DateTime.tryParse(subject['date']?.toString() ?? '');
      return (platform == 'tv' || platform == 'web') &&
          subject['nsfw'] != true &&
          date != null &&
          !date.isBefore(season) &&
          date.isBefore(end);
    }).toList();
    final seen = <int>{};
    final items = convertBgmSubjectsToAppFormat(candidates)
        .where(
          (item) =>
              resolveCoverImage(item) != null && seen.add(item['bgmId'] as int),
        )
        .take(6)
        .toList();
    // 不把上游空响应缓存一天；同季已有内容可保留，后续刷新还能重试。
    if (items.isEmpty) throw StateError('Bangumi 当季暂无可展示的番剧');

    await Future.wait(
      items.map((item) async {
        final bgmId = item['bgmId'] as int;
        item['bannerImageUrl'] = resolveCoverImage(item)!;
        try {
          // 横图只是增强：补图失败或超时仍使用 Bangumi 封面。
          final detail = await AniBakaApi.getAnimeDetail(
            bgmId,
          ).timeout(const Duration(seconds: 8));
          final url = AnimeDetailViewData.pickTmdbBackdrop(detail);
          if (url != null) {
            item['backdropUrl'] = url;
            item['bannerImageUrl'] = url;
          }
        } catch (error) {
          debugPrint('home swiper backdrop $bgmId: $error');
        }
      }),
    );
    return items;
  }

  Future<void> loadRank({bool force = false}) async {
    final index = rankIndex.value;
    try {
      final items = _itemList(
        await _cached('home_rank_bgm_v2_$index', () async {
          final subjects = await searchBgm(
            limit: 21,
            sort: 'rank',
            airDate: _rankAirDateFilter(rankDays[index]),
          );
          return convertBgmSubjectsToAppFormat(subjects);
        }, force: force),
      );
      _ranks.replaceAt(index, items);
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
  static Future<List<HomeItems>> loadSharedXinfan({bool force = false}) async {
    final raw = await _cached('home_xinfan_bgm_v3', () async {
      final groups = _emptyGroups(7);
      final days = await getBgmCalendar();

      days.forEach((key, value) {
        final day = int.tryParse(key);
        if (day == null || day < 1 || day > 7) return;
        groups[day - 1] = convertBgmSubjectsToAppFormat(value, trending: true);
      });
      return groups;
    }, force: force);

    final groups = raw as List;
    return List.generate(
      7,
      (index) => (groups[index] as List).cast<Map>(),
      growable: false,
    );
  }

  /// 读取缓存，并合并同一 key 的并发网络请求。
  static Future<Object> _cached(
    String key,
    Future<Object> Function() loader, {
    bool force = false,
  }) {
    if (!force) {
      final cached = _readCache(key);
      if (cached != null) return Future.value(cached);
    }

    return _requests.get(key, () async {
      final data = await loader();
      // 先完成缓存写入再发布结果，关闭“请求已结束但缓存尚不可见”的
      // 重复请求窗口。
      await _homeCache.write(key, data);
      return data;
    });
  }

  static Object? _readCache(String key, {bool allowExpired = false}) =>
      _homeCache.read(key, allowExpired: allowExpired);

  static HomeItems _itemList(Object? value) => (value as List).cast<Map>();
}

class _FeedNotifier extends ValueNotifier<HomeItems> {
  _FeedNotifier() : super(<Map>[]);

  void appendAll(HomeItems items) {
    value.addAll(items);
    notifyListeners();
  }
}

class _HomeGroupsNotifier extends ValueNotifier<List<HomeItems>> {
  _HomeGroupsNotifier(super.value);

  void replaceAt(int index, HomeItems items) {
    value[index] = items;
    notifyListeners();
  }
}
