import 'package:baka/utils/json_values.dart';
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
  final int? bgmId;
  final int? episodeIndex;
  final DownloadTaskKind kind;
  String? danmakuPath;
  String? filePath;
  /// 自定义保存目录（每次下载由用户选择，或取自默认下载目录设置）。
  /// 为空时回退到应用默认下载目录。
  String? saveDir;
  /// 扩展源名（如 Bangumi / C 岛等）。仅用于区分同名作品，作为作品
  /// 文件夹命名后缀，避免不同源的同一作品名互相覆盖。
  String? sourceName;
  /// 播放地址名（线路名，如「播放源1」「播放源2」）。同一个扩展源下
  /// 可能有多个播放地址，作品文件夹名需据此区分，否则不同播放地址
  /// 下载的同名作品都会落进同一个扩展源名文件夹。无播放地址时为空。
  String? lineName;

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
    this.saveDir,
    this.sourceName,
    this.lineName,
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

  void dispose() {
    statusNotifier.dispose();
    progressNotifier.dispose();
    downloadedBytesNotifier.dispose();
  }

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
    'saveDir': saveDir,
    'sourceName': sourceName,
    'lineName': lineName,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) => DownloadTask(
    id: json['id'],
    url: json['url'],
    filename: json['filename'],
    title: json['title'],
    subtitle: json['subtitle'],
    thumbnail: json['thumbnail'],
    bgmId: toInt(json['bgmId'] ?? json['videoId']),
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
    saveDir: json['saveDir'] as String?,
    sourceName: json['sourceName'] as String?,
    lineName: json['lineName'] as String?,
  );

  /// `.m3u8` 是 `m3u8` 的子串，两次扫描里第一次恒被第二次覆盖。
  static DownloadTaskKind inferKind(String url) =>
      url.toLowerCase().contains('m3u8')
      ? DownloadTaskKind.hls
      : DownloadTaskKind.file;

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
