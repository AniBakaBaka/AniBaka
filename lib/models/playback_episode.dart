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
    if (rawList is List) {
      if (rawList is List<PlaybackEpisode>) return rawList.length;
      var count = 0;
      for (final item in rawList) {
        if (item is PlaybackEpisode ||
            (item is String && item.trim().isNotEmpty)) {
          count++;
        }
      }
      if (count > 0) return count;
    }

    final raw = data['videos'];
    if (raw is String && raw.isNotEmpty) {
      var count = 0;
      var start = 0;
      while (start < raw.length) {
        // Match String.trim's Unicode whitespace without allocating each line.
        switch (raw.codeUnitAt(start)) {
          case >= 0x09 && <= 0x0d ||
              0x20 ||
              0x85 ||
              0xa0 ||
              0x1680 ||
              >= 0x2000 && <= 0x200a ||
              0x2028 ||
              0x2029 ||
              0x202f ||
              0x205f ||
              0x3000 ||
              0xfeff:
            start++;
            continue;
        }
        count++;
        final end = raw.indexOf('\n', start);
        if (end < 0) break;
        start = end + 1;
      }
      return count;
    }
    return 0;
  }

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
