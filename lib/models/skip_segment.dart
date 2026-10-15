import 'dart:convert';

import 'package:crypto/crypto.dart';

class SkipContext {
  const SkipContext({
    required this.sourceKey,
    this.timelineKey = 'original',
    this.subjectId,
    this.episodeId,
    this.episodeNumber,
    this.seriesKey,
  });

  final String sourceKey;
  final String timelineKey;
  final int? subjectId;
  final int? episodeId;
  // Playback policy only; never use playlist order as a public episode ID.
  final double? episodeNumber;
  final String? seriesKey;
  bool get isFirstEpisode => episodeNumber == 1;
  String? get suggestionKey =>
      seriesKey ?? (subjectId == null ? null : 'bgm:$subjectId');
  bool get bound => (subjectId ?? 0) > 0 && (episodeId ?? 0) > 0;
  String get localKey => '$sourceKey:$timelineKey';
  String? get seriesLocalKey =>
      seriesKey == null ? null : 'series:$seriesKey:$timelineKey';
  SkipContext bind(int subject, int episode) => SkipContext(
    sourceKey: sourceKey,
    timelineKey: timelineKey,
    subjectId: subject,
    episodeId: episode,
    episodeNumber: episodeNumber,
    seriesKey: seriesKey,
  );

  Map<String, dynamic> toJson(int durationMs) => {
    'source_key': sourceKey,
    'timeline_key': timelineKey,
    'bgm_id': subjectId,
    'episode_id': episodeId,
    'duration_ms': durationMs,
    if (seriesKey != null) 'series_key': seriesKey,
  };

  /// Stable source identity; never send signed playback URLs or local paths.
  static String sourceIdentity(List<Object?> parts) =>
      sha256.convert(utf8.encode(jsonEncode(parts))).toString();
}

class SkipSegment {
  const SkipSegment({
    required this.id,
    required this.type,
    required this.startMs,
    required this.endMs,
    required this.durationMs,
    required this.origin,
    this.automatic = false,
    this.status = 'candidate',
    this.confirms = 0,
    this.reports = 0,
    this.scope = 'episode',
  });

  final String id, type, origin, status;
  final String scope;
  bool get allEpisodes => scope == 'series';
  final int startMs, endMs, durationMs, confirms, reports;
  final bool automatic;
  String get label => type == 'op' ? '片头' : '片尾';
  bool contains(int position) => position >= startMs && position < endMs;
  bool get valid =>
      (type == 'op' || type == 'ed') &&
      startMs >= 0 &&
      endMs > startMs &&
      endMs <= durationMs;
  bool fits(int duration) =>
      valid &&
      endMs <= duration &&
      (allEpisodes || (durationMs - duration).abs() <= 2000);

  // Public candidates with a different reference duration may be inspected,
  // but must not enter the automatic playback session until locally confirmed.
  bool canPreview(int duration) =>
      origin == 'local' ? fits(duration) : valid && endMs <= duration;

  factory SkipSegment.fromJson(Map<String, dynamic> json) => SkipSegment(
    id: '${json['id']}',
    type: json['type'] as String,
    startMs: (json['start_ms'] as num).round(),
    endMs: (json['end_ms'] as num).round(),
    durationMs: (json['duration_ms'] as num).round(),
    origin: json['origin'] as String? ?? 'community',
    automatic: json['automatic'] == true,
    status: json['status'] as String? ?? 'candidate',
    confirms: (json['confirms'] as num?)?.toInt() ?? 0,
    reports: (json['reports'] as num?)?.toInt() ?? 0,
    scope: json['scope'] as String? ?? 'episode',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'start_ms': startMs,
    'end_ms': endMs,
    'duration_ms': durationMs,
    'origin': origin,
    'automatic': automatic,
    'status': status,
    'confirms': confirms,
    'reports': reports,
    'scope': scope,
  };
}

class SkipData {
  const SkipData({
    this.context,
    this.segments = const [],
    this.availableSegments,
    this.disabled = (op: false, ed: false),
    this.message = '等待视频信息',
  });
  final SkipContext? context;
  final List<SkipSegment> segments;
  // Includes disabled and duration-mismatched candidates for manual inspection.
  final List<SkipSegment>? availableSegments;
  List<SkipSegment> get editableSegments => availableSegments ?? segments;
  final ({bool op, bool ed}) disabled;
  final String message;
}

/// Per-open playback decisions, independent of the native player and HTTP.
class SkipSession {
  List<SkipSegment> segments = const [];
  final Set<String> _suppressed = {};
  final Set<String> _dismissed = {};
  int? _previous;

  void reset() {
    segments = const [];
    _suppressed.clear();
    _dismissed.clear();
    _previous = null;
  }

  void install(List<SkipSegment> values, int position) {
    final previousSegments = segments;
    segments = values;
    // Late data and resumed playback must not suddenly seek mid-segment.
    for (final segment in values) {
      final alreadyInstalled = previousSegments.any(
        (previous) =>
            previous.type == segment.type &&
            previous.startMs == segment.startMs &&
            previous.endMs == segment.endMs &&
            previous.durationMs == segment.durationMs,
      );
      if (!alreadyInstalled &&
          segment.contains(position) &&
          position > segment.startMs) {
        suppress(segment);
      }
    }
    _previous = position;
  }

  void suppress(SkipSegment segment) => _suppressed.add(segment.type);

  void dismiss(SkipSegment segment) {
    suppress(segment);
    _dismissed.add(segment.type);
  }

  void seek(int target) {
    for (final segment in segments) {
      if (segment.contains(target)) suppress(segment);
    }
    _previous = target;
  }

  ({SkipSegment segment, bool automatic})? observe(
    int position, {
    required int duration,
    required bool canAuto,
    double? episodeNumber,
  }) {
    final previous = _previous;
    _previous = position;
    if (episodeNumber == 1) return null;
    for (final segment in segments) {
      if (_dismissed.contains(segment.type) ||
          !segment.fits(duration) ||
          !segment.contains(position)) {
        continue;
      }
      if (previous != null && position < previous) suppress(segment);
      // Loading/playing events may lag behind the first position in a segment.
      // Explicit seeks, late data and undo are already tracked by suppression.
      final auto =
          canAuto &&
          segment.automatic &&
          !_suppressed.contains(segment.type) &&
          previous != null;
      if (auto) suppress(segment);
      return (segment: segment, automatic: auto);
    }
    return null;
  }
}

/// Only explicit episode labels are used; playlist order is not an identity.
double? skipEpisodeNumber(String title) {
  final text = title.trim();
  final number = _episodeNumber.firstMatch(text);
  if (number == null) return null;
  return double.tryParse(
    number.group(1) ?? number.group(2) ?? number.group(3)!,
  );
}

final _episodeNumber = RegExp(
  r'^(?:第\s*(\d+(?:\.\d+)?)\s*[集话話]|(?:EP?\.?|Episode)\s*(\d+(?:\.\d+)?)|(\d+(?:\.\d+)?))$',
  caseSensitive: false,
);

int? matchSkipEpisode(String title, List<Map<String, dynamic>> episodes) {
  final value = skipEpisodeNumber(title);
  if (value == null) return null;
  int? match;
  for (final episode in episodes) {
    if (episode['type'] != 0 || episode['sort'] != value) continue;
    if (match != null) return null;
    match = episode['id'] as int;
  }
  return match;
}
