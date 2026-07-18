import 'dart:convert';

import 'package:baka/instance.dart';

/// 源信誉先验：每个源一个指数移动平均分，取值 [-1, 1]。
///
/// 成功记 +1、失败记 -1，按 [_alpha] 混入历史分。
/// 新样本天然稀释旧样本，无需按时钟做衰减计算。
class SourceReputationService {
  SourceReputationService._();

  static const String _storageKey = 'source_reputation_v2';
  static const double _alpha = 0.2;

  static Map<String, double>? _scores;
  static Future<void>? _pendingWrite;
  static bool _dirty = false;

  static Map<String, double> snapshotFor(Iterable<String> sourceKeys) {
    final scores = _read();
    final snapshot = <String, double>{};
    for (final key in sourceKeys) {
      final score = scores[key];
      if (score != null) snapshot[key] = score;
    }
    return snapshot;
  }

  static Future<void> recordSuccess(String sourceKey) => _record(sourceKey, 1);

  static Future<void> recordFailure(String sourceKey) => _record(sourceKey, -1);

  static Future<void> _record(String sourceKey, double sample) {
    if (sourceKey.isEmpty || sourceKey == 'internal') {
      return Future<void>.value();
    }

    final scores = _read();
    final current = scores[sourceKey] ?? 0;
    scores[sourceKey] = (current * (1 - _alpha) + sample * _alpha).clamp(
      -1.0,
      1.0,
    );
    _dirty = true;
    return _flush();
  }

  static Future<void> _flush() => _pendingWrite ??= Future.doWhile(() async {
    _dirty = false;
    await Instances.sp.setString(_storageKey, jsonEncode(_read()));
    return _dirty;
  }).whenComplete(() => _pendingWrite = null);

  static Map<String, double> _read() {
    final cached = _scores;
    if (cached != null) return cached;

    final raw = Instances.sp.getString(_storageKey);
    if (raw == null || raw.isEmpty) return _scores = <String, double>{};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return _scores = <String, double>{};
      return _scores = {
        for (final entry in decoded.entries)
          if (entry.value is num)
            entry.key.toString(): (entry.value as num).toDouble(),
      };
    } catch (_) {
      return _scores = <String, double>{};
    }
  }
}
