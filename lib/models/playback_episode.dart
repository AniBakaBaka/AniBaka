import 'package:flutter/foundation.dart';

@immutable
class PlaybackEpisode {
  const PlaybackEpisode({required this.title, required this.lines});

  static const separator = '\$';

  final String title;
  final List<String> lines;

  int get lineCount => lines.length;

  String? lineAt(int oneBasedIndex) {
    final index = oneBasedIndex - 1;
    return index >= 0 && index < lines.length ? lines[index] : null;
  }

  String serialize() =>
      lines.isEmpty ? title : '$title$separator${lines.join(separator)}';

  static PlaybackEpisode? parse(String value) {
    if (value.trim().isEmpty) return null;
    final parts = value.split(separator);
    return PlaybackEpisode(
      title: parts.first,
      lines: List<String>.unmodifiable(
        parts.skip(1).where((line) => line.isNotEmpty),
      ),
    );
  }
}

class PlaybackEpisodeCatalog {
  PlaybackEpisodeCatalog._();

  static final _numberStartRegExp = RegExp(r'^[\d一二三四五六七八九十零]+');
  static final _punctuationRegExp = RegExp(r'^[、.:：\s]+');

  static List<PlaybackEpisode> parse(
    Iterable<String> values, {
    bool mergeDuplicateTitles = false,
  }) {
    final parsed = values
        .map(PlaybackEpisode.parse)
        .whereType<PlaybackEpisode>();
    if (!mergeDuplicateTitles) {
      return List<PlaybackEpisode>.unmodifiable(parsed);
    }

    final grouped = <String, List<String>>{};
    final titles = <String, String>{};
    for (final episode in parsed) {
      final key = _normalizedTitle(episode.title);
      grouped.putIfAbsent(key, () => <String>[]).addAll(episode.lines);
      titles.putIfAbsent(key, () => episode.title);
    }
    return List<PlaybackEpisode>.unmodifiable(
      grouped.entries.map(
        (entry) => PlaybackEpisode(
          title: titles[entry.key]!,
          lines: List<String>.unmodifiable(entry.value),
        ),
      ),
    );
  }

  static List<int> filterIndexes(
    List<PlaybackEpisode> episodes, {
    required bool ascending,
    String searchQuery = '',
  }) {
    final query = searchQuery.trim().toLowerCase();
    final result = <int>[];
    for (var i = 0; i < episodes.length; i++) {
      if (query.isEmpty || episodes[i].title.toLowerCase().contains(query)) {
        result.add(i);
      }
    }
    return ascending ? result : result.reversed.toList(growable: false);
  }

  static String _normalizedTitle(String title) {
    final trimmed = title.trim();
    final prefix = _numberStartRegExp.firstMatch(trimmed)?.group(0) ?? '';
    if (prefix.isEmpty) return trimmed;
    final normalized = trimmed
        .substring(prefix.length)
        .replaceFirst(_punctuationRegExp, '')
        .trim();
    return normalized.isEmpty ? trimmed : normalized;
  }
}
