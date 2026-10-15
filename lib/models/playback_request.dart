import 'dart:collection';

import 'package:baka/models/playback_episode.dart';

/// Shared handoff between matching, navigation and a playback session.
/// Each consumer owns its selection; immutable catalogs are shared. Legacy
/// fields are decoded only at the old page boundary, never written back.
class PlaybackRequest {
  PlaybackRequest({
    required this.source,
    this.episodes = const [],
    this.sourceNames,
    this.episodeIndex,
    this.lineIndex,
    this.prefetched,
    this.httpHeaders,
    Map<String, dynamic> metadata = const {},
  }) : metadata = Map.unmodifiable(metadata);

  PlaybackRequest.fromMap(
    Map data, {
    String? source,
    Map<String, dynamic>? metadataUpdates,
  }) : source = source ?? data['source'] as String? ?? '',
      episodes = PlaybackEpisodeCatalog.episodesOf(
        data,
        mergeDuplicateTitles: true,
      ),
      episodeIndex = data['currPlayIndex'] as int?,
      lineIndex = data['currUrl'] as int?,
      sourceNames = (data['sourceNames'] as List?)?.cast<String>(),
      prefetched = data['_prefetchedPlayback'] as PrefetchedMedia?,
      httpHeaders = (data['httpHeaders'] as Map?)?.cast<String, String>(),
      metadata = UnmodifiableMapView({
        for (final key in data.keys.cast<String>())
          if (!_typedKeys.contains(key)) key: data[key],
        ...?metadataUpdates,
      });

  /// Older cloud history stored a Bangumi ID in `id` without a source marker.
  /// It must be matched to a source instead of being queried as a site post.
  factory PlaybackRequest.fromHistory(Map data) {
    final source = (data['source'] as String? ?? '').trim();
    final bgmId = int.tryParse('${data['bgmId']}') ?? 0;
    final legacyCloud =
        source.isEmpty && bgmId > 0 && int.tryParse('${data['id']}') == bgmId;
    return PlaybackRequest.fromMap(data, source: legacyCloud ? 'bgm' : source)
      ..episodeIndex = data['index'] as int?
      ..lineIndex = data['url'] as int?;
  }

  static const _typedKeys = {
    'source',
    'videos',
    'videoList',
    'sourceNames',
    'currPlayIndex',
    'currUrl',
    '_prefetchedPlayback',
    'httpHeaders',
  };

  final Map<String, dynamic> metadata;
  final List<PlaybackEpisode> episodes;
  final List<String>? sourceNames;
  int? episodeIndex;
  int? lineIndex;
  PrefetchedMedia? prefetched;
  final String source;
  final Map<String, String>? httpHeaders;
  Object? get contentId => metadata['seriesId'] ?? metadata['id'];
  String get title => metadata['title'] as String? ?? '';

  /// Metadata updates merge once; a selection-only copy shares its metadata.
  PlaybackRequest copyWith({
    List<PlaybackEpisode>? episodes,
    List<String>? sourceNames,
    int? episodeIndex,
    int? lineIndex,
    Map<String, dynamic>? metadataUpdates,
  }) => PlaybackRequest._(
    source,
    episodes ?? this.episodes,
    sourceNames ?? this.sourceNames,
    episodeIndex ?? this.episodeIndex,
    lineIndex ?? this.lineIndex,
    prefetched,
    httpHeaders,
    metadataUpdates == null || metadataUpdates.isEmpty
        ? metadata
        : UnmodifiableMapView({...metadata, ...metadataUpdates}),
  );

  PlaybackRequest._(
    this.source,
    this.episodes,
    this.sourceNames,
    this.episodeIndex,
    this.lineIndex,
    this.prefetched,
    this.httpHeaders,
    this.metadata,
  );

  void storePrefetched({
    required int episodeIndex,
    required int lineIndex,
    required String episodeId,
    required String url,
    required Map<String, String> httpHeaders,
  }) {
    prefetched = PrefetchedMedia(
      source: source,
      episodeIndex: episodeIndex,
      lineIndex: lineIndex,
      episodeId: episodeId,
      url: url,
      httpHeaders: httpHeaders,
      resolvedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class PrefetchedMedia {
  const PrefetchedMedia({
    required this.source,
    required this.episodeIndex,
    required this.lineIndex,
    required this.episodeId,
    required this.url,
    required this.httpHeaders,
    required this.resolvedAt,
  });
  final String source, episodeId, url;
  final int episodeIndex, lineIndex, resolvedAt;
  final Map<String, String> httpHeaders;

  bool matches(String sourceKey, int episode, int line, String id, int now) =>
      source == sourceKey &&
      episodeIndex == episode &&
      lineIndex == line &&
      episodeId == id &&
      url.isNotEmpty &&
      now >= resolvedAt &&
      now - resolvedAt <= const Duration(minutes: 10).inMilliseconds;
}
