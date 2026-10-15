import 'dart:convert';

import 'package:flutter/foundation.dart';

enum AnimeSeason {
  spring('春季', 4),
  summer('夏季', 7),
  autumn('秋季', 10),
  winter('冬季', 1);

  const AnimeSeason(this.label, this.month);

  final String label;
  final int month;
}

enum AnimeFeed { recommended, latest, pure }

/// 首页与筛选面板共用的查询条件；tags 由创建者提供只读列表。
class AnimeFilter {
  const AnimeFilter({this.year, this.season, this.tags = const []})
    : assert(season == null || year != null),
      feed = null;

  const AnimeFilter._feed(this.feed)
    : year = null,
      season = null,
      tags = const [];

  static const presets = [
    AnimeFilter._feed(AnimeFeed.recommended),
    AnimeFilter._feed(AnimeFeed.latest),
    AnimeFilter._feed(AnimeFeed.pure),
  ];

  final AnimeFeed? feed;
  final int? year;
  final AnimeSeason? season;
  final List<String> tags;

  String get label => switch (feed) {
    AnimeFeed.recommended => '推荐',
    AnimeFeed.latest => '最新',
    AnimeFeed.pure => '纯净',
    null =>
      year == null && tags.isEmpty
          ? '全部'
          : [
              if (year != null) '$year${season?.label ?? '年'}',
              ...tags,
            ].join('、'),
  };

  String get cacheKey => jsonEncode([feed?.name, year, season?.month, tags]);

  /// Bangumi v0 的日期条件取交集，结束日期不包含在区间内。
  /// https://github.com/bangumi/api/blob/master/open-api/v0.yaml
  List<String>? get airDate {
    if (year == null) return null;
    final month = season?.month ?? 1;
    final end = DateTime(year!, month + (season == null ? 12 : 3));
    return [
      '>=$year-${month.toString().padLeft(2, '0')}-01',
      '<${end.year}-${end.month.toString().padLeft(2, '0')}-01',
    ];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnimeFilter &&
          feed == other.feed &&
          year == other.year &&
          season == other.season &&
          listEquals(tags, other.tags);

  @override
  int get hashCode => Object.hash(feed, year, season, Object.hashAll(tags));
}
