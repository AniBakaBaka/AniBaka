/// 追番收藏数据模型
library;

import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/json_values.dart';

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

  static CollectionStatus? fromValue(int? value) {
    if (value == null || value < 1 || value > values.length) return null;
    return values[value - 1];
  }
}

/// 追番收藏记录
class AnimeCollection {
  /// Only site posts use this ID namespace; Bangumi and adapter IDs are not posts.
  static int? postIdFrom(Map data, {String? source}) {
    final origin = source ?? data['source'] as String? ?? '';
    if (origin.isNotEmpty && origin != 'internal') return null;
    final id = toInt(data['id']);
    return id != null && id > 0 ? id : null;
  }

  final int? postId;
  final int? bgmId;
  final int status;
  final int rating;
  final String? comment;
  final int? epTotal;
  final int? epWatched;
  final List<String> tags;
  final bool isPrivate;
  final bool nsfw;
  final String? postTitle;
  final String? postCover;
  final double? bgmRating;
  final String? bgmImage;
  final String? bgmTitle;

  const AnimeCollection({
    required this.status,
    this.postId,
    this.bgmId,
    this.rating = 0,
    this.comment,
    this.epTotal,
    this.epWatched,
    this.tags = const [],
    this.isPrivate = false,
    this.nsfw = false,
    this.postTitle,
    this.postCover,
    this.bgmRating,
    this.bgmImage,
    this.bgmTitle,
  });

  String get displayTitle => (postTitle != null && postTitle!.isNotEmpty)
      ? postTitle!
      : (bgmTitle ?? '');

  String get displayCover => bgmImage ?? postCover ?? '';

  factory AnimeCollection.fromJson(
    Map<String, dynamic> json,
  ) => AnimeCollection(
    postId: json['post_id'] as int?,
    bgmId: json['bgm_id'] as int?,
    status: json['status'] as int,
    rating: json['rating'] as int? ?? 0,
    comment: json['comment'] as String?,
    epTotal: json['ep_total'] as int?,
    epWatched: json['ep_watched'] as int?,
    // Local storage now retains the list; older records and AniBaka use CSV.
    tags: switch (json['tags']) {
      final List value => value.cast<String>(),
      final String value when value.isNotEmpty =>
        value
            .split(_tagSeparator)
            .where((tag) => tag.isNotEmpty)
            .toSet()
            .toList(growable: false),
      _ => const [],
    },
    isPrivate: json['is_private'] as bool? ?? false,
    nsfw: json['nsfw'] == true,
    postTitle: json['post_title'] as String?,
    postCover: json['post_cover'] as String?,
    bgmRating: (json['bgm_rating'] as num?)?.toDouble(),
    bgmImage: json['bgm_image'] as String?,
    bgmTitle: json['bgm_title'] as String?,
  );

  factory AnimeCollection.fromBangumi(Map<String, dynamic> json) {
    final subject = json['subject'] as Map<String, dynamic>?;
    final subjectId = json['subject_id'] as int;
    return AnimeCollection(
      bgmId: subjectId,
      status: json['type'] as int,
      rating: json['rate'] as int,
      epWatched: json['ep_status'] as int,
      tags: (json['tags'] as List).cast<String>(),
      bgmImage: BgmUtils.bgmCoverProxyUrl(subjectId),
      isPrivate: json['private'] as bool,
      nsfw: subject?['nsfw'] == true,
      bgmTitle: trimmed(subject?['name_cn']) ?? trimmed(subject?['name']) ?? '',
      comment: trimmed(json['comment']),
      epTotal: subject?['eps'] as int?,
      bgmRating: (subject?['score'] as num?)?.toDouble(),
    );
  }

  static final _tagSeparator = RegExp(r'[,，\s]+');

  Map<String, dynamic> toJson({bool includeLocalFields = false}) => {
    if (postId != null) 'post_id': postId,
    if (bgmId != null) 'bgm_id': bgmId,
    'status': status,
    if (rating > 0) 'rating': rating,
    if (comment != null && comment!.isNotEmpty) 'comment': comment,
    if (epTotal != null) 'ep_total': epTotal,
    if (epWatched != null) 'ep_watched': epWatched,
    if (tags.isNotEmpty) 'tags': includeLocalFields ? tags : tags.join(','),
    'is_private': isPrivate,
    if (includeLocalFields) 'nsfw': nsfw,
    if (postTitle != null && postTitle!.isNotEmpty) 'post_title': postTitle,
    if (postCover != null && postCover!.isNotEmpty) 'post_cover': postCover,
    if (bgmImage != null && bgmImage!.isNotEmpty) 'bgm_image': bgmImage,
    if (bgmTitle != null && bgmTitle!.isNotEmpty) 'bgm_title': bgmTitle,
    if (includeLocalFields && bgmRating != null) 'bgm_rating': bgmRating,
  };
}

/// 收藏统计
class CollectionStats {
  final int wish;
  final int collect;
  final int doing;
  final int onHold;
  final int dropped;
  final int total;

  const CollectionStats({
    this.wish = 0,
    this.collect = 0,
    this.doing = 0,
    this.onHold = 0,
    this.dropped = 0,
    this.total = 0,
  });

  factory CollectionStats.fromJson(Map<String, dynamic> json) =>
      CollectionStats(
        wish: json['wish'] as int,
        collect: json['collect'] as int,
        doing: json['do'] as int,
        onHold: json['on_hold'] as int,
        dropped: json['dropped'] as int,
        total: json['total'] as int,
      );

  int countForStatus(CollectionStatus status) => switch (status) {
    CollectionStatus.wish => wish,
    CollectionStatus.collect => collect,
    CollectionStatus.doing => doing,
    CollectionStatus.onHold => onHold,
    CollectionStatus.dropped => dropped,
  };
}
