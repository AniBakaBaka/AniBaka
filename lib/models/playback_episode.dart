import 'dart:collection';

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

  /// 就地按 `$` 切分：只为标题和每条线路各分配一个 substring，
  /// 不再走 `trim()` + `split()` + `skip().where()` + 复制成不可变列表的链路。
  static PlaybackEpisode? parse(String value) {
    if (_isBlank(value)) return null;

    final titleEnd = value.indexOf(separator);
    if (titleEnd < 0) {
      return PlaybackEpisode(title: value, lines: const []);
    }

    final lines = <String>[];
    var start = titleEnd + 1;
    while (start <= value.length) {
      var end = value.indexOf(separator, start);
      if (end < 0) end = value.length;
      if (end > start) lines.add(value.substring(start, end));
      start = end + 1;
    }
    return PlaybackEpisode(
      title: value.substring(0, titleEnd),
      // 视图而非拷贝：底层列表是本地变量，不会外泄。
      lines: UnmodifiableListView(lines),
    );
  }

  static bool _isBlank(String value) {
    for (var i = 0; i < value.length; i++) {
      if (value.codeUnitAt(i) > 0x20) return false;
    }
    return true;
  }
}

class PlaybackEpisodeCatalog {
  PlaybackEpisodeCatalog._();

  /// 单趟扫描 `videos` 串的非空行边界，返回行数；[sink] 为 null 时只计数不分配，
  /// 返回 true 表示已取到所需内容、提前中止扫描。
  ///
  /// 这是全仓唯一的剧集行扫描器——player_service、source_match_engine 与换源
  /// 控制器过去各自手抄了一份。
  static int _scanLines(String raw, bool Function(int start, int end)? sink) {
    var count = 0;
    var start = 0;
    for (var end = 0; end <= raw.length; end++) {
      if (end != raw.length && raw.codeUnitAt(end) != 0x0A) continue;
      var hasContent = false;
      for (var i = start; i < end; i++) {
        if (raw.codeUnitAt(i) > 0x20) {
          hasContent = true;
          break;
        }
      }
      if (hasContent) {
        count++;
        if (sink != null && sink(start, end)) break;
      }
      start = end + 1;
    }
    return count;
  }

  static bool _isUsableEntry(Object? item) =>
      item is String && !PlaybackEpisode._isBlank(item);

  /// 优先取 `videoList`，否则按行切 `videos`。返回未解析的序列化剧集串。
  static List<String> rawEpisodesOf(Map data) {
    final rawList = data['videoList'];
    if (rawList is List) {
      final out = <String>[];
      for (final item in rawList) {
        if (_isUsableEntry(item)) out.add(item as String);
      }
      if (out.isNotEmpty) return out;
    }

    final raw = data['videos'];
    if (raw is! String || raw.isEmpty) return const [];
    final lines = <String>[];
    _scanLines(raw, (start, end) {
      lines.add(raw.substring(start, end));
      return false;
    });
    return lines;
  }

  /// 取第 [index] 集并解析。口径同 [rawEpisodesOf]，但只为命中的那一集分配
  /// substring——调用方过去为了拿一集要把整个 videos blob 物化一遍。
  static PlaybackEpisode? episodeAt(Map data, int index) {
    if (index < 0) return null;

    final rawList = data['videoList'];
    if (rawList is List) {
      var seen = 0;
      for (final item in rawList) {
        if (!_isUsableEntry(item)) continue;
        if (seen == index) return PlaybackEpisode.parse(item as String);
        seen++;
      }
      // videoList 有可用条目但下标越界：与 rawEpisodesOf 一致，不回落到 videos。
      if (seen > 0) return null;
    }

    final raw = data['videos'];
    if (raw is! String || raw.isEmpty) return null;

    String? hit;
    var seen = 0;
    _scanLines(raw, (start, end) {
      if (seen++ != index) return false;
      hit = raw.substring(start, end);
      return true;
    });
    return hit == null ? null : PlaybackEpisode.parse(hit!);
  }

  /// 集数。与 [rawEpisodesOf] 的口径一致，但不为任何一集分配 substring。
  static int countFrom(Map data) {
    final rawList = data['videoList'];
    if (rawList is List) {
      var count = 0;
      for (final item in rawList) {
        if (_isUsableEntry(item)) count++;
      }
      if (count > 0) return count;
    }

    final raw = data['videos'];
    return (raw is String && raw.isNotEmpty) ? _scanLines(raw, null) : 0;
  }

  static List<PlaybackEpisode> parse(
    Iterable<String> values, {
    bool mergeDuplicateTitles = false,
  }) {
    if (!mergeDuplicateTitles) {
      final episodes = <PlaybackEpisode>[];
      for (final value in values) {
        final episode = PlaybackEpisode.parse(value);
        if (episode != null) episodes.add(episode);
      }
      return UnmodifiableListView(episodes);
    }

    // 惰性合并：目录标题几乎全唯一，首现直接收录解析结果；
    // 只有真正撞到重复标题时才把该槽位的线路表复制成可变列表并在最后重建。
    final slotOf = <String, int>{};
    final episodes = <PlaybackEpisode>[];
    final merged = <int, List<String>>{};

    for (final value in values) {
      final episode = PlaybackEpisode.parse(value);
      if (episode == null) continue;

      final key = _mergeKey(episode.title);
      final slot = slotOf[key];
      if (slot == null) {
        slotOf[key] = episodes.length;
        episodes.add(episode);
      } else {
        (merged[slot] ??= List<String>.of(episodes[slot].lines)).addAll(
          episode.lines,
        );
      }
    }

    for (final entry in merged.entries) {
      episodes[entry.key] = PlaybackEpisode(
        title: episodes[entry.key].title,
        lines: UnmodifiableListView(entry.value),
      );
    }
    return UnmodifiableListView(episodes);
  }

  /// 可见集数索引。空查询时按需正序/倒序直接生成，不再多复制一次 `reversed`。
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
      if (query.isEmpty || _matches(episodes[i].title, query)) result.add(i);
    }
    return result;
  }

  /// `query` 已是小写；标题原样命中即可收工
  /// （中日文标题恒走这条路径）。
  static bool _matches(String title, String query) =>
      title.contains(query) || title.toLowerCase().contains(query);

  static final Set<int> _numberUnits = '一二三四五六七八九十零'.codeUnits.toSet();

  /// `[、.:：]` 加上各类空白（含 NBSP / 全角空格 / BOM）。
  static final Set<int> _separatorUnits = {...'、.:： 　﻿'.codeUnits};

  /// 合并键：剥掉「12、」「3. 」这类序号前缀，让同一集的多条线路归到一起。
  /// 常见的「第N集」不带前导数字，会在第一步就原样返回，零分配。
  static String _mergeKey(String title) {
    final trimmed = title.trim();
    var i = 0;
    while (i < trimmed.length && _isNumberUnit(trimmed.codeUnitAt(i))) {
      i++;
    }
    if (i == 0) return trimmed;

    while (i < trimmed.length && _isSeparatorUnit(trimmed.codeUnitAt(i))) {
      i++;
    }
    final normalized = i >= trimmed.length ? '' : trimmed.substring(i).trim();
    return normalized.isEmpty ? trimmed : normalized;
  }

  static bool _isNumberUnit(int unit) =>
      (unit >= 0x30 && unit <= 0x39) || _numberUnits.contains(unit);

  static bool _isSeparatorUnit(int unit) =>
      unit <= 0x20 || _separatorUnits.contains(unit);
}
