import 'package:baka/models/playback_episode.dart';
import 'package:baka/source/models/episode.dart';

class Source {
  final List<Episode> episodes;
  final String? sourceName;

  Source(this.episodes, [this.sourceName]);
}

/// Player-facing episode catalog shared by source search, matching and player
/// services. Source parsers produce line-oriented [Source] values; this class
/// transposes them once and keeps the typed result for the rest of the flow.
class PlaybackCatalog {
  const PlaybackCatalog({required this.episodes, required this.sourceNames});

  static const empty = PlaybackCatalog(episodes: [], sourceNames: []);

  final List<PlaybackEpisode> episodes;
  final List<String> sourceNames;

  bool get isEmpty => episodes.isEmpty;

  factory PlaybackCatalog.fromSources(List<Source> sources) {
    if (sources.isEmpty) return empty;

    final slots = <int, _EpisodeSlot>{};
    for (var sourceIndex = 0; sourceIndex < sources.length; sourceIndex++) {
      final source = sources[sourceIndex];
      for (var i = 0; i < source.episodes.length; i++) {
        final episode = source.episodes[i];
        final index = episode.episode >= 0 ? episode.episode : i;
        final slot = slots[index];
        if (slot == null) {
          slots[index] = _EpisodeSlot(
            episode.name,
            episode.episodeId,
            sourceIndex,
          );
        } else if (slot.lastSourceIndex == sourceIndex) {
          slot.lines.last = episode.episodeId;
          if (slot.titleSourceIndex == sourceIndex) slot.title = episode.name;
        } else {
          slot.lines.add(episode.episodeId);
          slot.lastSourceIndex = sourceIndex;
        }
      }
    }

    if (slots.isEmpty) return empty;
    final indexes = slots.keys.toList()..sort();
    return PlaybackCatalog(
      episodes: List<PlaybackEpisode>.generate(indexes.length, (i) {
        final slot = slots[indexes[i]]!;
        return PlaybackEpisode(title: slot.title, lines: slot.lines);
      }, growable: false),
      sourceNames: List<String>.generate(
        sources.length,
        (i) => sources[i].sourceName ?? '线路${i + 1}',
        growable: false,
      ),
    );
  }
}

class _EpisodeSlot {
  _EpisodeSlot(this.title, String line, int sourceIndex)
    : titleSourceIndex = sourceIndex,
      lastSourceIndex = sourceIndex,
      lines = [line];

  String title;
  final int titleSourceIndex;
  int lastSourceIndex;
  final List<String> lines;
}
