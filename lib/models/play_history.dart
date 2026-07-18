/// 播放历史数据模型
class PlayHistory {
  final int? id;
  final int? userId;
  final int videoId;
  final String videoTitle;
  final String? videoCover;
  final int videoDuration;
  final int playProgress;
  final double? playPercentage;
  final int? episodeId;
  final String? episodeTitle;
  final int? videoType;
  final String? platform;
  final int? bgmId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool isFinished;

  PlayHistory({
    required this.videoId,
    required this.videoTitle,
    required this.videoDuration,
    required this.playProgress,
    this.id,
    this.userId,
    this.videoCover,
    this.playPercentage,
    this.episodeId,
    this.episodeTitle,
    this.videoType,
    this.platform,
    this.bgmId,
    this.createdAt,
    this.updatedAt,
    this.isFinished = false,
  });

  factory PlayHistory.fromJson(Map<String, dynamic> json) {
    return PlayHistory(
      id: (json['id'] as num?)?.toInt(),
      userId: (json['user_id'] as num?)?.toInt(),
      videoId: (json['video_id'] as num?)?.toInt() ?? 0,
      videoTitle: json['video_title'] as String? ?? '',
      videoCover: json['video_cover'] as String?,
      videoDuration: (json['video_duration'] as num?)?.toInt() ?? 0,
      playProgress: (json['play_progress'] as num?)?.toInt() ?? 0,
      playPercentage: (json['play_percentage'] as num?)?.toDouble(),
      episodeId: (json['episode_id'] as num?)?.toInt(),
      episodeTitle: json['episode_title'] as String?,
      videoType: (json['video_type'] as num?)?.toInt(),
      platform: json['platform'] as String?,
      bgmId: (json['bgm_id'] as num?)?.toInt(),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)
          : null,
      isFinished: json['is_finished'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'video_id': videoId,
      'video_title': videoTitle,
      if (videoCover != null) 'video_cover': videoCover,
      'video_duration': videoDuration,
      'play_progress': playProgress,
      if (episodeId != null) 'episode_id': episodeId,
      if (episodeTitle != null) 'episode_title': episodeTitle,
      if (videoType != null) 'video_type': videoType,
      if (platform != null) 'platform': platform,
      if (bgmId != null) 'bgm_id': bgmId,
    };
  }
}

/// 播放历史列表响应
class PlayHistoryListResponse {
  final List<PlayHistory> list;

  PlayHistoryListResponse({required this.list});

  factory PlayHistoryListResponse.fromJson(Map<String, dynamic> json) {
    final rawList = json['list'];
    return PlayHistoryListResponse(
      list: rawList is List
          ? rawList.map((item) => PlayHistory.fromJson(item)).toList()
          : const [],
    );
  }
}
