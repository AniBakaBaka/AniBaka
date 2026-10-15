import 'package:baka/models/bgm.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/source/models/series.dart';

/// A source result retains its Series. Only the legacy internal API needs a map.
class SourceSearchResult {
  SourceSearchResult(
    Series this.series, {
    required this.source,
    required this.displayName,
    this.fallbackDescription = '',
  }) : internalData = null;

  SourceSearchResult.internal(Map<String, dynamic> this.internalData)
    : series = null,
      source = 'internal',
      displayName = '站内',
      fallbackDescription = '';

  final Series? series;
  final Map<String, dynamic>? internalData;
  final String source, displayName, fallbackDescription;
  String get title => series?.name ?? internalData!['title'] as String? ?? '';
  String get id => series?.seriesId ?? '${internalData!['id']}';
  late final String key = '$source|$id';
  String get description => series?.description ?? fallbackDescription;
  String get cover =>
      series?.image ?? resolveCoverImage(internalData ?? const {}) ?? '';
  late final int? episodeCount = _episodeCount();

  int? _episodeCount() {
    final data = internalData;
    if (data == null) return null;
    final count = PlaybackEpisodeCatalog.countFrom(data);
    return count > 0 ? count : null;
  }

  Map<String, dynamic> toLegacyMap() {
    final data = internalData;
    if (data != null) return data;
    final image = cover;
    return {
      'title': title,
      'seriesId': id,
      'source': source,
      'sourceDisplayName': displayName,
      'tag': displayName,
      'description': description,
      'subtitle': description,
      'image': image,
      'content': image,
      if (series!.bgmId != null) 'bgmId': series!.bgmId,
      if (series!.score != null) 'score': series!.score,
      if (image.isNotEmpty) 'bgmImageUrl': image,
    };
  }

  /// Old search pages cross this boundary once when opening playback.
  factory SourceSearchResult.fromLegacy(Map<String, dynamic> data) {
    if (data['source'] == 'internal') return SourceSearchResult.internal(data);
    return SourceSearchResult(
      Series(
        data['seriesId'] as String,
        data['title'] as String? ?? '',
        description: data['description'] as String?,
        image: data['image'] as String?,
        bgmId: data['bgmId'] as int?,
        score: (data['score'] as num?)?.toDouble(),
      ),
      source: data['source'] as String,
      displayName: data['sourceDisplayName'] as String? ?? '',
    );
  }
}
