import 'package:flutter/foundation.dart';

enum DownloadStatus { waiting, downloading, paused, completed, failed }

enum DownloadTaskKind { file, hls }

class DownloadTask {
  final String id;
  final String url;
  final String filename;
  final String title;
  final String? subtitle;
  final String? thumbnail;
  final String? bgmId;
  final int? episodeIndex;
  final DownloadTaskKind kind;
  String? danmakuPath;
  String? filePath;

  final ValueNotifier<DownloadStatus> statusNotifier;
  final ValueNotifier<double> progressNotifier;
  final ValueNotifier<int> downloadedBytesNotifier;

  int totalBytes;
  final DateTime createdAt;
  DateTime? completedAt;

  DownloadTask({
    required this.id,
    required this.url,
    required this.filename,
    required this.title,
    this.subtitle,
    this.thumbnail,
    this.bgmId,
    this.episodeIndex,
    DownloadTaskKind? kind,
    this.danmakuPath,
    DownloadStatus status = DownloadStatus.waiting,
    double progress = 0.0,
    int downloadedBytes = 0,
    this.totalBytes = 0,
    this.filePath,
    DateTime? createdAt,
    this.completedAt,
  }) : statusNotifier = ValueNotifier(status),
       progressNotifier = ValueNotifier(progress),
       downloadedBytesNotifier = ValueNotifier(downloadedBytes),
       kind = kind ?? inferKind(url),
       createdAt = createdAt ?? DateTime.now();

  DownloadStatus get status => statusNotifier.value;
  set status(DownloadStatus s) => statusNotifier.value = s;

  double get progress => progressNotifier.value;
  set progress(double p) => progressNotifier.value = p;

  int get downloadedBytes => downloadedBytesNotifier.value;
  set downloadedBytes(int b) => downloadedBytesNotifier.value = b;

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'filename': filename,
    'title': title,
    'subtitle': subtitle,
    'thumbnail': thumbnail,
    'bgmId': bgmId,
    'episodeIndex': episodeIndex,
    'kind': kind.name,
    'danmakuPath': danmakuPath,
    'status': status.index,
    'progress': progress,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'completedAt': completedAt?.millisecondsSinceEpoch,
    'filePath': filePath,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) => DownloadTask(
    id: json['id'],
    url: json['url'],
    filename: json['filename'],
    title: json['title'],
    subtitle: json['subtitle'],
    thumbnail: json['thumbnail'],
    bgmId: json['bgmId'] ?? json['videoId'],
    episodeIndex: json['episodeIndex'],
    kind: _kindFromJson(json),
    danmakuPath: json['danmakuPath'],
    status: DownloadStatus.values[json['status'] ?? 0],
    progress: (json['progress'] ?? 0.0).toDouble(),
    downloadedBytes: json['downloadedBytes'] ?? 0,
    totalBytes: json['totalBytes'] ?? 0,
    createdAt: json['createdAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'])
        : null,
    completedAt: json['completedAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['completedAt'])
        : null,
    filePath: json['filePath'],
  );

  static DownloadTaskKind inferKind(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') || lower.contains('m3u8')
        ? DownloadTaskKind.hls
        : DownloadTaskKind.file;
  }

  static DownloadTaskKind _kindFromJson(Map<String, dynamic> json) {
    final raw = json['kind'];
    if (raw is String) {
      for (final kind in DownloadTaskKind.values) {
        if (kind.name == raw) return kind;
      }
    }
    return inferKind(json['url']?.toString() ?? '');
  }
}
