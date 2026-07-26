/// 追番收藏数据模型
library;

import 'package:baka/utils/bgm_utils.dart';

/// 收藏状态枚举
enum CollectionStatus {
  wish(1, '想看'),
  collect(2, '看过'),
  doing(3, '在看'),
  onHold(4, '搁置'),
  dropped(5, '抛弃');

  final int value;
  final String label;

  const CollectionStatus(this.value, this.label);

  /// value 与声明顺序一一对应（1..5），直接下标定位后再核对一次，
  /// 既是 O(1) 也不会因日后调整枚举顺序而失准。
  static CollectionStatus? fromValue(int? value) {
    if (value == null || value < 1 || value > values.length) return null;
    final status = values[value - 1];
    return status.value == value ? status : null;
  }
}

/// 追番收藏记录
class AnimeCollection {
  final int? id;
  final int? userId;
  final int? postId;
  final int? bgmId;
  final int status;
  final String? statusText;
  final int rating;
  final String? comment;
  final int? epTotal;
  final int? epWatched;
  final String? tags;
  final bool isPrivate;
  final String? postTitle;
  final String? postCover;
  final double? bgmRating;
  final String? bgmImage;
  final String? bgmTitle;

  AnimeCollection({
    required this.status,
    this.id,
    this.userId,
    this.postId,
    this.bgmId,
    this.statusText,
    this.rating = 0,
    this.comment,
    this.epTotal,
    this.epWatched,
    this.tags,
    this.isPrivate = false,
    this.postTitle,
    this.postCover,
    this.bgmRating,
    this.bgmImage,
    this.bgmTitle,
  });

  String get displayTitle {
    if (postTitle != null && postTitle!.isNotEmpty) return postTitle!;
    if (bgmTitle != null && bgmTitle!.isNotEmpty) return bgmTitle!;
    return '';
  }

  String get displayCover => bgmImage ?? postCover ?? '';

  factory AnimeCollection.fromJson(Map<String, dynamic> json) {
    return AnimeCollection(
      id: BgmUtils.toInt(json['id']),
      userId: BgmUtils.toInt(json['user_id']),
      postId: BgmUtils.toInt(json['post_id']),
      bgmId: BgmUtils.toInt(json['bgm_id']),
      status: BgmUtils.toInt(json['status']) ?? 1,
      statusText: json['status_text']?.toString(),
      rating: BgmUtils.toInt(json['rating']) ?? 0,
      comment: json['comment']?.toString(),
      epTotal: BgmUtils.toInt(json['ep_total']),
      epWatched: BgmUtils.toInt(json['ep_watched']),
      tags: json['tags']?.toString(),
      isPrivate: BgmUtils.toBool(json['is_private']),
      postTitle: json['post_title']?.toString(),
      postCover: json['post_cover']?.toString(),
      bgmRating: BgmUtils.toDouble(json['bgm_rating']),
      bgmImage: json['bgm_image']?.toString(),
      bgmTitle: json['bgm_title']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (postId != null) 'post_id': postId,
      if (bgmId != null) 'bgm_id': bgmId,
      'status': status,
      if (rating > 0) 'rating': rating,
      if (comment != null && comment!.isNotEmpty) 'comment': comment,
      if (epTotal != null) 'ep_total': epTotal,
      if (epWatched != null) 'ep_watched': epWatched,
      if (tags != null && tags!.isNotEmpty) 'tags': tags,
      'is_private': isPrivate,
      if (postTitle != null && postTitle!.isNotEmpty) 'post_title': postTitle,
      if (postCover != null && postCover!.isNotEmpty) 'post_cover': postCover,
      if (bgmImage != null && bgmImage!.isNotEmpty) 'bgm_image': bgmImage,
      if (bgmTitle != null && bgmTitle!.isNotEmpty) 'bgm_title': bgmTitle,
    };
  }
}

/// 追番收藏列表响应
class CollectionListResponse {
  final List<AnimeCollection> list;
  final int total;
  final int page;
  final int pageSize;

  CollectionListResponse({
    required this.list,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  factory CollectionListResponse.fromJson(Map<String, dynamic> json) {
    return CollectionListResponse(
      list: BgmUtils.mapList(json['list'], AnimeCollection.fromJson),
      total: BgmUtils.toInt(json['total']) ?? 0,
      page: BgmUtils.toInt(json['page']) ?? 1,
      pageSize: BgmUtils.toInt(json['page_size']) ?? 20,
    );
  }
}

/// 收藏统计
class CollectionStats {
  final int wish;
  final int collect;
  final int doing;
  final int onHold;
  final int dropped;
  final int total;

  CollectionStats({
    this.wish = 0,
    this.collect = 0,
    this.doing = 0,
    this.onHold = 0,
    this.dropped = 0,
    this.total = 0,
  });

  factory CollectionStats.fromJson(Map<String, dynamic> json) {
    return CollectionStats(
      wish: BgmUtils.toInt(json['wish']) ?? 0,
      collect: BgmUtils.toInt(json['collect']) ?? 0,
      doing: BgmUtils.toInt(json['do']) ?? 0,
      onHold: BgmUtils.toInt(json['on_hold']) ?? 0,
      dropped: BgmUtils.toInt(json['dropped']) ?? 0,
      total: BgmUtils.toInt(json['total']) ?? 0,
    );
  }

  int countForStatus(CollectionStatus status) => switch (status) {
    CollectionStatus.wish => wish,
    CollectionStatus.collect => collect,
    CollectionStatus.doing => doing,
    CollectionStatus.onHold => onHold,
    CollectionStatus.dropped => dropped,
  };
}
