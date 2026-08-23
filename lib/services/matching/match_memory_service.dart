import 'dart:convert';

import 'package:baka/instance.dart';

import 'title_matcher.dart';

class MatchMemoryEntry {
  const MatchMemoryEntry({
    required this.source,
    required this.seriesId,
    required this.updatedAtMs,
    this.title,
    this.sourceDisplayName,
  });

  factory MatchMemoryEntry.fromJson(Map<String, dynamic> raw) {
    return MatchMemoryEntry(
      source: raw['source'] as String,
      seriesId: raw['seriesId'] as String,
      updatedAtMs: raw['updatedAtMs'] as int,
      title: raw['title'] as String?,
      sourceDisplayName: raw['sourceDisplayName'] as String?,
    );
  }

  final String source;
  final String seriesId;
  final int updatedAtMs;
  final String? title;
  final String? sourceDisplayName;

  bool get isValid => source.isNotEmpty && seriesId.isNotEmpty;

  bool isFreshAt(int nowMs) {
    final ageMs = nowMs - updatedAtMs;
    return ageMs >= 0 && ageMs < MatchMemoryService.ttl.inMilliseconds;
  }

  Map<String, dynamic> toJson() => {
    'source': source,
    'seriesId': seriesId,
    'updatedAtMs': updatedAtMs,
    if (title?.isNotEmpty ?? false) 'title': title,
    if (sourceDisplayName?.isNotEmpty ?? false)
      'sourceDisplayName': sourceDisplayName,
  };
}

/// 记住某部番剧上次自动匹配成功的源，下次直接优先探测。
class MatchMemoryService {
  MatchMemoryService._();

  static const Duration ttl = Duration(days: 14);
  static const int maxEntries = 200;
  static const String _storageKey = 'match_memory_v1';
  static const String _aliasesKey = 'video_source_search_aliases';

  static Map<String, MatchMemoryEntry>? _cache;
  static Map<String, List<String>>? _aliases;

  static List<String> readAliases(String key, {String? fallbackKey}) {
    final aliases = _readAliases();
    return aliases[key] ??
        (fallbackKey == null ? null : aliases[fallbackKey]) ??
        const [];
  }

  static Future<void> saveAliases(String key, List<String> values) async {
    final aliases = _readAliases();
    if (values.isEmpty) {
      aliases.remove(key);
    } else {
      aliases[key] = values;
    }
    await Instances.sp.setString(_aliasesKey, jsonEncode(aliases));
  }

  static MatchMemoryEntry? read({required String title, int? bgmId}) {
    final entry = _readAll()[keyFor(bgmId: bgmId, title: title)];
    if (entry == null) return null;
    if (entry.isFreshAt(DateTime.now().millisecondsSinceEpoch) &&
        entry.isValid) {
      return entry;
    }
    _readAll().remove(keyFor(bgmId: bgmId, title: title));
    return null;
  }

  static Future<void> writeSuccess({
    required String title,
    required String source,
    required String seriesId,
    int? bgmId,
    String? candidateTitle,
    String? sourceDisplayName,
  }) async {
    if (source.isEmpty || seriesId.isEmpty || source == 'internal') return;

    final map = _readAll();
    map[keyFor(bgmId: bgmId, title: title)] = MatchMemoryEntry(
      source: source,
      seriesId: seriesId,
      title: candidateTitle,
      sourceDisplayName: sourceDisplayName,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _prune(map);
    await _persist(map);
  }

  static Future<void> remove({required String title, int? bgmId}) async {
    final map = _readAll();
    if (map.remove(keyFor(bgmId: bgmId, title: title)) != null) {
      await _persist(map);
    }
  }

  static String keyFor({required String title, int? bgmId}) {
    if (bgmId != null && bgmId > 0) return 'bgm:$bgmId';
    return 'title:${TitleFingerprint.normalize(title)}';
  }

  static Map<String, MatchMemoryEntry> _readAll() {
    final cached = _cache;
    if (cached != null) return cached;

    final raw = Instances.sp.getString(_storageKey);
    if (raw == null || raw.isEmpty) return _cache = {};

    try {
      final decoded = jsonDecode(raw);
      return _cache = (decoded as Map<String, dynamic>).map(
        (key, value) => MapEntry(
          key,
          MatchMemoryEntry.fromJson(value as Map<String, dynamic>),
        ),
      );
    } catch (_) {
      return _cache = {};
    }
  }

  static Map<String, List<String>> _readAliases() {
    final cached = _aliases;
    if (cached != null) return cached;
    final raw = Instances.sp.getString(_aliasesKey);
    if (raw == null || raw.isEmpty) return _aliases = {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return _aliases = {
      for (final entry in decoded.entries)
        entry.key: (entry.value as List<dynamic>).cast<String>(),
    };
  }

  static void _prune(Map<String, MatchMemoryEntry> map) {
    final now = DateTime.now().millisecondsSinceEpoch;
    map.removeWhere((_, entry) => !entry.isFreshAt(now) || !entry.isValid);
    if (map.length <= maxEntries) return;

    final entries = map.entries.toList()
      ..sort((a, b) => b.value.updatedAtMs.compareTo(a.value.updatedAtMs));
    map
      ..clear()
      ..addEntries(entries.take(maxEntries));
  }

  static Future<void> _persist(Map<String, MatchMemoryEntry> map) {
    _cache = map;
    return Instances.sp.setString(_storageKey, jsonEncode(map));
  }
}
