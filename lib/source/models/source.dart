import 'package:baka/models/playback_episode.dart';

/// One parsed episode of a playback line.
class Episode {
  Episode(this.episodeId, this.episode, [this.episodeName]);

  final String episodeId;
  final int episode;
  final String? episodeName;

  String get name => episodeName ?? '第${episode + 1}集';
}

/// One playback line as produced by the parsers.
class Source {
  Source(this.episodes, [this.sourceName]);

  final List<Episode> episodes;
  final String? sourceName;
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
    final slots = <int, _EpisodeSlot>{};
    for (var line = 0; line < sources.length; line++) {
      final episodes = sources[line].episodes;
      for (var i = 0; i < episodes.length; i++) {
        final episode = episodes[i];
        if (episode.episodeId.isEmpty) continue;
        final slot = slots.putIfAbsent(
          episode.episode >= 0 ? episode.episode : i,
          () => _EpisodeSlot(line, sources.length),
        );
        slot.lines[line] = episode.episodeId;
        // The line that introduced an episode owns its title.
        if (slot.owner == line) slot.title = episode.name;
      }
    }
    if (slots.isEmpty) return empty;
    final indexes = slots.keys.toList()..sort();
    return PlaybackCatalog(
      episodes: [
        for (final index in indexes)
          PlaybackEpisode(
            title: slots[index]!.title,
            lines: slots[index]!.lines,
          ),
      ],
      sourceNames: [
        for (var i = 0; i < sources.length; i++)
          sources[i].sourceName ?? '线路${i + 1}',
      ],
    );
  }
}

class _EpisodeSlot {
  _EpisodeSlot(this.owner, int lineCount) : lines = List.filled(lineCount, '');

  final int owner;
  final List<String> lines;
  String title = '';
}
