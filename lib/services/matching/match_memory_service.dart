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

  factory MatchMemoryEntry.fromJson(dynamic raw) {
    if (raw is! Map) {
      return const MatchMemoryEntry(source: '', seriesId: '', updatedAtMs: 0);
    }
    return MatchMemoryEntry(
      source: raw['source']?.toString() ?? '',
      seriesId: raw['seriesId']?.toString() ?? '',
      updatedAtMs: (raw['updatedAtMs'] as num?)?.toInt() ?? 0,
      title: raw['title']?.toString(),
      sourceDisplayName: raw['sourceDisplayName']?.toString(),
    );
  }

  final String source;
  final String seriesId;
  final int updatedAtMs;
  final String? title;
  final String? sourceDisplayName;

  bool get isValid => source.isNotEmpty && seriesId.isNotEmpty;

  bool get isFresh {
    final ageMs = DateTime.now().millisecondsSinceEpoch - updatedAtMs;
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

  static Map<String, MatchMemoryEntry>? _cache;

  static MatchMemoryEntry? read({required String title, int? bgmId}) {
    final entry = _readAll()[keyFor(bgmId: bgmId, title: title)];
    if (entry == null) return null;
    if (entry.isFresh && entry.isValid) return entry;
    remove(bgmId: bgmId, title: title);
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
      if (decoded is! Map) return _cache = {};
      return _cache = decoded.map(
        (key, value) =>
            MapEntry(key.toString(), MatchMemoryEntry.fromJson(value)),
      );
    } catch (_) {
      return _cache = {};
    }
  }

  static void _prune(Map<String, MatchMemoryEntry> map) {
    map.removeWhere((_, entry) => !entry.isFresh || !entry.isValid);
    if (map.length <= maxEntries) return;

    final entries = map.entries.toList()
      ..sort((a, b) => b.value.updatedAtMs.compareTo(a.value.updatedAtMs));
    map
      ..clear()
      ..addEntries(entries.take(maxEntries));
  }

  static Future<void> _persist(Map<String, MatchMemoryEntry> map) {
    _cache = map;
    final json = jsonEncode({
      for (final entry in map.entries) entry.key: entry.value.toJson(),
    });
    return Instances.sp.setString(_storageKey, json);
  }
}
