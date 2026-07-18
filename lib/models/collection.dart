/// 追番收藏数据模型
library;

/// 收藏状态枚举
enum CollectionStatus {
  wish(1, '想看', 'wish'),
  collect(2, '看过', 'collect'),
  doing(3, '在看', 'do'),
  onHold(4, '搁置', 'on_hold'),
  dropped(5, '抛弃', 'dropped');

  final int value;
  final String label;
  final String key;

  const CollectionStatus(this.value, this.label, this.key);

  static CollectionStatus? fromValue(int? value) {
    if (value == null) return null;
    return CollectionStatus.values.cast<CollectionStatus?>().firstWhere(
      (s) => s?.value == value,
      orElse: () => null,
    );
  }

  static CollectionStatus? fromKey(String? key) {
    if (key == null) return null;
    return CollectionStatus.values.cast<CollectionStatus?>().firstWhere(
      (s) => s?.key == key,
      orElse: () => null,
    );
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
  final DateTime? createdAt;
  final DateTime? updatedAt;
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
    this.createdAt,
    this.updatedAt,
    this.postTitle,
    this.postCover,
    this.bgmRating,
    this.bgmImage,
    this.bgmTitle,
  });

  CollectionStatus? get collectionStatus => CollectionStatus.fromValue(status);

  String get displayTitle {
    if (postTitle != null && postTitle!.isNotEmpty) return postTitle!;
    if (bgmTitle != null && bgmTitle!.isNotEmpty) return bgmTitle!;
    return '';
  }

  String get displayCover => bgmImage ?? postCover ?? '';

  factory AnimeCollection.fromJson(Map<String, dynamic> json) {
    return AnimeCollection(
      id: _parseInt(json['id']),
      userId: _parseInt(json['user_id']),
      postId: _parseInt(json['post_id']),
      bgmId: _parseInt(json['bgm_id']),
      status: _parseInt(json['status']) ?? 1,
      statusText: json['status_text']?.toString(),
      rating: _parseInt(json['rating']) ?? 0,
      comment: json['comment']?.toString(),
      epTotal: _parseInt(json['ep_total']),
      epWatched: _parseInt(json['ep_watched']),
      tags: json['tags']?.toString(),
      isPrivate: _parseBool(json['is_private']),
      createdAt: _parseDateTime(json['created_at']),
      updatedAt: _parseDateTime(json['updated_at']),
      postTitle: json['post_title']?.toString(),
      postCover: json['post_cover']?.toString(),
      bgmRating: _parseDouble(json['bgm_rating']),
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

  AnimeCollection copyWith({
    int? id,
    int? userId,
    int? postId,
    int? bgmId,
    int? status,
    String? statusText,
    int? rating,
    String? comment,
    int? epTotal,
    int? epWatched,
    String? tags,
    bool? isPrivate,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? postTitle,
    String? postCover,
    double? bgmRating,
    String? bgmImage,
    String? bgmTitle,
  }) {
    return AnimeCollection(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      postId: postId ?? this.postId,
      bgmId: bgmId ?? this.bgmId,
      status: status ?? this.status,
      statusText: statusText ?? this.statusText,
      rating: rating ?? this.rating,
      comment: comment ?? this.comment,
      epTotal: epTotal ?? this.epTotal,
      epWatched: epWatched ?? this.epWatched,
      tags: tags ?? this.tags,
      isPrivate: isPrivate ?? this.isPrivate,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      postTitle: postTitle ?? this.postTitle,
      postCover: postCover ?? this.postCover,
      bgmRating: bgmRating ?? this.bgmRating,
      bgmImage: bgmImage ?? this.bgmImage,
      bgmTitle: bgmTitle ?? this.bgmTitle,
    );
  }

  static int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return null;
  }

  static bool _parseBool(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is int) return value != 0;
    if (value is String) return value.toLowerCase() == 'true' || value == '1';
    return false;
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
    final rawList = json['list'];
    return CollectionListResponse(
      list: rawList is List
          ? rawList.map((item) => AnimeCollection.fromJson(item)).toList()
          : const [],
      total: json['total'] ?? 0,
      page: json['page'] ?? 1,
      pageSize: json['page_size'] ?? 20,
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
      wish: json['wish'] ?? 0,
      collect: json['collect'] ?? 0,
      doing: json['do'] ?? 0,
      onHold: json['on_hold'] ?? 0,
      dropped: json['dropped'] ?? 0,
      total: json['total'] ?? 0,
    );
  }

  int countForStatus(CollectionStatus status) {
    switch (status) {
      case CollectionStatus.wish:
        return wish;
      case CollectionStatus.collect:
        return collect;
      case CollectionStatus.doing:
        return doing;
      case CollectionStatus.onHold:
        return onHold;
      case CollectionStatus.dropped:
        return dropped;
    }
  }
}
