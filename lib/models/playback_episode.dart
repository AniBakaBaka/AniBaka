import 'package:flutter/foundation.dart';

@immutable
class PlaybackEpisode {
  const PlaybackEpisode({required this.title, required this.lines});

  static const separator = '\$';

  final String title;
  final List<String> lines;

  int get lineCount => lines.length;

  Iterable<int> get availableLineIndexes sync* {
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].isNotEmpty) yield i + 1;
    }
  }

  String? lineAt(int oneBasedIndex) {
    final index = oneBasedIndex - 1;
    return index >= 0 && index < lines.length && lines[index].isNotEmpty
        ? lines[index]
        : null;
  }

  String serialize() =>
      lines.isEmpty ? title : '$title$separator${lines.join(separator)}';

  static PlaybackEpisode? parse(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    final titleEnd = trimmed.indexOf(separator);
    if (titleEnd < 0) {
      return PlaybackEpisode(title: trimmed, lines: const []);
    }

    final title = trimmed.substring(0, titleEnd).trim();
    final lines = trimmed.substring(titleEnd + 1).split(separator);
    for (var i = 0; i < lines.length; i++) {
      lines[i] = lines[i].trim();
    }

    return PlaybackEpisode(title: title, lines: lines);
  }
}

class PlaybackEpisodeCatalog {
  PlaybackEpisodeCatalog._();

  /// 从 Map 数据中提取已解析的剧集列表。
  static List<PlaybackEpisode> episodesOf(
    Map data, {
    bool mergeDuplicateTitles = false,
  }) {
    final rawList = data['videoList'];
    if (rawList is List<PlaybackEpisode>) return rawList;
    if (rawList is List) {
      final episodes = parse(
        rawList,
        mergeDuplicateTitles: mergeDuplicateTitles,
      );
      if (episodes.isNotEmpty) return episodes;
    }
    final raw = data['videos'];
    if (raw is! String || raw.isEmpty) return const [];
    return parse(raw.split('\n'), mergeDuplicateTitles: mergeDuplicateTitles);
  }

  /// 计算剧集总数。
  static int countFrom(Map data) {
    final rawList = data['videoList'];
    if (rawList is List<PlaybackEpisode>) return rawList.length;
    if (rawList is List) {
      final count = rawList
          .where(
            (item) =>
                item is PlaybackEpisode ||
                (item is String && item.trim().isNotEmpty),
          )
          .length;
      if (count > 0) return count;
    }
    final raw = data['videos'];
    return raw is String ? _nonBlankLine.allMatches(raw).length : 0;
  }

  // `\s*` may cross blank lines, so each match ends on a distinct line.
  static final _nonBlankLine = RegExp(r'^\s*\S', multiLine: true);

  /// 解析序列化字符串集合为 [PlaybackEpisode] 列表。
  static List<PlaybackEpisode> parse(
    Iterable<Object?> values, {
    bool mergeDuplicateTitles = false,
  }) {
    final slotOf = mergeDuplicateTitles ? <String, int>{} : null;
    final episodes = <PlaybackEpisode>[];
    Map<int, List<String>>? mergedLines;

    for (final value in values) {
      final episode = switch (value) {
        PlaybackEpisode() => value,
        String() => PlaybackEpisode.parse(value),
        _ => null,
      };
      if (episode == null) continue;
      if (slotOf == null) {
        episodes.add(episode);
        continue;
      }

      final key = _mergeKey(episode.title);
      final slot = slotOf[key];
      if (slot == null) {
        slotOf[key] = episodes.length;
        episodes.add(episode);
      } else {
        final existing = episodes[slot];
        ((mergedLines ??= {})[slot] ??= List<String>.of(
          existing.lines,
        )).addAll(episode.lines);
      }
    }

    for (final entry
        in mergedLines?.entries ?? const <MapEntry<int, List<String>>>[]) {
      episodes[entry.key] = PlaybackEpisode(
        title: episodes[entry.key].title,
        lines: entry.value,
      );
    }

    return episodes;
  }

  static String _mergeKey(String title) {
    final trimmed = title.trim();
    final normalized = trimmed.replaceFirst(_titlePrefix, '').trim();
    return normalized.isEmpty ? trimmed : normalized;
  }

  static final _titlePrefix = RegExp(r'^\d+[\s.、:：]*');

  /// 按搜索词和正倒序过滤剧集下标。
  static List<int> filterIndexes(
    List<PlaybackEpisode> episodes, {
    required bool ascending,
    String searchQuery = '',
  }) {
    final query = searchQuery.trim().toLowerCase();
    final result = <int>[];
    final last = episodes.length - 1;

    for (var n = 0; n <= last; n++) {
      final i = ascending ? n : last - n;
      if (query.isEmpty || episodes[i].title.toLowerCase().contains(query)) {
        result.add(i);
      }
    }
    return result;
  }
}
